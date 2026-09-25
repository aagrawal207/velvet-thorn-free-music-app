import SwiftUI

@main
@MainActor
struct GanaBajanaWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
        .backgroundTask(.watchConnectivity) {
            await WatchAppSession.shared.receiveBackgroundUpdates()
        }
    }
}
