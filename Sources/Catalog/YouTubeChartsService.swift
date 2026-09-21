import Foundation

actor YouTubeChartsService: MusicChartsProviding {
    /// Loads album-audio metadata (square artwork, album, duration) for video IDs; defaults to YouTube Music's get_queue.
    typealias MetadataLoader = @Sendable ([String]) async throws -> [Track]

    private let transport: CatalogTransport
    private let metadata: MetadataLoader

    init(session: URLSession = CatalogTransport.anonymousSession(), now: @escaping @Sendable () -> Date = { Date() },
         metadata: MetadataLoader? = nil) {
        self.transport = CatalogTransport(session: session, now: now)
        if let metadata {
            self.metadata = metadata
        } else {
            let catalog = YouTubeMusicService(session: session, now: now)
            self.metadata = { try await catalog.audioMetadata(for: $0) }
        }
    }

    func weeklyChart(language: MusicLanguage) async throws -> ChartSnapshot {
        try Task.checkCancellation()
        for region in language == .hindi ? ["in"] : ["us", "global"] {
            let response = try await fetch(region: region)
            var snapshot = try CatalogChartParser.parseSongChart(response.json, language: language, region: region, fetchedAt: response.fetchedAt)
            guard !snapshot.entries.isEmpty else { continue }
            snapshot.entries = try await enriched(snapshot.entries)
            try Task.checkCancellation()
            return snapshot
        }
        try Task.checkCancellation()
        throw MusicServiceError.unavailable("No matching album-audio recordings are available in the latest weekly song charts.")
    }

    /// Charts only expose a video frame per song; one get_queue batch supplies the square album art and album
    /// details. Ranks, titles, credits, and view counts stay the chart's own, and failures keep the frames.
    private func enriched(_ entries: [ChartEntry]) async throws -> [ChartEntry] {
        let ids = Array(entries.map(\.track.id).prefix(50))
        let byID: [String: Track]
        do {
            byID = Dictionary(try await metadata(ids).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return entries
        }
        return entries.map { entry in
            guard let extra = byID[entry.track.id], extra.isAudioRecording == true else { return entry }
            var track = entry.track
            track.artworkURL = extra.artworkURL ?? track.artworkURL
            track.albumTitle = extra.albumTitle ?? track.albumTitle
            track.albumID = extra.albumID ?? track.albumID
            track.duration = extra.duration ?? track.duration
            track.adoptMissingMetadata(from: extra)
            return ChartEntry(rank: entry.rank, track: track, views: entry.views, previousRank: entry.previousRank)
        }
    }

    private func fetch(region: String) async throws -> CatalogResponse {
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "perspective", value: "CHART_DETAILS"),
            URLQueryItem(name: "chart_params_country_code", value: region),
            URLQueryItem(name: "chart_params_chart_type", value: "TRACKS"),
            URLQueryItem(name: "chart_params_period_type", value: "WEEKLY"),
        ]
        guard let parameters = query.percentEncodedQuery else { throw MusicServiceError.invalidResponse }
        let body: CatalogJSON = [
            "browseId": "FEmusic_analytics_charts_home",
            "context": ["client": ["clientName": "WEB_MUSIC_ANALYTICS", "clientVersion": "2.0", "hl": "en", "gl": "US"]],
            "query": .string(parameters),
        ]
        return try await transport.post(baseURL: CatalogTransport.chartsURL, endpoint: "browse", body: body, ttl: 15 * 60)
    }
}
