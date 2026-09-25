import Foundation

@MainActor
final class WatchAppSession {
    static let shared = WatchAppSession()

    let model: WatchCompanionModel
    private let transport: WatchConnectivityTransport?

    private init() {
        #if DEBUG
        if let client = WatchDebugFixtures.client(arguments: ProcessInfo.processInfo.arguments) {
            transport = nil
            model = WatchCompanionModel(client: client)
            return
        }
        #endif
        let transport = WatchConnectivityTransport()
        self.transport = transport
        model = WatchCompanionModel(client: WatchRequestClient(transport: transport))
    }

    func receiveBackgroundUpdates() async {
        model.start()
        await transport?.finishBackgroundDelivery()
    }
}
