import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MomentMixPersistenceTests: XCTestCase {
    private typealias F = MomentMixFixtures

    func testAtomicFileRoundTripAndExternalConflictPreserveBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("moments.json")
        let store = MomentMixStore(persistence: MomentMixFilePersistence(url: url), now: F.start)
        XCTAssertTrue(store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.start))
        XCTAssertTrue(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        let bytes = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(MomentMixSnapshot.self, from: bytes)
        XCTAssertEqual(decoded.evidence.count, 3)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let reopened = MomentMixStore(persistence: MomentMixFilePersistence(url: url), now: F.now)
        XCTAssertEqual(reopened.snapshot, store.snapshot)
        let external = Data("external repair in progress".utf8)
        try external.write(to: url, options: .atomic)
        XCTAssertFalse(store.setLearningEnabled(false, now: F.now))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testOversizedFileIsPreservedAndCollectionBlocked() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("moments.json")
        let bytes = Data(repeating: 0x20, count: MomentMixFilePersistence.maximumBytes + 1)
        try bytes.write(to: url)
        let store = MomentMixStore(persistence: MomentMixFilePersistence(url: url), now: F.start)
        XCTAssertFalse(store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.now))
        XCTAssertFalse(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotNil(store.errorMessage)
    }

    func testMissingParentIsAnEmptyReadAndFirstWriteCreatesDedicatedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("GanaBajana/Moments", isDirectory: true)
        let url = directory.appendingPathComponent("moments.json")
        let disk = MomentMixFilePersistence(url: url)
        XCTAssertNil(try disk.read(), "Native missing-path errors are empty state, not corruption")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Reading does not create the store")
        let store = MomentMixStore(persistence: disk, now: F.start)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.start))
        XCTAssertTrue(store.observe(events: F.recurring, now: F.now, calendar: F.calendar))
        let bytes = try XCTUnwrap(disk.read())
        XCTAssertEqual(try JSONDecoder().decode(MomentMixSnapshot.self, from: bytes).evidence.count, 3)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testNonDirectoryParentIsNotMistakenForMissingStore() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = Data("valuable existing file".utf8)
        try original.write(to: parent)
        let disk = MomentMixFilePersistence(url: parent.appendingPathComponent("moments.json"))
        XCTAssertThrowsError(try disk.read())
        let store = MomentMixStore(persistence: disk, now: F.start)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.synchronizePrivacy(historyEnabled: true, historyEpoch: nil, now: F.start))
        XCTAssertEqual(try Data(contentsOf: parent), original)
    }

    func testMissingPathClassificationDoesNotSwallowOtherNativeFailures() {
        let missing = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOENT.rawValue))
        XCTAssertTrue(MomentMixFilePersistence.isMissingFile(missing))
        for code in [CocoaError.Code.fileNoSuchFile, .fileReadNoSuchFile] {
            XCTAssertTrue(MomentMixFilePersistence.isMissingFile(NSError(domain: NSCocoaErrorDomain, code: code.rawValue)))
            XCTAssertTrue(MomentMixFilePersistence.isMissingFile(NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                userInfo: [NSUnderlyingErrorKey: missing])))
            for errno in [POSIXErrorCode.EACCES, .ENOTDIR, .EIO] {
                let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(errno.rawValue))
                XCTAssertFalse(MomentMixFilePersistence.isMissingFile(underlying))
                XCTAssertFalse(MomentMixFilePersistence.isMissingFile(NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                    userInfo: [NSUnderlyingErrorKey: underlying])))
            }
        }
    }
}
