import XCTest
@testable import GanaBajana

/// Live search timing per stage (`GANABAJANA_LIVE_TESTS=1`, `GanaBajanaLive`); `SEARCHTIME` lines are printed and
/// attached. Nothing asserts on speed because the network is not under test.
final class SearchLatencyLiveTests: XCTestCase {
    private static let queries = ["Kesariya", "Blinding Lights", "Arijit Singh", "Shape of You", "Tum Hi Ho"]

    private func requireLiveTests() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set GANABAJANA_LIVE_TESTS=1 to time live searches.")
        }
    }

    private static func timed<T: Sendable>(_ body: () async throws -> T) async -> (ms: Int, value: T?) {
        let start = ContinuousClock.now
        let value = try? await body()
        return (Int(start.duration(to: .now) / .milliseconds(1)), value)
    }

    func testSearchStageTimings() async throws {
        try requireLiveTests()
        var lines: [String] = []
        for query in Self.queries {
            // Fresh services per query so the in-memory response cache never answers a timed request.
            let youTube = YouTubeMusicService()
            _ = await Self.timed { try await youTube.search(query: "warm up \(query.count)", filter: .albums, continuation: nil) }
            let songs = await Self.timed { try await youTube.search(query: query, filter: .songs, continuation: nil) }
            let repeatSongs = await Self.timed { try await youTube.search(query: query, filter: .songs, continuation: nil) }
            let fresh = YouTubeMusicService()
            _ = await Self.timed { try await fresh.search(query: "warm up \(query.count)", filter: .albums, continuation: nil) }
            let albums = await Self.timed { try await fresh.search(query: query, filter: .albums, continuation: nil) }
            let artists = await Self.timed { try await fresh.search(query: query, filter: .artists, continuation: nil) }
            var artistPageMs = -1
            var topSongsMs = -1
            var sameSongs = "n/a"
            if let match = artists.value.flatMap({ SearchRelevance.matchedArtist(in: $0.collections, query: query, correctedQuery: $0.correctedQuery) }) {
                let other = YouTubeMusicService()
                _ = await Self.timed { try await other.search(query: "warm up \(query.count)", filter: .albums, continuation: nil) }
                let top = await Self.timed { try await other.artistTopSongs(id: match.id) }
                topSongsMs = top.ms
                let full = await Self.timed { try await fresh.artist(id: match.id) }
                artistPageMs = full.ms
                sameSongs = String(top.value?.map(\.id) == full.value?.topSongs.map(\.id))
                    + "/\(top.value?.count ?? -1)vs\(full.value?.topSongs.count ?? -1)"
                    + "/durations=\(top.value?.allSatisfy { $0.duration != nil } ?? false)"
            }
            let saavn = await Self.timed { try await JioSaavnCatalogService().search(query: query, filter: .songs, continuation: nil) }
            let gaana = await Self.timed { try await GaanaCatalogService().search(query: query, filter: .songs, continuation: nil) }
            let compositeYouTube = YouTubeMusicService()
            _ = await Self.timed { try await compositeYouTube.search(query: "warm up \(query.count)", filter: .albums, continuation: nil) }
            let composite = CompositeCatalog(youTube: compositeYouTube,
                                             secondary: [.jioSaavn: JioSaavnCatalogService(), .gaana: GaanaCatalogService()])
            let merged = await Self.timed {
                try await CompositeCatalog.searchingAllSources { try await composite.search(query: query, filter: .songs, continuation: nil) }
            }
            let progressiveYouTube = YouTubeMusicService()
            _ = await Self.timed { try await progressiveYouTube.search(query: "warm up \(query.count)", filter: .albums, continuation: nil) }
            let progressive = CompositeCatalog(youTube: progressiveYouTube,
                                               secondary: [.jioSaavn: JioSaavnCatalogService(), .gaana: GaanaCatalogService()])
            let progressiveStart = ContinuousClock.now
            var firstMs = -1
            var updates = 0
            var trackCount = 0
            do {
                for try await update in await progressive.progressiveSearch(query: query, filter: .songs) {
                    updates += 1
                    switch update {
                    case .primary(let page):
                        firstMs = Int(progressiveStart.duration(to: .now) / .milliseconds(1))
                        trackCount += page.tracks.count
                    case .secondary(_, let page): trackCount += page.tracks.count
                    }
                }
            } catch { }
            let completeMs = Int(progressiveStart.duration(to: .now) / .milliseconds(1))
            lines.append("SEARCHTIME-PROGRESSIVE query=\"\(query)\" first=\(firstMs)ms complete=\(completeMs)ms updates=\(updates) tracks=\(trackCount)")
            lines.append("SEARCHTIME query=\"\(query)\" ytSongs=\(songs.ms)ms/\(songs.value?.tracks.count ?? -1) featured=\(songs.value?.featuredArtist != nil) "
                + "ytSongsCached=\(repeatSongs.ms)ms singleRequest(albums)=\(albums.ms)ms artistsSearch=\(artists.ms)ms artistPage=\(artistPageMs)ms topSongs=\(topSongsMs)ms same=\(sameSongs) "
                + "saavn=\(saavn.ms)ms/\(saavn.value?.tracks.count ?? -1) gaana=\(gaana.ms)ms/\(gaana.value?.tracks.count ?? -1) "
                + "composite=\(merged.ms)ms/\(merged.value?.tracks.count ?? -1)")
        }
        lines.forEach { print($0) }
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "search-latency"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertFalse(lines.isEmpty)
    }
}
