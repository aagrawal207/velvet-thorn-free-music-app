import Foundation
import OSLog

/// What an import copies from the signed-in YouTube Music account. Raw values are the bounded `kind=` metric field.
enum YouTubeLibraryKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case likes, playlists, subscriptions, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .likes: "Liked songs"
        case .playlists: "Playlists"
        case .subscriptions: "Followed artists"
        case .history: "Recent history"
        }
    }

    var detail: String {
        switch self {
        case .likes: "Likes songs here that you liked there. Nothing is unliked."
        case .playlists: "Copies playlists you made or saved. Pick which ones below."
        case .subscriptions: "Follows the artists you subscribe to."
        case .history: "Keeps your most recent 200 plays in one playlist. No listening time is recorded."
        }
    }

    /// History is off by default: it creates a playlist the listener may not expect.
    var isOnByDefault: Bool { self != .history }
}

/// Device-local record of what earlier imports created, so a re-import updates instead of duplicating.
/// Not synced and not tied to the sign-in: signing out keeps imported content and this map.
struct YouTubeImportLedger: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let historyPlaylistName = "YouTube Music history"

    var version = Self.currentVersion
    var lastImportedAt: Date?
    /// Remote playlist browse id (`VLPL...`) to the local playlist it was copied into.
    var playlists: [String: UUID] = [:]
    /// The one local playlist that mirrors recent history.
    var historyPlaylistID: UUID?
    /// Applied counts from the last run, keyed by `YouTubeLibraryKind.rawValue` so the JSON stays readable.
    var lastCounts: [String: Int] = [:]

    func count(for kind: YouTubeLibraryKind) -> Int { lastCounts[kind.rawValue] ?? 0 }

    mutating func setCount(_ count: Int, for kind: YouTubeLibraryKind) { lastCounts[kind.rawValue] = count }
}

enum YouTubeImportLedgerError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "The import record on this device was written by a newer version of Velvet Thorn."
        case .tooLarge: "The import record on this device is too large to read."
        }
    }
}

/// Reads and writes the ledger as a small JSON file next to the library. A missing file is an empty ledger.
struct YouTubeImportLedgerStore: Sendable {
    static let fileName = "youtube-import.json"
    static let maximumBytes = 4 * 1_024 * 1_024
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Account")

    let url: URL

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("GanaBajana/\(fileName)")
    }

    init(url: URL = YouTubeImportLedgerStore.defaultURL) {
        self.url = url
    }

    func load() throws -> YouTubeImportLedger {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return YouTubeImportLedger() }
        guard data.count <= Self.maximumBytes else { throw YouTubeImportLedgerError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(YouTubeImportLedger.self, from: data)
        guard ledger.version <= YouTubeImportLedger.currentVersion else {
            throw YouTubeImportLedgerError.unsupportedVersion(ledger.version)
        }
        return ledger
    }

    func save(_ ledger: YouTubeImportLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
