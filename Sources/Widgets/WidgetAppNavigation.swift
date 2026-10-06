import Foundation
import OSLog

@MainActor
extension MusicAppModel {
    @discardableResult
    func handleWidgetURL(_ url: URL) -> Bool {
        guard let route = MusicWidgetRoute(url: url) else {
            recordWidgetOpen(nil, outcome: .invalid)
            return false
        }
        cancelPendingArtistLookup()
        guard widgetLibraryIsReady(for: route) else { return true }
        if route.startsPlayback, isOffline {
            cancelPendingRadio()
            let controls = player.controlRevision
            widgetOpenTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshCachedSongs()
                guard !Task.isCancelled else {
                    self.recordWidgetOpen(route, outcome: .cancelled)
                    return
                }
                self.widgetOpenTask = nil
                guard self.player.controlRevision == controls else {
                    self.recordWidgetOpen(route, outcome: .cancelled)
                    return
                }
                guard !self.isOffline || (self.hasLoadedCachedSongs && self.cachedSongsUsage != nil && self.cachedSongsError == nil) else {
                    self.showToast("Cached songs couldn’t be checked. Open Storage to try again.")
                    self.recordWidgetOpen(route, outcome: .offline)
                    return
                }
                self.performWidgetRoute(route)
            }
        } else {
            performWidgetRoute(route)
        }
        return true
    }

    private func performWidgetRoute(_ route: MusicWidgetRoute) {
        guard widgetLibraryIsReady(for: route) else { return }

        let outcome: WidgetOpenOutcome
        switch route {
        case .open(let kind):
            openWidgetCollection(kind)
            outcome = .success
        case .playTrack(let source, let id):
            outcome = playWidgetTrack(id: id, source: source)
        case .mix(let kind, let periodKey, let play):
            outcome = openWidgetMix(kind, periodKey: periodKey, startsPlayback: play)
        }
        recordWidgetOpen(route, outcome: outcome)
    }

    private func widgetLibraryIsReady(for route: MusicWidgetRoute) -> Bool {
        guard library.validateWidgetLibrarySource(), library.hasLoadedDocument, !library.requiresReload else {
            openLibrary()
            showToast("Your saved library needs attention. Reload it before opening this widget’s music.")
            recordWidgetOpen(route, outcome: .unavailable)
            return false
        }
        guard library.preferences.hasCompletedWelcome else {
            recordWidgetOpen(route, outcome: .unavailable)
            return false
        }
        return true
    }

    private func openWidgetCollection(_ kind: MusicWidgetKind) {
        openLibrary()
        switch kind {
        case .recentlyPlayed: widgetLibraryDestination = .recents
        case .likedSongs: widgetLibraryDestination = .likes
        case .mixes:
            selectedTab = .home
            navigationPaths[.home] = []
        }
    }

    private func playWidgetTrack(id: String, source: MusicWidgetKind) -> WidgetOpenOutcome {
        let tracks: [Track]
        let resumePosition: TimeInterval
        switch source {
        case .recentlyPlayed:
            guard library.preferences.saveListeningHistory else {
                openWidgetCollection(source)
                showToast("Listening history is off. Recent songs stay hidden on your widget.")
                return .stale
            }
            tracks = library.recentlyPlayed.map(\.track)
            resumePosition = library.recentlyPlayed.first { $0.id == id }?.position ?? 0
        case .likedSongs:
            tracks = library.favorites
            resumePosition = 0
        case .mixes:
            return .invalid
        }
        guard let track = tracks.first(where: { $0.id == id }) else {
            openWidgetCollection(source)
            showToast("This song is no longer in that list. Choose another song in Velvet Thorn.")
            return .stale
        }
        if isOffline, !cachedPlayableTrackIDs.contains(id) {
            showToast("This song isn’t cached. Choose a cached song to keep listening offline.")
            return .offline
        }
        // An already-playing recent selection is an open-player gesture, not a queue restart.
        if source == .recentlyPlayed, player.currentTrack?.id == id {
            cancelPendingRadio()
            cancelPendingArtistLookup()
            dismissSearchKeyboard()
            isSettingsPresented = false
            if !player.isPlaying, !player.isLoading { player.resumePlayback() }
            isPlayerPresented = true
            return .success
        }
        guard play(track, in: tracks) else { return .offline }
        if source == .recentlyPlayed, resumePosition > 0 { player.seek(to: resumePosition) }
        isSettingsPresented = false
        isPlayerPresented = true
        return .success
    }

    private func openWidgetMix(_ kind: GeneratedPlaylistKind, periodKey: String, startsPlayback: Bool) -> WidgetOpenOutcome {
        guard let mix = library.mix(kind), !mix.tracks.isEmpty else {
            openWidgetCollection(.mixes)
            showToast("This saved mix is no longer available. Open Home to find your music.")
            return .stale
        }
        let matches = mix.periodKey == periodKey
        guard !startsPlayback || matches else {
            openWidgetCollection(.mixes)
            open(mix.collection)
            showToast("Your mix has refreshed. Choose Play to start the saved mix shown here.")
            return .stale
        }
        if startsPlayback {
            if isOffline, hasLoadedCachedSongs, cachedSongsUsage != nil,
               !mix.tracks.contains(where: { cachedPlayableTrackIDs.contains($0.id) }) {
                showToast("This mix has no cached songs. Choose Cached songs to keep listening offline.")
                return .offline
            }
            play(mix.tracks)
            isSettingsPresented = false
            isPlayerPresented = true
        } else {
            openWidgetCollection(.mixes)
            open(mix.collection)
        }
        return .success
    }

    private enum WidgetOpenOutcome { case success, stale, unavailable, offline, invalid, cancelled }

    private func recordWidgetOpen(_ route: MusicWidgetRoute?, outcome: WidgetOpenOutcome) {
        let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Widgets")
        let kind = route?.source.rawValue ?? "unknown"
        let play = route?.startsPlayback == true ? 1 : 0
        log.info("event=widget_open kind=\(kind, privacy: .public) play=\(play) success=\(outcome == .success ? 1 : 0) stale=\(outcome == .stale ? 1 : 0) unavailable=\(outcome == .unavailable ? 1 : 0) offline=\(outcome == .offline ? 1 : 0) invalid=\(outcome == .invalid ? 1 : 0) cancelled=\(outcome == .cancelled ? 1 : 0)")
    }
}
