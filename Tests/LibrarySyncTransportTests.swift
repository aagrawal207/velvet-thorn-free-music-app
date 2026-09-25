import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncTransportTests: XCTestCase {
    func testDeviceIdentityBindingAndEnabledDefaultPersistInABackupExcludedDirectory() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let device = harness.device()
        device.library.toggleFavorite(libraryTestTrack("saved"))
        let url = try XCTUnwrap(device.library.syncDeviceConfigurationURL)
        let storage = LibrarySyncDeviceConfigurationStore(fileURL: url)
        var configuration = try storage.load()
        XCTAssertTrue(configuration.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        configuration.boundAccount = "account-a"
        configuration.lastSyncDate = LibrarySyncTestData.now
        try storage.save(configuration)
        let restored = try LibrarySyncDeviceConfigurationStore(fileURL: url).load()
        XCTAssertEqual(restored, configuration)
        let resources = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resources.isExcludedFromBackup, true)

        let restoredDirectory = harness.root.appendingPathComponent("restored-device")
        try LibraryPersistence.write(Data(contentsOf: device.fileURL),
                                     to: restoredDirectory.appendingPathComponent(LibraryPersistence.fileName), replacing: nil)
        let restoredLibrary = LibraryStore(directory: restoredDirectory, now: { LibrarySyncTestData.now }, writerID: LibrarySyncTestData.c)
        let newConfiguration = try LibrarySyncDeviceConfigurationStore(fileURL: restoredLibrary.syncDeviceConfigurationURL).load()
        XCTAssertTrue(newConfiguration.enabled)
        XCTAssertNil(newConfiguration.boundAccount)
        XCTAssertNil(newConfiguration.lastSyncDate)
        XCTAssertNotEqual(newConfiguration.replicaID, configuration.replicaID)
        XCTAssertEqual(restoredLibrary.favorites.map(\.id), ["saved"])
    }

    func testPreviouslySavedExplicitOffLoadsUnchangedAcrossRestarts() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let url = harness.root.appendingPathComponent("config/device.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Data(#"{"version":1,"replicaID":"00000000-0000-0000-0000-000000000001","enabled":false,"boundAccount":"account-a"}"#.utf8)
        try saved.write(to: url, options: .atomic)

        for _ in 0..<2 {
            let configuration = try LibrarySyncDeviceConfigurationStore(fileURL: url).load()
            XCTAssertFalse(configuration.enabled)
            XCTAssertEqual(configuration.replicaID, LibrarySyncTestData.a)
            XCTAssertEqual(configuration.boundAccount, "account-a")
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
    }

    func testCorruptNewerAndExternallyChangedDeviceConfigurationCannotBeReplaced() throws {
        let missingEnabled = Data(#"{"version":1,"replicaID":"00000000-0000-0000-0000-000000000001"}"#.utf8)
        let invalidEnabled = Data(#"{"version":1,"replicaID":"00000000-0000-0000-0000-000000000001","enabled":"false"}"#.utf8)
        for bytes in [Data("corrupt".utf8), Data("{\"version\":999,\"unknown\":true}".utf8), missingEnabled, invalidEnabled] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let url = harness.root.appendingPathComponent("config/device.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
            let store = LibrarySyncDeviceConfigurationStore(fileURL: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(LibrarySyncDeviceConfiguration()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let url = harness.root.appendingPathComponent("config/device.json")
        let first = LibrarySyncDeviceConfigurationStore(fileURL: url)
        let stale = try first.load()
        let external = LibrarySyncDeviceConfigurationStore(fileURL: url)
        var current = try external.load()
        current.enabled = false
        current.boundAccount = "account-b"
        try external.save(current)
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try first.save(stale))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFileReadsRejectOversizedSparseFilesAndSymbolicLinksBeforeLoadingTheirContents() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        try FileManager.default.createDirectory(at: harness.root, withIntermediateDirectories: true)
        let file = harness.root.appendingPathComponent("large.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(LibrarySyncCodec.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try LibrarySyncFileIO.readBounded(file)) {
            XCTAssertEqual($0 as? LibrarySyncError, .tooLarge)
        }
        let target = harness.root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = harness.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LibrarySyncFileIO.readBounded(link))
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
    }

    func testExcessiveReplicaCountFailsWithoutPartialApplyOrPublication() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("local"))
        let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: LibrarySyncState())
        let file = LibrarySyncRemoteFile(replicaID: replica.replicaID, data: try LibrarySyncCodec.encodeReplica(replica))
        a.transport.additionalFiles = Array(repeating: file, count: LibrarySyncCodec.maximumFiles + 1)
        let bytes = try Data(contentsOf: a.fileURL)
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
        XCTAssertNil(a.sync.lastSyncDate)
    }

    func testLeaseInvalidationCancelsRegisteredIOAndRejectsFuturePublication() throws {
        let lease = LibrarySyncLease()
        let calls = LibrarySyncTestCancellationCounter()
        lease.onInvalidation { calls.increment() }
        XCTAssertNoThrow(try lease.check())
        lease.invalidate()
        lease.invalidate()
        XCTAssertEqual(calls.value, 1)
        lease.onInvalidation { calls.increment() }
        XCTAssertEqual(calls.value, 2)
        XCTAssertThrowsError(try lease.whileValid { XCTFail("A cancelled lease must not enter the publication body") })
    }

    func testAccountTokenEqualityDoesNotDependOnArchiveByteFormatting() throws {
        let token: NSString = "account-a"
        let binary = NSKeyedArchiver(requiringSecureCoding: true)
        binary.outputFormat = .binary
        binary.encode(token, forKey: NSKeyedArchiveRootObjectKey)
        binary.finishEncoding()
        let xml = NSKeyedArchiver(requiringSecureCoding: true)
        xml.outputFormat = .xml
        xml.encode(token, forKey: NSKeyedArchiveRootObjectKey)
        xml.finishEncoding()
        XCTAssertNotEqual(binary.encodedData, xml.encodedData)
        let first = try LibrarySyncFileIO.decodeAccount(binary.encodedData.base64EncodedString(), currentToken: token)
        let second = try LibrarySyncFileIO.decodeAccount(xml.encodedData.base64EncodedString(), currentToken: token)
        XCTAssertTrue(first.isEqual(second))
    }
}

private final class LibrarySyncTestCancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
