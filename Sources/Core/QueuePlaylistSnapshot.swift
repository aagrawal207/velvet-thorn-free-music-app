struct QueuePlaylistSnapshot: Sendable {
    let tracks: [Track]

    init(queue: [Track], currentIndex: Int) {
        guard queue.indices.contains(currentIndex) else {
            tracks = []
            return
        }
        var seen = Set<String>()
        // Earlier occurrences must not replace the selected recording's metadata or exclude its remaining copy.
        tracks = queue[currentIndex...].filter { seen.insert($0.id).inserted }
    }
}
