import XCTest
@testable import GanaBajana

final class LRCParserTests: XCTestCase {
    func testFractionPrecisionAndMultipleTimestamps() {
        let lines = LRCParser.parse("""
        [00:01.809]Synthetic opening
        [00:02.20][00:04.007]Synthetic repeat
        [01:03]Synthetic ending
        [00:03.5]Synthetic bridge
        """)
        for (line, expected) in zip(lines, [1.809, 2.2, 3.5, 4.007, 63]) {
            XCTAssertEqual(line.time, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(lines.map(\.id), [0, 1, 4, 2, 3])
        XCTAssertEqual(lines[1].text, lines[3].text)
    }

    func testGlobalOffsetsUnicodeAndBlankInstrumentalLines() {
        let source = """
        [ar:Synthetic Artist]
        [00:01.50]नई सुबह का रंग
        [00:03.00]
        [00:05.001]A made-up return
        [offset:+250]
        """
        let lines = LRCParser.parse(source)
        XCTAssertEqual(lines.map(\.time), [1.25, 2.75, 4.751])
        XCTAssertEqual(lines[0].text, "नई सुबह का रंग")
        XCTAssertEqual(lines[1].text, "")
        XCTAssertEqual(lines.map(\.id), LRCParser.parse(source).map(\.id))
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 3.5), 1)
    }

    func testEmbeddedOffsetSignClampingAndLastOffsetWins() {
        let lines = LRCParser.parse("[offset:900]\n[00:00.20]Invented dawn\n[00:02]Invented dusk\n[offset:-500]")
        XCTAssertEqual(lines.map(\.time), [0.7, 2.5])
        XCTAssertEqual(LRCParser.parse("[offset:+500]\n[00:00.20]Invented dawn").first?.time, 0)
    }

    func testBracketedWordsAreRetainedAfterTheTimestamp() {
        XCTAssertEqual(LRCParser.parse("[00:01] [A synthetic aside] continues").first?.text,
                       "[A synthetic aside] continues")
        XCTAssertEqual(LRCParser.parse("[00:01] [Aside: synthetic] continues").first?.text,
                       "[Aside: synthetic] continues")
    }

    func testMalformedTagsDoNotPoisonValidLines() {
        let lines = LRCParser.parse("""
        [00:99.20]Invalid seconds
        [bad:tag]Untimed metadata
        [00:01.]Invalid fraction
        [00:02.abc]Invalid fraction
        [-01:03]Invalid sign
        [00:04.000]Valid synthetic phrase
        [offset:NaN]
        [00:05.01][00:90.00]Another synthetic phrase
        """)
        XCTAssertEqual(lines.map(\.time), [4, 5.01])
        XCTAssertEqual(lines.last?.text, "Another synthetic phrase")
    }

    func testStableDuplicateTimesAndDurationBoundary() {
        let source = "[00:05]First\n[00:05]Second\n[00:08]\n[00:12]After the recording"
        let lines = LRCParser.parse(source, duration: 10)
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
        XCTAssertNil(LRCParser.activeLineIndex(in: lines, at: 4.99))
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 5), 1)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 9.99, duration: 10), 2)
        XCTAssertNil(LRCParser.activeLineIndex(in: lines, at: 10, duration: 10))
        XCTAssertNil(LRCParser.activeLineIndex(in: lines, at: .nan))
        XCTAssertNil(LRCParser.activeLineIndex(in: lines, at: -.infinity))
    }

    func testUserOffsetAndSeekUseTheSameSign() {
        let lines = LRCParser.parse("[00:10]A synthetic line\n[00:20]The next synthetic line")
        XCTAssertNil(LRCParser.activeLineIndex(in: lines, at: 10, offset: 0.5))
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 10.5, offset: 0.5), 0)
        XCTAssertEqual(LyricsTiming.seekPosition(for: lines[0], offset: 0.5, duration: 100), 10.5)
        XCTAssertEqual(LyricsTiming.seekPosition(for: lines[0], offset: -0.5, duration: 100), 9.5)
        XCTAssertEqual(LyricsTiming.seekPosition(for: lines[1], offset: 1, duration: 20), 20)
        XCTAssertEqual(LyricsTiming.boundedOffset(.nan), 0)
    }

    func testParserRejectsUnboundedDocumentsRatherThanTruncatingTiming() {
        XCTAssertTrue(LRCParser.parse(String(repeating: "x", count: LRCParser.maximumSourceBytes + 1)).isEmpty)
        XCTAssertTrue(LRCParser.parse(String(repeating: "[00:01]Synthetic\n", count: LRCParser.maximumLines + 1)).isEmpty)
    }

    func testPlainTextNeverAcquiresTiming() {
        XCTAssertTrue(LRCParser.parse("A synthetic plain first line\nA synthetic plain second line").isEmpty)
    }
}
