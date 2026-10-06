import Foundation
import UIKit

@MainActor
final class BackgroundDownloadApplicationDelegate: NSObject, UIApplicationDelegate {
    nonisolated override init() { super.init() }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        TVLyricsSceneConfiguration.configuration(for: session.role)
            ?? UISceneConfiguration(name: nil, sessionRole: session.role)
    }

    var reconnectDownloads: (@MainActor () -> Void)? {
        didSet { reconnectIfNeeded() }
    }
    private var reconnectPending = false

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard BackgroundDownloadCompletion.handleEvents(identifier: identifier, completionHandler: completionHandler) else {
            completionHandler()
            return
        }
        reconnectPending = true
        reconnectIfNeeded()
    }

    private func reconnectIfNeeded() {
        guard reconnectPending, let reconnectDownloads else { return }
        reconnectPending = false
        reconnectDownloads()
    }
}

/// UIKit owns these closures. A drain may arrive before application(_:handleEventsForBackgroundURLSession:completionHandler:).
@MainActor
enum BackgroundDownloadCompletion {
    private static var handlers: [() -> Void] = []
    private static var drained = false

    @discardableResult
    static func handleEvents(identifier: String, completionHandler: @escaping () -> Void) -> Bool {
        guard identifier == SystemBackgroundDownloadSession.identifier else { return false }
        handlers.append(completionHandler)
        finishIfReady()
        return true
    }

    static func didDrain() {
        drained = true
        finishIfReady()
    }

    private static func finishIfReady() {
        guard drained, !handlers.isEmpty else { return }
        let pending = handlers
        handlers.removeAll()
        drained = false
        pending.forEach { $0() }
    }
}
