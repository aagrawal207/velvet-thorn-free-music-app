import Foundation

struct PlaybackQueue {
    struct Entry: Identifiable {
        let id: UUID
        let track: Track
    }

    private(set) var entries: [Entry] = []
    private(set) var original: [Entry] = []
    private(set) var selectedID: UUID?
    private(set) var shuffled = false

    var tracks: [Track] { entries.map(\.track) }
    var index: Int { entries.firstIndex { $0.id == selectedID } ?? 0 }
    var current: Track? { entries.first { $0.id == selectedID }?.track }

    mutating func replace(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        entries = tracks.map { Entry(id: UUID(), track: $0) }
        original = entries
        selectedID = entries.isEmpty ? nil : entries[min(max(0, index), entries.count - 1)].id
        self.shuffled = false
        if shuffled { toggleShuffle() }
    }

    mutating func restore(_ snapshot: PlaybackSnapshot) {
        replace(snapshot.queue, startingAt: snapshot.currentIndex)
        // A persisted shuffled queue is already in playback order; shuffling again changes its continuation.
        shuffled = snapshot.shuffleEnabled
        guard shuffled, let savedOrder = snapshot.originalQueue, savedOrder.count == entries.count else { return }
        var remaining = Dictionary(grouping: entries.reversed(), by: { $0.track.id })
        var restoredOrder: [Entry] = []
        for track in savedOrder {
            guard var matches = remaining[track.id], !matches.isEmpty else { return }
            let index = matches.lastIndex { $0.track == track } ?? matches.count - 1
            restoredOrder.append(matches.remove(at: index))
            remaining[track.id] = matches
        }
        guard remaining.values.allSatisfy(\.isEmpty) else { return }
        // Reuse live queue entries: duplicate occurrences keep distinct identities and stale metadata cannot replace them.
        original = restoredOrder
    }

    func snapshot(position: TimeInterval, repeatMode: RepeatMode) -> PlaybackSnapshot {
        PlaybackSnapshot(queue: tracks, currentIndex: index, position: PlaybackTiming.position(position),
                         shuffleEnabled: shuffled, repeatMode: repeatMode, originalQueue: original.map(\.track))
    }

    mutating func toggleShuffle() {
        if shuffled {
            entries = original
        } else {
            original = entries
            let current = entries.first { $0.id == selectedID }
            entries = current.map { [$0] } ?? []
            entries += original.filter { $0.id != selectedID }.shuffled()
        }
        shuffled.toggle()
    }

    mutating func enqueue(_ track: Track, next: Bool) {
        let entry = Entry(id: UUID(), track: track)
        let insertion = next && !entries.isEmpty ? index + 1 : entries.count
        entries.insert(entry, at: insertion)
        let originalIndex = original.firstIndex { $0.id == selectedID }
        original.insert(entry, at: next ? originalIndex.map { $0 + 1 } ?? original.count : original.count)
        if selectedID == nil { selectedID = entry.id }
    }

    mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        original.removeAll { $0.id == removed.id }
        if removed.id == selectedID {
            selectedID = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
        }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let indexes = offsets.filter { entries.indices.contains($0) }
        guard !indexes.isEmpty else { return }
        let moving = indexes.map { entries[$0] }
        let destination = min(max(0, destination), entries.count)
        let insertion = destination - indexes.filter { $0 < destination }.count
        for index in indexes.reversed() { entries.remove(at: index) }
        entries.insert(contentsOf: moving, at: insertion)
        if shuffled {
            let ids = Set(moving.map(\.id))
            original.removeAll { ids.contains($0.id) }
            let successor = entries.dropFirst(insertion + moving.count).first?.id
            let anchor = original.firstIndex { $0.id == successor } ?? original.count
            original.insert(contentsOf: moving, at: anchor)
        } else {
            original = entries
        }
    }

    @discardableResult
    mutating func advance(repeatMode: RepeatMode, automatic: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        if automatic && repeatMode == .one { return true }
        if index + 1 < entries.count {
            selectedID = entries[index + 1].id
            return true
        }
        if repeatMode == .all {
            selectedID = entries[0].id
            return true
        }
        return false
    }

    mutating func previous(repeatMode: RepeatMode) {
        guard !entries.isEmpty else { return }
        let previous = index > 0 ? index - 1 : (repeatMode == .all ? entries.count - 1 : 0)
        selectedID = entries[previous].id
    }
}
