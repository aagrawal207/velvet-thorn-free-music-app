import AVFoundation
import Foundation
import OSLog

enum LiveRadioDiagnostics {
    enum Stage: String, Sendable {
        case probeResponse = "probe_response", probeMIME = "probe_mime", probeBody = "probe_body"
        case probePlaylist = "probe_playlist", probeComplete = "probe_complete", resolvedURL = "resolved_url"
        case probeElementary = "probe_elementary", nativeElementary = "native_elementary"
        case nativePlayable = "native_playable", nativeAudio = "native_audio", nativeVideo = "native_video"
    }
    enum Outcome: String, Sendable { case began, passed, rejected, failed, cancelled }
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "LiveRadio")

    static func record(_ stage: Stage, _ outcome: Outcome) {
        log.info("event=live_radio_validation stage=\(stage.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
    }
}

enum LiveRadioNativeValidation {
    static func validate(_ asset: AVURLAsset, connection: LiveRadioConnection? = nil) async throws {
        try await validate(url: asset.url, connection: connection,
            playable: { try await asset.load(.isPlayable) },
            audioCount: { (try await asset.loadTracks(withMediaType: .audio)).count },
            videoCount: { (try await asset.loadTracks(withMediaType: .video)).count })
    }

    static func validate(url: URL, connection: LiveRadioConnection? = nil,
                         playable: @Sendable () async throws -> Bool,
                         audioCount: @Sendable () async throws -> Int,
                         videoCount: @Sendable () async throws -> Int) async throws {
        try await require(.resolvedURL) { LiveRadioURLPolicy.permits(url) }
        try await require(.nativePlayable, check: playable)
        try await require(.nativeVideo) { try await videoCount() == 0 }
        try await require(.nativeAudio) {
            let count = try await audioCount()
            if count > 0 { return true }
            // Continuous elementary audio and HLS expose item tracks without a static asset-track collection.
            let proven = count == 0 && (connection?.hasElementaryProof(for: url) == true
                || connection?.hasPlaylistProof(for: url) == true)
            LiveRadioDiagnostics.record(.nativeElementary, proven ? .passed : .rejected)
            return proven
        }
    }

    static func require(_ stage: LiveRadioDiagnostics.Stage, check: @Sendable () async throws -> Bool) async throws {
        LiveRadioDiagnostics.record(stage, .began)
        let accepted: Bool
        do {
            try Task.checkCancellation()
            accepted = try await check()
            try Task.checkCancellation()
        } catch {
            LiveRadioDiagnostics.record(stage, Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            throw error
        }
        LiveRadioDiagnostics.record(stage, accepted ? .passed : .rejected)
        guard accepted else { throw LiveRadioError.invalidStation }
    }
}
