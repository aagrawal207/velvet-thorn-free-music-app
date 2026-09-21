import XCTest
@testable import GanaBajana

@MainActor
final class TrackRowAccessibilityTests: XCTestCase {
    func testRankExplicitFlagAndProviderCountRemainSeparateFromTheSongLabel() {
        let track = Track(id: "row", title: "Garden Paths", artists: ["Fixture Singer"], isExplicit: true, playCount: 1_200)
        let row = TrackRow(track: track, rank: 3)

        XCTAssertEqual(row.accessibilityValue, "Rank 3. Explicit. YouTube Music: \(1_200.formatted()) plays worldwide")
        XCTAssertFalse(row.accessibilityValue.contains(track.title))
        XCTAssertFalse(row.accessibilityValue.contains(track.artistName))
    }

    func testContextualSubtitleIsExposedInsteadOfHiddenProviderPopularity() {
        let track = Track(id: "row", title: "Morning Windows", artists: ["Fixture Singer"], playCount: 800)
        let row = TrackRow(track: track, rank: 1, subtitle: "26 min listened · 6 plays")

        XCTAssertEqual(row.accessibilityValue, "Rank 1. 26 min listened · 6 plays")
        XCTAssertFalse(row.accessibilityValue.contains("worldwide"))
        XCTAssertFalse(row.accessibilityValue.contains("800"))
    }

    func testRecapMetadataExplicitlyIdentifiesPersonalListeningAndItsWindow() {
        let track = Track(id: "row", title: "Tum Hi Ho", artists: ["Arijit Singh"], playCount: 1_000_000)
        let row = TrackRow(track: track, rank: 1, subtitle: "Arijit Singh · 26 min listened · 6 plays",
                           accessibilityMetadata: "Your listening in the last 7 days: 26 min listened, 6 plays")

        XCTAssertEqual(row.accessibilityValue, "Rank 1. Your listening in the last 7 days: 26 min listened, 6 plays")
        XCTAssertFalse(row.accessibilityValue.contains("YouTube"))
        XCTAssertFalse(row.accessibilityValue.contains(track.artistName))
    }

    func testMissingZeroAndNegativeProviderCountsDoNotInventPopularity() {
        for count in [nil, 0, -1] as [Int64?] {
            let track = Track(id: "row", title: "Unwritten", artists: ["Fixture Singer"], playCount: count)
            XCTAssertEqual(TrackRow(track: track).accessibilityValue, "")
        }
    }

    func testOneWorldwidePlayIsSingular() {
        let track = Track(id: "row", title: "First play", artists: ["Fixture Singer"], playCount: 1)
        XCTAssertEqual(TrackRow(track: track).accessibilityValue, "YouTube Music: 1 play worldwide")
    }
}
