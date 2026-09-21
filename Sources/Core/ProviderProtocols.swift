import Foundation

protocol MusicCatalogProviding: Sendable {
    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage
    func browse(id: String) async throws -> CatalogPage
    func artist(id: String) async throws -> ArtistPage
    /// A language-targeted mix seeded by `seed`, for Home surfaces that promise Hindi or English music.
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track]
    /// The provider's "listeners also play" queue for `seed`: audio recordings in provider order, seed excluded,
    /// with no language targeting. Autoplay uses this so an English song is followed by its own neighbors.
    func radio(seed: Track) async throws -> [Track]
    /// Consumer filters can exhaust a cached radio; recovery needs a fresh response while honoring provider cooldowns.
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track]
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection]
}

extension MusicCatalogProviding {
    /// Artist pages are browse pages whose rows are the artist's top songs and whose collections mix
    /// releases with related artists; providers with a richer artist endpoint override this.
    func artist(id: String) async throws -> ArtistPage {
        let page = try await browse(id: id)
        return ArtistPage(id: id, name: page.title ?? "", artworkURL: page.collections.first?.artworkURL,
                          topSongs: page.tracks,
                          releases: page.collections.filter { $0.kind == .album },
                          relatedArtists: page.collections.filter { $0.kind == .artist })
    }

    func radio(seed: Track) async throws -> [Track] {
        try await recommendations(seed: seed, language: seed.language ?? .english)
    }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        try Task.checkCancellation()
        let tracks = try await radio(seed: seed)
        try Task.checkCancellation()
        return tracks
    }
}

protocol MusicChartsProviding: Sendable {
    func weeklyChart(language: MusicLanguage) async throws -> ChartSnapshot
}

protocol LyricsProviding: Sendable {
    func lyrics(for track: Track) async throws -> LyricsDocument
}

/// Source encoding metadata is separate from YouTubeKit.Stream, whose signed URL must never enter a cache sidecar.
struct SourceAudioQuality: Codable, Equatable, Sendable {
    enum Codec: String, Codable, Sendable {
        case aac = "mp4a.40.2"
        case heAAC = "mp4a.40.5"
        case heAACv2 = "mp4a.40.29"
        case opus

        var title: String {
            switch self {
            case .aac: "AAC"
            case .heAAC: "HE-AAC"
            case .heAACv2: "HE-AAC v2"
            case .opus: "Opus"
            }
        }
    }

    let codec: Codec
    let bitRate: Int?
    let sampleRate: Int?
    let channels: Int?

    init(codec: Codec, bitRate: Int? = nil, sampleRate: Int? = nil, channels: Int? = nil) {
        self.codec = codec
        self.bitRate = Self.validBitRate(bitRate)
        self.sampleRate = sampleRate.flatMap { (8_000...192_000).contains($0) ? $0 : nil }
        self.channels = channels.flatMap { (1...8).contains($0) ? $0 : nil }
    }

    static func validBitRate(_ value: Int?) -> Int? {
        value.flatMap { (8_000...1_536_000).contains($0) ? $0 : nil }
    }

    static func preferredBitRate(average: Int?, advertised: Int?) -> Int? {
        validBitRate(average) ?? validBitRate(advertised)
    }

    /// Bitrate orders available encodings; it is not a perceptual equivalence between codecs.
    static func prefers(_ lhs: SourceAudioQuality?, over rhs: SourceAudioQuality?) -> Bool {
        let left = lhs?.bitRate ?? 0
        let right = rhs?.bitRate ?? 0
        if left != right { return left > right }
        return lhs?.codec != .opus && rhs?.codec == .opus
    }

    var summary: String {
        var parts = [bitRate.map { "\(Int((Double($0) / 1_000).rounded())) kbps \(codec.title)" } ?? codec.title]
        if let sampleRate {
            let rate = (Double(sampleRate) / 1_000).formatted(.number.grouping(.never).precision(.fractionLength(0...3)))
            parts.append("\(rate) kHz")
        }
        if let channels { parts.append(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels") }
        return parts.joined(separator: " · ")
    }

    private enum CodingKeys: String, CodingKey { case codec, bitRate, sampleRate, channels }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(codec: try values.decode(Codec.self, forKey: .codec),
                  bitRate: try values.decodeIfPresent(Int.self, forKey: .bitRate),
                  sampleRate: try values.decodeIfPresent(Int.self, forKey: .sampleRate),
                  channels: try values.decodeIfPresent(Int.self, forKey: .channels))
    }
}

struct ResolvedStream: Sendable {
    var url: URL
    var duration: TimeInterval?
    var expiresAt: Date?
    /// Provider loudness relative to its reference level, in dB. Positive means louder than reference.
    var loudnessDb: Double?
    /// Worldwide play count reported alongside the stream, when the provider includes it.
    var viewCount: Int64?
    var quality: SourceAudioQuality?

    init(url: URL, duration: TimeInterval? = nil, expiresAt: Date? = nil, loudnessDb: Double? = nil,
         viewCount: Int64? = nil, quality: SourceAudioQuality? = nil) {
        self.url = url
        self.duration = duration
        self.expiresAt = expiresAt
        self.loudnessDb = loudnessDb
        self.viewCount = viewCount
        self.quality = quality
    }
}

protocol StreamResolving: Sendable {
    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream
    func prefetch(_ tracks: [Track]) async
}

extension StreamResolving {
    func prefetch(_ tracks: [Track]) async { }
}
