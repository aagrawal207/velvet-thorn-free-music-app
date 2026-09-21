import XCTest
@testable import GanaBajana

@MainActor
final class AudioCacheManagementTests: XCTestCase {
    func testUsageCountsOnlyCompleteFilesAndReportsTheActualPolicyAndPins() async throws {
        let fixture = try makeFixture(capacityBytes: 1_048_576, maximumFiles: 7)
        let first = try fixture.seed("complete-a")
        let second = try fixture.seed("complete-b", seconds: 2)
        await fixture.cache.pin("complete-b")
        try Data([1, 2, 3]).write(to: fixture.cache.directory.appendingPathComponent("truncated.wav"))
        try fixture.sidecar("truncated", bytes: 100)
        try fixture.sidecar("missing", bytes: 100)
        try Data([1, 2, 3]).write(to: fixture.cache.directory.appendingPathComponent("orphan.wav"))
        try Data([1, 2, 3]).write(to: fixture.cache.directory.appendingPathComponent("pending-\(UUID()).part"))
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted()

        let usage = try await fixture.cache.storageUsage()

        XCTAssertEqual(usage.bytes, Int64(try Data(contentsOf: first).count + Data(contentsOf: second).count))
        XCTAssertEqual(usage.songCount, 2)
        XCTAssertEqual(usage.retainedBytes, Int64(try Data(contentsOf: second).count))
        XCTAssertEqual(usage.retainedSongCount, 1)
        XCTAssertEqual(usage.capacityBytes, 1_048_576)
        XCTAssertEqual(usage.maximumSongs, 7)
        XCTAssertEqual(usage.pendingDownloads, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path).sorted(), names,
                       "Measuring storage must not prune files or change the cache's contents")
    }

    func testClearRetainsPinsFreshPlaybackSnapshotAndReadsDuringTheClear() async throws {
        let fixture = try makeFixture()
        let ids = ["pinned", "new-pin", "read-during-clear", "live-player", "unused"]
        for id in ids { try fixture.seed(id) }
        let partial = fixture.cache.directory.appendingPathComponent("pinned-\(UUID()).part")
        try Data([1, 2, 3]).write(to: partial)
        await fixture.cache.pin("pinned")
        let gate = AppModelRequestGate<String, Set<String>>()
        addTeardownBlock { await gate.close() }
        let clear = Task { try await fixture.cache.clearUnused { (try? await gate.receive("snapshot")) ?? [] } }
        let request = try await gate.request(at: 0)
        await fixture.cache.unpin("pinned")
        await fixture.cache.pin(only: ["new-pin"])
        let readDuringClear = await fixture.cache.entry(for: "read-during-clear")
        XCTAssertNotNil(readDuringClear)
        try await gate.complete(request, with: .success(["live-player"]))

        let usage = try await clear.value

        XCTAssertEqual(usage.songCount, 4)
        XCTAssertEqual(usage.retainedSongCount, 4)
        XCTAssertEqual(usage.retainedBytes, Int64(PlaybackTestSupport.audioData(seconds: 1).count) * 4)
        for id in ids.dropLast() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("\(id).wav").path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cache.directory.appendingPathComponent("unused.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "A cancelled partial transfer is not used by the player")
    }

    func testClearCancelsActiveAndQueuedWritersAndRejectsAPreClearWritePermit() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture { request in
            let delay: TimeInterval = request.url?.query?.contains("id=active") == true ? 10 : 0
            return CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: delay)
        }
        let oldPermit = try await fixture.cache.writePermit()
        let activeURL = AudioCacheTests.remote("active")
        let queuedURL = AudioCacheTests.remote("queued")
        let active = Task { try await fixture.cache.store(trackID: "active", from: activeURL, stream: ResolvedStream(url: activeURL)) }
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        let queued = Task { try await fixture.cache.store(trackID: "queued", from: queuedURL, stream: ResolvedStream(url: queuedURL)) }
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 2 }
        let before = try await fixture.cache.storageUsage()
        XCTAssertEqual(before.pendingDownloads, 2)
        XCTAssertEqual(before.songCount, 0)

        let cleared = try await fixture.cache.clearUnused()
        for task in [active, queued] {
            do { _ = try await task.value; XCTFail("A pre-clear transfer must not publish a cached file") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
        XCTAssertEqual(cleared.bytes, 0)
        XCTAssertEqual(cleared.songCount, 0)
        XCTAssertEqual(cleared.pendingDownloads, 0)
        XCTAssertEqual(fixture.mock.state.requests.count, 1, "The queued transfer never starts")
        try await PlaybackTestSupport.eventually { fixture.mock.state.cancellations == 1 }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])

        do {
            _ = try await fixture.cache.store(trackID: "queued", from: queuedURL, stream: ResolvedStream(url: queuedURL), permit: oldPermit)
            XCTFail("A delayed resolver must not start a writer with a pre-clear permit")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.mock.state.requests.count, 1)
        let fresh = try await fixture.cache.store(trackID: "queued", from: queuedURL, stream: ResolvedStream(url: queuedURL))
        XCTAssertEqual(fresh.bytes, Int64(payload.count), "Fresh playback can populate the cache after a clear")
        let after = try await fixture.cache.storageUsage()
        XCTAssertEqual(after.songCount, 1)
        let cancelled = await fixture.cache.entry(for: "active")
        XCTAssertNil(cancelled)
    }

    func testClearWaitsForAWriterWhoseLastWaiterAlreadyCancelled() async throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        let fixture = try makeFixture { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload, delay: 10)
        }
        let url = AudioCacheTests.remote("cancelled")
        let work = Task { try await fixture.cache.store(trackID: "cancelled", from: url, stream: ResolvedStream(url: url)) }
        try await PlaybackTestSupport.eventually { fixture.mock.state.requests.count == 1 }
        work.cancel()
        _ = await work.result
        try await PlaybackTestSupport.eventually { await fixture.cache.activeWaiterCount == 0 }

        let cleared = try await fixture.cache.clearUnused()

        XCTAssertEqual(cleared.songCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])
        try await PlaybackTestSupport.eventually { fixture.mock.state.cancellations == 1 }
    }

    func testMetadataCannotEscapeTheCacheAndSymlinksAreNotCountedAsSongs() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.cache.directory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside.wav")
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        try payload.write(to: outside)
        let linked = fixture.cache.directory.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        try fixture.sidecar("linked", bytes: Int64(payload.count))
        try fixture.sidecar("escape", bytes: Int64(payload.count), fileExtension: "wav/../../outside.wav")
        let unrelated = fixture.cache.directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: unrelated)

        let before = try await fixture.cache.storageUsage()
        XCTAssertEqual(before.songCount, 0)
        XCTAssertEqual(before.bytes, 0)
        _ = try await fixture.cache.clearUnused()
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: linked.path))
    }

    func testStorageErrorsAreReportedAndUnexpectedDirectoriesArePreserved() async throws {
        let fixture = try makeFixture()
        let blocker = Data("not a directory".utf8)
        try blocker.write(to: fixture.cache.directory)
        do { _ = try await fixture.cache.storageUsage(); XCTFail("A read failure is not an empty cache") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        do { _ = try await fixture.cache.clearUnused(); XCTFail("A failed clear must be reported") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        XCTAssertEqual(try Data(contentsOf: fixture.cache.directory), blocker)

        try FileManager.default.removeItem(at: fixture.cache.directory)
        let unexpected = fixture.cache.directory.appendingPathComponent("unexpected.wav", isDirectory: true)
        try FileManager.default.createDirectory(at: unexpected, withIntermediateDirectories: true)
        let marker = unexpected.appendingPathComponent("keep.txt")
        try blocker.write(to: marker)
        do { _ = try await fixture.cache.clearUnused(); XCTFail("Directories must never be recursively removed as audio") }
        catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        let remote = AudioCacheTests.remote("unexpected")
        do {
            _ = try await fixture.cache.store(trackID: "unexpected", from: remote, stream: ResolvedStream(url: remote))
            XCTFail("A later download must not remove the preserved directory either")
        } catch { XCTAssertTrue(error is AudioCache.ManagementError) }
        XCTAssertEqual(try Data(contentsOf: marker), blocker)
    }

    func testCacheClearPreservesLibraryEvenWhenItSharesTheSuppliedDirectory() async throws {
        let fixture = try makeFixture()
        let library = LibraryStore(directory: fixture.cache.directory)
        let track = libraryTestTrack("saved-song")
        library.toggleFavorite(track)
        let playlist = library.createPlaylist(name: "Keep this playlist")
        library.add(track, to: playlist)
        library.recordRecent(track: track, position: 12)
        library.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-90), seconds: 60)
        library.setLyricsOffset(1.5, for: track.id)
        library.recordSearch("Saved query")
        library.updatePlayback(PlaybackSnapshot(queue: [track], currentIndex: 0, position: 12))
        XCTAssertNil(library.errorMessage)
        let libraryURL = fixture.cache.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: libraryURL)
        let audio = try fixture.seed("cached-song")

        let usage = try await fixture.cache.clearUnused()

        XCTAssertEqual(usage.songCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try Data(contentsOf: libraryURL), saved)
        XCTAssertEqual(library.storageBytes, Int64(saved.count))
        let restored = LibraryStore(directory: fixture.cache.directory)
        XCTAssertEqual(restored.favorites, [track])
        XCTAssertEqual(restored.playlists.first?.tracks, [track])
        XCTAssertEqual(restored.recentSearches, ["Saved query"])
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(restored.lyricsOffset(for: track.id), 1.5)
        XCTAssertEqual(restored.playback.position, 12)
    }

    func testAnUnwritableCacheReportsTheRemovalErrorInsteadOfAnEmptyResult() async throws {
        let fixture = try makeFixture()
        let media = try fixture.seed("protected-file")
        let original = try Data(contentsOf: media)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cache.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.cache.directory.path) }

        do { _ = try await fixture.cache.clearUnused(); XCTFail("An unsuccessful removal must throw") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }

        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.songCount, 1)
        XCTAssertEqual(usage.bytes, Int64(original.count))
        XCTAssertEqual(try Data(contentsOf: media), original)
    }

    private func makeFixture(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40,
                             handler: CatalogMockState.Handler? = nil) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(capacityBytes: capacityBytes, maximumFiles: maximumFiles, handler: handler)
        addTeardownBlock { try await fixture.close() }
        return fixture
    }
}
