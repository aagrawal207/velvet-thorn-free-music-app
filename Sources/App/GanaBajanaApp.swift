import BackgroundTasks
import SwiftUI
import UserNotifications

@main
@MainActor
struct GanaBajanaApp: App {
    @UIApplicationDelegateAdaptor(BackgroundDownloadApplicationDelegate.self) private var appDelegate
    static let releaseRefreshTask = "com.agraabhi.ganabajana.releases"

    @State private var model: MusicAppModel
    private let notificationPresenter: ForegroundNotificationPresenter
    private let watchPhoneSession: WatchPhoneSession?
    private let handoffPublisher: PlaybackHandoffPublisher

    init() {
        TipSupport.configure(isTesting: Self.isTesting, arguments: ProcessInfo.processInfo.arguments)
        #if DEBUG
        let model = DebugBootstrap.makeModel()
        DebugBootstrap.installUITestGeometryRequests()
        #else
        let model = MusicAppModel()
        #endif
        _model = State(initialValue: model)
        let presenter = ForegroundNotificationPresenter { [weak model] route in
            model?.receiveReleaseNotification(route)
        }
        notificationPresenter = presenter
        TVLyricsRuntime.shared.install(model.tvLyrics)
        PlaybackIntentRuntime.perform = { [weak model] command in
            model?.performPlaybackIntent(command) ?? .unavailable
        }
        #if DEBUG
        if !Self.isTesting { model.startWidgetUpdates() }
        else { DebugWidgetSupport.startSharing(model) }
        #else
        model.startWidgetUpdates()
        #endif
        let companionPlayback = CompanionPlaybackController(model: model)
        CompanionRuntime.playback = companionPlayback
        let handoff = PlaybackHandoffPublisher(model: model)
        handoffPublisher = handoff
        handoff.start()
        let nearby = Self.makeNearbyDevices(model: model, playback: companionPlayback)
        model.nearbyDevices = nearby
        #if DEBUG
        let startsWatchSession = !Self.isTesting || DebugBootstrap.usesPairedWatchFixture
        #else
        let startsWatchSession = !Self.isTesting
        #endif
        if !startsWatchSession {
            watchPhoneSession = nil
        } else {
            let session = WatchPhoneSession(playback: companionPlayback)
            watchPhoneSession = session
            session.start()
        }
        if !Self.isTesting { appDelegate.reconnectDownloads = { model.restoreDownloadQueue() } }
        UNUserNotificationCenter.current().delegate = presenter
        #if DEBUG
        DebugReleaseNotificationFixture.install(presenter, model: model)
        #endif
        Self.registerReleaseRefresh(model)
        Self.registerMixRefresh(model)
        Self.scheduleMixRefresh()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.momentMixController, model.momentMixes)
                .modifier(PhoneSceneLifecycle(model: model))
                .modifier(HandoffSceneLifecycle(publisher: handoffPublisher))
                .onContinueUserActivity(PlaybackHandoffCodec.activityType) { activity in
                    model.acceptHandoff(activity)
                }
                .modifier(TVLyricsPhoneLifecycle(controller: model.tvLyrics))
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    model.momentMixes.synchronize(library: model.library, historyEpoch: model.library.listeningHistoryEpoch)
                }
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .task {
                    if !Self.isTesting { model.activateDeviceServices() }
                    #if DEBUG
                    await DebugBootstrap.performLaunchAction(model)
                    async let snapshots: Void = DebugWindowSnapshot.run(model)
                    async let nearby: Void = DebugNearbyFixture.run(model)
                    _ = await (snapshots, nearby)
                    #endif
                }
        }
        .commands { VelvetThornCommands(model: model) }
    }

    /// Fixture and unit hosts keep their own enable flag so a developer's saved On never opens sockets in tests.
    private static func makeNearbyDevices(model: MusicAppModel, playback: CompanionPlaybackController) -> NearbyDevicesController {
        #if DEBUG
        if let fixture = DebugNearbyFixture.makeController(model: model, playback: playback) { return fixture }
        #endif
        guard isTesting, let defaults = UserDefaults(suiteName: "com.agraabhi.ganabajana.nearby-tests") else {
            return NearbyDevicesController(model: model, playback: playback)
        }
        defaults.removeObject(forKey: NearbyDevicesController.enabledKey)
        defaults.removeObject(forKey: NearbyDevicesController.choiceMadeKey)
        let identity = NearbyDeviceIdentity.current
        return NearbyDevicesController(host: MusicAppNearbyHost(model: model, playback: playback), transport: NearbyNetworkTransport(),
                                       keyStore: KeychainNearbyLinkKeyStore(), defaults: defaults,
                                       displayName: identity.name, deviceKind: identity.kind)
    }

    private static func registerReleaseRefresh(_ model: MusicAppModel) {
        guard Bundle.main.bundleIdentifier != nil, !isTesting else { return }
        ReleaseRefreshRegistration.register(identifier: releaseRefreshTask, operation: {
            _ = await model.checkForNewReleases()
        }, reschedule: { scheduleReleaseRefresh() })
    }

    /// Opportunistic: iOS decides when (or whether) the refresh runs, so foreground checks remain the primary path.
    fileprivate static func scheduleReleaseRefresh() {
        guard Bundle.main.bundleIdentifier != nil, !isTesting else { return }
        let request = BGAppRefreshTaskRequest(identifier: releaseRefreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(ReleaseWatcher.checkInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func registerMixRefresh(_ model: MusicAppModel) {
        guard Bundle.main.bundleIdentifier != nil, !isTesting else { return }
        MixRefreshRegistration.register(operation: { await model.refreshMixesForBackgroundTask() },
                                        reschedule: { scheduleMixRefresh() })
    }

    /// Same opportunistic contract as release refresh; Home's `refreshMixes()` on load stays the primary path.
    static func scheduleMixRefresh() {
        guard Bundle.main.bundleIdentifier != nil, !isTesting else { return }
        MixRefreshRegistration.schedule()
    }

    fileprivate static var isTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("--uitesting")
        #else
        false
        #endif
    }
}

@MainActor
private struct HandoffSceneLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let publisher: PlaybackHandoffPublisher

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase, initial: true) { _, phase in publisher.setSceneActive(phase == .active) }
    }
}

@MainActor
private struct PhoneSceneLifecycle: ViewModifier {
    // Read inside the window content so an active CarPlay scene cannot mask the phone window's own phase.
    @Environment(\.scenePhase) private var scenePhase
    let model: MusicAppModel

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.player.flushListeningProgress() }
                if phase == .background {
                    GanaBajanaApp.scheduleReleaseRefresh()
                    GanaBajanaApp.scheduleMixRefresh()
                }
                if phase == .active {
                    if !GanaBajanaApp.isTesting { model.activateDeviceServices() }
                    Task { await model.checkForNewReleases() }
                } else {
                    model.deactivateDeviceServices()
                }
            }
    }
}

@MainActor
enum ReleaseRefreshRegistration {
    @MainActor
    struct TaskHandle {
        let installExpiration: @MainActor (@escaping @Sendable () -> Void) -> Void
        let complete: @MainActor (Bool) -> Void
    }

    typealias LaunchHandler = @MainActor @Sendable (TaskHandle) -> Void
    typealias Registrar = @MainActor (String, DispatchQueue, @escaping LaunchHandler) -> Bool

    @discardableResult
    static func register(identifier: String, registrar: Registrar? = nil,
                         operation: @escaping @MainActor () async -> Void,
                         reschedule: @escaping @MainActor () -> Void) -> Bool {
        let register = registrar ?? registerWithSystem
        // The SDK callback inherits main-actor isolation; its queue must match before the callback enters.
        return register(identifier, .main) { handle in
            let work = Task { @MainActor in
                if !Task.isCancelled { await operation() }
                reschedule()
                handle.complete(!Task.isCancelled)
            }
            handle.installExpiration { @Sendable in work.cancel() }
        }
    }

    private static func registerWithSystem(identifier: String, queue: DispatchQueue,
                                           launch: @escaping LaunchHandler) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: queue) { task in
            launch(TaskHandle(installExpiration: { task.expirationHandler = $0 },
                              complete: { task.setTaskCompleted(success: $0) }))
        }
    }
}
