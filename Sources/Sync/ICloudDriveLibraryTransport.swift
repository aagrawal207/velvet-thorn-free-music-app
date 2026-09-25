import CryptoKit
import Foundation

@MainActor
final class ICloudDriveLibraryTransport: LibrarySyncTransport {
    nonisolated static let containerIdentifier = "iCloud.com.agraabhi.ganabajana"
    private let worker: ICloudDriveLibraryWorker
    private var observer: LibrarySyncUbiquityObserver?

    init(containerIdentifier: String = ICloudDriveLibraryTransport.containerIdentifier) {
        worker = ICloudDriveLibraryWorker(containerIdentifier: containerIdentifier)
    }

    func accountIdentifier() async throws -> String? {
        guard observer != nil else { throw LibrarySyncError.unavailable }
        return try await worker.accountIdentifier()
    }

    func accountsMatch(_ lhs: String, _ rhs: String) throws -> Bool {
        if lhs == rhs { return true }
        guard let current = FileManager.default.ubiquityIdentityToken as? NSObject else { throw LibrarySyncError.unavailable }
        return try LibrarySyncFileIO.decodeAccount(lhs, currentToken: current).isEqual(LibrarySyncFileIO.decodeAccount(rhs, currentToken: current))
    }

    func read(in scope: LibrarySyncScope) async throws -> LibrarySyncReadResult {
        let directory = try await worker.directory(in: scope)
        try scope.lease.check()
        observer?.watch(directory)
        var result = try await worker.read(directory: directory, in: scope)
        try scope.lease.check()
        if observer?.isGathering == true { result.pendingDownloads += 1 }
        if observer?.failedToStart == true { throw LibrarySyncError.unavailable }
        return result
    }

    func publish(_ data: Data, in scope: LibrarySyncScope, replacing expectation: LibrarySyncPublicationExpectation) async throws {
        let directory = try await worker.directory(in: scope)
        try scope.lease.check()
        try await worker.publish(data, directory: directory, in: scope, replacing: expectation)
        try scope.lease.check()
    }

    func startObserving(_ changed: @escaping @MainActor @Sendable (LibrarySyncTransportEvent) -> Void) {
        guard observer == nil else { return }
        observer = LibrarySyncUbiquityObserver(changed: changed)
    }

    func stopObserving() { observer?.stop(); observer = nil }
    isolated deinit { observer?.stop() }
}

private actor ICloudDriveLibraryWorker {
    let containerIdentifier: String

    init(containerIdentifier: String) { self.containerIdentifier = containerIdentifier }

    func accountIdentifier() throws -> String? { try LibrarySyncFileIO.accountIdentifier() }

    func directory(in scope: LibrarySyncScope) throws -> URL {
        try LibrarySyncFileIO.verify(scope)
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            throw LibrarySyncError.unavailable
        }
        try LibrarySyncFileIO.verify(scope)
        return container.appendingPathComponent("Documents/LibrarySync", isDirectory: true)
    }

    func read(directory: URL, in scope: LibrarySyncScope) throws -> LibrarySyncReadResult {
        try LibrarySyncFileIO.verify(scope)
        let urls: [URL]
        do {
            urls = try LibrarySyncFileIO.coordinatedContents(directory, scope: scope)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return LibrarySyncReadResult() }
        var result = LibrarySyncReadResult()
        var bytes = 0
        var seen = Set<UUID>()
        var placeholders = Set<UUID>()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try LibrarySyncFileIO.verify(scope)
            let name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                let logicalName = String(name.dropFirst().dropLast(".icloud".count))
                guard let id = UUID(uuidString: String(logicalName.dropLast(".json".count))) else {
                    throw LibrarySyncError.invalidData("download placeholder name")
                }
                placeholders.insert(id)
                guard seen.union(placeholders).count <= LibrarySyncCodec.maximumFiles else { throw LibrarySyncError.tooLarge }
                let logicalURL = directory.appendingPathComponent(logicalName)
                do {
                    let resources = try logicalURL.resourceValues(forKeys: [.fileSizeKey])
                    if let size = resources.fileSize, size > LibrarySyncCodec.maximumFileBytes { throw LibrarySyncError.tooLarge }
                } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { }
                try FileManager.default.startDownloadingUbiquitousItem(at: logicalURL)
                result.pendingDownloads += 1
                continue
            }
            if name.hasPrefix(".") || url.pathExtension != "json" { continue }
            guard let replicaID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  name == "\(replicaID.uuidString.lowercased()).json", seen.insert(replicaID).inserted else {
                throw LibrarySyncError.invalidData("replica file name")
            }
            guard seen.union(placeholders).count <= LibrarySyncCodec.maximumFiles else { throw LibrarySyncError.tooLarge }
            if try !LibrarySyncFileIO.isReady(url) {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                result.pendingDownloads += 1
                continue
            }
            let currentLimit = min(LibrarySyncCodec.maximumFileBytes, LibrarySyncCodec.maximumBatchBytes - bytes)
            let current = try LibrarySyncFileIO.coordinatedRead(url, scope: scope, maximumBytes: currentLimit)
            try append(current, replicaID: replicaID, into: &result, bytes: &bytes)
            if replicaID == scope.replicaID { result.publication.ownFile = current }
            let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            guard result.files.count + result.pendingDownloads + conflicts.count <= LibrarySyncCodec.maximumFiles else {
                throw LibrarySyncError.tooLarge
            }
            for version in conflicts {
                let limit = min(LibrarySyncCodec.maximumFileBytes, LibrarySyncCodec.maximumBatchBytes - bytes)
                let data = try LibrarySyncFileIO.coordinatedRead(version.url, scope: scope, isConflictVersion: true, maximumBytes: limit)
                try append(data, replicaID: replicaID, into: &result, bytes: &bytes)
                if replicaID == scope.replicaID { result.publication.conflictDigests.append(LibrarySyncFileIO.digest(data)) }
            }
        }
        result.publication.conflictDigests.sort()
        try LibrarySyncFileIO.verify(scope)
        return result
    }

    private func append(_ data: Data, replicaID: UUID, into result: inout LibrarySyncReadResult, bytes: inout Int) throws {
        guard result.files.count < LibrarySyncCodec.maximumFiles, data.count <= LibrarySyncCodec.maximumBatchBytes - bytes else {
            throw LibrarySyncError.tooLarge
        }
        bytes += data.count
        result.files.append(LibrarySyncRemoteFile(replicaID: replicaID, data: data))
    }

    func publish(_ data: Data, directory: URL, in scope: LibrarySyncScope,
                 replacing expectation: LibrarySyncPublicationExpectation) throws {
        guard data.count <= LibrarySyncCodec.maximumFileBytes else { throw LibrarySyncError.tooLarge }
        try LibrarySyncFileIO.verify(scope)
        _ = try LibrarySyncCodec.decodeReplica(data, expectedReplicaID: scope.replicaID, now: Date())
        try LibrarySyncFileIO.coordinatedWrite(directory, scope: scope, options: []) { coordinated in
            try scope.lease.whileValid {
                try LibrarySyncFileIO.verifyAccount(scope)
                do { try LibrarySyncFileIO.verifyDirectory(coordinated) }
                catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { }
                try FileManager.default.createDirectory(at: coordinated, withIntermediateDirectories: true)
            }
        }
        let url = directory.appendingPathComponent("\(scope.replicaID.uuidString.lowercased()).json")
        let checkedConflicts = try checkedConflictIdentities(at: url, scope: scope, expectation: expectation)
        try LibrarySyncFileIO.coordinatedWrite(url, scope: scope, options: .forReplacing) { coordinated in
            try LibrarySyncFileIO.verify(scope)
            let current: Data?
            do {
                guard try LibrarySyncFileIO.isReady(coordinated) else { throw LibrarySyncError.changedDuringSync }
                current = try LibrarySyncFileIO.readBounded(coordinated)
            } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { current = nil }
            guard current == expectation.ownFile else { throw LibrarySyncError.changedDuringSync }
            let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated) ?? []
            guard versions.count <= LibrarySyncCodec.maximumFiles else { throw LibrarySyncError.tooLarge }
            guard versions.count == checkedConflicts.count,
                  versions.allSatisfy({ version in checkedConflicts.contains { $0.matches(version.persistentIdentifier) } }) else {
                throw LibrarySyncError.changedDuringSync
            }
            if current == data { return }
            let stagingDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: coordinated.deletingLastPathComponent(), create: true
            )
            defer { try? FileManager.default.removeItem(at: stagingDirectory) }
            let stagingFile = stagingDirectory.appendingPathComponent("library-replica")
            #if os(iOS)
            try data.write(to: stagingFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: stagingFile, options: .atomic)
            #endif
            // Only the same-volume replacement holds the cancellation fence, not the potentially large staging write.
            try scope.lease.whileValid {
                try LibrarySyncFileIO.verifyAccount(scope)
                if current == nil {
                    try FileManager.default.moveItem(at: stagingFile, to: coordinated)
                } else {
                    _ = try FileManager.default.replaceItemAt(coordinated, withItemAt: stagingFile, backupItemName: nil, options: .usingNewMetadataOnly)
                }
            }
            // Conflict versions stay unresolved; OS upload completion is not a durable multi-device acknowledgement.
        }
        try LibrarySyncFileIO.verify(scope)
    }

    private func checkedConflictIdentities(at url: URL, scope: LibrarySyncScope,
                                           expectation: LibrarySyncPublicationExpectation) throws -> [LibrarySyncConflictIdentity] {
        let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard versions.count <= LibrarySyncCodec.maximumFiles else { throw LibrarySyncError.tooLarge }
        guard versions.count == expectation.conflictDigests.count else { throw LibrarySyncError.changedDuringSync }
        var bytes = 0
        var digests: [String] = []
        var identities: [LibrarySyncConflictIdentity] = []
        for version in versions {
            let limit = min(LibrarySyncCodec.maximumFileBytes, LibrarySyncCodec.maximumBatchBytes - bytes)
            let data = try LibrarySyncFileIO.coordinatedRead(version.url, scope: scope, isConflictVersion: true, maximumBytes: limit)
            bytes += data.count
            digests.append(LibrarySyncFileIO.digest(data))
            identities.append(try LibrarySyncConflictIdentity(version.persistentIdentifier))
        }
        guard digests.sorted() == expectation.conflictDigests else { throw LibrarySyncError.changedDuringSync }
        return identities
    }
}

// Version contents are immutable; the persistent ID lets the write accessor verify the coordinated reads' membership.
private final class LibrarySyncConflictIdentity: @unchecked Sendable {
    private let identifier: any NSObjectProtocol
    init(_ identifier: any NSCoding) throws {
        guard let object = identifier as? any NSObjectProtocol else { throw LibrarySyncError.invalidData("conflict version identity") }
        self.identifier = object
    }
    func matches(_ other: any NSCoding) -> Bool { identifier.isEqual(other) }
}

enum LibrarySyncFileIO {
    static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey
    ]

    static func accountIdentifier() throws -> String? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        guard token is any NSSecureCoding else { throw LibrarySyncError.invalidData("iCloud identity token") }
        let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        guard data.count <= 12 * 1024 else { throw LibrarySyncError.tooLarge }
        return data.base64EncodedString()
    }

    // Apple's token equality is semantic; keyed-archive byte ordering is not an account identifier.
    static func decodeAccount(_ identifier: String, currentToken: NSObject) throws -> NSObject {
        guard identifier.utf8.count <= 16 * 1024, let data = Data(base64Encoded: identifier) else {
            throw LibrarySyncError.invalidData("saved iCloud account binding")
        }
        let classes: [AnyClass] = [type(of: currentToken), NSString.self, NSData.self, NSNumber.self, NSUUID.self, NSArray.self, NSDictionary.self]
        guard let token = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? NSObject else {
            throw LibrarySyncError.invalidData("saved iCloud account binding")
        }
        return token
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func verifyAccount(_ scope: LibrarySyncScope) throws {
        guard let current = FileManager.default.ubiquityIdentityToken as? NSObject else { throw LibrarySyncError.unavailable }
        guard try current.isEqual(decodeAccount(scope.accountIdentifier, currentToken: current)) else { throw LibrarySyncError.accountChanged }
    }

    static func verify(_ scope: LibrarySyncScope) throws { try scope.lease.check(); try verifyAccount(scope) }

    static func isReady(_ url: URL) throws -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard values.isSymbolicLink != true else { throw LibrarySyncError.invalidData("symbolic-link replica") }
        if let error = values.ubiquitousItemDownloadingError { throw error }
        if let error = values.ubiquitousItemUploadingError { throw error }
        if let size = values.fileSize, size > LibrarySyncCodec.maximumFileBytes { throw LibrarySyncError.tooLarge }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current { return false }
        guard values.isRegularFile == true else { throw LibrarySyncError.invalidData("non-file replica") }
        return true
    }

    static func readBounded(_ url: URL, maximumBytes: Int = LibrarySyncCodec.maximumFileBytes) throws -> Data {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibrarySyncError.invalidData("non-file sync data") }
        if let size = values.fileSize, size > maximumBytes { throw LibrarySyncError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(1024 * 1024, maximumBytes - result.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - result.count else { throw LibrarySyncError.tooLarge }
            result.append(chunk)
        }
        return result
    }

    static func verifyDirectory(_ url: URL) throws {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibrarySyncError.invalidData("sync directory") }
    }

    static func coordinatedContents(_ url: URL, scope: LibrarySyncScope) throws -> [URL] {
        let box = LibrarySyncIOResult<[URL]>()
        let coordinator = LibrarySyncCoordinator()
        let cancellation = scope.lease.onInvalidation { coordinator.value.cancel() }
        defer { scope.lease.removeCancellation(cancellation) }
        var error: NSError?
        coordinator.value.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            box.set(Result {
                try verify(scope)
                try verifyDirectory(coordinated)
                let enumerationError = LibrarySyncIOResult<Bool>()
                guard let enumerator = FileManager.default.enumerator(at: coordinated, includingPropertiesForKeys: Array(resourceKeys),
                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants], errorHandler: { _, error in
                        enumerationError.set(.failure(error))
                        return false
                    }) else { throw LibrarySyncError.unavailable }
                var result: [URL] = []
                while let entry = enumerator.nextObject() as? URL {
                    try scope.lease.check()
                    guard result.count < LibrarySyncCodec.maximumFiles * 2 else { throw LibrarySyncError.tooLarge }
                    result.append(entry)
                }
                try enumerationError.rethrowIfFailed()
                return result
            })
        }
        if let error { throw error }
        return try box.get()
    }

    static func coordinatedRead(_ url: URL, scope: LibrarySyncScope, isConflictVersion: Bool = false,
                                maximumBytes: Int = LibrarySyncCodec.maximumFileBytes) throws -> Data {
        let box = LibrarySyncIOResult<Data>()
        let coordinator = LibrarySyncCoordinator()
        let cancellation = scope.lease.onInvalidation { coordinator.value.cancel() }
        defer { scope.lease.removeCancellation(cancellation) }
        var error: NSError?
        coordinator.value.coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            box.set(Result {
                try verify(scope)
                if !isConflictVersion {
                    guard try isReady(coordinated) else { throw LibrarySyncError.changedDuringSync }
                }
                return try readBounded(coordinated, maximumBytes: maximumBytes)
            })
        }
        if let error { throw error }
        return try box.get()
    }

    static func coordinatedWrite(_ url: URL, scope: LibrarySyncScope, options: NSFileCoordinator.WritingOptions,
                                  _ body: @escaping @Sendable (URL) throws -> Void) throws {
        let box = LibrarySyncIOResult<Bool>()
        let coordinator = LibrarySyncCoordinator()
        let cancellation = scope.lease.onInvalidation { coordinator.value.cancel() }
        defer { scope.lease.removeCancellation(cancellation) }
        var error: NSError?
        coordinator.value.coordinate(writingItemAt: url, options: options, error: &error) { coordinated in
            box.set(Result { try body(coordinated); return true })
        }
        if let error { throw error }
        _ = try box.get()
    }
}

private final class LibrarySyncIOResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    func set(_ result: Result<Value, any Error>) { lock.withLock { self.result = result } }
    func get() throws -> Value {
        try lock.withLock {
            guard let result else { throw LibrarySyncError.changedDuringSync }
            return try result.get()
        }
    }
    func rethrowIfFailed() throws { try lock.withLock { if case .some(.failure(let error)) = result { throw error } } }
}

private final class LibrarySyncCoordinator: @unchecked Sendable {
    let value = NSFileCoordinator(filePresenter: nil)
}

@MainActor
private final class LibrarySyncUbiquityObserver {
    private let changed: @MainActor @Sendable (LibrarySyncTransportEvent) -> Void
    private var identityObserver: (any NSObjectProtocol)?
    private var queryObservers: [any NSObjectProtocol] = []
    private var query: NSMetadataQuery?
    private var directory: URL?
    private var queryGeneration = UUID()
    private(set) var isGathering = false
    private(set) var failedToStart = false

    init(changed: @escaping @MainActor @Sendable (LibrarySyncTransportEvent) -> Void) {
        self.changed = changed
        identityObserver = NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopQuery()
                self?.changed(.identityChanged)
            }
        }
    }

    func watch(_ directory: URL) {
        guard self.directory != directory || failedToStart else { return }
        stopQuery()
        self.directory = directory
        isGathering = true
        failedToStart = false
        let generation = queryGeneration
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, ".json")
        query.notificationBatchingInterval = 1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            queryObservers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard self?.queryGeneration == generation else { return }
                    if name == .NSMetadataQueryDidFinishGathering { self?.isGathering = false }
                    self?.changed(.filesChanged)
                }
            })
        }
        self.query = query
        failedToStart = !query.start()
    }

    private func stopQuery() {
        queryGeneration = UUID()
        query?.stop()
        query = nil
        directory = nil
        isGathering = false
        queryObservers.forEach(NotificationCenter.default.removeObserver)
        queryObservers = []
    }

    func stop() {
        stopQuery()
        if let identityObserver { NotificationCenter.default.removeObserver(identityObserver) }
        identityObserver = nil
    }

    isolated deinit { stop() }
}
