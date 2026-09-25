#if DEBUG
import Foundation

@MainActor
enum WatchDebugFixtures {
    static func client(arguments: [String]) -> WatchRequestClient? {
        guard let flag = arguments.firstIndex(of: "--watch-fixture"),
              arguments.indices.contains(flag + 1),
              let mode = WatchFixtureTransport.Mode(rawValue: arguments[flag + 1]) else { return nil }
        return WatchRequestClient(transport: WatchFixtureTransport(mode: mode))
    }
}

@MainActor
private final class WatchFixtureTransport: WatchTransport {
    enum Mode: String {
        case playing, paused, empty, disconnected, loading, error, pending, long
        case libraryError = "library-error"
        case libraryEmpty = "library-empty"
    }

    var state: WatchConnectionState = .activating
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?
    private let mode: Mode
    private let sessionID = UUID(uuidString: "BFEEF100-1D98-4C91-8120-13C48800F100")!
    private let playlistID = UUID(uuidString: "BFEEF100-1D98-4C91-8120-13C48800F101")!
    private var sequence: UInt64 = 1
    private var isPlaying: Bool
    private var isFavorite = false
    private var isShuffled = false
    private var repeatMode = CompanionRepeatMode.off
    private var songIndex = 0
    private var hasSelection: Bool
    private var isLoading: Bool
    private var playbackError: String?
    private var activated = false
    private var position: Double = 42
    private var lastClock = WatchClock.now
    private var executionLeases: [UUID: TimeInterval] = [:]
    private var leaseOrder: [UUID] = []

    init(mode: Mode) {
        self.mode = mode
        isPlaying = mode != .paused && mode != .empty && mode != .libraryEmpty && mode != .error && mode != .loading
        hasSelection = mode != .empty && mode != .libraryEmpty
        isLoading = mode == .loading
        playbackError = mode == .error ? "Playback couldn’t continue. Open Breezy on iPhone to try again." : nil
    }

    func activate() {
        guard !activated else { return }
        activated = true
        state = .ready(reachable: mode != .disconnected, installed: true, needsUnlock: false)
        onEvent?(.stateChanged(state))
        if let data = try? CompanionWire.encode(snapshot) { onEvent?(.applicationContext(data)) }
    }

    func refreshState() { onEvent?(.stateChanged(state)) }

    func updateApplicationContext(_ data: Data) throws {}

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        guard state.canMessage, let request = try? CompanionWire.decode(CompanionRequest.self, from: data) else {
            completion(.failure(.unreachable))
            return
        }
        advancePosition()
        if !WatchActionPolicy.isReadOnly(request.action) {
            guard let lease = request.executionLease, lease.sessionID == sessionID,
                  let expiry = executionLeases[lease.id], WatchClock.now < expiry else {
                respond(CompanionResponse(id: request.id, accepted: false, snapshot: snapshot,
                                          error: "This action expired. Refresh before trying again."), completion: completion)
                return
            }
            executionLeases[lease.id] = nil
            if let expected = request.expectedTrackID, expected != snapshot.nowPlaying?.trackID {
                respond(CompanionResponse(id: request.id, accepted: false, snapshot: snapshot,
                                          error: "The song has changed. Refresh before using this control."), completion: completion)
                return
            }
        }
        if mode == .pending, !WatchActionPolicy.isReadOnly(request.action) { return }
        var page: CompanionPage?
        var lease: CompanionExecutionLease?
        switch request.action {
        case .snapshot: lease = issueLease()
        case .browse(let location):
            if let error = snapshot.libraryError, location != "root", location != "queue" {
                respond(CompanionResponse(id: request.id, accepted: false, snapshot: snapshot, error: error), completion: completion)
                return
            }
            page = makePage(location)
        case .play: isPlaying = true; isLoading = false; playbackError = nil
        case .pause: isPlaying = false; isLoading = false
        case .next: songIndex = (songIndex + 1) % 3; position = 0
        case .previous: songIndex = (songIndex + 2) % 3; position = 0
        case .seek(let value): position = min(value, 214)
        case .setFavorite(let value): isFavorite = value
        case .setShuffle(let value): isShuffled = value
        case .setRepeatMode(let value): repeatMode = value
        case .playItem(_, let itemID, _):
            songIndex = Int(itemID.replacingOccurrences(of: "item:", with: "")) ?? 0
            hasSelection = true
            isPlaying = true
            isLoading = false
            playbackError = nil
            position = 0
        }
        sequence += 1
        let response = CompanionResponse(id: request.id, accepted: true, snapshot: snapshot, page: page, executionLease: lease)
        respond(response, completion: completion)
    }

    private func respond(_ response: CompanionResponse,
                         completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        if let data = try? CompanionWire.encode(response) { completion(.success(data)) }
        else { completion(.failure(.deliveryFailed)) }
    }

    private func issueLease() -> CompanionExecutionLease {
        let lease = CompanionExecutionLease(id: UUID(), sessionID: sessionID)
        executionLeases[lease.id] = WatchClock.now + 6
        leaseOrder.append(lease.id)
        if leaseOrder.count > 128 { executionLeases[leaseOrder.removeFirst()] = nil }
        return lease
    }

    private var snapshot: CompanionSnapshot {
        CompanionSnapshot(
            sessionID: sessionID, sequence: sequence, updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            nowPlaying: hasSelection ? CompanionNowPlaying(
                trackID: "fixture-song-\(songIndex)", title: title(songIndex), artist: artist(songIndex),
                position: position, duration: 214, isPlaying: isPlaying, isLoading: isLoading,
                isFavorite: isFavorite, shuffleEnabled: isShuffled, repeatMode: repeatMode, errorMessage: playbackError
            ) : nil,
            libraryError: mode == .libraryError || mode == .libraryEmpty
                ? "Your saved library needs attention. Open Breezy on iPhone to check or recover it." : nil
        )
    }

    private func makePage(_ location: String) -> CompanionPage {
        if location == "root" {
            return CompanionPage(location: location, title: "Library", revision: "fixture-root", items: [
                CompanionItem(id: "favorites", title: "Favorites", subtitle: "", destination: "favorites"),
                CompanionItem(id: "recent", title: "Recently played", subtitle: "", destination: "recent"),
                CompanionItem(id: "playlists", title: "Playlists", subtitle: "", destination: "playlists"),
                CompanionItem(id: "queue", title: "Queue", subtitle: "", destination: "queue")
            ], isTruncated: false)
        }
        if location == "playlists" {
            return CompanionPage(location: location, title: "Playlists", revision: "fixture-playlists", items: mode == .empty ? [] : [
                CompanionItem(id: playlistID.uuidString, title: "Evening breeze", subtitle: "3 songs",
                              destination: "playlist:\(playlistID.uuidString)")
            ], isTruncated: false)
        }
        let title = location == "favorites" ? "Favorites" : location == "recent" ? "Recently played"
            : location == "queue" ? "Queue" : "Evening breeze"
        return CompanionPage(location: location, title: title, revision: "fixture-songs", items: mode == .empty ? [] : (0..<3).map {
            CompanionItem(id: "item:\($0)", title: self.title($0), subtitle: artist($0))
        }, isTruncated: false)
    }

    private func title(_ index: Int) -> String {
        if mode == .long { return "बारिश की शाम · A very long song title for a quiet evening" }
        return ["Evening breeze", "A little sunshine", "On the way home"][index % 3]
    }

    private func artist(_ index: Int) -> String {
        mode == .long ? "A long artist credit with a guest vocalist" : ["Breezy Sessions", "The Window Seat", "Sunday Company"][index % 3]
    }

    private func advancePosition() {
        let now = WatchClock.now
        if isPlaying, !isLoading, playbackError == nil { position = min(214, position + max(0, now - lastClock)) }
        lastClock = now
    }
}
#endif
