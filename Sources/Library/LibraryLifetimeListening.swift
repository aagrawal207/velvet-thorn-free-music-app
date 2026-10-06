import CryptoKit
import Foundation

struct LifetimeListeningPublication: Sendable {
    let summary: LifetimeListeningSummary
    let hasFutureReceipts: Bool

    init(_ rollup: LifetimeListeningRollup, now: Date) {
        summary = rollup.summary
        hasFutureReceipts = rollup.sessions.values.contains { $0.startedAt > now }
    }
}

enum LibraryHex {
    private static let digits = Array("0123456789abcdef".utf8)

    /// Lowercase, two digits per byte: byte-identical to joining `String(format: "%02x")`, which stored receipts use.
    static func lowercase<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        String(unsafeUninitializedCapacity: bytes.count * 2) { buffer in
            var index = 0
            for byte in bytes {
                buffer[index] = digits[Int(byte >> 4)]
                buffer[index + 1] = digits[Int(byte & 0x0f)]
                index += 2
            }
            return index
        }
    }

    static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).withUnsafeBytes { lowercase($0) }
    }
}

struct LifetimeListeningContribution: Codable, Equatable, Sendable {
    var identity: String
    var startedAt: Date
    var seconds: TimeInterval
    var qualified: Bool

    init(_ event: ListeningEvent) {
        identity = LibraryHex.sha256(event.track.id)
        let milliseconds = min((event.startedAt.timeIntervalSince1970 * 1000).rounded(), 253_402_300_799_999)
        startedAt = Date(timeIntervalSince1970: milliseconds / 1000)
        seconds = event.listenedSeconds
        qualified = seconds >= ListeningAnalytics.qualifyingSeconds(for: event.track)
    }

    func joined(_ other: Self) throws -> Self {
        guard identity == other.identity, startedAt == other.startedAt else {
            throw LibraryStorageError.invalidData("lifetime session identity")
        }
        var result = self
        result.seconds = max(seconds, other.seconds)
        result.qualified = qualified || other.qualified
        return result
    }

    func validate() throws {
        guard identity.utf8.count == 64, identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              LibraryValidation.isValidDate(startedAt), seconds.isFinite, seconds > 0,
              seconds <= LifetimeListeningRollup.maximumSeconds else {
            throw LibraryStorageError.invalidData("lifetime contribution")
        }
    }
}

struct LifetimeListeningRollup: Codable, Equatable, Sendable {
    static let maximumSessions = 200_000
    static let maximumSeconds: Double = 1_000_000_000_000
    static let maximumPlays = 10_000_000_000
    // Exact union of overlapping histories requires identity receipts even after song metadata expires.
    var sessions: [String: LifetimeListeningContribution] = [:]

    var summary: LifetimeListeningSummary {
        summary(through: nil)
    }

    func summary(through now: Date?) -> LifetimeListeningSummary {
        var result = LifetimeListeningSummary()
        for receipt in sessions.values {
            if let now, receipt.startedAt > now { continue }
            result.seconds += receipt.seconds
            if receipt.qualified { result.plays += 1 }
            result.coverageStartedAt = min(result.coverageStartedAt ?? receipt.startedAt, receipt.startedAt)
        }
        return result
    }

    mutating func include(_ event: ListeningEvent) throws {
        let key = event.id.uuidString
        let contribution = LifetimeListeningContribution(event)
        try contribution.validate()
        guard sessions[key] != nil || sessions.count < Self.maximumSessions else { throw LibraryStorageError.tooLarge }
        sessions[key] = try sessions[key]?.joined(contribution) ?? contribution
    }

    func cumulativeEvent(for delta: ListeningEvent) throws -> ListeningEvent {
        guard let receipt = sessions[delta.id.uuidString] else { return delta }
        _ = try receipt.joined(LifetimeListeningContribution(delta))
        var result = delta
        result.startedAt = receipt.startedAt
        result.listenedSeconds += receipt.seconds
        return result
    }

    func validate() throws {
        guard sessions.count <= Self.maximumSessions,
              sessions.keys.allSatisfy({ UUID(uuidString: $0)?.uuidString == $0 }) else {
            throw LibraryStorageError.invalidData("lifetime bounds or identity")
        }
        try sessions.values.forEach { try $0.validate() }
        let total = summary
        guard total.seconds <= Self.maximumSeconds, total.plays <= Self.maximumPlays else {
            throw LibraryStorageError.invalidData("lifetime total overflow")
        }
    }
}
