import Foundation

enum LibrarySyncMerge {
    static func joined(_ lhs: LibrarySyncState, _ rhs: LibrarySyncState) throws -> LibrarySyncState {
        guard lhs.version <= LibrarySyncState.currentVersion, rhs.version <= LibrarySyncState.currentVersion else {
            throw LibrarySyncError.newerVersion
        }
        guard lhs.version == LibrarySyncState.currentVersion, rhs.version == LibrarySyncState.currentVersion else {
            throw LibrarySyncError.unsupportedVersion
        }
        var lhs = lhs
        var rhs = rhs
        try LibraryLifetimeSync.migrateLegacy(&lhs)
        try LibraryLifetimeSync.migrateLegacy(&rhs)
        var result = lhs
        result.clock = latest(lhs.clock, rhs.clock)
        result.historyReset = latest(lhs.historyReset, rhs.historyReset)
        result.historyRetirement = latest(lhs.historyRetirement, rhs.historyRetirement)
        result.searchReset = latest(lhs.searchReset, rhs.searchReset)
        if lhs.searchReset == rhs.searchReset {
            result.searchFloor = latest(lhs.searchFloor, rhs.searchFloor)
            result.searchSelectionFloor = latest(lhs.searchSelectionFloor, rhs.searchSelectionFloor)
        } else {
            result.searchFloor = result.searchReset == lhs.searchReset ? lhs.searchFloor : rhs.searchFloor
            result.searchSelectionFloor = result.searchReset == lhs.searchReset ? lhs.searchSelectionFloor : rhs.searchSelectionFloor
        }
        for (key, incoming) in rhs.registers {
            if let existing = result.registers[key] {
                result.registers[key] = try joinRegister(existing, incoming, key: key)
            } else {
                result.registers[key] = incoming
            }
        }
        discardObsoleteGenerations(&result)
        guard result.registers.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        return result
    }

    static func latest<Value: Comparable>(_ lhs: Value?, _ rhs: Value?) -> Value? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        case (.some, .none): lhs
        case (.none, _): rhs
        }
    }

    static func discardObsoleteGenerations(_ state: inout LibrarySyncState) {
        let deletedPlaylists = Set(state.registers.compactMap { key, value in
            key.collection == .playlist && value.value == nil ? key.id : nil
        })
        state.registers = state.registers.filter { key, register in
            if key.collection.isHistory { return register.generation == state.historyReset }
            if key.collection.isSearchHistory {
                let rank = LibrarySyncSearchBoundary(revision: register.revision, key: key.id)
                let floor = key.collection == .search ? state.searchFloor : state.searchSelectionFloor
                return register.generation == state.searchReset && (floor.map { rank > $0 } ?? true)
            }
            return !key.collection.isPlaylistChild || !deletedPlaylists.contains(key.id)
        }
    }

    static func compact(_ state: inout LibrarySyncState, retaining document: LibraryDocument) {
        discardObsoleteGenerations(&state)
        compactHistory(&state, retaining: document)
        let releases = Set(document.releases.map(\.id))
        for (key, stored) in state.registers where key.collection == .release && !releases.contains(key.id) && stored.value != nil {
            var register = stored
            register.value = nil
            state.registers[key] = register
        }
        compactSearches(.search, floor: \.searchFloor, in: &state)
        compactSearches(.searchSelection, floor: \.searchSelectionFloor, in: &state)
    }

    private static func compactSearches(_ collection: LibrarySyncCollection,
                                        floor: WritableKeyPath<LibrarySyncState, LibrarySyncSearchBoundary?>,
                                        in state: inout LibrarySyncState) {
        let searches = LibrarySyncProjection.entries(collection, in: state).filter { $0.1.value != nil }
        if searches.count > SearchHistory.limit {
            let (key, register) = searches[SearchHistory.limit]
            state[keyPath: floor] = latest(state[keyPath: floor], LibrarySyncSearchBoundary(revision: register.revision, key: key.id))
            discardObsoleteGenerations(&state)
        }
        let searchMutations = LibrarySyncProjection.entries(collection, in: state)
        if searchMutations.count > SearchHistory.limit * 2 {
            let oldestLive = searchMutations.last(where: { $0.1.value != nil }).map {
                LibrarySyncSearchBoundary(revision: $0.1.revision, key: $0.0.id)
            }
            // A live entry can outlive arbitrarily many removals; its newer tombstones must then remain too.
            if let (key, register) = searchMutations.dropFirst(SearchHistory.limit * 2).first(where: { key, register in
                let rank = LibrarySyncSearchBoundary(revision: register.revision, key: key.id)
                return oldestLive.map { rank < $0 } ?? true
            }) {
                state[keyPath: floor] = latest(state[keyPath: floor], LibrarySyncSearchBoundary(revision: register.revision, key: key.id))
                discardObsoleteGenerations(&state)
            }
        }
    }

    static func compactHistory(_ state: inout LibrarySyncState, retaining document: LibraryDocument) {
        let events = Set(document.events.map { $0.id.uuidString })
        let recents = Set(document.recentlyPlayed.map(\.id))
        state.registers = state.registers.filter { key, _ in
            if key.collection == .event { return events.contains(key.id) }
            if key.collection == .recent { return recents.contains(key.id) }
            return true
        }
    }

    static func joinRegister(_ lhs: LibrarySyncRegister, _ rhs: LibrarySyncRegister,
                             key: LibrarySyncKey) throws -> LibrarySyncRegister {
        if lhs == rhs { return lhs }
        if key.collection == .event, let left = lhs.value, let right = rhs.value {
            let a = try LibrarySyncCodec.decode(ListeningEvent.self, from: left)
            let b = try LibrarySyncCodec.decode(ListeningEvent.self, from: right)
            guard a.id == b.id, a.track.id == b.track.id, a.startedAt == b.startedAt else {
                throw LibrarySyncError.invalidData("conflicting listening session identity")
            }
        }
        if lhs.generation != rhs.generation {
            return latest(lhs.generation, rhs.generation) == lhs.generation ? lhs : rhs
        }
        if key.collection == .playlist, lhs.value == nil || rhs.value == nil {
            // Playlist IDs are never reused. An offline rename or track insertion cannot undo deletion.
            if lhs.value != nil { return rhs }
            if rhs.value != nil { return lhs }
        }
        var winner = try preferred(lhs, rhs, collection: key.collection)
        if let left = lhs.value, let right = rhs.value {
            switch key.collection {
            case .lifetimeSession:
                let a = try LibrarySyncCodec.decode(LifetimeListeningContribution.self, from: left)
                let b = try LibrarySyncCodec.decode(LifetimeListeningContribution.self, from: right)
                winner.value = try LibrarySyncCodec.encode(a.joined(b))
            case .event:
                var event = try LibrarySyncCodec.decode(ListeningEvent.self, from: winner.value!)
                event.listenedSeconds = max(try LibrarySyncCodec.decode(ListeningEvent.self, from: left).listenedSeconds,
                                            try LibrarySyncCodec.decode(ListeningEvent.self, from: right).listenedSeconds)
                winner.value = try LibrarySyncCodec.encode(event)
            case .followMetadata:
                let a = try LibrarySyncCodec.decode(FollowedArtist.self, from: left)
                let b = try LibrarySyncCodec.decode(FollowedArtist.self, from: right)
                var artist = try LibrarySyncCodec.decode(FollowedArtist.self, from: winner.value!)
                artist.knownReleaseIDs = Set(a.knownReleaseIDs + b.knownReleaseIDs).sorted()
                artist.hasEstablishedReleaseBaseline = a.hasEstablishedReleaseBaseline || b.hasEstablishedReleaseBaseline
                artist.lastCheckedAt = [a.lastCheckedAt, b.lastCheckedAt].compactMap { $0 }.max()
                winner.value = try LibrarySyncCodec.encode(artist)
            case .playlistUpdated:
                winner.value = try LibrarySyncCodec.encode(max(try LibrarySyncCodec.decode(Date.self, from: left),
                                                               try LibrarySyncCodec.decode(Date.self, from: right)))
            case .releaseSeen:
                let seenLeft = try LibrarySyncCodec.decode(Bool.self, from: left)
                let seenRight = try LibrarySyncCodec.decode(Bool.self, from: right)
                winner.value = try LibrarySyncCodec.encode(seenLeft || seenRight)
            default: break
            }
        }
        return winner
    }

    private static func preferred(_ lhs: LibrarySyncRegister, _ rhs: LibrarySyncRegister,
                                  collection: LibrarySyncCollection) throws -> LibrarySyncRegister {
        if lhs.revision != rhs.revision { return lhs.revision > rhs.revision ? lhs : rhs }
        if lhs.value == nil { return lhs }
        if rhs.value == nil { return rhs }
        let a = try comparisonPayload(lhs.value!, collection: collection)
        let b = try comparisonPayload(rhs.value!, collection: collection)
        return a.lexicographicallyPrecedes(b) ? rhs : lhs
    }

    private static func comparisonPayload(_ data: Data, collection: LibrarySyncCollection) throws -> Data {
        switch collection {
        case .event:
            var event = try LibrarySyncCodec.decode(ListeningEvent.self, from: data)
            event.listenedSeconds = 1
            return try LibrarySyncCodec.encode(event)
        case .followMetadata:
            return try LibrarySyncCodec.encode(LibrarySyncProjection.followIdentity(LibrarySyncCodec.decode(FollowedArtist.self, from: data)))
        default: return data
        }
    }
}
