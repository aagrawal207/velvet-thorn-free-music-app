import SwiftUI
import XCTest
@testable import GanaBajana

@MainActor
final class CollectionPresentationTests: XCTestCase {
    func testCompleteCollectionSummaryIncludesEveryKnownSongLength() {
        let tracks = songs(durations: [262, 269, 342, 202, 234])
        XCTAssertEqual(CollectionDetailView.trackSummary(for: tracks), "5 songs · 21:49")
        XCTAssertEqual(CollectionDetailView.trackSummary(for: songs(durations: [3_661, 62])), "2 songs · 1:02:03")
    }

    func testMissingOrInvalidSongLengthOmitsTheTotalInsteadOfSummingAPartialAlbum() {
        for duration in [nil, 0, -1, 0.5, .nan, .infinity, -.infinity] as [TimeInterval?] {
            let tracks = songs(durations: [262, duration, 234])
            XCTAssertEqual(CollectionDetailView.trackSummary(for: tracks), "3 songs", "duration: \(String(describing: duration))")
        }
    }

    func testAnIncompleteCatalogPageReportsOnlyTheLoadedCount() {
        let tracks = songs(durations: [262, 269])
        XCTAssertEqual(CollectionDetailView.trackSummary(for: tracks, hasMore: true), "2 songs loaded")
    }

    func testEmptyAndSingleSongCollectionsDoNotInventAZeroLength() {
        XCTAssertEqual(CollectionDetailView.trackSummary(for: []), "0 songs")
        XCTAssertEqual(CollectionDetailView.trackSummary(for: songs(durations: [nil])), "1 song")
        XCTAssertEqual(CollectionDetailView.trackSummary(for: songs(durations: [62])), "1 song · 1:02")
    }

    func testTotalsBeyondTheClockFormatterRangeAreOmittedRatherThanClamped() {
        XCTAssertEqual(CollectionDetailView.trackSummary(for: songs(durations: [180_000, 180_000])), "2 songs")
        XCTAssertEqual(CollectionDetailView.trackSummary(for: songs(durations: [.greatestFiniteMagnitude, .greatestFiniteMagnitude])), "2 songs")
    }

    func testVisibleSongDurationRemainsPartOfTheWholeRowVoiceOverValue() {
        let track = Track(id: "known", title: "Garden Paths", artists: ["Fixture Singer"], duration: 262,
                          isExplicit: true, playCount: 1_200)
        let row = TrackRow(track: track, rank: 3, showsDuration: true)
        XCTAssertEqual(row.durationText, "4:22")
        XCTAssertEqual(row.accessibilityValue, "Rank 3. Explicit. YouTube Music: \(1_200.formatted()) plays worldwide. Duration 4:22")

        let contextual = TrackRow(track: track, subtitle: "Live recording", showsDuration: true)
        XCTAssertEqual(contextual.accessibilityValue, "Explicit. Live recording. Duration 4:22")
    }

    func testSongDurationsAreOptInAndUnavailableLengthsAreOmitted() {
        let track = Track(id: "known", title: "Garden Paths", duration: 262)
        XCTAssertNil(TrackRow(track: track).durationText)
        XCTAssertEqual(TrackRow(track: track).accessibilityValue, "")

        for duration in [nil, 0, -1, 0.5, .nan, .infinity, -.infinity, 360_000] as [TimeInterval?] {
            let row = TrackRow(track: Track(id: "unknown", title: "Unwritten", duration: duration), showsDuration: true)
            XCTAssertNil(row.durationText, "duration: \(String(describing: duration))")
            XCTAssertEqual(row.accessibilityValue, "")
        }
        let longRecording = TrackRow(track: Track(id: "long", title: "Long recording", duration: 3_671.8), showsDuration: true)
        XCTAssertEqual(longRecording.durationText, "1:01:11")
        XCTAssertEqual(longRecording.accessibilityValue, "Duration 1:01:11")
    }

    func testPhoneCoverUsesTheAvailableWidthWithoutOverflowingSmallPhones() {
        let sizes: [(width: CGFloat, side: CGFloat)] = [(320, 272), (375, 327), (402, 354), (430, 360)]
        for (width, expectedSide) in sizes {
            let layout = CollectionHeaderLayout(width: width, viewportHeight: 700, dynamicTypeSize: .large)
            XCTAssertFalse(layout.isHorizontal)
            XCTAssertEqual(layout.artworkSide, expectedSide, accuracy: 1e-6)
        }
        let unmeasured = CollectionHeaderLayout(width: .nan, viewportHeight: .nan, dynamicTypeSize: .large)
        XCTAssertEqual(unmeasured.artworkSide, 0)
    }

    func testIPadCoverHasAUsableDetailsColumnAndStacksAtAccessibilitySizes() {
        let regular = CollectionHeaderLayout(width: 760, viewportHeight: 900, dynamicTypeSize: .large)
        XCTAssertTrue(regular.isHorizontal)
        XCTAssertEqual(regular.artworkSide, 360)

        let largeText = CollectionHeaderLayout(width: 760, viewportHeight: 900, dynamicTypeSize: .accessibility5)
        XCTAssertFalse(largeText.isHorizontal)
        XCTAssertEqual(largeText.artworkSide, 360)

        let splitView = CollectionHeaderLayout(width: 500, viewportHeight: 900, dynamicTypeSize: .large)
        XCTAssertFalse(splitView.isHorizontal)
        XCTAssertEqual(splitView.artworkSide, 360)
    }

    func testLandscapeCoverFitsTheViewportAboveTheMiniPlayer() {
        let smallPhone = CollectionHeaderLayout(width: 568, viewportHeight: 227, dynamicTypeSize: .large)
        XCTAssertTrue(smallPhone.isHorizontal)
        XCTAssertEqual(smallPhone.artworkSide, 203)
        for typeSize in [DynamicTypeSize.large, .accessibility5] {
            let layout = CollectionHeaderLayout(width: 760, viewportHeight: 250, dynamicTypeSize: typeSize)
            XCTAssertEqual(layout.isHorizontal, typeSize == .large)
            XCTAssertEqual(layout.artworkSide, 226)
        }
    }

    func testArtistPicturesAreTenPercentSmallerInPhoneIPadAndLandscapeLayouts() {
        let cases: [(width: CGFloat, height: CGFloat, typeSize: DynamicTypeSize, side: CGFloat, horizontal: Bool)] = [
            (320, 700, .large, 244.8, false),
            (375, 700, .large, 294.3, false),
            (402, 700, .large, 318.6, false),
            (430, 700, .large, 324, false),
            (760, 900, .large, 324, true),
            (760, 900, .accessibility5, 324, false),
            (500, 900, .large, 324, false),
            (568, 227, .large, 182.7, true),
            (760, 250, .accessibility5, 203.4, false),
        ]
        for value in cases {
            let layout = CollectionHeaderLayout(width: value.width, viewportHeight: value.height,
                                                dynamicTypeSize: value.typeSize, isArtist: true)
            XCTAssertEqual(layout.artworkSide, value.side, accuracy: 1e-6)
            XCTAssertEqual(layout.isHorizontal, value.horizontal)
        }
        let unmeasured = CollectionHeaderLayout(width: .nan, viewportHeight: .nan, dynamicTypeSize: .large, isArtist: true)
        XCTAssertEqual(unmeasured.artworkSide, 0)
    }

    private func songs(durations: [TimeInterval?]) -> [Track] {
        durations.enumerated().map { index, duration in
            Track(id: "collection.\(index)", title: "Fixture song \(index + 1)", duration: duration)
        }
    }
}
