#if DEBUG
import Foundation

/// End-to-end link check between two local builds (Mac and simulator) that cannot share an iCloud Keychain item.
/// `--nearby-fixture <64 hex key> [--nearby-fixture-action playHere|playOn]`; results print as `NEARBY_FIXTURE` lines.
@MainActor
enum DebugNearbyFixture {
    static var key: Data? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--nearby-fixture"), arguments.indices.contains(index + 1) else { return nil }
        let hex = Array(arguments[index + 1].utf8)
        guard hex.count == 64 else { return nil }
        var bytes: [UInt8] = []
        for offset in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[offset..<offset + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    static func makeController(model: MusicAppModel, playback: CompanionPlaybackController) -> NearbyDevicesController? {
        guard let key, let defaults = UserDefaults(suiteName: "com.agraabhi.ganabajana.nearby-fixture") else { return nil }
        defaults.removePersistentDomain(forName: "com.agraabhi.ganabajana.nearby-fixture")
        let identity = NearbyDeviceIdentity.current
        let controller = NearbyDevicesController(host: MusicAppNearbyHost(model: model, playback: playback),
                                                 transport: NearbyNetworkTransport(), keyStore: FixtureKeyStore(key: key),
                                                 defaults: defaults, displayName: identity.name, deviceKind: identity.kind)
        controller.enable()
        return controller
    }

    static func run(_ model: MusicAppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard key != nil, let controller = model.nearbyDevices else { return }
        let action = arguments.firstIndex(of: "--nearby-fixture-action").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        report("started kind=\(controller.deviceKind.rawValue) action=\(action ?? "none")")
        let started = Date()
        while controller.peers.first(where: \.isConnected) == nil, Date().timeIntervalSince(started) < 60 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let peer = controller.peers.first(where: \.isConnected) else { report("result=no_peer"); return }
        report("connected seconds=\(Int(Date().timeIntervalSince(started))) peer_kind=\(peer.kind.rawValue)")
        try? await Task.sleep(for: .seconds(3))
        if let remote = controller.peers.first(where: { $0.id == peer.id })?.nowPlaying?.snapshot.nowPlaying {
            report("peer_now_playing track=\(remote.trackID) playing=\(remote.isPlaying) position=\(Int(remote.position))")
        } else {
            report("peer_now_playing none")
        }
        switch action {
        case "playHere": controller.playHere(from: peer.id)
        case "playOn": controller.playOn(peer.id)
        default: break
        }
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            let player = model.player
            let remote = controller.peers.first(where: { $0.id == peer.id })?.nowPlaying?.snapshot.nowPlaying
            report("tick local_track=\(player.currentTrack?.id ?? "none") local_playing=\(player.isPlaying) "
                + "local_position=\(String(format: "%.1f", player.position)) remote_playing=\(remote?.isPlaying ?? false) "
                + "remote_position=\(String(format: "%.1f", remote?.position ?? -1)) transfer=\(controller.transferState)")
        }
        report("done")
    }

    nonisolated private static func report(_ line: String) {
        print("NEARBY_FIXTURE \(line)")
        fflush(stdout)
    }

    private struct FixtureKeyStore: NearbyLinkKeyStoring {
        let key: Data
        func readLinkKey() throws -> Data? { key }
        func writeLinkKey(_ key: Data) throws {}
    }
}
#endif
