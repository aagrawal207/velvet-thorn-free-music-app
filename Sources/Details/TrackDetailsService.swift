import Foundation
import OSLog

/// Supplies Song details for a track; the store is the real implementation and fixtures swap it out.
protocol TrackDetailsProviding: Sendable {
    func details(for track: Track, refresh: Bool) async -> TrackDetails?
}

/// Network side of Song details; the store calls it only on cache misses and explicit refreshes.
protocol TrackDetailsFetching: Sendable {
    func fetch(_ track: Track, refresh: Bool) async -> TrackDetails?
}

/// Combines the sources in order: YouTube's description (Data API, then the InnerTube player request),
/// then MusicBrainz for gaps. Only YouTube recordings get YouTube requests; other sources use MusicBrainz alone.
actor TrackDetailsService: TrackDetailsFetching {
    static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "SongDetails")
    private let dataAPI: YouTubeDataAPI?
    private let player: YouTubePlayerDetailsClient?
    private let musicBrainz: ArtistSpotlightMusicBrainz?
    private let now: @Sendable () -> Date

    init(dataAPI: YouTubeDataAPI?, player: YouTubePlayerDetailsClient?, musicBrainz: ArtistSpotlightMusicBrainz?,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.dataAPI = dataAPI
        self.player = player
        self.musicBrainz = musicBrainz
        self.now = now
    }

    func fetch(_ track: Track, refresh: Bool) async -> TrackDetails? {
        var details = TrackDetails(track: track, fetchedAt: now())
        var isArtTrack = false
        if track.source == .youTubeMusic, let videoID = CatalogText.videoID(track.providerID) {
            guard let video = await videoDetails(videoID, refresh: refresh, into: &details) else {
                if Task.isCancelled { return nil }
                return await enrich(details, track: track, isArtTrack: false)
            }
            if Task.isCancelled { return nil }
            details.channelTitle = video.channelTitle
            details.publishedAt = video.publishedAt
            details.viewCount = video.viewCount
            details.description = video.description
            if let parsed = ProvidedToYouTubeDescriptionParser.parse(video.description) {
                isArtTrack = true
                details.sources.insert(.youTubeDescription)
                details.credits = parsed.credits
                details.albumTitle = parsed.album ?? details.albumTitle
                details.releaseDateText = parsed.releasedOn
                details.releaseDate = parsed.releaseDate
                details.phonogramLine = parsed.phonogramLine
                details.copyrightLine = parsed.copyrightLine
            }
            let videoSource = details.sources.contains(.youTubeDataAPI) ? "dataapi" : "player"
            Self.logger.info("event=detailsDescription artTrack=\(isArtTrack ? 1 : 0) credits=\(details.displayCredits.count) source=\(videoSource, privacy: .public)")
        }
        return await enrich(details, track: track, isArtTrack: isArtTrack)
    }

    private func videoDetails(_ videoID: String, refresh: Bool, into details: inout TrackDetails) async -> YouTubeVideoDetails? {
        if let dataAPI {
            do {
                guard let metadata = try await dataAPI.metadata(for: videoID, refresh: refresh) else {
                    // The official API answered that the recording does not exist; the player cannot know better.
                    Self.logger.info("event=detailsVideoLookup source=dataapi outcome=missing")
                    return nil
                }
                details.sources.insert(.youTubeDataAPI)
                Self.logger.info("event=detailsVideoLookup source=dataapi outcome=success")
                return YouTubeVideoDetails(videoID: videoID, description: metadata.description, channelTitle: metadata.channelTitle,
                                           publishedAt: metadata.publishedAt, publishedAtText: nil, viewCount: metadata.viewCount)
            } catch is CancellationError {
                return nil
            } catch {
                let reason = (error as? YouTubeDataAPI.RequestError).map { "\($0)" } ?? "error"
                Self.logger.info("event=detailsVideoLookup source=dataapi outcome=failed reason=\(reason, privacy: .public)")
            }
        }
        guard !Task.isCancelled, let player else { return nil }
        do {
            let video = try await player.details(for: videoID, refresh: refresh)
            Self.logger.info("event=detailsVideoLookup source=player outcome=\(video == nil ? "missing" : "success")")
            if video != nil { details.sources.insert(.youTubePlayer) }
            return video
        } catch is CancellationError {
            return nil
        } catch {
            let reason = (error as? YouTubePlayerDetailsClient.RequestError).map { "\($0)" } ?? "error"
            Self.logger.info("event=detailsVideoLookup source=player outcome=failed reason=\(reason, privacy: .public)")
            return nil
        }
    }

    private func enrich(_ details: TrackDetails, track: Track, isArtTrack: Bool) async -> TrackDetails? {
        var details = details
        let needsMusicBrainz = !isArtTrack || details.displayCredits.isEmpty
        if needsMusicBrainz, let musicBrainz, !Task.isCancelled {
            do {
                if let found = try await musicBrainz.recordingDetails(for: track) {
                    var extra = TrackDetails(track: track, fetchedAt: details.fetchedAt)
                    extra.credits = found.credits
                    extra.albumTitle = found.releaseTitle
                    extra.releaseDate = found.releaseDate
                    extra.releaseDateText = found.releaseDateText
                    extra.isrc = found.isrc
                    extra.musicBrainzRecordingID = found.recordingID
                    extra.sources = [.musicBrainz]
                    details.fillMissing(from: extra)
                    Self.logger.info("event=detailsMusicBrainz matched=1 credits=\(found.credits.count)")
                } else {
                    Self.logger.info("event=detailsMusicBrainz matched=0 credits=0")
                }
            } catch is CancellationError {
                return nil
            } catch {
                Self.logger.info("event=detailsMusicBrainz matched=0 failed=1")
            }
        }
        guard !Task.isCancelled else { return nil }
        let outcome = details.hasContent ? "found" : "none"
        Self.logger.info("event=detailsFetched outcome=\(outcome, privacy: .public) sources=\(details.sources.count) credits=\(details.displayCredits.count) creditSource=\(details.creditSource.map { "\($0)" } ?? "none", privacy: .public)")
        return details.hasContent ? details : nil
    }
}
