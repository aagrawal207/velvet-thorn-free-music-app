import XCTest
@testable import GanaBajana

final class TasteProfileTests: XCTestCase {
    private let now = RecommendationFixtures.now

    private func build(events: [ListeningEvent] = [], favorites: [Track] = [], playlists: [UserPlaylist] = [],
                       recents: [RecentListen] = []) -> TasteProfile {
        TasteProfile.build(events: events, favorites: favorites, playlists: playlists, recents: recents, now: now)
    }

    func testListenedSecondsDecayWithATwentyOneDayHalfLife() {
        let track = RecommendationFixtures.track("a", artist: "Arijit Singh")
        let fresh = build(events: [RecommendationFixtures.event(track, daysAgo: 0, seconds: 100)])
        let halved = build(events: [RecommendationFixtures.event(track, daysAgo: 21, seconds: 100)])
        let quartered = build(events: [RecommendationFixtures.event(track, daysAgo: 42, seconds: 100)])
        XCTAssertEqual(fresh.trackAffinity["a"] ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(halved.trackAffinity["a"] ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(quartered.trackAffinity["a"] ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(halved.artistAffinity["arijit singh"] ?? 0, 50, accuracy: 1e-9)
        let future = build(events: [RecommendationFixtures.event(track, daysAgo: -3, seconds: 100)])
        XCTAssertEqual(future.trackAffinity["a"] ?? 0, 100, accuracy: 1e-9, "Clock skew must not inflate weights")
    }

    func testOnlyQualifyingListensCountButEveryTapIsHeard() {
        let long = RecommendationFixtures.track("long", artist: "Arijit Singh", duration: 240)
        let short = RecommendationFixtures.track("short", artist: "Shreya Ghoshal", duration: 30)
        let unknown = RecommendationFixtures.track("unknown", artist: "Pritam", duration: nil)
        let profile = build(events: [
            RecommendationFixtures.event(long, daysAgo: 0, seconds: 0.5),
            RecommendationFixtures.event(long, daysAgo: 0, seconds: 29.999),
            RecommendationFixtures.event(short, daysAgo: 0, seconds: 15),
            RecommendationFixtures.event(short, daysAgo: 0, seconds: 14.999),
            RecommendationFixtures.event(unknown, daysAgo: 0, seconds: 30),
            RecommendationFixtures.event(unknown, daysAgo: 0, seconds: 29),
        ])
        XCTAssertNil(profile.trackAffinity["long"])
        XCTAssertNil(profile.artistAffinity["arijit singh"])
        XCTAssertEqual(profile.trackAffinity["short"] ?? 0, 15, accuracy: 1e-9)
        XCTAssertEqual(profile.trackAffinity["unknown"] ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(profile.heardTrackIDs, ["long", "short", "unknown"])
        XCTAssertTrue(profile.topTracks(limit: 10).allSatisfy { $0.id != "long" })
    }

    func testFavoritesAndPlaylistsBoostArtistsAndTracksWithoutDecay() {
        let favorite = RecommendationFixtures.track("fav", artist: "Atif Aslam")
        let listed = RecommendationFixtures.track("listed", artist: "Atif Aslam")
        let playlist = UserPlaylist(name: "Drive", tracks: [listed, favorite])
        let profile = build(favorites: [favorite], playlists: [playlist])
        XCTAssertEqual(profile.trackAffinity["fav"] ?? 0, 240, accuracy: 1e-9)
        XCTAssertEqual(profile.trackAffinity["listed"] ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(profile.artistAffinity["atif aslam"] ?? 0, 300, accuracy: 1e-9)
        XCTAssertEqual(profile.heardTrackIDs, ["fav", "listed"])
        XCTAssertEqual(profile.topTracks(limit: 5).map(\.id), ["fav", "listed"])
        XCTAssertTrue(profile.isColdStart, "Likes alone do not prove listening habits")
    }

    func testColdStartNeedsThreeQualifyingListensAcrossTwoArtists() {
        let a = RecommendationFixtures.track("a", artist: "Arijit Singh")
        let b = RecommendationFixtures.track("b", artist: "The Weeknd")
        XCTAssertTrue(build().isColdStart)
        XCTAssertTrue(build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 60),
            RecommendationFixtures.event(b, daysAgo: 0, seconds: 60),
        ]).isColdStart)
        XCTAssertTrue(build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 60),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 60),
            RecommendationFixtures.event(a, daysAgo: 2, seconds: 60),
        ]).isColdStart)
        XCTAssertTrue(build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 60),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 60),
            RecommendationFixtures.event(b, daysAgo: 2, seconds: 1),
        ]).isColdStart, "A stray tap must not lift the profile out of cold start")
        XCTAssertFalse(build(events: [
            RecommendationFixtures.event(a, daysAgo: 0, seconds: 60),
            RecommendationFixtures.event(a, daysAgo: 1, seconds: 60),
            RecommendationFixtures.event(b, daysAgo: 2, seconds: 60),
        ]).isColdStart)
    }

    func testTopArtistsUseTheMostListenedSpellingAndMostCommonChannelID() {
        let upper = Track(id: "u", title: "Upper", artists: ["Arijit Singh", "Shreya Ghoshal"], artistID: "UCarijit", duration: 240)
        let lower = Track(id: "l", title: "Lower", artists: [" arijit singh "], artistID: "UCother", duration: 240)
        let shreya = Track(id: "s", title: "Solo", artists: ["Shreya Ghoshal"], artistID: "UCshreya", duration: 240)
        let profile = build(events: [
            RecommendationFixtures.event(upper, daysAgo: 0, seconds: 100),
            RecommendationFixtures.event(upper, daysAgo: 0, seconds: 100),
            RecommendationFixtures.event(lower, daysAgo: 0, seconds: 150),
            RecommendationFixtures.event(shreya, daysAgo: 0, seconds: 100),
        ])
        let artists = profile.topArtists(limit: 5)
        XCTAssertEqual(artists.map(\.name), ["Arijit Singh", "Shreya Ghoshal"])
        XCTAssertEqual(artists.map(\.id), ["UCarijit", "UCshreya"])
        XCTAssertEqual(artists[0].weight, 350, accuracy: 1e-9)
        XCTAssertEqual(artists[1].weight, 300, accuracy: 1e-9)
        XCTAssertEqual(profile.topArtists(limit: 1).count, 1)
        XCTAssertTrue(profile.topArtists(limit: 0).isEmpty)
    }

    func testFeaturedArtistsNeverInheritThePrimaryArtistsChannelID() throws {
        let duet = Track(id: "d", title: "Duet", artists: ["Arijit Singh", "Alka Yagnik"], artistID: "UCarijit", duration: 240)
        let profile = build(events: [RecommendationFixtures.event(duet, daysAgo: 0, seconds: 100)])
        let artists = profile.topArtists(limit: 5)
        let featured = try XCTUnwrap(artists.first { $0.name == "Alka Yagnik" })
        let primary = try XCTUnwrap(artists.first { $0.name == "Arijit Singh" })
        XCTAssertNil(featured.id)
        XCTAssertEqual(primary.id, "UCarijit")
    }

    func testEveryCreditKeepsItsOwnIDWhenThePrimaryIsUnlinkedOrSeveralArtistsAreLinked() throws {
        let cases: [[ArtistCredit]] = [
            [ArtistCredit(name: "Primary Singer"), ArtistCredit(name: "Arijit Singh", id: "UCarijit"),
             ArtistCredit(name: "Alka Yagnik", id: "UCalka")],
            [ArtistCredit(name: "Primary Singer", id: "UCprimary"), ArtistCredit(name: "Arijit Singh", id: "UCarijit"),
             ArtistCredit(name: "Alka Yagnik", id: "UCalka")],
        ]
        for credits in cases {
            let song = Track(id: "collaboration", title: "Together", credits: credits, duration: 240)
            let profile = build(events: [RecommendationFixtures.event(song, daysAgo: 0, seconds: 100)],
                                favorites: [song], playlists: [UserPlaylist(name: "Collaborations", tracks: [song])])
            let artists = profile.topArtists(limit: 10)
            XCTAssertEqual(artists.count, 3)
            for credit in credits {
                let artist = try XCTUnwrap(artists.first { $0.name == credit.name })
                XCTAssertEqual(artist.id, credit.id, "The channel must stay with its own credited name")
                XCTAssertEqual(artist.weight, 340, accuracy: 1e-9)
            }
        }
    }

    func testTopTracksReturnTheLatestTrackValueAndRankByAffinity() {
        let old = Track(id: "a", title: "Old Title", artists: ["Arijit Singh"], duration: 240)
        var renamed = old
        renamed.title = "New Title"
        renamed.artworkURL = URL(string: "https://example.com/art.jpg")
        let other = RecommendationFixtures.track("b", artist: "The Weeknd")
        let profile = build(events: [
            RecommendationFixtures.event(renamed, daysAgo: 1, seconds: 100),
            RecommendationFixtures.event(old, daysAgo: 5, seconds: 100),
            RecommendationFixtures.event(other, daysAgo: 0, seconds: 300),
        ])
        let top = profile.topTracks(limit: 2)
        XCTAssertEqual(top.map(\.id), ["b", "a"])
        XCTAssertEqual(top[1].title, "New Title")
        XCTAssertEqual(profile.track(id: "a")?.artworkURL, renamed.artworkURL)
    }

    func testLanguageMixAndHeardIDsCoverEverySource() {
        let hindi = RecommendationFixtures.track("h", artist: "Arijit Singh", language: .hindi)
        let english = RecommendationFixtures.track("e", artist: "The Weeknd", language: .english)
        let unknown = RecommendationFixtures.track("u", artist: "Someone")
        let recent = RecentListen(track: RecommendationFixtures.track("r", artist: "Recent"), playedAt: now, position: 10)
        let profile = build(
            events: [RecommendationFixtures.event(hindi, daysAgo: 0, seconds: 100), RecommendationFixtures.event(unknown, daysAgo: 0, seconds: 100)],
            favorites: [english], playlists: [UserPlaylist(name: "Mix", tracks: [RecommendationFixtures.track("p", artist: "Listed")])],
            recents: [recent]
        )
        XCTAssertEqual(profile.languageMix[.hindi] ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(profile.languageMix[.english] ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(profile.dominantLanguage, .english)
        XCTAssertEqual(profile.language(forArtist: "arijit singh"), .hindi)
        XCTAssertNil(profile.language(forArtist: "Someone"))
        XCTAssertEqual(profile.heardTrackIDs, ["h", "u", "e", "p", "r"])
        XCTAssertEqual(profile.track(id: "r")?.artists, ["Recent"])
    }

    func testInvalidEventsAreIgnoredAndBlankArtistsAreNotInvented() {
        let blank = Track(id: "blank", title: "No Artist", artists: ["", "  "], duration: 240)
        let profile = build(events: [
            RecommendationFixtures.event(blank, daysAgo: 0, seconds: 100),
            ListeningEvent(id: UUID(), track: blank, startedAt: now, listenedSeconds: .nan),
            ListeningEvent(id: UUID(), track: blank, startedAt: now, listenedSeconds: .infinity),
            ListeningEvent(id: UUID(), track: Track(id: "", title: "Ghost"), startedAt: now, listenedSeconds: 100),
        ])
        XCTAssertEqual(profile.trackAffinity["blank"] ?? 0, 100, accuracy: 1e-9)
        XCTAssertTrue(profile.artistAffinity.isEmpty)
        XCTAssertEqual(profile.heardTrackIDs, ["blank"])
        XCTAssertTrue(profile.topArtists(limit: 3).isEmpty)
    }
}
