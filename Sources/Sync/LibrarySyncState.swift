import Foundation

struct LibrarySyncRevision: Codable, Hashable, Comparable, Sendable {
    var milliseconds: Int64
    var counter: Int64
    var writer: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.milliseconds != rhs.milliseconds { return lhs.milliseconds < rhs.milliseconds }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.writer.uuidString < rhs.writer.uuidString
    }

    func validate() throws {
        guard (0..<253_402_300_800_000).contains(milliseconds), (0..<Int64.max).contains(counter) else {
            throw LibrarySyncError.invalidData("mutation revision")
        }
    }
}

enum LibrarySyncCollection: String, Codable, Sendable {
    case preference, reaction, playlist, playlistName, playlistUpdated, playlistTrack, playlistTrackMetadata, playlistPosition
    case follow, followMetadata, release, releaseSeen, event, recent, search, searchSelection, mix, language, lyrics

    var isHistory: Bool { self == .event || self == .recent || self == .mix }
    var isSearchHistory: Bool { self == .search || self == .searchSelection }
    var isPlaylistChild: Bool {
        self == .playlistName || self == .playlistUpdated || self == .playlistTrack || self == .playlistTrackMetadata || self == .playlistPosition
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let collection = Self(rawValue: value) else { throw LibrarySyncError.newerVersion }
        self = collection
    }
}

struct LibrarySyncKey: Codable, Hashable, Comparable, Sendable {
    var collection: LibrarySyncCollection
    var id: String
    var member: String?

    init(_ collection: LibrarySyncCollection, _ id: String, member: String? = nil) {
        self.collection = collection
        self.id = id
        self.member = member
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.collection != rhs.collection { return lhs.collection.rawValue < rhs.collection.rawValue }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return (lhs.member ?? "") < (rhs.member ?? "")
    }
}

struct LibrarySyncRegister: Codable, Equatable, Sendable {
    var revision: LibrarySyncRevision
    var value: Data?
    // A late offline mutation belongs to the reset generation it actually observed, regardless of its clock.
    var generation: LibrarySyncRevision?
}

struct LibrarySyncSearchBoundary: Codable, Equatable, Comparable, Sendable {
    var revision: LibrarySyncRevision
    var key: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        return lhs.key > rhs.key
    }
}

enum LibrarySyncReaction: Codable, Equatable, Sendable {
    case liked(Track)
    case disliked(DislikedSong)
}

struct LibrarySyncState: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = currentVersion
    var clock: LibrarySyncRevision?
    var historyReset: LibrarySyncRevision?
    var historyRetirement: LibrarySyncRevision?
    var searchReset: LibrarySyncRevision?
    var searchFloor: LibrarySyncSearchBoundary?
    var searchSelectionFloor: LibrarySyncSearchBoundary?
    var registers: [LibrarySyncKey: LibrarySyncRegister] = [:]

    init() { }

    mutating func nextRevision(now: Date, writer: UUID) throws -> LibrarySyncRevision {
        guard LibraryValidation.isValidDate(now) else { throw LibrarySyncError.invalidData("device clock") }
        let wall = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let milliseconds = max(wall, clock?.milliseconds ?? 0)
        let counter: Int64
        if let clock, clock.milliseconds == milliseconds {
            guard clock.counter < Int64.max - 1 else { throw LibrarySyncError.invalidData("exhausted mutation clock") }
            counter = clock.counter + 1
        } else {
            counter = 0
        }
        let revision = LibrarySyncRevision(milliseconds: milliseconds, counter: counter, writer: writer)
        try revision.validate()
        clock = revision
        return revision
    }

    mutating func put(_ key: LibrarySyncKey, value: Data?, revision: LibrarySyncRevision) {
        let generation = key.collection.isHistory ? historyReset : key.collection.isSearchHistory ? searchReset : nil
        registers[key] = LibrarySyncRegister(revision: revision, value: value, generation: generation)
    }

    // An entry array makes duplicate keys detectable and gives the wire format a canonical byte order.
    private struct Entry: Codable {
        var key: LibrarySyncKey
        var register: LibrarySyncRegister
    }

    private enum CodingKeys: String, CodingKey {
        case version, clock, historyReset, historyRetirement, searchReset, searchFloor, searchSelectionFloor, registers
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else { throw LibrarySyncError.newerVersion }
        guard version == 1 || version == Self.currentVersion else { throw LibrarySyncError.unsupportedVersion }
        clock = try values.decodeIfPresent(LibrarySyncRevision.self, forKey: .clock)
        historyReset = try values.decodeIfPresent(LibrarySyncRevision.self, forKey: .historyReset)
        historyRetirement = try values.decodeIfPresent(LibrarySyncRevision.self, forKey: .historyRetirement)
        searchReset = try values.decodeIfPresent(LibrarySyncRevision.self, forKey: .searchReset)
        searchFloor = try values.decodeIfPresent(LibrarySyncSearchBoundary.self, forKey: .searchFloor)
        searchSelectionFloor = try values.decodeIfPresent(LibrarySyncSearchBoundary.self, forKey: .searchSelectionFloor)
        let entries = try values.decode([Entry].self, forKey: .registers)
        guard entries.count <= LibrarySyncCodec.maximumRegisters else { throw LibrarySyncError.tooLarge }
        for entry in entries {
            guard registers.updateValue(entry.register, forKey: entry.key) == nil else {
                throw LibrarySyncError.invalidData("duplicate mutation keys")
            }
        }
        if version == 1, searchSelectionFloor != nil || registers.keys.contains(where: { $0.collection == .searchSelection }) {
            throw LibrarySyncError.invalidData("search selection format version")
        }
        // Schema migration keeps every original revision; reading a replica is not a new user edit.
        version = Self.currentVersion
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encodeIfPresent(clock, forKey: .clock)
        try values.encodeIfPresent(historyReset, forKey: .historyReset)
        try values.encodeIfPresent(historyRetirement, forKey: .historyRetirement)
        try values.encodeIfPresent(searchReset, forKey: .searchReset)
        try values.encodeIfPresent(searchFloor, forKey: .searchFloor)
        try values.encodeIfPresent(searchSelectionFloor, forKey: .searchSelectionFloor)
        try values.encode(registers.keys.sorted().map { Entry(key: $0, register: registers[$0]!) }, forKey: .registers)
    }
}

struct LibrarySyncReplica: Codable, Equatable, Sendable {
    static let currentVersion = 2
    var version = currentVersion
    var replicaID: UUID
    var state: LibrarySyncState

    private enum CodingKeys: String, CodingKey { case version, replicaID, state }
}

extension LibrarySyncReplica {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard storedVersion <= Self.currentVersion else { throw LibrarySyncError.newerVersion }
        guard storedVersion == 1 || storedVersion == Self.currentVersion else { throw LibrarySyncError.unsupportedVersion }
        replicaID = try values.decode(UUID.self, forKey: .replicaID)
        state = try values.decode(LibrarySyncState.self, forKey: .state)
        if storedVersion == 1, state.searchSelectionFloor != nil || state.registers.keys.contains(where: { $0.collection == .searchSelection }) {
            throw LibrarySyncError.invalidData("search selection replica version")
        }
        version = Self.currentVersion
    }
}

enum LibrarySyncError: LocalizedError, Equatable {
    case newerVersion, unsupportedVersion, tooLarge, unavailable, cancelled, changedDuringSync, accountChanged
    case localChangedDuringSync
    case invalidData(String)
    case localStorage(String)

    var errorDescription: String? {
        switch self {
        case .newerVersion:
            "An iCloud library uses a newer format. Update Breezy before syncing. The saved files have been kept."
        case .unsupportedVersion:
            "An iCloud library uses an unsupported format. The saved files have been kept."
        case .tooLarge:
            "The iCloud library exceeds Breezy’s safe sync size limit. No cloud files were replaced."
        case .unavailable:
            "iCloud Drive is unavailable. Check your Apple Account and iCloud Drive settings, then retry."
        case .cancelled:
            "This sync was cancelled. Your on-device library has been kept."
        case .changedDuringSync:
            "An iCloud library changed during sync. Retry to merge the latest files."
        case .accountChanged:
            "Your Apple Account changed. Turn iCloud sync on again to use this account."
        case .localChangedDuringSync:
            "Your library changed while sync was preparing. Sync again to include the latest edits."
        case .invalidData(let detail):
            "An iCloud library contains invalid \(detail). The saved files have been kept."
        case .localStorage(let detail):
            "Breezy couldn’t save the synced library on this device. \(detail)"
        }
    }
}

enum LibrarySyncCodec {
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumBatchBytes = 256 * 1024 * 1024
    static let maximumFiles = 128
    static let maximumRegisters = 200_000

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    static func encodeReplica(_ replica: LibrarySyncReplica) throws -> Data {
        let data = try encode(replica)
        guard data.count <= maximumFileBytes else { throw LibrarySyncError.tooLarge }
        return data
    }

    static func decodeReplica(_ data: Data, expectedReplicaID: UUID, now: Date) throws -> LibrarySyncReplica {
        guard data.count <= maximumFileBytes else { throw LibrarySyncError.tooLarge }
        let version = try decode(LibraryPersistence.VersionHeader.self, from: data).version
        guard version <= LibrarySyncReplica.currentVersion else { throw LibrarySyncError.newerVersion }
        guard version == 1 || version == LibrarySyncReplica.currentVersion else { throw LibrarySyncError.unsupportedVersion }
        let replica = try decode(LibrarySyncReplica.self, from: data)
        guard replica.replicaID == expectedReplicaID else { throw LibrarySyncError.invalidData("replica identity") }
        try LibrarySyncValidation.validate(replica.state, now: now)
        return replica
    }
}
