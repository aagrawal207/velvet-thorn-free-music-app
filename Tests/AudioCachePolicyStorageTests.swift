import XCTest
@testable import GanaBajana

@MainActor
final class AudioCachePolicyStorageTests: XCTestCase {
    func testLoweringTheLimitEvictsOldestUnusedSongsAndKeepsPinsAndLiveFiles() async throws {
        let fixture = try makeFixture()
        let ids = ["pinned", "outgoing", "older-unused", "recent-unused"]
        for (index, id) in ids.enumerated() {
            let url = try fixture.seed(id)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                                                 ofItemAtPath: url.path)
        }
        await fixture.cache.pin("pinned")
        let songBytes = Int64(PlaybackTestSupport.audioData(seconds: 1).count)

        let lowered = try await fixture.cache.updatePolicy(capacityBytes: songBytes * 3, maximumFiles: 20) { ["outgoing"] }

        XCTAssertEqual(lowered.songCount, 3)
        XCTAssertEqual(lowered.retainedSongCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("older-unused.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("recent-unused.wav").path))
        let smaller = try await fixture.cache.updatePolicy(capacityBytes: songBytes, maximumFiles: 1) { ["outgoing"] }
        XCTAssertEqual(smaller.capacityBytes, songBytes)
        XCTAssertEqual(smaller.maximumSongs, 1)
        XCTAssertEqual(smaller.songCount, 2, "Only files in use can remain above the requested limits")
        XCTAssertEqual(smaller.bytes, songBytes * 2)
        XCTAssertEqual(smaller.retainedBytes, songBytes * 2)
    }

    func testPolicyUpdateProtectsReadsAndPinChangesWhileItWaitsForTheLiveSnapshot() async throws {
        let fixture = try makeFixture()
        for id in ["pinned", "read", "new-pin", "snapshot", "unused"] { try fixture.seed(id) }
        await fixture.cache.pin("pinned")
        let gate = AppModelRequestGate<String, Set<String>>()
        addTeardownBlock { await gate.close() }
        let update = Task {
            try await fixture.cache.updatePolicy(capacityBytes: 1, maximumFiles: 1) {
                (try? await gate.receive("live files")) ?? []
            }
        }
        let request = try await gate.request(at: 0)
        await fixture.cache.pin(only: ["new-pin"])
        let read = await fixture.cache.entry(for: "read")
        XCTAssertNotNil(read)
        try await gate.complete(request, with: .success(["snapshot"]))

        let updated = try await update.value

        XCTAssertEqual(updated.retainedSongCount, 4)
        XCTAssertEqual(updated.songCount, 4)
        XCTAssertEqual(updated.capacityBytes, 1)
        XCTAssertEqual(updated.maximumSongs, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("unused.wav").path))
    }

    func testLargerChoicesIncreaseTheRealSongBoundAndShrinkingTrimsImmediately() async throws {
        let fixture = try makeFixture()
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        try FileManager.default.createDirectory(at: fixture.cache.directory, withIntermediateDirectories: true)
        for index in 0..<205 {
            let id = "small-\(index)"
            try payload.write(to: fixture.cache.directory.appendingPathComponent("\(id).wav"))
            try fixture.sidecar(id, bytes: Int64(payload.count))
        }
        let resolver = fixture.resolver()

        let largest = try await resolver.setAudioCacheLimit(.gb5) { [] }
        XCTAssertEqual(largest?.maximumSongs, 1_000)
        XCTAssertEqual(largest?.songCount, 205, "The old forty-song bound must not defeat a larger byte limit")
        XCTAssertEqual(largest?.capacityBytes, 5_368_709_120)
        let standard = try await resolver.setAudioCacheLimit(.gb1) { [] }
        XCTAssertEqual(standard?.maximumSongs, 200)
        XCTAssertEqual(standard?.songCount, 200)
        let small = try await resolver.setAudioCacheLimit(.mb250) { [] }
        XCTAssertEqual(small?.maximumSongs, 50)
        XCTAssertEqual(small?.songCount, 50)
        XCTAssertEqual(small?.capacityBytes, 262_144_000)
    }

    func testShrinkDrainsOldTransfersAndRejectsOldPermitsBeforeAcceptingNewDownloads() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture { request in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload,
                        delay: request.url?.query?.contains("id=old") == true ? 10 : 0)
        }
        let oldURL = AudioCacheTests.remote("old")
        let queuedURL = AudioCacheTests.remote("queued")
        let permit = try await fixture.cache.writePermit()
        let old = Task { try await fixture.cache.store(trackID: "old", from: oldURL, stream: ResolvedStream(url: oldURL), permit: permit) }
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let queued = Task {
            try await fixture.cache.store(trackID: "queued", from: queuedURL, stream: ResolvedStream(url: queuedURL), permit: permit)
        }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }

        let lowered = try await fixture.cache.updatePolicy(capacityBytes: Int64(payload.count), maximumFiles: 1)

        for task in [old, queued] {
            do { _ = try await task.value; XCTFail("Pre-change writers must finish before the limit update returns") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
        XCTAssertEqual(lowered.pendingDownloads, 0)
        XCTAssertEqual(lowered.bytes, 0)
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        do {
            _ = try await fixture.cache.store(trackID: "queued", from: queuedURL, stream: ResolvedStream(url: queuedURL), permit: permit)
            XCTFail("A pre-shrink resolver must not use its old write permit")
        } catch { XCTAssertTrue(error is CancellationError) }
        for id in ["fresh-a", "fresh-b"] {
            let url = AudioCacheTests.remote(id)
            _ = try await fixture.cache.store(trackID: id, from: url, stream: ResolvedStream(url: url))
            let usage = try await fixture.cache.storageUsage()
            XCTAssertLessThanOrEqual(usage.bytes, Int64(payload.count))
            XCTAssertEqual(usage.songCount, 1)
        }
        let stale = await fixture.cache.entry(for: "old")
        XCTAssertNil(stale)
    }

    func testFailedEvictionThrowsAndRestoresThePreviousPolicy() async throws {
        let fixture = try makeFixture()
        let first = try fixture.seed("first")
        let second = try fixture.seed("second")
        let before = try await fixture.cache.storageUsage()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cache.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.cache.directory.path) }

        do {
            _ = try await fixture.cache.updatePolicy(capacityBytes: 1, maximumFiles: 1)
            XCTFail("Failure to evict unused audio must not be reported as a successful limit change")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }

        let after = try await fixture.cache.storageUsage()
        XCTAssertEqual(after.capacityBytes, before.capacityBytes)
        XCTAssertEqual(after.maximumSongs, before.maximumSongs)
        XCTAssertEqual(after.bytes, before.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    private func makeFixture(handler: CatalogMockState.Handler? = nil) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(capacityBytes: AudioCacheLimit.defaultLimit.bytes,
                                                 maximumFiles: AudioCacheLimit.defaultLimit.maximumSongs, handler: handler)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}
