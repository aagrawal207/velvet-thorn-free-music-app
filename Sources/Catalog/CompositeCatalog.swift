import Foundation
import OSLog

/// Routes catalog calls by id prefix and fans searches out to every enabled source. YouTube Music stays the primary
/// catalog: it cannot be disabled, its results lead, and its continuation drives pagination.
actor CompositeCatalog: MusicCatalogProviding, LyricsProviding, AlbumDescriptionProviding {
    /// Extra wait the secondary sources may add on top of the primary search.
    static let defaultSecondarySearchDeadline: TimeInterval = 6
    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "Catalog")

    let youTube: any MusicCatalogProviding
    private let secondary: [MusicSource: any MusicCatalogProviding]
    private let secondarySearchDeadline: TimeInterval
    private var enabledSources: Set<MusicSource>

    init(youTube: any MusicCatalogProviding, secondary: [MusicSource: any MusicCatalogProviding],
         enabledSources: [MusicSource] = MusicSource.allCases,
         secondarySearchDeadline: TimeInterval = CompositeCatalog.defaultSecondarySearchDeadline) {
        self.youTube = youTube
        self.secondary = secondary.filter { $0.key != .youTubeMusic }
        self.secondarySearchDeadline = secondarySearchDeadline.isFinite ? max(0.05, secondarySearchDeadline) : Self.defaultSecondarySearchDeadline
        self.enabledSources = Set(enabledSources)
    }

    /// Fan-out is opt-in per call: internal name lookups (artist matching, radio seeds, spotlight counts) must keep
    /// one provider so mixed play-count units and duplicate recordings never enter a single-source page.
    @TaskLocal static var searchesAllSources = false

    /// Inherits the caller's isolation so a main-actor caller can pass a main-actor closure.
    static func searchingAllSources<Value: Sendable>(isolation: isolated (any Actor)? = #isolation,
                                                     _ body: () async throws -> Value) async rethrows -> Value {
        try await $searchesAllSources.withValue(true) { try await body() }
    }

    /// Mirrors `UserPreferences.enabledCatalogSources`; YouTube's absence from the list is ignored.
    func setEnabledSources(_ sources: [MusicSource]) {
        enabledSources = Set(sources)
    }

    /// Sources a search asks, in display order; YouTube first.
    var activeSources: [MusicSource] {
        [.youTubeMusic] + MusicSource.allCases.filter { $0 != .youTubeMusic && enabledSources.contains($0) && secondary[$0] != nil }
    }

    private func provider(for id: String) -> any MusicCatalogProviding {
        let source = MusicSource.source(of: id)
        return source == .youTubeMusic ? youTube : (secondary[source] ?? EmptyCatalog())
    }

    // MARK: MusicCatalogProviding

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try Task.checkCancellation()
        let sources = activeSources
        // Continuations belong to the primary; a disabled or absent extra source means a plain pass-through.
        guard continuation == nil, Self.searchesAllSources, sources.count > 1 else {
            return try await youTube.search(query: query, filter: filter, continuation: continuation)
        }
        let deadline = secondarySearchDeadline
        let providers = secondary
        return try await withThrowingTaskGroup(of: (MusicSource, Result<CatalogPage, any Error>).self) { group in
            group.addTask { [youTube] in
                await (.youTubeMusic, Self.outcome { try await youTube.search(query: query, filter: filter, continuation: nil) })
            }
            for source in sources where source != .youTubeMusic {
                guard let provider = providers[source] else { continue }
                group.addTask {
                    await (source, Self.outcome {
                        try await PlaybackDeadline.run(seconds: deadline) { try await provider.search(query: query, filter: filter, continuation: nil) }
                    })
                }
            }
            var pages: [MusicSource: CatalogPage] = [:]
            var failures: [MusicSource: any Error] = [:]
            for try await (source, result) in group {
                switch result {
                case .success(let page): pages[source] = page
                case .failure(let error):
                    if error is CancellationError { throw error }
                    failures[source] = error
                }
            }
            try Task.checkCancellation()
            Self.logger.debug("event=composite_search sources=\(sources.count) ok=\(pages.count) failed=\(failures.count)")
            guard !pages.isEmpty else { throw failures[.youTubeMusic] ?? failures.values.first ?? MusicServiceError.invalidResponse }
            var merged = pages[.youTubeMusic] ?? CatalogPage()
            var trackIDs = Set(merged.tracks.map(\.id))
            var collectionIDs = Set(merged.collections.map(\.id))
            for source in sources where source != .youTubeMusic {
                guard let page = pages[source] else { continue }
                merged.tracks += page.tracks.filter { trackIDs.insert($0.id).inserted }
                merged.collections += page.collections.filter { collectionIDs.insert($0.id).inserted }
            }
            return merged
        }
    }

    enum SearchUpdate: Sendable {
        /// YouTube Music's page, or an empty page when only extra sources answered; always the first update.
        case primary(CatalogPage)
        case secondary(MusicSource, CatalogPage)
    }

    /// The Search screen's fan-out without the wait: YouTube Music's results arrive as soon as they exist and each
    /// extra source follows on its own deadline. Outcomes and failure rules match `search` under `searchingAllSources`.
    func progressiveSearch(query: String, filter: SearchFilter) -> AsyncThrowingStream<SearchUpdate, any Error> {
        let sources = activeSources
        let providers = secondary
        let deadline = secondarySearchDeadline
        let youTube = self.youTube
        return AsyncThrowingStream { continuation in
            let work = Task {
                await withTaskGroup(of: (MusicSource, Result<CatalogPage, any Error>).self) { group in
                    group.addTask {
                        await (.youTubeMusic, Self.outcome { try await youTube.search(query: query, filter: filter, continuation: nil) })
                    }
                    for source in sources where source != .youTubeMusic {
                        guard let provider = providers[source] else { continue }
                        group.addTask {
                            await (source, Self.outcome {
                                try await PlaybackDeadline.run(seconds: deadline) { try await provider.search(query: query, filter: filter, continuation: nil) }
                            })
                        }
                    }
                    var primaryError: (any Error)?
                    var primaryDelivered = false
                    var waiting: [MusicSource: CatalogPage] = [:]
                    func deliverWaiting() {
                        for source in sources where waiting[source] != nil {
                            continuation.yield(.secondary(source, waiting.removeValue(forKey: source)!))
                        }
                    }
                    for await (source, result) in group {
                        if Task.isCancelled { break }
                        switch result {
                        case .success(let page) where source == .youTubeMusic:
                            continuation.yield(.primary(page))
                            primaryDelivered = true
                            deliverWaiting()
                        case .success(let page):
                            if !primaryDelivered, primaryError != nil {
                                continuation.yield(.primary(CatalogPage()))
                                primaryDelivered = true
                            }
                            if primaryDelivered { continuation.yield(.secondary(source, page)) } else { waiting[source] = page }
                        case .failure(let error) where source == .youTubeMusic:
                            if error is CancellationError { group.cancelAll(); continuation.finish(throwing: error); return }
                            primaryError = error
                            // Extra sources still answer on their own; an empty primary keeps their results visible.
                            if !waiting.isEmpty {
                                continuation.yield(.primary(CatalogPage()))
                                primaryDelivered = true
                                deliverWaiting()
                            }
                        case .failure:
                            break
                        }
                    }
                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    if !primaryDelivered {
                        continuation.finish(throwing: primaryError ?? MusicServiceError.invalidResponse)
                        return
                    }
                    Self.logger.debug("event=progressive_search sources=\(sources.count) primary_failed=\(primaryError == nil ? 0 : 1)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func outcome(_ body: @Sendable () async throws -> CatalogPage) async -> Result<CatalogPage, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    func browse(id: String) async throws -> CatalogPage {
        try await provider(for: id).browse(id: id)
    }

    func artist(id: String) async throws -> ArtistPage {
        try await provider(for: id).artist(id: id)
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await provider(for: seed.id).recommendations(seed: seed, language: language)
    }

    func radio(seed: Track) async throws -> [Track] {
        try await provider(for: seed.id).radio(seed: seed)
    }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        try await provider(for: seed.id).radio(seed: seed, forceRefresh: forceRefresh)
    }

    /// Home discovery is the primary catalog's editorial surface.
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try await youTube.discovery(languages: languages)
    }

    // MARK: LyricsProviding

    /// A source without a lyrics hook answers unavailable, so the composite lyrics provider stops cleanly.
    func lyrics(for track: Track) async throws -> LyricsDocument {
        guard let provider = provider(for: track.id) as? any LyricsProviding else {
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: track.source.title)
        }
        return try await provider.lyrics(for: track)
    }

    // MARK: AlbumDescriptionProviding

    func albumDescription(id: String) async throws -> AlbumDescription? {
        try await (provider(for: id) as? any AlbumDescriptionProviding)?.albumDescription(id: id)
    }
}

/// Stands in for a source that is not installed; every call answers empty and browsing an id of it is unavailable.
struct EmptyCatalog: MusicCatalogProviding {
    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage { CatalogPage() }
    func browse(id: String) async throws -> CatalogPage {
        throw MusicServiceError.unavailable("This music comes from a catalog that is not available in this build.")
    }
    func artist(id: String) async throws -> ArtistPage {
        throw MusicServiceError.unavailable("This artist comes from a catalog that is not available in this build.")
    }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { [] }
    func radio(seed: Track) async throws -> [Track] { [] }
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] { [] }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { [] }
}
