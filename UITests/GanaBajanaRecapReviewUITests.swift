import XCTest

/// R13 items 1 and 2: Listening languages closes the recap and the total is a stat tile with a compact chart.
@MainActor
final class GanaBajanaRecapReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testListeningLanguagesFollowsRankingsAndPrecedesNotesAndCollapsedHistory() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.tap(ui.app.buttons["tab.recap"].firstMatch)
        try ui.wait("The seeded recap must show its populated sections") {
            ui.element("recap.totalListening").exists && ui.app.buttons["recap.share"].exists
        }
        let languages = ui.app.buttons["recap.listeningLanguages"]
        try ui.reveal(languages, maxSwipes: 20)
        try ui.requireHittable(languages)
        // The plain VStack keeps these sections in the tree, so frames compare without a second scroll; the
        // metrics grid is lazy and drops off-screen cells, so its order is covered by the hero and On repeat around it.
        for id in ["recap.totalListening", "recap.topArtist", "recap.onRepeat.play", "recap.dayChart", "recap.share"] {
            let section = ui.element(id)
            XCTAssertTrue(section.exists, "\(id) must exist above the languages entry")
            XCTAssertLessThan(section.frame.minY, languages.frame.minY, "\(id) must sit above Listening languages")
        }
        let artist = ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recap.artist.")).firstMatch
        XCTAssertTrue(artist.exists)
        XCTAssertLessThan(artist.frame.minY, languages.frame.minY, "Artists in rotation must sit above Listening languages")
        let notes = ui.element("recap.howCounted")
        XCTAssertTrue(notes.exists)
        XCTAssertGreaterThan(notes.frame.minY, languages.frame.maxY - 1)
        XCTAssertGreaterThan(ui.element("recap.recent").frame.minY, notes.frame.maxY - 1, "Collapsed history is last")
        XCTAssertTrue(languages.label.contains("Listening Languages"))
        XCTAssertTrue(languages.label.contains("Last 30 days"))
        try ui.expectValue(languages, "20 plays · 5 songs")
        ui.capture("recap-languages-last-section")

        try ui.tap(languages)
        try ui.wait("The entry must still open the languages page") { ui.app.navigationBars["Listening Languages"].exists }
        try ui.tap(ui.app.navigationBars["Listening Languages"].buttons.firstMatch)
        try ui.wait("Back must return to the recap") { ui.element("recap.screen").exists }
    }

    func testTotalIsAStatTileWithACompactChartAndAPreviousPeriodComparison() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--recap-history-fixture"])
        try ui.tap(ui.app.buttons["tab.recap"].firstMatch)
        let total = ui.element("recap.totalListening")
        let chart = ui.element("recap.totalListening.chart")
        try ui.requireHittable(total)
        XCTAssertEqual(total.label, "89 minutes listened in the last 7 days")
        XCTAssertEqual(try ui.recapSeconds(), 89 * 60, accuracy: 0.5)
        // Seven older sessions (1,862 s) sit 8 to 13 days back, so this week's 5,359 s read as 2.9 times as much.
        XCTAssertEqual(total.value as? String, "2.9 times as much as the previous 7 days")
        XCTAssertTrue(chart.exists)
        XCTAssertEqual(chart.label, "Listening by day, last 7 days")
        let chartSummary = chart.value as? String ?? ""
        XCTAssertTrue(chartSummary.contains("with listening"), chartSummary)
        XCTAssertTrue(chartSummary.contains("Most on"), chartSummary)
        XCTAssertFalse(chartSummary.contains("No listening"), "The seeded week has six days with sessions")
        // Beside the tile in compact width, never covering it; the row holds numbers and bars only.
        XCTAssertGreaterThanOrEqual(chart.frame.minX, total.frame.maxX - 1)
        XCTAssertGreaterThanOrEqual(chart.frame.height, 60)
        XCTAssertLessThan(abs(chart.frame.maxY - total.frame.maxY), 40, "Tile and chart share the same row")
        ui.capture("recap-total-stat-tile-week")

        try ui.tap(ui.app.buttons["recap.window.month"])
        try ui.wait("The month window must relabel the tile and chart") {
            total.label == "120 minutes listened in the last 30 days" && chart.label == "Listening by week, last 30 days"
        }
        XCTAssertEqual(total.value as? String, "No listening in the previous 30 days")

        try ui.tap(ui.app.buttons["recap.window.year"])
        try ui.wait("The year window has no retained previous period to compare with") {
            total.label == "120 minutes listened in the last 365 days" && chart.label == "Listening by month, last 365 days"
                && (total.value as? String ?? "").isEmpty
        }
        ui.capture("recap-total-stat-tile-year")
    }

    func testTileReadsTheSameTotalInEveryWindowWithoutOlderHistory() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.tap(ui.app.buttons["tab.recap"].firstMatch)
        for (window, days) in [("week", 7), ("month", 30), ("year", 365)] {
            try ui.tap(ui.app.buttons["recap.window.\(window)"])
            try ui.expectMetric("recap.totalListening", number: 89, description: "minutes listened")
            let total = ui.element("recap.totalListening")
            XCTAssertEqual(total.label, "89 minutes listened in the last \(days) days")
            XCTAssertEqual(total.value as? String ?? "", window == "year" ? "" : "No listening in the previous \(days) days")
        }
    }

    func testAllTimeUsesSavedHistoryLabelsAndPreservesTabIdentity() throws {
        let ui = makeDriver()
        try ui.launch()
        let tab = ui.app.buttons["tab.recap"].firstMatch
        XCTAssertEqual(tab.label, "Stats")
        try ui.tap(tab)
        XCTAssertTrue(ui.app.staticTexts["Stats"].exists)
        try ui.tap(ui.app.buttons["recap.window.allTime"])
        try ui.wait("All Time uses available history, not a 365-day label") {
            ui.element("recap.totalListening").label == "89 minutes listened across all available history"
        }
        XCTAssertEqual(ui.element("recap.historyCoverage").label,
                       "Based on saved history; older deleted plays cannot be recovered")
        XCTAssertTrue(ui.app.buttons["recap.window.allTime"].isSelected)
        XCTAssertFalse(ui.app.buttons["recap.window.week"].isSelected)
        XCTAssertEqual(ui.element("recap.totalListening.chart").label, "Listening over time, all available history")
        XCTAssertEqual(ui.element("recap.totalListening").value as? String ?? "", "")
        let share = ui.app.buttons["recap.share"]
        try ui.reveal(share)
        try ui.tap(share)
        try ui.wait("The All Time preview carries the saved-history scope") {
            ui.element("recap.share.previewImage").label == "Stats Card, All available history"
        }
        XCTAssertTrue(ui.app.buttons["recap.share.previewShare"].exists)
        try ui.tap(ui.app.buttons["recap.share.done"])
        try ui.reveal(ui.app.buttons["recap.window.week"], direction: .down)
        try ui.tap(ui.app.buttons["recap.window.week"])
        try ui.wait("Rolling windows retain their previous identity and scope") {
            ui.element("recap.totalListening").label == "89 minutes listened in the last 7 days"
                && !ui.element("recap.historyCoverage").exists
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "recap-review")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
