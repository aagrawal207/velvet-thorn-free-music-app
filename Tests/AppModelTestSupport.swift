import Foundation
import XCTest
@testable import GanaBajana

enum AppModelTestFailure: Error {
    case timedOut(String)
    case unexpectedRequest(String)
    case alreadyCompleted(Int)
    case storage(String)
}

actor AppModelRequestGate<Input: Sendable, Output: Sendable> {
    struct Request: Sendable {
        let id: Int
        let input: Input
    }

    private(set) var requests: [Request] = []
    private(set) var cancellations: Set<Int> = []
    private var pending: [Int: CheckedContinuation<Output, any Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var timedOut: Set<Int> = []
    private var immediate: [Result<Output, any Error>] = []
    private var closed = false

    func receive(_ input: Input) async throws -> Output {
        guard !closed else { throw CancellationError() }
        let request = Request(id: requests.count, input: input)
        requests.append(request)
        if !immediate.isEmpty { return try immediate.removeFirst().get() }

        // Providers can finish after cancellation; the test controls when their response arrives.
        // Closing the gate also releases requests when an assertion or request wait fails.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = continuation
                deadlines[request.id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.expire(request.id)
                }
            }
        } onCancel: {
            Task { await self.recordCancellation(request.id) }
        }
    }

    func enqueue(_ result: Result<Output, any Error>) {
        immediate.append(result)
    }

    func request(at index: Int) async throws -> Request {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while requests.count <= index {
            guard ContinuousClock.now < deadline else {
                throw AppModelTestFailure.timedOut("Provider request \(index)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return requests[index]
    }

    func complete(_ request: Request, with result: Result<Output, any Error>) throws {
        guard let continuation = pending.removeValue(forKey: request.id) else {
            throw AppModelTestFailure.alreadyCompleted(request.id)
        }
        deadlines.removeValue(forKey: request.id)?.cancel()
        continuation.resume(with: result)
    }

    func close() {
        closed = true
        deadlines.values.forEach { $0.cancel() }
        deadlines.removeAll()
        let waiting = Array(pending.values)
        pending.removeAll()
        immediate.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
        XCTAssertTrue(timedOut.isEmpty, "Unanswered \(Input.self) fixture requests: \(timedOut.sorted())")
    }

    private func recordCancellation(_ id: Int) { cancellations.insert(id) }

    private func expire(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)
        timedOut.insert(id)
        continuation.resume(throwing: AppModelTestFailure.timedOut("Unanswered provider request \(id)"))
    }
}

struct AppModelSearchRequest: Equatable, Sendable {
    let query: String
    let filter: SearchFilter
    let continuation: String?
}

struct AppModelRadioRequest: Sendable {
    let seed: Track
    let language: MusicLanguage
}

actor AppModelCatalogProvider: MusicCatalogProviding {
    let searches = AppModelRequestGate<AppModelSearchRequest, CatalogPage>()
    let discoveries = AppModelRequestGate<Set<MusicLanguage>, [DiscoverySection]>()
    let radios = AppModelRequestGate<AppModelRadioRequest, [Track]>()
    let autoplayRadios = AppModelRequestGate<Track, [Track]>()
    let artists = AppModelRequestGate<String, ArtistPage>()
    private(set) var radioRefreshRequests: [(seed: Track, forceRefresh: Bool)] = []

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await searches.receive(AppModelSearchRequest(query: query, filter: filter, continuation: continuation))
    }

    func browse(id: String) async throws -> CatalogPage {
        throw AppModelTestFailure.unexpectedRequest("browse: \(id)")
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await radios.receive(AppModelRadioRequest(seed: seed, language: language))
    }

    func radio(seed: Track) async throws -> [Track] {
        try await autoplayRadios.receive(seed)
    }

    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] {
        radioRefreshRequests.append((seed, forceRefresh))
        return try await radio(seed: seed)
    }

    func artist(id: String) async throws -> ArtistPage {
        try await artists.receive(id)
    }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try await discoveries.receive(languages)
    }

    func close() async {
        await searches.close()
        await discoveries.close()
        await radios.close()
        await autoplayRadios.close()
        await artists.close()
    }
}

actor AppModelChartsProvider: MusicChartsProviding {
    let charts = AppModelRequestGate<MusicLanguage, ChartSnapshot>()

    func weeklyChart(language: MusicLanguage) async throws -> ChartSnapshot {
        try await charts.receive(language)
    }
}

actor AppModelLyricsProvider: LyricsProviding {
    private(set) var requests: [Track] = []

    func lyrics(for track: Track) async throws -> LyricsDocument {
        requests.append(track)
        return LyricsDocument(trackID: track.id, kind: .unavailable, source: "Offline fixture")
    }
}

struct AppModelStreamRequest: Sendable {
    let track: Track
    let forceRefresh: Bool
}

actor AppModelStreamResolver: StreamResolving {
    let streams = AppModelRequestGate<AppModelStreamRequest, ResolvedStream>()

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await streams.receive(AppModelStreamRequest(track: track, forceRefresh: forceRefresh))
    }
}

@MainActor
final class AppModelTestContext {
    let directory: URL
    let library: LibraryStore
    let catalog = AppModelCatalogProvider()
    let charts = AppModelChartsProvider()
    let lyrics = AppModelLyricsProvider()
    let streams = AppModelStreamResolver()
    let player: PlayerController
    let model: MusicAppModel
    private var tasks: [Task<Void, Never>] = []

    init(languages: Set<MusicLanguage> = [.english], snapshot: PlaybackSnapshot = PlaybackSnapshot(),
         resolver: (any StreamResolving)? = nil, generatesMixes: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-AppModelTests-\(UUID())", isDirectory: true)
        library = LibraryStore(directory: directory)
        var preferences = library.preferences
        preferences.languages = languages
        preferences.useEncryptedDNS = false
        preferences.allowRemoteFallback = false
        library.preferences = preferences
        library.updatePlayback(snapshot)
        if let error = library.errorMessage {
            try? FileManager.default.removeItem(at: directory)
            throw AppModelTestFailure.storage(error)
        }
        player = PlayerController(resolver: resolver ?? streams)
        // Most gates exercise one Home or Search request; mix publication tests opt into the engine's fan-out.
        model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts, lyrics: lyrics,
                              account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                              generatesMixes: generatesMixes)
    }

    func start(_ operation: @escaping @MainActor (MusicAppModel) async -> Void) -> Task<Void, Never> {
        let task = Task { @MainActor [model] in await operation(model) }
        tasks.append(task)
        return task
    }

    func seedHistory(_ track: Track) {
        library.recordListening(track: track, sessionID: UUID(),
                                startedAt: Date().addingTimeInterval(-120), seconds: 40)
    }

    /// Enough real listening for a personal profile: three counted plays across two artists, where only the
    /// primary artist carries a channel id and therefore seeds a "Because you like" section.
    func seedListener(primary: Track, language: MusicLanguage = .english) -> Track {
        var seed = primary
        seed.credits = [ArtistCredit(name: "Artist \(primary.id)", id: "UC\(primary.id)")]
        var other = AppModelFixtures.track("\(primary.id)-other", language: language)
        other.artists = ["Other Artist"]
        for offset in [-300.0, -200.0] {
            library.recordListening(track: seed, sessionID: UUID(), startedAt: Date().addingTimeInterval(offset), seconds: 40)
        }
        library.recordListening(track: other, sessionID: UUID(), startedAt: Date().addingTimeInterval(-100), seconds: 40)
        return seed
    }

    func artistPage(_ id: String, songs: [Track]) -> ArtistPage {
        ArtistPage(id: id, name: "Artist \(id)", topSongs: songs)
    }

    func seedSearch(_ page: CatalogPage, query: String = "fixture", filter: SearchFilter = .songs) async {
        model.searchQuery = query
        model.searchFilter = filter
        await catalog.searches.enqueue(.success(page))
        await model.search()
    }

    func close() async throws {
        tasks.forEach { $0.cancel() }
        player.pause()
        await catalog.close()
        await charts.charts.close()
        await streams.streams.close()
        for task in tasks { await task.value }
        tasks.removeAll()
        try await AppModelFixtures.eventually { !model.isGeneratingMixes }
        try FileManager.default.removeItem(at: directory)
    }
}

enum AppModelFixtures {
    static func track(_ id: String, language: MusicLanguage = .english) -> Track {
        var track = libraryTestTrack(id)
        track.language = language
        return track
    }

    static func section(_ id: String, language: MusicLanguage = .english) -> DiscoverySection {
        DiscoverySection(id: id, title: "Discovery \(id)", language: language,
                         tracks: [track("\(id)-song", language: language)])
    }

    static func chart(_ id: String, language: MusicLanguage = .english) -> ChartSnapshot {
        ChartSnapshot(id: id, title: "Weekly \(language.title)", subtitle: "Provider fixture",
                      source: "Offline chart provider", language: language,
                      periodStart: Date(timeIntervalSince1970: 1_700_000_000),
                      periodEnd: Date(timeIntervalSince1970: 1_700_604_800),
                      fetchedAt: Date(timeIntervalSince1970: 1_700_700_000),
                      entries: [ChartEntry(rank: 1, track: track("\(id)-song", language: language))])
    }

    @MainActor
    static func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AppModelTestFailure.timedOut("Model state") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
