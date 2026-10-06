import XCTest
import YouTubeKit
@testable import GanaBajana

@MainActor
final class ExtractorUpdateTestsPersistence: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeCenter(_ directory: URL) -> ExtractorUpdateCenter {
        ExtractorUpdateCenter(directory: directory, app: ExtractorUpdateFixtures.app, metric: { _, _ in })
    }

    private func activate(_ center: ExtractorUpdateCenter, revision: Int64, confirm: Bool = false) async throws {
        let data = try ExtractorUpdateFixtures.package(revision: revision)
        await center.prepare(source: .manual) { data }
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: true)
        XCTAssertEqual(center.activeRevision, revision)
        if confirm { center.confirmPlaybackSucceeded(generation: center.runtimeGeneration) }
    }

    func testActivatedRulesRepairActualFastPathVisitorExtractionWithoutRebuild() async throws {
        let center = makeCenter(directory())
        center.start()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let oldHTML = #"{"VISITOR_DATA":"fixture-visitor"}"#
        let changedHTML = oldHTML.replacingOccurrences(of: "VISITOR_DATA", with: "VISITOR_TOKEN")
        XCTAssertEqual(YouTubeAudioFastPath.visitorData(in: oldHTML), "fixture-visitor")
        XCTAssertNil(YouTubeAudioFastPath.visitorData(in: changedHTML, compatibility: YouTubeKitHooks.extractionCompatibility.rules))
        try await activate(center, revision: 1)
        XCTAssertEqual(YouTubeAudioFastPath.visitorData(in: changedHTML, compatibility: YouTubeKitHooks.extractionCompatibility.rules), "fixture-visitor")
        center.rollback()
        XCTAssertNil(YouTubeAudioFastPath.visitorData(in: changedHTML, compatibility: YouTubeKitHooks.extractionCompatibility.rules))
        XCTAssertEqual(YouTubeAudioFastPath.visitorData(in: oldHTML), "fixture-visitor")
    }

    func testManualActivationRequiresExplicitTrust() async throws {
        let center = makeCenter(directory())
        center.start()
        let data = try ExtractorUpdateFixtures.package()
        await center.prepare(source: .manual) { data }
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: false)
        XCTAssertNil(center.activeRevision)
        XCTAssertEqual(center.highestRevision, 0)
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: true)
        XCTAssertEqual(center.activeRevision, 1)
        center.useBundled()
    }

    func testConfirmedRelaunchUnconfirmedRecoveryAndMonotonicRollback() async throws {
        let root = directory()
        let center = makeCenter(root)
        center.start()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        try await activate(center, revision: 1, confirm: true)
        let restored = makeCenter(root)
        restored.start()
        XCTAssertEqual(restored.activeRevision, 1)
        XCTAssertFalse(restored.needsPlaybackConfirmation)
        try await activate(restored, revision: 2)
        let recovered = makeCenter(root)
        recovered.start()
        XCTAssertEqual(recovered.activeRevision, 1)
        XCTAssertEqual(recovered.highestRevision, 2)
        XCTAssertTrue(recovered.recoveredUnconfirmed)
        let replay = try ExtractorUpdateFixtures.package(revision: 2)
        await recovered.prepare(source: .manual) { replay }
        XCTAssertNil(recovered.pendingRevision)
        XCTAssertEqual(recovered.activeRevision, 1)
        try await activate(recovered, revision: 3, confirm: true)
        recovered.rollback()
        XCTAssertEqual(recovered.activeRevision, 1)
        XCTAssertEqual(recovered.highestRevision, 3)
        recovered.useBundled()
        let bundled = makeCenter(root)
        bundled.start()
        XCTAssertNil(bundled.activeRevision)
        XCTAssertEqual(bundled.highestRevision, 3)
    }

    func testFirstUnconfirmedPackageFallsBackToBundledOnRestart() async throws {
        let root = directory()
        let center = makeCenter(root)
        center.start()
        try await activate(center, revision: 4)
        let restored = makeCenter(root)
        restored.start()
        XCTAssertNil(restored.activeRevision)
        XCTAssertEqual(restored.highestRevision, 4)
        XCTAssertTrue(restored.recoveredUnconfirmed)
    }

    func testStalePlaybackCannotConfirmANewGeneration() async throws {
        let center = makeCenter(directory())
        center.start()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        try await activate(center, revision: 1)
        let old = center.runtimeGeneration
        try await activate(center, revision: 2)
        center.confirmPlaybackSucceeded(generation: old)
        XCTAssertTrue(center.needsPlaybackConfirmation)
        center.rollback()
        XCTAssertNil(center.activeRevision)
    }

    func testFailedAtomicWriteNeverPublishesRulesOrRevision() async throws {
        var events: [ExtractorUpdateEvent] = []
        let center = ExtractorUpdateCenter(directory: directory(), app: ExtractorUpdateFixtures.app,
            write: { _, _ in throw ExtractorUpdateFailure.storage }, metric: { event, _ in events.append(event) })
        center.start()
        let generation = center.runtimeGeneration
        let data = try ExtractorUpdateFixtures.package()
        await center.prepare(source: .manual) { data }
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: true)
        XCTAssertNil(center.activeRevision)
        XCTAssertEqual(center.highestRevision, 0)
        XCTAssertEqual(center.runtimeGeneration, generation)
        XCTAssertEqual(events, [.prepared, .rejected])
    }

    func testCorruptFutureAndOversizedStoragePreservedAndBlocksOverwrite() async throws {
        for bytes in [Data("broken".utf8), Data(#"{"version":999,"payload":"e30=","sha256":"invalid"}"#.utf8),
                      Data(repeating: 32, count: ExtractorUpdateStore.maximumDiskBytes + 1)] {
            let root = directory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("state.json")
            try bytes.write(to: file)
            let center = makeCenter(root)
            center.start()
            XCTAssertNil(center.activeRevision)
            XCTAssertFalse(center.storageAvailable)
            let package = try ExtractorUpdateFixtures.package()
            await center.prepare(source: .manual) { package }
            center.activatePending(id: UUID(), trustingManualSource: true)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testExternalDiskChangeRejectsActivationWithoutClobberingIt() async throws {
        let root = directory()
        let center = makeCenter(root)
        center.start()
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        try await activate(center, revision: 1, confirm: true)
        let file = root.appendingPathComponent("state.json")
        let external = Data("external-change".utf8)
        try external.write(to: file, options: .atomic)
        let data = try ExtractorUpdateFixtures.package(revision: 2)
        await center.prepare(source: .manual) { data }
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: true)
        XCTAssertEqual(center.activeRevision, 1)
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    func testAppUpgradeRetiresIncompatibleRulesButKeepsRevisionFloor() async throws {
        let root = directory()
        let center = makeCenter(root)
        center.start()
        try await activate(center, revision: 7, confirm: true)
        let upgraded = ExtractorUpdateCenter(directory: root,
            app: .init(bundleID: ExtractorUpdateFixtures.app.bundleID, build: 9), metric: { _, _ in })
        upgraded.start()
        XCTAssertNil(upgraded.activeRevision)
        XCTAssertEqual(upgraded.highestRevision, 7)
        XCTAssertTrue(upgraded.storageAvailable)
    }

    func testCancelledOrSupersededTransportCannotPresentOrActivateLatePackage() async throws {
        let center = makeCenter(directory())
        center.start()
        let gate = ExtractorUpdateReceiveGate()
        let stale = Task { await center.prepare(source: .manual) { await gate.receive() } }
        await gate.waitUntilStarted()
        center.cancel()
        let newer = try ExtractorUpdateFixtures.package(revision: 2)
        await center.prepare(source: .manual) { newer }
        await gate.release(try ExtractorUpdateFixtures.package())
        await stale.value
        XCTAssertEqual(center.pendingRevision, 2)
        XCTAssertFalse(center.isBusy)
        center.activatePending(id: try XCTUnwrap(center.pendingID), trustingManualSource: true)
        XCTAssertEqual(center.activeRevision, 2)
        center.useBundled()
    }

    func testBundledRecoveryRetiresAnOutstandingImport() async throws {
        let center = makeCenter(directory())
        center.start()
        let gate = ExtractorUpdateReceiveGate()
        let task = Task { await center.prepare(source: .manual) { await gate.receive() } }
        await gate.waitUntilStarted()
        center.useBundled()
        await gate.release(try ExtractorUpdateFixtures.package())
        await task.value
        XCTAssertNil(center.pendingRevision)
        XCTAssertNil(center.activeRevision)
    }

    func testEarlierTrustConfirmationCannotActivateAReplacementCandidate() async throws {
        let center = makeCenter(directory())
        center.start()
        let first = try ExtractorUpdateFixtures.package()
        await center.prepare(source: .manual) { first }
        let reviewedID = try XCTUnwrap(center.pendingID)
        let replacement = try ExtractorUpdateFixtures.package(revision: 2)
        await center.prepare(source: .manual) { replacement }
        center.activatePending(id: reviewedID, trustingManualSource: true)
        XCTAssertNil(center.activeRevision)
        XCTAssertEqual(center.pendingRevision, 2)
        center.cancel()
    }

    func testParentTaskCancellationRejectsTransportThatReturnsAfterCancellation() async throws {
        let center = makeCenter(directory())
        center.start()
        let gate = ExtractorUpdateReceiveGate()
        let task = Task { await center.prepare(source: .manual) { await gate.receive() } }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release(try ExtractorUpdateFixtures.package())
        await task.value
        XCTAssertNil(center.pendingRevision)
        XCTAssertFalse(center.isBusy)
    }

    func testNoConfiguredFeedReportsManualSetupWithoutAnyRequest() async {
        var failures: [ExtractorUpdateFailure] = []
        let center = ExtractorUpdateCenter(directory: directory(), app: ExtractorUpdateFixtures.app,
            metric: { _, failure in if let failure { failures.append(failure) } })
        center.start()
        XCTAssertFalse(center.feedConfigured)
        await center.checkFeed()
        XCTAssertNil(center.pendingRevision)
        XCTAssertEqual(failures, [.feedNotConfigured])
    }
}

private actor ExtractorUpdateReceiveGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func receive() async -> Data {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release(_ data: Data) { continuation?.resume(returning: data); continuation = nil }
}
