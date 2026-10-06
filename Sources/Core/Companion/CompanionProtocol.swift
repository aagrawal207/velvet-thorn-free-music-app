import Foundation

enum CompanionRepeatMode: String, Codable, Equatable, Sendable {
    case off
    case all
    case one
}

/// The phone's accent, mirrored by raw value because the watch target cannot see `AppAccent` or its palette.
enum CompanionAccent: String, CaseIterable, Codable, Equatable, Sendable {
    case coral, mint, ocean, violet, amber, rose, teal

    /// Matches the phone's default accent, so a watch that has never heard from its phone looks like an unchanged phone.
    static let fallback: CompanionAccent = .coral
}

struct CompanionExecutionLease: Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID

    init(id: UUID, sessionID: UUID) {
        self.id = id
        self.sessionID = sessionID
    }

    private enum CodingKeys: String, CodingKey { case id, sessionID }

    init(from decoder: any Decoder) throws {
        try CompanionWire.requireKeys(["id", "sessionID"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), sessionID: try values.decode(UUID.self, forKey: .sessionID))
    }
}

struct CompanionSnapshot: Codable, Equatable, Sendable {
    let sessionID: UUID
    let sequence: UInt64
    let updatedAt: Date
    let nowPlaying: CompanionNowPlaying?
    let libraryError: String?
    /// Nil when absent or unrecognised; the watch then keeps the last accent it applied.
    let accent: CompanionAccent?

    init(sessionID: UUID, sequence: UInt64, updatedAt: Date, nowPlaying: CompanionNowPlaying?, libraryError: String? = nil,
         accent: CompanionAccent? = nil) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.updatedAt = updatedAt
        self.nowPlaying = nowPlaying
        self.libraryError = libraryError.map(CompanionWire.boundedText)
        self.accent = accent
    }

    private enum CodingKeys: String, CodingKey { case sessionID, sequence, updatedAt, nowPlaying, libraryError, accent }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let date = try values.decode(Date.self, forKey: .updatedAt)
        guard date.timeIntervalSince1970.isFinite else { throw CompanionWireError.malformedRequest }
        // Cosmetic and optional: an unknown or mistyped accent must never cost the watch its playback snapshot.
        let accent = (try? values.decodeIfPresent(String.self, forKey: .accent)).flatMap(CompanionAccent.init(rawValue:))
        self.init(sessionID: try values.decode(UUID.self, forKey: .sessionID),
                  sequence: try values.decode(UInt64.self, forKey: .sequence), updatedAt: date,
                  nowPlaying: try values.decodeIfPresent(CompanionNowPlaying.self, forKey: .nowPlaying),
                  libraryError: try values.decodeIfPresent(String.self, forKey: .libraryError), accent: accent)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(nowPlaying, forKey: .nowPlaying)
        try values.encodeIfPresent(libraryError, forKey: .libraryError)
        try values.encodeIfPresent(accent, forKey: .accent)
    }
}

struct CompanionNowPlaying: Codable, Equatable, Sendable {
    let trackID: String
    let title: String
    let artist: String
    let position: Double
    let duration: Double
    let isPlaying: Bool
    let isLoading: Bool
    let isFavorite: Bool
    /// The super-like tier; always false when `isFavorite` is false.
    let isSuperLiked: Bool
    let shuffleEnabled: Bool
    let repeatMode: CompanionRepeatMode
    let errorMessage: String?

    init(
        trackID: String,
        title: String,
        artist: String,
        position: Double,
        duration: Double,
        isPlaying: Bool,
        isLoading: Bool,
        isFavorite: Bool,
        isSuperLiked: Bool = false,
        shuffleEnabled: Bool,
        repeatMode: CompanionRepeatMode,
        errorMessage: String? = nil
    ) {
        self.trackID = trackID
        self.title = CompanionWire.boundedText(title)
        self.artist = CompanionWire.boundedText(artist)
        let duration = duration.isFinite && duration > 0 ? duration : 0
        self.position = position.isFinite ? max(0, duration > 0 ? min(position, duration) : position) : 0
        self.duration = duration
        self.isPlaying = isPlaying
        self.isLoading = isLoading
        self.isFavorite = isFavorite
        self.isSuperLiked = isFavorite && isSuperLiked
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.errorMessage = errorMessage.map(CompanionWire.boundedText)
    }

    private enum CodingKeys: String, CodingKey {
        case trackID, title, artist, position, duration, isPlaying, isLoading, isFavorite, isSuperLiked, shuffleEnabled, repeatMode
        case errorMessage
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let trackID = try values.decode(String.self, forKey: .trackID)
        guard CompanionWire.isValidIdentifier(trackID) else { throw CompanionWireError.invalidTrackID }
        self.init(trackID: trackID, title: try values.decode(String.self, forKey: .title),
                  artist: try values.decode(String.self, forKey: .artist),
                  position: try values.decode(Double.self, forKey: .position),
                  duration: try values.decode(Double.self, forKey: .duration),
                  isPlaying: try values.decode(Bool.self, forKey: .isPlaying),
                  isLoading: try values.decode(Bool.self, forKey: .isLoading),
                  isFavorite: try values.decode(Bool.self, forKey: .isFavorite),
                  isSuperLiked: try values.decode(Bool.self, forKey: .isSuperLiked),
                  shuffleEnabled: try values.decode(Bool.self, forKey: .shuffleEnabled),
                  repeatMode: try values.decode(CompanionRepeatMode.self, forKey: .repeatMode),
                  errorMessage: try values.decodeIfPresent(String.self, forKey: .errorMessage))
    }

    func encode(to encoder: any Encoder) throws {
        guard CompanionWire.isValidIdentifier(trackID) else { throw CompanionWireError.invalidTrackID }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(trackID, forKey: .trackID)
        try values.encode(title, forKey: .title)
        try values.encode(artist, forKey: .artist)
        try values.encode(position, forKey: .position)
        try values.encode(duration, forKey: .duration)
        try values.encode(isPlaying, forKey: .isPlaying)
        try values.encode(isLoading, forKey: .isLoading)
        try values.encode(isFavorite, forKey: .isFavorite)
        try values.encode(isSuperLiked, forKey: .isSuperLiked)
        try values.encode(shuffleEnabled, forKey: .shuffleEnabled)
        try values.encode(repeatMode, forKey: .repeatMode)
        try values.encodeIfPresent(errorMessage, forKey: .errorMessage)
    }
}

struct CompanionRequest: Codable, Equatable, Sendable {
    let version: Int
    let id: UUID
    let action: CompanionAction
    let expectedTrackID: String?
    let executionLease: CompanionExecutionLease?

    init(version: Int = CompanionWire.version, id: UUID = UUID(), action: CompanionAction, expectedTrackID: String? = nil,
         executionLease: CompanionExecutionLease? = nil) {
        self.version = version
        self.id = id
        self.action = action
        self.expectedTrackID = expectedTrackID
        self.executionLease = executionLease
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, action, expectedTrackID, executionLease
    }

    init(from decoder: any Decoder) throws {
        try CompanionWire.requireKeys(["version", "id", "action"], optional: ["expectedTrackID", "executionLease"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == CompanionWire.version else { throw CompanionWireError.unsupportedVersion }
        self.init(version: version, id: try values.decode(UUID.self, forKey: .id),
                  action: try values.decode(CompanionAction.self, forKey: .action),
                  expectedTrackID: try values.decodeIfPresent(String.self, forKey: .expectedTrackID),
                  executionLease: try values.decodeIfPresent(CompanionExecutionLease.self, forKey: .executionLease))
        try validate()
    }

    func validate() throws {
        guard version == CompanionWire.version else { throw CompanionWireError.unsupportedVersion }
        if let expectedTrackID, !CompanionWire.isValidIdentifier(expectedTrackID) {
            throw CompanionWireError.invalidTrackID
        }
        switch action {
        case .browse(let location):
            guard CompanionWire.canonicalLocation(location) != nil else { throw CompanionWireError.invalidLocation }
        case .playItem(let location, let itemID, let revision):
            guard CompanionWire.canonicalLocation(location) != nil else { throw CompanionWireError.invalidLocation }
            guard CompanionWire.isValidIdentifier(itemID),
                  CompanionWire.isValidIdentifier(revision, maximumBytes: CompanionWire.maximumRevisionBytes) else {
                throw CompanionWireError.invalidItem
            }
        case .seek(let position):
            guard position.isFinite, position >= 0 else { throw CompanionWireError.invalidSeek }
        case .snapshot, .play, .pause, .next, .previous, .setFavorite, .setSuperLiked, .setShuffle, .setRepeatMode:
            break
        }
    }
}

enum CompanionAction: Codable, Equatable, Sendable {
    case snapshot
    case browse(String)
    case play
    case pause
    case next
    case previous
    case seek(Double)
    case setFavorite(Bool)
    /// True promotes the current song to a super like (liking it if needed); false steps it back to a like.
    case setSuperLiked(Bool)
    case setShuffle(Bool)
    case setRepeatMode(CompanionRepeatMode)
    case playItem(location: String, itemID: String, revision: String)

    private enum CodingKeys: String, CodingKey {
        case snapshot, browse, play, pause, next, previous, seek, setFavorite, setSuperLiked, setShuffle, setRepeatMode, playItem
    }

    private enum ArgumentKeys: String, CodingKey {
        case value = "_0"
        case location, itemID, revision
    }

    init(from decoder: any Decoder) throws {
        let keys = try CompanionWire.keys(in: decoder)
        guard keys.count == 1, let name = keys.first, let key = CodingKeys(rawValue: name) else {
            throw CompanionWireError.malformedRequest
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try values.superDecoder(forKey: key)
        switch key {
        case .snapshot, .play, .pause, .next, .previous:
            try CompanionWire.requireKeys([], in: payload)
            switch key {
            case .snapshot: self = .snapshot
            case .play: self = .play
            case .pause: self = .pause
            case .next: self = .next
            default: self = .previous
            }
        case .browse, .seek, .setFavorite, .setSuperLiked, .setShuffle, .setRepeatMode:
            try CompanionWire.requireKeys(["_0"], in: payload)
            let arguments = try payload.container(keyedBy: ArgumentKeys.self)
            switch key {
            case .browse: self = .browse(try arguments.decode(String.self, forKey: .value))
            case .seek: self = .seek(try arguments.decode(Double.self, forKey: .value))
            case .setFavorite: self = .setFavorite(try arguments.decode(Bool.self, forKey: .value))
            case .setSuperLiked: self = .setSuperLiked(try arguments.decode(Bool.self, forKey: .value))
            case .setShuffle: self = .setShuffle(try arguments.decode(Bool.self, forKey: .value))
            default: self = .setRepeatMode(try arguments.decode(CompanionRepeatMode.self, forKey: .value))
            }
        case .playItem:
            try CompanionWire.requireKeys(["location", "itemID", "revision"], in: payload)
            let arguments = try payload.container(keyedBy: ArgumentKeys.self)
            self = .playItem(location: try arguments.decode(String.self, forKey: .location),
                             itemID: try arguments.decode(String.self, forKey: .itemID),
                             revision: try arguments.decode(String.self, forKey: .revision))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot: _ = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .snapshot)
        case .play: _ = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .play)
        case .pause: _ = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .pause)
        case .next: _ = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .next)
        case .previous: _ = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .previous)
        case .browse(let location):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .browse)
            try arguments.encode(location, forKey: .value)
        case .seek(let position):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .seek)
            try arguments.encode(position, forKey: .value)
        case .setFavorite(let favorite):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .setFavorite)
            try arguments.encode(favorite, forKey: .value)
        case .setSuperLiked(let superLiked):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .setSuperLiked)
            try arguments.encode(superLiked, forKey: .value)
        case .setShuffle(let shuffled):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .setShuffle)
            try arguments.encode(shuffled, forKey: .value)
        case .setRepeatMode(let mode):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .setRepeatMode)
            try arguments.encode(mode, forKey: .value)
        case .playItem(let location, let itemID, let revision):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: .playItem)
            try arguments.encode(location, forKey: .location)
            try arguments.encode(itemID, forKey: .itemID)
            try arguments.encode(revision, forKey: .revision)
        }
    }
}

struct CompanionResponse: Codable, Equatable, Sendable {
    let id: UUID
    let accepted: Bool
    let snapshot: CompanionSnapshot
    let page: CompanionPage?
    let error: String?
    let executionLease: CompanionExecutionLease?

    init(
        id: UUID,
        accepted: Bool,
        snapshot: CompanionSnapshot,
        page: CompanionPage? = nil,
        error: String? = nil,
        executionLease: CompanionExecutionLease? = nil
    ) {
        self.id = id
        self.accepted = accepted
        self.snapshot = snapshot
        self.page = page
        self.error = error.map(CompanionWire.boundedText)
        self.executionLease = executionLease
    }

    private enum CodingKeys: String, CodingKey { case id, accepted, snapshot, page, error, executionLease }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id), accepted: try values.decode(Bool.self, forKey: .accepted),
                  snapshot: try values.decode(CompanionSnapshot.self, forKey: .snapshot),
                  page: try values.decodeIfPresent(CompanionPage.self, forKey: .page),
                  error: try values.decodeIfPresent(String.self, forKey: .error),
                  executionLease: try values.decodeIfPresent(CompanionExecutionLease.self, forKey: .executionLease))
    }
}

struct CompanionPage: Codable, Equatable, Sendable {
    let location: String
    let title: String
    let revision: String
    let items: [CompanionItem]
    let isTruncated: Bool

    init(location: String, title: String, revision: String, items: [CompanionItem], isTruncated: Bool) {
        self.location = location
        self.title = CompanionWire.boundedText(title)
        self.revision = revision
        self.items = Array(items.prefix(CompanionWire.maximumItems))
        self.isTruncated = isTruncated || items.count > CompanionWire.maximumItems
    }

    private enum CodingKeys: String, CodingKey { case location, title, revision, items, isTruncated }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let location = try values.decode(String.self, forKey: .location)
        let revision = try values.decode(String.self, forKey: .revision)
        let items = try values.decode([CompanionItem].self, forKey: .items)
        guard CompanionWire.canonicalLocation(location) != nil,
              CompanionWire.isValidIdentifier(revision, maximumBytes: CompanionWire.maximumRevisionBytes),
              Set(items.map(\.id)).count == items.count else { throw CompanionWireError.malformedRequest }
        self.init(location: location, title: try values.decode(String.self, forKey: .title), revision: revision,
                  items: items, isTruncated: try values.decode(Bool.self, forKey: .isTruncated))
    }

    func encode(to encoder: any Encoder) throws {
        guard CompanionWire.canonicalLocation(location) != nil,
              CompanionWire.isValidIdentifier(revision, maximumBytes: CompanionWire.maximumRevisionBytes),
              Set(items.map(\.id)).count == items.count else { throw CompanionWireError.invalidItem }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(location, forKey: .location)
        try values.encode(title, forKey: .title)
        try values.encode(revision, forKey: .revision)
        try values.encode(items, forKey: .items)
        try values.encode(isTruncated, forKey: .isTruncated)
    }
}

struct CompanionItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let destination: String?

    init(id: String, title: String, subtitle: String, destination: String? = nil) {
        self.id = id
        self.title = CompanionWire.boundedText(title)
        self.subtitle = CompanionWire.boundedText(subtitle)
        self.destination = destination
    }

    private enum CodingKeys: String, CodingKey { case id, title, subtitle, destination }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let destination = try values.decodeIfPresent(String.self, forKey: .destination)
        guard CompanionWire.isValidIdentifier(id),
              destination.map({ CompanionWire.canonicalLocation($0) != nil }) ?? true else {
            throw CompanionWireError.invalidItem
        }
        self.init(id: id, title: try values.decode(String.self, forKey: .title),
                  subtitle: try values.decode(String.self, forKey: .subtitle), destination: destination)
    }

    func encode(to encoder: any Encoder) throws {
        guard CompanionWire.isValidIdentifier(id),
              destination.map({ CompanionWire.canonicalLocation($0) != nil }) ?? true else {
            throw CompanionWireError.invalidItem
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(subtitle, forKey: .subtitle)
        try values.encodeIfPresent(destination, forKey: .destination)
    }
}

enum CompanionWireError: Error, LocalizedError, Equatable, Sendable {
    case oversizedMessage, malformedRequest, unsupportedVersion, invalidLocation, invalidTrackID, invalidItem, invalidSeek

    var errorDescription: String? {
        switch self {
        case .oversizedMessage: "This companion message is too large. Refresh and try again."
        case .malformedRequest: "This companion request couldn’t be read. Refresh and try again."
        case .unsupportedVersion: "Update Velvet Thorn on your iPhone and Apple Watch to use these controls."
        case .invalidLocation: "This library page is unavailable. Refresh and try again."
        case .invalidTrackID: "This song can’t be controlled from here. Refresh and try again."
        case .invalidItem: "This library item is unavailable. Refresh and try again."
        case .invalidSeek: "Choose a valid playback position."
        }
    }
}

enum CompanionWire {
    /// Version 2 adds `isSuperLiked` to the snapshot and the `setSuperLiked` action; both sides ship together.
    /// The optional snapshot `accent` needs no bump: snapshot decoding ignores unknown keys and tolerates its absence.
    static let version = 2
    static let maximumMessageBytes = 60 * 1_024
    static let maximumItems = 40
    static let maximumIdentifierBytes = 256
    static let maximumRevisionBytes = 64
    static let maximumTextBytes = 384

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumMessageBytes else { throw CompanionWireError.oversizedMessage }
        return data
    }

    // The byte check precedes decoding, including unknown keys and JSON whitespace that DTO validation cannot see.
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= maximumMessageBytes else { throw CompanionWireError.oversizedMessage }
        guard !data.isEmpty else { throw CompanionWireError.malformedRequest }
        return try JSONDecoder().decode(type, from: data)
    }

    static func canonicalLocation(_ value: String) -> String? {
        guard value.utf8.prefix(65).count <= 64 else { return nil }
        switch value {
        case "root", "favorites", "recent", "playlists", "queue": return value
        default:
            guard value.hasPrefix("playlist:"), value.utf8.count == 45,
                  let id = UUID(uuidString: String(value.dropFirst(9))) else { return nil }
            return "playlist:\(id.uuidString)"
        }
    }

    static func isValidIdentifier(_ value: String, maximumBytes: Int = maximumIdentifierBytes) -> Bool {
        guard !value.isEmpty else { return false }
        var bytes = 0
        var hasContent = false
        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            hasContent = hasContent || !CharacterSet.whitespacesAndNewlines.contains(scalar)
            bytes += encodedBytes(scalar)
            if bytes > maximumBytes { return false }
        }
        return hasContent
    }

    // Budget JSON-escaped bytes rather than characters; control characters and multibyte titles stay within 60 KiB.
    static func boundedText(_ value: String) -> String {
        var result = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            let width = encodedBytes(scalar)
            guard bytes + width <= maximumTextBytes else {
                while bytes > maximumTextBytes - 3, let last = result.unicodeScalars.last {
                    bytes -= encodedBytes(last)
                    result.unicodeScalars.removeLast()
                }
                result.append("…")
                break
            }
            result.unicodeScalars.append(scalar)
            bytes += width
        }
        return result
    }

    private static func encodedBytes(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<32, 0x2028, 0x2029: 6
        case 34, 47, 92: 2
        case 0..<0x80: 1
        case 0..<0x800: 2
        case 0..<0x10000: 3
        default: 4
        }
    }

    fileprivate static func keys(in decoder: any Decoder) throws -> Set<String> {
        Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    }

    fileprivate static func requireKeys(_ required: Set<String>, optional: Set<String> = [], in decoder: any Decoder) throws {
        let actual = try keys(in: decoder)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw CompanionWireError.malformedRequest
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
