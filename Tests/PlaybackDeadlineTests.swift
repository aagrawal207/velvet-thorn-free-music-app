import XCTest
@testable import GanaBajana

private actor PlaybackDeadlineGate {
    private var continuation: CheckedContinuation<Int, Never>?
    private var released = false
    private(set) var started = false

    func wait() async -> Int {
        started = true
        if released { return 42 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(returning: 42); continuation = nil }
}

final class PlaybackDeadlineTests: XCTestCase {
    func testDeadlineReturnsWithoutWaitingForNoncooperativeWork() async throws {
        let gate = PlaybackDeadlineGate()
        let start = ContinuousClock.now
        do {
            _ = try await PlaybackDeadline.run(seconds: 0.1) { await gate.wait() }
            XCTFail("Expected deadline")
        } catch { XCTAssertTrue(error is PlaybackStreamError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        await gate.release()
    }

    func testCancellationReturnsPromptlyAndLateSuccessIsIgnored() async throws {
        let gate = PlaybackDeadlineGate()
        let task = Task { try await PlaybackDeadline.run(seconds: 30) { await gate.wait() } }
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
    }
}
