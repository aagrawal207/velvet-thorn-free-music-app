import Foundation
import XCTest

@MainActor
final class GanaBajanaDailyMixesUITests: XCTestCase {
    private struct Mix {
        let id: String
        let title: String
        let caption: String
    }

    // `--daily-mixes-fixture` order; links are `mix.<id>` and Play controls `mix.play.<id>`.
    private static let mixes = [Mix(id: "mix.discoverWeekly", title: "Discover Weekly", caption: "New every Monday"),
                                Mix(id: "mix.dailyMix", title: "Daily Mix 1", caption: "Arijit Singh, Alka Yagnik and more"),
                                Mix(id: "mix.dailyMix2", title: "Daily Mix 2", caption: "Hip hop"),
                                Mix(id: "mix.dailyMix3", title: "Daily Mix 3", caption: "Fixture Tamil Composer and Fixture Tamil Singer")]

    override func setUpWithError() throws { continueAfterFailure = false }

    func testMadeForYouShowsDiscoverWeeklyThenThreeDailyMixesAndOpensDailyMixTwo() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "daily-mixes")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--daily-mixes-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"])

        let mixes = Self.mixes
        let cards = mixes.map { ui.app.buttons["mix.\($0.id)"] }
        try ui.reveal(cards[0], maxSwipes: 10)
        try ui.wait("Discover Weekly and all three Daily Mixes must be in the Made for You grid") {
            cards.allSatisfy(\.exists)
        }
        // Vertical reveals only: no mix may need a sideways swipe to come into view.
        try ui.reveal(cards[3])
        expectLabels(cards)

        let window = ui.app.windows.firstMatch.frame
        let columns = window.width >= 700 ? 4 : 2
        let frames = cards.map(\.frame)
        for index in frames.indices {
            let mix = mixes[index]
            XCTAssertEqual(frames[index].width, frames[0].width, accuracy: 1, "Every mix card has the same width")
            if index % columns > 0 {
                let left = frames[index - 1]
                XCTAssertGreaterThan(frames[index].minX, left.maxX - 1e-6, "\(mix.title) must sit to the right of \(mixes[index - 1].title)")
                XCTAssertEqual(frames[index].minY, left.minY, accuracy: 1, "\(mix.title) shares \(mixes[index - 1].title)'s row")
                XCTAssertEqual(frames[index].height, left.height, accuracy: 1, "Cards in one row share one height")
            }
            if index >= columns {
                let above = frames[index - columns]
                XCTAssertGreaterThan(frames[index].minY, above.maxY - 1e-6, "\(mix.title) must start a row below \(mixes[index - columns].title)")
                XCTAssertEqual(frames[index].minX, above.minX, accuracy: 1, "\(mix.title) stays in \(mixes[index - columns].title)'s column")
            }
        }
        for (card, mix) in zip(cards, mixes) {
            XCTAssertTrue(card.isHittable, "\(mix.title) must be reachable together with every other mix")
            XCTAssertGreaterThanOrEqual(card.frame.minX + 1e-6, window.minX, "\(mix.title) starts inside the window")
            XCTAssertLessThanOrEqual(card.frame.maxX, window.maxX + 1e-6, "\(mix.title) ends inside the window")
            XCTAssertGreaterThanOrEqual(card.frame.height + 1e-6, 44, "\(mix.title) keeps a 44-point target")
            expectPlayTarget(on: card, of: mix, ui: ui)
        }
        let grid = ui.element("home.mixes")
        XCTAssertTrue(grid.exists, "Made for You must be one grid")
        let scrollers = ui.app.scrollViews.containing(.button, identifier: "mix.\(mixes[3].id)").allElementsBoundByIndex
        XCTAssertFalse(scrollers.isEmpty)
        for scroller in scrollers {
            // A carousel's own scroller would be no taller than its cards; only Home's vertical scroller may hold them.
            XCTAssertGreaterThan(scroller.frame.height, grid.frame.height, "The mixes must not sit in a horizontal carousel")
        }
        ui.capture("home-made-for-you-grid-\(device(ui))")

        // Play is its own control: it starts the mix from its first song and leaves Home in place.
        try ui.tap(ui.app.buttons["mix.play.\(mixes[2].id)"])
        try ui.wait("Daily Mix 2's Play control must start its first song") {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Hiphop fixture song 1, Fixture Rapper")
        }
        XCTAssertFalse(ui.app.staticTexts["collection.title"].exists, "Play must not open the mix page")

        try ui.reveal(cards[2])
        try ui.tap(cards[2])
        let content = ui.app.scrollViews.containing(.staticText, identifier: "collection.title").firstMatch
        try ui.wait("Daily Mix 2 must open its own mix page") {
            content.exists && content.staticTexts["collection.title"].label == "Daily Mix 2"
        }
        let rows = content.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play.fixture.mix.hiphop."))
        try ui.wait("The Daily Mix 2 page must list its songs") { rows.count > 0 }
        XCTAssertEqual(content.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play.fixture.mix.bollywood.")).count, 0,
                       "Daily Mix 2 must not show Daily Mix 1's songs")
        ui.capture("home-daily-mix-2-page-\(device(ui))")
    }

    func testMadeForYouStacksOneMixPerRowAtAccessibilityTextSizes() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "daily-mixes-ax")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--daily-mixes-fixture", "-UIPreferredContentSizeCategoryName",
                                            "UICTContentSizeCategoryAccessibilityXXXL"])

        let mixes = Self.mixes
        let cards = mixes.map { ui.app.buttons["mix.\($0.id)"] }
        try ui.reveal(cards[0], maxSwipes: 16)
        try ui.wait("Discover Weekly and all three Daily Mixes must be in the Made for You grid") {
            cards.allSatisfy(\.exists)
        }
        expectLabels(cards)

        // Read in one pass, so every frame shares the same scroll offset.
        let frames = cards.map(\.frame)
        let window = ui.app.windows.firstMatch.frame
        let column = min(window.width, window.width >= 700 ? 1000 : 760)
        for (index, mix) in mixes.enumerated() {
            XCTAssertEqual(frames[index].minX, frames[0].minX, accuracy: 1, "\(mix.title) stays in the single column")
            XCTAssertEqual(frames[index].width, column - 40, accuracy: 1, "\(mix.title) spans the column inside its insets")
            XCTAssertGreaterThanOrEqual(frames[index].height + 1e-6, 44, "\(mix.title) keeps a 44-point target")
            if index > 0 {
                XCTAssertGreaterThan(frames[index].minY, frames[index - 1].maxY - 1e-6, "\(mix.title) stacks below \(mixes[index - 1].title)")
            }
        }
        for (card, mix) in zip(cards, mixes) {
            try ui.reveal(card, maxSwipes: 16)
            try ui.requireHittable(card)
            expectPlayTarget(on: card, of: mix, ui: ui)
        }
        ui.capture("home-made-for-you-accessibility-\(device(ui))")
    }

    private func expectLabels(_ cards: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        for (card, mix) in zip(cards, Self.mixes) {
            XCTAssertTrue(card.label.contains(mix.title), "Card label \(card.label) must name \(mix.title)", file: file, line: line)
            XCTAssertTrue(card.label.contains(mix.caption), "Card label \(card.label) must carry its focus \(mix.caption)",
                          file: file, line: line)
        }
    }

    /// The Play control is its own button over the card, outside the browse link, with a full 44-point target.
    private func expectPlayTarget(on card: XCUIElement, of mix: Mix, ui: AppUITestDriver,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let play = ui.app.buttons["mix.play.\(mix.id)"]
        XCTAssertTrue(play.exists && play.isHittable, "\(mix.title) must keep a reachable Play control", file: file, line: line)
        XCTAssertEqual(play.label, "Play \(mix.title)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(play.frame.width + 1e-6, 44, "\(mix.title) Play target width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(play.frame.height + 1e-6, 44, "\(mix.title) Play target height", file: file, line: line)
        XCTAssertTrue(card.frame.insetBy(dx: -1, dy: -1).contains(play.frame), "\(mix.title) Play sits on its own card",
                      file: file, line: line)
    }

    private func device(_ ui: AppUITestDriver) -> String {
        let width = ui.app.windows.firstMatch.frame.width
        return width >= 700 ? "ipad" : width <= 390 ? "small-phone" : "phone"
    }
}
