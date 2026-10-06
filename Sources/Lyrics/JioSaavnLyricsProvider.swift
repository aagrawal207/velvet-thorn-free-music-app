import Foundation

actor JioSaavnLyricsProvider: LyricsProviding {
    typealias Search = @Sendable (Track) async throws -> [Track]
    typealias Fetch = @Sendable (Track) async throws -> LyricsDocument

    private let search: Search
    private let fetch: Fetch
    private var activeLookups = 0

    init(catalog: JioSaavnCatalogService) {
        search = { track in
            try await catalog.search(query: "\(LyricsMatcher.cleanTitle(track.title, artists: track.artists)) \(track.artistName)",
                                     filter: .songs, continuation: nil).tracks
        }
        fetch = { track in
            let response: JioSaavnResponse
            do {
                response = try await catalog.transport.get(call: "lyrics.getLyrics", parameters: [("lyrics_id", track.providerID)],
                                                          ttl: JioSaavnTransport.detailsLifetime)
            } catch is JioSaavnTransport.APIFailure {
                try Task.checkCancellation()
                return LyricsDocument(trackID: track.id, kind: .unavailable, source: "JioSaavn")
            }
            try Task.checkCancellation()
            return try Self.document(response, for: track)
        }
    }

    init(search: @escaping Search, fetch: @escaping Fetch) {
        self.search = search
        self.fetch = fetch
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try Task.checkCancellation()
        guard activeLookups < 2 else { throw LyricsLookupError.sourcesFailed }
        activeLookups += 1
        defer { activeLookups -= 1 }
        let recording: Track
        if track.source == .jioSaavn {
            guard MusicSource.entityKind(of: track.id) == .track, JioSaavnText.identifier(track.providerID) != nil else {
                throw LyricsLookupError.recordingMismatch
            }
            recording = track
        } else {
            guard LyricsMatcher.validDuration(track.duration) != nil else { return missing(track) }
            let candidates = try await search(track)
            try Task.checkCancellation()
            guard candidates.count <= 20 else { throw MusicServiceError.invalidResponse }
            var seen = Set<String>()
            let matches = candidates.filter { Self.matches($0, to: track) && seen.insert($0.id).inserted }
            // Similar releases are not proof of which recording supplied the text.
            guard matches.count == 1, let match = matches.first else { return missing(track) }
            recording = match
        }
        var document = try await fetch(recording)
        try Task.checkCancellation()
        try document.validateVariant(for: recording)
        guard document.source == "JioSaavn" else { throw MusicServiceError.invalidResponse }
        document.providerTrackID = recording.id
        document.trackID = track.id
        document.matchedTitle = recording.title
        document.matchedArtist = recording.artistName
        return document
    }

    nonisolated static func matches(_ candidate: Track, to track: Track) -> Bool {
        guard candidate.source == .jioSaavn, MusicSource.entityKind(of: candidate.id) == .track,
              JioSaavnText.identifier(candidate.providerID) != nil,
              candidate.isAudioRecording != false,
              LyricsMatcher.validDuration(candidate.duration) != nil,
              LyricsMatcher.validDuration(track.duration) != nil,
              LyricsRecordingIdentity.sameTitle(track.title, candidate.title, artists: track.artists),
              LyricsRecordingIdentity.sameArtists(track.artists, candidate.artists),
              LyricsRecordingIdentity.sameArtists(candidate.artists, track.artists) else { return false }
        if let expected = track.language, let actual = candidate.language, expected != actual { return false }
        let identity = LRCLIBRecord(id: 1, trackName: candidate.title, artistName: candidate.artistName,
                                    albumName: candidate.albumTitle, duration: candidate.duration, plainLyrics: "Identity check")
        return LyricsMatcher.evaluate(identity, for: track)?.isExact == true
    }

    nonisolated static func document(_ response: JioSaavnResponse, for track: Track) throws -> LyricsDocument {
        guard let raw = response.json["lyrics"].string, raw.utf8.count <= LRCParser.maximumSourceBytes else {
            throw MusicServiceError.invalidResponse
        }
        let text = JioSaavnParser.lyrics(response.json)
        let credit = JioSaavnText.clean(response.json["lyrics_copyright"].string)
        let document = LyricsDocument(trackID: track.id, kind: text == nil ? .unavailable : .plain,
            plainText: text, source: "JioSaavn", matchedTitle: track.title, matchedArtist: track.artistName,
            fetchedAt: response.fetchedAt, attributionText: credit, providerTrackID: track.id)
        try document.validateVariant(for: track)
        return document
    }

    private func missing(_ track: Track) -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .unavailable, source: "JioSaavn")
    }
}
