import XCTest

/// R20 super-like extras over `--r19-fixture` (Starlight super liked, Heartless a plain like): the Home shelf and its
/// see-all link into Liked Songs on the Super Liked chip, the row glyph, the Storage count and hiding the shelf in
/// Customize Home. One phone workflow in dark and light.
@MainActor
final class GanaBajanaR20UITests: XCTestCase {
    private let heartless = "heartless19"   // liked, not super liked
    private let starlight = "starlight19"   // the fixture's only super like
    private let plainLikes = ["heartless19", "landslide19", "blackbird19", "fireflies19", "paparazzi19"]
    private let shelfGroup = "home.group.superLiked"
    private let shelfSwitch = "home.customization.show.superLiked"

    override func setUpWithError() throws { continueAfterFailure = false }

    func testSuperLikedShelfSeeAllRowGlyphStorageCountAndHidingInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }

            try step("Home / \(appearance): the Super Liked shelf shows Starlight and no plain like", ui) {
                let header = ui.app.buttons["home.superLiked.seeAll"]
                try target(header, ui)
                XCTAssertEqual(header.label, "Super Liked, see all")
                let group = ui.element(shelfGroup)
                XCTAssertTrue(group.exists)
                let card = group.buttons["track.card.\(starlight)"]
                try ui.wait("The shelf must list the fixture's super like") { card.exists }
                XCTAssertTrue(card.label.contains("Starlight"))
                for id in plainLikes {
                    XCTAssertFalse(ui.app.buttons["track.card.\(id)"].exists, "\(id) is a plain like and stays off the shelf")
                }
                XCTAssertTrue(ui.app.buttons["Play Super Liked"].exists)
                XCTAssertLessThan(header.frame.maxY, card.frame.minY + 1e-6, "The header sits above its cards")
            }
            capture("home-shelf", appearance, ui)

            try step("See all / \(appearance): opens Liked Songs on the Super Liked chip", ui) {
                try ui.tap(ui.app.buttons["home.superLiked.seeAll"])
                try ui.wait("See all must open Liked Songs") { ui.app.navigationBars["Liked Songs"].exists }
                let chip = ui.app.buttons["library.likes.filter.superLiked"]
                try ui.wait("The Super Liked chip must start selected") { chip.exists && chip.isSelected }
                XCTAssertFalse(ui.app.buttons["library.likes.filter.all"].isSelected)
                try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "1 of 6 songs")
                try ui.reveal(ui.app.buttons["track.play.\(starlight)"])
                XCTAssertFalse(ui.app.buttons["track.play.\(heartless)"].exists)
            }
            capture("see-all-super-liked-chip", appearance, ui)

            try step("Rows / \(appearance): Starlight carries the bolt glyph, Heartless does not", ui) {
                let all = ui.app.buttons["library.likes.filter.all"]
                try ui.reveal(all, direction: .down)
                try ui.tap(all)
                try ui.wait("All must show every like") { all.isSelected }
                try ui.expectLabel(ui.app.staticTexts["library.likes.count"], "6 songs")
                let starlightRow = ui.app.buttons["track.play.\(starlight)"]
                try ui.reveal(starlightRow)
                let glyph = ui.element("track.superLiked.\(starlight)")
                try ui.wait("The super liked row must show its glyph after the duration") { glyph.exists }
                XCTAssertTrue(ui.accessibleText(starlightRow).contains("Super liked"))
                let duration = ui.element("track.duration.\(starlight)")
                XCTAssertTrue(duration.exists)
                XCTAssertLessThanOrEqual(duration.frame.maxX, glyph.frame.minX + 1e-6, "The glyph follows the duration")
                let heartlessRow = ui.app.buttons["track.play.\(heartless)"]
                try ui.reveal(heartlessRow)
                XCTAssertTrue(heartlessRow.exists)
                XCTAssertFalse(ui.element("track.superLiked.\(heartless)").exists, "A plain like has no tier glyph")
                XCTAssertFalse(ui.accessibleText(heartlessRow).contains("Super liked"))
            }
            capture("rows-glyph", appearance, ui)

            try step("Storage / \(appearance): Super Liked counts one, directly after Liked Songs", ui) {
                try ui.tap(ui.app.navigationBars["Liked Songs"].buttons.firstMatch)
                try ui.wait("Back must return to Home") { ui.app.buttons["home.settings"].exists }
                try openStorage(ui)
                let likes = ui.element("storage.library.likes")
                let superLikes = ui.element("storage.library.superLikes")
                let playlists = ui.element("storage.library.playlists")
                try ui.reveal(superLikes, maxSwipes: 16)
                XCTAssertTrue(ui.accessibleText(likes).contains("Liked Songs"))
                XCTAssertTrue(ui.accessibleText(likes).contains("6"))
                XCTAssertTrue(ui.accessibleText(superLikes).contains("Super Liked"))
                XCTAssertTrue(ui.accessibleText(superLikes).contains("1"))
                XCTAssertGreaterThanOrEqual(superLikes.frame.height + 1e-6, 44)
                XCTAssertLessThanOrEqual(likes.frame.maxY, superLikes.frame.minY + 1e-6, "Super Liked follows Liked Songs")
                XCTAssertLessThanOrEqual(superLikes.frame.maxY, playlists.frame.minY + 1e-6, "Playlists comes after it")
            }
            capture("storage-count", appearance, ui)

            try step("Customize Home / \(appearance): hiding the shelf removes it from Home", ui) {
                try ui.returnToSettingsRoot()
                try openCustomizeHome(ui)
                let row = ui.app.switches[shelfSwitch]
                try ui.reveal(row, maxSwipes: 24)
                XCTAssertTrue(row.exists)
                XCTAssertTrue(row.label.hasPrefix("Super Liked"), "The row uses the section's title: \(row.label)")
                XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 44)
                try ui.setSwitch(shelfSwitch, to: false)
                try ui.closeHomeCustomization()
                try ui.wait("A hidden Super Liked section must leave Home") { !ui.element(self.shelfGroup).exists }
                XCTAssertFalse(ui.app.buttons["track.card.\(starlight)"].exists)
                XCTAssertFalse(ui.app.buttons["home.superLiked.seeAll"].exists)
            }
            capture("home-shelf-hidden", appearance, ui)

            try step("Customize Home / \(appearance): showing it again brings the shelf back", ui) {
                try ui.openHomeCustomization()
                try ui.expectSwitch(shelfSwitch, isOn: false)
                try ui.setSwitch(shelfSwitch, to: true)
                try ui.closeHomeCustomization()
                try ui.reveal(ui.app.buttons["home.superLiked.seeAll"])
                try ui.wait("The shelf must return with its super like") {
                    ui.element(self.shelfGroup).buttons["track.card.\(self.starlight)"].exists
                }
            }
        }
    }

    // MARK: - Launch and navigation

    private func launch(_ appearance: String) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "r20-\(appearance)")
        addTeardownBlock { await ui.finish() }
        try ui.launch(additionalArguments: ["--r19-fixture"] + (appearance == "light" ? ["--light"] : []))
        return ui
    }

    private func openStorage(_ ui: AppUITestDriver) throws {
        try ui.openSettings()
        try ui.openSettingsPage(.library)
        let storage = ui.app.buttons["settings.storage"]
        try ui.reveal(storage, maxSwipes: 16)
        try ui.tap(storage)
        try ui.wait("Settings must open Storage") { ui.app.navigationBars["Storage"].exists }
    }

    /// From the Settings root, the Discovery page's Customize Home row; `openHomeCustomization` needs Home first.
    private func openCustomizeHome(_ ui: AppUITestDriver) throws {
        try ui.openSettingsPage(.discovery)
        let link = ui.app.buttons["settings.customizeHome"]
        try ui.reveal(link, maxSwipes: 24)
        try ui.tap(link)
        try ui.wait("Settings must open Customize Home") { ui.app.navigationBars["Customize Home"].exists }
    }

    // MARK: - Shared assertions

    private func target(_ element: XCUIElement, _ ui: AppUITestDriver, file: StaticString = #filePath, line: UInt = #line) throws {
        try ui.reveal(element)
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, element.identifier, file: file, line: line)
    }

    private func step(_ name: String, _ ui: AppUITestDriver, perform action: () throws -> Void) throws {
        try XCTContext.runActivity(named: "R20: \(name)") { _ in
            do { try action() }
            catch {
                ui.note("r20-action-failure", """
                Action: \(name)
                Store: \(ui.storeName)
                Likes count: \(ui.accessibleText(ui.app.staticTexts["library.likes.count"]))
                Shelf: \(ui.element(shelfGroup).exists ? "present" : "absent")
                Toast: \(ui.accessibleText(ui.element("message.text")))
                Failure: \(error.localizedDescription)
                """)
                throw error
            }
        }
    }

    private func capture(_ stage: String, _ appearance: String, _ ui: AppUITestDriver) {
        let width = ui.app.windows.firstMatch.frame.width
        let device = width >= 700 ? "ipad" : width <= 390 ? "small-phone" : "phone"
        ui.capture("r20-\(device)-\(appearance)-\(stage)")
    }
}
