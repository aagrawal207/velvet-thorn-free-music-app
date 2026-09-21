import Foundation
import Observation
import OSLog
import SwiftUI

enum AppTab: Hashable { case home, search, library, recap }

@MainActor @Observable
final class MusicAppModel {
    // Provider copy can change; these IDs identify the two hitlists rather than the whole editorial category.
    private static let excludedHomeShelfIDs: Set<String> = ["editorial-hindi", "editorial-english"]

    let library: LibraryStore
    let player: PlayerController
    let catalog: any MusicCatalogProviding
    let lyrics: any LyricsProviding
    /// Optional YouTube sign-in used only for stream lookups.
    let account: YouTubeAccountStore
    let tips: TipJarService
    @ObservationIgnored let releases: ReleaseWatcher
    @ObservationIgnored private let chartProvider: any MusicChartsProviding
    @ObservationIgnored private let engine: RecommendationEngine
    @ObservationIgnored private let experienceRadio: ExperienceRadioEngine
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Discovery")
    @ObservationIgnored private var homeGeneration = UUID()
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var personalizationGeneration = UUID()
    @ObservationIgnored private var completedSearch: SearchIdentity?
    @ObservationIgnored private var loadedLanguages: Set<MusicLanguage>?
    @ObservationIgnored private var loadedAt: Date?
    @ObservationIgnored private var mixesTask: Task<Void, Never>?
    @ObservationIgnored private var followTasks: Set<String> = []
    @ObservationIgnored private var artistLookupGeneration = UUID()
    @ObservationIgnored private let generatesMixes: Bool
    @ObservationIgnored private var consumedSearchFocusRequest = 0
    @ObservationIgnored private var radioSelectionGeneration = UUID()
    @ObservationIgnored private var radioContinuationGeneration = UUID()
    @ObservationIgnored private var playbackIntentGeneration = UUID()
    @ObservationIgnored private var needsInitialPlaybackRestore = false
    @ObservationIgnored private var radioSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var radioRetryTask: Task<Void, Never>?
    @ObservationIgnored private var radioRequestLanguages: Set<MusicLanguage>?
    @ObservationIgnored private var radioRequestUsesPreferences = true

    var selectedTab: AppTab = .home {
        didSet {
            if selectedTab != oldValue { cancelPendingArtistLookup() }
            if selectedTab != .search { dismissSearchKeyboard() }
        }
    }
    var isPlayerPresented = false {
        didSet {
            if isPlayerPresented != oldValue { cancelPendingArtistLookup() }
            if isPlayerPresented { dismissSearchKeyboard() }
        }
    }
    var isSettingsPresented = false {
        didSet {
            if isSettingsPresented != oldValue { cancelPendingArtistLookup() }
            if isSettingsPresented { dismissSearchKeyboard() }
        }
    }
    var toast: String?
    /// Programmatic pushes per tab (album and artist pages opened from the player); tapped links push on top.
    var navigationPaths: [AppTab: [MusicCollection]] = [:] {
        didSet {
            if navigationPaths[selectedTab, default: []] != oldValue[selectedTab, default: []] { cancelPendingArtistLookup() }
        }
    }
    private(set) var homeSections: [DiscoverySection] = []
    private(set) var charts: [ChartSnapshot] = []
    private(set) var isLoadingHome = false
    private(set) var isGeneratingMixes = false
    private var releaseChecksInFlight = 0
    var isCheckingNewReleases: Bool { releaseChecksInFlight > 0 }
    /// True once listening history is rich enough for personal mixes; Home hides the "play a few songs" hint.
    private(set) var hasListeningProfile = false
    private(set) var homeError: String?
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { cancelPendingArtistLookup() } }
    }
    var searchFilter: SearchFilter = .songs {
        didSet { if searchFilter != oldValue { cancelPendingArtistLookup() } }
    }
    private(set) var searchPage = CatalogPage()
    private(set) var isSearching = false
    private(set) var searchError: String?
    private(set) var hasSearched = false
    private(set) var searchFocusRequest = 0
    private(set) var searchFocusDismissal = 0
    private(set) var selectedRadioExperience: RadioExperience?
    private(set) var isLoadingRadio = false
    private(set) var radioError: String?
    private(set) var isContinuingRadio = false
    private(set) var radioContinuationError: String?
    private var radioSession: RadioSession?
    /// True while a title-only credit is being matched to an artist page.
    private(set) var isArtistLookupPending = false

    init(library: LibraryStore = LibraryStore(), player: PlayerController? = nil,
         catalog: (any MusicCatalogProviding)? = nil,
         charts: (any MusicChartsProviding)? = nil,
         lyrics: (any LyricsProviding)? = nil,
         releaseNotifier: (any ReleaseNotifying)? = nil,
         account: YouTubeAccountStore? = nil,
         generatesMixes: Bool = true) {
        LyricsDNSConfiguration.configure(enabled: library.preferences.useEncryptedDNS)
        self.generatesMixes = generatesMixes
        let player = player ?? PlayerController()
        let catalog = catalog ?? YouTubeMusicService()
        self.library = library
        self.player = player
        self.catalog = catalog
        self.account = account ?? YouTubeAccountStore()
        #if DEBUG
        let observingPurchases = !ProcessInfo.processInfo.arguments.contains("--uitesting")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #else
        let observingPurchases = true
        #endif
        self.tips = TipJarService(library: library, observeTransactions: observingPurchases)
        self.chartProvider = charts ?? YouTubeChartsService()
        self.lyrics = lyrics ?? CompositeLyricsProvider(primary: LRCLyricsService(), fallback: catalog as? any LyricsProviding)
        self.engine = RecommendationEngine(catalog: catalog)
        self.experienceRadio = ExperienceRadioEngine(catalog: catalog)
        self.releases = ReleaseWatcher(library: library, catalog: catalog, notifier: releaseNotifier ?? LocalReleaseNotifier())
        player.setAudioCacheLimit(library.preferences.audioCacheLimit)
        player.setRemoteFallbackEnabled(library.preferences.allowRemoteFallback)
        player.apply(PlaybackTransitionSettings(library.preferences))
        needsInitialPlaybackRestore = !library.hasLoadedDocument
        player.restore(library.playback)
        player.onListeningProgress = { [weak library, weak player] track, session, started, seconds in
            guard let library, library.recordListening(track: track, sessionID: session, startedAt: started, seconds: seconds) else { return false }
            if player?.currentTrack?.id == track.id {
                library.recordRecent(track: track, position: player?.position ?? 0)
            }
            return true
        }
        player.onSnapshotChanged = { [weak self, weak library] snapshot in
            // Lifecycle checkpoints and restore's retirement flush cannot make a failed-startup placeholder durable.
            if self?.needsInitialPlaybackRestore == true {
                guard !snapshot.queue.isEmpty || snapshot.position != 0
                        || snapshot.shuffleEnabled || snapshot.repeatMode != .off else { return }
                self?.needsInitialPlaybackRestore = false
            }
            library?.updatePlayback(snapshot)
        }
        player.onTrackStarted = { [weak library, weak player] track in
            library?.recordRecent(track: track, position: player?.position ?? 0)
        }
        player.onQueueExhausted = { [weak self] track in
            await self?.autoplayTracks(after: track) ?? []
        }
        library.onHistoryCleared = { [weak self] in
            guard let self else { return }
            self.player.discardPendingListening()
            self.retirePersonalization()
            self.hasListeningProfile = false
            self.homeSections.removeAll { $0.id.hasPrefix("personal.") }
        }
    }

    isolated deinit {
        mixesTask?.cancel()
        radioSelectionTask?.cancel()
        radioRetryTask?.cancel()
    }

    // MARK: Preferences

    /// Single entry point for preference edits so dependent services see the change at once.
    func updatePreferences(_ change: (inout UserPreferences) -> Void) {
        var preferences = library.preferences
        let previous = preferences
        change(&preferences)
        guard preferences != previous else { return }
        if preferences.crossfadeSeconds != previous.crossfadeSeconds || preferences.saveListeningHistory != previous.saveListeningHistory {
            player.flushListeningProgress()
        }
        library.preferences = preferences
        let applied = library.preferences
        if previous.saveListeningHistory, !applied.saveListeningHistory {
            player.discardPendingListening()
        }
        if applied.languages != previous.languages { retirePersonalization() }
        applyPreferenceServices(applied, replacing: previous)
    }

    private func applyPreferenceServices(_ applied: UserPreferences, replacing previous: UserPreferences) {
        if applied.audioCacheLimit != previous.audioCacheLimit {
            player.setAudioCacheLimit(applied.audioCacheLimit)
        }
        if applied.languages != previous.languages, radioRequestUsesPreferences, isLoadingRadio || radioError != nil { cancelPendingRadio() }
        if PlaybackTransitionSettings(applied) != PlaybackTransitionSettings(previous) {
            player.apply(PlaybackTransitionSettings(applied))
        }
        if applied.allowRemoteFallback != previous.allowRemoteFallback {
            player.setRemoteFallbackEnabled(applied.allowRemoteFallback)
        }
        if applied.useEncryptedDNS != previous.useEncryptedDNS {
            LyricsDNSConfiguration.configure(enabled: applied.useEncryptedDNS)
        }
    }

    // MARK: Library recovery

    /// Reload runs outside listening callbacks so privacy boundaries retire captured deltas before retries.
    @discardableResult
    func reloadSavedLibrary() -> LibraryReloadResult {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        let previous = library.preferences
        let result = library.reloadFromDisk()
        guard result != .failed else {
            showToast(library.errorMessage ?? "Your saved library couldn’t be reloaded.")
            return result
        }

        retirePersonalization()
        homeGeneration = UUID()
        isLoadingHome = false
        homeError = nil
        loadedLanguages = nil
        loadedAt = nil
        let applied = library.preferences
        homeSections = withoutDisliked(homeSections.filter {
            !$0.id.hasPrefix("personal.") && ($0.language.map(applied.languages.contains) ?? true)
        })
        charts.removeAll { !applied.languages.contains($0.language) }
        if isLoadingRadio || radioError != nil { cancelPendingRadio() }
        applyPreferenceServices(applied, replacing: previous)

        // An untouched failed-startup placeholder has no live resume state to take precedence over the saved queue.
        if needsInitialPlaybackRestore {
            player.restore(library.playback)
            needsInitialPlaybackRestore = false
        }
        player.flushListeningProgress()
        hasListeningProfile = !tasteProfile().isColdStart
        showToast(library.errorMessage ?? "Saved library reloaded.")
        return result
    }

    // MARK: Home

    func loadHome(force: Bool = false) async {
        let languages = library.preferences.languages
        refreshMixes()
        Task { await checkForNewReleases() }
        if !force, !isLoadingHome, !homeSections.isEmpty, loadedLanguages == languages,
           let loadedAt, Date().timeIntervalSince(loadedAt) < 900 {
            homeGeneration = UUID()
            return
        }
        let generation = UUID()
        homeGeneration = generation
        isLoadingHome = true
        homeError = nil
        charts.removeAll { !languages.contains($0.language) }
        homeSections.removeAll { $0.language.map { !languages.contains($0) } ?? false }
        defer { if generation == homeGeneration { isLoadingHome = false } }

        let provider = catalog
        let chartProvider = chartProvider
        let engine = engine
        let profile = tasteProfile()
        hasListeningProfile = !profile.isColdStart
        let personalGeneration = personalizationGeneration
        if profile.isColdStart { homeSections.removeAll { $0.id.hasPrefix("personal.") } }
        var discoveryFailure: String?
        var discoverySucceeded = false

        await withTaskGroup(of: HomeUpdate.self) { group in
            group.addTask {
                do { return .sections(try await provider.discovery(languages: languages)) }
                catch { return .discoveryFailure(error.localizedDescription) }
            }
            for language in MusicLanguage.allCases where languages.contains(language) {
                group.addTask {
                    do { return .chart(try await chartProvider.weeklyChart(language: language)) }
                    catch { return .chartFailure }
                }
            }
            if !profile.isColdStart {
                group.addTask {
                    do { return .personal(try await engine.becauseYouListen(profile: profile, languages: languages)) }
                    catch { return .chartFailure }
                }
            }
            for await update in group {
                guard generation == homeGeneration, languages == library.preferences.languages,
                      !Task.isCancelled else { group.cancelAll(); return }
                switch update {
                case .sections(let incoming):
                    let sections = incoming.filter { !Self.excludedHomeShelfIDs.contains($0.id) }
                    let personal = homeSections.filter { $0.id.hasPrefix("personal.") }
                    homeSections = personal + withoutDisliked(sections)
                    discoverySucceeded = !sections.isEmpty
                    if player.currentTrack == nil { player.prefetch(sections.flatMap(\.tracks)) }
                case .personal(let sections):
                    guard personalGeneration == personalizationGeneration else { continue }
                    homeSections.removeAll { $0.id.hasPrefix("personal.") }
                    let preferred = withoutDisliked(sections).filter { !$0.tracks.isEmpty && ($0.language.map(languages.contains) ?? true) }
                    homeSections.insert(contentsOf: preferred, at: 0)
                case .chart(let chart):
                    charts.removeAll { $0.language == chart.language }
                    charts.append(chart)
                    charts.sort { $0.language.rawValue > $1.language.rawValue }
                case .discoveryFailure(let message): discoveryFailure = message
                case .chartFailure: log.info("optionalChartOrRadioUnavailable=1")
                }
            }
        }
        guard generation == homeGeneration, languages == library.preferences.languages, !Task.isCancelled else { return }
        if let discoveryFailure { homeError = discoveryFailure }
        if discoverySucceeded {
            loadedLanguages = languages
            loadedAt = Date()
        }
    }

    // MARK: Mixes

    var discoverWeekly: GeneratedPlaylist? { library.mix(.discoverWeekly) }
    var dailyMix: GeneratedPlaylist? { library.mix(.dailyMix) }

    /// Regenerates each mix whose period has rolled over; a mix from the current period is never replaced.
    @discardableResult
    func refreshMixes() -> Task<Void, Never>? {
        guard generatesMixes, library.preferences.saveListeningHistory || !library.mixes.isEmpty else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let weekKey = RecommendationEngine.weekKey(for: now, calendar: calendar)
        let dayKey = RecommendationEngine.dayKey(for: now, calendar: calendar)
        let needsWeekly = library.mix(.discoverWeekly)?.periodKey != weekKey
        let needsDaily = library.mix(.dailyMix)?.periodKey != dayKey
        guard needsWeekly || needsDaily else { return nil }
        if let mixesTask { return mixesTask }
        let profile = tasteProfile()
        hasListeningProfile = !profile.isColdStart
        guard !profile.isColdStart else { return nil }
        let languages = library.preferences.languages
        let engine = engine
        let generation = personalizationGeneration
        let periods: [(GeneratedPlaylistKind, String)] = [(.discoverWeekly, weekKey), (.dailyMix, dayKey)]
        isGeneratingMixes = true
        mixesTask = Task { @MainActor [weak self] in
            defer {
                if self?.personalizationGeneration == generation {
                    self?.mixesTask = nil
                    self?.isGeneratingMixes = false
                }
            }
            for (kind, periodKey) in periods {
                guard !Task.isCancelled, self?.personalizationGeneration == generation,
                      self?.library.preferences.languages == languages else { return }
                guard self?.library.mix(kind)?.periodKey != periodKey else { continue }
                let generated: GeneratedPlaylist?
                switch kind {
                case .discoverWeekly:
                    generated = try? await engine.discoverWeekly(profile: profile, languages: languages, periodKey: periodKey)
                case .dailyMix:
                    generated = try? await engine.dailyMix(profile: profile, languages: languages, periodKey: periodKey)
                }
                guard !Task.isCancelled, let self, self.personalizationGeneration == generation,
                      self.library.preferences.languages == languages else { return }
                guard var mix = generated, self.library.mix(kind)?.periodKey != periodKey else { continue }
                let disliked = self.library.dislikedTrackIDs
                mix.tracks.removeAll { disliked.contains($0.id) }
                self.library.saveMix(mix)
            }
        }
        return mixesTask
    }

    private func retirePersonalization() {
        personalizationGeneration = UUID()
        mixesTask?.cancel()
        mixesTask = nil
        isGeneratingMixes = false
    }

    private func tasteProfile() -> TasteProfile {
        TasteProfile.build(events: library.events, favorites: library.favorites, playlists: library.playlists,
                           recents: library.recentlyPlayed, disliked: library.disliked, now: Date())
    }

    // MARK: Navigation

    /// RootView sends user tab taps here, including a reselect of the current tab.
    func selectTab(_ tab: AppTab) {
        cancelPendingArtistLookup()
        let isReselection = selectedTab == tab
        selectedTab = tab
        guard tab == .search else { return }
        navigationPaths[.search] = []
        if isReselection { searchFocusRequest += 1 }
        else { dismissSearchKeyboard() }
    }

    /// Opens a collection page on the current tab, closing the player first so the page is visible.
    func open(_ collection: MusicCollection) {
        finishSearchResultInteraction(collectionID: collection.id)
        isPlayerPresented = false
        isSettingsPresented = false
        var path = navigationPaths[selectedTab] ?? []
        if path.last?.id != collection.id { path.append(collection) }
        navigationPaths[selectedTab] = path
    }

    func navigationPath(for tab: AppTab) -> Binding<[MusicCollection]> {
        Binding { [weak self] in self?.navigationPaths[tab] ?? [] } set: { [weak self] value in
            self?.navigationPaths[tab] = value
            if tab == .search, !value.isEmpty { self?.dismissSearchKeyboard() }
        }
    }

    /// Opens an artist's page. Credits parsed from a title carry no id, so those are looked up by name first;
    /// when no artist page matches closely enough, search shows what the catalog has.
    func openArtist(_ credit: ArtistCredit) async {
        guard !Task.isCancelled else { return }
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        if let page = credit.collection {
            open(page)
            return
        }
        let name = credit.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let generation = artistLookupGeneration
        let originTab = selectedTab
        isArtistLookupPending = true
        defer { if artistLookupGeneration == generation { isArtistLookupPending = false } }
        var match: MusicCollection?
        do {
            let page = try await catalog.search(query: name, filter: .artists, continuation: nil)
            match = SearchRelevance.matchedArtist(in: page.collections, query: name, correctedQuery: page.correctedQuery)
        } catch { }
        guard artistLookupGeneration == generation, selectedTab == originTab, !Task.isCancelled else { return }
        if let match { open(match) }
        else { openSearch(name) }
    }

    /// View-local destinations and sheets can supersede a lookup without changing a model binding.
    func cancelPendingArtistLookup() {
        artistLookupGeneration = UUID()
        isArtistLookupPending = false
    }

    // MARK: Taste

    /// Disliking skips the song when it is playing; the choice also removes it from mixes and future autoplay.
    func toggleDislike(_ track: Track) {
        let wasDisliked = library.isDisliked(track)
        library.toggleDislike(track)
        guard !wasDisliked, library.isDisliked(track) else {
            if wasDisliked { showToast("Removed from disliked songs") }
            return
        }
        homeSections = homeSections.map { section in
            var section = section
            section.tracks.removeAll { $0.id == track.id }
            return section
        }
        if player.isRadioSession {
            for index in player.queue.indices.reversed() where index != player.currentIndex {
                if ExperienceRadioEngine.isDisliked(player.queue[index], disliked: library.disliked) {
                    player.removeFromQueue(at: index)
                }
            }
        }
        if player.currentTrack?.id == track.id, player.queue.count > 1 || player.isRadioSession, player.isPlaying || player.isLoading {
            player.next()
        }
        showToast("You won’t hear \(track.title) in mixes or autoplay.")
    }

    // MARK: Following

    func isFollowing(_ artist: MusicCollection) -> Bool {
        artist.kind == .artist && library.isFollowing(artistID: artist.id)
    }

    func isFollowPending(_ artist: MusicCollection) -> Bool { followTasks.contains(artist.id) }

    /// Follows or unfollows; following records the artist's current releases as the baseline so only later
    /// releases are announced, and asks for notification permission the first time when alerts are on.
    func toggleFollow(_ artist: MusicCollection) async {
        guard artist.kind == .artist, !followTasks.contains(artist.id) else { return }
        if library.isFollowing(artistID: artist.id) {
            library.unfollow(artistID: artist.id)
            showToast("Unfollowed \(artist.title)")
            return
        }
        followTasks.insert(artist.id)
        defer { followTasks.remove(artist.id) }
        var followed = FollowedArtist(id: artist.id, name: artist.title, artworkURL: artist.artworkURL)
        if let page = try? await catalog.artist(id: artist.id) {
            followed.knownReleaseIDs = page.releases.map(\.id)
            followed.hasEstablishedReleaseBaseline = true
            followed.lastCheckedAt = Date()
            if followed.artworkURL == nil { followed.artworkURL = page.artworkURL }
        }
        library.follow(followed)
        guard library.isFollowing(artistID: artist.id) else { return }
        if library.preferences.newReleaseAlerts {
            let granted = await releases.requestAlertsAuthorization()
            showToast(granted ? "Following \(artist.title). You’ll hear about new releases."
                              : "Following \(artist.title). Turn on notifications in Settings for release alerts.")
        } else {
            showToast("Following \(artist.title)")
        }
    }

    /// Foreground and background refresh entry point for release checks.
    func checkForNewReleases(force: Bool = false) async -> Int {
        releaseChecksInFlight += 1
        defer { releaseChecksInFlight -= 1 }
        return await releases.checkNow(force: force)
    }

    // MARK: Search

    func consumeSearchFocusRequest(_ request: Int) -> Bool {
        guard request > consumedSearchFocusRequest, request == searchFocusRequest,
              selectedTab == .search, navigationPaths[.search, default: []].isEmpty,
              !isPlayerPresented, !isSettingsPresented else { return false }
        consumedSearchFocusRequest = request
        return true
    }

    func dismissSearchKeyboard() {
        consumedSearchFocusRequest = searchFocusRequest
        searchFocusDismissal += 1
    }

    func commitSearch() {
        cancelPendingArtistLookup()
        library.recordSearch(searchQuery)
    }

    private func finishSearchResultInteraction(trackID: String? = nil, collectionID: String? = nil) {
        cancelPendingArtistLookup()
        let selectedResult = trackID.map { id in searchPage.tracks.contains { $0.id == id } } ?? false
        let selectedCollection = collectionID.map { id in
            searchPage.collections.contains { $0.id == id } || searchPage.featuredArtist?.id == id
        } ?? false
        if selectedTab == .search, navigationPaths[.search, default: []].isEmpty,
           completedSearch == SearchIdentity(query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines), filter: searchFilter),
           selectedResult || selectedCollection { commitSearch() }
        dismissSearchKeyboard()
    }

    /// Explicit refreshes supersede artist navigation even when the search input is unchanged.
    func search() async {
        cancelPendingArtistLookup()
        await loadSearch()
    }

    /// Lifecycle and debounce work belongs to the existing input intent, which may precede an artist tap.
    func loadSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = searchFilter
        let generation = UUID()
        searchGeneration = generation
        searchError = nil
        searchPage = CatalogPage()
        completedSearch = nil
        hasSearched = false
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        defer { if searchGeneration == generation { isSearching = false } }
        do {
            let page = try await catalog.search(query: query, filter: filter, continuation: nil)
            try Task.checkCancellation()
            guard searchGeneration == generation, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter else { return }
            searchPage = page
            completedSearch = SearchIdentity(query: query, filter: filter)
            hasSearched = true
            if filter == .songs { player.prefetch(page.tracks) }
        } catch {
            guard searchGeneration == generation, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter, !Task.isCancelled else { return }
            hasSearched = true
            searchError = error.localizedDescription
        }
    }

    func loadMoreSearch() async {
        guard !isSearching, let continuation = searchPage.continuation else { return }
        let generation = searchGeneration
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = searchFilter
        guard completedSearch == SearchIdentity(query: query, filter: filter) else { return }
        isSearching = true
        searchError = nil
        defer { if searchGeneration == generation { isSearching = false } }
        do {
            let page = try await catalog.search(query: query, filter: filter, continuation: continuation)
            try Task.checkCancellation()
            guard generation == searchGeneration, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter else { return }
            var trackIDs = Set(searchPage.tracks.map(\.id))
            var collectionIDs = Set(searchPage.collections.map(\.id))
            searchPage.tracks += page.tracks.filter { trackIDs.insert($0.id).inserted }
            searchPage.collections += page.collections.filter { collectionIDs.insert($0.id).inserted }
            searchPage.continuation = page.continuation
        } catch {
            guard generation == searchGeneration, query == searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                  filter == searchFilter, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
    }

    // MARK: Playback

    func play(_ track: Track, in tracks: [Track] = []) {
        finishSearchResultInteraction(trackID: track.id)
        endRadioSession()
        let queue = tracks.isEmpty ? [track] : tracks
        if let index = queue.firstIndex(where: { $0.id == track.id }) { player.play(queue, startingAt: index) }
        else { player.play([track] + queue) }
    }

    func play(_ tracks: [Track], shuffle: Bool = false) {
        guard !tracks.isEmpty else { showToast("There are no songs in this mix yet."); return }
        finishSearchResultInteraction(trackID: tracks.first?.id)
        endRadioSession()
        if player.shuffleEnabled != shuffle { player.toggleShuffle() }
        player.play(tracks, startingAt: shuffle ? Int.random(in: tracks.indices) : 0)
    }

    /// Queue navigation keeps the current radio identity but supersedes any pending station tap.
    func playQueueTrack(at index: Int) {
        guard player.queue.indices.contains(index) else { return }
        cancelPendingArtistLookup()
        cancelPendingRadio()
        retireRadioContinuation()
        playbackIntentGeneration = UUID()
        dismissSearchKeyboard()
        let isRadio = player.isRadioSession
        if !isRadio { radioSession = nil }
        player.play(player.queue, startingAt: index, isRadio: isRadio)
    }

    // MARK: Experience radio

    var radioExperiences: [RadioExperience] {
        RadioExperience.discoveryStations.filter { $0.selection(for: library.preferences.languages) != nil }
    }

    var activeRadioExperience: RadioExperience? {
        player.isRadioSession ? radioSession?.experience : nil
    }

    var activeRadioContentLabel: String? {
        guard player.isRadioSession, let session = radioSession else { return nil }
        return session.experience.selection(for: session.languages)?.contentLabel
    }

    func isActiveRadio(_ experience: RadioExperience) -> Bool {
        guard player.isRadioSession, let session = radioSession, session.experience.stationID == experience.stationID else { return false }
        let base = RadioExperience.stations.first { $0.id == experience.stationID } ?? experience
        return base.selection(for: library.preferences.languages) == base.selection(for: session.languages)
    }

    var radioSessionLabel: String? {
        guard player.isRadioSession else { return nil }
        return activeRadioExperience?.radioTitle ?? "Radio"
    }

    @discardableResult
    func startRadio(_ experience: RadioExperience, languages selectedLanguages: Set<MusicLanguage>? = nil) -> Task<Void, Never> {
        needsInitialPlaybackRestore = false
        cancelPendingArtistLookup()
        cancelPendingRadio()
        dismissSearchKeyboard()
        let generation = UUID()
        radioSelectionGeneration = generation
        selectedRadioExperience = experience
        isLoadingRadio = true
        radioError = nil
        let engine = experienceRadio
        let disliked = library.disliked
        let preferencesAtStart = library.preferences.languages
        let languages = selectedLanguages ?? preferencesAtStart
        let usesPreferences = selectedLanguages == nil
        radioRequestLanguages = languages
        radioRequestUsesPreferences = usesPreferences
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.radioSelectionGeneration == generation {
                    self?.isLoadingRadio = false
                    self?.radioSelectionTask = nil
                }
            }
            do {
                let batch = try await engine.start(experience, disliked: disliked, languages: languages)
                try Task.checkCancellation()
                guard let self, self.radioSelectionGeneration == generation,
                      !usesPreferences || self.library.preferences.languages == preferencesAtStart else { return }
                let currentDislikes = self.library.disliked
                let tracks = ExperienceRadioEngine.selection(buckets: [batch.tracks], disliked: currentDislikes, languages: languages).tracks
                let trackIDs = Set(tracks.map(\.id))
                let buckets = batch.buckets.filter { trackIDs.contains($0.anchor.id) }
                guard tracks.count >= ExperienceRadioEngine.minimumQueueSize, !buckets.isEmpty,
                      !trackIDs.isDisjoint(with: batch.discoveryTrackIDs) else {
                    throw ExperienceRadioError.tooFewSongs
                }
                self.retireRadioContinuation()
                self.playbackIntentGeneration = UUID()
                self.radioSession = RadioSession(experience: experience, buckets: buckets, languages: languages,
                                                 usesDiscoveryPreferences: usesPreferences)
                if self.player.shuffleEnabled { self.player.toggleShuffle() }
                self.player.play(tracks, isRadio: true)
            } catch {
                guard let self, self.radioSelectionGeneration == generation,
                      !usesPreferences || self.library.preferences.languages == preferencesAtStart, !Task.isCancelled else { return }
                self.radioError = error.localizedDescription
            }
        }
        radioSelectionTask = task
        return task
    }

    func cancelPendingRadio() {
        radioSelectionGeneration = UUID()
        radioSelectionTask?.cancel()
        radioSelectionTask = nil
        isLoadingRadio = false
        radioError = nil
        selectedRadioExperience = activeRadioExperience
        radioRequestLanguages = player.isRadioSession ? radioSession?.languages : nil
        radioRequestUsesPreferences = player.isRadioSession ? radioSession?.usesDiscoveryPreferences ?? true : true
    }

    func retryRadio() {
        if let experience = selectedRadioExperience {
            startRadio(experience, languages: radioRequestUsesPreferences ? nil : radioRequestLanguages)
        }
    }

    func retryRadioContinuation() {
        guard player.isRadioSession, let session = radioSession, let track = player.currentTrack,
              !isContinuingRadio else { return }
        radioRetryTask?.cancel()
        let intent = playbackIntentGeneration
        radioRetryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.playbackIntentGeneration == intent,
                  self.player.isRadioSession, self.radioSession?.id == session.id else { return }
            let tracks = await self.continueRadio(after: track, session: session, forceRefresh: true)
            guard !Task.isCancelled, self.player.isRadioSession, self.radioSession?.id == session.id,
                  self.playbackIntentGeneration == intent else { return }
            self.player.appendAutoplay(tracks)
        }
    }

    private func endRadioSession() {
        cancelPendingRadio()
        retireRadioContinuation()
        playbackIntentGeneration = UUID()
        radioSession = nil
        selectedRadioExperience = nil
        radioRequestLanguages = nil
        radioRequestUsesPreferences = true
    }

    private func retireRadioContinuation() {
        radioContinuationGeneration = UUID()
        radioRetryTask?.cancel()
        radioRetryTask = nil
        isContinuingRadio = false
        radioContinuationError = nil
    }

    private func continueRadio(after track: Track, session: RadioSession, forceRefresh: Bool = false) async -> [Track] {
        guard !Task.isCancelled, player.isRadioSession, radioSession?.id == session.id else { return [] }
        let generation = UUID()
        radioContinuationGeneration = generation
        let intent = playbackIntentGeneration
        isContinuingRadio = true
        radioContinuationError = nil
        defer { if radioContinuationGeneration == generation { isContinuingRadio = false } }
        do {
            let batch = try await experienceRadio.continueRadio(buckets: session.buckets, round: session.round,
                queue: player.queue + [track], disliked: library.disliked, languages: session.languages,
                experience: session.experience, forceRefresh: forceRefresh)
            try Task.checkCancellation()
            guard radioContinuationGeneration == generation, radioSession?.id == session.id,
                  playbackIntentGeneration == intent, player.isRadioSession else { return [] }
            let tracks = ExperienceRadioEngine.selection(buckets: [batch.tracks], excluding: player.queue + [track],
                                                          disliked: library.disliked, languages: session.languages).tracks
            guard !tracks.isEmpty else { throw ExperienceRadioError.unavailable }
            radioSession?.buckets = batch.buckets
            radioSession?.round += 1
            return tracks
        } catch {
            guard radioContinuationGeneration == generation, radioSession?.id == session.id,
                  playbackIntentGeneration == intent, player.isRadioSession, !Task.isCancelled else { return [] }
            radioContinuationError = error.localizedDescription
            return []
        }
    }

    private func withoutDisliked(_ sections: [DiscoverySection]) -> [DiscoverySection] {
        let disliked = library.dislikedTrackIDs
        guard !disliked.isEmpty else { return sections }
        return sections.map { section in
            var section = section
            section.tracks.removeAll { disliked.contains($0.id) }
            return section
        }
    }

    /// Autoplay continuation: the provider's radio for the song that is ending, minus anything queued or
    /// disliked and minus other versions of songs already in the queue, so a remix never follows its original.
    private func autoplayTracks(after track: Track) async -> [Track] {
        guard !Task.isCancelled else { return [] }
        if player.isRadioSession, let session = radioSession { return await continueRadio(after: track, session: session) }
        let intent = playbackIntentGeneration
        let isRadio = player.isRadioSession
        do {
            let radio = try await catalog.radio(seed: track)
            try Task.checkCancellation()
            guard playbackIntentGeneration == intent, player.isRadioSession == isRadio else { return [] }
            return Self.autoplaySelection(from: radio, queue: player.queue + [track], disliked: library.dislikedTrackIDs)
        } catch {
            log.info("autoplayUnavailable=1")
            return []
        }
    }

    static func autoplaySelection(from radio: [Track], queue: [Track], disliked: Set<String>, limit: Int = 20) -> [Track] {
        var excluded = Set(queue.map(\.id)).union(disliked)
        var titles = Set(queue.map { SongTitle.core($0.title) })
        return Array(radio.filter { candidate in
            guard !excluded.contains(candidate.id), candidate.isAudioRecording != false else { return false }
            let core = SongTitle.core(candidate.title)
            guard core.isEmpty || titles.insert(core).inserted else { return false }
            excluded.insert(candidate.id)
            return true
        }.prefix(max(0, limit)))
    }

    func showToast(_ text: String) {
        toast = text
        AppAccessibilityAnnouncements.post(text)
    }

    func openSearch(_ query: String) {
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        navigationPaths[.search] = []
        searchQuery = query
        searchFilter = .songs
        selectedTab = .search
        isPlayerPresented = false
        isSettingsPresented = false
    }

    private struct RadioSession {
        let id = UUID()
        let experience: RadioExperience
        var buckets: [ExperienceRadioEngine.Bucket]
        // Discovery preference edits apply to future station starts, not the listener's active selection.
        let languages: Set<MusicLanguage>
        let usesDiscoveryPreferences: Bool
        var round = 0
    }

    private enum HomeUpdate: Sendable {
        case sections([DiscoverySection]), personal([DiscoverySection]), chart(ChartSnapshot)
        case discoveryFailure(String), chartFailure
    }

    private struct SearchIdentity: Equatable {
        let query: String
        let filter: SearchFilter
    }
}
