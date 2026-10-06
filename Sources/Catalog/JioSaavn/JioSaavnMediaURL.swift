import CommonCrypto
import Foundation

/// Decrypts JioSaavn's `encrypted_media_url` and derives the bitrate tiers of the resulting CDN file name.
enum JioSaavnMediaURL {
    /// The provider's fixed DES key, published with every unofficial client; it protects nothing.
    static let key = Data("38346591".utf8)
    private static let hosts = ["saavncdn.com"]

    enum DecryptionError: Error, Equatable, Sendable { case invalidBase64, cipherFailed(Int32), invalidURL }

    static func decrypt(_ base64: String) throws -> URL {
        guard let cipherText = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              !cipherText.isEmpty, cipherText.count % kCCBlockSizeDES == 0 else { throw DecryptionError.invalidBase64 }
        let plain = try crypt(cipherText, operation: CCOperation(kCCDecrypt))
        guard let text = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), isMediaHost(url) else { throw DecryptionError.invalidURL }
        return url
    }

    /// The inverse operation, used by tests to build vectors without shipping real ciphertext.
    static func encrypt(_ url: URL) throws -> String {
        try crypt(Data(url.absoluteString.utf8), operation: CCOperation(kCCEncrypt)).base64EncodedString()
    }

    private static func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeDES)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeDES, nil, inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputBytes.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw DecryptionError.cipherFailed(status) }
        return output.prefix(moved)
    }

    static func isMediaHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Bitrate tiers the CDN publishes as `<name>_<kbps>.mp4`; 320 exists only when the catalog row says so.
    enum Tier: Int, CaseIterable, Comparable, Sendable {
        case kbps320 = 320, kbps160 = 160, kbps96 = 96, kbps48 = 48

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }

        var bitRate: Int { rawValue * 1_000 }

        var quality: SourceAudioQuality {
            SourceAudioQuality(codec: .aac, bitRate: bitRate, sampleRate: 44_100, channels: 2)
        }
    }

    /// Highest first. `has320` reflects the row's `320kbps` flag; every song publishes the lower tiers.
    static func tiers(has320: Bool) -> [Tier] {
        Tier.allCases.filter { has320 || $0 != .kbps320 }.sorted(by: >)
    }

    /// Tiers at or under the listener's ceiling, highest first; a ceiling under every tier keeps the lowest one.
    static func candidates(has320: Bool, maximumBitRate: Int?) -> [Tier] {
        let available = tiers(has320: has320)
        guard let maximumBitRate else { return available }
        let allowed = available.filter { $0.bitRate <= maximumBitRate }
        return allowed.isEmpty ? [available.last].compactMap { $0 } : allowed
    }

    /// Rewrites the decrypted `_96.mp4` (or any tier) file name to `tier`; nil when the name has no tier suffix.
    static func url(_ url: URL, tier: Tier) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension.lowercased() == "mp4", let underscore = name.lastIndex(of: "_"),
              Int(name[name.index(after: underscore)...]) != nil else { return nil }
        let renamed = String(name[..<underscore]) + "_\(tier.rawValue).mp4"
        return url.deletingLastPathComponent().appendingPathComponent(renamed)
    }
}
