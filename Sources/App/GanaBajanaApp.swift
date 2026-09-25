import BackgroundTasks
import SwiftUI
import UserNotifications

@main
@MainActor
struct GanaBajanaApp: App {
    static let releaseRefreshTask = "com.agraabhi.ganabajana.releases"

    @State private var model: MusicAppModel
    private let notificationPresenter = ForegroundNotificationPresenter()
    private let watchPhoneSession: WatchPhoneSession?

    init() {
        #if DEBUG
        let model = DebugBootstrap.makeModel()
        DebugBootstrap.installUITestGeometryRequests()
        #else
        let model = MusicAppModel()
        #endif
        _model = State(initialValue: model)
        #if DEBUG
        if !Self.isTesting { model.startWidgetUpdates() }
        else { DebugWidgetSupport.startSharing(model) }
        #else
        model.startWidgetUpdates()
        #endif
        let companionPlayback = CompanionPlaybackController(model: model)
        CompanionRuntime.playback = companionPlayback
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
        UNUserNotificationCenter.current().delegate = notificationPresenter
        Self.registerReleaseRefresh(model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modifier(PhoneSceneLifecycle(model: model))
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .task {
                    if !Self.isTesting { model.activateDeviceServices() }
                    #if DEBUG
                    await DebugBootstrap.performLaunchAction(model)
                    #endif
                }
        }
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
private struct PhoneSceneLifecycle: ViewModifier {
    // Read inside the window content so an active CarPlay scene cannot mask the phone window's own phase.
    @Environment(\.scenePhase) private var scenePhase
    let model: MusicAppModel

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { model.player.flushListeningProgress() }
                if phase == .background { GanaBajanaApp.scheduleReleaseRefresh() }
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

/// Lets release alerts show as banners while the app is open, matching what the lock screen would show.
private final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
