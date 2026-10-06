import CryptoKit
import Foundation
import Security

/// Storage for the shared link key; production uses the synchronizable Keychain item, tests an in-memory store.
protocol NearbyLinkKeyStoring: Sendable {
    func readLinkKey() throws -> Data?
    func writeLinkKey(_ key: Data) throws
}

enum NearbyLinkKeyError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case invalidCode, expiredCode, pairingFailed
}

/// Devices signed in to one Apple ID share this item through iCloud Keychain, which is what lets them connect without pairing.
struct KeychainNearbyLinkKeyStore: NearbyLinkKeyStoring {
    static let service = "com.agraabhi.ganabajana.nearby-link"
    static let account = "link-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            // Mac Catalyst defaults to the file keychain, which cannot hold synchronizable items.
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
        ]
    }

    func readLinkKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw NearbyLinkKeyError.keychain(status)
        }
    }

    func writeLinkKey(_ key: Data) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: key,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
            status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        }
        guard status == errSecSuccess else { throw NearbyLinkKeyError.keychain(status) }
    }
}

enum NearbyLinkKey {
    static let byteCount = 32
    static let linkIdentity = "velvet-thorn-link-v1"
    static let pairingIdentity = "velvet-thorn-pair-v1"

    /// Reads the stored key, creating one when none exists; a malformed synced value is replaced rather than trusted.
    static func current(in store: any NearbyLinkKeyStoring) throws -> Data {
        if let stored = try store.readLinkKey(), stored.count == byteCount { return stored }
        let key = random()
        try store.writeLinkKey(key)
        return key
    }

    static func random() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The TLS PSK is derived rather than the raw key, so the stored secret has one use per derivation label.
    static func tlsPSK(linkKey: Data) -> Data {
        derive(SymmetricKey(data: linkKey), salt: linkIdentity, info: "tls-psk")
    }

    /// Derived from the canonical code, so case, hyphens and spaces typed on either device yield the same key.
    static func pairingPSK(code: String) -> Data {
        let canonical = NearbyPairingCode.normalized(code) ?? code
        return derive(SymmetricKey(data: Data(canonical.utf8)), salt: pairingIdentity, info: "tls-psk")
    }

    private static func derive(_ key: SymmetricKey, salt: String, info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }
}

/// An 80-bit code shown on one device: five minutes, single use, retired after repeated failed TLS handshakes.
/// The code is the pairing PSK's only secret, so it must be long enough to resist offline guessing of a recorded handshake.
struct NearbyPairingCode: Equatable, Sendable {
    static let lifetime: TimeInterval = 300
    static let maximumFailedAttempts = 10
    static let length = 16
    /// Crockford base32: no I, L, O or U, so a code read aloud or retyped has no lookalike characters.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Canonical form: 16 uppercase alphabet characters without separators.
    let code: String
    let issuedAt: TimeInterval
    private(set) var failedAttempts = 0
    private(set) var isConsumed = false

    init(code: String, issuedAt: TimeInterval) {
        self.code = Self.normalized(code) ?? code
        self.issuedAt = issuedAt
    }

    static func generate(at uptime: TimeInterval) -> NearbyPairingCode {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return NearbyPairingCode(code: String(characters), issuedAt: uptime)
    }

    /// Accepts any case, ignores hyphens and whitespace, and reads O as 0 and I or L as 1; nil unless exactly 16 symbols remain.
    static func normalized(_ input: String) -> String? {
        var result: [Character] = []
        for character in input.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            let mapped: Character = switch character {
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
            guard alphabet.contains(mapped), result.count < length else { return nil }
            result.append(mapped)
        }
        return result.count == length ? String(result) : nil
    }

    static func isWellFormed(_ code: String) -> Bool { normalized(code) != nil }

    /// Four groups of four, the form shown on screen and copied.
    static func display(_ code: String) -> String {
        let canonical = Array(normalized(code) ?? code)
        return stride(from: 0, to: canonical.count, by: 4)
            .map { String(canonical[$0..<min($0 + 4, canonical.count)]) }
            .joined(separator: "-")
    }

    var display: String { Self.display(code) }
    var expiresAt: TimeInterval { issuedAt + Self.lifetime }

    func isUsable(at uptime: TimeInterval) -> Bool {
        !isConsumed && failedAttempts < Self.maximumFailedAttempts && uptime >= issuedAt && uptime < expiresAt
    }

    mutating func recordFailedAttempt() { failedAttempts += 1 }
    mutating func consume() { isConsumed = true }
}

/// The code authenticates the session and its 80 bits defeat offline guessing of a recorded handshake.
/// The ephemeral X25519 keys add forward secrecy: a code that leaks after pairing still reveals no link key.
enum NearbyPairing {
    struct Joiner {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let request: NearbyPairingRequest
    }

    static func makeJoiner() throws -> Joiner {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        return Joiner(privateKey: privateKey, request: try NearbyPairingRequest(publicKey: privateKey.publicKey.rawRepresentation))
    }

    static func grant(for request: NearbyPairingRequest, linkKey: Data, code: String) throws -> NearbyPairingGrant {
        guard NearbyPairingCode.isWellFormed(code), linkKey.count == NearbyLinkKey.byteCount else {
            throw NearbyLinkKeyError.pairingFailed
        }
        let joinerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: joinerKey)
        let wrapping = wrappingKey(shared, code: code, joiner: request.publicKey, shower: privateKey.publicKey.rawRepresentation)
        let sealed = try ChaChaPoly.seal(linkKey, using: wrapping).combined
        return try NearbyPairingGrant(publicKey: privateKey.publicKey.rawRepresentation, sealedLinkKey: sealed)
    }

    static func accept(_ grant: NearbyPairingGrant, joiner: Joiner, code: String) throws -> Data {
        guard NearbyPairingCode.isWellFormed(code) else { throw NearbyLinkKeyError.invalidCode }
        do {
            let showerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: grant.publicKey)
            let shared = try joiner.privateKey.sharedSecretFromKeyAgreement(with: showerKey)
            let wrapping = wrappingKey(shared, code: code, joiner: joiner.request.publicKey, shower: grant.publicKey)
            let key = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: grant.sealedLinkKey), using: wrapping)
            guard key.count == NearbyLinkKey.byteCount else { throw NearbyLinkKeyError.pairingFailed }
            return key
        } catch {
            throw NearbyLinkKeyError.pairingFailed
        }
    }

    private static func wrappingKey(_ shared: SharedSecret, code: String, joiner: Data, shower: Data) -> SymmetricKey {
        var info = Data("velvet-thorn-pair-grant-v1".utf8)
        info.append(joiner)
        info.append(shower)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: NearbyLinkKey.pairingPSK(code: code),
                                              sharedInfo: info, outputByteCount: 32)
    }
}
