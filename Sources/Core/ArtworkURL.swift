import Foundation

/// Rewrites provider artwork URLs to the pixel size a surface needs. Catalog responses carry small
/// thumbnails (60–120 px); Google user-content hosts accept size suffixes, YouTube's ytimg host only
/// serves fixed names, and some of those names do not exist for every recording.
enum ArtworkURL {
    enum Tier: Comparable, Sendable {
        case thumbnail, standard, large

        var pixels: Int {
            switch self {
            case .thumbnail: 120
            case .standard: 544
            case .large: 1080
            }
        }
    }

    /// Tier for a square displayed at `points` on a 3x display, with headroom for `scaledToFill` cropping.
    static func tier(forDisplaySize points: CGFloat) -> Tier {
        switch points {
        case ..<48: .thumbnail
        case ..<200: .standard
        default: .large
        }
    }

    /// Ordered candidates to try for `tier`; later entries are fallbacks for hosts that may 404 on the first.
    static func candidates(for url: URL, tier: Tier) -> [URL] {
        guard let host = url.host?.lowercased() else { return [url] }
        if host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") {
            return [sized(url, pixels: tier.pixels) ?? url]
        }
        if host == "i.ytimg.com" || host.hasSuffix(".ytimg.com") {
            let names: [String] = switch tier {
            case .thumbnail: ["mqdefault"]
            case .standard: ["hqdefault"]
            case .large: ["maxresdefault", "sddefault", "hqdefault"]
            }
            var seen = Set<String>()
            return names.compactMap { renamed(url, to: $0) }.filter { seen.insert($0.absoluteString).inserted }
                .ifEmpty([url])
        }
        return [url]
    }

    /// Preferred single URL for `tier`; the first candidate.
    static func preferred(_ url: URL, tier: Tier) -> URL {
        candidates(for: url, tier: tier).first ?? url
    }

    private static let sizeSuffix = try! NSRegularExpression(
        pattern: #"=(?:w\d+-h\d+|s\d+)((?:-[a-z]+\d*)*)$"#, options: [.caseInsensitive])

    private static func sized(_ url: URL, pixels: Int) -> URL? {
        let text = url.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        guard let match = sizeSuffix.firstMatch(in: text, range: range),
              let full = Range(match.range, in: text) else { return nil }
        // Keep the provider's crop/quality flags (for example "-p" smart crop on artist photos) and ensure "-rj".
        var flags = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        if !flags.split(separator: "-").contains(where: { $0.hasPrefix("l") && Int($0.dropFirst()) != nil }) { flags += "-l90" }
        if !flags.split(separator: "-").contains("rj") { flags += "-rj" }
        return URL(string: text[..<full.lowerBound] + "=w\(pixels)-h\(pixels)" + flags)
    }

    private static func renamed(_ url: URL, to name: String) -> URL? {
        var components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3, components[0] == "vi", let last = components.last, last.hasSuffix(".jpg") else { return nil }
        components[components.count - 1] = "\(name).jpg"
        var rebuilt = URLComponents(url: url, resolvingAgainstBaseURL: false)
        rebuilt?.path = "/" + components.joined(separator: "/")
        return rebuilt?.url
    }
}

private extension Array {
    func ifEmpty(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}
