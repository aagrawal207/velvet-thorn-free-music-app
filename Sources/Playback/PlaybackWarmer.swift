import Foundation
import OSLog

/// Prepares the songs a listener is likely to tap next; one job at a time, replaced by a newer event. With a preloader,
/// progressive songs get ready-to-play assets and HLS songs signed URLs; without one, URLs plus a speculative download
/// of the first. Surfaces, gates and budgets are in `docs/FAST_START.md`.
@MainActor @Observable
final class PlaybackWarmer {
    enum Surface: String, Sendable {
        case search, collection, artist, home

        var limit: Int {
            switch self {
            case .search, .collection, .artist: 3
            case .home: 2
            }
        }
    }

    /// Resolutions any number of warm events may start in a sliding minute, on top of each event's own limit.
    nonisolated static let resolutionsPerMinute = 12
    nonisolated static let searchOwner = "search"

    /// Seeded UI runs keep warming off so their resolver and cache inventory stay deterministic; the fast-start fixture
    /// opts back in. Unit hosts construct their own warmers.
    nonisolated static var isEnabledByDefault: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting") {
            #if DEBUG
            return arguments.contains("--fast-start-fixture")
            #else
            return false
            #endif
        }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    struct Network {
        var isOffline: @MainActor () -> Bool
        var isExpensive: @MainActor () -> Bool
        var isConstrained: @MainActor () -> Bool
        /// `downloadsOverCellular`: the listener's consent to spend an expensive path on audio they did not choose.
        var allowsExpensive: @MainActor () -> Bool
    }

    private let resolver: (any StreamWarming)?
    private let network: Network
    private let preloader: PlaybackPreloader?
    private let enabled: Bool
    private let now: @MainActor () -> Date
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var owner: String?
    private var budget: [Date] = []
    /// Songs the last finished job resolved; the fixture UI reads it through `search.warm.count`.
    private(set) var resolvedCount = 0
    private(set) var lastOutcome: StreamWarmOutcome?
    private(set) var lastSurface: Surface?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Playback")

    /// Resolvers that are not `StreamWarming` (playback fixtures, plain test resolvers) leave the warmer inert.
    init(resolver: any StreamResolving, network: Network, preloader: PlaybackPreloader? = nil,
         enabled: Bool = PlaybackWarmer.isEnabledByDefault, now: @escaping @MainActor () -> Date = { Date() }) {
        self.resolver = resolver as? any StreamWarming
        self.network = network
        self.preloader = preloader
        self.enabled = enabled
        self.now = now
    }

    var isActive: Bool { task != nil }
    var isAvailable: Bool { enabled && resolver != nil }

    /// Replaces any running job. Video entries and duplicates are dropped before the surface's limit applies. `owner`
    /// names the page (a collection id, or "search") so leaving it cancels only its own job.
    func warm(_ tracks: [Track], surface: Surface, owner: String) {
        let routesToPreloader = preloader?.isAvailable == true
        // Re-routing replaces the browse request in place; cancelling first would restart preparations still wanted.
        retireJob()
        guard enabled, let resolver else { return }
        if let reason = skipReason() {
            preloader?.cancelBrowse()
            log.debug("event=warm_skipped surface=\(surface.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
            return
        }
        var seen = Set<String>()
        let candidates = Array(tracks.filter { $0.isAudioRecording != false && seen.insert($0.id).inserted }.prefix(surface.limit))
        var urlTracks = candidates
        var download = true
        if routesToPreloader, let preloader {
            // Preloaded assets make a complete speculative download unnecessary; HLS songs still benefit from a URL.
            preloader.setBrowse(candidates.filter { $0.source != .gaana }, owner: owner)
            urlTracks = candidates.filter { $0.source == .gaana }
            download = false
            log.debug("event=warm_routed surface=\(surface.rawValue, privacy: .public) preloads=\(candidates.count - urlTracks.count) urls=\(urlTracks.count)")
            self.owner = owner
        }
        // The minute budget covers the warmer's own resolutions; the preloader paces its lane separately.
        let current = now()
        budget.removeAll { current.timeIntervalSince($0) >= 60 }
        let allowed = Self.resolutionsPerMinute - budget.count
        guard allowed > 0 else {
            if !urlTracks.isEmpty { log.debug("event=warm_skipped surface=\(surface.rawValue, privacy: .public) reason=budget") }
            return
        }
        let selected = Array(urlTracks.prefix(allowed))
        guard !selected.isEmpty else { return }
        urlTracks = selected
        budget += Array(repeating: current, count: selected.count)
        let job = UUID()
        token = job
        self.owner = owner
        task = Task(priority: .utility) { [weak self] in
            let outcome = await resolver.warm(urlTracks, download: download, token: job)
            guard !Task.isCancelled, let self, self.token == job else { return }
            self.task = nil
            // Songs that needed no request give their share of the minute back.
            for _ in 0..<min(outcome.skipped, self.budget.count) { self.budget.removeLast() }
            self.resolvedCount = outcome.resolved
            self.lastOutcome = outcome
            self.lastSurface = surface
            self.log.info("event=warm_up surface=\(surface.rawValue, privacy: .public) resolved=\(outcome.resolved) downloaded=\(outcome.downloadScheduled ? 1 : 0) skipped=\(outcome.skipped) failed=\(outcome.failed)")
        }
    }

    /// Retires the running job and the speculative download it started; `owner` limits this to that page's job.
    func cancel(owner: String? = nil) {
        if let owner, owner != self.owner { return }
        preloader?.cancelBrowse(owner: owner)
        retireJob()
    }

    private func retireJob() {
        let retired = token
        token = UUID()
        owner = nil
        task?.cancel()
        task = nil
        if let resolver { Task { await resolver.cancelWarm(token: retired) } }
    }

    private func skipReason() -> String? {
        if network.isOffline() { return "offline" }
        if network.isConstrained() { return "low_data" }
        if network.isExpensive() && !network.allowsExpensive() { return "expensive" }
        return nil
    }
}

#if DEBUG
/// `--fast-start-fixture`: a cold resolution costs `coldDelay`, like a network lookup, and a warmed one is immediate.
/// Streams are the ordinary fixture files and nothing is written to the audio cache.
actor DebugFastStartAudioResolver: StreamWarming {
    static let coldDelay: Duration = .seconds(2)
    private var warmed: Set<String> = []

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        if warmed.contains(track.id) {
            PlaybackStartTrace.record(.urlCache, for: track.id)
        } else {
            try await Task.sleep(for: Self.coldDelay)
            PlaybackStartTrace.record(.fastPath, for: track.id)
        }
        return try await DebugMusicFixtures().resolve(track: track, forceRefresh: forceRefresh)
    }

    func warm(_ tracks: [Track], download: Bool, token: UUID) async -> StreamWarmOutcome {
        var outcome = StreamWarmOutcome()
        for track in tracks {
            if warmed.contains(track.id) { outcome.skipped += 1; continue }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return outcome }
            warmed.insert(track.id)
            PlaybackStartTrace.markWarmed(track.id)
            outcome.resolved += 1
        }
        return outcome
    }
}
#endif
