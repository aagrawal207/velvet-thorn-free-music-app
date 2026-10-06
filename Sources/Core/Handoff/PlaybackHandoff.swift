import Compression
import Foundation

/// Where an externally supplied playback state came from; logs use the raw value.
enum PlaybackContinuationOrigin: String, Sendable {
    case handoff
    case nearbyDevice = "nearby_device"
}

/// One device's music selection, offered to the listener's other devices through Handoff.
struct PlaybackHandoff: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = PlaybackHandoff.currentVersion
    /// Per-run identity, so a device never continues its own advertised activity.
    var senderID: UUID
    var sentAt: Date
    var wasPlaying: Bool
    var snapshot: PlaybackSnapshot

    init(senderID: UUID, sentAt: Date, wasPlaying: Bool, snapshot: PlaybackSnapshot) {
        self.senderID = senderID
        self.sentAt = sentAt
        self.wasPlaying = wasPlaying
        self.snapshot = snapshot
    }

    static func == (lhs: PlaybackHandoff, rhs: PlaybackHandoff) -> Bool {
        lhs.version == rhs.version && lhs.senderID == rhs.senderID && lhs.sentAt == rhs.sentAt
            && lhs.wasPlaying == rhs.wasPlaying && PlaybackHandoffCodec.sameSnapshot(lhs.snapshot, rhs.snapshot)
    }

    /// Transfer time counts only while the sender was playing, and at most 30 seconds of it.
    func resumePosition(now: Date, duration: TimeInterval?) -> TimeInterval {
        var position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
        if wasPlaying {
            let elapsed = now.timeIntervalSince(sentAt)
            position += elapsed.isFinite ? min(max(elapsed, 0), 30) : 0
        }
        if let duration, duration.isFinite, duration > 0 {
            position = min(position, max(0, duration - 1))
        }
        return max(0, position)
    }
}

enum PlaybackHandoffCodec {
    static let activityType = "com.agraabhi.ganabajana.playback"
    static let payloadKey = "payload"
    /// Shared by the publisher and the receiver for the lifetime of this process.
    static let localSenderID = UUID()
    /// Apple recommends small Handoff payloads; this is the compressed size on the wire.
    static let maximumPayloadBytes = 24 * 1024
    /// Checked before JSON parsing so a small compressed payload cannot expand without bound.
    static let maximumDecodedBytes = 512 * 1024
    static let maximumQueueCount = 1_024
    static let maximumTrackIDBytes = 256
    static let windowBefore = 10
    static let windowAfter = 150

    enum Failure: String, Error, Sendable {
        case missingPayload = "missing_payload"
        case tooLarge = "too_large"
        case decompression
        case malformed
        case unsupportedVersion = "unsupported_version"
        case invalidSnapshot = "invalid_snapshot"
        case invalidTimestamp = "invalid_timestamp"
    }

    // MARK: Encoding

    /// Returns the payload that fits the cap (possibly a window of the queue) and its compressed bytes.
    static func encodeBounded(_ handoff: PlaybackHandoff) throws -> (payload: PlaybackHandoff, data: Data) {
        var source = handoff
        source.version = PlaybackHandoff.currentVersion
        source.snapshot = sanitized(source.snapshot)
        if !isValid(source.snapshot) {
            // An inconsistent original order must not block the play order, which is what the receiver needs.
            source.snapshot.originalQueue = nil
            source.snapshot.originalQueueIndices = nil
        }
        try validate(source.snapshot)
        guard isValidDate(source.sentAt) else { throw Failure.invalidTimestamp }

        let snapshot = source.snapshot
        let count = snapshot.queue.count
        let index = snapshot.currentIndex
        var tried = Set<[Int]>()
        for (before, after) in windowSizes(before: min(windowBefore, index)) {
            let start = index - before
            let end = min(count, index + 1 + after)
            let covers = start == 0 && end == count
            // A cut shuffled queue cannot carry the full original order, so the window becomes the order.
            let variants = covers && snapshot.shuffleEnabled && snapshot.originalQueue != nil ? [true, false] : [false]
            for keepsOriginal in variants where tried.insert([start, end, keepsOriginal ? 1 : 0]).inserted {
                var candidate = source
                candidate.snapshot = window(snapshot, range: start..<end, keepsOriginal: keepsOriginal)
                guard (try? validate(candidate.snapshot)) != nil else { continue }
                let data = try compress(JSONEncoder().encode(candidate))
                if data.count <= maximumPayloadBytes { return (candidate, data) }
            }
        }
        throw Failure.tooLarge
    }

    static func userInfo(for handoff: PlaybackHandoff) throws -> [String: Data] {
        [payloadKey: try encodeBounded(handoff).data]
    }

    // MARK: Decoding

    static func decode(userInfo: [AnyHashable: Any]?) throws -> PlaybackHandoff {
        guard let data = userInfo?[payloadKey] as? Data else { throw Failure.missingPayload }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> PlaybackHandoff {
        guard !data.isEmpty else { throw Failure.missingPayload }
        guard data.count <= maximumPayloadBytes else { throw Failure.tooLarge }
        let json = try decompress(data)
        struct VersionProbe: Decodable { let version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: json) else { throw Failure.malformed }
        guard probe.version == PlaybackHandoff.currentVersion else { throw Failure.unsupportedVersion }
        guard var handoff = try? JSONDecoder().decode(PlaybackHandoff.self, from: json) else { throw Failure.malformed }
        guard isValidDate(handoff.sentAt) else { throw Failure.invalidTimestamp }
        handoff.snapshot = sanitized(handoff.snapshot)
        try validate(handoff.snapshot)
        return handoff
    }

    /// The rules every continued snapshot meets, whichever transport delivered it.
    static func validate(_ snapshot: PlaybackSnapshot) throws {
        guard !snapshot.queue.isEmpty, snapshot.queue.count <= maximumQueueCount,
              (snapshot.originalQueue?.count ?? 0) <= maximumQueueCount else { throw Failure.invalidSnapshot }
        let ids = snapshot.queue.map(\.id) + (snapshot.originalQueue?.map(\.id) ?? [])
        guard ids.allSatisfy({ $0.utf8.count <= maximumTrackIDBytes }) else { throw Failure.invalidSnapshot }
        do { try LibraryValidation.validatePlayback(snapshot) } catch { throw Failure.invalidSnapshot }
    }

    static func isValid(_ snapshot: PlaybackSnapshot) -> Bool {
        (try? validate(snapshot)) != nil
    }

    static func sameSnapshot(_ lhs: PlaybackSnapshot, _ rhs: PlaybackSnapshot) -> Bool {
        lhs.queue == rhs.queue && lhs.currentIndex == rhs.currentIndex && lhs.position == rhs.position
            && lhs.shuffleEnabled == rhs.shuffleEnabled && lhs.repeatMode == rhs.repeatMode
            && lhs.originalQueue == rhs.originalQueue && lhs.originalQueueIndices == rhs.originalQueueIndices
    }

    // MARK: Log buckets

    static func countBucket(_ count: Int) -> String {
        switch count {
        case ..<1: "0"
        case 1: "1"
        case 2...10: "2_10"
        case 11...50: "11_50"
        case 51...200: "51_200"
        default: "201_plus"
        }
    }

    static func bytesBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_024: "lt_1k"
        case ..<4_096: "1k_4k"
        case ..<16_384: "4k_16k"
        case ...maximumPayloadBytes: "16k_24k"
        default: "gt_24k"
        }
    }

    // MARK: Internals

    private static func windowSizes(before: Int) -> [(Int, Int)] {
        var sizes: [(Int, Int)] = []
        var after = windowAfter
        while after > 0 { sizes.append((before, after)); after /= 2 }
        var earlier = before
        while earlier > 0 { sizes.append((earlier, 0)); earlier /= 2 }
        sizes.append((0, 0))
        return sizes
    }

    private static func window(_ snapshot: PlaybackSnapshot, range: Range<Int>, keepsOriginal: Bool) -> PlaybackSnapshot {
        var result = snapshot
        result.queue = Array(snapshot.queue[range])
        result.currentIndex = snapshot.currentIndex - range.lowerBound
        // An unshuffled queue is its own original order, so carrying it again only costs bytes.
        if !keepsOriginal || !snapshot.shuffleEnabled {
            result.originalQueue = nil
            result.originalQueueIndices = nil
        }
        return result
    }

    private static func sanitized(_ snapshot: PlaybackSnapshot) -> PlaybackSnapshot {
        var result = snapshot
        result.queue = snapshot.queue.map(sanitized)
        result.originalQueue = snapshot.originalQueue?.map(sanitized)
        return result
    }

    /// Artwork is the only URL a Track carries; anything resembling signed media or credentials is dropped.
    private static func sanitized(_ track: Track) -> Track {
        guard let url = track.artworkURL else { return track }
        var result = track
        let host = url.host?.lowercased() ?? ""
        let signedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            ["expire", "signature", "sig", "token"].contains($0.name.lowercased())
        } ?? false
        if url.scheme?.lowercased() != "https" || host.isEmpty || url.user != nil || url.password != nil
            || host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") || url.path == "/videoplayback" || signedQuery {
            result.artworkURL = nil
        }
        return result
    }

    private static func isValidDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && LibraryValidation.isValidDate(date)
    }

    private static func compress(_ data: Data) throws -> Data {
        guard let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { throw Failure.malformed }
        return compressed
    }

    private static func decompress(_ data: Data) throws -> Data {
        // One spare byte distinguishes an output that exactly fits from one that was truncated at the cap.
        let capacity = maximumDecodedBytes + 1
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { throw Failure.decompression }
        guard written <= maximumDecodedBytes else { throw Failure.tooLarge }
        output.count = written
        return output
    }
}
