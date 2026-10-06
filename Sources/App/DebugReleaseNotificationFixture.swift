#if DEBUG
import Foundation
import UserNotifications

@MainActor
enum DebugReleaseNotificationFixture {
    private static var presenter: ForegroundNotificationPresenter?

    static func install(_ presenter: ForegroundNotificationPresenter, model: MusicAppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"), arguments.contains("--release-notification-fixture") else { return }
        self.presenter = presenter
        // Delivers a real banner so UI tests can exercise the system delegate entry point.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request().identifier])
        if arguments.contains("--release-notification-system") { scheduleSystemNotification() }
        if arguments.contains("--release-notification-on-launch"),
           let route = ReleaseNotificationRoute(request: request(), actionIdentifier: UNNotificationDefaultActionIdentifier) {
            model.receiveReleaseNotification(route)
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            Task { @MainActor in
                await DebugReleaseNotificationFixture.presenter?.handle(
                    request: DebugReleaseNotificationFixture.request(), actionIdentifier: UNNotificationDefaultActionIdentifier).value
            }
        }, "com.agraabhi.ganabajana.uitests.release.tap" as CFString, nil, .deliverImmediately)
    }

    private static func request(trigger: UNNotificationTrigger? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Notification Album"
        content.userInfo = ["releaseTitle": "Notification Album"]
        return UNNotificationRequest(identifier: "release.\(DebugMusicFixtures.albumID)", content: content, trigger: trigger)
    }

    private static func scheduleSystemNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            center.removeAllDeliveredNotifications()
            try? await center.add(request(trigger: UNTimeIntervalNotificationTrigger(timeInterval: 15, repeats: false)))
        }
    }
}
#endif
