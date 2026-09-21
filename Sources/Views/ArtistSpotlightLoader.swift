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
    private(set) var tracks: [Track]
    private(set) var languages: [String: ArtistSongLanguageResult] = [:]
    private var hints: [String: ArtistSongLanguageResult] = [:]
    private var library: LibraryStore?
    var filter: ArtistSpotlightFilter = .all
    private(set) var isLoadingSongs = false
    private(set) var isCheckingLanguages = false
    private(set) var hadCatalogFailures = false
    private(set) var hasLoaded = false
    private(set) var reloadRequest = 0
    private var isPreparing = false

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let catalogConfiguration: ArtistSpotlightCatalogService.Configuration
    @ObservationIgnored private var languageService: ArtistSpotlightLanguageService?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var languageTask: Task<Void, Never>?

    init(artist: ArtistPage, configuration: Configuration = Configuration(),
         catalogConfiguration: ArtistSpotlightCatalogService.Configuration = .init(),
         languageService: ArtistSpotlightLanguageService? = nil, library: LibraryStore? = nil) {
        self.artist = artist
        tracks = ArtistSpotlight.sorted(artist.topSongs)
        self.configuration = configuration
        self.catalogConfiguration = catalogConfiguration
        self.languageService = languageService
        self.library = library
        hints = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            ArtistSpotlightLanguageSignals.titleHint(track.title).map { (track.id, $0) }
        })
    }

    isolated deinit {
        loadTask?.cancel()
        languageTask?.cancel()
    }

    var collection: MusicCollection { ArtistSpotlight.collection(for: artist, tracks: tracks) }

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

    func overridesChanged() { keepAvailableFilter() }

    var availableLanguages: [ArtistSongLanguage] {
        let found = Set(tracks.compactMap { languageResult(for: $0)?.language })
        return ArtistSongLanguage.allCases.filter(found.contains)
    }

    var filters: [ArtistSpotlightFilter] {
        [.all] + availableLanguages.map(ArtistSpotlightFilter.language) + (unclassifiedCount > 0 ? [.unclassified] : [])
    }

    var unclassifiedCount: Int { count(for: .unclassified) }
    var missingPlayCounts: Int { tracks.filter { ArtistSpotlight.availableCount($0) == nil }.count }
    var checkedLanguageCount: Int { tracks.filter { !needsLanguageCheck($0) }.count }
    var hasInferredLanguages: Bool { tracks.contains { languageResult(for: $0)?.isInferred == true } }
    var hasLikelyLanguages: Bool { tracks.contains { languageResult(for: $0)?.isLikely == true } }
    var canCheckMoreLanguages: Bool { tracks.contains { needsLanguageCheck($0) } }
    var hasFailedLanguageChecks: Bool { languages.values.contains(.unclassified(.lookupFailed)) }
    var isBusy: Bool { isPreparing || isLoadingSongs || isCheckingLanguages }

    func count(for filter: ArtistSpotlightFilter) -> Int {
        let results = effectiveResults
        return tracks.filter { ArtistSpotlight.matches($0, filter: filter, languages: results, overrides: overrides) }.count
    }

    func requestReload() { reloadRequest &+= 1 }

    func load(catalog: any MusicCatalogProviding, lyrics: any LyricsProviding, force: Bool = false, library: LibraryStore? = nil) async {
        if let library { self.library = library }
        guard !hasLoaded || force else { return }
        cancel()
        let request = generation
        let service = languageService ?? ArtistSpotlightLanguageService(provider: lyrics, metadataLookup: { track in
            try await ArtistSpotlightMusicBrainz.shared?.language(for: track)
        })
        languageService = service
        isPreparing = true
        isLoadingSongs = true
        hadCatalogFailures = false
        let work = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await performLoad(catalog: catalog, languageService: service, request: request)
        }
        loadTask = work
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if request == generation {
            loadTask = nil
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
        isPreparing = false
        isLoadingSongs = false
        isCheckingLanguages = false
    }

    private func performLoad(catalog: any MusicCatalogProviding, languageService: ArtistSpotlightLanguageService,
                             request: UUID) async {
        defer {
            if request == generation { isLoadingSongs = false }
        }
        let originalIDs = Set(tracks.map(\.id))
        async let firstChecks = classifyBatch(using: languageService, limit: configuration.automaticLanguageChecks, request: request)
        do {
            let service = ArtistSpotlightCatalogService(catalog: catalog, configuration: catalogConfiguration)
            let outcome = try await service.load(artist) { [weak self] tracks in
                await self?.accept(tracks, request: request)
            }
            try Task.checkCancellation()
            guard request == generation else { return }
            accept(outcome.tracks, request: request)
            hadCatalogFailures = outcome.hadFailures
            hasLoaded = true
            isLoadingSongs = false
        } catch {
            guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            hadCatalogFailures = true
        }
        let checked = await firstChecks
        guard request == generation, !Task.isCancelled else { return }
        let remaining = max(0, configuration.automaticLanguageChecks - checked)
        if remaining > 0 {
            _ = await classifyBatch(using: languageService, limit: remaining, request: request, excluding: originalIDs)
        }
    }

    private func accept(_ updated: [Track], request: UUID) {
        guard request == generation, !Task.isCancelled else { return }
        let previous = Dictionary(uniqueKeysWithValues: tracks.filter { languages[$0.id] != nil }
            .map { ($0.id, LyricsMatcher.RecordingKey($0)) })
        languages = languages.filter { id, _ in
            updated.contains { $0.id == id && previous[id] == LyricsMatcher.RecordingKey($0) }
        }
        let oldTitles = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.title) })
        hints = Dictionary(uniqueKeysWithValues: updated.compactMap { track in
            let hint = oldTitles[track.id] == track.title ? hints[track.id] : ArtistSpotlightLanguageSignals.titleHint(track.title)
            return hint.map { (track.id, $0) }
        })
        tracks = updated
        keepAvailableFilter()
    }

    private func classifyBatch(using service: ArtistSpotlightLanguageService, limit: Int, request: UUID,
                               excluding: Set<String> = []) async -> Int {
        guard request == generation, !Task.isCancelled else { return 0 }
        let pending = Array(tracks.filter { !excluding.contains($0.id) && needsLanguageCheck($0) }.prefix(max(0, limit)))
        if !pending.isEmpty { isCheckingLanguages = true }
        defer {
            if request == generation, !isPreparing { isCheckingLanguages = false }
        }
        guard !pending.isEmpty else { return 0 }
        let deadline = Date().addingTimeInterval(configuration.languageBatchTimeout)
        var started = 0
        do {
            try await withThrowingTaskGroup(of: (Track, ArtistSongLanguageResult).self) { group in
                var next = min(2, pending.count)
                for index in 0..<next {
                    started += 1
                    group.addTask { (pending[index], try await Self.classify(pending[index], using: service, deadline: deadline)) }
                }
                while let (track, result) = try await group.next() {
                    try Task.checkCancellation()
                    guard request == generation else { group.cancelAll(); return }
                    if tracks.contains(where: { $0.id == track.id && LyricsMatcher.RecordingKey($0) == LyricsMatcher.RecordingKey(track) }) {
                        languages[track.id] = result
                        keepAvailableFilter()
                    }
                    while next < pending.count, !needsLanguageCheck(pending[next]) { next += 1 }
                    if next < pending.count, Date() < deadline {
                        let index = next
                        next += 1
                        started += 1
                        group.addTask { (pending[index], try await Self.classify(pending[index], using: service, deadline: deadline)) }
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

    private func keepAvailableFilter() {
        if !filters.contains(filter) { filter = .all }
    }
}
