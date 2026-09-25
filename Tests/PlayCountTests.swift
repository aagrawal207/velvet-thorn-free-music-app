import XCTest
@testable import GanaBajana

final class PlayCountTests: XCTestCase {
    func testProviderLabelsKeepCompactAndWrittenScales() {
        let cases: [(String, Int64)] = [
            ("1.2B plays", 1_200_000_000), ("1.2 billion plays", 1_200_000_000),
            ("173 million plays", 173_000_000), ("845 thousand plays", 845_000),
            ("12,345 plays", 12_345), ("1\u{202F}234\u{00A0}567 plays", 1_234_567),
            ("1.2 M plays", 1_200_000), ("0.5K plays", 500), ("0 plays", 0), ("1 play", 1),
        ]
        for (label, expected) in cases {
            XCTAssertEqual(PlayCountText.parse(label, unit: .plays), expected, label)
        }
    }

    func testWholeLabelAndSourceUnitAreRequired() {
        for label in ["3M weekly plays", "12,345 monthly plays", "1.2B total weekly views",
                      "12M monthly listeners", "665M monthly audience", "20 subscribers",
                      "1e9 plays", "+12 plays", "-12 plays", "1,23 plays", "1..2M plays",
                      "12 songs • 34 plays", "unknown plays", "1.2B", "1.2B plays yesterday"] {
            XCTAssertNil(PlayCountText.parse(label), label)
        }
        XCTAssertEqual(PlayCountText.parse("200,574,245 views", unit: .views), 200_574_245)
        XCTAssertNil(PlayCountText.parse("200,574,245 views", unit: .plays))
        XCTAssertNil(PlayCountText.parse("1.2 billion plays", unit: .views))
    }

    func testLiteralIntegerPrecisionAndOverflow() {
        XCTAssertEqual(PlayCountText.parse("9,007,199,254,740,993 plays"), 9_007_199_254_740_993)
        XCTAssertEqual(PlayCountText.parse("9223372036854775807 plays"), Int64.max)
        XCTAssertNil(PlayCountText.parse("9223372036854775808 plays"))
        XCTAssertNil(PlayCountText.parse("10 trillion trillion plays"))
        XCTAssertNil(PlayCountText.parse("99999999999999999999T plays"))
        XCTAssertNil(PlayCountText.parse("0.5 plays"), "A fractional literal must not invent a whole play")
    }

    func testPresentationUsesSingularAndHidesUnavailablePopularity() {
        XCTAssertEqual(PlayCountText.plays(1), "1 play")
        XCTAssertEqual(PlayCountText.plays(1_200_000_000), "1.2B plays")
        for count in [nil, 0, -1] as [Int64?] { XCTAssertNil(PlayCountText.plays(count)) }
    }

    func testMissingCountCannotBeAdoptedFromAnotherRecording() {
        var track = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho")
        var other = Track(id: "BjL7AuPsmEk", title: track.title, playCount: 1_200_000_000)
        track.adoptMissingMetadata(from: other)
        XCTAssertNil(track.playCount)
        other.id = track.id
        track.adoptMissingMetadata(from: other)
        XCTAssertEqual(track.playCount, 1_200_000_000)
    }

    func testLegacyTrackCountAndCloudCodecRoundTripStayCompatible() throws {
        let legacy = Data(#"{"id":"fsiPzT50ZiM","title":"Tum Hi Ho","artists":["Arijit Singh"],"playCount":1200000000}"#.utf8)
        let track = try JSONDecoder().decode(Track.self, from: legacy)
        XCTAssertEqual(track.playCount, 1_200_000_000)
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)), track)
        XCTAssertEqual(try LibrarySyncCodec.decode(Track.self, from: LibrarySyncCodec.encode(track)), track)
        XCTAssertNoThrow(try LibraryValidation.validateTrack(track))
        let unknown = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"unknown","title":"Unknown"}"#.utf8))
        XCTAssertNil(unknown.playCount)
    }
}
