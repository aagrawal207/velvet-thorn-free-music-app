import Foundation
import Observation

@MainActor @Observable
final class RadioSearchModel {
    var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespacesAndNewlines)
                != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) { invalidate() }
        }
    }
    var filter: SearchFilter = .songs { didSet { if filter != oldValue { invalidate() } } }
    private(set) var songs: [Track] = []
    private(set) var artists: [MusicCollection] = []
    private(set) var isLoading = false
    private(set) var hasSearched = false
    private(set) var errorMessage: String?
    private(set) var attempt = 0
    @ObservationIgnored private var generation = UUID()

    struct Request: Hashable {
        let query: String
        let filter: SearchFilter
        let isOffline: Bool
        let attempt: Int
    }

    func request(isOffline: Bool) -> Request {
        Request(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                filter: filter, isOffline: isOffline, attempt: attempt)
    }

    func retry() {
        invalidate()
        attempt += 1
    }

    func cancel() { invalidate() }

    func load(_ request: Request, catalog: any MusicCatalogProviding, isOffline: () -> Bool) async {
        guard !Task.isCancelled, request == self.request(isOffline: request.isOffline) else { return }
        invalidate()
        guard !request.query.isEmpty, !request.isOffline, !isOffline(),
              request.filter == .songs || request.filter == .artists else { return }
        let token = generation
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            try await Task.sleep(for: .milliseconds(320))
            try Task.checkCancellation()
            guard generation == token, !isOffline() else { return }
            let page = try await CompositeCatalog.searchingAllSources {
                try await catalog.search(query: request.query, filter: request.filter, continuation: nil)
            }
            try Task.checkCancellation()
            guard generation == token, !isOffline() else { return }
            var ids = Set<String>()
            if request.filter == .songs {
                songs = Array(page.tracks.filter {
                    $0.isAudioRecording == true && RadioSeed.song($0).isValid && ids.insert($0.id).inserted
                }.prefix(30))
            } else {
                let candidates = page.featuredArtist.map { [$0] } ?? []
                artists = Array((candidates + page.collections).filter {
                    $0.kind == .artist && ids.insert($0.id).inserted
                }.prefix(30))
            }
            hasSearched = true
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            errorMessage = error.localizedDescription
            hasSearched = true
        }
    }

    private func invalidate() {
        // Invalidate synchronously on edits, before SwiftUI schedules the replacement task.
        generation = UUID()
        songs = []
        artists = []
        isLoading = false
        hasSearched = false
        errorMessage = nil
    }
}
