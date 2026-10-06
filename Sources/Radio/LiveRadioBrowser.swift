import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LiveRadioBrowser {
    let favorites: LiveRadioFavorites
    private(set) var stations: [LiveRadioStation] = []
    private(set) var isLoading = false
    /// Directory results are listed only after their stream answers the same probe playback uses.
    private(set) var isVerifying = false
    /// Stations in the latest results whose stream failed the probe and are therefore not listed.
    private(set) var hiddenCount = 0
    private(set) var errorMessage: String?
    private(set) var hasSearched = false
    @ObservationIgnored private let directory: any LiveRadioDirectoryProviding
    @ObservationIgnored private let verifier: (any LiveRadioResolving)?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var health: [UUID: (working: Bool, checkedAt: Date)] = [:]
    /// Broadcasters come and go within the hour; a stale verdict is probed again rather than trusted.
    static let healthLifetime: TimeInterval = 30 * 60
    /// Enough parallel probes to fill a screen quickly without opening a hundred connections at once.
    static let verificationWidth = 6
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "LiveRadio")

    init(directory: any LiveRadioDirectoryProviding = LiveRadioDirectory(), favorites: LiveRadioFavorites,
         verifier: (any LiveRadioResolving)? = nil) {
        self.directory = directory
        self.favorites = favorites
        self.verifier = verifier
    }

    func search(_ filter: LiveRadioFilter, isOffline: Bool) async {
        let token = UUID()
        generation = token
        stations = []
        errorMessage = nil
        hasSearched = true
        hiddenCount = 0
        isVerifying = false
        guard !isOffline else {
            isLoading = false
            errorMessage = "Live radio needs an internet connection. Saved stations remain on this device."
            return
        }
        isLoading = true
        let results: [LiveRadioStation]
        do {
            results = try await directory.search(filter)
            try Task.checkCancellation()
            guard generation == token else { return }
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            isLoading = false
            errorMessage = (error as? LiveRadioError)?.localizedDescription ?? LiveRadioError.unavailable.localizedDescription
            return
        }
        isLoading = false
        guard let verifier else {
            stations = results
            return
        }
        await verify(results, with: verifier, token: token)
    }

    private func verify(_ results: [LiveRadioStation], with verifier: any LiveRadioResolving, token: UUID) async {
        let now = Date()
        var working = Set<UUID>()
        var pending: [LiveRadioStation] = []
        for station in results {
            if let verdict = health[station.id], now.timeIntervalSince(verdict.checkedAt) < Self.healthLifetime {
                if verdict.working { working.insert(station.id) } else { hiddenCount += 1 }
            } else {
                pending.append(station)
            }
        }
        // Results keep the directory's vote order as verified stations join.
        stations = results.filter { working.contains($0.id) }
        guard !pending.isEmpty else { return }
        isVerifying = true
        let started = ContinuousClock.now
        var failed = 0
        await withTaskGroup(of: (UUID, Bool?).self) { group in
            var queue = pending.makeIterator()
            func enqueue() {
                guard let station = queue.next() else { return }
                group.addTask { (station.id, await Self.probe(station, with: verifier)) }
            }
            for _ in 0..<Self.verificationWidth { enqueue() }
            while let (id, verdict) = await group.next() {
                guard generation == token, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let verdict {
                    health[id] = (verdict, Date())
                    if verdict {
                        working.insert(id)
                        stations = results.filter { working.contains($0.id) }
                    } else {
                        failed += 1
                        hiddenCount += 1
                    }
                }
                enqueue()
            }
        }
        guard generation == token else { return }
        isVerifying = false
        let elapsed = started.duration(to: .now).components.seconds
        Self.log.info("event=live_radio_verification checked=\(pending.count, privacy: .public) failed=\(failed, privacy: .public) seconds=\(elapsed, privacy: .public)")
    }

    /// `nil` when the probe was cancelled, which says nothing about the station.
    private nonisolated static func probe(_ station: LiveRadioStation, with verifier: any LiveRadioResolving) async -> Bool? {
        do {
            _ = try await verifier.resolve(station)
            return true
        } catch {
            return Task.isCancelled || error is CancellationError ? nil : false
        }
    }

    func cancelSearch() {
        generation = UUID()
        isLoading = false
        isVerifying = false
    }
}
