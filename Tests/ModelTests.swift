import XCTest
@testable import GanaBajana

final class ModelTests: XCTestCase {
    func testDurationFormattingIsBoundedAndRejectsNonfiniteValues() {
        XCTAssertEqual(TimeText.duration(.nan), "0:00")
        XCTAssertEqual(TimeText.duration(-1), "0:00")
        XCTAssertEqual(TimeText.duration(234.9), "3:54")
        XCTAssertEqual(TimeText.duration(3605), "1:00:05")
    }

    func testTrackPersistsProviderIdentityAndUnicode() throws {
        let track = Track(id: "fsiPzT50ZiM", title: "तुम ही हो", artists: ["Arijit Singh"], language: .hindi)
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)), track)
        XCTAssertEqual(track.shareURL?.host, "music.youtube.com")
    }

    func testLegacyStoredTracksDecodeIntoCreditsAndEncodeCreditsOnly() throws {
        let legacy = Data("""
        {"id":"fsiPzT50ZiM","title":"Tum Hi Ho","artists":["Arijit Singh","Mithoon"],"artistID":"UCDxKh1gFWeYsqePvgVzmPoQ","albumTitle":"Aashiqui 2","language":"hindi"}
        """.utf8)
        let track = try JSONDecoder().decode(Track.self, from: legacy)
        XCTAssertEqual(track.credits, [ArtistCredit(name: "Arijit Singh", id: "UCDxKh1gFWeYsqePvgVzmPoQ"), ArtistCredit(name: "Mithoon")],
                       "The stored artistID belonged to the first name only")
        XCTAssertEqual(track.artists, ["Arijit Singh", "Mithoon"])
        XCTAssertEqual(track.artistID, "UCDxKh1gFWeYsqePvgVzmPoQ")
        XCTAssertEqual(track.artistName, "Arijit Singh, Mithoon")
        XCTAssertFalse(track.isExplicit, "A missing explicit flag stays false")
        XCTAssertEqual(track.language, .hindi)

        let encoded = try JSONEncoder().encode(track)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["credits"], "New stores write credits")
        XCTAssertNil(object["artists"], "The legacy name list is no longer written")
        XCTAssertNil(object["artistID"], "The legacy primary id is no longer written")
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: encoded), track)

        let unlinked = Data(#"{"id":"J7p4bzqLvCw","title":"STAY","artists":["The Kid LAROI","Justin Bieber"],"isExplicit":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Track.self, from: unlinked)
        XCTAssertEqual(decoded.credits.map(\.id), [nil, nil] as [String?])
        XCTAssertNil(decoded.artistID)
        XCTAssertNil(decoded.artistCollection)
        XCTAssertTrue(decoded.isExplicit)
    }

    func testAssigningArtistNamesKeepsTheIDsOfNamesThatStay() {
        var track = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [
            ArtistCredit(name: "Arijit Singh", id: "UCDxKh1gFWeYsqePvgVzmPoQ"), ArtistCredit(name: "Mithoon", id: "UCCTN01plFzn4npREHKT2_9Q"),
        ])
        track.artists = ["Mithoon", "arijit singh", "Newcomer"]
        XCTAssertEqual(track.credits.map(\.name), ["Mithoon", "arijit singh", "Newcomer"])
        XCTAssertEqual(track.credits.map(\.id), ["UCCTN01plFzn4npREHKT2_9Q", "UCDxKh1gFWeYsqePvgVzmPoQ", nil] as [String?], "Ids follow names case-insensitively")
        XCTAssertEqual(track.artistID, "UCCTN01plFzn4npREHKT2_9Q", "The primary artist is whoever is credited first")
        XCTAssertEqual(track.artistCollection, MusicCollection(id: "UCCTN01plFzn4npREHKT2_9Q", title: "Mithoon", kind: .artist))
        XCTAssertNil(ArtistCredit(name: "T-Pain").collection)
        XCTAssertNil(ArtistCredit(name: "Nobody", id: "").collection, "An empty id is not a page")
    }

    func testFeaturedArtistsComeOnlyFromFeatureClauses() {
        XCTAssertEqual(ArtistCredit.featured(inTitle: "Six Days (Remix) (feat. Mos Def & Al Be Back)").map(\.name), ["Mos Def", "Al Be Back"])
        XCTAssertEqual(ArtistCredit.featured(inTitle: "Fortnight (with Taylor Swift)").map(\.name), ["Taylor Swift"])
        XCTAssertEqual(ArtistCredit.featured(inTitle: "Sicko Mode [ft. Drake]").map(\.name), ["Drake"])
        XCTAssertEqual(ArtistCredit.featured(inTitle: "Good Life feat. T-Pain").map(\.name), ["T-Pain"], "A trailing clause needs no brackets")
        XCTAssertEqual(ArtistCredit.featured(inTitle: "Song feat. A, B and C").map(\.name), ["A", "B", "C"])
        XCTAssertTrue(ArtistCredit.featured(inTitle: "Kesariya (From \"Brahmastra\")").isEmpty, "A film credit is not a feature")
        XCTAssertTrue(ArtistCredit.featured(inTitle: "5 ft 2").isEmpty, "Numbers are not artists")
        XCTAssertTrue(ArtistCredit.featured(inTitle: "Stay With Me").isEmpty, "\"with\" only counts inside brackets")
        XCTAssertTrue(ArtistCredit.featured(inTitle: "Tum Hi Ho").isEmpty)
        XCTAssertTrue(ArtistCredit.featured(inTitle: "Good Life (feat. T-Pain)").allSatisfy { $0.id == nil }, "Title features are unlinked until opened by name")
    }

    func testSongTitleCoreCollapsesVersionsAndFeatureClauses() {
        XCTAssertEqual(SongTitle.core("Six Days (Remix) (feat. Mos Def)"), "six days")
        XCTAssertEqual(SongTitle.core("Six Days - Radio Edit"), "six days")
        XCTAssertEqual(SongTitle.core("Six Days"), "six days")
        XCTAssertEqual(SongTitle.core("Kesariya (From \"Brahmastra\")"), "kesariya")
        XCTAssertEqual(SongTitle.core("Tum Hi Ho feat. Mithoon"), "tum hi ho")
        XCTAssertTrue(SongTitle.isVersion("Six Days - Radio Edit", of: "Six Days (Remix) (feat. Mos Def)"))
        XCTAssertTrue(SongTitle.isVersion("Kesariya (Lofi)", of: "Kesariya"))
        XCTAssertFalse(SongTitle.isVersion("Stay", of: "Stay With Me"), "A longer title is a different song, not a version")
        XCTAssertFalse(SongTitle.isVersion("", of: ""), "Empty titles never match")
        XCTAssertEqual(SongTitle.core("Remix"), "remix", "The last word survives when it is the whole title")
    }
}
