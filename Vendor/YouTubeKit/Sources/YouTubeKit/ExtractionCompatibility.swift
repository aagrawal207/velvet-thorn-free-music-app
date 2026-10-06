import Foundation
import CryptoKit

/// Data-only compatibility surfaces. No supplied text is evaluated as code or as a regular expression.
@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public struct ExtractionCompatibility: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public enum Operation: String, Codable, Sendable { case reverse, dropFirst, swapFirst, rotateLeft }
        public let operation: Operation
        public let argument: Int
        public init(operation: Operation, argument: Int) {
            self.operation = operation
            self.argument = argument
        }
    }

    public struct Player: Codable, Equatable, Sendable {
        public let sha256: String
        public let signature: [Step]?
        public let throttling: [Step]?
        public init(sha256: String, signature: [Step]? = nil, throttling: [Step]? = nil) {
            self.sha256 = sha256
            self.signature = signature
            self.throttling = throttling
        }
    }

    public let timestampKeys: [String]
    public let visitorKeys: [String]
    public let players: [Player]

    public init(timestampKeys: [String] = [], visitorKeys: [String] = [], players: [Player] = []) {
        self.timestampKeys = timestampKeys
        self.visitorKeys = visitorKeys
        self.players = players
    }

    public static let bundled = ExtractionCompatibility()
    public enum Failure: Error, Sendable { case invalidRules, inputBounds }

    public func validate() throws {
        for keys in [timestampKeys, visitorKeys] {
            guard keys.count <= 8, Set(keys).count == keys.count else { throw Failure.invalidRules }
            for key in keys {
                guard (1...64).contains(key.utf8.count),
                      key.utf8.allSatisfy({ Self.identifierByte($0) }) else { throw Failure.invalidRules }
            }
        }
        guard players.count <= 16, Set(players.map(\.sha256)).count == players.count else { throw Failure.invalidRules }
        for player in players {
            guard Self.isSHA256(player.sha256), player.signature != nil || player.throttling != nil else {
                throw Failure.invalidRules
            }
            for plan in [player.signature, player.throttling].compactMap({ $0 }) {
                guard (1...64).contains(plan.count) else { throw Failure.invalidRules }
                for step in plan {
                    guard (0...4096).contains(step.argument), step.operation != .reverse || step.argument == 0 else {
                        throw Failure.invalidRules
                    }
                }
            }
        }
    }

    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func playerHash(_ js: String) throws -> String {
        guard js.utf8.count <= 12_000_000 else { throw Failure.inputBounds }
        return SHA256.hash(data: Data(js.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func player(for js: String) throws -> Player? {
        guard !players.isEmpty else { return nil }
        let hash = try Self.playerHash(js)
        return players.first { $0.sha256 == hash }
    }

    /// Challenges use a bounded ASCII alphabet; transforms cannot grow output or invoke external work.
    public static func transform(_ input: String, steps: [Step]) throws -> String {
        try ExtractionCompatibility(players: [.init(sha256: String(repeating: "0", count: 64), signature: steps)]).validate()
        guard (1...4096).contains(input.utf8.count), input.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw Failure.inputBounds
        }
        var bytes = Array(input.utf8)
        for step in steps {
            guard !bytes.isEmpty else { throw Failure.inputBounds }
            switch step.operation {
            case .reverse: bytes.reverse()
            case .dropFirst: bytes = Array(bytes.dropFirst(step.argument))
            case .swapFirst: bytes.swapAt(0, step.argument % bytes.count)
            case .rotateLeft:
                let offset = step.argument % bytes.count
                bytes = Array(bytes[offset...]) + Array(bytes[..<offset])
            }
        }
        guard !bytes.isEmpty else { throw Failure.inputBounds }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func signatureTimestamp(in js: String) -> Int? {
        guard js.utf8.count <= 12_000_000 else { return nil }
        for key in timestampKeys {
            if let value = Self.capture(key: key, source: js, suffix: #"[ \t\r\n]{0,16}:[ \t\r\n]{0,16}([0-9]{5,6})(?![0-9])"#),
               let number = Int(value) { return number }
        }
        return nil
    }

    public func visitorData(in html: String) -> String? {
        guard html.utf8.count <= 4_000_000 else { return nil }
        for key in visitorKeys {
            if let value = Self.capture(key: key, source: html,
                                       suffix: #"[ \t\r\n]{0,16}:[ \t\r\n]{0,16}"([A-Za-z0-9_%=+./-]{1,4096})""#) {
                return value
            }
        }
        return nil
    }

    private static func identifierByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 36
    }

    private static func capture(key: String, source: String, suffix: String) -> String? {
        guard (1...64).contains(key.utf8.count), key.utf8.allSatisfy({ identifierByte($0) }) else { return nil }
        let literal = NSRegularExpression.escapedPattern(for: key)
        // All quantifiers are compiled, finite constants. The package supplies only an escaped literal identifier.
        let pattern = #"(?<![A-Za-z0-9_$])(?:""# + literal + #""|"# + literal + #")(?![A-Za-z0-9_$])"# + suffix
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
public struct ExtractionCompatibilitySnapshot: Sendable {
    public let generation: UInt64
    public let rules: ExtractionCompatibility
}

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
final class ExtractionCompatibilityRegistry: @unchecked Sendable {
    static let shared = ExtractionCompatibilityRegistry()
    private let lock = NSLock()
    private var value = ExtractionCompatibilitySnapshot(generation: 0, rules: .bundled)

    func snapshot() -> ExtractionCompatibilitySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func install(_ rules: ExtractionCompatibility) throws -> ExtractionCompatibilitySnapshot {
        try rules.validate()
        lock.lock()
        defer { lock.unlock() }
        value = .init(generation: value.generation &+ 1, rules: rules)
        return value
    }
}
