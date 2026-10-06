import Foundation
import XCTest
@testable import GanaBajana

enum LibrarySyncTestData {
    static let now = Date(timeIntervalSince1970: 1_789_776_000)
    static let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static func revision(_ counter: Int64, writer: UUID = a) -> LibrarySyncRevision {
        LibrarySyncRevision(milliseconds: Int64(now.timeIntervalSince1970 * 1000), counter: counter, writer: writer)
    }

    static func single<T: Encodable>(_ collection: LibrarySyncCollection, _ id: String, value: T,
                                     revision: LibrarySyncRevision) throws -> LibrarySyncState {
        var state = LibrarySyncState()
        state.clock = revision
        state.put(LibrarySyncKey(collection, id), value: try LibrarySyncCodec.encode(value), revision: revision)
        return state
    }

    static func rendered(_ state: LibrarySyncState, now: Date = LibrarySyncTestData.now) throws -> LibraryDocument {
        try LibrarySyncProjection.materialize(state, onto: LibraryDocument(), now: now)
    }

    /// Bytes as an older app wrote them: never `superLikedIDs` (v5), and below v4 no `lifetimeListening` or receipts.
    static func legacyDocumentBytes(_ document: LibraryDocument) throws -> Data {
        precondition((1..<LibraryPersistence.currentVersion).contains(document.version))
        var legacy = document
        if var state = legacy.syncState {
            state.version = min(state.version, document.version < 4 ? 2 : 3)
            if document.version < 4 { state.registers = state.registers.filter { $0.key.collection != .lifetimeSession } }
            legacy.syncState = state
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(legacy)) as? [String: Any])
        if document.version < 4 { object.removeValue(forKey: "lifetimeListening") }
        object.removeValue(forKey: "superLikedIDs")
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}

@MainActor
final class LibrarySyncTestConfiguration: LibrarySyncConfigurationPersisting {
    var value: LibrarySyncDeviceConfiguration
    var loadError: (any Error)?
    var saveError: (any Error)?
    private(set) var saveCount = 0

    init(replicaID: UUID) { value = LibrarySyncDeviceConfiguration(replicaID: replicaID) }
    func load() throws -> LibrarySyncDeviceConfiguration {
        if let loadError { throw loadError }
        return value
    }
    func save(_ configuration: LibrarySyncDeviceConfiguration) throws {
        if let saveError { throw saveError }
        saveCount += 1
        value = configuration
    }
}

@MainActor
final class LibrarySyncTestCloud {
    var accounts: [String: [UUID: Data]] = [:]
}

@MainActor
final class LibrarySyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class LibrarySyncTestTransport: LibrarySyncTransport {
    let cloud: LibrarySyncTestCloud
    var account: String? = "account-a"
    var accountAliases: [String: String] = [:]
    var additionalFiles: [LibrarySyncRemoteFile] = []
    var pendingDownloads = 0
    var readError: (any Error)?
    var publishError: (any Error)?
    var beforeReadReturns: (@MainActor () async -> Void)?
    var beforePublication: (@MainActor () async -> Void)?
    var beforeAccountReturns: (@MainActor (Int) async -> Void)?
    private(set) var accountChecks = 0
    private(set) var reads = 0
    private(set) var publicationAttempts = 0
    private(set) var writes: [(String, UUID, Data)] = []
    private(set) var observing = false
    private(set) var stopped = 0
    private(set) var lastScope: LibrarySyncScope?
    private var changed: (@MainActor @Sendable (LibrarySyncTransportEvent) -> Void)?

    init(cloud: LibrarySyncTestCloud) { self.cloud = cloud }
    func accountIdentifier() async throws -> String? {
        accountChecks += 1
        await beforeAccountReturns?(accountChecks)
        return account
    }
    func accountsMatch(_ lhs: String, _ rhs: String) throws -> Bool {
        (accountAliases[lhs] ?? lhs) == (accountAliases[rhs] ?? rhs)
    }
    func read(in scope: LibrarySyncScope) async throws -> LibrarySyncReadResult {
        reads += 1
        lastScope = scope
        if let readError { throw readError }
        let files = cloud.accounts[scope.accountIdentifier] ?? [:]
        let snapshot = LibrarySyncReadResult(
            files: files.map { LibrarySyncRemoteFile(replicaID: $0.key, data: $0.value) } + additionalFiles,
            pendingDownloads: pendingDownloads, publication: LibrarySyncPublicationExpectation(ownFile: files[scope.replicaID])
        )
        // Deliberately returns captured data after cancellation so the controller's stale-apply fence is exercised.
        await beforeReadReturns?()
        return snapshot
    }
    func publish(_ data: Data, in scope: LibrarySyncScope, replacing expectation: LibrarySyncPublicationExpectation) async throws {
        publicationAttempts += 1
        lastScope = scope
        await beforePublication?()
        try scope.lease.check()
        guard let account else { throw LibrarySyncError.unavailable }
        guard try accountsMatch(account, scope.accountIdentifier) else { throw LibrarySyncError.accountChanged }
        if let publishError { throw publishError }
        guard cloud.accounts[scope.accountIdentifier]?[scope.replicaID] == expectation.ownFile else { throw LibrarySyncError.changedDuringSync }
        if cloud.accounts[scope.accountIdentifier]?[scope.replicaID] != data {
            cloud.accounts[scope.accountIdentifier, default: [:]][scope.replicaID] = data
            writes.append((scope.accountIdentifier, scope.replicaID, data))
        }
    }
    func startObserving(_ changed: @escaping @MainActor @Sendable (LibrarySyncTransportEvent) -> Void) {
        observing = true
        self.changed = changed
    }
    func stopObserving() { observing = false; changed = nil; stopped += 1 }
    func emit(_ event: LibrarySyncTransportEvent) { changed?(event) }
}

@MainActor
final class LibrarySyncTestDevice {
    let id: UUID
    let directory: URL
    let library: LibraryStore
    let transport: LibrarySyncTestTransport
    let configuration: LibrarySyncTestConfiguration
    let sync: ICloudLibrarySync

    init(id: UUID, directory: URL, cloud: LibrarySyncTestCloud, clock: RecommendationTestClock,
         debounce: Duration = .milliseconds(10), timeout: Duration = .seconds(10),
         retryDelays: [Duration] = [.seconds(5), .seconds(30)]) {
        self.id = id
        self.directory = directory
        library = LibraryStore(directory: directory, now: { clock.now }, writerID: id)
        transport = LibrarySyncTestTransport(cloud: cloud)
        configuration = LibrarySyncTestConfiguration(replicaID: id)
        sync = ICloudLibrarySync(library: library, transport: transport, configuration: configuration,
                                now: { clock.now }, debounce: debounce, operationTimeout: timeout, retryDelays: retryDelays,
                                uptime: { clock.now.timeIntervalSince1970 })
    }

    var fileURL: URL { directory.appendingPathComponent(LibraryPersistence.fileName) }
    func state() throws -> LibrarySyncState { try library.cloudReplica(replicaID: id).state }
    func saved() throws -> LibraryDocument { try LibraryPersistence.decode(Data(contentsOf: fileURL), now: LibrarySyncTestData.now) }
}

@MainActor
final class LibrarySyncTestHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-LibrarySync-\(UUID())", isDirectory: true)
    let cloud = LibrarySyncTestCloud()
    let clock = RecommendationTestClock(LibrarySyncTestData.now)

    func device(_ id: UUID = LibrarySyncTestData.a, debounce: Duration = .milliseconds(10),
                timeout: Duration = .seconds(10), retryDelays: [Duration] = [.seconds(5), .seconds(30)]) -> LibrarySyncTestDevice {
        LibrarySyncTestDevice(id: id, directory: root.appendingPathComponent(id.uuidString, isDirectory: true),
                             cloud: cloud, clock: clock, debounce: debounce, timeout: timeout, retryDelays: retryDelays)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
