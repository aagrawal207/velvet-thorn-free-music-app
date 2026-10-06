import Foundation
import Observation

extension MusicAppModel {
    func installLyricsSelection() {
        lyricsSelection.onSelectionChanged = { [weak self] track, document in
            guard let self, self.selectedLyricsTrack == track,
                  self.player.currentTrack?.id == track.id,
                  let token = self.selectedLyricsToken, let document else { return }
            let variant = self.lyricsSelection.variants.first { $0.id == document.selectionID }
            self.tvLyrics.select(document, token: token,
                label: variant?.title(recordingLanguage: self.lyricsSelection.recordingLanguage))
        }
        observeLyricsTrack()
    }

    func loadSelectedLyrics(for track: Track, recordingLanguage: String? = nil) {
        guard player.currentTrack?.id == track.id else { return }
        lyricsSelectionTask?.cancel()
        selectedLyricsTrack = track
        let token = tvLyrics.beginSelection(for: track.id)
        selectedLyricsToken = token
        let correction = library.recordingLanguageOverrides[track.id]
        lyricsSelectionTask = Task { [weak self] in
            guard let self else { return }
            var language = correction ?? recordingLanguage
            if language == nil { language = try? await self.lyricLanguageLookup?(track) }
            guard !Task.isCancelled, self.selectedLyricsToken == token,
                  self.player.currentTrack?.id == track.id else { return }
            guard correction == self.library.recordingLanguageOverrides[track.id] else {
                self.loadSelectedLyrics(for: track)
                return
            }
            await self.lyricsSelection.load(for: track, using: self.lyrics, recordingLanguage: language)
        }
    }

    func prepareTVLyrics() {
        guard let track = player.currentTrack else { return }
        if let document = lyricsSelection.selectedDocument, document.trackID == track.id,
           let token = tvLyrics.beginSelection(for: track.id) {
            selectedLyricsToken = token
            let variant = lyricsSelection.variants.first { $0.id == document.selectionID }
            tvLyrics.select(document, token: token,
                label: variant?.title(recordingLanguage: lyricsSelection.recordingLanguage))
        } else {
            loadSelectedLyrics(for: track)
        }
    }

    func clearSelectedLyrics(reason: TVLyricsController.StopReason) {
        lyricsSelectionTask?.cancel()
        lyricsSelectionTask = nil
        selectedLyricsToken = nil
        selectedLyricsTrack = nil
        lyricsSelection.clear()
        tvLyrics.stop(reason: reason)
    }

    func stopTVLyricsForSignOut() { clearSelectedLyrics(reason: .signOut) }

    private func observeLyricsTrack() {
        let previous = player.currentTrack?.id
        let correction = previous.flatMap { library.recordingLanguageOverrides[$0] }
        withObservationTracking {
            _ = player.currentTrack?.id
            _ = library.recordingLanguageOverrides
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = self.player.currentTrack?.id
                let currentCorrection = current.flatMap { self.library.recordingLanguageOverrides[$0] }
                if current != previous || currentCorrection != correction {
                    let reloadCorrection = current == previous && self.selectedLyricsTrack != nil
                    self.lyricsSelectionTask?.cancel()
                    self.selectedLyricsToken = nil
                    self.selectedLyricsTrack = nil
                    self.lyricsSelection.clear()
                    self.tvLyrics.synchronizeTrack()
                    if self.tvLyrics.isEnabled || reloadCorrection, let track = self.player.currentTrack {
                        self.loadSelectedLyrics(for: track)
                    }
                }
                self.observeLyricsTrack()
            }
        }
    }
}
