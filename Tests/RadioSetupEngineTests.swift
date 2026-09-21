import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class RadioSetupEngineTests: XCTestCase {
    func testAnytimeUsesActualCreditedAudioAndFiltersDislikesLanguagesAndDuplicates() async throws {
        let artist = ArtistCredit(name: "Catalog Artist", id: "UCsetupArtist")
        let audio = RecommendationFixtures.track("audio", title: "First Song", artist: artist.name, artistID: artist.id, language: .english)
        let unknownLanguage = RecommendationFixtures.track("unknown-language", artist: artist.name, artistID: artist.id)
        let blocked = RecommendationFixtures.track("blocked", title: "Blocked Song", artist: artist.name)
        let duplicate = RecommendationFixtures.track("remaster", title: "First Song (Remastered)", artist: artist.name)
        let rows = [RecommendationFixtures.track("other-artist", artist: "Unrelated Singer"),
                    RecommendationFixtures.track("video", artist: artist.name, audio: false),
                    RecommendationFixtures.track("unverified", artist: artist.name, audio: nil),
                    RecommendationFixtures.track("hindi", artist: artist.name, language: .hindi),
                    blocked, audio, audio, duplicate, unknownLanguage]
        let catalog = ExperienceRadioCatalogFixture(artists: ["UCsetupArtist": .success(
            ArtistPage(id: "UCsetupArtist", name: artist.name, topSongs: rows))])
        let result = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(configuration(for: [artist]),
            disliked: [DislikedSong(id: "another-release", title: "Blocked Song (Remastered)", artists: [artist.name])])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.error)
        XCTAssertEqual(result.first?.seeds.compactMap(\.recording), [audio, unknownLanguage])
        XCTAssertTrue(result[0].seeds.allSatisfy { $0.year == nil && $0.yearSource == nil })
        let searches = await catalog.searchRequests
        let radios = await catalog.radioRequests
        XCTAssertTrue(searches.isEmpty, "A linked artist does not need a name lookup")
        XCTAssertTrue(radios.isEmpty, "Setup resolves starting songs without starting radio playback")
    }

    func testEraChangesChooseDatedAlbumSongsRatherThanPopularUndatedTopSongs() async throws {
        let artist = ArtistCredit(name: "Catalog Artist", id: "UCdatedArtist")
        var popular = RecommendationFixtures.track("popular-undated", artist: artist.name)
        popular.playCount = 9_000_000_000
        var older = RecommendationFixtures.track("older-song", artist: artist.name)
        older.albumID = "older-album"
        var newer = RecommendationFixtures.track("newer-song", artist: artist.name)
        newer.albumID = "newer-album"
        var anotherAlbum = RecommendationFixtures.track("other-album-song", artist: artist.name)
        anotherAlbum.albumID = "unrelated-release"
        let releases = [
            RecommendationFixtures.release("unknown-album", title: "Undated", subtitle: "Album"),
            RecommendationFixtures.release("future-album", title: "Future", subtitle: "Album · 2099"),
            RecommendationFixtures.release("remaster-album", title: "Anniversary remaster", subtitle: "Album · 2022"),
            RecommendationFixtures.release("older-album", title: "Earlier release", subtitle: "Album · 1998"),
            RecommendationFixtures.release("newer-album", title: "Later release", subtitle: "Album · 2018"),
        ]
        let catalog = ExperienceRadioCatalogFixture(artists: ["UCdatedArtist": .success(
            ArtistPage(id: "UCdatedArtist", name: artist.name, topSongs: [popular], releases: releases))], albums: [
                "older-album": .success(CatalogPage(tracks: [older])),
                "newer-album": .success(CatalogPage(tracks: [anotherAlbum,
                    RecommendationFixtures.track("wrong-credit", artist: "Another Singer"),
                    RecommendationFixtures.track("video", artist: artist.name, audio: false), newer])),
            ])
        let engine = ExperienceRadioEngine(catalog: catalog)
        let cases: [(RadioEra, Track, Int?)] = [(.anytime, popular, nil), (.older, older, 1998), (.newer, newer, 2018)]
        for (era, expected, year) in cases {
            let result = try await engine.resolveArtists(configuration(for: [artist], era: era), disliked: [])
            let seed = try XCTUnwrap(result.first?.seeds.first)
            XCTAssertEqual(result.first?.seeds.count, 1)
            XCTAssertEqual(seed.recording, expected)
            XCTAssertEqual(seed.year, year)
            if let albumID = expected.albumID {
                XCTAssertEqual(seed.yearSource?.absoluteString, "https://music.youtube.com/browse/\(albumID)")
            } else { XCTAssertNil(seed.yearSource) }
        }
        let browses = await catalog.browseRequests
        XCTAssertEqual(browses, ["older-album", "newer-album"])
    }

    func testKnownOriginalDoesNotBecomeNewerThroughARecentCompilation() async throws {
        let artist = ArtistCredit(name: "Radiohead", id: "UCradioheadFixture")
        var song = RecommendationFixtures.track("recent-upload", title: "No Surprises (Remastered)", artist: artist.name)
        song.albumID = "recent-release"
        let release = RecommendationFixtures.release("recent-release", title: "Studio collection", subtitle: "Album · 2018")
        let catalog = ExperienceRadioCatalogFixture(artists: ["UCradioheadFixture": .success(
            ArtistPage(id: "UCradioheadFixture", name: artist.name, topSongs: [song], releases: [release]))],
            albums: ["recent-release": .success(CatalogPage(tracks: [song]))])
        let result = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(configuration(for: [artist], era: .newer), disliked: [])
        XCTAssertTrue(try XCTUnwrap(result.first).seeds.isEmpty)
        XCTAssertNil(result.first?.error, "An empty dated result is distinct from a failed lookup")
    }

    func testLiveVersionsCannotBorrowTheCuratedOriginalYear() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let intent = station.seeds[1]
        let artist = ArtistCredit(name: "Pixies", id: "UCpixiesFixture")
        let cases: [(String, Int?)] = [
            ("Where Is My Mind? (Recorded Live in 2020)", nil),
            ("Where Is My Mind? - Live at Wembley", nil),
            ("Where Is My Mind? Live", nil),
            ("Where Is My Mind? Acoustic Version", nil),
            ("Where Is My Mind? (Remastered)", 1988),
        ]
        for (title, year) in cases {
            let song = RecommendationFixtures.track("version", title: title, artist: artist.name)
            let catalog = ExperienceRadioCatalogFixture(searches: [intent.query: .success([song])], artists: [
                "UCpixiesFixture": .success(ArtistPage(id: "UCpixiesFixture", name: artist.name, topSongs: [song])),
            ])
            var value = RadioConfiguration(station: station, languages: [.english])
            value.era = .older
            value.artists = [artist]
            let result = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(value, disliked: [])
            if let year {
                XCTAssertEqual(result.first?.seeds.first?.recording, song, title)
                XCTAssertEqual(result.first?.seeds.first?.year, year, title)
                XCTAssertEqual(result.first?.seeds.first?.yearSource, intent.yearSource, title)
            } else {
                XCTAssertTrue(try XCTUnwrap(result.first).seeds.isEmpty, title)
                XCTAssertNil(result.first?.error, title)
            }
        }
    }

    func testFailedCuratedLookupRemainsRetryableWhenTheArtistPageHasNoDatedAlternative() async throws {
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let artist = ArtistCredit(name: "Pixies", id: "UCpixiesFixture")
        let catalog = ExperienceRadioCatalogFixture(searches: [station.seeds[1].query: .failure(
            MusicServiceError.network("Temporary song search failure"))], artists: [
                "UCpixiesFixture": .success(ArtistPage(id: "UCpixiesFixture", name: artist.name)),
            ])
        var value = RadioConfiguration(station: station, languages: [.english])
        value.era = .older
        value.artists = [artist]
        let result = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(value, disliked: [])
        XCTAssertTrue(try XCTUnwrap(result.first).seeds.isEmpty)
        XCTAssertEqual(result.first?.error, "Temporary song search failure")
    }

    func testArtistLookupsAndAlbumBrowsesHaveBudgetsAndBoundedConcurrency() async throws {
        let artists = (0..<7).map { ArtistCredit(name: "Catalog Artist \($0)", id: "UCsetupArtist\($0)") }
        var pages: [String: Result<ArtistPage, any Error>] = [:]
        var albums: [String: Result<CatalogPage, any Error>] = [:]
        for artist in artists.prefix(4) {
            let id = try XCTUnwrap(artist.id)
            let releases = (0..<6).map { index in
                RecommendationFixtures.release("\(id)-release-\(index)", title: "Album \(index)", subtitle: "Album · \(2020 - index)")
            }
            pages[id] = .success(ArtistPage(id: id, name: artist.name, releases: releases))
            for release in releases { albums[release.id] = .success(CatalogPage()) }
        }
        let catalog = ExperienceRadioCatalogFixture(artists: pages, albums: albums, delay: .milliseconds(40))
        let selections = [artists[0], ArtistCredit(name: "CATALOG ARTIST 0", id: "duplicate-credit")] + Array(artists.dropFirst())
        let results = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(configuration(for: selections, era: .newer), disliked: [])
        let artistCalls = await catalog.artistRequests
        let browseCalls = await catalog.browseRequests
        let peak = await catalog.maximumActiveRequests
        XCTAssertEqual(results.map(\.artist), Array(artists.prefix(4)))
        XCTAssertTrue(results.allSatisfy { $0.seeds.isEmpty && $0.error == nil })
        XCTAssertEqual(Set(artistCalls), Set(artists.prefix(4).compactMap(\.id)))
        XCTAssertEqual(artistCalls.count, 4)
        XCTAssertEqual(browseCalls.count, 8)
        for artist in artists.prefix(4) {
            let id = try XCTUnwrap(artist.id)
            XCTAssertEqual(browseCalls.filter { $0.hasPrefix(id + "-release-") }, [id + "-release-0", id + "-release-1"])
        }
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testUnlinkedArtistsResolveThroughMatchingArtistSearchResults() async throws {
        let credit = ArtistCredit(name: "A. R. Rahman")
        let match = MusicCollection(id: "UCmatchedRahman", title: "AR Rahman", kind: .artist)
        let song = RecommendationFixtures.track("credited-audio", artist: "A.R. Rahman")
        let catalog = ExperienceRadioCatalogFixture(artists: [match.id: .success(
            ArtistPage(id: match.id, name: match.title, topSongs: [song]))], artistSearches: [credit.name: .success([
                MusicCollection(id: "not-an-artist", title: credit.name, kind: .album),
                MusicCollection(id: "tribute-channel", title: "Rahman Tribute Singers", kind: .artist), match,
            ])])
        let result = try await ExperienceRadioEngine(catalog: catalog).resolveArtists(configuration(for: [credit]), disliked: [])
        XCTAssertEqual(result.first?.seeds.first?.recording, song)
        XCTAssertEqual(result.first?.seeds.first?.artist.id, match.id)
        let calls = await catalog.searchRequests
        XCTAssertEqual(calls, [AppModelSearchRequest(query: credit.name, filter: .artists, continuation: nil)])
        let artistCalls = await catalog.artistRequests
        XCTAssertEqual(artistCalls, [match.id])
    }

    func testConfiguredDatedStartRejectsMissingSourcesUnknownYearsAndIncompatibleYears() async throws {
        let f = ExperienceRadioFixtures.self
        let source = try XCTUnwrap(URL(string: "https://music.youtube.com/browse/dated-fixture"))
        let valid = RadioExperience.Seed(recording: f.pixies, artist: f.melancholy.seeds[1].artist, year: 1988, yearSource: source)
        let invalid: [(Int?, URL?)] = [(nil, source), (1999, nil), (2017, source)]
        for (year, source) in invalid {
            let other = RadioExperience.Seed(recording: f.cas, artist: f.melancholy.seeds[0].artist, year: year, yearSource: source)
            let value = RadioExperience(id: "dated-recordings", title: "Dated fixture", description: "Fixture", symbol: "radio",
                discoveryLanguages: [.english], contentLabel: "English", seeds: [valid, other], defaultEra: .older)
            let extra = RecommendationFixtures.track("dated-neighbor", title: "Linger", artist: "The Cranberries")
            let catalog = ExperienceRadioCatalogFixture(radios: [f.pixies.id: .success([f.dream, f.alt, extra])])
            let batch = try await ExperienceRadioEngine(catalog: catalog).start(value, disliked: [], languages: [.english])
            XCTAssertEqual(batch.buckets.map(\.anchor.id), [f.pixies.id], "Only the sourced recording in the chosen era may seed radio")
            XCTAssertEqual(batch.tracks.count, 4)
            let searches = await catalog.searchRequests
            let radios = await catalog.radioRequests
            XCTAssertTrue(searches.isEmpty, "Resolved recordings must keep their provider identifiers")
            XCTAssertEqual(radios, [f.pixies])
        }
    }

    private func configuration(for artists: [ArtistCredit], era: RadioEra = .anytime) -> RadioConfiguration {
        var value = RadioConfiguration(station: ExperienceRadioFixtures.melancholy, languages: [.english])
        value.artists = artists
        value.era = era
        return value
    }
}
