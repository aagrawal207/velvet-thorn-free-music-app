import Foundation
import Observation

@MainActor @Observable
final class WatchCompanionModel {
    private(set) var connection: WatchConnectionState = .activating
    private(set) var timeline = WatchSnapshotState()
    private(set) var pendingCommand: CompanionRequest?
    private(set) var isRefreshing = false
    private(set) var needsReconciliation = false
    private(set) var notice: String?
    private(set) var pages: [String: CompanionPage] = [:]
    private(set) var loadingPages: Set<String> = []
    private(set) var pageErrors: [String: String] = [:]
    private(set) var contentRevision: UInt64 = 0
    private(set) var isForeground = false

    @ObservationIgnored private let client: WatchRequestClient
    @ObservationIgnored private let uptime: @MainActor () -> TimeInterval
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lifecycle = UUID()
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var pageRequestIDs: [String: UUID] = [:]
    @ObservationIgnored private var pageRevisions: [String: UInt64] = [:]
    @ObservationIgnored private var pendingWasDispatched = false

    init(client: WatchRequestClient, uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now }) {
        self.client = client
        self.uptime = uptime
    }

    deinit {
        refreshTask?.cancel()
        heartbeatTask?.cancel()
    }

    var nowPlaying: CompanionNowPlaying? { timeline.snapshot?.nowPlaying }
    var libraryError: String? { timeline.snapshot?.libraryError }
    var isCurrent: Bool { timeline.isCurrent(at: uptime()) }
    var isPlaying: Bool { timeline.isPlaying(at: uptime()) }
    var position: Double { timeline.position(at: uptime()) }
    var canChooseItem: Bool { isCurrent && !needsReconciliation && pendingCommand == nil }
    var canControl: Bool { canChooseItem && nowPlaying != nil }

    func start() {
        guard !started else { return }
        started = true
        client.onStateChange = { [weak self] state in self?.connectionChanged(state) }
        client.onSnapshot = { [weak self] snapshot in self?.receiveContext(snapshot) }
        client.start()
    }

    func setForeground(_ foreground: Bool) {
        start()
        guard foreground != isForeground else { return }
        isForeground = foreground
        lifecycle = UUID()
        timeline.setAvailability(reachable: connection.canMessage, foreground: foreground, at: uptime())
        heartbeatTask?.cancel()
        heartbeatTask = nil
        if foreground {
            contentRevision &+= 1
            client.refreshConnection()
            scheduleRefresh()
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    guard let self, isForeground else { return }
                    await refresh()
                }
            }
        } else {
            if pendingCommand != nil, pendingWasDispatched { markUncertain() }
            pendingCommand = nil
            pendingWasDispatched = false
            refreshID = nil
            isRefreshing = false
            refreshTask?.cancel()
            refreshTask = nil
            pageRequestIDs.removeAll()
            loadingPages.removeAll()
            client.cancelAll()
        }
    }

    func refresh() async {
        guard isForeground, !isRefreshing else { return }
        client.refreshConnection()
        guard connection.canMessage else { return }
        let request = CompanionRequest(action: .snapshot)
        let lifecycle = self.lifecycle
        refreshID = request.id
        isRefreshing = true
        defer {
            if refreshID == request.id {
                refreshID = nil
                isRefreshing = false
            }
        }
        do {
            let response = try await client.request(request)
            guard lifecycle == self.lifecycle, isForeground, refreshID == request.id else { return }
            let wasUncertain = needsReconciliation
            guard accept(response.snapshot) else { return }
            if wasUncertain {
                notice = "Updated from iPhone. Check the player before trying that action again."
            } else if response.accepted {
                notice = nil
            } else {
                notice = response.error ?? "Couldn’t update from iPhone."
            }
        } catch is CancellationError {
        } catch {
            guard lifecycle == self.lifecycle, isForeground, refreshID == request.id else { return }
            timeline.invalidate(at: uptime())
            if !needsReconciliation { notice = "Couldn’t update from iPhone. Open Breezy there, then refresh." }
        }
    }

    @discardableResult
    func command(_ action: CompanionAction, displayed: CompanionSnapshot) async -> Bool {
        guard !WatchActionPolicy.isReadOnly(action), canChooseItem else { return false }
        guard let current = timeline.snapshot,
              WatchActionPolicy.matches(action, displayed: displayed, current: current) else {
            notice = "The player changed. Check the latest song and controls before trying again."
            return false
        }
        switch action {
        case .playItem: break
        default: guard displayed.nowPlaying != nil else { return false }
        }
        let request = CompanionRequest(action: action, expectedTrackID: displayed.nowPlaying?.trackID)
        let lifecycle = self.lifecycle
        pendingCommand = request
        pendingWasDispatched = false
        notice = nil
        defer {
            if pendingCommand?.id == request.id {
                pendingCommand = nil
                pendingWasDispatched = false
            }
        }
        do {
            let response = try await client.request(request, displayed: displayed) { [weak self] preflight in
                guard let self, lifecycle == self.lifecycle, isForeground, pendingCommand?.id == request.id,
                      !needsReconciliation, let current = timeline.snapshot,
                      WatchActionPolicy.matches(action, displayed: displayed, current: current) else { return false }
                return accept(preflight)
            } willSendMutation: { [weak self] in
                self?.pendingWasDispatched = true
            }
            guard lifecycle == self.lifecycle, isForeground, pendingCommand?.id == request.id else { return false }
            guard accept(response.snapshot) else {
                markUncertain()
                scheduleRefresh()
                return false
            }
            contentRevision &+= 1
            if !response.accepted { notice = response.error ?? "This action couldn’t be completed. Refresh and try again." }
            return response.accepted
        } catch WatchRequestError.busy {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            notice = "Your iPhone is updating. Try again in a moment."
            return false
        } catch WatchRequestError.unreachable {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            timeline.invalidate(at: uptime())
            notice = "Open Breezy on iPhone, then refresh."
            return false
        } catch WatchRequestError.staleContext {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            notice = "The player changed. Check the latest song and controls before trying again."
            scheduleRefresh()
            return false
        } catch WatchRequestError.leaseUnavailable {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            notice = "Couldn’t prepare this action. Update Breezy on iPhone and watch, then refresh."
            return false
        } catch let error as CompanionWireError {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            notice = error.localizedDescription
            return false
        } catch {
            guard lifecycle == self.lifecycle, pendingCommand?.id == request.id else { return false }
            if pendingWasDispatched {
                // WCSession cannot recall a dispatched command, including a cancelled or mismatched reply.
                markUncertain()
                scheduleRefresh()
            } else if !(error is CancellationError) {
                notice = "Couldn’t check the player on iPhone. Refresh and try again."
            }
            return false
        }
    }

    func loadPage(_ location: String, force: Bool = false) async {
        guard CompanionWire.canonicalLocation(location) != nil, isForeground else { return }
        guard connection.canMessage else {
            pageErrors[location] = "Open Breezy on iPhone to load your library."
            return
        }
        guard pageRequestIDs[location] == nil else { return }
        if !force, pages[location] != nil, pageRevisions[location] == contentRevision { return }
        let request = CompanionRequest(action: .browse(location))
        let lifecycle = self.lifecycle
        pageRequestIDs[location] = request.id
        loadingPages.insert(location)
        pageErrors[location] = nil
        defer {
            if pageRequestIDs[location] == request.id {
                pageRequestIDs[location] = nil
                loadingPages.remove(location)
            }
        }
        do {
            let response = try await client.request(request)
            guard lifecycle == self.lifecycle, isForeground, pageRequestIDs[location] == request.id else { return }
            guard accept(response.snapshot) else {
                pageErrors[location] = "Your iPhone session changed. Refresh this page."
                return
            }
            guard response.accepted, let page = response.page,
                  CompanionWire.canonicalLocation(page.location) == CompanionWire.canonicalLocation(location),
                  Set(page.items.map(\.id)).count == page.items.count else {
                pageErrors[location] = response.error ?? "This page couldn’t be loaded. Refresh and try again."
                return
            }
            pages[location] = page
            pageRevisions[location] = contentRevision
        } catch is CancellationError {
        } catch {
            guard lifecycle == self.lifecycle, pageRequestIDs[location] == request.id else { return }
            pageErrors[location] = "Couldn’t load this page from iPhone."
        }
    }

    func dismissNotice() { notice = nil }

    var connectionTitle: String {
        switch connection {
        case .unsupported: "Companion unavailable"
        case .activating: "Connecting to iPhone"
        case .inactive: "Reconnecting to iPhone"
        case .failed: "Connection unavailable"
        case .ready(_, false, _): "Install Breezy on iPhone"
        case .ready(_, _, true): "Unlock your iPhone"
        case .ready(false, _, _): "iPhone unavailable"
        case .ready(true, _, _): isCurrent ? "On iPhone" : "Updating from iPhone"
        }
    }

    var connectionDetail: String {
        switch connection {
        case .ready(_, false, _): "This watch app controls Breezy on your paired iPhone."
        case .ready(_, _, true): "Unlock your iPhone after restarting it, then open Breezy."
        case .ready(false, _, _), .failed, .inactive:
            "Open Breezy on your paired iPhone and keep it nearby."
        case .unsupported: "Use Breezy on your iPhone to play music."
        default: "Your music plays on iPhone. Controls update when it replies."
        }
    }

    private func connectionChanged(_ state: WatchConnectionState) {
        let wasReachable = connection.canMessage
        connection = state
        timeline.setAvailability(reachable: state.canMessage, foreground: isForeground, at: uptime())
        if wasReachable && !state.canMessage {
            if pendingCommand != nil, pendingWasDispatched { markUncertain() }
        }
        if state.canMessage && !wasReachable {
            contentRevision &+= 1
            scheduleRefresh()
        }
    }

    private func receiveContext(_ snapshot: CompanionSnapshot) {
        let previousSession = timeline.snapshot?.sessionID
        timeline.receive(snapshot, source: .applicationContext, at: uptime())
        if previousSession != nil, previousSession != snapshot.sessionID { scheduleRefresh() }
    }

    private func accept(_ snapshot: CompanionSnapshot) -> Bool {
        let previousSession = timeline.snapshot?.sessionID
        timeline.receive(snapshot, source: .reply, at: uptime())
        guard timeline.snapshot?.sessionID == snapshot.sessionID, isCurrent else { return false }
        needsReconciliation = false
        if previousSession != snapshot.sessionID {
            pages.removeAll()
            pageRevisions.removeAll()
            contentRevision &+= 1
        }
        return true
    }

    private func markUncertain() {
        guard !needsReconciliation else { return }
        needsReconciliation = true
        timeline.invalidate(at: uptime())
        notice = "No confirmation from iPhone. Refresh to check the player before trying that action again."
        pendingCommand = nil
        pendingWasDispatched = false
        refreshID = nil
        isRefreshing = false
        refreshTask?.cancel()
        refreshTask = nil
        pageRequestIDs.removeAll()
        loadingPages.removeAll()
        client.cancelAll()
    }

    private func scheduleRefresh() {
        guard isForeground, connection.canMessage else { return }
        refreshTask = Task { [weak self] in await self?.refresh() }
    }
}
