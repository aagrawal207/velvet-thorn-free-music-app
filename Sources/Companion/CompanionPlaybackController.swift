import CryptoKit
import Foundation
import Observation

@MainActor
final class CompanionPlaybackController {
    private(set) var snapshot: CompanionSnapshot

    private let model: MusicAppModel
    private let monotonicNow: @MainActor () -> ContinuousClock.Instant
    private var observedState: ObservedState?
    private var observers: [UUID: Observer] = [:]
    private var responses: [UUID: Receipt] = [:]
    private var responseOrder: [UUID] = []
    private var executionLeases: [UUID: (issuedAt: ContinuousClock.Instant, repeatMode: CompanionRepeatMode)] = [:]
    private var executionLeaseOrder: [UUID] = []
    private var cachedPages: [String: (page: CompanionPage, source: BrowseSource)] = [:]
    private var cachedPageOrder: [String] = []
    private var isHandlingRequest = false
    private var isNotifying = false
    private var notificationPending = false

    init(model: MusicAppModel, monotonicNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.model = model
        self.monotonicNow = monotonicNow
        snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 0, updatedAt: Date(), nowPlaying: nil)
        refreshObservation()
    }

    func observe(_ observer: @escaping @MainActor (CompanionSnapshot) -> Void) -> UUID {
        refreshSnapshot()
        notifyObservers()
        let id = UUID()
        observers[id] = Observer(receive: observer, lastSequence: snapshot.sequence)
        observer(snapshot)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    /// Which companion sent a request; only the like metrics distinguish them, the semantics are identical.
    enum Origin: Sendable {
        case watch, carPlay, nearbyDevice

        var likeSurface: MusicAppModel.LikeSurface {
            switch self {
            case .watch: .watch
            case .carPlay: .carPlay
            case .nearbyDevice: .nearbyDevice
            }
        }
    }

    func handle(_ request: CompanionRequest, origin: Origin = .watch) -> CompanionResponse {
        defer { notifyObservers() }
        refreshSnapshot()
        do {
            try request.validate()
            _ = try CompanionWire.encode(request)
        } catch {
            return issuingLease(for: rejection(request, error: error))
        }

        // Lease renewal changes delivery authorization, not command identity; replay never re-enters mutation validation.
        if let receipt = responses[request.id] {
            guard receipt.matches(request) else { return issuingLease(for: rejection(request, error: Failure.reusedRequestID)) }
            return issuingLease(for: receipt.response)
        }
        guard !isHandlingRequest else { return issuingLease(for: rejection(request, error: Failure.busy)) }
        isHandlingRequest = true
        defer { isHandlingRequest = false }

        let response: CompanionResponse
        do {
            let page = try perform(request, origin: origin)
            refreshSnapshot()
            response = CompanionResponse(id: request.id, accepted: true, snapshot: snapshot, page: page)
        } catch {
            refreshSnapshot()
            response = rejection(request, error: error)
        }
        responses[request.id] = Receipt(request: request, response: response)
        responseOrder.append(request.id)
        if responseOrder.count > 128 { responses.removeValue(forKey: responseOrder.removeFirst()) }
        return issuingLease(for: response)
    }

    private func perform(_ request: CompanionRequest, origin: Origin) throws -> CompanionPage? {
        switch request.action {
        case .snapshot: return nil
        case .browse(let location): return try makePage(location: location).page
        default: break
        }

        let player = model.player
        if let expected = request.expectedTrackID, expected != player.currentTrack?.id { throw Failure.staleTrack }
        switch request.action {
        case .play, .pause, .next, .previous, .seek, .setFavorite, .setSuperLiked:
            guard let track = player.currentTrack else { throw Failure.noTrack }
            guard CompanionWire.isValidIdentifier(track.id) else { throw CompanionWireError.invalidTrackID }
        default: break
        }
        try validateExecutionLease(request.executionLease)

        switch request.action {
        case .play:
            guard !player.isPlaying, !player.isLoading else { return nil }
            try validateExecutionLease(request.executionLease)
            model.cancelPendingRadio()
            player.resumePlayback()
        case .pause:
            try validateExecutionLease(request.executionLease)
            model.cancelPendingRadio()
            player.pause()
        case .next:
            try validateExecutionLease(request.executionLease)
            model.cancelPendingRadio()
            player.next()
        case .previous:
            try validateExecutionLease(request.executionLease)
            model.cancelPendingRadio()
            player.previous()
        case .seek(let position):
            guard PlaybackTiming.position(position) == position else { throw CompanionWireError.invalidSeek }
            let target = PlaybackTiming.position(position, duration: player.duration)
            try validateExecutionLease(request.executionLease)
            player.seek(to: target)
        case .setFavorite(let favorite):
            guard model.library.hasLoadedDocument, !model.library.requiresReload else { throw libraryFailure() }
            guard let track = player.currentTrack else { throw Failure.noTrack }
            let needsChange = model.library.isFavorite(track) != favorite
            try validateExecutionLease(request.executionLease)
            // Unliking from a companion removes a super like with the like, matching the phone heart's tap.
            if needsChange { model.toggleLike(track, surface: origin.likeSurface) }
            guard model.library.isFavorite(track) == favorite else { throw libraryFailure() }
        case .setSuperLiked(let superLiked):
            guard model.library.hasLoadedDocument, !model.library.requiresReload else { throw libraryFailure() }
            guard let track = player.currentTrack else { throw Failure.noTrack }
            let needsChange = model.library.isSuperLiked(track) != superLiked
            try validateExecutionLease(request.executionLease)
            if needsChange { model.toggleSuperLike(track, surface: origin.likeSurface) }
            guard model.library.isSuperLiked(track) == superLiked else { throw libraryFailure() }
        case .setShuffle(let shuffled):
            let needsChange = player.shuffleEnabled != shuffled
            try validateExecutionLease(request.executionLease)
            if needsChange { player.toggleShuffle() }
        case .setRepeatMode(let mode):
            for step in 0..<3 where repeatMode(player.repeatMode) != mode {
                try validateExecutionLease(request.executionLease)
                // Later cycles belong to this command; only the first compares against the preflight value.
                if step == 0, let lease = request.executionLease,
                   executionLeases[lease.id]?.repeatMode != repeatMode(player.repeatMode) { throw Failure.staleRepeatMode }
                player.cycleRepeatMode()
            }
        case .playItem(let location, let itemID, let revision):
            let selection = try makePage(location: location)
            guard selection.page.revision == revision else { throw Failure.stalePage }
            guard case .tracks(_, let tracks) = selection.source,
                  let index = selection.page.items.firstIndex(where: { $0.id == itemID }),
                  tracks.indices.contains(index) else { throw Failure.notPlayable }
            let track = tracks[index]
            guard CompanionWire.isValidIdentifier(track.id) else { throw CompanionWireError.invalidTrackID }
            // Page hashing may outlast the lease; authorize only after its content and occurrence have been checked.
            try validateExecutionLease(request.executionLease)
            if selection.page.location == "queue" { model.playQueueTrack(at: index) }
            else { model.play(track, in: tracks) }
            guard player.currentTrack == track else { throw Failure.notApplied }
        case .snapshot, .browse: break
        }

        if model.library.errorMessage != nil { throw libraryFailure() }
        return nil
    }

    private func validateExecutionLease(_ lease: CompanionExecutionLease?) throws {
        guard let lease else { return }
        guard lease.sessionID == snapshot.sessionID, let issued = executionLeases[lease.id] else {
            throw Failure.invalidExecutionLease
        }
        let elapsed = issued.issuedAt.duration(to: monotonicNow())
        guard elapsed >= .zero, elapsed < .seconds(6) else { throw Failure.invalidExecutionLease }
    }

    private func issuingLease(for response: CompanionResponse) -> CompanionResponse {
        let lease = CompanionExecutionLease(id: UUID(), sessionID: snapshot.sessionID)
        // Cached receipts may describe an older mode; bind authorization to the value actually returned to the caller.
        executionLeases[lease.id] = (issuedAt: monotonicNow(),
                                    repeatMode: response.snapshot.nowPlaying?.repeatMode ?? repeatMode(model.player.repeatMode))
        executionLeaseOrder.append(lease.id)
        if executionLeaseOrder.count > 128 { executionLeases.removeValue(forKey: executionLeaseOrder.removeFirst()) }
        return CompanionResponse(id: response.id, accepted: response.accepted, snapshot: response.snapshot,
                                 page: response.page, error: response.error, executionLease: lease)
    }

    private func rejection(_ request: CompanionRequest, error: any Error) -> CompanionResponse {
        let message: String
        if let error = error as? CompanionWireError { message = error.localizedDescription }
        else if let error = error as? Failure { message = error.localizedDescription }
        else { message = "This companion request couldn’t be completed. Refresh and try again." }
        return CompanionResponse(id: request.id, accepted: false, snapshot: snapshot, error: message)
    }

    private func libraryFailure() -> Failure {
        .library(Self.libraryError)
    }

    private func refreshObservation() {
        let state = withObservationTracking {
            readState()
        } onChange: { [weak self] in
            // Observation fires before the write; one main-actor hop reads the completed mutation and re-arms tracking.
            Task { @MainActor [weak self] in self?.refreshObservation() }
        }
        updateSnapshot(state)
        notifyObservers()
    }

    private func refreshSnapshot() {
        updateSnapshot(readState())
    }

    private func readState() -> ObservedState {
        let player = model.player
        let library = model.library
        // Provider and file-system error strings can contain credentials or paths; transport only fixed presentation copy.
        let libraryError = library.errorMessage.map { _ in Self.libraryError }
        let playbackError = player.errorMessage.map { _ in Self.playbackError }
        let nowPlaying = player.currentTrack.flatMap { track -> CompanionNowPlaying? in
            guard CompanionWire.isValidIdentifier(track.id) else { return nil }
            return CompanionNowPlaying(
                trackID: track.id, title: track.title, artist: track.artistName,
                position: PlaybackTiming.position(player.position, duration: player.duration),
                duration: PlaybackTiming.validDuration(player.duration) ?? 0,
                isPlaying: player.isPlaying, isLoading: player.isLoading,
                isFavorite: library.isFavorite(track), isSuperLiked: library.isSuperLiked(track), shuffleEnabled: player.shuffleEnabled,
                repeatMode: repeatMode(player.repeatMode), errorMessage: playbackError
            )
        }
        return ObservedState(nowPlaying: nowPlaying, queue: player.queue, favorites: library.favorites,
                             recentTracks: library.recentlyPlayed.map(\.track), playlists: library.playlists,
                             libraryError: libraryError, accent: library.preferences.accent.companionAccent)
    }

    private func updateSnapshot(_ state: ObservedState) {
        guard observedState != state else { return }
        observedState = state
        snapshot = CompanionSnapshot(sessionID: snapshot.sessionID, sequence: snapshot.sequence + 1,
                                     updatedAt: Date(), nowPlaying: state.nowPlaying, libraryError: state.libraryError,
                                     accent: state.accent)
        notificationPending = true
    }

    private func notifyObservers() {
        guard !isHandlingRequest, !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        while notificationPending {
            notificationPending = false
            let current = snapshot
            for id in Array(observers.keys) {
                guard var observer = observers[id], observer.lastSequence < current.sequence else { continue }
                observer.lastSequence = current.sequence
                observers[id] = observer
                observer.receive(current)
            }
        }
    }

    private func makePage(location: String) throws -> (page: CompanionPage, source: BrowseSource) {
        guard let location = CompanionWire.canonicalLocation(location) else { throw CompanionWireError.invalidLocation }
        if location != "root", location != "queue", !model.library.hasLoadedDocument || model.library.requiresReload {
            throw libraryFailure()
        }
        let source: BrowseSource
        switch location {
        case "root": source = .root
        case "favorites": source = .tracks(title: "Favorites", model.library.favorites)
        case "recent": source = .tracks(title: "Recently played", model.library.recentlyPlayed.map(\.track))
        case "queue": source = .tracks(title: "Queue", model.player.queue)
        case "playlists": source = .playlists(model.library.playlists)
        default:
            guard let id = UUID(uuidString: String(location.dropFirst(9))),
                  let playlist = model.library.playlists.first(where: { $0.id == id }) else {
                throw CompanionWireError.invalidLocation
            }
            source = .tracks(title: playlist.name, playlist.tracks)
        }

        // Position ticks can refresh a visible list; reuse its hash only while the entire source still matches.
        if let cached = cachedPages[location], cached.source == source { return cached }

        let title: String
        let items: [CompanionItem]
        let count: Int
        switch source {
        case .root:
            title = "Library"
            items = Self.rootItems
            count = items.count
        case .playlists(let playlists):
            title = "Playlists"
            count = playlists.count
            items = playlists.prefix(CompanionWire.maximumItems).map { playlist in
                CompanionItem(id: playlist.id.uuidString, title: playlist.name,
                              subtitle: playlist.tracks.count == 1 ? "1 song" : "\(playlist.tracks.count) songs",
                              destination: "playlist:\(playlist.id.uuidString)")
            }
        case .tracks(let name, let tracks):
            title = name
            count = tracks.count
            // The row ID names an occurrence; the revision binds its index to the complete, untruncated order.
            items = tracks.prefix(CompanionWire.maximumItems).enumerated().map { index, track in
                CompanionItem(id: "item:\(index)", title: track.title, subtitle: track.artistName)
            }
        }
        let revision = try pageRevision(location: location, title: title, source: source)
        let result = (page: CompanionPage(location: location, title: title, revision: revision, items: items,
                                          isTruncated: count > items.count), source: source)
        cachedPages[location] = result
        cachedPageOrder.removeAll { $0 == location }
        cachedPageOrder.append(location)
        if cachedPageOrder.count > 16 { cachedPages.removeValue(forKey: cachedPageOrder.removeFirst()) }
        return result
    }

    private func pageRevision(location: String, title: String, source: BrowseSource) throws -> String {
        var digest = SHA256()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        include(Data(snapshot.sessionID.uuidString.utf8), in: &digest)
        include(Data(location.utf8), in: &digest)
        include(Data(title.utf8), in: &digest)
        switch source {
        case .root:
            for item in Self.rootItems { include(try encoder.encode(item), in: &digest) }
        case .playlists(let playlists):
            for playlist in playlists { include(try encoder.encode(playlist), in: &digest) }
        case .tracks(_, let tracks):
            for track in tracks { include(try encoder.encode(track), in: &digest) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func include(_ data: Data, in digest: inout SHA256) {
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
        digest.update(data: data)
    }

    private func repeatMode(_ mode: RepeatMode) -> CompanionRepeatMode {
        switch mode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private static let libraryError = "Your library change couldn’t be saved. Open Velvet Thorn on your iPhone to try again."
    private static let playbackError = "Playback couldn’t continue. Open Velvet Thorn on your iPhone to try again."
    private static let rootItems = [
        CompanionItem(id: "favorites", title: "Favorites", subtitle: "", destination: "favorites"),
        CompanionItem(id: "recent", title: "Recently played", subtitle: "", destination: "recent"),
        CompanionItem(id: "playlists", title: "Playlists", subtitle: "", destination: "playlists"),
        CompanionItem(id: "queue", title: "Queue", subtitle: "", destination: "queue"),
    ]

    private struct Observer {
        let receive: @MainActor (CompanionSnapshot) -> Void
        var lastSequence: UInt64
    }

    private struct Receipt {
        let request: CompanionRequest
        let response: CompanionResponse

        func matches(_ other: CompanionRequest) -> Bool {
            request.id == other.id && request.version == other.version && request.action == other.action
                && request.expectedTrackID == other.expectedTrackID
        }
    }

    private struct ObservedState: Equatable {
        let nowPlaying: CompanionNowPlaying?
        let queue: [Track]
        let favorites: [Track]
        let recentTracks: [Track]
        let playlists: [UserPlaylist]
        let libraryError: String?
        let accent: CompanionAccent
    }

    private enum BrowseSource: Equatable {
        case root
        case playlists([UserPlaylist])
        case tracks(title: String, [Track])
    }

    private enum Failure: LocalizedError {
        case noTrack, staleTrack, stalePage, notPlayable, notApplied, reusedRequestID, busy, invalidExecutionLease, staleRepeatMode
        case library(String)

        var errorDescription: String? {
            switch self {
            case .noTrack: "Choose a song on your iPhone or in the library first."
            case .staleTrack: "The song has changed. Refresh before using this control."
            case .stalePage: "This list has changed. Refresh it before choosing a song."
            case .notPlayable: "This song is no longer in this list. Refresh and try again."
            case .notApplied: "This song couldn’t be selected. Open Velvet Thorn on your iPhone to try again."
            case .reusedRequestID: "This request was already used for another action. Refresh and try again."
            case .busy: "Playback is updating. Try again."
            case .invalidExecutionLease: "This playback request expired. Refresh and try again."
            case .staleRepeatMode: "Repeat mode changed on your iPhone. Refresh and try again."
            case .library(let message): message
            }
        }
    }
}

extension AppAccent {
    // Exhaustive so a new phone accent cannot ship without a deliberate watch projection.
    var companionAccent: CompanionAccent {
        switch self {
        case .coral: .coral
        case .mint: .mint
        case .ocean: .ocean
        case .violet: .violet
        case .amber: .amber
        case .rose: .rose
        case .teal: .teal
        }
    }
}
