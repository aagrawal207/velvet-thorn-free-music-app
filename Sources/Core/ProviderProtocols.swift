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

/// Optional discovery; existing consumers and providers keep the single-document contract.
protocol LyricsVariantsProviding: LyricsProviding {
    func lyricVariants(for track: Track) async throws -> [LyricsDocument]
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

    /// Playback order under an optional ceiling (`AudioQualityPreference.maximumBitRate`): fitting formats best first,
    /// then higher ones closest first so a song still plays when nothing fits; unknown bitrates cannot prove they fit.
    static func ranked<Candidate>(_ candidates: [Candidate], maximumBitRate: Int?,
                                  quality: (Candidate) -> SourceAudioQuality?) -> [Candidate] {
        let ordered = candidates.sorted { prefers(quality($0), over: quality($1)) }
        guard let maximumBitRate else { return ordered }
        var fitting: [Candidate] = [], above: [Candidate] = [], unknown: [Candidate] = []
        for candidate in ordered {
            guard let bitRate = quality(candidate)?.bitRate else { unknown.append(candidate); continue }
            if bitRate <= maximumBitRate { fitting.append(candidate) } else { above.append(candidate) }
        }
        let closest = above.sorted { lhs, rhs in
            let left = quality(lhs)?.bitRate ?? 0, right = quality(rhs)?.bitRate ?? 0
            if left != right { return left < right }
            return quality(lhs)?.codec != .opus && quality(rhs)?.codec == .opus
        }
        return fitting + closest + unknown
    }

    /// True when `quality` is allowed to play under the ceiling; an absent ceiling or unknown bitrate never blocks.
    static func fits(_ quality: SourceAudioQuality?, maximumBitRate: Int?) -> Bool {
        guard let maximumBitRate, let bitRate = quality?.bitRate else { return true }
        return bitRate <= maximumBitRate
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

    /// Acquisition provenance describes the playing bytes, never the catalog identity or measured output fidelity.
    static func playbackSummary(quality: SourceAudioQuality?, catalogSource: MusicSource?, playbackSource: MusicSource?) -> String {
        let encoding = quality?.summary ?? "Quality information unavailable"
        guard let playbackSource else { return encoding + " · Playback source unknown" }
        let provider = catalogSource == playbackSource ? playbackSource.title : "via \(playbackSource.title)"
        return encoding + " · " + provider
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
    /// Views of this recording/upload, not the provider's aggregate song plays. Cached streams retain old views.
    var viewCount: Int64?
    var quality: SourceAudioQuality?
    /// The provider that supplied these bytes; nil means unknown, including legacy cached copies.
    /// This is acquisition metadata, not a second catalog identity or a source inferred from the URL.
    var playbackSource: MusicSource?
    /// In-memory provenance of fresh YouTube extraction. Complete cached files cannot confirm compatibility updates.
    var extractionGeneration: UInt64?

    init(url: URL, duration: TimeInterval? = nil, expiresAt: Date? = nil, loudnessDb: Double? = nil,
         viewCount: Int64? = nil, quality: SourceAudioQuality? = nil, playbackSource: MusicSource? = nil,
         extractionGeneration: UInt64? = nil) {
        self.url = url
        self.duration = duration
        self.expiresAt = expiresAt
        self.loudnessDb = loudnessDb
        self.viewCount = viewCount
        self.quality = quality
        self.playbackSource = playbackSource
        self.extractionGeneration = extractionGeneration
    }
}

protocol StreamResolving: Sendable {
    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream
    func prefetch(_ tracks: [Track]) async
}

extension StreamResolving {
    func prefetch(_ tracks: [Track]) async { }
}
