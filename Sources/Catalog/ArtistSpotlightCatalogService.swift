import Foundation
import OSLog

enum ArtistSpotlightDiagnostics {
    static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "ArtistSpotlight")
}

struct ArtistSpotlightCatalogService: Sendable {
    struct Configuration: Sendable {
        var minimumSongCount = 20
        var maximumArtistSearchPages = 2
        var maximumAlbumRequests = 3
        var maximumAdditionalTracks = 100
        var maximumCountSearches = 20
        var maximumConcurrentRequests = 3
        var requestTimeout: TimeInterval = 10
        var totalTimeout: TimeInterval = 40
    }

    struct Outcome: Sendable {
        let tracks: [Track]
        let candidates: [Track]
        let hadFailures: Bool
    }

    private enum Request: Sendable {
        case artistSongs(String, continuation: String?)
        case album(String)
        case count(String)

        var operation: String {
            switch self {
            case .artistSongs: "artistSongs"
            case .album: "album"
            case .count: "count"
            }
        }
    }

    let catalog: any MusicCatalogProviding
    var configuration = Configuration()
    var now: @Sendable () -> Date = { Date() }

    // A single trailing closure observes display rows; raw snapshots require both labelled callbacks.
    func load(_ artist: ArtistPage,
              onUpdate: @escaping @Sendable ([Track]) async -> Void = { _ in }) async throws -> Outcome {
        try await load(artist, onCandidates: { _ in }, onUpdate: onUpdate)
    }

    func load(_ artist: ArtistPage, onCandidates: @escaping @Sendable ([Track]) async -> Void,
              onUpdate: @escaping @Sendable ([Track]) async -> Void) async throws -> Outcome {
        try Task.checkCancellation()
        let started = now()
        let deadline = started.addingTimeInterval(configuration.totalTimeout)
        let initial = ArtistSpotlight.mergedTracks(artist.topSongs)
        let additionalLimit = max(0, configuration.maximumAdditionalTracks)
        // The existing song and request budgets bound retained aliases, including aliases of a full listing.
        let requestBudget = max(0, configuration.maximumArtistSearchPages) + max(0, configuration.maximumAlbumRequests)
        let candidateLimit = initial.count + (initial.count + additionalLimit) * requestBudget
        var candidates = initial
        func display(_ candidates: [Track]) -> ArtistSpotlight.SongDisplay {
            ArtistSpotlight.displaySongs(candidates, artist: artist, maximumAdditionalTracks: additionalLimit)
        }
        func publish(_ candidates: [Track]) async {
            await onCandidates(candidates)
            await onUpdate(ArtistSpotlight.sorted(display(candidates).tracks))
        }
        var hadFailures = false
        var usedAlbumFallback = false
        var searchPages = 0
        var countSearches = 0
        await publish(candidates)

        do {
            // The provider's artist listing omits songs that credit the artist after another performer, so the
            // bounded search runs even for a full listing; only the album fallback waits for a sparse one.
            if let artistName = CatalogText.clean(artist.name) {
                var cursor: String?
                var visited = Set<String>()
                for _ in 0..<max(0, configuration.maximumArtistSearchPages) {
                    guard now() < deadline else { break }
                    searchPages += 1
                    guard let page = try await response(to: .artistSongs(artistName, continuation: cursor), deadline: deadline) else {
                        hadFailures = true
                        break
                    }
                    candidates = supplement(candidates, with: page.tracks, artist: artist, limit: candidateLimit)
                    try Task.checkCancellation()
                    await publish(candidates)
                    guard let next = page.continuation, visited.insert(next).inserted else { break }
                    cursor = next
                }
            }

            if display(candidates).tracks.count < configuration.minimumSongCount, now() < deadline {
                let albums = Array(CatalogText.uniqueCollections(artist.releases.filter { $0.kind == .album })
                    .prefix(max(0, configuration.maximumAlbumRequests)))
                usedAlbumFallback = !albums.isEmpty
                let base = candidates
                try await withThrowingTaskGroup(of: (Int, CatalogPage?).self) { group in
                    var pages: [Int: [Track]] = [:]
                    var next = min(albums.count, concurrency)
                    for index in 0..<next {
                        group.addTask { (index, try await response(to: .album(albums[index].id), deadline: deadline)) }
                    }
                    while let (index, page) = try await group.next() {
                        try Task.checkCancellation()
                        if let page { pages[index] = supplement(base, with: page.tracks, artist: artist, limit: candidateLimit) }
                        else { hadFailures = true }
                        let ordered = pages.keys.sorted().flatMap { pages[$0] ?? [] }
                        candidates = supplement(base, with: ordered, artist: artist, limit: candidateLimit)
                        await publish(candidates)
                        if next < albums.count, display(candidates).tracks.count < configuration.minimumSongCount, now() < deadline {
                            let index = next
                            next += 1
                            group.addTask { (index, try await response(to: .album(albums[index].id), deadline: deadline)) }
                        }
                    }
                }
            }

            // The listing's count wins. Search only fills missing counts on the exact provider ID,
            // with title and artist checks so covers, clips, and translated recordings cannot lend counts.
            let missing = Array(display(candidates).tracks.filter { ArtistSpotlight.availableCount($0) == nil }
                .prefix(max(0, configuration.maximumCountSearches)))
            if CatalogText.clean(artist.name) != nil, now() < deadline {
                try await withThrowingTaskGroup(of: (Int, CatalogPage?).self) { group in
                    var next = min(missing.count, concurrency)
                    for index in 0..<next {
                        countSearches += 1
                        group.addTask { (index, try await response(to: .count(countQuery(missing[index], artist: artist)), deadline: deadline)) }
                    }
                    while let (index, page) = try await group.next() {
                        try Task.checkCancellation()
                        let original = missing[index]
                        if let page {
                            if let count = ArtistSpotlight.matchingCount(for: original, in: page.tracks, artist: artist),
                               let position = candidates.firstIndex(where: { $0.id == original.id }) {
                                candidates[position].playCount = count
                                await publish(candidates)
                            }
                        } else { hadFailures = true }
                        if next < missing.count, now() < deadline {
                            let index = next
                            next += 1
                            countSearches += 1
                            group.addTask { (index, try await response(to: .count(countQuery(missing[index], artist: artist)), deadline: deadline)) }
                        }
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            ArtistSpotlightDiagnostics.logger.info("catalogSuccess=0 catalogFailure=0 catalogCancelled=1")
            throw error
        }

        let finalDisplay = display(candidates)
        let ordered = ArtistSpotlight.sorted(finalDisplay.tracks)
        let knownCounts = ordered.filter { ArtistSpotlight.availableCount($0) != nil }.count
        let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
        ArtistSpotlightDiagnostics.logger.info("catalogSuccess=\(hadFailures ? 0 : 1) catalogFailure=\(hadFailures ? 1 : 0) catalogCancelled=0 searchPages=\(searchPages) fallbackUsed=\(usedAlbumFallback ? 1 : 0) countSearches=\(countSearches) knownCounts=\(knownCounts) songs=\(ordered.count) displayAliases=\(finalDisplay.aliasCount) latencyMs=\(milliseconds)")
        return Outcome(tracks: ordered, candidates: candidates, hadFailures: hadFailures)
    }

    private var concurrency: Int { min(3, max(1, configuration.maximumConcurrentRequests)) }

    private func countQuery(_ track: Track, artist: ArtistPage) -> String {
        "\(LyricsMatcher.cleanTitle(track.title, artists: track.artists)) \(artist.name)"
    }

    // Retain source recordings rather than display winners so later pages can reconsider every release.
    private func supplement(_ tracks: [Track], with candidates: [Track], artist: ArtistPage, limit: Int) -> [Track] {
        let existing = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var retainedIDs = Set(existing.keys)
        let matching = candidates.filter {
            guard ArtistSpotlight.credits(artist, on: $0), $0.isAudioRecording != false,
                  CatalogText.clean($0.id) != nil, CatalogText.clean($0.title) != nil else { return false }
            if retainedIDs.contains($0.id) { return true }
            guard retainedIDs.count < limit else { return false }
            retainedIDs.insert($0.id)
            return true
        }.map { candidate in
            guard let original = existing[candidate.id], ArtistSpotlight.availableCount(original) == nil else { return candidate }
            var checked = candidate
            checked.playCount = ArtistSpotlight.matchingCount(for: original, in: [candidate], artist: artist)
            return checked
        }
        return ArtistSpotlight.mergedTracks(tracks + matching)
    }

    private func response(to request: Request, deadline: Date) async throws -> CatalogPage? {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { return nil }
        let started = now()
        do {
            let page = try await PlaybackDeadline.run(seconds: min(configuration.requestTimeout, remaining)) {
                switch request {
                case .artistSongs(let query, let continuation):
                    try await catalog.search(query: query, filter: .songs, continuation: continuation)
                case .album(let id): try await catalog.browse(id: id)
                case .count(let query): try await catalog.search(query: query, filter: .songs, continuation: nil)
                }
            }
            try Task.checkCancellation()
            let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
            ArtistSpotlightDiagnostics.logger.debug("operation=\(request.operation, privacy: .public) requestSuccess=1 requestFailure=0 timedOut=0 latencyMs=\(milliseconds)")
            return page
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let timedOut: Bool
            if let error = error as? PlaybackStreamError, case .timedOut = error { timedOut = true }
            else { timedOut = false }
            let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
            ArtistSpotlightDiagnostics.logger.info("operation=\(request.operation, privacy: .public) requestSuccess=0 requestFailure=1 timedOut=\(timedOut ? 1 : 0) latencyMs=\(milliseconds)")
            return nil
        }
    }
}
