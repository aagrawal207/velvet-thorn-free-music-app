import Foundation
import XCTest
@testable import GanaBajana

final class PlaybackHandoffTests: XCTestCase {
    // MARK: Codec

    func testRoundTripPreservesPayloadThroughUserInfo() throws {
        let handoff = PlaybackHandoff(senderID: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000), wasPlaying: true,
                                      snapshot: PlaybackSnapshot(queue: tracks(3), currentIndex: 1, position: 42.5, repeatMode: .all))
        let encoded = try PlaybackHandoffCodec.encodeBounded(handoff)
        XCTAssertEqual(encoded.payload, handoff)
        XCTAssertLessThanOrEqual(encoded.data.count, PlaybackHandoffCodec.maximumPayloadBytes)
        XCTAssertEqual(try PlaybackHandoffCodec.decode(encoded.data), handoff)
        let userInfo: [AnyHashable: Any] = try PlaybackHandoffCodec.userInfo(for: handoff)
        XCTAssertEqual(userInfo.count, 1)
        XCTAssertEqual(try PlaybackHandoffCodec.decode(userInfo: userInfo), handoff)
        XCTAssertEqual(PlaybackHandoffCodec.activityType, "com.agraabhi.ganabajana.playback")
    }

    func testUnshuffledQueueOmitsRedundantOriginalOrder() throws {
        var snapshot = PlaybackSnapshot(queue: tracks(3), currentIndex: 2, position: 5)
        snapshot.originalQueue = snapshot.queue
        snapshot.originalQueueIndices = [0, 1, 2]
        let payload = try PlaybackHandoffCodec.encodeBounded(handoff(snapshot)).payload
        XCTAssertNil(payload.snapshot.originalQueue)
        XCTAssertNil(payload.snapshot.originalQueueIndices)
        XCTAssertEqual(payload.snapshot.queue, snapshot.queue)
        XCTAssertEqual(payload.snapshot.currentIndex, 2)
    }

    func testOtherVersionsAreRejected() throws {
        for version in [0, 2, 99] {
            var object = try jsonObject(handoff(PlaybackSnapshot(queue: tracks(1))))
            object["version"] = version
            assertFailure(.unsupportedVersion) { _ = try PlaybackHandoffCodec.decode(compressed(object)) }
        }
        var missing = try jsonObject(handoff(PlaybackSnapshot(queue: tracks(1))))
        missing.removeValue(forKey: "version")
        assertFailure(.malformed) { _ = try PlaybackHandoffCodec.decode(compressed(missing)) }
    }

    func testOversizedMalformedAndExpandingPayloadsAreRejected() throws {
        assertFailure(.missingPayload) { _ = try PlaybackHandoffCodec.decode(userInfo: nil) }
        assertFailure(.missingPayload) { _ = try PlaybackHandoffCodec.decode(userInfo: ["payload": "text"]) }
        assertFailure(.missingPayload) { _ = try PlaybackHandoffCodec.decode(Data()) }
        assertFailure(.tooLarge) {
            _ = try PlaybackHandoffCodec.decode(Data(count: PlaybackHandoffCodec.maximumPayloadBytes + 1))
        }
        assertFailure(.decompression) { _ = try PlaybackHandoffCodec.decode(Data("not compressed".utf8)) }
        let notJSON = try XCTUnwrap((Data("{\"version\": 1, \"queue\": [".utf8) as NSData).compressed(using: .lzfse) as Data)
        assertFailure(.malformed) { _ = try PlaybackHandoffCodec.decode(notJSON) }
        let bomb = try XCTUnwrap((Data(repeating: 0x20, count: 600_000) as NSData).compressed(using: .lzfse) as Data)
        XCTAssertLessThan(bomb.count, PlaybackHandoffCodec.maximumPayloadBytes)
        assertFailure(.tooLarge) { _ = try PlaybackHandoffCodec.decode(bomb) }
    }

    func testInvalidSnapshotsAreRejectedOnDecode() throws {
        let valid = PlaybackSnapshot(queue: tracks(2), currentIndex: 1, position: 10)
        var empty = valid
        empty.queue = []
        empty.currentIndex = 0
        empty.position = 0
        var outOfRange = valid
        outOfRange.currentIndex = 2
        var negative = valid
        negative.position = -1
        var blankID = valid
        blankID.queue[0].id = "  "
        var longID = valid
        longID.queue[0].id = String(repeating: "a", count: PlaybackHandoffCodec.maximumTrackIDBytes + 1)
        var badPermutation = valid
        badPermutation.shuffleEnabled = true
        badPermutation.originalQueue = valid.queue
        badPermutation.originalQueueIndices = [0, 0]
        for snapshot in [empty, outOfRange, negative, blankID, longID, badPermutation] {
            let object = try jsonObject(handoff(snapshot))
            assertFailure(.invalidSnapshot) { _ = try PlaybackHandoffCodec.decode(compressed(object)) }
        }
        var infinite = try jsonObject(handoff(valid))
        infinite["sentAt"] = 1e300
        assertFailure(.invalidTimestamp) { _ = try PlaybackHandoffCodec.decode(compressed(infinite)) }
        var maximumID = valid
        maximumID.queue[0].id = String(repeating: "a", count: PlaybackHandoffCodec.maximumTrackIDBytes)
        XCTAssertNoThrow(try PlaybackHandoffCodec.decode(compressed(jsonObject(handoff(maximumID)))))
    }

    func testWindowKeepsCurrentOccurrenceAndRebasesIndex() throws {
        let queue = tracks(400)
        let payload = try PlaybackHandoffCodec.encodeBounded(handoff(PlaybackSnapshot(queue: queue, currentIndex: 200, position: 7))).payload
        XCTAssertEqual(payload.snapshot.queue, Array(queue[190...350]))
        XCTAssertEqual(payload.snapshot.currentIndex, 10)
        XCTAssertEqual(payload.snapshot.queue[payload.snapshot.currentIndex], queue[200])
        XCTAssertEqual(payload.snapshot.position, 7)

        let early = try PlaybackHandoffCodec.encodeBounded(handoff(PlaybackSnapshot(queue: queue, currentIndex: 3))).payload
        XCTAssertEqual(early.snapshot.queue, Array(queue[0...153]))
        XCTAssertEqual(early.snapshot.currentIndex, 3)
    }

    func testWindowShrinksUntilThePayloadFits() throws {
        // Random titles defeat compression, so the full 161-song window cannot fit in 24 KiB.
        let queue = (0..<400).map { index in
            Track(id: "song-\(index)", title: (0..<12).map { _ in UUID().uuidString }.joined(), artists: ["Artist"], duration: 200)
        }
        let encoded = try PlaybackHandoffCodec.encodeBounded(handoff(PlaybackSnapshot(queue: queue, currentIndex: 200)))
        let window = encoded.payload.snapshot
        XCTAssertLessThanOrEqual(encoded.data.count, PlaybackHandoffCodec.maximumPayloadBytes)
        XCTAssertLessThan(window.queue.count, 161)
        XCTAssertGreaterThan(window.queue.count, 1)
        XCTAssertLessThanOrEqual(window.currentIndex, PlaybackHandoffCodec.windowBefore)
        let start = 200 - window.currentIndex
        XCTAssertEqual(window.queue, Array(queue[start..<(start + window.queue.count)]))
        XCTAssertEqual(try PlaybackHandoffCodec.decode(encoded.data), encoded.payload)

        let huge = Track(id: "huge", title: (0..<3_000).map { _ in UUID().uuidString }.joined(), artists: ["Artist"])
        assertFailure(.tooLarge) { _ = try PlaybackHandoffCodec.encodeBounded(handoff(PlaybackSnapshot(queue: [huge]))) }
    }

    func testShuffledWindowDropsOriginalMappingButKeepsShuffleAndPlayOrder() throws {
        let original = tracks(400)
        let snapshot = shuffledSnapshot(original: original, currentIndex: 200)
        XCTAssertNoThrow(try LibraryValidation.validatePlayback(snapshot))
        let encoded = try PlaybackHandoffCodec.encodeBounded(handoff(snapshot))
        let window = encoded.payload.snapshot
        XCTAssertTrue(window.shuffleEnabled)
        XCTAssertNil(window.originalQueue)
        XCTAssertNil(window.originalQueueIndices)
        XCTAssertEqual(window.queue, Array(snapshot.queue[190...350]))
        XCTAssertEqual(window.queue[window.currentIndex], snapshot.queue[200])
        XCTAssertEqual(try PlaybackHandoffCodec.decode(encoded.data).snapshot.queue, window.queue)

        let small = shuffledSnapshot(original: tracks(5), currentIndex: 1)
        let kept = try PlaybackHandoffCodec.decode(PlaybackHandoffCodec.encodeBounded(handoff(small)).data).snapshot
        XCTAssertEqual(kept.originalQueue, small.originalQueue)
        XCTAssertEqual(kept.originalQueueIndices, small.originalQueueIndices)
        XCTAssertEqual(kept.queue, small.queue)
    }

    func testSignedLookingArtworkIsDropped() throws {
        var signed = libraryTestTrack("signed")
        signed.artworkURL = URL(string: "https://rr1.googlevideo.com/videoplayback?expire=1&signature=abc")
        var plain = libraryTestTrack("plain")
        plain.artworkURL = URL(string: "http://example.org/art.jpg")
        var kept = libraryTestTrack("kept")
        kept.artworkURL = URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")
        let payload = try PlaybackHandoffCodec.encodeBounded(handoff(PlaybackSnapshot(queue: [signed, plain, kept]))).payload
        XCTAssertNil(payload.snapshot.queue[0].artworkURL)
        XCTAssertNil(payload.snapshot.queue[1].artworkURL)
        XCTAssertEqual(payload.snapshot.queue[2].artworkURL, kept.artworkURL)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(json.contains("googlevideo"))
    }

    func testResumePositionAddsBoundedTransferTimeOnlyWhilePlaying() {
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        func payload(_ position: TimeInterval, playing: Bool) -> PlaybackHandoff {
            PlaybackHandoff(senderID: UUID(), sentAt: sentAt, wasPlaying: playing,
                            snapshot: PlaybackSnapshot(queue: tracks(1), position: position))
        }
        XCTAssertEqual(payload(40, playing: true).resumePosition(now: sentAt.addingTimeInterval(10), duration: nil), 50)
        XCTAssertEqual(payload(40, playing: true).resumePosition(now: sentAt.addingTimeInterval(500), duration: nil), 70)
        XCTAssertEqual(payload(40, playing: true).resumePosition(now: sentAt.addingTimeInterval(-60), duration: nil), 40)
        XCTAssertEqual(payload(40, playing: false).resumePosition(now: sentAt.addingTimeInterval(10), duration: nil), 40)
        XCTAssertEqual(payload(238, playing: true).resumePosition(now: sentAt.addingTimeInterval(10), duration: 240), 239)
        XCTAssertEqual(payload(5, playing: false).resumePosition(now: sentAt, duration: 0.5), 0)
        XCTAssertEqual(payload(-3, playing: false).resumePosition(now: sentAt, duration: nil), 0)
        XCTAssertEqual(payload(.nan, playing: true).resumePosition(now: sentAt.addingTimeInterval(4), duration: nil), 4)
    }

    func testDelegateRefreshesPositionAtSaveTimeAndReportsContinuation() throws {
        let continued = expectation(description: "continued")
        let delegate = PlaybackHandoffActivityDelegate { continued.fulfill() }
        let sentAt = Date(timeIntervalSince1970: 1_800_000_000)
        let playing = PlaybackHandoff(senderID: UUID(), sentAt: sentAt, wasPlaying: true,
                                      snapshot: PlaybackSnapshot(queue: tracks(1), position: 20))
        XCTAssertNil(delegate.refreshedPayload(at: sentAt))
        delegate.store(playing, duration: 200)
        XCTAssertEqual(delegate.refreshedPayload(at: sentAt.addingTimeInterval(90))?.snapshot.position, 110)
        XCTAssertEqual(delegate.refreshedPayload(at: sentAt.addingTimeInterval(90))?.sentAt, sentAt.addingTimeInterval(90))
        XCTAssertEqual(delegate.refreshedPayload(at: sentAt.addingTimeInterval(900))?.snapshot.position, 199)
        var paused = playing
        paused.wasPlaying = false
        delegate.store(paused, duration: 200)
        XCTAssertEqual(delegate.refreshedPayload(at: sentAt.addingTimeInterval(90))?.snapshot.position, 20)

        let activity = NSUserActivity(activityType: PlaybackHandoffCodec.activityType)
        delegate.userActivityWillSave(activity)
        let saved = try PlaybackHandoffCodec.decode(userInfo: activity.userInfo)
        XCTAssertEqual(saved.snapshot.position, 20)
        delegate.userActivityWasContinued(activity)
        wait(for: [continued], timeout: 1)
        delegate.clear()
        XCTAssertNil(delegate.refreshedPayload(at: sentAt))
    }

    // MARK: Helpers

    private func tracks(_ count: Int) -> [Track] {
        (0..<count).map { libraryTestTrack("song-\($0)") }
    }

    private func handoff(_ snapshot: PlaybackSnapshot) -> PlaybackHandoff {
        PlaybackHandoff(senderID: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000), wasPlaying: false, snapshot: snapshot)
    }

    /// Play order reverses the original order, with an explicit occurrence mapping.
    private func shuffledSnapshot(original: [Track], currentIndex: Int) -> PlaybackSnapshot {
        let count = original.count
        return PlaybackSnapshot(queue: original.reversed(), currentIndex: currentIndex, position: 3, shuffleEnabled: true,
                                originalQueue: original, originalQueueIndices: (0..<count).map { count - 1 - $0 })
    }

    private func jsonObject(_ handoff: PlaybackHandoff) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(handoff)) as? [String: Any])
    }

    private func compressed(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object)
        return try XCTUnwrap((json as NSData).compressed(using: .lzfse) as Data)
    }

    private func assertFailure(_ expected: PlaybackHandoffCodec.Failure, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PlaybackHandoffCodec.Failure, expected, file: file, line: line)
        }
    }
}
