import Foundation
import OSLog
import UserNotifications

struct ReleaseNotificationRoute: Sendable {
    let id: String
    let title: String
    let subtitle: String

    init?(request: UNNotificationRequest, actionIdentifier: String) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              request.identifier.hasPrefix("release.") else { return nil }
        let id = String(request.identifier.dropFirst("release.".count))
        guard !id.isEmpty, id.utf8.count <= 512,
              !id.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        self.id = id
        title = Self.text(request.content.userInfo["releaseTitle"], fallback: "New Release")
        subtitle = Self.text(request.content.userInfo["releaseSubtitle"], fallback: "")
    }

    private static func text(_ value: Any?, fallback: String) -> String {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= 2_048 else { return fallback }
        return text
    }
}

final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let openRelease: @MainActor @Sendable (ReleaseNotificationRoute) -> Void
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Releases")

    init(openRelease: @escaping @MainActor @Sendable (ReleaseNotificationRoute) -> Void) {
        self.openRelease = openRelease
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // UIKit's response completion asserts the main thread; the async form would finish on the cooperative pool and crash.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let task = handle(request: response.notification.request, actionIdentifier: response.actionIdentifier)
        let completion = MainThreadCompletion(completionHandler)
        Task { @MainActor in
            await task.value
            completion.run()
        }
    }

    func handle(request: UNNotificationRequest, actionIdentifier: String) -> Task<Void, Never> {
        let route = ReleaseNotificationRoute(request: request, actionIdentifier: actionIdentifier)
        let openRelease = self.openRelease
        return Task { @MainActor in
            guard let route else {
                Self.log.debug("event=release_notification_tap outcome=ignored")
                return
            }
            openRelease(route)
            Self.log.debug("event=release_notification_tap outcome=accepted")
        }
    }
}

/// UserNotifications hands over a non-Sendable completion; it is only ever invoked on the main actor.
private struct MainThreadCompletion: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) { self.body = body }

    @MainActor func run() { body() }
}
