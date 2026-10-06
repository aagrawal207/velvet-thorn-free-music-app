import AVFoundation
import Foundation
import ImageIO
import MediaPlayer
import OSLog
import UIKit

@MainActor
final class PlaybackSystemControls {
    private weak var owner: PlayerController?
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var artworkTrackID: String?
    private var artwork: MPMediaItemArtwork?
    private var transitionTask: UIBackgroundTaskIdentifier = .invalid
    private var transitionToken = UUID()
    private var listeningTask: UIBackgroundTaskIdentifier = .invalid
    private var listeningToken = UUID()
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "AudioSession")

    init(owner: PlayerController) {
        self.owner = owner
        configureSession()
        observeSystem()
        registerCommands(owner: owner)
    }

    func configureSession() {
        do { try PlaybackAudioRoute.session.apply(to: AVAudioSession.sharedInstance()) }
        catch { log.error("event=session_configuration_failed") }
    }

    func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try PlaybackAudioRoute.session.apply(to: session)
        try session.setActive(true)
    }

    func deactivateSession() {
        // Pausing yields the audio session but keeps the published, resumable Now Playing selection.
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { log.debug("event=session_deactivation_deferred") }
    }

    func tearDown() {
        endTransition()
        endListeningCheckpoint()
        artworkTask?.cancel()
        artworkTask = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        commands.forEach { $0.0.removeTarget($0.1) }
        commands.removeAll()
    }

    func beginTransition() {
        guard transitionTask == .invalid else { return }
        let token = UUID()
        transitionToken = token
        transitionTask = UIApplication.shared.beginBackgroundTask(withName: "Load next song") { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.transitionToken == token, self.transitionTask != .invalid else { return }
                self.endTransition()
                self.owner?.handleBackgroundTransitionExpired()
            }
        }
    }

    func endTransition() {
        guard transitionTask != .invalid else { return }
        let task = transitionTask
        transitionTask = .invalid
        transitionToken = UUID()
        UIApplication.shared.endBackgroundTask(task)
    }

    func update(track: Track?, position: TimeInterval, duration: TimeInterval, playing: Bool, index: Int, count: Int) {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = track != nil
        commands.pauseCommand.isEnabled = track != nil
        commands.togglePlayPauseCommand.isEnabled = track != nil
        commands.stopCommand.isEnabled = track != nil
        commands.nextTrackCommand.isEnabled = count > 0
        commands.previousTrackCommand.isEnabled = count > 0
        commands.changePlaybackPositionCommand.isEnabled = track != nil && duration > 0
        guard let track else {
            artworkTask?.cancel()
            artworkURL = nil
            artworkTrackID = nil
            artwork = nil
            center.nowPlayingInfo = nil
            return
        }
        loadArtwork(for: track)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistName,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: PlaybackTiming.position(position, duration: duration),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: count,
            MPNowPlayingInfoPropertyExternalContentIdentifier: track.id
        ]
        if let album = track.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
    }

    static func liveNowPlayingInfo(station: LiveRadioStation, playing: Bool) -> [String: Any] {
        [MPMediaItemPropertyTitle: station.name,
         MPMediaItemPropertyArtist: "Live Radio",
         MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
         MPNowPlayingInfoPropertyIsLiveStream: true,
         MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
         MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0]
    }

    func updateLive(station: LiveRadioStation, playing: Bool) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        artworkTrackID = nil
        artwork = nil
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.changePlaybackPositionCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.liveNowPlayingInfo(station: station, playing: playing)
    }

    func beginListeningCheckpoint() {
        guard listeningTask == .invalid else { return }
        let token = UUID()
        listeningToken = token
        listeningTask = UIApplication.shared.beginBackgroundTask(withName: "Save listening checkpoint") { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.listeningToken == token, self.listeningTask != .invalid else { return }
                self.owner?.handleListeningCheckpointExpiration()
            }
        }
    }

    func endListeningCheckpoint() {
        guard listeningTask != .invalid else { return }
        let task = listeningTask
        listeningTask = .invalid
        listeningToken = UUID()
        UIApplication.shared.endBackgroundTask(task)
    }

    private func loadArtwork(for track: Track) {
        guard artworkTrackID != track.id || artworkURL != track.artworkURL else { return }
        artworkTask?.cancel()
        artworkTrackID = track.id
        artworkURL = track.artworkURL
        artwork = nil
        guard let url = track.artworkURL, url.scheme?.lowercased() == "https" else { return }
        let trackID = track.id
        artworkTask = Task { @MainActor [weak self] in
            // The lock screen shows artwork near full width, so try the large variant before the stored one.
            let candidates = ArtworkURL.candidates(for: url, tier: .large) + [url]
            for candidate in candidates {
                do {
                    let data = try await PlaybackDeadline.run(seconds: 12) { try await Self.fetchArtwork(candidate) }
                    try Task.checkCancellation()
                    guard let self, self.artworkTrackID == trackID, self.artworkURL == url else { return }
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1024
                          ] as CFDictionary) else { continue }
                    let image = UIImage(cgImage: thumbnail)
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
                    self.owner?.publishNowPlaying()
                    return
                } catch is CancellationError {
                    return
                } catch { }
            }
        }
    }

    private nonisolated static func fetchArtwork(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.chunkedBody(from: url)
        defer { body.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= 5_000_000 else {
            throw MusicServiceError.invalidResponse
        }
        var data = Data()
        for try await chunk in body {
            try Task.checkCancellation()
            guard chunk.count <= 5_000_000 - data.count else { throw MusicServiceError.invalidResponse }
            data.append(chunk)
        }
        return data
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) {
            @Sendable [weak owner] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                if type == AVAudioSession.InterruptionType.began.rawValue { owner?.handleInterruption(began: true) }
                else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    owner?.handleInterruption(began: false, shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
            @Sendable [weak owner, log = self.log] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
                let kind = PlaybackAudioRoute.kind(for: outputs)
                let external = owner?.isExternalPlaybackActive == true ? 1 : 0
                log.info("event=route_change kind=\(kind.rawValue, privacy: .public) reason=\(reason ?? 0) external=\(external)")
                // Only losing the device pauses; a new AirPlay route keeps the player's clock running, so stall recovery stays idle.
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { owner?.handleRouteDetached() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) {
            @Sendable [weak owner] _ in
            MainActor.assumeIsolated { owner?.handleMediaServicesReset() }
        })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification,
                     UIApplication.didBecomeActiveNotification, UIApplication.willTerminateNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) {
                @Sendable [weak owner] _ in
                MainActor.assumeIsolated { owner?.handleLifecycleCheckpoint() }
            })
        }
    }

    private func registerCommands(owner: PlayerController) {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in Self.performTransport(.play, owner: owner) }
            return .success
        }
        register(center.pauseCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in Self.performTransport(.pause, owner: owner) }
            return .success
        }
        register(center.stopCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in Self.performTransport(.stop, owner: owner) }
            return .success
        }
        register(center.togglePlayPauseCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in Self.performTransport(.toggle, owner: owner) }
            return .success
        }
        register(center.nextTrackCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in owner?.next() }
            return .success
        }
        register(center.previousTrackCommand) { @Sendable [weak owner] _ in
            Task { @MainActor [weak owner] in owner?.previous() }
            return .success
        }
        register(center.changePlaybackPositionCommand) { @Sendable [weak owner] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak owner] in owner?.seek(to: position) }
            return .success
        }
    }

    private func register(_ command: MPRemoteCommand, handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        commands.append((command, command.addTarget(handler: handler)))
    }

    enum TransportAction { case play, pause, toggle, stop }

    static func performTransport(_ action: TransportAction, owner: PlayerController?) {
        switch action {
        case .play: owner?.resumePlayback()
        case .pause: owner?.pause()
        case .toggle: owner?.togglePlayback()
        case .stop: owner?.stopPlayback()
        }
    }
}

/// Audio-only routing: AirPlay receivers get the rendered audio, never the item URL, which they cannot fetch
/// for `file://` copies, device-bound signed URLs or Opus-in-MP4.
enum PlaybackAudioRoute {
    struct SessionConfiguration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let policy: AVAudioSession.RouteSharingPolicy
        let options: AVAudioSession.CategoryOptions

        func apply(to session: AVAudioSession) throws {
            try session.setCategory(category, mode: mode, policy: policy, options: options)
        }
    }

    /// Long-form audio rejects mixing options, so `options` must stay empty while `policy` is `.longFormAudio`.
    static var session: SessionConfiguration {
        SessionConfiguration(category: .playback, mode: .default, policy: .longFormAudio, options: [])
    }

    enum Kind: String, CaseIterable {
        case airplay, bluetooth, car, builtin, other
    }

    /// Every app player comes from here; a default AVPlayer would hand its URL to an Apple TV instead.
    @MainActor
    static func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.allowsExternalPlayback = false
        return player
    }

    /// The most specific output wins when a route has several, so AirPlay beside the speaker reports airplay.
    static func kind(for outputs: [AVAudioSession.Port]) -> Kind {
        let kinds = Set(outputs.map(kind(for:)))
        return [Kind.airplay, .car, .bluetooth, .builtin].first(where: kinds.contains) ?? .other
    }

    static func kind(for port: AVAudioSession.Port) -> Kind {
        switch port {
        case .airPlay: .airplay
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
        case .carAudio: .car
        case .builtInSpeaker, .builtInReceiver: .builtin
        default: .other
        }
    }
}
