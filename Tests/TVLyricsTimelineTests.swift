import XCTest
@testable import GanaBajana

final class TVLyricsTimelineTests: XCTestCase {
    private let lines = [LyricLine(id: 10, time: 2, text: "First"),
                         LyricLine(id: 20, time: 5, text: ""),
                         LyricLine(id: 30, time: 9, text: "Third")]

    private var timeline: TVLyricsTimeline {
        TVLyricsTimeline(document: LyricsDocument(trackID: "test", kind: .synced, lines: lines))
    }

    func testPositiveOffsetDelaysAndNegativeOffsetAdvancesAtExactBoundary() {
        XCTAssertNil(timeline.window(at: 3.499, offset: 1.5, duration: 20).current)
        XCTAssertEqual(timeline.window(at: 3.5, offset: 1.5, duration: 20).current?.id, 10)
        XCTAssertEqual(timeline.window(at: 0.5, offset: -1.5, duration: 20).current?.id, 10)
        XCTAssertEqual(timeline.window(at: 6.5, offset: 1.5, duration: 20).current?.id, 20)
    }

    func testBeforeFirstLineInstrumentalGapAndEndOfTrack() {
        let before = timeline.window(at: 0, offset: 0, duration: 20)
        XCTAssertNil(before.previous)
        XCTAssertNil(before.current)
        XCTAssertEqual(before.next?.text, "First")
        let gap = timeline.window(at: 5, offset: 0, duration: 20)
        XCTAssertEqual(gap.previous?.id, 10)
        XCTAssertEqual(gap.current?.text, "")
        XCTAssertEqual(gap.next?.id, 30)
        XCTAssertEqual(timeline.window(at: 20, offset: 0, duration: 20), .init())
    }

    func testBackwardSeekAndNonFiniteInputsDoNotInventProgress() {
        XCTAssertEqual(timeline.window(at: 10, offset: 0, duration: 20).current?.id, 30)
        XCTAssertEqual(timeline.window(at: 3, offset: 0, duration: 20).current?.id, 10)
        XCTAssertEqual(timeline.window(at: .nan, offset: 0, duration: nil), .init())
        XCTAssertEqual(timeline.window(at: -.infinity, offset: 0, duration: nil), .init())
        XCTAssertEqual(timeline.window(at: -1, offset: 0, duration: nil), .init())
        XCTAssertEqual(timeline.window(at: 2, offset: .nan, duration: nil).current?.id, 10)
        XCTAssertNil(timeline.window(at: 11, offset: 100, duration: nil).current)
        XCTAssertEqual(timeline.window(at: 12, offset: 100, duration: nil).current?.id, 10)
    }

    func testEmptyAndWhitespaceOnlyDocumentsAreUnavailable() {
        for kind in [LyricsKind.synced, .plain, .unavailable] {
            let document = LyricsDocument(trackID: "test", kind: kind, plainText: " \n\t ")
            let result = TVLyricsTimeline(document: document)
            XCTAssertEqual(result.mode, .unavailable)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(result.pages.isEmpty)
        }
        let blankLines = [LyricLine(id: 1, time: 0, text: " ")]
        XCTAssertEqual(TVLyricsTimeline(document: .init(trackID: "test", kind: .synced, lines: blankLines)).mode,
                       .unavailable)
    }

    func testInstrumentalAndUnavailableKindsDoNotExposeAttachedText() {
        for kind in [LyricsKind.instrumental, .unavailable] {
            let result = TVLyricsTimeline(document: .init(trackID: "test", kind: kind, lines: lines, plainText: "Ignore"))
            XCTAssertEqual(result.mode, kind == .instrumental ? .instrumental : .unavailable)
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(result.pages.isEmpty)
            XCTAssertEqual(result.window(at: 5, offset: 0, duration: 20), .init())
        }
    }

    func testUntimedPagesKeepOrderWithoutFabricatingTimestamps() {
        let document = LyricsDocument(trackID: "test", kind: .plain, plainText: "First page\n\nSecond page\n Third page ")
        let result = TVLyricsTimeline(document: document)
        XCTAssertEqual(result.mode, .untimed)
        XCTAssertEqual(result.pages, ["First page", "Second page", "Third page"])
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.window(at: 999, offset: -10, duration: nil), .init())
    }

    func testPlainFallbackAndUnicodePaginationPreserveText() {
        let unicode = String(repeating: "क्ष", count: 150)
        let document = LyricsDocument(trackID: "test", kind: .synced, plainText: unicode)
        let result = TVLyricsTimeline(document: document)
        XCTAssertEqual(result.mode, .untimed)
        XCTAssertGreaterThan(result.pages.count, 1)
        XCTAssertEqual(result.pages.joined(), unicode)
        XCTAssertTrue(result.pages.allSatisfy { $0.count <= TVLyricsTimeline.charactersPerPage })
    }

    func testInvalidTimesAreExcludedAndDuplicateTimestampsKeepInputOrder() {
        let malformed = [LyricLine(id: 90, time: 9, text: "Last"),
                         LyricLine(id: 1, time: .nan, text: "Invalid"),
                         LyricLine(id: 2, time: -1, text: "Invalid"),
                         LyricLine(id: 8, time: 2, text: "First at time"),
                         LyricLine(id: 8, time: 2, text: "Last at time")]
        let result = TVLyricsTimeline(document: .init(trackID: "test", kind: .synced, lines: malformed))
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.window(at: 2, offset: 0, duration: 20).current?.text, "Last at time")
        XCTAssertEqual(result.window(at: 2, offset: 0, duration: 20).next?.text, "Last")
    }

    func testOversizedDocumentsFailClosed() {
        let excessiveText = String(repeating: "x", count: LRCParser.maximumSourceBytes + 1)
        XCTAssertEqual(TVLyricsTimeline(document: .init(trackID: "test", kind: .plain, plainText: excessiveText)).mode,
                       .unavailable)
        let excessivePages = String(repeating: "x\n", count: LRCParser.maximumLines + 1)
        XCTAssertEqual(TVLyricsTimeline(document: .init(trackID: "test", kind: .plain, plainText: excessivePages)).mode,
                       .unavailable)
    }
}
