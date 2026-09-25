import Foundation

struct LibrarySyncRemoteFile: Sendable {
    var replicaID: UUID
    var data: Data
}

struct LibrarySyncPublicationExpectation: Sendable {
    var ownFile: Data?
    var conflictDigests: [String] = []
}

struct LibrarySyncReadResult: Sendable {
    var files: [LibrarySyncRemoteFile] = []
    var pendingDownloads = 0
    var publication = LibrarySyncPublicationExpectation()
}

struct LibrarySyncScope: Sendable {
    var accountIdentifier: String
    var replicaID: UUID
    var lease: LibrarySyncLease
}

enum LibrarySyncTransportEvent: Sendable { case filesChanged, identityChanged }

@MainActor
protocol LibrarySyncTransport: AnyObject {
    func accountIdentifier() async throws -> String?
    func accountsMatch(_ lhs: String, _ rhs: String) throws -> Bool
    func read(in scope: LibrarySyncScope) async throws -> LibrarySyncReadResult
    func publish(_ data: Data, in scope: LibrarySyncScope, replacing: LibrarySyncPublicationExpectation) async throws
    func startObserving(_ changed: @escaping @MainActor @Sendable (LibrarySyncTransportEvent) -> Void)
    func stopObserving()
}

extension LibrarySyncTransport {
    func accountsMatch(_ lhs: String, _ rhs: String) throws -> Bool { lhs == rhs }
}

// Cancellation must reach coordinated I/O even while its worker is blocked outside the actor executor.
final class LibrarySyncLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    var isValid: Bool { lock.withLock { valid } }
    func invalidate() {
        let callbacks = lock.withLock {
            valid = false
            let callbacks = Array(cancellations.values)
            cancellations.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    func onInvalidation(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyInvalid = lock.withLock {
            if !valid { return true }
            cancellations[id] = callback
            return false
        }
        if alreadyInvalid { callback() }
        return id
    }

    func removeCancellation(_ id: UUID) { _ = lock.withLock { cancellations.removeValue(forKey: id) } }

    func check() throws {
        guard isValid, !Task.isCancelled else { throw LibrarySyncError.cancelled }
    }

    func whileValid<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard valid, !Task.isCancelled else { throw LibrarySyncError.cancelled }
            return try body()
        }
    }
}
