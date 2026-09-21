import BackgroundTasks
import SwiftUI
import UserNotifications

@main
@MainActor
struct GanaBajanaApp: App {
    static let releaseRefreshTask = "com.agraabhi.ganabajana.releases"

    @Environment(\.scenePhase) private var scenePhase
    @State private var model: MusicAppModel
    private let notificationPresenter = ForegroundNotificationPresenter()

    init() {
        #if DEBUG
        let model = DebugBootstrap.makeModel()
        DebugBootstrap.installUITestGeometryRequests()
        #else
        let model = MusicAppModel()
        #endif
        _model = State(initialValue: model)
        UNUserNotificationCenter.current().delegate = notificationPresenter
        Self.registerReleaseRefresh(model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.player.flushListeningProgress() }
                    if phase == .background { Self.scheduleReleaseRefresh() }
                    if phase == .active { Task { await model.checkForNewReleases() } }
                }
                .onOpenURL { url in
                    guard url.scheme == "ganabajana", url.host == "search",
                          let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "q" })?.value else { return }
                    model.openSearch(query)
                }
                .task {
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
    private static func scheduleReleaseRefresh() {
        guard Bundle.main.bundleIdentifier != nil, !isTesting else { return }
        let request = BGAppRefreshTaskRequest(identifier: releaseRefreshTask)
        request.earliestBeginDate = Date().addingTimeInterval(ReleaseWatcher.checkInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.arguments.contains("--uitesting")
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
