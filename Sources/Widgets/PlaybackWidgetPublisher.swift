import Foundation
import Observation
import OSLog
import WidgetKit

/// Mirrors the playback selection into the App Group for Lock Screen widgets and Controls.
/// It publishes only selection, play state, display text and accent, never positions, so ticks cause no writes.
@MainActor
final class PlaybackWidgetPublisher {
    private weak var player: PlayerController?
    private weak var library: LibraryStore?
    private let store: WidgetPlaybackStateStore
    private let delay: Duration
    private let reload: @MainActor () -> Void
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Widgets")
    private var pending: Task<Void, Never>?
    private var published: WidgetPlaybackState?
    private(set) var reloadCount = 0

    init(player: PlayerController, library: LibraryStore, store: WidgetPlaybackStateStore = WidgetPlaybackStateStore(),
         delay: Duration = .milliseconds(300), reload: @escaping @MainActor () -> Void) {
        self.player = player
        self.library = library
        self.store = store
        self.delay = delay
        self.reload = reload
        observe()
        publish()
    }

    static func reloadSystemSurfaces() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetPlaybackState.nowPlayingWidgetKind)
        ControlCenter.shared.reloadControls(ofKind: WidgetPlaybackState.playPauseControlKind)
    }

    func state() -> WidgetPlaybackState {
        guard let player else { return .empty }
        let accent = library?.preferences.accent ?? .coral
        // Opening the app or a background resume can briefly report a selection before the library loads.
        let history = library.map { $0.hasLoadedDocument && $0.preferences.saveListeningHistory } ?? false
        let active = player.isPlaying || player.isLoading
        if let station = player.liveStation {
            return WidgetPlaybackState(hasSelection: true, isPlaying: active, isLiveRadio: true,
                                       title: history ? WidgetPlaybackState.bounded(station.name) : nil,
                                       subtitle: history ? "Live radio" : nil, accent: accent)
        }
        guard let track = player.currentTrack else { return WidgetPlaybackState(hasSelection: false, isPlaying: false, accent: accent) }
        return WidgetPlaybackState(hasSelection: true, isPlaying: active,
                                   title: history ? WidgetPlaybackState.bounded(track.title) : nil,
                                   subtitle: history ? WidgetPlaybackState.bounded(track.artistName) : nil, accent: accent)
    }

    func publish() {
        pending?.cancel()
        pending = nil
        let next = state()
        guard next != published else { return }
        do {
            let changed = try store.write(next)
            published = next
            if changed {
                reloadCount += 1
                reload()
            }
            log.info("event=widget_playback_state success=1 changed=\(changed ? 1 : 0) selection=\(next.hasSelection ? 1 : 0) playing=\(next.isPlaying ? 1 : 0) radio=\(next.isLiveRadio ? 1 : 0) titled=\(next.title == nil ? 0 : 1)")
        } catch {
            log.error("event=widget_playback_state success=0 changed=0 selection=\(next.hasSelection ? 1 : 0) playing=\(next.isPlaying ? 1 : 0) radio=\(next.isLiveRadio ? 1 : 0) titled=\(next.title == nil ? 0 : 1)")
        }
    }

    private func observe() {
        withObservationTracking {
            _ = state()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.schedule()
                self?.observe()
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        let delay = delay
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }
}

@MainActor
extension MusicAppModel {
    /// Lock Screen, Control Center and Shortcuts requests. Cold launches arrive after `init` restored the paused queue.
    @discardableResult
    func performPlaybackIntent(_ command: PlaybackIntentCommand) -> PlaybackIntentOutcome {
        let outcome: PlaybackIntentOutcome
        if !library.hasLoadedDocument || !library.preferences.hasCompletedWelcome {
            outcome = .unavailable
        } else {
            switch command {
            case .toggle:
                outcome = (player.isPlaying || player.isLoading) ? pauseFromIntent() : playFromIntent()
            case .play:
                outcome = (player.isPlaying || player.isLoading) ? .unchanged : playFromIntent()
            case .pause:
                outcome = (player.isPlaying || player.isLoading) ? pauseFromIntent() : .unchanged
            case .openPlayer:
                cancelPendingArtistLookup()
                isSettingsPresented = false
                if player.hasPlaybackSelection {
                    dismissSearchKeyboard()
                    isPlayerPresented = true
                    outcome = .success
                } else {
                    outcome = .noSelection
                }
            }
        }
        Logger(subsystem: "com.agraabhi.ganabajana", category: "Widgets")
            .info("event=playback_intent action=\(command.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
        return outcome
    }

    private func playFromIntent() -> PlaybackIntentOutcome {
        guard player.hasPlaybackSelection else { return .noSelection }
        cancelPendingRadio()
        player.resumePlayback()
        return .success
    }

    private func pauseFromIntent() -> PlaybackIntentOutcome {
        cancelPendingRadio()
        player.pause()
        return .success
    }
}
