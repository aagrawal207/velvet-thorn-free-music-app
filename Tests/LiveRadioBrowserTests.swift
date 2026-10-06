import XCTest
@testable import GanaBajana

@MainActor
final class LiveRadioBrowserTests: XCTestCase {
    func testSupersededSearchCannotReplaceNewResultsOrError() async throws {
        let directory = LiveRadioBrowserGate()
        let browser = LiveRadioBrowser(directory: directory, favorites: LiveRadioFavorites(url: nil))
        let old = Task { await browser.search(LiveRadioFilter(name: "old"), isOffline: false) }
        try await PlaybackTestSupport.eventually { await directory.names.contains("old") }
        let current = Task { await browser.search(LiveRadioFilter(name: "current"), isOffline: false) }
        try await PlaybackTestSupport.eventually { await directory.names.contains("current") }
        await directory.finish("current", result: .success([LiveRadioTestSupport.station]))
        await current.value
        await directory.finish("old", result: .failure(LiveRadioError.unavailable))
        await old.value
        XCTAssertEqual(browser.stations, [LiveRadioTestSupport.station])
        XCTAssertNil(browser.errorMessage)
        XCTAssertFalse(browser.isLoading)
    }

    func testCancelAndOfflineNeverPublishStaleResultsOrSendFavorites() async throws {
        let directory = LiveRadioBrowserGate()
        let favorites = LiveRadioFavorites(url: nil)
        favorites.toggle(LiveRadioTestSupport.station)
        let browser = LiveRadioBrowser(directory: directory, favorites: favorites)
        let task = Task { await browser.search(LiveRadioFilter(name: "pending"), isOffline: false) }
        try await PlaybackTestSupport.eventually { await directory.names.contains("pending") }
        task.cancel()
        browser.cancelSearch()
        await directory.finish("pending", result: .success([LiveRadioTestSupport.station]))
        await task.value
        XCTAssertTrue(browser.stations.isEmpty)
        await browser.search(.npr, isOffline: true)
        let names = await directory.names
        XCTAssertEqual(names, ["pending"])
        XCTAssertNotNil(browser.errorMessage)
        XCTAssertEqual(favorites.stations, [LiveRadioTestSupport.station])
    }
}

@MainActor
final class LiveRadioVerificationTests: XCTestCase {
    private func stations(_ count: Int) -> [LiveRadioStation] {
        (0..<count).map { index in
            LiveRadioStation(id: UUID(), name: "Station \(index)", streamingURL: URL(string: "https://s\(index).example.org/live")!,
                             homepageURL: nil, artworkURL: nil, countryCode: "US", languages: [], tags: [], codec: "MP3", isHLS: false)
        }
    }

    func testOnlyStationsWhoseStreamAnswersAreListedInDirectoryOrder() async {
        let all = stations(9)
        let failing: Set<UUID> = [all[1].id, all[4].id, all[8].id]
        let verifier = LiveRadioVerifierStub(failing: failing)
        let browser = LiveRadioBrowser(directory: LiveRadioFixedDirectory(all), favorites: LiveRadioFavorites(url: nil), verifier: verifier)
        await browser.search(LiveRadioFilter(), isOffline: false)
        XCTAssertEqual(browser.stations, all.filter { !failing.contains($0.id) })
        XCTAssertEqual(browser.hiddenCount, 3)
        XCTAssertFalse(browser.isVerifying)
        XCTAssertFalse(browser.isLoading)
        let probes = await verifier.probeCount
        XCTAssertEqual(probes, 9)
        let widest = await verifier.maximumInFlight
        XCTAssertLessThanOrEqual(widest, LiveRadioBrowser.verificationWidth)
    }

    func testRecentVerdictsAreReusedAndHiddenCountStaysPerSearch() async {
        let all = stations(4)
        let verifier = LiveRadioVerifierStub(failing: [all[2].id])
        let browser = LiveRadioBrowser(directory: LiveRadioFixedDirectory(all), favorites: LiveRadioFavorites(url: nil), verifier: verifier)
        await browser.search(LiveRadioFilter(), isOffline: false)
        await browser.search(LiveRadioFilter(name: "again"), isOffline: false)
        let probes = await verifier.probeCount
        XCTAssertEqual(probes, 4, "A verdict younger than the health lifetime must not probe the broadcaster again")
        XCTAssertEqual(browser.stations.count, 3)
        XCTAssertEqual(browser.hiddenCount, 1)
    }

    func testWithoutAVerifierResultsAreListedUnprobed() async {
        let all = stations(3)
        let browser = LiveRadioBrowser(directory: LiveRadioFixedDirectory(all), favorites: LiveRadioFavorites(url: nil))
        await browser.search(LiveRadioFilter(), isOffline: false)
        XCTAssertEqual(browser.stations, all)
        XCTAssertEqual(browser.hiddenCount, 0)
    }
}

private struct LiveRadioFixedDirectory: LiveRadioDirectoryProviding {
    let stations: [LiveRadioStation]
    init(_ stations: [LiveRadioStation]) { self.stations = stations }
    func search(_ filter: LiveRadioFilter) async throws -> [LiveRadioStation] { stations }
}

private actor LiveRadioVerifierStub: LiveRadioResolving {
    let failing: Set<UUID>
    private(set) var probeCount = 0
    private(set) var maximumInFlight = 0
    private var inFlight = 0
    init(failing: Set<UUID>) { self.failing = failing }

    func resolve(_ station: LiveRadioStation) async throws -> LiveRadioConnection {
        probeCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        if failing.contains(station.id) { throw LiveRadioError.invalidStation }
        return LiveRadioConnection(station: station, streamingURL: station.streamingURL)
    }
}

private actor LiveRadioBrowserGate: LiveRadioDirectoryProviding {
    private(set) var names: [String] = []
    private var waiting: [String: CheckedContinuation<[LiveRadioStation], Error>] = [:]
    func search(_ filter: LiveRadioFilter) async throws -> [LiveRadioStation] {
        names.append(filter.name)
        return try await withCheckedThrowingContinuation { waiting[filter.name] = $0 }
    }
    func finish(_ name: String, result: Result<[LiveRadioStation], Error>) { waiting.removeValue(forKey: name)?.resume(with: result) }
}
