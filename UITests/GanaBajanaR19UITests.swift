import XCTest

/// Super Likes over `--r19-fixture`: the heart's tap/hold, the song and More menus, the Liked Songs chip and swipe
/// actions, the three-way Download Liked Songs scope with the Downloads filters, and the TipKit hint after a first like.
@MainActor
final class GanaBajanaR19UITests: XCTestCase {
    // DebugR19Fixture ids; bare ids are exactly 11 characters so the download queue accepts them.
    private let heartless = "heartless19"   // liked, not super liked, not downloaded; `--player` opens here
    private let sunflower = "sunflower19"   // not liked, playable; one Next after Heartless in the queue
    private let landslide = "landslide19"   // liked, downloaded
    private let blackbird = "blackbird19"   // liked, downloaded
    private let starlight = "starlight19"   // super liked, not downloaded
    private let fireflies = "fireflies19"   // liked
    private let paparazzi = "paparazzi19"   // liked
    private let nightcall = "nightcall19"   // not liked, downloaded
    private let tipTitle = "Hold to Super Like"
    private let tipMessage = "Super likes count more in your mixes and can download on their own."
    private let superLikedEmptyHint = "Hold the heart on a song you love, or choose Super Like from its menu."

    override func setUpWithError() throws { continueAfterFailure = false }

    func testPlayerHeartHoldPromotesTapRemovesAndTapRelikesInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance, player: true)
            defer { ui.finish() }
            try ui.expectCurrentTrack(heartless)
            let title = ui.app.staticTexts["player.track.\(heartless)"]
            XCTAssertEqual(title.label, "Heartless")
            let heart = ui.app.buttons["player.like"]
            try target(heart, ui)
            try ui.expectLabel(heart, "Unlike this song")
            try ui.expectValue(heart, "Liked")
            capture("heart-liked", appearance, ui)

            try step("Heart / \(appearance): a 0.6 s hold promotes the like to a super like", ui) {
                heart.press(forDuration: 0.6)
                try ui.expectValue(heart, "Super Liked")
                try ui.expectLabel(heart, "Unlike this song")
            }
            XCTAssertTrue(heart.isSelected)
            capture("heart-super-liked", appearance, ui)

            try step("Heart / \(appearance): a tap on a super liked song removes the like and its tier", ui) {
                try ui.tap(heart)
                try ui.expectLabel(heart, "Like this song")
                try ui.wait("An unliked heart reports no tier value") {
                    heart.exists && (heart.value as? String ?? "").isEmpty
                }
            }
            XCTAssertFalse(heart.isSelected)
            capture("heart-unliked", appearance, ui)

            try step("Heart / \(appearance): a tap likes the song again as a plain like", ui) {
                try ui.tap(heart)
                try ui.expectLabel(heart, "Unlike this song")
                try ui.expectValue(heart, "Liked")
            }
            XCTAssertTrue(ui.app.buttons["player.like"].exists, "The heart must keep its identifier through every state")
            try ui.expectCurrentTrack(heartless)
            XCTAssertEqual(title.label, "Heartless", "Reacting must not change the current song")
            try target(heart, ui)
        }
    }

    func testSongMenuSuperLikeAndPlayerMoreChangeToLikeInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try openLikedSongs(ui)
            let count = ui.app.staticTexts["library.likes.count"]
            try ui.expectLabel(count, "6 songs")

            try step("Menu / \(appearance): the song menu promotes Heartless with Super Like", ui) {
                try ui.reveal(ui.app.buttons["track.play.\(heartless)"])
                let options = ui.app.buttons["track.options.\(heartless)"]
                try target(options, ui)
                try ui.tap(options)
                let remove = ui.app.buttons["Remove from Liked Songs"]
                let superLike = ui.app.buttons["Super Like"]
                try ui.wait("A liked song's menu offers Remove from Liked Songs, then Super Like") {
                    remove.exists && superLike.exists
                }
                XCTAssertFalse(ui.app.buttons["Change to Like"].exists)
                XCTAssertFalse(ui.app.buttons["Like Song"].exists)
                try ui.requireHittable(superLike)
                capture("menu-super-like", appearance, ui)
                try ui.tap(superLike)
                try ui.wait("Choosing Super Like closes the menu") { !superLike.exists }
            }

            try step("Menu / \(appearance): Super Liked lists the promotion first and the fixture super like", ui) {
                try selectLikedFilter("superLiked", ui)
                try ui.expectLabel(count, "2 of 6 songs")
                let promoted = ui.app.buttons["track.play.\(heartless)"]
                let existing = ui.app.buttons["track.play.\(starlight)"]
                try ui.reveal(promoted)
                try ui.reveal(existing)
                XCTAssertLessThan(promoted.frame.minY, existing.frame.minY, "A promotion is the newest reaction")
                for id in [landslide, blackbird, fireflies, paparazzi] {
                    XCTAssertFalse(ui.app.buttons["track.play.\(id)"].exists, "\(id) is not super liked")
                }
            }
            capture("menu-super-liked-chip", appearance, ui)

            try step("More / \(appearance): playing the fixture super like and opening More shows Change to Like", ui) {
                let row = ui.app.buttons["track.play.\(starlight)"]
                try ui.reveal(row)
                try ui.tap(row)
                try ui.wait("Playing Starlight must update the mini-player") {
                    ui.app.buttons["miniPlayer.open"].exists && ui.app.buttons["miniPlayer.open"].label.contains("Starlight")
                }
                try ui.openPlayer()
                try ui.expectCurrentTrack(starlight)
                try ui.expectValue(ui.app.buttons["player.like"], "Super Liked")
                try ui.openPlayerMenu()
                let more = ui.app.buttons["player.options.superLike"]
                try target(more, ui)
                try ui.expectLabel(more, "Change to Like")
                XCTAssertEqual(more.value as? String, "Keeps the like, drops the extra weight.")
                capture("more-change-to-like", appearance, ui)
                try ui.tap(more)
                try ui.wait("Change to Like must dismiss the More sheet") {
                    !ui.element("player.options.sheet").exists && !more.exists
                }
            }
            let heart = ui.app.buttons["player.like"]
            try ui.expectValue(heart, "Liked")
            try ui.expectLabel(heart, "Unlike this song")
            capture("more-demoted-heart", appearance, ui)
        }
    }

    func testLikedSongsSuperLikedChipSwipeActionsAndEmptyStateInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try openLikedSongs(ui)
            let count = ui.app.staticTexts["library.likes.count"]
            let chips = [("all", "All"), ("superLiked", "Super Liked"), ("downloaded", "Downloaded"), ("onDevice", "On This Device")]
            try step("Chips / \(appearance): All, Super Liked, Downloaded, On This Device in that order", ui) {
                for (key, title) in chips {
                    let chip = likedFilter(key, ui)
                    try ui.reveal(chip, direction: .down)
                    try target(chip, ui)
                    XCTAssertEqual(chip.label, title)
                }
                assertOrdered(chips.map { likedFilter($0.0, ui) })
                XCTAssertTrue(likedFilter("all", ui).isSelected)
                try ui.expectLabel(count, "6 songs")
            }

            try step("Chips / \(appearance): Super Liked shows exactly the fixture's super like", ui) {
                try selectLikedFilter("superLiked", ui)
                try ui.expectLabel(count, "1 of 6 songs")
                try ui.reveal(ui.app.buttons["track.play.\(starlight)"])
                for id in [heartless, landslide, blackbird, fireflies, paparazzi] {
                    XCTAssertFalse(ui.app.buttons["track.play.\(id)"].exists, "\(id) is a plain like")
                }
            }
            capture("chip-super-liked", appearance, ui)

            try step("Swipe / \(appearance): the leading swipe on a plain like offers Super Like", ui) {
                try selectLikedFilter("all", ui)
                let row = ui.app.buttons["track.play.\(heartless)"]
                let promote = try revealLeadingAction(on: row, id: "library.superLike.\(heartless)", ui)
                try target(promote, ui, reveal: false)
                XCTAssertEqual(promote.label, "Super Like")
                capture("swipe-super-like", appearance, ui)
                try ui.tap(promote)
                try ui.wait("The swipe action closes after promoting") { !promote.exists }
                try selectLikedFilter("superLiked", ui)
                try ui.expectLabel(count, "2 of 6 songs")
                try ui.reveal(ui.app.buttons["track.play.\(heartless)"])
                try ui.reveal(ui.app.buttons["track.play.\(starlight)"])
            }

            try step("Swipe / \(appearance): Change to Like on both super likes empties the filter", ui) {
                for id in [heartless, starlight] {
                    let row = ui.app.buttons["track.play.\(id)"]
                    let demote = try revealLeadingAction(on: row, id: "library.superLike.\(id)", ui)
                    try target(demote, ui, reveal: false)
                    XCTAssertEqual(demote.label, "Change to Like")
                    try ui.tap(demote)
                    try ui.wait("A demoted song leaves the Super Liked filter") { !row.exists }
                }
                let empty = ui.element("library.likes.filter.empty")
                try ui.reveal(empty)
                let hint = superLikedEmptyHint
                try ui.wait("The Super Liked empty state explains how to add one") {
                    ui.app.staticTexts["No Super Likes Yet"].exists && ui.app.staticTexts[hint].exists
                }
                try ui.expectLabel(count, "0 of 6 songs")
            }
            capture("chip-super-liked-empty", appearance, ui)
            try selectLikedFilter("all", ui)
            try ui.expectLabel(count, "6 songs")
        }
    }

    func testSuperLikedOnlyDownloadScopeQueuesBacklogAndFiltersDownloadsInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance)
            defer { ui.finish() }
            try step("Scope / \(appearance): Settings > Library & iCloud offers Off, Super Liked Only and All Liked", ui) {
                try ui.openSettings()
                try ui.openSettingsPage(.library)
                let menu = ui.app.buttons["settings.autoDownloadLiked"]
                try target(menu, ui)
                XCTAssertEqual(menu.label, "Download Liked Songs")
                try ui.expectValue(menu, "Off")
                try chooseScope(menu, id: "settings.autoDownloadLiked", choice: "superLiked", title: "Super Liked Only", ui)
                let alert = ui.app.alerts["Download Super Liked Songs?"]
                try ui.wait("Super Liked Only confirms its one-song backlog") {
                    alert.exists && alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                        "1 super liked song will be queued")).firstMatch.exists
                }
                capture("scope-confirm-super-liked", appearance, ui)
                try confirm(alert, action: "settings.autoDownloadLiked.confirm", label: "Download", ui)
                try ui.expectValue(menu, "Super Liked Only")
                try ui.tap(ui.app.buttons["settings.done"])
                try ui.wait("Settings must close") { !ui.app.buttons["settings.done"].exists }
            }

            try openDownloads(ui)
            let summary = ui.app.staticTexts["downloads.summary"]
            try step("Downloads / \(appearance): the queued super like joins the three fixture downloads", ui) {
                let failure = ui.element("message.text")
                try ui.wait("The staged copy must be promoted into the download tier", timeout: 120) {
                    (summary.exists && summary.label.hasPrefix("4 songs on this device"))
                        || ui.accessibleText(failure).contains("R19 fixture audio")
                }
                XCTAssertTrue(summary.label.hasPrefix("4 songs on this device"), ui.accessibleText(failure))
            }
            let filters = [("all", "All"), ("superLiked", "Super Liked"), ("liked", "Liked"), ("notLiked", "Not Liked")]
            try step("Downloads / \(appearance): All, Super Liked, Liked, Not Liked chips", ui) {
                for (key, title) in filters {
                    let chip = downloadsFilter(key, ui)
                    try ui.reveal(chip, direction: .down)
                    try target(chip, ui)
                    XCTAssertEqual(chip.label, title)
                }
                assertOrdered(filters.map { downloadsFilter($0.0, ui) })
                XCTAssertTrue(downloadsFilter("all", ui).isSelected)
            }
            try step("Downloads / \(appearance): Super Liked lists only the promoted download", ui) {
                try selectDownloadsFilter("superLiked", ui)
                try expectDownloads(present: [starlight], absent: [landslide, blackbird, nightcall], ui)
            }
            capture("downloads-super-liked", appearance, ui)
            try step("Downloads / \(appearance): Not Liked keeps the unliked download and Liked the liked ones", ui) {
                try selectDownloadsFilter("notLiked", ui)
                try expectDownloads(present: [nightcall], absent: [landslide, blackbird, starlight], ui)
                try selectDownloadsFilter("liked", ui)
                try expectDownloads(present: [landslide, blackbird, starlight], absent: [nightcall], ui)
                try selectDownloadsFilter("all", ui)
                try expectDownloads(present: [landslide, blackbird, starlight, nightcall], absent: [], ui)
            }

            try step("Chips / \(appearance): Super Liked Only keeps Downloaded and On This Device in Liked Songs", ui) {
                try ui.tap(ui.app.navigationBars["Downloads"].buttons.firstMatch)
                try ui.wait("Back must return to the library") { ui.app.buttons["library.likes"].exists }
                try openLikedSongs(ui)
                for key in ["all", "superLiked", "downloaded", "onDevice"] {
                    let chip = likedFilter(key, ui)
                    try ui.reveal(chip, direction: .down)
                    XCTAssertTrue(chip.exists, "\(key) stays available under Super Liked Only")
                }
                let menu = ui.app.buttons["library.likes.autoDownload"]
                try target(menu, ui)
                try ui.expectValue(menu, "Super Liked Only")
            }
            capture("liked-songs-super-liked-only", appearance, ui)

            try step("Chips / \(appearance): All Liked confirms the remaining backlog and hides the copy chips", ui) {
                let menu = ui.app.buttons["library.likes.autoDownload"]
                try chooseScope(menu, id: "library.likes.autoDownload", choice: "liked", title: "All Liked", ui)
                let alert = ui.app.alerts["Download Liked Songs?"]
                try ui.wait("All Liked confirms the three likes still off this device") {
                    alert.exists && alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
                        "3 liked songs will be queued")).firstMatch.exists
                }
                try confirm(alert, action: "library.likes.autoDownload.confirm", label: "Download", ui)
                try ui.expectValue(menu, "All Liked")
                let all = likedFilter("all", ui)
                let superLiked = likedFilter("superLiked", ui)
                let downloaded = likedFilter("downloaded", ui)
                let onDevice = likedFilter("onDevice", ui)
                try ui.wait("All Liked leaves only the All and Super Liked chips, with All selected") {
                    all.exists && all.isSelected && superLiked.exists && !downloaded.exists && !onDevice.exists
                }
                let status = ui.app.staticTexts["library.likes.downloadStatus"]
                try ui.reveal(status, direction: .down)
                try ui.wait("Every like promotes from its staged copy", timeout: 60) {
                    status.label.hasPrefix("6 of 6 downloaded")
                }
            }
            capture("liked-songs-all-liked", appearance, ui)
        }
    }

    func testHoldToSuperLikeTipAppearsAfterFirstLikeAndDismissesInLightAndDark() throws {
        for appearance in ["dark", "light"] {
            let ui = try launch(appearance, player: true, arguments: ["--show-tips"])
            defer { ui.finish() }
            try ui.expectCurrentTrack(heartless)
            let heart = ui.app.buttons["player.like"]
            try step("Tip / \(appearance): Next reaches the unliked fixture song without a tip", ui) {
                XCTAssertFalse(tipTitleElement(ui).exists, "No tip before any like")
                let next = ui.app.buttons["player.next"]
                try ui.reveal(next)
                try ui.tap(next)
                try ui.expectCurrentTrack(sunflower)
                try ui.expectLabel(heart, "Like this song")
                try assertTipStaysAbsent(ui, for: 2)
            }
            try step("Tip / \(appearance): the first like shows Hold to Super Like anchored to the heart", ui) {
                try target(heart, ui)
                try ui.tap(heart)
                try ui.expectLabel(heart, "Unlike this song")
                let title = tipTitleElement(ui)
                let message = ui.app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", tipMessage)).firstMatch
                try ui.wait("TipKit must show the Hold to Super Like tip after the first like", timeout: 10) {
                    title.exists
                }
                try ui.wait("The tip carries its message") { message.exists }
            }
            capture("tip-shown", appearance, ui)
            try step("Tip / \(appearance): its close control dismisses it", ui) {
                try dismissTip(ui)
            }
            try step("Tip / \(appearance): opening and closing More does not bring it back", ui) {
                try ui.openPlayerMenu()
                try ui.closeSheet("Song Options")
                try assertTipStaysAbsent(ui, for: 3)
            }
            try ui.expectValue(heart, "Liked")
            capture("tip-dismissed", appearance, ui)
        }
    }

    // MARK: - Launch

    private func launch(_ appearance: String, player: Bool = false, arguments: [String] = []) throws -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "r19-\(appearance)")
        addTeardownBlock { await ui.finish() }
        let fixture = ["--r19-fixture"] + (appearance == "light" ? ["--light"] : []) + arguments
        if player {
            // The full player covers the tab bar, so the shared launch helper's Home-tab wait cannot be used.
            XCUIDevice.shared.orientation = .portrait
            ui.app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player"] + fixture
                + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            ui.app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
            ui.app.launch()
            try ui.requireHittable(ui.app.buttons["player.close"], timeout: 25)
        } else {
            try ui.launch(additionalArguments: fixture)
        }
        return ui
    }

    // MARK: - Library and Downloads

    private func openLikedSongs(_ ui: AppUITestDriver) throws {
        try ui.selectTab("library")
        let likes = ui.app.buttons["library.likes"]
        try ui.reveal(likes)
        try ui.tap(likes)
        try ui.wait("Liked Songs must open") { ui.app.navigationBars["Liked Songs"].exists }
    }

    private func openDownloads(_ ui: AppUITestDriver) throws {
        try ui.selectTab("library")
        let downloads = ui.app.buttons["library.downloads"]
        try ui.reveal(downloads)
        try target(downloads, ui)
        try ui.tap(downloads)
        try ui.wait("Downloads must open") { ui.app.navigationBars["Downloads"].exists }
    }

    private func likedFilter(_ key: String, _ ui: AppUITestDriver) -> XCUIElement {
        ui.app.buttons["library.likes.filter.\(key)"]
    }

    private func downloadsFilter(_ key: String, _ ui: AppUITestDriver) -> XCUIElement {
        ui.app.buttons["downloads.filter.\(key)"]
    }

    /// Chips sit in the list header, which a revealed row can push off the top; scroll back before tapping.
    private func selectLikedFilter(_ key: String, _ ui: AppUITestDriver) throws {
        try selectChip(likedFilter(key, ui), ui)
    }

    private func selectDownloadsFilter(_ key: String, _ ui: AppUITestDriver) throws {
        try selectChip(downloadsFilter(key, ui), ui)
    }

    private func selectChip(_ chip: XCUIElement, _ ui: AppUITestDriver) throws {
        try ui.reveal(chip, direction: .down)
        try ui.tap(chip)
        try ui.wait("The \(chip.identifier) chip must report its selection") { chip.exists && chip.isSelected }
    }

    private func expectDownloads(present: [String], absent: [String], _ ui: AppUITestDriver) throws {
        for id in present {
            let row = ui.app.buttons["downloads.play.\(id)"]
            try ui.reveal(row)
            XCTAssertTrue(ui.accessibleText(row).contains("Downloaded"), "\(id) must be listed as downloaded")
        }
        for id in absent {
            XCTAssertFalse(ui.app.buttons["downloads.play.\(id)"].exists, "\(id) must be hidden by the current filter")
        }
    }

    /// Reveals a row's leading swipe action without the full-swipe travel that would run it: a 160-point pull
    /// stays under half of any phone row while comfortably exceeding the action's own width.
    private func revealLeadingAction(on row: XCUIElement, id: String, _ ui: AppUITestDriver) throws -> XCUIElement {
        try ui.reveal(row)
        try ui.requireHittable(row)
        let action = ui.app.buttons[id]
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 24, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 160, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.1)
        if !waitBriefly(for: action, timeout: 3) {
            // A pull the list rejected leaves the row closed; the system swipe is the second attempt.
            row.swipeRight()
        }
        try ui.wait("The leading swipe must reveal \(id)") { action.exists && action.isHittable }
        return action
    }

    private func waitBriefly(for element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    // MARK: - Download Liked Songs scope

    /// Opens the Download Liked Songs menu row and picks a scope by its per-choice identifier or native label.
    /// Native menu items are system chrome, so only the row itself carries the 44-point assertion.
    private func chooseScope(_ menu: XCUIElement, id: String, choice: String, title: String, _ ui: AppUITestDriver) throws {
        try target(menu, ui)
        try ui.tap(menu)
        let identified = ui.app.buttons["\(id).choice.\(choice)"]
        let native = ui.app.buttons[title]
        try ui.wait("The Download Liked Songs menu must offer \(title)") { identified.exists || native.exists }
        let option = identified.exists ? identified : native
        try ui.requireHittable(option)
        try ui.tap(option)
    }

    /// Alerts expose a parent button and a virtual child with the same identifier and label; tap the owning parent.
    private func confirm(_ alert: XCUIElement, action id: String, label: String, _ ui: AppUITestDriver) throws {
        let predicate = NSPredicate(format: "identifier == %@ AND label == %@", id, label)
        try ui.wait("The \(label) action must appear in the confirmation") {
            alert.exists && alert.buttons.matching(predicate).count > 0
        }
        let matches = alert.buttons.matching(predicate).allElementsBoundByIndex
        let parents = matches.filter { $0.descendants(matching: .button).matching(predicate).count > 0 }
        let candidates = matches.count == 1 ? matches : parents
        guard candidates.count == 1, let parent = candidates.first,
              matches.count == 1 + parent.descendants(matching: .button).matching(predicate).count else {
            throw AppUIWorkflowFailure(message: "Expected one owning alert button for \(id); found \(matches.count) matches and \(parents.count) parents.")
        }
        try target(parent, ui, reveal: false)
        try ui.tap(parent)
        try ui.wait("The confirmation must dismiss after \(label)") { !alert.exists }
    }

    // MARK: - Tip

    private func tipTitleElement(_ ui: AppUITestDriver) -> XCUIElement {
        ui.app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", tipTitle)).firstMatch
    }

    private func assertTipStaysAbsent(_ ui: AppUITestDriver, for interval: TimeInterval) throws {
        let title = tipTitleElement(ui)
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { title.exists } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.isInverted = true
        guard XCTWaiter.wait(for: [expectation], timeout: interval) == .completed else {
            ui.captureFailure("r19-tip-unexpected", detail: "The Hold to Super Like tip appeared without a first like or after it was dismissed.")
            throw AppUIWorkflowFailure(message: "The Hold to Super Like tip must not be visible here.")
        }
    }

    /// TipKit's popover chrome differs between releases: prefer its close control by label, then any control inside
    /// the tip, then a tap outside the callout, which also dismisses a popover.
    private func dismissTip(_ ui: AppUITestDriver) throws {
        let title = tipTitleElement(ui)
        let closeLabels = ["Close", "Dismiss", "Close Tip", "Dismiss Tip", "Close tip", "Dismiss tip"]
        let labelled = ui.app.buttons.matching(NSPredicate(format: "(label IN %@) AND NOT (identifier BEGINSWITH %@)",
                                                            closeLabels, "player.")).allElementsBoundByIndex
        if let close = labelled.first(where: { $0.isHittable }) {
            ui.note("r19-tip-dismissal", "Close control: label \(close.label), identifier \(close.identifier)")
            try ui.tap(close)
        } else if let container = tipContainer(ui),
                  let control = container.buttons.allElementsBoundByIndex.first(where: {
                      !$0.identifier.hasPrefix("player.") && $0.isHittable
                  }) {
            ui.note("r19-tip-dismissal", "Container control: label \(control.label), identifier \(control.identifier)")
            try ui.tap(control)
        } else {
            let callout = (tipContainer(ui)?.frame ?? title.frame).insetBy(dx: -24, dy: -24)
            let window = ui.app.windows.firstMatch
            let artwork = ui.element("player.artwork")
            let candidates = [artwork.exists ? CGPoint(x: artwork.frame.midX, y: artwork.frame.midY) : nil,
                              CGPoint(x: window.frame.midX, y: window.frame.minY + window.frame.height * 0.3)]
            guard let point = candidates.compactMap({ $0 }).first(where: { window.frame.contains($0) && !callout.contains($0) }) else {
                ui.captureFailure("r19-tip-dismissal", detail: "No close control and no stable point outside the tip callout.")
                throw AppUIWorkflowFailure(message: "The Hold to Super Like tip offered no way to dismiss it.")
            }
            ui.note("r19-tip-dismissal", "Outside tap at \(point); callout \(callout)")
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)).tap()
        }
        try ui.wait("The dismissed tip must leave the screen") { !title.exists }
    }

    /// The smallest element that contains the tip title together with at least one control of its own.
    private func tipContainer(_ ui: AppUITestDriver) -> XCUIElement? {
        let holders = ui.app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", tipTitle)).allElementsBoundByIndex
        let window = ui.app.windows.firstMatch.frame
        return holders.filter { holder in
            let frame = holder.frame
            guard !frame.isEmpty, !frame.isNull, frame.width < window.width || frame.height < window.height else { return false }
            return holder.buttons.matching(NSPredicate(format: "NOT (identifier BEGINSWITH %@)", "player.")).count > 0
        }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    // MARK: - Shared assertions

    /// Each control must sit to the right of the previous one on the same row, or on a later row.
    private func assertOrdered(_ elements: [XCUIElement], file: StaticString = #filePath, line: UInt = #line) {
        for (leading, trailing) in zip(elements, elements.dropFirst()) {
            let first = leading.frame, second = trailing.frame
            let sameRow = abs(first.midY - second.midY) < max(first.height, second.height) / 2
            XCTAssertTrue(sameRow ? first.maxX <= second.minX + 1e-6 : first.maxY <= second.minY + 1e-6,
                          "\(leading.identifier) must precede \(trailing.identifier)", file: file, line: line)
        }
    }

    private func target(_ element: XCUIElement, _ ui: AppUITestDriver, reveal: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        if reveal { try ui.reveal(element) }
        try ui.requireHittable(element)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44, element.identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44, element.identifier, file: file, line: line)
        let window = ui.app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX + 1e-6, window.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1e-6, file: file, line: line)
    }

    private func step(_ name: String, _ ui: AppUITestDriver, perform action: () throws -> Void) throws {
        try XCTContext.runActivity(named: "R19: \(name)") { _ in
            do { try action() }
            catch {
                ui.note("r19-action-failure", """
                Action: \(name)
                Store: \(ui.storeName)
                Mini-player: \(ui.accessibleText(ui.app.buttons["miniPlayer.open"]))
                Heart: \(ui.accessibleText(ui.app.buttons["player.like"]))
                Likes count: \(ui.accessibleText(ui.app.staticTexts["library.likes.count"]))
                Downloads summary: \(ui.accessibleText(ui.app.staticTexts["downloads.summary"]))
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
        ui.capture("r19-\(device)-\(appearance)-\(stage)")
    }
}
