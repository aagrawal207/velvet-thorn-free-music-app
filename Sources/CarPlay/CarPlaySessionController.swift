import CarPlay
import OSLog
import UIKit

@MainActor
final class CarPlaySessionController: NSObject, CPInterfaceControllerDelegate, CPTabBarTemplateDelegate {
    private struct PlaybackAttempt: Sendable {
        let intent: UUID
        let sessionID: UUID
        let trackID: String
    }

    private let interface: any CarPlayInterfaceTransport
    private let playbackProvider: @MainActor () -> CompanionPlaybackController?
    private let configuredLimits: CarPlayTemplateLimits?
    private var lists: CarPlayListTemplates { CarPlayListTemplates(limits: configuredLimits ?? CarPlayTemplateLimits()) }
    private let navigator: CarPlayTemplateNavigator
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "CarPlay")
    private var connection = UUID()
    private var binding = UUID()
    private var intent = UUID()
    private var playback: CompanionPlaybackController?
    private var observation: UUID?
    private var latestSnapshot: CompanionSnapshot?
    private var playbackAttempt: PlaybackAttempt?
    private var shownPlaybackError: String?
    private var refreshTask: Task<Void, Never>?
    private var initialLoadTask: Task<Void, Never>?
    private var rootLists: [CPListTemplate] = []
    private var browsingRoot: CPTemplate?
    private weak var visibleList: CPListTemplate?
    private(set) var rootTemplate: CPTemplate?
    private(set) var nowPlayingControls: CarPlayNowPlayingControls?
    private(set) var isConnected = false

    init(interface: any CarPlayInterfaceTransport, limits: CarPlayTemplateLimits? = nil,
         playbackProvider: @escaping @MainActor () -> CompanionPlaybackController? = { CompanionRuntime.playback }) {
        self.interface = interface
        self.playbackProvider = playbackProvider
        configuredLimits = limits
        navigator = CarPlayTemplateNavigator(interface: interface)
        super.init()
    }

    isolated deinit { disconnect() }

    func connect() {
        disconnect()
        connection = UUID()
        isConnected = true
        interface.delegate = self
        if lists.limits.tabs == 4 {
            let entries = [("favorites", "Favorites", "heart"), ("recent", "Recently played", "clock"),
                           ("playlists", "Playlists", "music.note.list"), ("queue", "Queue", "list.bullet")]
            rootLists = entries.map { location, title, symbol in
                let list = makeList(location: location, title: title)
                list.tabTitle = title
                list.tabImage = UIImage(systemName: symbol)
                return list
            }
            let tabs = CPTabBarTemplate(templates: rootLists)
            tabs.delegate = self
            browsingRoot = tabs
        } else {
            rootLists = [makeList(location: "root", title: "Library")]
            browsingRoot = rootLists.first
        }
        let connected = connection
        nowPlayingControls = CarPlayNowPlayingControls(request: { [weak self] request, displayed in
            guard let self, self.isCurrent(connected) else { return }
            self.perform(request, sessionID: displayed.sessionID, expectedState: displayed.nowPlaying)
        }, upNext: { [weak self] in
            guard let self, self.isCurrent(connected), self.interface.topTemplate === CPNowPlayingTemplate.shared else { return }
            self.openQueue()
        })
        _ = currentPlayback()
        installBrowsingRoot()
        // The root and shared Now Playing controls are usable before any library work or phone view appears.
        initialLoadTask = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(connected), !Task.isCancelled else { return }
            self.initialLoadTask = nil
            for list in self.rootLists {
                guard self.isCurrent(connected), !Task.isCancelled else { return }
                if let context = self.context(for: list), context.page == nil, !context.hasError { self.load(list) }
                await Task.yield()
            }
        }
    }

    func disconnect() {
        isConnected = false
        connection = UUID()
        binding = UUID()
        refreshTask?.cancel()
        initialLoadTask?.cancel()
        refreshTask = nil
        initialLoadTask = nil
        navigator.disconnect()
        if let observation { playback?.removeObserver(observation) }
        observation = nil
        playback = nil
        latestSnapshot = nil
        playbackAttempt = nil
        shownPlaybackError = nil
        nowPlayingControls?.disconnect()
        nowPlayingControls = nil
        if interface.delegate === self { interface.delegate = nil }
        if let tabs = browsingRoot as? CPTabBarTemplate, tabs.delegate === self { tabs.delegate = nil }
        visibleList = nil
        rootLists = []
        browsingRoot = nil
        rootTemplate = nil
    }

    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard isConnected else { return }
        if let list = aTemplate as? CPListTemplate, context(for: list) != nil {
            visibleList = list
            scheduleRefresh()
        } else {
            visibleList = nil
            if aTemplate === CPNowPlayingTemplate.shared { scheduleRefresh() }
        }
    }

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        guard isConnected, !navigator.isChangingTemplates,
              let list = aTemplate as? CPListTemplate, let context = context(for: list), !context.hasError else { return }
        beginIntent()
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        guard isConnected, tabBarTemplate === browsingRoot else { return }
        beginIntent()
        if let list = selectedTemplate as? CPListTemplate, context(for: list) != nil {
            visibleList = list
            load(list)
        }
    }

    private func makeList(location: String, title: String) -> CPListTemplate {
        lists.make(location: location, title: title, connection: connection) { [weak self] list in
            guard let self, self.isVisible(list) else { return }
            self.beginIntent()
            self.lists.loading(list)
            self.load(list)
        }
    }

    private func installBrowsingRoot() {
        guard isConnected, let browsingRoot else { return }
        rootTemplate = browsingRoot
        let connected = connection
        navigator.installRoot(browsingRoot) { [weak self] message in
            guard let self, self.isCurrent(connected) else { return }
            self.showRootFailure(message)
        }
    }

    private func showRootFailure(_ message: String) {
        log.error("event=root_template_failed")
        let connected = connection
        let fallback = makeList(location: "root", title: "Breezy")
        lists.error(on: fallback, title: "Couldn’t open CarPlay", message: message) { [weak self, weak fallback] in
            guard let self, self.isCurrent(connected), let fallback, self.rootTemplate === fallback,
                  self.isVisible(fallback), !self.navigator.isChangingTemplates else { return }
            self.lists.loading(fallback)
            self.beginIntent()
            self.installBrowsingRoot()
            for list in self.rootLists { self.load(list) }
        }
        rootTemplate = fallback
        navigator.installRoot(fallback) { [weak self] _ in
            guard let self, self.isCurrent(connected) else { return }
            self.log.error("event=fallback_root_template_failed")
        }
    }

    private func currentPlayback() -> CompanionPlaybackController? {
        guard isConnected else { return nil }
        let current = playbackProvider()
        if playback !== current {
            if let observation { playback?.removeObserver(observation) }
            observation = nil
            playback = current
            binding = UUID()
            latestSnapshot = nil
            playbackAttempt = nil
            shownPlaybackError = nil
            nowPlayingControls?.update(nil)
            if let current {
                let connected = connection
                let bound = binding
                observation = current.observe { [weak self] snapshot in
                    guard let self, self.isCurrent(connected), self.binding == bound else { return }
                    guard self.playbackProvider() === self.playback else { _ = self.currentPlayback(); return }
                    self.receive(snapshot)
                }
            }
        }
        return current
    }

    private func load(_ list: CPListTemplate) {
        guard let context = context(for: list) else { return }
        guard let playback = currentPlayback() else {
            showBrowseError(on: list, title: "Breezy isn’t ready",
                            message: "The shared player isn’t available yet. Choose Retry to check again.")
            return
        }
        let request = CompanionRequest(action: .browse(context.location))
        let response = playback.handle(request)
        receive(response.snapshot)
        guard response.id == request.id, response.accepted, let page = response.page, page.location == context.location else {
            if showLibraryFailure(response, on: list) { return }
            showBrowseError(on: list, title: "Couldn’t load your music", message: response.error ?? "Choose Retry to reload this list.")
            return
        }
        let factory = lists
        guard context.page != page || context.sessionID != response.snapshot.sessionID
                || context.displayedItemLimit != factory.limits.items || context.displayedSectionLimit != factory.limits.sections else { return }
        let revision = page.revision
        let sessionID = response.snapshot.sessionID
        factory.display(page, sessionID: sessionID, on: list) { [weak self, weak list] item in
            guard let self, let list else { return }
            self.select(item, from: list, revision: revision, sessionID: sessionID)
        }
    }

    private func showBrowseError(on list: CPListTemplate, title: String, message: String, actionTitle: String = "Retry") {
        lists.error(on: list, title: title, message: message, actionTitle: actionTitle) { [weak self, weak list] in
            guard let self, let list, self.isVisible(list) else { return }
            self.beginIntent()
            self.lists.loading(list)
            self.load(list)
        }
    }

    private func select(_ item: CompanionItem, from list: CPListTemplate, revision: String, sessionID: UUID) {
        guard isVisible(list), let context = context(for: list), context.page?.revision == revision else { return }
        beginIntent()
        guard let playback = currentPlayback() else {
            showBrowseError(on: list, title: "Breezy isn’t ready", message: "The shared player isn’t available. Choose Retry.")
            return
        }
        guard playback.snapshot.sessionID == sessionID else {
            showBrowseError(on: list, title: "Your player changed", message: "Choose Retry to reload this list before selecting a song.")
            return
        }
        if let destination = item.destination {
            let next = makeList(location: destination, title: item.title)
            show(next, originatingFrom: list)
            load(next)
        } else {
            let request = CompanionRequest(action: .playItem(location: context.location, itemID: item.id, revision: revision))
            let response = playback.handle(request)
            receive(response.snapshot)
            guard response.id == request.id, response.accepted else {
                if showLibraryFailure(response, on: list) { return }
                showBrowseError(on: list, title: "Couldn’t play this song", message: response.error ?? "Reload this list and try again.")
                return
            }
            recordPlaybackAttempt(response.snapshot)
            show(CPNowPlayingTemplate.shared, originatingFrom: list)
            scheduleRefresh()
        }
    }

    private func show(_ template: CPTemplate, originatingFrom source: CPListTemplate?) {
        let connected = connection
        let selectedIntent = intent
        navigator.show(template) { [weak self, weak source] message in
            guard let self, self.isCurrent(connected), self.intent == selectedIntent else { return }
            self.log.error("event=template_navigation_failed")
            if let source, self.isVisible(source) {
                self.lists.error(on: source, title: "Couldn’t open this screen", message: message) { [weak self, weak source] in
                    guard let self, self.isCurrent(connected), let source, self.isVisible(source) else { return }
                    self.beginIntent()
                    self.load(source)
                    self.show(template, originatingFrom: source)
                }
            } else {
                self.showNavigationFailure(message, retrying: template)
            }
        }
    }

    private func showNavigationFailure(_ message: String, retrying target: CPTemplate) {
        let connected = connection
        let errorList = makeList(location: "queue", title: "CarPlay")
        lists.error(on: errorList, title: "Couldn’t open this screen", message: message) { [weak self, weak errorList] in
            guard let self, self.isCurrent(connected), let errorList, self.isVisible(errorList) else { return }
            self.beginIntent()
            self.show(target, originatingFrom: errorList)
        }
        navigator.show(errorList) { [weak self] _ in
            guard let self, self.isCurrent(connected) else { return }
            self.log.error("event=navigation_error_template_failed")
        }
    }

    private func openQueue() {
        guard isConnected else { return }
        beginIntent()
        let queue = interface.templates.compactMap { $0 as? CPListTemplate }.first {
            context(for: $0)?.location == "queue" && context(for: $0)?.hasError == false
        } ?? makeList(location: "queue", title: "Queue")
        show(queue, originatingFrom: visibleList)
        load(queue)
    }

    private func perform(_ request: CompanionRequest, sessionID: UUID, returnToNowPlaying: Bool = false,
                         expectedState: CompanionNowPlaying? = nil) {
        guard isConnected else { return }
        if request.action == .play || returnToNowPlaying { beginIntent() }
        guard let playback = currentPlayback(), playback.snapshot.sessionID == sessionID else {
            beginIntent()
            showActionError("The shared player changed or isn’t ready. Reload your queue to continue.", retry: { [weak self] in
                self?.openQueue()
            })
            return
        }
        if let expectedState {
            let current = playback.handle(CompanionRequest(action: .snapshot)).snapshot
            receive(current)
            guard let actual = current.nowPlaying, actual.trackID == expectedState.trackID else { return }
            switch request.action {
            case .setFavorite where actual.isFavorite != expectedState.isFavorite: return
            case .setShuffle where actual.shuffleEnabled != expectedState.shuffleEnabled: return
            case .setRepeatMode where actual.repeatMode != expectedState.repeatMode: return
            default: break
            }
        }
        let response = playback.handle(request)
        receive(response.snapshot)
        guard response.id == request.id, response.accepted else {
            if let expected = request.expectedTrackID, expected != response.snapshot.nowPlaying?.trackID { return }
            beginIntent()
            if showLibraryFailure(response) { return }
            showActionError(response.error ?? "The player couldn’t make this change. Try again.") { [weak self] in
                self?.perform(CompanionRequest(action: request.action, expectedTrackID: request.expectedTrackID),
                              sessionID: sessionID, returnToNowPlaying: true)
            }
            return
        }
        if case .play = request.action {
            recordPlaybackAttempt(response.snapshot)
            show(CPNowPlayingTemplate.shared, originatingFrom: visibleList)
            scheduleRefresh()
        } else if returnToNowPlaying {
            show(CPNowPlayingTemplate.shared, originatingFrom: visibleList)
        }
    }

    private func showLibraryFailure(_ response: CompanionResponse, on source: CPListTemplate? = nil) -> Bool {
        guard !response.accepted, let message = response.snapshot.libraryError else { return false }
        if let source {
            showBrowseError(on: source, title: "Library needs attention", message: message, actionTitle: "Reload")
        } else {
            let connected = connection
            let notice = makeList(location: "queue", title: "Library")
            lists.error(on: notice, title: "Library needs attention", message: message,
                        actionTitle: "Now Playing", actionSymbol: "music.note") { [weak self, weak notice] in
                guard let self, self.isCurrent(connected), let notice, self.isVisible(notice) else { return }
                self.beginIntent()
                self.show(CPNowPlayingTemplate.shared, originatingFrom: notice)
            }
            show(notice, originatingFrom: visibleList)
        }
        return true
    }

    private func showActionError(_ message: String, retry: @escaping @MainActor @Sendable () -> Void) {
        let connected = connection
        let errorList = makeList(location: "queue", title: "Playback")
        lists.error(on: errorList, title: "Couldn’t update playback", message: message) { [weak self, weak errorList] in
            guard let self, self.isCurrent(connected), let errorList, self.isVisible(errorList) else { return }
            retry()
        }
        show(errorList, originatingFrom: visibleList)
    }

    private func recordPlaybackAttempt(_ snapshot: CompanionSnapshot) {
        guard let playing = snapshot.nowPlaying else { return }
        playbackAttempt = PlaybackAttempt(intent: intent, sessionID: snapshot.sessionID, trackID: playing.trackID)
    }

    private func receive(_ snapshot: CompanionSnapshot) {
        guard isConnected else { return }
        let previous = latestSnapshot
        if let previous, previous.sessionID == snapshot.sessionID, snapshot.sequence <= previous.sequence { return }
        latestSnapshot = snapshot
        nowPlayingControls?.update(snapshot)
        if let playbackAttempt, playbackAttempt.sessionID != snapshot.sessionID || playbackAttempt.trackID != snapshot.nowPlaying?.trackID {
            self.playbackAttempt = nil
        }
        let old = previous?.nowPlaying
        let new = snapshot.nowPlaying
        if visibleList != nil || old == new || old?.trackID != new?.trackID || old?.isFavorite != new?.isFavorite
            || old?.shuffleEnabled != new?.shuffleEnabled || old?.errorMessage != new?.errorMessage {
            scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        guard isConnected, refreshTask == nil else { return }
        let connected = connection
        refreshTask = Task { @MainActor [weak self] in
            guard let self, self.isCurrent(connected), !Task.isCancelled else { return }
            self.refreshTask = nil
            if let list = self.visibleList, let context = self.context(for: list), !context.hasError { self.load(list) }
            self.presentPlaybackFailureIfNeeded()
        }
    }

    private func presentPlaybackFailureIfNeeded() {
        guard playbackAttempt != nil || interface.topTemplate === CPNowPlayingTemplate.shared,
              let playback = currentPlayback() else { return }
        let current = playback.handle(CompanionRequest(action: .snapshot)).snapshot
        receive(current)
        if playbackAttempt == nil, interface.topTemplate === CPNowPlayingTemplate.shared { recordPlaybackAttempt(current) }
        // Library recovery belongs on the phone; only the bridge's playback error can offer a playback retry.
        guard let attempt = playbackAttempt, attempt.intent == intent,
              let snapshot = latestSnapshot, snapshot.sessionID == attempt.sessionID,
              let playing = snapshot.nowPlaying, playing.trackID == attempt.trackID,
              let message = playing.errorMessage, !message.isEmpty, shownPlaybackError != message else { return }
        shownPlaybackError = message
        showActionError(message) { [weak self] in
            self?.perform(CompanionRequest(action: .play, expectedTrackID: attempt.trackID), sessionID: attempt.sessionID)
        }
    }

    private func beginIntent() {
        intent = UUID()
        playbackAttempt = nil
        shownPlaybackError = nil
        navigator.userChangedNavigation()
    }

    private func context(for template: CPListTemplate) -> CarPlayListContext? {
        guard isConnected, let context = template.userInfo as? CarPlayListContext, context.connection == connection else { return nil }
        return context
    }

    private func isVisible(_ list: CPListTemplate) -> Bool {
        guard context(for: list) != nil else { return false }
        let top = interface.topTemplate
        if top === list { return true }
        guard top === browsingRoot, let tabs = browsingRoot as? CPTabBarTemplate else { return false }
        return (tabs.selectedTemplate ?? rootLists.first) === list
    }

    private func isCurrent(_ connected: UUID) -> Bool { isConnected && connection == connected }
}
