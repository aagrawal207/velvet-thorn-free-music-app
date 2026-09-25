import Foundation
import Observation

@MainActor @Observable
final class ArtistSpotlightLoader {
    struct Configuration: Sendable {
        var automaticLanguageChecks = 12
        var languageBatchSize = 12
        var languageBatchTimeout: TimeInterval = 36
    }

    let artist: ArtistPage
    private var candidates: [Track] {
        didSet { cachedDisplay = nil }
    }
    private(set) var languages: [String: ArtistSongLanguageResult] = [:] {
        didSet { cachedDisplay = nil }
    }
    private var hints: [String: ArtistSongLanguageResult] = [:]
    private var library: LibraryStore?
    var filter: ArtistSpotlightFilter = .all
    var isBrowsingLanguages = false
    private(set) var isLoadingSongs = false
    private(set) var isCheckingLanguages = false
    private(set) var hadCatalogFailures = false
    private(set) var hasLoaded = false
    private(set) var reloadRequest = 0
    private var isPreparing = false

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let catalogConfiguration: ArtistSpotlightCatalogService.Configuration
    @ObservationIgnored private let maximumAdditionalTracks: Int
    @ObservationIgnored private var cachedDisplay: (overrides: [String: String], value: ArtistSpotlight.SongDisplay)?
    @ObservationIgnored private var languageService: ArtistSpotlightLanguageService?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var hasScheduledLanguageChecks = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var languageTask: Task<Void, Never>?
    @ObservationIgnored private var songLoadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(artist: ArtistPage, configuration: Configuration = Configuration(),
         catalogConfiguration: ArtistSpotlightCatalogService.Configuration = .init(),
         languageService: ArtistSpotlightLanguageService? = nil, library: LibraryStore? = nil) {
        self.artist = artist
        let initial = ArtistSpotlight.mergedTracks(artist.topSongs)
        candidates = initial
        maximumAdditionalTracks = max(0, catalogConfiguration.maximumAdditionalTracks)
        self.configuration = configuration
        self.catalogConfiguration = catalogConfiguration
        self.languageService = languageService
        self.library = library
        hints = Dictionary(uniqueKeysWithValues: initial.compactMap { track in
            ArtistSpotlightLanguageSignals.titleHint(track.title).map { (track.id, $0) }
        })
    }

    isolated deinit {
        loadTask?.cancel()
        languageTask?.cancel()
    }

    var collection: MusicCollection { ArtistSpotlight.collection(for: artist, tracks: tracks) }

    var tracks: [Track] { display.tracks }
    var listedTracks: [Track] { display.listedTracks }
    var featuredTracks: [Track] { display.featuredTracks }

    private var display: ArtistSpotlight.SongDisplay {
        // Observable reads remain necessary on cache hits so corrections and evidence refresh the visible rows.
        let source = candidates
        let checked = languages
        let corrections = overrides
        if let cachedDisplay, cachedDisplay.overrides == corrections { return cachedDisplay.value }
        var value = ArtistSpotlight.displaySongs(source, artist: artist, languages: checked, overrides: corrections,
                                                maximumAdditionalTracks: maximumAdditionalTracks)
        value.tracks = ArtistSpotlight.sorted(value.tracks)
        cachedDisplay = (corrections, value)
        return value
    }

    private var effectiveResults: [String: ArtistSongLanguageResult] {
        hints.merging(languages) { hint, checked in
            switch checked {
            case .unclassified(.lookupFailed), .unclassified(.noMatchedLyrics), .unclassified(.insufficientText), .unclassified(.uncertainLanguage): hint
            default: checked
            }
        }
    }
    private var overrides: [String: String] { library?.recordingLanguageOverrides ?? [:] }

    var visibleTracks: [Track] {
        let results = effectiveResults
        return tracks.filter { ArtistSpotlight.matches($0, filter: filter, languages: results, overrides: overrides) }
    }

    func languageResult(for track: Track) -> ArtistSongLanguageResult? {
        ArtistSpotlight.languageResult(for: track, in: effectiveResults, overrides: overrides)
    }

    var availableLanguages: [ArtistSongLanguage] {
        let results = effectiveResults
        let corrections = overrides
        let found = Set(tracks.compactMap { ArtistSpotlight.languageResult(for: $0, in: results, overrides: corrections)?.language })
        return ArtistSongLanguage.allCases.filter(found.contains)
    }

    var hasUsefulLanguageFacets: Bool { availableLanguages.count >= 2 }
    var languageControlTitle: String { hasUsefulLanguageFacets ? "Browse by language" : "Languages" }

    var filters: [ArtistSpotlightFilter] {
        var included = Set(availableLanguages)
        if case .language(let selected) = filter { included.insert(selected) }
        // An empty selected facet stays selected; asynchronous checks must not change the listener's queue scope.
        return [.all] + ArtistSongLanguage.allCases.filter(included.contains).map(ArtistSpotlightFilter.language)
            + (unclassifiedCount > 0 || filter == .unclassified ? [.unclassified] : [])
    }

    var unclassifiedCount: Int { count(for: .unclassified) }
    var missingPlayCounts: Int { tracks.filter { ArtistSpotlight.availableCount($0) == nil }.count }
    var checkedLanguageCount: Int { tracks.filter { !needsLanguageCheck($0) }.count }
    var hasInferredLanguages: Bool { tracks.contains { languageResult(for: $0)?.isInferred == true } }
    var hasLikelyLanguages: Bool { tracks.contains { languageResult(for: $0)?.isLikely == true } }
    var canCheckMoreLanguages: Bool { tracks.contains { needsLanguageCheck($0) } }
    var hasFailedLanguageChecks: Bool { tracks.contains { languages[$0.id] == .unclassified(.lookupFailed) } }
    var isBusy: Bool { isPreparing || isLoadingSongs || isCheckingLanguages }

    func count(for filter: ArtistSpotlightFilter) -> Int {
        let results = effectiveResults
        return tracks.filter { ArtistSpotlight.matches($0, filter: filter, languages: results, overrides: overrides) }.count
    }

    /// Try again from the song list. Its task keys on reloadRequest, so the bump re-runs load() once per tap;
    /// resetting here keeps later appearances from cancelling the shared load and refetching.
    func requestReload() {
        cancel()
        hasLoaded = false
        reloadRequest &+= 1
    }

    /// Starts the bounded catalog load once for the artist page. The loader owns the task, so pushing and
    /// popping the song list neither restarts nor cancels it; only cancel() and deinit do.
    func startLoadingSongs(catalog: any MusicCatalogProviding, library: LibraryStore? = nil) {
        if let library { self.library = library }
        guard !hasLoaded, loadTask == nil else { return }
        let request = generation
        let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: catalogConfiguration)
        let artist = self.artist
        isLoadingSongs = true
        hadCatalogFailures = false
        // Only momentary strong references: a popped artist page must release the loader so deinit can cancel this.
        loadTask = Task { [weak self] in
            do {
                let outcome = try await service.load(artist, onCandidates: { [weak self] candidates in
                    await self?.accept(candidates, request: request)
                }, onUpdate: { _ in })
                try Task.checkCancellation()
                self?.finishSongLoad(.success(outcome), request: request)
            } catch {
                // The transport maps URLError.cancelled to CancellationError; only this task's own cancellation
                // (cancel() or deinit already retired the load) may skip finishing, or waiters would hang.
                guard !Task.isCancelled else { return }
                self?.finishSongLoad(.failure(error), request: request)
            }
        }
    }

    /// Prepares the song list: joins or starts the song load and runs the automatic language batch once per
    /// preparation. `force` abandons the current preparation; the song list's Try again uses requestReload().
    func load(catalog: any MusicCatalogProviding, lyrics: any LyricsProviding, force: Bool = false, library: LibraryStore? = nil) async {
        if let library { self.library = library }
        guard force || !hasLoaded || !hasScheduledLanguageChecks else { return }
        if force {
            cancel()
            hasLoaded = false
        }
        let request = generation
        let service = languageService ?? ArtistSpotlightLanguageService(provider: lyrics, metadataLookup: { track in
            try await ArtistSpotlightMusicBrainz.shared?.language(for: track)
        })
        languageService = service
        isPreparing = true
        startLoadingSongs(catalog: catalog)
        if hasScheduledLanguageChecks {
            await awaitSongLoad()
        } else {
            hasScheduledLanguageChecks = true
            let pass = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await performLanguagePass(using: service, request: request)
            }
            languageTask = pass
            // Leaving the song list ends its language work; the shared song load keeps serving the artist page.
            await withTaskCancellationHandler {
                await pass.value
            } onCancel: {
                pass.cancel()
            }
            // A manual batch may have replaced the handle while the cancelled pass unwound; leave it in place.
            if request == generation, languageTask == pass { languageTask = nil }
        }
        if request == generation {
            isPreparing = false
            isCheckingLanguages = false
        }
    }

    func checkMoreLanguages(retryFailures: Bool = false) {
        guard !isBusy, let service = languageService else { return }
        if retryFailures { languages = languages.filter { $0.value != .unclassified(.lookupFailed) } }
        let request = generation
        isCheckingLanguages = true
        languageTask = Task { [weak self] in
            guard let self else { return }
            _ = await classifyBatch(using: service, limit: configuration.languageBatchSize, request: request)
            if request == generation { languageTask = nil }
        }
    }

    func cancel() {
        generation = UUID()
        loadTask?.cancel()
        languageTask?.cancel()
        loadTask = nil
        languageTask = nil
        hasScheduledLanguageChecks = false
        isPreparing = false
        isLoadingSongs = false
        isCheckingLanguages = false
        resumeSongLoadWaiters()
    }

    /// Stops lyrics and MusicBrainz lookups without touching the song load the artist page still displays.
    func cancelLanguageChecks() {
        languageTask?.cancel()
        languageTask = nil
        isPreparing = false
        isCheckingLanguages = false
    }

    private func finishSongLoad(_ result: Result<ArtistSpotlightCatalogService.Outcome, any Error>, request: UUID) {
        guard request == generation else { return }
        switch result {
        case .success(let outcome):
            accept(outcome.candidates, request: request)
            hadCatalogFailures = outcome.hadFailures
            hasLoaded = true
        case .failure:
            hadCatalogFailures = true
        }
        isLoadingSongs = false
        loadTask = nil
        resumeSongLoadWaiters()
    }

    private func performLanguagePass(using service: ArtistSpotlightLanguageService, request: UUID) async {
        var completed = false
        defer {
            // An interrupted pass runs again on the next visit; cancel() already reset the flag for a newer generation.
            if !completed, request == generation { hasScheduledLanguageChecks = false }
        }
        // Catalog selection settles before spending the recording-specific lookup budget on representatives.
        await awaitSongLoad()
        guard request == generation, !Task.isCancelled else { return }
        _ = await classifyBatch(using: service, limit: configuration.automaticLanguageChecks, request: request)
        completed = !Task.isCancelled
    }

    /// Waits for the in-flight song load without owning it: a cancelled caller stops waiting while the load
    /// continues. Task.value would ignore the caller's cancellation and keep the loader alive.
    private func awaitSongLoad() async {
        guard loadTask != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled || loadTask == nil {
                    continuation.resume()
                } else {
                    songLoadWaiters[id] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.songLoadWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    private func resumeSongLoadWaiters() {
        let waiters = Array(songLoadWaiters.values)
        songLoadWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    private func accept(_ updated: [Track], request: UUID) {
        guard request == generation, !Task.isCancelled else { return }
        let previous = Dictionary(uniqueKeysWithValues: candidates.filter { languages[$0.id] != nil }
            .map { ($0.id, LyricsMatcher.RecordingKey($0)) })
        languages = languages.filter { id, _ in
            updated.contains { $0.id == id && previous[id] == LyricsMatcher.RecordingKey($0) }
        }
        let oldTitles = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.title) })
        hints = Dictionary(uniqueKeysWithValues: updated.compactMap { track in
            let hint = oldTitles[track.id] == track.title ? hints[track.id] : ArtistSpotlightLanguageSignals.titleHint(track.title)
            return hint.map { (track.id, $0) }
        })
        candidates = updated
    }

    private func classifyBatch(using service: ArtistSpotlightLanguageService, limit: Int, request: UUID) async -> Int {
        guard request == generation, !Task.isCancelled else { return 0 }
        let pending = Array(tracks.filter { needsLanguageCheck($0) }.prefix(min(2, max(0, limit))))
        if !pending.isEmpty { isCheckingLanguages = true }
        defer {
            if request == generation, !isPreparing { isCheckingLanguages = false }
        }
        guard !pending.isEmpty else { return 0 }
        let deadline = Date().addingTimeInterval(configuration.languageBatchTimeout)
        var started = 0
        var attempted = Set<String>()
        do {
            try await withThrowingTaskGroup(of: (Track, ArtistSongLanguageResult).self) { group in
                for track in pending {
                    started += 1
                    attempted.insert(track.id)
                    group.addTask { (track, try await Self.classify(track, using: service, deadline: deadline)) }
                }
                while let (track, result) = try await group.next() {
                    try Task.checkCancellation()
                    guard request == generation else { group.cancelAll(); return }
                    if candidates.contains(where: { $0.id == track.id && LyricsMatcher.RecordingKey($0) == LyricsMatcher.RecordingKey(track) }) {
                        languages[track.id] = result
                    }
                    if started < limit, Date() < deadline,
                       let next = tracks.first(where: { !attempted.contains($0.id) && needsLanguageCheck($0) }) {
                        started += 1
                        attempted.insert(next.id)
                        group.addTask { (next, try await Self.classify(next, using: service, deadline: deadline)) }
                    }
                }
            }
        } catch { }
        return started
    }

    private nonisolated static func classify(_ track: Track, using service: ArtistSpotlightLanguageService,
                                            deadline: Date) async throws -> ArtistSongLanguageResult {
        do {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .unclassified(.lookupFailed) }
            let result = try await PlaybackDeadline.run(seconds: remaining) { try await service.classification(for: track) }
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .unclassified(.lookupFailed)
        }
    }

    private func needsLanguageCheck(_ track: Track) -> Bool {
        overrides[track.id] == nil && ArtistSongLanguageResult.recordingMetadata(track) == nil && languages[track.id] == nil
    }
}
