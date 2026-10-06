import Foundation

/// Public directory metadata, never a recording or a library-history identity.
struct LiveRadioStation: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let streamingURL: URL
    let homepageURL: URL?
    let artworkURL: URL?
    let countryCode: String
    let languages: [String]
    let tags: [String]
    let codec: String
    let isHLS: Bool

    var subtitle: String {
        ([countryCode.isEmpty ? nil : Locale.current.localizedString(forRegionCode: countryCode)]
            + languages.prefix(2).map { Optional($0) }).compactMap { $0 }.joined(separator: " · ")
    }

    var isValid: Bool {
        Self.validText(name, maximum: 256) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LiveRadioURLPolicy.permits(streamingURL)
            && (homepageURL.map(LiveRadioURLPolicy.permits) ?? true)
            && (artworkURL.map(LiveRadioURLPolicy.permits) ?? true)
            && (countryCode.isEmpty || (countryCode.utf8.count == 2 && countryCode.utf8.allSatisfy { (65...90).contains($0) }))
            && languages.count <= 16 && languages.allSatisfy { Self.validText($0, maximum: 64) }
            && tags.count <= 32 && tags.allSatisfy { Self.validText($0, maximum: 64) }
            && Self.supportedCodecs.contains(codec)
    }

    static let supportedCodecs: Set<String> = ["MP3", "AAC", "AAC+", "HE-AAC", "HE-AACV2"]

    static func validText(_ text: String, maximum: Int) -> Bool {
        text.utf8.count <= maximum && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Station hosts are independent of the music-provider allowlists; only public HTTPS names are eligible.
enum LiveRadioURLPolicy {
    static func permits(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 2_048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.port.map({ (1...65_535).contains($0) }) ?? true,
              let host = parts.host?.lowercased(), host.utf8.count <= 253,
              !host.hasSuffix("."), host.contains("."), !host.contains(":"),
              !["localhost", "local", "localdomain", "internal", "intranet", "corp", "lan", "home", "arpa", "onion", "test", "invalid"]
                .contains(host.split(separator: ".").last.map(String.init) ?? ""),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }), let tld = labels.last, tld.utf8.allSatisfy({ (97...122).contains($0) }), tld.count >= 2 else { return false }
        return true
    }
}
