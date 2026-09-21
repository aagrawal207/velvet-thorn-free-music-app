import Foundation
import XCTest
@testable import YouTubeKit

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class BoundedExtractionTransportTests: ExtractionStreamingTestCase {
    func testDeclaredOversizeCancelsBeforeAnyBodyOrEOF() async throws {
        for length in [Int64(9), Int64.max] {
            let stream = ExtractionTestStream()
            let session = makeSession([stream])
            let work = try await start(stream, session: session)
            XCTAssertTrue(stream.respond(expectedLength: length))
            try await assertOversized(work, stream: stream)
            XCTAssertEqual(stream.deliveredBytes, 0)
        }
    }

    func testUnknownLengthStopsAtTheFirstOverflowingChunk() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]))
        XCTAssertTrue(stream.respond())
        XCTAssertTrue(stream.send(Data([0, 1, 2])))
        XCTAssertTrue(stream.send(Data([3, 4, 5, 6, 7])))
        XCTAssertTrue(stream.send(Data([8])))
        try await assertOversized(work, stream: stream)
        XCTAssertEqual(stream.deliveredBytes, 9)
        XCTAssertEqual(stream.deliveredChunks, 3)
    }

    func testCoalescedDataCannotBypassASmallerDeclaredLength() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]))
        XCTAssertTrue(stream.respond(expectedLength: 1))
        XCTAssertTrue(stream.send(Data(repeating: 0xFF, count: 9)))
        try await assertOversized(work, stream: stream)
        XCTAssertEqual(stream.deliveredChunks, 1)
    }

    func testExactBoundaryRoundTripsKnownUnknownAndOverstatedLengths() async throws {
        let lengths: [Int64?] = [8, nil, 16]
        for length in lengths {
            let stream = ExtractionTestStream()
            let work = try await start(stream, session: makeSession([stream]), limit: length == 16 ? 16 : 8)
            XCTAssertTrue(stream.respond(expectedLength: length))
            let body = Data([0, 1, 0x80, 0xFF, 4, 5, 6, 7])
            XCTAssertTrue(stream.send(body.prefix(3)))
            XCTAssertTrue(stream.send(body.dropFirst(3)))
            XCTAssertTrue(stream.finish())
            let (data, response) = try await work.value
            XCTAssertEqual(data, body)
            XCTAssertEqual(response.expectedContentLength, length ?? -1)
            XCTAssertEqual(stream.cancellations, 0)
        }
    }

    func testEmptyAndHTTPErrorBodiesKeepTheirStatusAndHeaders() async throws {
        for (status, body) in [(204, Data()), (403, Data("denied".utf8))] {
            let stream = ExtractionTestStream()
            let work = try await start(stream, session: makeSession([stream]))
            stream.respond(status: status, expectedLength: Int64(body.count))
            stream.send(body)
            stream.finish()
            let (data, response) = try await work.value
            XCTAssertEqual(data, body)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Streaming-Fixture"), "preserved")
        }
    }

    func testTransportFailureDiscardsPartialData() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]))
        stream.respond()
        stream.send(Data([1, 2]))
        stream.finish(error: URLError(.networkConnectionLost))
        do { _ = try await work.value; XCTFail("Expected the transport failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testInvalidBudgetsDoNotCreateTasks() async throws {
        let stream = ExtractionTestStream()
        let session = makeSession([stream])
        let budgets = [
            ExtractionTransport.Budget(maximumBytes: 0, timeout: 1),
            .init(maximumBytes: -1, timeout: 1), .init(maximumBytes: Int.max, timeout: 1),
            .init(maximumBytes: 1, timeout: 0), .init(maximumBytes: 1, timeout: .infinity),
            .init(maximumBytes: 1, timeout: .nan), .init(maximumBytes: 1, timeout: 61)
        ]
        for budget in budgets {
            do {
                _ = try await ExtractionTransport.data(for: stream.request, budget: budget, session: session)
                XCTFail("Expected an invalid budget")
            } catch { XCTAssertEqual(error as? ExtractionTransportError, .invalidBudget) }
        }
        XCTAssertNil(stream.recordedRequest)
        let tasks = await session.allTasks
        XCTAssertTrue(tasks.isEmpty)
    }

    func testAlreadyCancelledCallerNeverStartsLoading() async throws {
        let stream = ExtractionTestStream()
        let session = makeSession([stream])
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ExtractionTransport.data(for: stream.request, budget: .html, session: session)
        }
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(stream.recordedRequest)
    }

    func testCancellationBeforeHeadersAndDuringAStalledBodyStopsOnlyThatTask() async throws {
        for sendHeaders in [false, true] {
            let stream = ExtractionTestStream()
            let session = makeSession([stream])
            let work = try await start(stream, session: session)
            if sendHeaders {
                stream.respond()
                stream.send(Data([1, 2, 3]))
            }
            work.cancel()
            try await eventually { stream.cancellations == 1 }
            do { _ = try await work.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(stream.didFinish)
            XCTAssertFalse(stream.send(Data([4])))
        }
    }

    func testNativeCancellationIsNormalized() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]))
        stream.respond()
        stream.finish(error: URLError(.cancelled))
        do { _ = try await work.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testResourceDeadlineStopsAHeaderlessRequest() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]), timeout: 0.5)
        try await eventually { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected a resource timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertFalse(stream.didFinish)
        XCTAssertEqual(stream.deliveredBytes, 0)
    }

    func testResourceDeadlineIsNotResetByContinuouslyArrivingBytes() async throws {
        let stream = ExtractionTestStream()
        let work = try await start(stream, session: makeSession([stream]), limit: 1_000, timeout: 0.6)
        stream.respond()
        for _ in 0..<100 {
            if !stream.send(Data([1])) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await eventually { stream.cancellations == 1 }
        do { _ = try await work.value; XCTFail("Expected an overall resource timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertGreaterThan(stream.deliveredChunks, 1)
        XCTAssertLessThan(stream.deliveredChunks, 100)
        XCTAssertFalse(stream.didFinish)
    }

    func testConcurrentSameURLRequestsAndLaterRequestsSurviveSiblingRejection() async throws {
        for cancel in [false, true] {
            let first = ExtractionTestStream(path: "/same-url")
            let sibling = ExtractionTestStream(path: "/same-url")
            let later = ExtractionTestStream(path: "/same-url")
            let session = makeSession([first, sibling, later])
            let rejected = try await start(first, session: session)
            let accepted = try await start(sibling, session: session, limit: 16)
            first.respond()
            sibling.respond()
            sibling.send(Data([1, 2]))
            if cancel { rejected.cancel() }
            else { first.send(Data(repeating: 1, count: 9)) }
            try await eventually { first.cancellations == 1 }
            do { _ = try await rejected.value; XCTFail("Expected rejection") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ExtractionTransportError, .responseTooLarge) }
            }
            XCTAssertEqual(sibling.cancellations, 0)
            sibling.send(Data(repeating: 3, count: 10))
            sibling.finish()
            let (data, _) = try await accepted.value
            XCTAssertEqual(data, Data([1, 2]) + Data(repeating: 3, count: 10))

            let subsequent = try await start(later, session: session)
            later.complete(Data([7]))
            let (next, _) = try await subsequent.value
            XCTAssertEqual(next, Data([7]))
            XCTAssertEqual(later.recordedRequest?.value(forHTTPHeaderField: "X-Fixture-Configuration"), "preserved")
            XCTAssertFalse(later.recordedRequest?.httpShouldHandleCookies ?? true)
        }
    }

    func testDeadlineDoesNotInvalidateTheSharedSessionOrItsSibling() async throws {
        let expired = ExtractionTestStream()
        let sibling = ExtractionTestStream()
        let session = makeSession([expired, sibling])
        let first = try await start(expired, session: session, timeout: 0.5)
        let second = try await start(sibling, session: session, timeout: 5)
        sibling.respond()
        sibling.send(Data([1]))
        try await eventually { expired.cancellations == 1 }
        do { _ = try await first.value; XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(sibling.cancellations, 0)
        sibling.send(Data([2]))
        sibling.finish()
        let (data, _) = try await second.value
        XCTAssertEqual(data, Data([1, 2]))
    }

    func testOrdinaryInjectedSessionsStillUseReceiptLimitsAndPreserveTheirConfiguration() async throws {
        let oversized = ExtractionTestStream()
        let later = ExtractionTestStream()
        let session = makeSession([oversized, later], ordinarySession: true)
        let work = try await start(oversized, session: session)
        oversized.respond()
        oversized.send(Data(repeating: 1, count: 9))
        try await assertOversized(work, stream: oversized)
        let next = try await start(later, session: session)
        later.complete(Data([1]))
        let (data, _) = try await next.value
        XCTAssertEqual(data, Data([1]))
        XCTAssertEqual(later.recordedRequest?.value(forHTTPHeaderField: "X-Fixture-Configuration"), "preserved")
        XCTAssertNil(session.delegate)
    }
}
