import XCTest
@testable import GanaBajana

@MainActor
final class AlbumDescriptionLoaderTests: XCTestCase {
    func testAlreadyProvidedDescriptionNeedsNoLookup() async {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let album = AlbumDescriptionFixtures.collection()
        let description = AlbumDescriptionFixtures.document()
        loader.accept(description, for: album)
        await loader.load(for: album, using: provider)
        let count = await provider.requestCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(loader.state, .loaded(description))
    }

    func testLateSuccessCannotAttachToAnotherAlbum() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let firstAlbum = AlbumDescriptionFixtures.collection()
        let secondAlbum = AlbumDescriptionFixtures.collection(id: AlbumDescriptionFixtures.otherID)
        let first = Task { await loader.load(for: firstAlbum, using: provider) }
        try await provider.waitForRequests(1)
        let second = Task { await loader.load(for: secondAlbum, using: provider) }
        try await provider.waitForRequests(2)
        let expected = AlbumDescriptionFixtures.document(id: secondAlbum.id)
        await provider.complete(1, with: expected)
        await second.value
        await provider.complete(0, with: AlbumDescriptionFixtures.document())
        await first.value
        XCTAssertEqual(loader.collection, secondAlbum)
        XCTAssertEqual(loader.state, .loaded(expected))
    }

    func testSameIDWithNewMetadataAndLateFailureCannotReplaceNewerState() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let original = AlbumDescriptionFixtures.collection()
        let corrected = AlbumDescriptionFixtures.collection(title: "Paper Satellites (Live)")
        let first = Task { await loader.load(for: original, using: provider) }
        try await provider.waitForRequests(1)
        let second = Task { await loader.load(for: corrected, using: provider) }
        try await provider.waitForRequests(2)
        let expected = AlbumDescriptionFixtures.document(title: corrected.title)
        await provider.complete(1, with: expected)
        await second.value
        await provider.fail(0)
        await first.value
        XCTAssertEqual(loader.collection, corrected)
        XCTAssertEqual(loader.state, .loaded(expected))
    }

    func testMissingDescriptionIsDistinctFromFailureAndDoesNotAutomaticallyRetry() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let album = AlbumDescriptionFixtures.collection()
        let first = Task { await loader.load(for: album, using: provider) }
        try await provider.waitForRequests(1)
        await provider.complete(0, with: nil)
        await first.value
        XCTAssertEqual(loader.state, .unavailable)
        await loader.load(for: album, using: provider)
        let count = await provider.requestCount
        XCTAssertEqual(count, 1)

        let unsupported = AlbumDescriptionLoader()
        await unsupported.load(for: album, using: nil)
        XCTAssertEqual(unsupported.state, .unavailable)
    }

    func testExplicitRetryClearsFailureAndRejectsWrongAlbumIDs() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let album = AlbumDescriptionFixtures.collection()
        let first = Task { await loader.load(for: album, using: provider) }
        try await provider.waitForRequests(1)
        await provider.fail(0)
        await first.value
        XCTAssertEqual(loader.state, .failed)
        await loader.load(for: album, using: provider)
        let count = await provider.requestCount
        XCTAssertEqual(count, 1, "A view update must not turn into an automatic retry loop")

        let mismatch = Task { await loader.load(for: album, using: provider, retry: true) }
        try await provider.waitForRequests(2)
        XCTAssertEqual(loader.state, .loading)
        await provider.complete(1, with: AlbumDescriptionFixtures.document(id: AlbumDescriptionFixtures.otherID))
        await mismatch.value
        XCTAssertEqual(loader.state, .failed)

        let retry = Task { await loader.load(for: album, using: provider, retry: true) }
        try await provider.waitForRequests(3)
        await provider.complete(2, with: AlbumDescriptionFixtures.document())
        await retry.value
        XCTAssertEqual(loader.state, .loaded(AlbumDescriptionFixtures.document()))
    }

    func testCallerAndViewCancellationRetireResultsAndAllowANewLoad() async throws {
        for cancelView in [false, true] {
            let provider = AlbumDescriptionControlledProvider()
            let loader = AlbumDescriptionLoader()
            let album = AlbumDescriptionFixtures.collection()
            let first = Task { await loader.load(for: album, using: provider) }
            try await provider.waitForRequests(1)
            if cancelView { loader.cancel() } else { first.cancel() }
            await first.value
            XCTAssertEqual(loader.state, .idle)
            let second = Task { await loader.load(for: album, using: provider) }
            try await provider.waitForRequests(2)
            await provider.complete(0, with: AlbumDescriptionFixtures.document())
            XCTAssertEqual(loader.state, .loading, "The retired result cannot satisfy a newer lookup")
            await provider.complete(1, with: nil)
            await second.value
            XCTAssertEqual(loader.state, .unavailable)
        }
    }

    func testDeadlineDoesNotDependOnAnInjectedProviderCooperatingWithCancellation() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader(timeout: 0.1)
        let album = AlbumDescriptionFixtures.collection()
        let started = Date()
        let task = Task { await loader.load(for: album, using: provider) }
        try await provider.waitForRequests(1)
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(loader.state, .failed)
        await provider.complete(0, with: AlbumDescriptionFixtures.document())
        XCTAssertEqual(loader.state, .failed)
    }

    func testCatalogDescriptionSupersedesPendingOptionalLookupAndNeedsNoSecondRequest() async throws {
        let provider = AlbumDescriptionControlledProvider()
        let loader = AlbumDescriptionLoader()
        let album = AlbumDescriptionFixtures.collection()
        let work = Task { await loader.load(for: album, using: provider) }
        try await provider.waitForRequests(1)
        let description = AlbumDescriptionFixtures.document()
        loader.accept(description, for: album)
        await provider.fail(0)
        await work.value
        await loader.load(for: album, using: provider)
        let count = await provider.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(loader.state, .loaded(description))
        loader.accept(AlbumDescriptionFixtures.document(id: AlbumDescriptionFixtures.otherID), for: album)
        XCTAssertEqual(loader.state, .failed)
    }
}

private actor AlbumDescriptionControlledProvider: AlbumDescriptionProviding {
    private var pending: [Int: CheckedContinuation<AlbumDescription?, Error>] = [:]
    private(set) var requestCount = 0

    func albumDescription(id: String) async throws -> AlbumDescription? {
        try await withCheckedThrowingContinuation { continuation in
            pending[requestCount] = continuation
            requestCount += 1
        }
    }

    func complete(_ request: Int, with result: AlbumDescription?) { pending.removeValue(forKey: request)?.resume(returning: result) }
    func fail(_ request: Int) { pending.removeValue(forKey: request)?.resume(throwing: URLError(.notConnectedToInternet)) }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1_000 {
            if requestCount >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw URLError(.timedOut)
    }
}
