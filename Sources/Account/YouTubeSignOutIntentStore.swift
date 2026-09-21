import Foundation
import Synchronization

protocol YouTubeSignOutIntentStoring: Sendable {
    func isPending() throws -> Bool
    func setPending(_ pending: Bool) throws
}

final class MemorySignOutIntentStore: YouTubeSignOutIntentStoring {
    private let pending = Mutex(false)

    func isPending() throws -> Bool { pending.withLock { $0 } }
    func setPending(_ value: Bool) throws { pending.withLock { $0 = value } }
}

/// A credential-free marker prevents a failed Keychain deletion from restoring the account after relaunch.
struct FileSignOutIntentStore: YouTubeSignOutIntentStoring {
    private let fileURL: URL
    private static let marker = Data([1])

    init(fileURL: URL = URL.applicationSupportDirectory
        .appendingPathComponent("GanaBajana/Account/pending-sign-out")) {
        self.fileURL = fileURL
    }

    func isPending() throws -> Bool {
        do {
            guard try Data(contentsOf: fileURL) == Self.marker else { throw IntentError.invalidMarker }
            return true
        } catch CocoaError.fileReadNoSuchFile {
            return false
        }
    }

    func setPending(_ pending: Bool) throws {
        if pending {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.marker.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            do { try FileManager.default.removeItem(at: fileURL) }
            catch CocoaError.fileNoSuchFile { }
        }
    }

    private enum IntentError: Error { case invalidMarker }
}
