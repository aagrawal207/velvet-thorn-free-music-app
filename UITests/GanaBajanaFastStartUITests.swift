import XCTest

/// `--fast-start-fixture` gives cold resolutions a 2 s lookup; `search.warm.count` and `search.playbackStart` are
/// DEBUG readouts of the warmer's last job and the player's last `playback_start` ("path=<path> ms=<n>").
@MainActor
final class GanaBajanaFastStartUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAWarmedSearchResultStartsWellBeforeAnUnwarmedOne() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--fast-start-fixture"])
        // "i" matches four fixture songs; the warmer takes the top three and leaves Blinding Lights cold.
        try ui.search("i")
        try ui.waitForSearchResults()
        let counter = ui.app.staticTexts["search.warm.count"]
        try ui.wait("The warmer must resolve the top three results") { counter.exists && (counter.value as? String) == "3" }

        let start = ui.app.staticTexts["search.playbackStart"]
        try ui.playSearchResult(id: AppUIFixture.tumHiHo, title: "Tum Hi Ho")
        let warmed = try playbackStart(start, path: "warmed", ui: ui)
        XCTAssertLessThan(warmed, 1_500, "A warmed song reaches audio without the cold lookup")

        try ui.playSearchResult(id: AppUIFixture.blindingLights, title: "Blinding Lights")
        let cold = try playbackStart(start, path: "fastPath", ui: ui)
        XCTAssertGreaterThanOrEqual(cold, 2_000, "The unwarmed song pays the fixture's 2 s lookup")
        XCTAssertLessThan(warmed + 1_000, cold, "Warming saves at least a second over the cold start (\(warmed) ms vs \(cold) ms)")
        print("FASTSTART-UI warmed=\(warmed)ms cold=\(cold)ms")
        ui.capture("fast-start-warmed-versus-cold")

        // A new query replaces the warm job; the counter follows the newest result set.
        try ui.replaceSearchQuery("Shape")
        try ui.waitForSearchResults()
        try ui.wait("The newest result set is warmed") { (counter.value as? String) == "1" }
    }

    /// Waits for a `playback_start` on `path` and returns its milliseconds.
    private func playbackStart(_ element: XCUIElement, path: String, ui: AppUITestDriver) throws -> Int {
        try ui.wait("playback_start must report path=\(path)", timeout: 10) {
            (element.value as? String)?.hasPrefix("path=\(path) ") == true
        }
        let value = element.value as? String ?? ""
        return try XCTUnwrap(Int(value.split(separator: "=").last ?? ""), value)
    }

    private func makeDriver() -> AppUITestDriver {
        let driver = AppUITestDriver(testCase: self, prefix: "faststart")
        addTeardownBlock { await driver.finish() }
        return driver
    }
}
