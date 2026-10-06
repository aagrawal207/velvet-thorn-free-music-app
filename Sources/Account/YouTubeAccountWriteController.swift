import Foundation
import Observation
import OSLog

@MainActor @Observable
final class YouTubeAccountWriteController {
    struct Context: Equatable, Sendable {
        let generation: UUID
        let sessionRevision: UInt64
    }

    private(set) var isBusy = false
    private(set) var isLoadingPlaylists = false
    private(set) var playlists: [MusicCollection] = []
    private(set) var playlistsAreLimited = false
    private(set) var message: String?
    private(set) var permissionError: String?
    private(set) var presentationGeneration = UUID()
    private var permission: YouTubeAccountWritePermissionStore.Permission?
    private var permissionBlocked = false
    private let account: YouTubeAccountStore
    @ObservationIgnored private let permissions: YouTubeAccountWritePermissionStore
    @ObservationIgnored private let client: any YouTubeAccountWriteProviding
    @ObservationIgnored private let isOffline: @MainActor () -> Bool
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var access: YouTubeAccountWriteAccess?
    @ObservationIgnored private var playlistContext: Context?
    @ObservationIgnored private var playlistsReadAt: ContinuousClock.Instant?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Account")

    init(account: YouTubeAccountStore, permissions: YouTubeAccountWritePermissionStore = .init(),
         client: any YouTubeAccountWriteProviding = YouTubeAccountWriteClient(),
         isOffline: @escaping @MainActor () -> Bool = { false }) {
        self.account = account
        self.permissions = permissions
        self.client = client
        self.isOffline = isOffline
        do { permission = try permissions.read() }
        catch { blockPermission() }
        observer = account.observeSessionChanges { [weak self] in self?.sessionChanged() }
    }

    deinit {
        work?.cancel()
        access?.retire()
    }

    var hasSession: Bool { account.isSignedIn && !account.isSignOutPending }
    var canAuthorize: Bool { hasSession && !account.isExpired && account.session?.writeSessionID != nil }
    var allowsChanges: Bool {
        canAuthorize && !permissionBlocked && permission?.allow == true
            && permission?.sessionID == account.session?.writeSessionID
    }
    var context: Context { Context(generation: presentationGeneration, sessionRevision: account.sessionRevision) }

    /// Call only from the explicit device/account permission control, never from library preference propagation.
    func setAllowsChanges(_ allow: Bool) {
        retirePending()
        presentationGeneration = UUID()
        clearPlaylists()
        if allow && !canAuthorize { message = YouTubeAccountWriteError.notSignedIn.localizedDescription; return }
        do {
            permission = try permissions.setAllowed(allow, sessionID: account.session?.writeSessionID)
            permissionBlocked = false
            permissionError = nil
            log.info("event=account_write_permission enabled=\(allow)")
        } catch { blockPermission() }
    }

    func loadOwnedPlaylists(context expected: Context) {
        guard !isBusy else { return }
        do {
            let access = try authorize(expected)
            clearPlaylists()
            isLoadingPlaylists = true
            let id = begin(access)
            work = Task { [weak self, client] in
                do {
                    let listing = try await client.ownedPlaylists(access: access)
                    try access.check()
                    guard let self, self.activeID == id, self.context == expected else { return }
                    self.playlists = listing.items
                    self.playlistsAreLimited = listing.isLimited
                    self.playlistContext = expected
                    self.playlistsReadAt = .now
                    self.message = listing.items.isEmpty ? "No owned playlists were found in the pages YouTube returned." : nil
                    self.log.info("event=account_write_playlists status=ok count=\(listing.items.count)")
                    self.finish(id)
                } catch {
                    guard let self, self.activeID == id, self.context == expected else { return }
                    self.report(error, operation: "playlists")
                    self.finish(id)
                }
            }
        } catch { report(error, operation: "playlists") }
    }

    /// These are remote-only actions; a caller supplies the context captured when its UI was presented.
    func perform(_ action: YouTubeAccountWriteAction, track: Track, playlist: MusicCollection? = nil, context expected: Context) {
        guard !isBusy else { return }
        guard [.like, .removeLike, .addToPlaylist].contains(action), let id = YouTubeAccountWriteTarget.videoID(track) else {
            report(YouTubeAccountWriteError.invalidTarget, operation: action.rawValue)
            return
        }
        if action == .addToPlaylist {
            guard let playlist, playlistContext == expected, let readAt = playlistsReadAt,
                  readAt.duration(to: .now) < .seconds(300), playlists.contains(where: { $0.id == playlist.id }),
                  playlist.kind == .playlist else {
                report(YouTubeAccountWriteError.notOwned, operation: action.rawValue)
                return
            }
        }
        start(action, targetID: id, playlistID: playlist?.id, expected: expected)
    }

    func setSubscribed(_ subscribed: Bool, artist: ArtistCredit, context expected: Context) {
        guard !isBusy else { return }
        let action: YouTubeAccountWriteAction = subscribed ? .subscribe : .unsubscribe
        guard let id = YouTubeAccountWriteTarget.channelID(artist) else {
            report(YouTubeAccountWriteError.invalidTarget, operation: action.rawValue)
            return
        }
        start(action, targetID: id, playlistID: nil, expected: expected)
    }

    func cancel() {
        retirePending()
        presentationGeneration = UUID()
        clearPlaylists()
    }

    /// The model calls this when its owning scene/runtime is permanently retired.
    func shutdown() {
        cancel()
        if let observer { account.removeSessionObserver(observer) }
        observer = nil
    }

    private func start(_ action: YouTubeAccountWriteAction, targetID: String, playlistID: String?, expected: Context) {
        guard !isBusy else { return }
        do {
            let access = try authorize(expected)
            let id = begin(access)
            log.info("event=account_write action=\(action.rawValue, privacy: .public) status=started")
            work = Task { [weak self, client] in
                do {
                    try await client.perform(action, targetID: targetID, playlistID: playlistID, access: access)
                    try access.check()
                    guard let self, self.activeID == id, self.context == expected else { return }
                    _ = try self.checkPermission(expected)
                    self.message = "Confirmed on YouTube."
                    self.log.info("event=account_write action=\(action.rawValue, privacy: .public) status=confirmed")
                    self.finish(id)
                } catch {
                    guard let self, self.activeID == id, self.context == expected else { return }
                    self.report(error, operation: action.rawValue)
                    self.finish(id)
                }
            }
        } catch { report(error, operation: action.rawValue) }
    }

    private func checkPermission(_ expected: Context) throws -> YouTubeAccountSession {
        guard context == expected else { throw YouTubeAccountWriteError.retired }
        guard canAuthorize, let session = account.session else { throw YouTubeAccountWriteError.notSignedIn }
        do {
            let current = try permissions.read()
            guard current == permission else { throw YouTubeAccountWriteError.permissionStorage }
        } catch {
            blockPermission()
            access?.retire()
            throw YouTubeAccountWriteError.permissionStorage
        }
        guard allowsChanges else { throw YouTubeAccountWriteError.notOptedIn }
        return session
    }

    private func authorize(_ expected: Context) throws -> YouTubeAccountWriteAccess {
        let session = try checkPermission(expected)
        guard !isOffline() else { throw YouTubeAccountWriteError.offline }
        return YouTubeAccountWriteAccess(session: session, generation: permission!.generation)
    }

    private func begin(_ access: YouTubeAccountWriteAccess) -> UUID {
        let id = UUID()
        activeID = id
        self.access = access
        isBusy = true
        message = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        access?.retire()
        access = nil
        activeID = nil
        work = nil
        isBusy = false
        isLoadingPlaylists = false
    }

    private func retirePending() {
        let mutationWasPending = isBusy && !isLoadingPlaylists
        access?.retire()
        work?.cancel()
        access = nil
        work = nil
        activeID = nil
        isBusy = false
        isLoadingPlaylists = false
        message = mutationWasPending ? YouTubeAccountWriteError.couldNotConfirm.localizedDescription : nil
        if mutationWasPending { log.info("event=account_write action=pending status=retired") }
    }

    private func sessionChanged() {
        retirePending()
        presentationGeneration = UUID()
        clearPlaylists()
    }

    private func clearPlaylists() {
        playlists = []
        playlistsAreLimited = false
        playlistContext = nil
        playlistsReadAt = nil
    }

    private func blockPermission() {
        permissionBlocked = true
        permissionError = YouTubeAccountWriteError.permissionStorage.localizedDescription
        log.error("event=account_write_permission status=storage_error")
    }

    private func report(_ error: any Error, operation: String) {
        let failure = error as? YouTubeAccountWriteError ?? .couldNotConfirm
        message = failure.localizedDescription
        log.info("event=account_write action=\(operation, privacy: .public) status=\(failure.rawValue, privacy: .public)")
    }
}
