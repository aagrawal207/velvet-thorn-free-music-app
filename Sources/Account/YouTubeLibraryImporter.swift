import Foundation
import Observation
import OSLog

/// Per-kind caps on what one import reads; tests shrink them to exercise the limits with small fixtures.
struct YouTubeImportBounds: Sendable {
    var likes = 2_000
    var playlistTracks = 1_000
    var playlists = 200
    var subscriptions = 500
    var historyRows = 500
    var historyPlaylistSize = 200
    /// Safety net against a provider that keeps handing out fresh tokens.
    var pagesPerListing = 60
}

enum YouTubeImportKindStatus: Equatable, Sendable {
    case pending, running, done, failed(String), unauthorized, rateLimited, cancelled
}

struct YouTubeImportKindProgress: Equatable, Sendable {
    /// Remote rows read so far.
    var fetched = 0
    /// Local additions: new likes, created playlists, new follows or songs added to the history playlist.
    var applied = 0
    /// Existing imported playlists that received new songs (playlists only).
    var updated = 0
    var status: YouTubeImportKindStatus = .pending
}

enum YouTubeImportRunStatus: Equatable, Sendable { case idle, running, finished, cancelled }

struct YouTubeImportSelection: Equatable, Sendable {
    var kinds: Set<YouTubeLibraryKind>
    /// Remote playlist ids to copy; nil copies every listed playlist.
    var playlistIDs: Set<String>?

    init(kinds: Set<YouTubeLibraryKind>, playlistIDs: Set<String>? = nil) {
        self.kinds = kinds
        self.playlistIDs = playlistIDs
    }
}

/// Copies the signed-in account's library into the local `LibraryStore`, additively and idempotently. Runs one kind
/// after another on the main actor; page fetches await the client actor. Nothing is written to the account.
@MainActor @Observable
final class YouTubeLibraryImporter {
    private(set) var runStatus: YouTubeImportRunStatus = .idle
    private(set) var progress: [YouTubeLibraryKind: YouTubeImportKindProgress] = [:]
    private(set) var summary: String?
    /// YouTube refused the saved cookies; Settings offers Sign in again.
    private(set) var needsSignIn = false
    private(set) var errorMessage: String?
    private(set) var remotePlaylists: [MusicCollection] = []
    private(set) var hasLoadedPlaylists = false
    private(set) var isLoadingPlaylists = false
    private(set) var playlistsError: String?
    private(set) var ledger: YouTubeImportLedger

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let account: YouTubeAccountStore
    @ObservationIgnored private let client: any YouTubeAccountLibraryProviding
    @ObservationIgnored private let ledgerStore: YouTubeImportLedgerStore
    @ObservationIgnored private let bounds: YouTubeImportBounds
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var playlistsTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Account")

    init(library: LibraryStore, account: YouTubeAccountStore, client: any YouTubeAccountLibraryProviding,
         ledgerStore: YouTubeImportLedgerStore, bounds: YouTubeImportBounds = YouTubeImportBounds(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.account = account
        self.client = client
        self.ledgerStore = ledgerStore
        self.bounds = bounds
        self.now = now
        do {
            ledger = try ledgerStore.load()
        } catch {
            ledger = YouTubeImportLedger()
            errorMessage = "Earlier import records couldn't be read. A new import may create duplicate playlists."
            log.error("event=import_ledger_read_failed")
        }
    }

    var isRunning: Bool { runStatus == .running }
    var lastImportedAt: Date? { ledger.lastImportedAt }
    var hasSession: Bool { account.session != nil && !account.isSignOutPending }

    // MARK: Playlist picker

    func loadPlaylists() {
        guard playlistsTask == nil, hasSession else { return }
        isLoadingPlaylists = true
        playlistsError = nil
        playlistsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                playlistsTask = nil
                isLoadingPlaylists = false
            }
            do {
                remotePlaylists = try await fetchPlaylistList()
                hasLoadedPlaylists = true
            } catch is CancellationError {
            } catch YouTubeAccountLibraryError.unauthorized {
                needsSignIn = true
                playlistsError = YouTubeAccountLibraryError.unauthorized.localizedDescription
            } catch {
                playlistsError = error.localizedDescription
            }
        }
    }

    // MARK: Import runs

    func start(_ selection: YouTubeImportSelection) {
        guard !isRunning, hasSession else { return }
        task = Task { [weak self] in
            await self?.run(selection)
        }
    }

    func cancel() {
        task?.cancel()
        playlistsTask?.cancel()
    }

    /// Runs a whole import and returns when it has finished; `start` wraps this for the UI.
    func run(_ selection: YouTubeImportSelection) async {
        guard !isRunning else { return }
        let kinds = YouTubeLibraryKind.allCases.filter(selection.kinds.contains)
        progress = Dictionary(uniqueKeysWithValues: kinds.map { ($0, YouTubeImportKindProgress()) })
        summary = nil
        needsSignIn = false
        runStatus = .running
        log.info("event=import_started kinds=\(kinds.count)")
        var stop: YouTubeImportKindStatus?
        var anyFailed = false
        for kind in kinds {
            if let stop {
                progress[kind]?.status = stop
                continue
            }
            progress[kind]?.status = .running
            do {
                try await importKind(kind, selection: selection)
                progress[kind]?.status = .done
                ledger.setCount(progress[kind]?.applied ?? 0, for: kind)
                logKind(kind, status: "ok")
            } catch is CancellationError {
                progress[kind]?.status = .cancelled
                stop = .cancelled
                logKind(kind, status: "cancelled")
            } catch YouTubeAccountLibraryError.unauthorized {
                progress[kind]?.status = .unauthorized
                needsSignIn = true
                stop = .unauthorized
                anyFailed = true
                logKind(kind, status: "unauthorized")
            } catch MusicServiceError.rateLimited {
                progress[kind]?.status = .rateLimited
                anyFailed = true
                logKind(kind, status: "rateLimited")
            } catch {
                progress[kind]?.status = .failed(error.localizedDescription)
                anyFailed = true
                logKind(kind, status: "failed")
            }
            saveLedger()
        }
        if kinds.contains(where: { progress[$0]?.status == .done }) {
            ledger.lastImportedAt = now()
            saveLedger()
        }
        summary = Self.summary(progress)
        runStatus = stop == .cancelled ? .cancelled : .finished
        let outcome = stop == .cancelled ? "cancelled" : (stop == .unauthorized ? "unauthorized" : (anyFailed ? "failed" : "ok"))
        log.info("event=import_finished status=\(outcome, privacy: .public)")
    }

    private func logKind(_ kind: YouTubeLibraryKind, status: String) {
        let progress = progress[kind] ?? YouTubeImportKindProgress()
        log.info("event=import_kind kind=\(kind.rawValue, privacy: .public) status=\(status, privacy: .public) fetched=\(progress.fetched) count=\(progress.applied)")
    }

    private func importKind(_ kind: YouTubeLibraryKind, selection: YouTubeImportSelection) async throws {
        try Task.checkCancellation()
        switch kind {
        case .likes:
            try await pages(limit: bounds.likes, fetch: { try await client.likedSongs(continuation: $0) }) { tracks in
                progress[.likes]?.fetched += tracks.count
                progress[.likes]?.applied += library.addFavorites(tracks)
            }
        case .playlists:
            try await importPlaylists(selection.playlistIDs)
        case .subscriptions:
            try await pages(limit: bounds.subscriptions, fetch: { try await client.subscribedArtists(continuation: $0) }) { artists in
                progress[.subscriptions]?.fetched += artists.count
                for artist in artists where !library.isFollowing(artistID: artist.id) {
                    // No release baseline yet: the watcher records today's releases silently on its next check.
                    library.follow(FollowedArtist(id: artist.id, name: artist.title, artworkURL: artist.artworkURL, followedAt: now()))
                    if library.isFollowing(artistID: artist.id) { progress[.subscriptions]?.applied += 1 }
                }
            }
        case .history:
            try await importHistory()
        }
    }

    private func importPlaylists(_ selected: Set<String>?) async throws {
        let listed: [MusicCollection]
        if hasLoadedPlaylists {
            listed = remotePlaylists
        } else {
            listed = try await fetchPlaylistList()
            remotePlaylists = listed
            hasLoadedPlaylists = true
        }
        let wanted = listed.filter { selected?.contains($0.id) ?? true }
        progress[.playlists]?.fetched = wanted.count
        var unreadable = 0
        for remote in wanted {
            try Task.checkCancellation()
            var tracks: [Track] = []
            do {
                try await pages(limit: bounds.playlistTracks, fetch: { try await client.playlistTracks(id: remote.id, continuation: $0) }) {
                    tracks += $0
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch YouTubeAccountLibraryError.unauthorized {
                throw YouTubeAccountLibraryError.unauthorized
            } catch MusicServiceError.rateLimited {
                throw MusicServiceError.rateLimited
            } catch {
                // One unreadable playlist must not stop the others; the count surfaces in the kind's status.
                unreadable += 1
                continue
            }
            apply(remote, tracks: tracks)
            await Task.yield()
        }
        if unreadable > 0 {
            throw MusicServiceError.unavailable(unreadable == 1 ? "1 playlist couldn't be read." : "\(unreadable) playlists couldn't be read.")
        }
    }

    private func apply(_ remote: MusicCollection, tracks: [Track]) {
        if let localID = ledger.playlists[remote.id], library.playlists.contains(where: { $0.id == localID }) {
            if library.merge(tracks, into: localID) > 0 { progress[.playlists]?.updated += 1 }
            return
        }
        let name = Self.uniqueName(remote.title, among: library.playlists.map(\.name))
        let id = library.createPlaylist(name: name, tracks: tracks)
        guard library.playlists.contains(where: { $0.id == id }) else { return }
        ledger.playlists[remote.id] = id
        progress[.playlists]?.applied += 1
    }

    private func importHistory() async throws {
        var rows: [Track] = []
        try await pages(limit: bounds.historyRows, fetch: { try await client.history(continuation: $0) }) { rows += $0 }
        progress[.history]?.fetched = rows.count
        var seen = Set<String>()
        let recent = Array(rows.filter { seen.insert($0.id).inserted }.prefix(bounds.historyPlaylistSize))
        guard !recent.isEmpty else { return }
        if let id = ledger.historyPlaylistID, library.playlists.contains(where: { $0.id == id }) {
            progress[.history]?.applied += library.merge(recent, into: id, leading: true)
            return
        }
        let name = Self.uniqueName(YouTubeImportLedger.historyPlaylistName, among: library.playlists.map(\.name))
        let id = library.createPlaylist(name: name, tracks: recent)
        guard library.playlists.contains(where: { $0.id == id }) else { return }
        ledger.historyPlaylistID = id
        progress[.history]?.applied += recent.count
    }

    private func fetchPlaylistList() async throws -> [MusicCollection] {
        var listed: [MusicCollection] = []
        try await pages(limit: bounds.playlists, fetch: { try await client.playlists(continuation: $0) }) { listed += $0 }
        var seen = Set<String>()
        return listed.filter { seen.insert($0.id).inserted }
    }

    /// Walks a listing page by page up to `limit` items, checking for cancellation between pages.
    private func pages<Item: Sendable>(limit: Int, fetch: (String?) async throws -> YouTubeLibraryPage<Item>,
                                       apply: ([Item]) -> Void) async throws {
        var continuation: String?
        var visited = Set<String>()
        var count = 0
        for _ in 0..<bounds.pagesPerListing {
            try Task.checkCancellation()
            let page = try await fetch(continuation)
            try Task.checkCancellation()
            let items = Array(page.items.prefix(max(0, limit - count)))
            count += items.count
            apply(items)
            guard count < limit, let next = page.continuation, visited.insert(next).inserted else { return }
            continuation = next
            await Task.yield()
        }
    }

    private func saveLedger() {
        do {
            try ledgerStore.save(ledger)
        } catch {
            errorMessage = "The import finished, but its record couldn't be saved on this device. A later import may create duplicate playlists."
            log.error("event=import_ledger_write_failed")
        }
    }

    /// The remote name unless a local playlist already uses it; " (YouTube)" then tells the two apart.
    static func uniqueName(_ name: String, among existing: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "YouTube playlist" : trimmed
        let taken = existing.contains { $0.caseInsensitiveCompare(base) == .orderedSame }
        return taken ? base + " (YouTube)" : base
    }

    static func summary(_ progress: [YouTubeLibraryKind: YouTubeImportKindProgress]) -> String {
        var parts: [String] = []
        if let likes = progress[.likes], likes.applied > 0 { parts.append("liked \(count(likes.applied, "song"))") }
        if let playlists = progress[.playlists] {
            if playlists.applied > 0 { parts.append("added \(count(playlists.applied, "playlist"))") }
            if playlists.updated > 0 { parts.append("updated \(count(playlists.updated, "playlist"))") }
        }
        if let artists = progress[.subscriptions], artists.applied > 0 { parts.append("followed \(count(artists.applied, "artist"))") }
        if let history = progress[.history], history.applied > 0 {
            parts.append("added \(count(history.applied, "song")) to \(YouTubeImportLedger.historyPlaylistName)")
        }
        guard var first = parts.first else { return "Nothing new to import." }
        first = first.prefix(1).uppercased() + first.dropFirst()
        return ([first] + parts.dropFirst()).joined(separator: ", ") + "."
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        value == 1 ? "1 \(noun)" : "\(value.formatted()) \(noun)s"
    }
}
