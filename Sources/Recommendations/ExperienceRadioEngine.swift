import Foundation

struct ExperienceRadioEngine: Sendable {
    static let maximumConcurrentRequests = 3
    static let maximumSeedSearches = 6
    static let maximumRadioSeeds = 4
    static let queueLimit = 24
    static let minimumQueueSize = 4
    static let artistLimit = 4
    static let setupCandidatesPerArtist = 3
    static let setupReleaseBrowseLimit = 2
    static let maximumHintSeeds = 2
    static let maximumStyleQueries = 2
    static let maximumStylePlaylists = 2
    static let maximumDateArtists = 2
    static let maximumRadioRequests = 10
    static let artistHintTimeout: TimeInterval = 2
    static let requestTimeout: TimeInterval = 6
    static let startTimeout: TimeInterval = 30

    let catalog: any MusicCatalogProviding

    struct Bucket: Sendable {
        let anchor: Track
        var frontier: Track
    }

    struct Batch: Sendable {
        let tracks: [Track]
        let buckets: [Bucket]
        // Late dislikes must not leave a queue made only from fixed cue songs.
        var discoveryTrackIDs: Set<String> = []
    }

    func start(_ experience: RadioExperience, disliked: [DislikedSong],
               languages: Set<MusicLanguage> = Set(MusicLanguage.allCases)) async throws -> Batch {
        guard let selection = experience.selection(for: languages) else { throw ExperienceRadioError.noMatchingLanguages }
        do {
            return try await PlaybackDeadline.run(seconds: Self.startTimeout) {
                try await startWithinBudget(experience, selection: selection, disliked: disliked, languages: languages)
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw (error as? ExperienceRadioError) ?? ExperienceRadioError.unavailable
        }
    }

    private func startWithinBudget(_ experience: RadioExperience, selection: RadioExperience.Selection,
                                   disliked: [DislikedSong], languages: Set<MusicLanguage>) async throws -> Batch {
        let intents = Array(selection.seeds.prefix(Self.maximumSeedSearches))
        let pages = try await fetch(intents.map(Request.search))
        let matched = zip(intents, pages).compactMap {
            Self.matchedSeed($0, in: $1 ?? [], disliked: disliked, languages: languages)
        }
        let styleSeeds = try await datedTracks(matched, intents: intents, era: experience.defaultEra,
                                              disliked: disliked, languages: languages)
        var hints = RadioConfiguration(station: experience, languages: languages)
        hints.era = experience.defaultEra
        hints.artists = experience.artistHints.filter { artist in !styleSeeds.contains { Self.isCredited($0, to: artist) } }
        let resolvedHints = try await resolveArtists(hints, disliked: disliked, excludingQueries: Set(intents.map(\.query)))
        let hintSeeds = styleSeeds.filter { track in experience.artistHints.contains { Self.isCredited(track, to: $0) } }
            + resolvedHints.flatMap(\.seeds).compactMap(\.recording)
        // Missing cue songs should trigger mood discovery before an artist hint defines the whole station.
        let initial = styleSeeds.isEmpty ? []
            : Self.startingSeeds(style: styleSeeds, hints: hintSeeds, excluding: [], disliked: disliked, languages: languages)
        var lanes = try await radioLanes(initial, remainingBudget: Self.maximumRadioRequests)
        if let batch = Self.startingBatch(lanes: lanes, styleTracks: [], disliked: disliked, languages: languages) { return batch }

        let styleTracks = try await discoverStyle(selection, era: experience.defaultEra, disliked: disliked, languages: languages)
        if let batch = Self.startingBatch(lanes: lanes, styleTracks: styleTracks, disliked: disliked, languages: languages) { return batch }
        let fallbackSeeds = try await datedTracks(styleTracks, intents: intents, era: experience.defaultEra,
                                                 disliked: disliked, languages: languages)
        let attempted = Set(lanes.map(\.anchor.id))
        let alternatives = Self.startingSeeds(style: fallbackSeeds + styleSeeds, hints: hintSeeds, excluding: attempted,
                                             disliked: disliked, languages: languages)
        lanes += try await radioLanes(alternatives, remainingBudget: Self.maximumRadioRequests - lanes.count)
        if let batch = Self.startingBatch(lanes: lanes, styleTracks: styleTracks, disliked: disliked, languages: languages) { return batch }

        // Valid catalog audio can still be unusable here, so recovery must not replay the same cached response.
        let retries = try await radioLanes(Array(lanes.prefix(2).map(\.anchor)), remainingBudget: Self.maximumRadioRequests - lanes.count,
                                          forceRefresh: true)
        for retry in retries {
            if let index = lanes.firstIndex(where: { $0.anchor.id == retry.anchor.id }) {
                lanes[index].tracks = Self.selection(buckets: [retry.tracks, lanes[index].tracks], disliked: disliked,
                                                    limit: 60, languages: languages).tracks
            }
        }
        if let batch = Self.startingBatch(lanes: lanes, styleTracks: styleTracks, disliked: disliked, languages: languages) { return batch }
        throw lanes.isEmpty ? ExperienceRadioError.noSeeds : ExperienceRadioError.unavailable
    }

    private static func startingSeeds(style: [Track], hints: [Track], excluding: Set<String>,
                                      disliked: [DislikedSong], languages: Set<MusicLanguage>) -> [Track] {
        let defaults = RecommendationEngine.select(style.filter { !excluding.contains($0.id) }, limit: 24, artistCap: 1)
        let preferred = RecommendationEngine.select(hints.filter { !excluding.contains($0.id) }, limit: maximumHintSeeds, artistCap: 1)
        let ordered = selection(buckets: [defaults, preferred], disliked: disliked, limit: 24, languages: languages).tracks
        return RecommendationEngine.select(ordered, limit: maximumRadioSeeds, artistCap: 1)
    }

    private func radioLanes(_ seeds: [Track], remainingBudget: Int, forceRefresh: Bool = false) async throws -> [(anchor: Track, tracks: [Track])] {
        let bounded = Array(seeds.prefix(max(0, min(Self.maximumRadioSeeds, remainingBudget))))
        let pages = try await fetch(bounded.map { Request.radio($0, forceRefresh: forceRefresh) })
        return zip(bounded, pages).map { (anchor: $0, tracks: Array(($1 ?? []).prefix(60))) }
    }

    private static func startingBatch(lanes: [(anchor: Track, tracks: [Track])], styleTracks: [Track],
                                      disliked: [DislikedSong], languages: Set<MusicLanguage>) -> Batch? {
        // Genre results can fill the queue, but a verified starting seed still anchors the session.
        guard !lanes.isEmpty else { return nil }
        let anchors = Set(lanes.map(\.anchor.id))
        let useful = lanes.map { lane in
            lane.tracks.contains { !anchors.contains($0.id) && isUsable($0, languages: languages) && !isDisliked($0, disliked: disliked) }
        }
        let ranked = lanes.enumerated().sorted {
            if useful[$0.offset] != useful[$1.offset] { return useful[$0.offset] }
            return $0.offset < $1.offset
        }.map(\.element)
        let pools = ranked.map { [$0.anchor] + $0.tracks } + [styleTracks]
        let picks = selection(buckets: pools, disliked: disliked, languages: languages)
        let discoveryIDs = Set(lanes.flatMap(\.tracks).map(\.id)).subtracting(anchors).union(styleTracks.map(\.id))
        guard picks.tracks.count >= minimumQueueSize, picks.tracks.contains(where: { discoveryIDs.contains($0.id) }) else { return nil }
        let ids = Set(picks.tracks.map(\.id))
        let buckets = ranked.enumerated().compactMap { index, lane -> Bucket? in
            guard ids.contains(lane.anchor.id) else { return nil }
            return Bucket(anchor: lane.anchor, frontier: picks.lastByBucket[index] ?? lane.anchor)
        }
        guard !buckets.isEmpty else { return nil }
        return Batch(tracks: picks.tracks, buckets: Array(buckets.prefix(maximumRadioSeeds)), discoveryTrackIDs: discoveryIDs)
    }

    func continueRadio(buckets: [Bucket], round: Int, queue: [Track], disliked: [DislikedSong],
                       languages: Set<MusicLanguage> = Set(MusicLanguage.allCases), experience: RadioExperience? = nil,
                       forceRefresh: Bool = false) async throws -> Batch {
        let eligible = Array(buckets.filter {
            Self.isUsable($0.anchor, languages: languages) && !Self.isDisliked($0.anchor, disliked: disliked)
        }.prefix(Self.maximumRadioSeeds))
        guard !eligible.isEmpty else { throw ExperienceRadioError.noSeeds }
        // Each lane stays rooted in its own station seed. Revisit one anchor per round to limit gradual drift.
        let anchorIndex = max(0, round) % eligible.count
        let requests = eligible.enumerated().map { index, bucket in
            let revisitAnchor = eligible.count == 1 ? max(0, round).isMultiple(of: 4) : index == anchorIndex
            return Request.radio(revisitAnchor || !Self.isUsable(bucket.frontier, languages: languages)
                                 || Self.isDisliked(bucket.frontier, disliked: disliked)
                                 ? bucket.anchor : bucket.frontier, forceRefresh: forceRefresh)
        }
        let radios = try await fetch(requests)
        var selection = Self.selection(buckets: radios.map { $0 ?? [] }, excluding: queue, disliked: disliked, languages: languages)
        if selection.tracks.isEmpty, eligible.count == 1, case .radio(let requested, _) = requests[0],
           requested.id != eligible[0].frontier.id, Self.isUsable(eligible[0].frontier, languages: languages),
           !Self.isDisliked(eligible[0].frontier, disliked: disliked) {
            let frontier = try await fetch([.radio(eligible[0].frontier, forceRefresh: forceRefresh)])
            selection = Self.selection(buckets: frontier.map { $0 ?? [] }, excluding: queue, disliked: disliked, languages: languages)
        }
        if selection.tracks.isEmpty, let intent = experience?.selection(for: languages) {
            let related = try await discoverStyle(intent, era: .anytime, disliked: disliked, languages: languages)
            let pools = eligible.indices.map { lane in
                related.enumerated().filter { $0.offset % eligible.count == lane }.map(\.element)
            }
            selection = Self.selection(buckets: pools, excluding: queue, disliked: disliked, languages: languages)
        }
        guard !selection.tracks.isEmpty else { throw ExperienceRadioError.unavailable }
        let advanced = eligible.enumerated().map { index, bucket in
            Bucket(anchor: bucket.anchor, frontier: selection.lastByBucket[index] ?? bucket.frontier)
        }
        return Batch(tracks: selection.tracks, buckets: advanced)
    }

    static func matchedSeed(_ seed: RadioExperience.Seed, in tracks: [Track], disliked: [DislikedSong],
                            languages: Set<MusicLanguage> = []) -> Track? {
        let title = SearchRelevance.normalize(SongTitle.core(seed.title))
        let matches = tracks.filter { track in
            isUsable(track, languages: languages) && SearchRelevance.normalize(SongTitle.core(track.title)) == title
                && isCredited(track, to: seed.artist)
                && !isDisliked(track, disliked: disliked)
        }
        // Prefer the requested recording when the provider also offers a live take or a remaster.
        return matches.first { SearchRelevance.normalize($0.title) == SearchRelevance.normalize(seed.title) } ?? matches.first
    }

    static func isUsable(_ track: Track, languages: Set<MusicLanguage> = []) -> Bool {
        track.isAudioRecording == true && !track.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !SongTitle.core(track.title).isEmpty && RecommendationEngine.isRecommendable(track, languages: languages)
    }

    static func isDisliked(_ track: Track, disliked: [DislikedSong]) -> Bool {
        let core = SongTitle.core(track.title)
        return disliked.contains { $0.id == track.id || (!core.isEmpty && SongTitle.core($0.title) == core) }
    }

    static func isCredited(_ track: Track, to artist: ArtistCredit) -> Bool {
        track.credits.contains { credit in
            if let id = artist.id, credit.id == id { return true }
            return SearchRelevance.similarity(credit.name, artist.name) >= SearchRelevance.sameArtistThreshold
        }
    }

    // MARK: Style discovery and recording dates

    private func discoverStyle(_ selection: RadioExperience.Selection, era: RadioEra,
                               disliked: [DislikedSong], languages: Set<MusicLanguage>) async throws -> [Track] {
        let suffix = switch era { case .anytime: ""; case .older: " before 2000"; case .newer: " 2015 and later" }
        let queries = Array(selection.styleQueries.prefix(Self.maximumStyleQueries)).map { $0 + suffix }
        let requests = queries.flatMap { query in [(query, SearchFilter.songs), (query, SearchFilter.playlists)] }
        let pages = try await boundedMap(requests) { query, filter -> CatalogPage? in
            do { return try await request { try await catalog.search(query: query, filter: filter, continuation: nil) } }
            catch { try Task.checkCancellation(); if error is CancellationError { throw error }; return nil }
        }
        var seen = Set<String>()
        let playlists = Array(pages.compactMap { $0 }.flatMap(\.collections).filter {
            ($0.kind == .playlist || $0.kind == .mix) && !$0.id.isEmpty && seen.insert($0.id).inserted
        }.prefix(Self.maximumStylePlaylists))
        let collections = try await boundedMap(playlists) { collection -> CatalogPage? in
            if !collection.tracks.isEmpty { return CatalogPage(tracks: Array(collection.tracks.prefix(60))) }
            do { return try await request { try await catalog.browse(id: collection.id) } }
            catch { try Task.checkCancellation(); if error is CancellationError { throw error }; return nil }
        }
        return Self.selection(buckets: (pages + collections).compactMap { $0?.tracks }, disliked: disliked,
                              limit: 60, languages: languages).tracks
    }

    private func datedTracks(_ tracks: [Track], intents: [RadioExperience.Seed], era: RadioEra,
                             disliked: [DislikedSong], languages: Set<MusicLanguage>) async throws -> [Track] {
        // Year words in a query narrow discovery; only recording or matching album metadata proves the era.
        let eligible = Self.selection(buckets: [tracks], disliked: disliked, limit: 60, languages: languages).tracks
        guard era != .anytime else { return eligible }
        var seen = Set<String>()
        let artistIDs = Array(eligible.filter { Self.knownOriginal($0, intents: intents) == nil }.compactMap(\.artistID)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(Self.maximumDateArtists))
        let responses = try await boundedMap(artistIDs) { id -> ArtistPage? in
            do {
                let page = try await request { try await catalog.artist(id: id) }
                return page.id == id ? page : nil
            } catch { try Task.checkCancellation(); if error is CancellationError { throw error }; return nil }
        }
        let pages = responses.compactMap { $0 }
        var dated: [Track] = []
        for track in eligible {
            try Task.checkCancellation()
            if let original = Self.knownOriginal(track, intents: intents) {
                if era.accepts(year: original.year) { dated.append(track) }
                continue
            }
            for page in pages where track.credits.contains(where: { $0.id == page.id }) {
                var recording = track
                if let sameID = page.topSongs.first(where: { $0.id == track.id }) { recording.adoptMissingMetadata(from: sameID) }
                guard let albumID = recording.albumID,
                      let album = page.releases.prefix(30).first(where: { $0.kind == .album && $0.id == albumID }),
                      era != .newer || !Self.isReissue(album) else { continue }
                let year = await ReleaseWatcher.releaseYear(from: album.subtitle)
                if era.accepts(year: year) { dated.append(recording); break }
            }
        }
        return dated
    }

    private static func knownOriginal(_ track: Track, intents: [RadioExperience.Seed] = []) -> RadioExperience.Seed? {
        guard canUseOriginalYear(for: track.title) else { return nil }
        return (intents + RadioExperience.stations.flatMap(\.seeds)).first {
            $0.year != nil && $0.yearSource != nil && SongTitle.isVersion(track.title, of: $0.title) && isCredited(track, to: $0.artist)
        }
    }

    // MARK: Optional artist hints

    func resolveArtists(_ configuration: RadioConfiguration, disliked: [DislikedSong],
                        excludingQueries: Set<String> = []) async throws -> [RadioArtistResolution] {
        guard !configuration.languages.isEmpty else { return [] }
        var seen = Set<String>()
        let artists = Array(configuration.artists.filter {
            !RadioConfiguration.artistKey($0).isEmpty && seen.insert(RadioConfiguration.artistKey($0)).inserted
        }.prefix(RadioConfiguration.maximumArtists))
        return try await boundedMap(artists) { artist in
            do {
                // Optional hints get a short budget so slow artist or album lookups cannot exhaust startup.
                return try await PlaybackDeadline.run(seconds: Self.artistHintTimeout) {
                    try await resolveArtist(artist, configuration: configuration, disliked: disliked, excludingQueries: excludingQueries)
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                return RadioArtistResolution(artist: artist, seeds: [], error: error.localizedDescription)
            }
        }
    }

    private func resolveArtist(_ artist: ArtistCredit, configuration: RadioConfiguration,
                               disliked: [DislikedSong], excludingQueries: Set<String>) async throws -> RadioArtistResolution {
        let curated = (configuration.station.selection(for: configuration.languages)?.seeds ?? []).filter {
            RadioConfiguration.artistKey($0.artist) == RadioConfiguration.artistKey(artist)
                && !excludingQueries.contains($0.query)
                && (configuration.era == .anytime || ($0.yearSource != nil && configuration.era.accepts(year: $0.year)))
        }
        var seeds: [RadioExperience.Seed] = []
        var lastError: String?
        for intent in curated.prefix(2) {
            do {
                let page = try await request { try await catalog.search(query: intent.query, filter: .songs, continuation: nil) }
                try Task.checkCancellation()
                let originals = page.tracks.filter { Self.canUseOriginalYear(for: $0.title) }
                if let track = Self.matchedSeed(intent, in: originals, disliked: disliked, languages: configuration.languages) {
                    seeds.append(.init(recording: track, artist: artist, year: intent.year, yearSource: intent.yearSource))
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                lastError = error.localizedDescription
            }
        }
        if !seeds.isEmpty { return RadioArtistResolution(artist: artist, seeds: seeds) }

        let linked: ArtistCredit
        if let id = artist.id, !id.isEmpty {
            linked = artist
        } else {
            let page = try await request { try await catalog.search(query: artist.name, filter: .artists, continuation: nil) }
            try Task.checkCancellation()
            let exact = page.collections.filter {
                !$0.id.isEmpty && SearchRelevance.similarity($0.title, artist.name) >= SearchRelevance.sameArtistThreshold
            }
            guard let match = SearchRelevance.matchedArtist(in: exact, query: artist.name) else {
                throw MusicServiceError.unavailable("Couldn’t find an artist page for \(artist.name).")
            }
            linked = ArtistCredit(name: match.title, id: match.id)
        }
        guard let artistID = linked.id else { throw MusicServiceError.invalidResponse }
        let page = try await request { try await catalog.artist(id: artistID) }
        try Task.checkCancellation()
        guard page.id == artistID else { throw MusicServiceError.invalidResponse }

        if configuration.era == .anytime {
            seeds = Self.setupSeeds(page.topSongs, artist: linked, languages: configuration.languages, era: .anytime,
                                    disliked: disliked, release: nil, year: nil)
            if !seeds.isEmpty { return RadioArtistResolution(artist: artist, seeds: seeds) }
        }

        var releases: [(collection: MusicCollection, year: Int?)] = []
        var releaseIDs = Set<String>()
        for release in page.releases.prefix(30) where release.kind == .album && !release.id.isEmpty {
            guard releaseIDs.insert(release.id).inserted else { continue }
            let year = await ReleaseWatcher.releaseYear(from: release.subtitle)
            guard configuration.era.accepts(year: year),
                  configuration.era != .newer || !Self.isReissue(release) else { continue }
            releases.append((release, year))
        }
        if configuration.era != .anytime {
            releases.sort { left, right in
                let a = left.year ?? 0
                let b = right.year ?? 0
                if a == b { return left.collection.id < right.collection.id }
                return configuration.era == .older ? a < b : a > b
            }
        }
        for release in releases {
            let matching = page.topSongs.filter { $0.albumID == release.collection.id }
            seeds += Self.setupSeeds(matching, artist: linked, languages: configuration.languages, era: configuration.era,
                                     disliked: disliked, release: release.collection, year: release.year)
        }
        if !seeds.isEmpty {
            return RadioArtistResolution(artist: artist, seeds: Self.uniqueSetupSeeds(seeds))
        }

        for release in releases.prefix(Self.setupReleaseBrowseLimit) {
            do {
                let album = try await request { try await catalog.browse(id: release.collection.id) }
                try Task.checkCancellation()
                seeds += Self.setupSeeds(album.tracks, artist: linked, languages: configuration.languages, era: configuration.era,
                                         disliked: disliked, release: release.collection, year: release.year)
                if seeds.count >= Self.setupCandidatesPerArtist { break }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                lastError = error.localizedDescription
            }
        }
        return RadioArtistResolution(artist: artist, seeds: Self.uniqueSetupSeeds(seeds), error: seeds.isEmpty ? lastError : nil)
    }

    private static func setupSeeds(_ tracks: [Track], artist: ArtistCredit, languages: Set<MusicLanguage>, era: RadioEra,
                                   disliked: [DislikedSong], release: MusicCollection?, year: Int?) -> [RadioExperience.Seed] {
        let seeds = tracks.prefix(60).filter {
            isUsable($0, languages: languages) && isCredited($0, to: artist) && !isDisliked($0, disliked: disliked)
                && (release == nil || $0.albumID == nil || $0.albumID == release?.id)
        }
            .compactMap { track -> RadioExperience.Seed? in
                let original = knownOriginal(track)
                let date = original?.year ?? year
                guard era.accepts(year: date) else { return nil }
                let source = original?.yearSource ?? release.flatMap { URL(string: "https://music.youtube.com/browse/\($0.id)") }
                return .init(recording: track, artist: artist, year: date, yearSource: source)
            }
        return uniqueSetupSeeds(seeds)
    }

    private static func uniqueSetupSeeds(_ seeds: [RadioExperience.Seed]) -> [RadioExperience.Seed] {
        var ids = Set<String>()
        var titles = Set<String>()
        return Array(seeds.filter { seed in
            guard let recording = seed.recording, !ids.contains(recording.id), !titles.contains(SongTitle.core(recording.title)) else { return false }
            ids.insert(recording.id)
            titles.insert(SongTitle.core(recording.title))
            return true
        }.prefix(setupCandidatesPerArtist))
    }

    private static func canUseOriginalYear(for title: String) -> Bool {
        title.range(of: #"(?i)(?:[(\[][^)\]]*|\s[-–—|]\s.*)\b(?:live|acoustic|remix|cover|re-record|rerecord)"#,
                    options: .regularExpression) == nil
            && title.range(of: #"(?i)\b(?:live|acoustic|remix|cover|re-?record(?:ed|ing)?)(?:\s+(?:version|recording|edit))*\s*$"#,
                           options: .regularExpression) == nil
    }

    private static func isReissue(_ release: MusicCollection) -> Bool {
        let text = (release.title + " " + release.subtitle).lowercased()
        return ["remaster", "reissue", "anniversary", "greatest hits", "best of", "compilation", "expanded edition"].contains(where: text.contains)
    }

    struct Selection {
        var tracks: [Track] = []
        var lastByBucket: [Int: Track] = [:]
    }

    static func selection(buckets: [[Track]], excluding queue: [Track] = [], disliked: [DislikedSong],
                          limit: Int = queueLimit, languages: Set<MusicLanguage> = []) -> Selection {
        var selection = Selection()
        var ids = Set(queue.map(\.id)).union(disliked.map(\.id))
        var titles = Set((queue.map(\.title) + disliked.map(\.title)).map(SongTitle.core))
        var artistCounts: [String: Int] = [:]
        let pools = buckets.map { Array($0.prefix(60)) }
        var positions = [Int](repeating: 0, count: pools.count)
        while selection.tracks.count < max(0, limit) {
            var added = false
            for index in pools.indices where selection.tracks.count < limit {
                while positions[index] < pools[index].count {
                    let track = pools[index][positions[index]]
                    positions[index] += 1
                    let core = SongTitle.core(track.title)
                    let artist = RecommendationEngine.primaryArtistKey(track)
                    guard isUsable(track, languages: languages), !ids.contains(track.id), !titles.contains(core),
                          artistCounts[artist, default: 0] < artistLimit else { continue }
                    ids.insert(track.id)
                    titles.insert(core)
                    artistCounts[artist, default: 0] += 1
                    selection.tracks.append(track)
                    selection.lastByBucket[index] = track
                    added = true
                    break
                }
            }
            if !added { break }
        }
        return selection
    }

    private enum Request: Sendable {
        case search(RadioExperience.Seed)
        case radio(Track, forceRefresh: Bool = false)
    }

    private func fetch(_ requests: [Request]) async throws -> [[Track]?] {
        try await boundedMap(requests) { try await response(to: $0) }
    }

    private func request<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let value = try await PlaybackDeadline.run(seconds: Self.requestTimeout, operation: operation)
        try Task.checkCancellation()
        return value
    }

    private func boundedMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var responses: [(Int, Output)] = []
            var next = min(inputs.count, Self.maximumConcurrentRequests)
            for index in 0..<next {
                group.addTask { (index, try await operation(inputs[index])) }
            }
            while let response = try await group.next() {
                try Task.checkCancellation()
                responses.append(response)
                if next < inputs.count {
                    let index = next
                    next += 1
                    group.addTask { (index, try await operation(inputs[index])) }
                }
            }
            return responses.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func response(to request: Request) async throws -> [Track]? {
        do {
            try Task.checkCancellation()
            let tracks: [Track]
            switch request {
            case .search(let seed):
                if let recording = seed.recording { tracks = [recording] }
                else { tracks = try await self.request { try await catalog.search(query: seed.query, filter: .songs, continuation: nil).tracks } }
            case .radio(let seed, let forceRefresh):
                tracks = try await self.request { try await catalog.radio(seed: seed, forceRefresh: forceRefresh) }
            }
            try Task.checkCancellation()
            return tracks
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return nil
        }
    }
}

enum ExperienceRadioError: LocalizedError, Equatable, Sendable {
    case noSeeds, tooFewSongs, unavailable, noMatchingLanguages

    var errorDescription: String? {
        switch self {
        case .noSeeds: "No starting songs matched these preferences. Try another era or try again."
        case .tooFewSongs: "Too few songs are available right now. Try again."
        case .unavailable: "Radio couldn’t load songs. Check your connection and try again."
        case .noMatchingLanguages: "This station isn’t in your discovery languages. Choose another radio."
        }
    }
}
