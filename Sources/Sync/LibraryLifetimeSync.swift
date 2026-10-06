import Foundation

enum LibraryLifetimeSync {
    static func migrateLegacy(_ state: inout LibrarySyncState) throws {
        for (key, register) in state.registers where key.collection == .event && register.generation == state.historyReset {
            guard let data = register.value else { continue }
            let event = try LibrarySyncCodec.decode(ListeningEvent.self, from: data)
            let receiptKey = LibrarySyncKey(.lifetimeSession, key.id)
            let receipt = LibrarySyncRegister(revision: register.revision,
                value: try LibrarySyncCodec.encode(LifetimeListeningContribution(event)), generation: register.generation)
            if let existing = state.registers[receiptKey] {
                state.registers[receiptKey] = try LibrarySyncMerge.joinRegister(existing, receipt, key: receiptKey)
            } else { state.registers[receiptKey] = receipt }
        }
    }

    static func project(_ rollup: LifetimeListeningRollup) throws -> [LibrarySyncKey: Data] {
        var values: [LibrarySyncKey: Data] = [:]
        for (id, receipt) in rollup.sessions { values[LibrarySyncKey(.lifetimeSession, id)] = try LibrarySyncCodec.encode(receipt) }
        return values
    }

    static func materialize(_ state: LibrarySyncState) throws -> LifetimeListeningRollup {
        var result = LifetimeListeningRollup()
        for (key, register) in state.registers where register.generation == state.historyReset {
            guard let data = register.value else { continue }
            if key.collection == .lifetimeSession {
                result.sessions[key.id] = try LibrarySyncCodec.decode(LifetimeListeningContribution.self, from: data)
            }
        }
        try result.validate()
        return result
    }

    static func record(previous: LifetimeListeningRollup, candidate: LifetimeListeningRollup,
                       sessionIDs: Set<String>, state: inout LibrarySyncState, now: Date, writer: UUID) throws {
        for id in sessionIDs.sorted() {
            let key = LibrarySyncKey(.lifetimeSession, id)
            guard let receipt = candidate.sessions[id] else { continue }
            guard previous.sessions[id] != candidate.sessions[id] || state.registers[key] == nil else { continue }
            let revision = try state.nextRevision(now: now, writer: writer)
            state.put(key, value: try LibrarySyncCodec.encode(receipt), revision: revision)
        }
    }
}
