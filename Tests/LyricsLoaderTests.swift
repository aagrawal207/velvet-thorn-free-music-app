import XCTest
@testable import GanaBajana

@MainActor
final class LyricsLoaderTests: XCTestCase {
    func testAnOlderSuccessfulLoadCannotOverwriteTheCurrentTrack() async throws {
        let provider = LyricsControlledProvider()
        let loader = LyricsLoader()
        let firstTrack = LyricsTestFixtures.track
        var next = firstTrack
        next.id = "next-track"
        let nextTrack = next
        let first = Task { await loader.load(for: firstTrack, using: provider) }
        try await provider.waitForRequest(firstTrack.id)
        let second = Task { await loader.load(for: nextTrack, using: provider) }
        try await provider.waitForRequest(nextTrack.id)
        await provider.complete(nextTrack.id)
        await second.value
        await provider.complete(firstTrack.id)
        await first.value
        guard case .loaded(let document) = loader.state else { return XCTFail("Expected loaded lyrics") }
        XCTAssertEqual(document.trackID, nextTrack.id)
        XCTAssertEqual(loader.track?.id, nextTrack.id)
    }

    func testStaleFailureAndCancelledResultsCannotReplaceTheCurrentState() async throws {
        let provider = LyricsControlledProvider()
        let loader = LyricsLoader()
        let firstTrack = LyricsTestFixtures.track
        var next = firstTrack
        next.id = "next-track"
        let nextTrack = next
        let first = Task { await loader.load(for: firstTrack, using: provider) }
        try await provider.waitForRequest(firstTrack.id)
        let second = Task { await loader.load(for: nextTrack, using: provider) }
        try await provider.waitForRequest(nextTrack.id)
        await provider.complete(nextTrack.id)
        await second.value
        await provider.fail(firstTrack.id)
        await first.value
        guard case .loaded(let document) = loader.state else { return XCTFail("Stale error replaced current state") }
        XCTAssertEqual(document.trackID, nextTrack.id)

        let cancelled = Task { await loader.load(for: firstTrack, using: provider) }
        try await provider.waitForRequest(firstTrack.id)
        cancelled.cancel()
        await provider.complete(firstTrack.id)
        await cancelled.value
        guard case .loading = loader.state else { return XCTFail("Cancelled result was published") }
    }

    func testRetryClearsErrorAndRejectsProviderTrackIDMismatch() async throws {
        let provider = LyricsControlledProvider()
        let loader = LyricsLoader()
        let track = LyricsTestFixtures.track
        let failed = Task { await loader.load(for: track, using: provider) }
        try await provider.waitForRequest(track.id)
        await provider.fail(track.id)
        await failed.value
        guard case .failed = loader.state else { return XCTFail("Failure state missing") }
        let retry = Task { await loader.load(for: track, using: provider) }
        try await provider.waitForRequest(track.id)
        guard case .loading = loader.state else { return XCTFail("Retry did not clear error") }
        await provider.complete(track.id, documentTrackID: "wrong-id")
        await retry.value
        guard case .failed = loader.state else { return XCTFail("Accepted mismatched lyrics") }
    }
}

private actor LyricsControlledProvider: LyricsProviding {
    private var pending: [String: CheckedContinuation<LyricsDocument, any Error>] = [:]

    func lyrics(for track: Track) async throws -> LyricsDocument {
        try await withCheckedThrowingContinuation { pending[track.id] = $0 }
    }

    func complete(_ trackID: String, documentTrackID: String? = nil) {
        pending.removeValue(forKey: trackID)?.resume(returning: LyricsDocument(trackID: documentTrackID ?? trackID,
                                                                               kind: .plain, plainText: "Synthetic text"))
    }

    func fail(_ trackID: String) {
        pending.removeValue(forKey: trackID)?.resume(throwing: MusicServiceError.network("Synthetic failure"))
    }

    func waitForRequest(_ trackID: String) async throws {
        for _ in 0..<1_000 {
            if pending[trackID] != nil { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw NSError(domain: "LyricsLoaderTests", code: 1)
    }
}
