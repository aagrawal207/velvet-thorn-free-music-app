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

    func load(_ artist: ArtistPage,
              onUpdate: @escaping @Sendable ([Track]) async -> Void = { _ in }) async throws -> Outcome {
        try Task.checkCancellation()
        let started = now()
        let deadline = started.addingTimeInterval(configuration.totalTimeout)
        let initial = ArtistSpotlight.mergedTracks(artist.topSongs)
        let trackLimit = initial.count + max(0, configuration.maximumAdditionalTracks)
        var tracks = initial
        var hadFailures = false
        var usedSupplement = false
        var countSearches = 0
        await onUpdate(ArtistSpotlight.sorted(tracks))

        do {
            if let artistName = CatalogText.clean(artist.name), tracks.count < configuration.minimumSongCount {
                var cursor: String?
                var visited = Set<String>()
                for _ in 0..<max(0, configuration.maximumArtistSearchPages) {
                    guard tracks.count < configuration.minimumSongCount, now() < deadline else { break }
                    usedSupplement = true
                    guard let page = try await response(to: .artistSongs(artistName, continuation: cursor), deadline: deadline) else {
                        hadFailures = true
                        break
                    }
                    tracks = supplement(tracks, with: page.tracks, artist: artist, limit: trackLimit)
                    try Task.checkCancellation()
                    await onUpdate(ArtistSpotlight.sorted(tracks))
                    guard let next = page.continuation, visited.insert(next).inserted else { break }
                    cursor = next
                }
            }

            if tracks.count < configuration.minimumSongCount, now() < deadline {
                let albums = Array(CatalogText.uniqueCollections(artist.releases.filter { $0.kind == .album })
                    .prefix(max(0, configuration.maximumAlbumRequests)))
                usedSupplement = usedSupplement || !albums.isEmpty
                let base = tracks
                try await withThrowingTaskGroup(of: (Int, CatalogPage?).self) { group in
                    var pages: [Int: [Track]] = [:]
                    var next = min(albums.count, concurrency)
                    for index in 0..<next {
                        group.addTask { (index, try await response(to: .album(albums[index].id), deadline: deadline)) }
                    }
                    while let (index, page) = try await group.next() {
                        try Task.checkCancellation()
                        if let page { pages[index] = page.tracks }
                        else { hadFailures = true }
                        let ordered = pages.keys.sorted().flatMap { pages[$0] ?? [] }
                        tracks = supplement(base, with: ordered, artist: artist, limit: trackLimit)
                        await onUpdate(ArtistSpotlight.sorted(tracks))
                        if next < albums.count, tracks.count < configuration.minimumSongCount, now() < deadline {
                            let index = next
                            next += 1
                            group.addTask { (index, try await response(to: .album(albums[index].id), deadline: deadline)) }
                        }
                    }
                }
            }

            // The listing's count wins. Search only fills missing counts on the exact provider ID,
            // with title and artist checks so covers, clips, and translated recordings cannot lend counts.
            let missing = Array(tracks.filter { ArtistSpotlight.availableCount($0) == nil }
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
                               let position = tracks.firstIndex(where: { $0.id == original.id }) {
                                tracks[position].playCount = count
                                await onUpdate(ArtistSpotlight.sorted(tracks))
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

        let ordered = ArtistSpotlight.sorted(tracks)
        let knownCounts = ordered.filter { ArtistSpotlight.availableCount($0) != nil }.count
        let milliseconds = Int(max(0, now().timeIntervalSince(started)) * 1_000)
        ArtistSpotlightDiagnostics.logger.info("catalogSuccess=\(hadFailures ? 0 : 1) catalogFailure=\(hadFailures ? 1 : 0) catalogCancelled=0 fallbackUsed=\(usedSupplement ? 1 : 0) countSearches=\(countSearches) knownCounts=\(knownCounts) songs=\(ordered.count) latencyMs=\(milliseconds)")
        return Outcome(tracks: ordered, hadFailures: hadFailures)
    }

    private var concurrency: Int { min(3, max(1, configuration.maximumConcurrentRequests)) }

    private func countQuery(_ track: Track, artist: ArtistPage) -> String {
        "\(LyricsMatcher.cleanTitle(track.title, artists: track.artists)) \(artist.name)"
    }

    private func supplement(_ tracks: [Track], with candidates: [Track], artist: ArtistPage, limit: Int) -> [Track] {
        let existing = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let matching = candidates.filter { ArtistSpotlight.credits(artist, on: $0) }.map { candidate in
            guard let original = existing[candidate.id], ArtistSpotlight.availableCount(original) == nil else { return candidate }
            var checked = candidate
            checked.playCount = ArtistSpotlight.matchingCount(for: original, in: [candidate], artist: artist)
            return checked
        }
        return Array(ArtistSpotlight.mergedTracks(tracks + matching).prefix(limit))
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
