import Foundation

/// Wire contract for the local companion link between Velvet Thorn devices on one network.
/// Lives outside `Sources/Core/Companion` because the Watch target compiles that folder and has no `PlaybackSnapshot`.
enum NearbyLinkWire {
    static let version = 1
    static let serviceType = "_ganabajana._tcp"
    static let headerBytes = 4
    static let maximumFrameBytes = 2 * 1_024 * 1_024
    /// Everything except a transfer offer is a Companion projection; it keeps the Companion bound plus envelope room.
    static let maximumControlFrameBytes = CompanionWire.maximumMessageBytes + 4 * 1_024
    /// The receiver applies offers through `continuePlayback`, which refuses anything the Handoff codec would.
    static let maximumQueueOccurrences = PlaybackHandoffCodec.maximumQueueCount
    static let maximumArtworkURLBytes = 2_048
    static let maximumPosition: Double = 86_400
    static let pairingKeyBytes = 32
    /// ChaChaPoly combined form: 12-byte nonce, 32-byte key, 16-byte tag.
    static let sealedLinkKeyBytes = 60

    static func encode(_ message: NearbyLinkMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        try checkSize(payload, for: message)
        return payload
    }

    static func decode(_ payload: Data) throws -> NearbyLinkMessage {
        guard !payload.isEmpty else { throw NearbyLinkError.emptyFrame }
        guard payload.count <= maximumFrameBytes else { throw NearbyLinkError.oversizedFrame }
        let message: NearbyLinkMessage
        // Mistyped fields and bad JSON fail closed as one error, so peers cannot probe decoder internals.
        do { message = try JSONDecoder().decode(NearbyLinkMessage.self, from: payload) }
        catch is DecodingError { throw NearbyLinkError.malformed }
        try checkSize(payload, for: message)
        return message
    }

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw NearbyLinkError.emptyFrame }
        guard payload.count <= maximumFrameBytes else { throw NearbyLinkError.oversizedFrame }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: headerBytes)
        framed.append(payload)
        return framed
    }

    static func framed(_ message: NearbyLinkMessage) throws -> Data {
        try frame(encode(message))
    }

    private static func checkSize(_ payload: Data, for message: NearbyLinkMessage) throws {
        let limit: Int
        if case .transferOffer = message { limit = maximumFrameBytes } else { limit = maximumControlFrameBytes }
        guard payload.count <= limit else { throw NearbyLinkError.oversizedFrame }
    }

    /// Only `https` artwork survives, so a peer can never point this device's loader at a local or cleartext host.
    static func safeArtworkURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.absoluteString.utf8.count <= maximumArtworkURLBytes else { return nil }
        return url
    }

    static func isValidPosition(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximumPosition
    }
}

enum NearbyLinkError: Error, Equatable, Sendable {
    case oversizedFrame, emptyFrame, malformed, unsupportedVersion, invalidTransfer, decoderClosed
}

/// Incremental reader for 4-byte big-endian length-prefixed frames.
/// The length is checked before any payload byte is buffered; after an error the stream is unusable and must close.
struct NearbyFrameDecoder: Sendable {
    private var header = Data()
    private var payload = Data()
    private var expected: Int?
    private var failed = false

    init() {}

    var bufferedBytes: Int { header.count + payload.count }

    mutating func append(_ data: Data) throws -> [Data] {
        guard !failed else { throw NearbyLinkError.decoderClosed }
        var frames: [Data] = []
        var index = data.startIndex
        do {
            while index < data.endIndex {
                if let expected {
                    let take = min(expected - payload.count, data.endIndex - index)
                    payload.append(data[index..<(index + take)])
                    index += take
                    if payload.count == expected {
                        frames.append(payload)
                        payload = Data()
                        self.expected = nil
                    }
                } else {
                    let take = min(NearbyLinkWire.headerBytes - header.count, data.endIndex - index)
                    header.append(data[index..<(index + take)])
                    index += take
                    guard header.count == NearbyLinkWire.headerBytes else { continue }
                    let length = header.reduce(0) { ($0 << 8) | Int($1) }
                    header = Data()
                    guard length > 0 else { throw NearbyLinkError.emptyFrame }
                    guard length <= NearbyLinkWire.maximumFrameBytes else { throw NearbyLinkError.oversizedFrame }
                    expected = length
                    payload.reserveCapacity(min(length, 64 * 1_024))
                }
            }
        } catch {
            failed = true
            header = Data()
            payload = Data()
            expected = nil
            throw error
        }
        return frames
    }
}

enum NearbyDeviceKind: String, Codable, CaseIterable, Equatable, Sendable {
    case iPhone, iPad, mac
}

struct NearbyPeerHello: Codable, Equatable, Sendable {
    let installationID: UUID
    let displayName: String
    let deviceKind: NearbyDeviceKind
    let wireVersion: Int
    let companionWireVersion: Int

    init(installationID: UUID, displayName: String, deviceKind: NearbyDeviceKind,
         wireVersion: Int = NearbyLinkWire.version, companionWireVersion: Int = CompanionWire.version) {
        self.installationID = installationID
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = CompanionWire.boundedText(trimmed.isEmpty ? deviceKind.fallbackName : trimmed)
        self.deviceKind = deviceKind
        self.wireVersion = wireVersion
        self.companionWireVersion = companionWireVersion
    }

    private enum CodingKeys: String, CodingKey { case installationID, displayName, deviceKind, wireVersion, companionWireVersion }

    init(from decoder: any Decoder) throws {
        try NearbyKeys.require(["installationID", "displayName", "deviceKind", "wireVersion", "companionWireVersion"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let wire = try values.decode(Int.self, forKey: .wireVersion)
        let companion = try values.decode(Int.self, forKey: .companionWireVersion)
        guard wire == NearbyLinkWire.version, companion == CompanionWire.version else { throw NearbyLinkError.unsupportedVersion }
        guard let kind = NearbyDeviceKind(rawValue: try values.decode(String.self, forKey: .deviceKind)) else {
            throw NearbyLinkError.malformed
        }
        self.init(installationID: try values.decode(UUID.self, forKey: .installationID),
                  displayName: try values.decode(String.self, forKey: .displayName), deviceKind: kind,
                  wireVersion: wire, companionWireVersion: companion)
    }
}

extension NearbyDeviceKind {
    var fallbackName: String {
        switch self {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .mac: "Mac"
        }
    }
}

/// A peer's Companion snapshot plus the artwork the Watch never needed.
struct NearbyNowPlaying: Codable, Equatable, Sendable {
    let snapshot: CompanionSnapshot
    let artworkURL: URL?

    init(snapshot: CompanionSnapshot, artworkURL: URL?) {
        self.snapshot = snapshot
        self.artworkURL = snapshot.nowPlaying == nil ? nil : NearbyLinkWire.safeArtworkURL(artworkURL)
    }

    private enum CodingKeys: String, CodingKey { case snapshot, artworkURL }

    init(from decoder: any Decoder) throws {
        try NearbyKeys.require(["snapshot"], optional: ["artworkURL"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Unsafe or oversized artwork is cosmetic: drop it rather than lose the peer's playback state.
        let text = try? values.decodeIfPresent(String.self, forKey: .artworkURL)
        let url = text.flatMap { $0.utf8.count <= NearbyLinkWire.maximumArtworkURLBytes ? URL(string: $0) : nil }
        self.init(snapshot: try values.decode(CompanionSnapshot.self, forKey: .snapshot), artworkURL: url)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshot, forKey: .snapshot)
        try values.encodeIfPresent(artworkURL?.absoluteString, forKey: .artworkURL)
    }

    /// Position-only differences are throttled; everything a listener would notice publishes at once.
    func hasSameSemantics(as other: NearbyNowPlaying) -> Bool {
        guard artworkURL == other.artworkURL else { return false }
        let lhs = snapshot
        let rhs = other.snapshot
        guard lhs.sessionID == rhs.sessionID, lhs.libraryError == rhs.libraryError, lhs.accent == rhs.accent else { return false }
        switch (lhs.nowPlaying, rhs.nowPlaying) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            return lhs.trackID == rhs.trackID && lhs.title == rhs.title && lhs.artist == rhs.artist
                && lhs.duration == rhs.duration && lhs.isPlaying == rhs.isPlaying && lhs.isLoading == rhs.isLoading
                && lhs.isFavorite == rhs.isFavorite && lhs.isSuperLiked == rhs.isSuperLiked
                && lhs.shuffleEnabled == rhs.shuffleEnabled && lhs.repeatMode == rhs.repeatMode
                && lhs.errorMessage == rhs.errorMessage
        default: return false
        }
    }
}

enum NearbyTransferCancelReason: String, Codable, CaseIterable, Equatable, Sendable {
    case liveRadio, nothingSelected, queueTooLarge, busy, timeout, notReady, applyFailed, disconnected, cancelled
}

struct NearbyTransferOffer: Codable, Equatable, Sendable {
    let id: UUID
    let snapshot: PlaybackSnapshot
    let wasPlaying: Bool
    let position: Double

    /// Validates bounds and drops non-https artwork, so a peer cannot hand this device an unbounded or unsafe queue.
    init(id: UUID, snapshot: PlaybackSnapshot, wasPlaying: Bool, position: Double) throws {
        guard !snapshot.queue.isEmpty, snapshot.queue.count <= NearbyLinkWire.maximumQueueOccurrences,
              snapshot.queue.indices.contains(snapshot.currentIndex),
              NearbyLinkWire.isValidPosition(position), NearbyLinkWire.isValidPosition(snapshot.position),
              snapshot.queue.allSatisfy({ CompanionWire.isValidIdentifier($0.id) }) else { throw NearbyLinkError.invalidTransfer }
        if let original = snapshot.originalQueue {
            guard original.count <= NearbyLinkWire.maximumQueueOccurrences,
                  original.allSatisfy({ CompanionWire.isValidIdentifier($0.id) }) else { throw NearbyLinkError.invalidTransfer }
        }
        if let indices = snapshot.originalQueueIndices {
            let bound = snapshot.originalQueue?.count ?? snapshot.queue.count
            guard indices.count == snapshot.queue.count, indices.allSatisfy({ $0 >= 0 && $0 < bound }) else {
                throw NearbyLinkError.invalidTransfer
            }
        }
        var sanitized = snapshot
        sanitized.queue = snapshot.queue.map(Self.sanitized)
        sanitized.originalQueue = snapshot.originalQueue?.map(Self.sanitized)
        self.id = id
        self.snapshot = sanitized
        self.wasPlaying = wasPlaying
        self.position = position
    }

    var currentTrackID: String { snapshot.queue[snapshot.currentIndex].id }

    private static func sanitized(_ track: Track) -> Track {
        var track = track
        track.artworkURL = NearbyLinkWire.safeArtworkURL(track.artworkURL)
        return track
    }

    private enum CodingKeys: String, CodingKey { case id, snapshot, wasPlaying, position }

    init(from decoder: any Decoder) throws {
        try NearbyKeys.require(["id", "snapshot", "wasPlaying", "position"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: try values.decode(UUID.self, forKey: .id),
                      snapshot: try values.decode(PlaybackSnapshot.self, forKey: .snapshot),
                      wasPlaying: try values.decode(Bool.self, forKey: .wasPlaying),
                      position: try values.decode(Double.self, forKey: .position))
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(snapshot, forKey: .snapshot)
        try values.encode(wasPlaying, forKey: .wasPlaying)
        try values.encode(position, forKey: .position)
    }

    static func == (lhs: NearbyTransferOffer, rhs: NearbyTransferOffer) -> Bool {
        guard lhs.id == rhs.id, lhs.wasPlaying == rhs.wasPlaying, lhs.position == rhs.position else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(lhs.snapshot)) == (try? encoder.encode(rhs.snapshot))
    }
}

struct NearbyPairingRequest: Codable, Equatable, Sendable {
    let publicKey: Data

    init(publicKey: Data) throws {
        guard publicKey.count == NearbyLinkWire.pairingKeyBytes else { throw NearbyLinkError.malformed }
        self.publicKey = publicKey
    }

    private enum CodingKeys: String, CodingKey { case publicKey }

    init(from decoder: any Decoder) throws {
        try NearbyKeys.require(["publicKey"], in: decoder)
        try self.init(publicKey: try decoder.container(keyedBy: CodingKeys.self).decode(Data.self, forKey: .publicKey))
    }
}

struct NearbyPairingGrant: Codable, Equatable, Sendable {
    let publicKey: Data
    let sealedLinkKey: Data

    init(publicKey: Data, sealedLinkKey: Data) throws {
        guard publicKey.count == NearbyLinkWire.pairingKeyBytes, sealedLinkKey.count == NearbyLinkWire.sealedLinkKeyBytes else {
            throw NearbyLinkError.malformed
        }
        self.publicKey = publicKey
        self.sealedLinkKey = sealedLinkKey
    }

    private enum CodingKeys: String, CodingKey { case publicKey, sealedLinkKey }

    init(from decoder: any Decoder) throws {
        try NearbyKeys.require(["publicKey", "sealedLinkKey"], in: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(publicKey: try values.decode(Data.self, forKey: .publicKey),
                      sealedLinkKey: try values.decode(Data.self, forKey: .sealedLinkKey))
    }
}

/// One frame on the link: exactly `{"version": 1, "<case>": {...}}`. Unknown cases, extra keys or versions fail closed.
enum NearbyLinkMessage: Codable, Equatable, Sendable {
    case hello(NearbyPeerHello)
    case snapshot(NearbyNowPlaying)
    case request(CompanionRequest)
    case response(CompanionResponse)
    case transferRequest(id: UUID)
    case transferOffer(NearbyTransferOffer)
    case transferReady(id: UUID)
    /// `playing` is the sender's state at release, so a pause there during preparation is respected.
    case transferReleased(id: UUID, position: Double, playing: Bool)
    case transferPush(id: UUID)
    case transferCancel(id: UUID, reason: NearbyTransferCancelReason)
    case ping(id: UUID, sentUptime: Double)
    case pong(id: UUID, sentUptime: Double)
    case pairingRequest(NearbyPairingRequest)
    case pairingGrant(NearbyPairingGrant)

    /// Bounded metric name; never carries payload values.
    var kind: String { Kind(self).rawValue }

    private enum Kind: String, CaseIterable, CodingKey {
        case hello, snapshot, request, response, transferRequest, transferOffer, transferReady, transferReleased
        case transferPush, transferCancel, ping, pong, pairingRequest, pairingGrant
        /// The envelope's own key shares this enum so encoding uses one container; it never names a message.
        case version

        init(_ message: NearbyLinkMessage) {
            switch message {
            case .hello: self = .hello
            case .snapshot: self = .snapshot
            case .request: self = .request
            case .response: self = .response
            case .transferRequest: self = .transferRequest
            case .transferOffer: self = .transferOffer
            case .transferReady: self = .transferReady
            case .transferReleased: self = .transferReleased
            case .transferPush: self = .transferPush
            case .transferCancel: self = .transferCancel
            case .ping: self = .ping
            case .pong: self = .pong
            case .pairingRequest: self = .pairingRequest
            case .pairingGrant: self = .pairingGrant
            }
        }
    }

    private enum ArgumentKeys: String, CodingKey { case id, position, playing, reason, sentUptime }

    init(from decoder: any Decoder) throws {
        let keys = try NearbyKeys.keys(in: decoder)
        guard keys.contains("version") else { throw NearbyLinkError.malformed }
        let values = try decoder.container(keyedBy: Kind.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == NearbyLinkWire.version else { throw NearbyLinkError.unsupportedVersion }
        let names = keys.subtracting(["version"])
        guard names.count == 1, let name = names.first, let kind = Kind(rawValue: name), kind != .version else {
            throw NearbyLinkError.malformed
        }
        let payload = try values.superDecoder(forKey: kind)
        switch kind {
        case .hello: self = .hello(try NearbyPeerHello(from: payload))
        case .snapshot: self = .snapshot(try NearbyNowPlaying(from: payload))
        case .request: self = .request(try CompanionRequest(from: payload))
        case .response: self = .response(try CompanionResponse(from: payload))
        case .transferOffer: self = .transferOffer(try NearbyTransferOffer(from: payload))
        case .pairingRequest: self = .pairingRequest(try NearbyPairingRequest(from: payload))
        case .pairingGrant: self = .pairingGrant(try NearbyPairingGrant(from: payload))
        case .transferRequest, .transferReady, .transferPush:
            try NearbyKeys.require(["id"], in: payload)
            let id = try payload.container(keyedBy: ArgumentKeys.self).decode(UUID.self, forKey: .id)
            switch kind {
            case .transferRequest: self = .transferRequest(id: id)
            case .transferReady: self = .transferReady(id: id)
            default: self = .transferPush(id: id)
            }
        case .transferReleased:
            try NearbyKeys.require(["id", "position", "playing"], in: payload)
            let values = try payload.container(keyedBy: ArgumentKeys.self)
            let position = try values.decode(Double.self, forKey: .position)
            guard NearbyLinkWire.isValidPosition(position) else { throw NearbyLinkError.invalidTransfer }
            self = .transferReleased(id: try values.decode(UUID.self, forKey: .id), position: position,
                                     playing: try values.decode(Bool.self, forKey: .playing))
        case .transferCancel:
            try NearbyKeys.require(["id", "reason"], in: payload)
            let values = try payload.container(keyedBy: ArgumentKeys.self)
            guard let reason = NearbyTransferCancelReason(rawValue: try values.decode(String.self, forKey: .reason)) else {
                throw NearbyLinkError.malformed
            }
            self = .transferCancel(id: try values.decode(UUID.self, forKey: .id), reason: reason)
        case .version:
            throw NearbyLinkError.malformed
        case .ping, .pong:
            try NearbyKeys.require(["id", "sentUptime"], in: payload)
            let values = try payload.container(keyedBy: ArgumentKeys.self)
            let sent = try values.decode(Double.self, forKey: .sentUptime)
            guard sent.isFinite, sent >= 0 else { throw NearbyLinkError.malformed }
            let id = try values.decode(UUID.self, forKey: .id)
            self = kind == .ping ? .ping(id: id, sentUptime: sent) : .pong(id: id, sentUptime: sent)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Kind.self)
        try values.encode(NearbyLinkWire.version, forKey: .version)
        let kind = Kind(self)
        switch self {
        case .hello(let hello): try values.encode(hello, forKey: kind)
        case .snapshot(let snapshot): try values.encode(snapshot, forKey: kind)
        case .request(let request):
            try request.validate()
            try values.encode(request, forKey: kind)
        case .response(let response): try values.encode(response, forKey: kind)
        case .transferOffer(let offer): try values.encode(offer, forKey: kind)
        case .pairingRequest(let request): try values.encode(request, forKey: kind)
        case .pairingGrant(let grant): try values.encode(grant, forKey: kind)
        case .transferRequest(let id), .transferReady(let id), .transferPush(let id):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: kind)
            try arguments.encode(id, forKey: .id)
        case .transferReleased(let id, let position, let playing):
            guard NearbyLinkWire.isValidPosition(position) else { throw NearbyLinkError.invalidTransfer }
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: kind)
            try arguments.encode(id, forKey: .id)
            try arguments.encode(position, forKey: .position)
            try arguments.encode(playing, forKey: .playing)
        case .transferCancel(let id, let reason):
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: kind)
            try arguments.encode(id, forKey: .id)
            try arguments.encode(reason, forKey: .reason)
        case .ping(let id, let sent), .pong(let id, let sent):
            guard sent.isFinite, sent >= 0 else { throw NearbyLinkError.malformed }
            var arguments = values.nestedContainer(keyedBy: ArgumentKeys.self, forKey: kind)
            try arguments.encode(id, forKey: .id)
            try arguments.encode(sent, forKey: .sentUptime)
        }
    }
}

enum NearbyKeys {
    static func keys(in decoder: any Decoder) throws -> Set<String> {
        Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
    }

    static func require(_ required: Set<String>, optional: Set<String> = [], in decoder: any Decoder) throws {
        let actual = try keys(in: decoder)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
            throw NearbyLinkError.malformed
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
