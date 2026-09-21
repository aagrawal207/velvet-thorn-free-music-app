import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class ArtworkCancellationTests: XCTestCase {
    private typealias Waiter = (task: Task<UIImage?, Never>, completions: CatalogTestRecorder<Bool>)

    func testSoleWaiterCancellationStopsPartialArtworkAndDrainsUsage() async throws {
        let (loader, fixture) = makeLoader()
        let waiter = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        beginPartialImage(transfer, for: waiter)
        let before = await loader.storageUsage()
        XCTAssertEqual(before.pendingImages, 1)
        XCTAssertEqual(before.decodedBytes, 0)

        waiter.task.cancel()

        try await expectCompletion(waiter, hasImage: false)
        try await PlaybackTestSupport.eventually(timeout: 2) { transfer.cancellations == 1 }
        XCTAssertFalse(transfer.didFinish, "Cancellation must stop a body that has not sent EOF")
        XCTAssertFalse(transfer.send(Data([0])))
        try await expectDrained(loader, fixture: fixture)
    }

    func testOneCancelledWaiterReturnsBeforeEOFWhileTheOtherReceivesAndCachesArtwork() async throws {
        let (loader, fixture) = makeLoader()
        let first = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        let png = beginPartialImage(transfer, for: first)
        let second = startWaiter(loader)
        try await PlaybackTestSupport.eventually(timeout: 2) { await loader.activeWaiterCount == 2 }
        XCTAssertEqual(fixture.transfers.count, 1, "Both callers must share the same bounded reader")

        first.task.cancel()

        try await expectCompletion(first, hasImage: false)
        let waiting = await loader.activeWaiterCount
        XCTAssertEqual(waiting, 1)
        XCTAssertEqual(transfer.cancellations, 0)
        XCTAssertTrue(second.completions.values.isEmpty, "The surviving caller is still waiting for the body")
        XCTAssertFalse(transfer.didFinish)
        XCTAssertTrue(transfer.send(png.dropFirst(24)))
        XCTAssertTrue(transfer.finish())
        try await expectCompletion(second, hasImage: true)
        let image = await second.task.value
        XCTAssertEqual(image?.cgImage?.width, 64)
        let cached = await loader.image(for: Self.url, tier: .thumbnail, maxPixels: 64)
        XCTAssertEqual(cached?.cgImage?.width, 64)
        XCTAssertEqual(fixture.transfers.count, 1)
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.pendingImages, 0)
        XCTAssertEqual(usage.decodedImages, 1)
        XCTAssertGreaterThan(usage.decodedBytes, 0)
    }

    func testLastOfTwoCancelledWaitersStopsTheSharedTransfer() async throws {
        let (loader, fixture) = makeLoader()
        let first = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        beginPartialImage(transfer, for: first)
        let second = startWaiter(loader)
        try await PlaybackTestSupport.eventually(timeout: 2) { await loader.activeWaiterCount == 2 }

        first.task.cancel()
        try await expectCompletion(first, hasImage: false)
        XCTAssertEqual(transfer.cancellations, 0)
        second.task.cancel()

        try await expectCompletion(second, hasImage: false)
        try await PlaybackTestSupport.eventually(timeout: 2) { transfer.cancellations == 1 }
        XCTAssertEqual(fixture.transfers.count, 1)
        XCTAssertFalse(transfer.didFinish)
        XCTAssertFalse(transfer.send(Data([0])))
        try await expectDrained(loader, fixture: fixture)
    }

    func testCacheClearDrainsSharedAndCancellingFlightsAndFreshGenerationCanLoad() async throws {
        let (loader, fixture) = makeLoader()
        let first = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        beginPartialImage(transfer, for: first)
        let second = startWaiter(loader)
        let other = startWaiter(loader, url: URL(string: "https://artwork-stream.test/other.png")!)
        try await PlaybackTestSupport.eventually(timeout: 2) {
            await loader.activeWaiterCount == 3 && fixture.transfers.count == 2
        }
        let otherTransfer = fixture.transfers[1]
        beginPartialImage(otherTransfer, for: other)
        other.task.cancel()

        let cleared = await loader.clearCache()

        for waiter in [first, second, other] { try await expectCompletion(waiter, hasImage: false) }
        XCTAssertEqual(cleared.pendingImages, 0)
        XCTAssertEqual(cleared.decodedBytes, 0)
        XCTAssertEqual(cleared.decodedImages, 0)
        try await PlaybackTestSupport.eventually(timeout: 2) {
            transfer.cancellations == 1 && otherTransfer.cancellations == 1
        }
        XCTAssertFalse(transfer.didFinish)
        XCTAssertFalse(otherTransfer.didFinish)
        try await expectDrained(loader, fixture: fixture)

        let fresh = startWaiter(loader)
        let newTransfer = try await firstTransfer(fixture, index: 2)
        XCTAssertFalse(transfer.send(imageData()))
        XCTAssertFalse(transfer.finish())
        XCTAssertTrue(newTransfer.respond())
        XCTAssertTrue(newTransfer.send(imageData()))
        XCTAssertTrue(newTransfer.finish())
        try await expectCompletion(fresh, hasImage: true)
        let image = await fresh.task.value
        XCTAssertEqual(image?.cgImage?.width, 64)
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.decodedImages, 1)
        XCTAssertEqual(usage.pendingImages, 0)
    }

    func testNewCallerAfterLastCancellationGetsANewFlightForTheSameArtwork() async throws {
        let (loader, fixture) = makeLoader()
        let abandoned = startWaiter(loader)
        let oldTransfer = try await firstTransfer(fixture)
        beginPartialImage(oldTransfer, for: abandoned)
        abandoned.task.cancel()
        try await expectCompletion(abandoned, hasImage: false)

        let fresh = startWaiter(loader)
        let newTransfer = try await firstTransfer(fixture, index: 1)
        try await PlaybackTestSupport.eventually(timeout: 2) { oldTransfer.cancellations == 1 }
        XCTAssertFalse(oldTransfer.send(imageData()))
        XCTAssertFalse(oldTransfer.finish())
        XCTAssertTrue(fresh.completions.values.isEmpty)
        XCTAssertEqual(newTransfer.cancellations, 0)
        let before = await loader.storageUsage()
        XCTAssertEqual(before.decodedImages, 0)
        XCTAssertTrue(newTransfer.respond())
        XCTAssertTrue(newTransfer.send(imageData()))
        XCTAssertTrue(newTransfer.finish())

        try await expectCompletion(fresh, hasImage: true)
        let image = await fresh.task.value
        XCTAssertEqual(image?.cgImage?.width, 64)
        let cached = await loader.image(for: Self.url, tier: .thumbnail, maxPixels: 64)
        XCTAssertEqual(cached?.cgImage?.width, 64)
        XCTAssertEqual(fixture.transfers.count, 2)
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.pendingImages, 0)
        XCTAssertEqual(usage.decodedImages, 1)
    }

    func testDifferentPixelSizesKeepIndependentFlightsAndDecodedCacheEntries() async throws {
        let (loader, fixture) = makeLoader()
        let small = startWaiter(loader, maxPixels: 64)
        let smallTransfer = try await firstTransfer(fixture)
        beginPartialImage(smallTransfer, for: small)
        let large = startWaiter(loader, maxPixels: 128)
        let largeTransfer = try await firstTransfer(fixture, index: 1)
        let png = beginPartialImage(largeTransfer, for: large)
        small.task.cancel()
        try await expectCompletion(small, hasImage: false)
        try await PlaybackTestSupport.eventually(timeout: 2) { smallTransfer.cancellations == 1 }
        XCTAssertEqual(largeTransfer.cancellations, 0)
        XCTAssertTrue(largeTransfer.send(png.dropFirst(24)))
        XCTAssertTrue(largeTransfer.finish())
        try await expectCompletion(large, hasImage: true)
        let largeImage = await large.task.value
        XCTAssertEqual(largeImage?.cgImage?.width, 128)

        let replacement = startWaiter(loader, maxPixels: 64)
        let newTransfer = try await firstTransfer(fixture, index: 2)
        XCTAssertTrue(newTransfer.respond())
        XCTAssertTrue(newTransfer.send(png))
        XCTAssertTrue(newTransfer.finish())
        try await expectCompletion(replacement, hasImage: true)
        let smallImage = await replacement.task.value
        XCTAssertEqual(smallImage?.cgImage?.width, 64)
        for size in [64, 128] {
            let cached = await loader.image(for: Self.url, tier: .thumbnail, maxPixels: size)
            XCTAssertEqual(cached?.cgImage?.width, size)
        }
        XCTAssertEqual(fixture.transfers.count, 3)
        let usage = await loader.storageUsage()
        XCTAssertEqual(usage.decodedImages, 2)
        XCTAssertEqual(usage.pendingImages, 0)
    }

    func testResourceDeadlineStopsTricklingArtworkWithoutEOFOrCallerCancellation() async throws {
        let (loader, fixture) = makeLoader(resourceTimeout: 1.5)
        let waiter = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        beginPartialImage(transfer, for: waiter)
        let trickle = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard transfer.send(Data([0])) else { return }
            }
        }
        defer { trickle.cancel() }

        try await expectCompletion(waiter, hasImage: false, timeout: 4)

        XCTAssertFalse(waiter.task.isCancelled, "The resource deadline must work without a disappearing view")
        XCTAssertGreaterThan(transfer.deliveredChunks, 2, "The response keeps making progress during the deadline")
        XCTAssertLessThan(transfer.deliveredBytes, 12 << 20, "The resource deadline must not rely on the byte cap")
        XCTAssertEqual(fixture.session.configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(fixture.session.configuration.timeoutIntervalForResource, 120)
        try await PlaybackTestSupport.eventually(timeout: 2) { transfer.cancellations == 1 }
        XCTAssertFalse(transfer.didFinish)
        try await expectDrained(loader, fixture: fixture)
    }

    func testAlreadyCancelledArtworkCallerDoesNotCreateAFlight() async throws {
        let (loader, fixture) = makeLoader()
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await loader.image(for: Self.url, tier: .thumbnail, maxPixels: 64)
        }
        let image = await work.value
        XCTAssertNil(image)
        XCTAssertTrue(fixture.transfers.isEmpty)
        try await expectDrained(loader, fixture: fixture)
    }

    func testCancellationRacingEOFDoesNotPublishAbandonedArtwork() async throws {
        let (loader, fixture) = makeLoader()
        let waiter = startWaiter(loader)
        let transfer = try await firstTransfer(fixture)
        let png = beginPartialImage(transfer, for: waiter)
        XCTAssertTrue(transfer.send(png.dropFirst(24)))

        waiter.task.cancel()
        _ = transfer.finish()

        try await expectCompletion(waiter, hasImage: false)
        try await expectDrained(loader, fixture: fixture)
    }

    private static let url = URL(string: "https://artwork-stream.test/cover.png")!

    private func makeLoader(resourceTimeout: TimeInterval = 30) -> (ArtworkLoader, ArtworkStreamingFixture) {
        let fixture = ArtworkStreamingFixture()
        let loader = ArtworkLoader(session: fixture.session, resourceTimeout: resourceTimeout)
        addTeardownBlock {
            _ = await loader.clearCache()
            fixture.close()
        }
        return (loader, fixture)
    }

    private func startWaiter(_ loader: ArtworkLoader, url: URL = ArtworkCancellationTests.url, maxPixels: Int = 64) -> Waiter {
        let completions = CatalogTestRecorder<Bool>()
        let work = Task {
            let image = await loader.image(for: url, tier: .thumbnail, maxPixels: maxPixels)
            completions.record(image != nil)
            return image
        }
        addTeardownBlock { work.cancel() }
        return (work, completions)
    }

    private func firstTransfer(_ fixture: ArtworkStreamingFixture, index: Int = 0) async throws -> ArtworkStreamingTransfer {
        try await PlaybackTestSupport.eventually(timeout: 2) { fixture.transfers.count > index }
        return fixture.transfers[index]
    }

    @discardableResult
    private func beginPartialImage(_ transfer: ArtworkStreamingTransfer, for waiter: Waiter,
                                   file: StaticString = #filePath, line: UInt = #line) -> Data {
        let png = imageData()
        XCTAssertGreaterThan(png.count, 24, "The remaining image bytes must stay withheld", file: file, line: line)
        // Custom URLProtocol delivery does not reliably update URLSessionTask byte counters.
        // These calls acknowledge real client callbacks on the transfer's serial queue, without sending EOF.
        XCTAssertTrue(transfer.respond(), "Response headers must reach the URLProtocol client", file: file, line: line)
        XCTAssertTrue(transfer.send(png.prefix(24)), "The partial body must reach the URLProtocol client", file: file, line: line)
        XCTAssertEqual(transfer.deliveredChunks, 1, file: file, line: line)
        XCTAssertEqual(transfer.deliveredBytes, 24, file: file, line: line)
        XCTAssertTrue(transfer.isAwaitingBodyCompletion, "The partial response must remain open", file: file, line: line)
        XCTAssertFalse(transfer.didFinish, "EOF must stay under the test's control", file: file, line: line)
        XCTAssertEqual(transfer.cancellations, 0, file: file, line: line)
        XCTAssertTrue(waiter.completions.values.isEmpty, "The caller must still be waiting for the image", file: file, line: line)
        return png
    }

    private func expectCompletion(_ waiter: Waiter, hasImage: Bool, timeout: TimeInterval = 2) async throws {
        try await PlaybackTestSupport.eventually(timeout: timeout) { !waiter.completions.values.isEmpty }
        XCTAssertEqual(waiter.completions.values, [hasImage])
    }

    private func expectDrained(_ loader: ArtworkLoader, fixture: ArtworkStreamingFixture) async throws {
        try await PlaybackTestSupport.eventually(timeout: 2) {
            let usage = await loader.storageUsage()
            let tasks = await fixture.session.allTasks
            return usage.pendingImages == 0 && tasks.isEmpty
        }
        let usage = await loader.storageUsage()
        let waiters = await loader.activeWaiterCount
        XCTAssertEqual(waiters, 0)
        XCTAssertEqual(usage.pendingImages, 0)
        XCTAssertEqual(usage.decodedImages, 0)
        XCTAssertEqual(usage.decodedBytes, 0)
        XCTAssertEqual(usage.responseMemoryBytes, 0)
        XCTAssertEqual(usage.diskBytes, 0)
    }

    private func imageData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }
}

private final class ArtworkStreamingFixture: @unchecked Sendable {
    let session: URLSession
    private let id = UUID().uuidString
    private let state = ArtworkStreamingState()
    var transfers: [ArtworkStreamingTransfer] { state.transfers }

    init() {
        ArtworkStreamingURLProtocol.registry.register(state, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkStreamingURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Artwork-Cancellation-Test": id]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration)
    }

    func close() {
        session.invalidateAndCancel()
        ArtworkStreamingURLProtocol.registry.remove(id)
    }
}

private final class ArtworkStreamingState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ArtworkStreamingTransfer] = []
    var transfers: [ArtworkStreamingTransfer] { lock.withLock { recorded } }
    func started(_ transfer: ArtworkStreamingTransfer) { lock.withLock { recorded.append(transfer) } }
}

private final class ArtworkStreamingTransfer: @unchecked Sendable {
    let request: URLRequest
    private let queue = DispatchQueue(label: "ArtworkCancellationTests.transfer")
    private var loading: ArtworkStreamingURLProtocol?
    private var stops = 0
    private var finished = false
    private var responseDelivered = false
    private var chunks = 0
    private var bytes = 0

    init(_ loading: ArtworkStreamingURLProtocol) {
        self.loading = loading
        request = loading.request
    }

    var cancellations: Int { queue.sync { stops } }
    var didFinish: Bool { queue.sync { finished } }
    var deliveredChunks: Int { queue.sync { chunks } }
    var deliveredBytes: Int { queue.sync { bytes } }
    var isAwaitingBodyCompletion: Bool {
        queue.sync { responseDelivered && chunks > 0 && loading != nil && !finished && stops == 0 }
    }

    func respond() -> Bool {
        queue.sync {
            guard let loading, let client = loading.client, !responseDelivered, let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "image/png"]) else { return false }
            client.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
            responseDelivered = true
            return true
        }
    }

    func send(_ data: Data) -> Bool {
        queue.sync {
            guard let loading, let client = loading.client, responseDelivered else { return false }
            client.urlProtocol(loading, didLoad: data)
            chunks += 1
            bytes += data.count
            return true
        }
    }

    func finish() -> Bool {
        queue.sync {
            guard let loading, let client = loading.client, responseDelivered else { return false }
            finished = true
            self.loading = nil
            client.urlProtocolDidFinishLoading(loading)
            return true
        }
    }

    func stop() {
        queue.async {
            if self.loading != nil, !self.finished { self.stops += 1 }
            self.loading = nil
        }
    }
}

private final class ArtworkStreamingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: ArtworkStreamingState] = [:]
    func register(_ state: ArtworkStreamingState, id: String) { lock.withLock { states[id] = state } }
    func remove(_ id: String) { _ = lock.withLock { states.removeValue(forKey: id) } }
    func state(for request: URLRequest) -> ArtworkStreamingState? {
        guard let id = request.value(forHTTPHeaderField: "X-Artwork-Cancellation-Test") else { return nil }
        return lock.withLock { states[id] }
    }
}

private final class ArtworkStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = ArtworkStreamingRegistry()
    private let lock = NSLock()
    private var transfer: ArtworkStreamingTransfer?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let state = Self.registry.state(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let transfer = ArtworkStreamingTransfer(self)
        let wasStopped = lock.withLock { self.transfer = transfer; return stopped }
        state.started(transfer)
        if wasStopped { transfer.stop() }
    }

    override func stopLoading() {
        let transfer = lock.withLock { stopped = true; return self.transfer }
        transfer?.stop()
    }
}
