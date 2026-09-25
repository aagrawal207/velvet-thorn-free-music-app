import Foundation

struct LibraryTrackSearch {
    let tracks: [Track]
    let isFiltering: Bool
    private let sourceTrackIDs: [String]

    init(tracks: [Track], query: String) {
        let tokens = SearchRelevance.normalize(query).split(separator: " ")
        isFiltering = !tokens.isEmpty
        sourceTrackIDs = tracks.map(\.id)
        // Filtering keeps library order and recording occurrences; catalog ranking can retain unrelated songs.
        self.tracks = tokens.isEmpty ? tracks : tracks.filter { track in
            let text = ([track.title] + track.artists + [track.albumTitle ?? ""])
                .map(SearchRelevance.normalize).joined(separator: " ")
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    func removalIDs(at offsets: IndexSet) -> [String] {
        var seen = Set<String>()
        // LibraryStore removes by recording ID, so visible offsets must be resolved before a write.
        return offsets.compactMap { tracks.indices.contains($0) ? tracks[$0].id : nil }
            .filter { seen.insert($0).inserted }
    }

    func canReorder(currentTracks: [Track]) -> Bool {
        // A sync or another edit can invalidate even an unfiltered drag's source offsets.
        !isFiltering && !tracks.isEmpty && sourceTrackIDs == currentTracks.map(\.id)
    }
}
