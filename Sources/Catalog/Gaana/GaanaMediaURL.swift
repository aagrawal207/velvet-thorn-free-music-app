import CommonCrypto
import Foundation

/// Decrypts the `urls.<tier>.message` fields of Gaana's `song_detail` payload into HLS master playlist URLs.
enum GaanaMediaURL {
    /// The web player's fixed AES-128 key, shipped in its bundle as five Base64 fragments; it protects nothing.
    static let key = Data(base64Encoded: "Z3kxdCNiQGpsKGIkd3RtZQ==")!
    private static let hosts = ["akamaized.net", "gaana.com", "gaanacdn.com"]

    enum DecryptionError: Error, Equatable, Sendable { case invalidFormat, invalidBase64, cipherFailed(Int32), invalidURL }

    /// Message layout: one digit `p`, then `p - 1` filler characters, a 16-character ASCII IV at `p`, and Base64 ciphertext.
    static func decrypt(_ message: String) throws -> URL {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, let position = Int(String(first)), position >= 1,
              text.count > position + 16 else { throw DecryptionError.invalidFormat }
        let ivStart = text.index(text.startIndex, offsetBy: position)
        let ivEnd = text.index(ivStart, offsetBy: 16)
        let iv = Data(text[ivStart..<ivEnd].utf8)
        guard iv.count == kCCBlockSizeAES128, let cipherText = Data(base64Encoded: String(text[ivEnd...])),
              !cipherText.isEmpty, cipherText.count % kCCBlockSizeAES128 == 0 else { throw DecryptionError.invalidBase64 }
        let plain = try crypt(cipherText, iv: iv, operation: CCOperation(kCCDecrypt))
        guard let string = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string), isMediaHost(url) else { throw DecryptionError.invalidURL }
        return url
    }

    /// The inverse operation, used by tests to build vectors without shipping real ciphertext. `iv` must be 16 ASCII bytes.
    static func encrypt(_ url: URL, iv: String = "0123456789abcdef", filler: String = "xy") throws -> String {
        let ivData = Data(iv.utf8)
        guard ivData.count == kCCBlockSizeAES128, (1...9).contains(filler.count + 1) else { throw DecryptionError.invalidFormat }
        let cipherText = try crypt(Data(url.absoluteString.utf8), iv: ivData, operation: CCOperation(kCCEncrypt))
        return "\(filler.count + 1)\(filler)\(iv)\(cipherText.base64EncodedString())"
    }

    private static func crypt(_ input: Data, iv: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress, inputBytes.baseAddress, input.count,
                                outputBytes.baseAddress, outputBytes.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw DecryptionError.cipherFailed(status) }
        return output.prefix(moved)
    }

    /// Streams live on Akamai (`vodhlsgaana-*.akamaized.net`); previews on `streams.gaana.com`.
    static func isMediaHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// HLS variants the details call names; `auto` is the adaptive ladder (16, 64 and 128 kbps) and is not selected.
    enum Tier: String, CaseIterable, Comparable, Sendable {
        case high, medium

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.bitRate < rhs.bitRate }

        /// Observed master playlists: `high` 128 kbps and `medium` 64 kbps AAC-LC, 44.1 kHz stereo.
        var bitRate: Int {
            switch self {
            case .high: 128_000
            case .medium: 64_000
            }
        }

        var quality: SourceAudioQuality {
            SourceAudioQuality(codec: .aac, bitRate: bitRate, sampleRate: 44_100, channels: 2)
        }
    }

    /// Tiers at or under the listener's ceiling, highest first; a ceiling under every tier keeps the lowest one.
    static func candidates(available: Set<Tier>, maximumBitRate: Int?) -> [Tier] {
        let tiers = Tier.allCases.filter(available.contains).sorted(by: >)
        guard let maximumBitRate else { return tiers }
        let allowed = tiers.filter { $0.bitRate <= maximumBitRate }
        return allowed.isEmpty ? [tiers.last].compactMap { $0 } : allowed
    }
}
