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
    // Legacy checkpoints retain the absent field until occurrence order or selection actually changes.
    private var persistsOccurrenceMapping = false

    var tracks: [Track] { entries.map(\.track) }
    var index: Int { entries.firstIndex { $0.id == selectedID } ?? 0 }
    var current: Track? { entries.first { $0.id == selectedID }?.track }

    mutating func replace(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false,
                         using shuffle: ([Entry]) -> [Entry] = { $0.shuffled() }) {
        entries = tracks.map { Entry(id: UUID(), track: $0) }
        original = entries
        selectedID = entries.isEmpty ? nil : entries[min(max(0, index), entries.count - 1)].id
        persistsOccurrenceMapping = true
        self.shuffled = false
        if shuffled { toggleShuffle(using: shuffle) }
    }

    mutating func replaceShuffled(_ tracks: [Track], using shuffle: ([Entry]) -> [Entry] = { $0.shuffled() }) {
        replace(tracks)
        // The first occurrence is sampled with the tail; the source order remains available for unshuffle.
        entries = shuffle(entries)
        selectedID = entries.first?.id
        shuffled = true
    }

    mutating func restore(_ snapshot: PlaybackSnapshot) {
        replace(snapshot.queue, startingAt: snapshot.currentIndex)
        persistsOccurrenceMapping = snapshot.originalQueueIndices != nil
        // A persisted shuffled queue is already in playback order; shuffling again changes its continuation.
        shuffled = snapshot.shuffleEnabled
        if let indices = snapshot.originalQueueIndices {
            guard (try? LibraryValidation.validateOriginalQueueIndices(snapshot)) != nil else { return }
            var restoredOrder = entries
            for (queueIndex, originalIndex) in indices.enumerated() {
                restoredOrder[originalIndex] = entries[queueIndex]
            }
            original = restoredOrder
            return
        }
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
        var snapshot = PlaybackSnapshot(queue: tracks, currentIndex: index, position: PlaybackTiming.position(position),
                                        shuffleEnabled: shuffled, repeatMode: repeatMode, originalQueue: original.map(\.track))
        guard persistsOccurrenceMapping else { return snapshot }
        var originalIndices: [UUID: Int] = [:]
        for (index, entry) in original.enumerated() { originalIndices[entry.id] = index }
        // Missing occurrence identity must fail validation rather than save a guessed original position.
        snapshot.originalQueueIndices = entries.map { originalIndices[$0.id] ?? -1 }
        return snapshot
    }

    mutating func toggleShuffle(using shuffle: ([Entry]) -> [Entry] = { $0.shuffled() }) {
        if shuffled {
            entries = original
        } else {
            original = entries
            let current = entries.first { $0.id == selectedID }
            entries = current.map { [$0] } ?? []
            entries += shuffle(original.filter { $0.id != selectedID })
        }
        shuffled.toggle()
        persistsOccurrenceMapping = true
    }

    @discardableResult
    mutating func enqueue(_ track: Track, next: Bool) -> UUID {
        let entry = Entry(id: UUID(), track: track)
        let insertion = next && !entries.isEmpty ? index + 1 : entries.count
        entries.insert(entry, at: insertion)
        let originalIndex = original.firstIndex { $0.id == selectedID }
        original.insert(entry, at: next ? originalIndex.map { $0 + 1 } ?? original.count : original.count)
        if selectedID == nil { selectedID = entry.id }
        persistsOccurrenceMapping = true
        return entry.id
    }

    @discardableResult
    mutating func select(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let id = entries[index].id
        if selectedID != id { persistsOccurrenceMapping = true }
        selectedID = id
        return true
    }

    /// Housekeeping cannot remove the selected occurrence or its upcoming entries.
    @discardableResult
    mutating func removePreviousEntries(withIDs ids: Set<UUID>) -> [Entry] {
        let indices = entries.indices.prefix(index).filter { ids.contains(entries[$0].id) }
        let removed = indices.map { entries[$0] }
        for index in indices.reversed() { remove(at: index) }
        return removed
    }

    mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        original.removeAll { $0.id == removed.id }
        if removed.id == selectedID {
            selectedID = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
        }
        persistsOccurrenceMapping = true
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let indexes = offsets.filter { entries.indices.contains($0) }
        guard !indexes.isEmpty else { return }
        let previousEntries = entries.map(\.id)
        let previousOriginal = original.map(\.id)
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
        if entries.map(\.id) != previousEntries || original.map(\.id) != previousOriginal {
            persistsOccurrenceMapping = true
        }
    }

    @discardableResult
    mutating func advance(repeatMode: RepeatMode, automatic: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        if automatic && repeatMode == .one { return true }
        if index + 1 < entries.count {
            let nextID = entries[index + 1].id
            if selectedID != nextID { persistsOccurrenceMapping = true }
            selectedID = nextID
            return true
        }
        if repeatMode == .all {
            let nextID = entries[0].id
            if selectedID != nextID { persistsOccurrenceMapping = true }
            selectedID = nextID
            return true
        }
        return false
    }

    mutating func previous(repeatMode: RepeatMode) {
        guard !entries.isEmpty else { return }
        let previous = index > 0 ? index - 1 : (repeatMode == .all ? entries.count - 1 : 0)
        let previousID = entries[previous].id
        if selectedID != previousID { persistsOccurrenceMapping = true }
        selectedID = previousID
    }
}
