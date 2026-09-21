import Foundation
import Observation

@MainActor @Observable
final class LyricsLoader {
    enum State {
        case loading
        case loaded(LyricsDocument)
        case failed(String)
    }

    private(set) var track: Track?
    private(set) var state: State = .loading
    private var generation: UInt64 = 0

    func load(for track: Track, using provider: any LyricsProviding) async {
        generation &+= 1
        let requestGeneration = generation
        self.track = track
        state = .loading
        do {
            let document = try await provider.lyrics(for: track)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            guard document.trackID == track.id else { throw MusicServiceError.invalidResponse }
            state = .loaded(document)
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
