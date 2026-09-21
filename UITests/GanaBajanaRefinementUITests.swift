import XCTest
import UIKit

@MainActor
final class GanaBajanaRefinementUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testNativeTabsAndMusicOnlyHome() throws {
        let app = launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["YOUR DISCOVERY LANGUAGES"].exists)
        XCTAssertFalse(app.buttons["Hindi recommendations"].exists)
        XCTAssertFalse(app.buttons["English recommendations"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'music video'")).firstMatch.exists)
        capture(app, "liquid-glass-home-iphone17pro")
        for tab in ["search", "library", "recap", "home"] {
            let button = app.tabBars.buttons[tab.capitalized]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            if tab == "search" {
                XCTAssertFalse(app.keyboards.firstMatch.exists)
                button.tap()
                let done = app.buttons["search.dismissKeyboard"]
                XCTAssertTrue(done.waitForExistence(timeout: 5))
                done.tap()
                waitFor("Keyboard dismissal must restore navigation") { button.isHittable }
            }
            XCTAssertTrue(button.isSelected)
        }
    }

    func testPlayerSwipesDownDislikeSkipsAndAlbumActionMatchesMetadata() throws {
        let app = launch(extra: ["--player"])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        // Fixture songs carry no album id, so the Album shortcut stays visible but disabled.
        XCTAssertTrue(app.buttons["player.album"].exists)
        XCTAssertFalse(app.buttons["player.album"].isEnabled)

        let firstTitle = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.")).firstMatch.identifier
        app.buttons["player.playPause"].tap()
        let playing = NSPredicate { _, _ in MainActor.assumeIsolated { app.buttons["player.playPause"].label == "Pause" } }
        expectation(for: playing, evaluatedWith: nil)
        waitForExpectations(timeout: 15)

        openOptions(app)
        XCTAssertTrue(app.buttons["player.options.album"].exists)
        XCTAssertFalse(app.buttons["player.options.album"].isEnabled)
        reveal(app.buttons["player.options.airplay"], in: app.scrollViews["player.options.list"], app: app)
        XCTAssertFalse(app.buttons["player.options.dislike"].exists, "Liked songs must not offer a dislike action.")
        XCTAssertFalse(app.buttons["Dislike song"].exists)
        XCTAssertFalse(app.buttons["Remove dislike"].exists)
        closeOptions(app)
        let like = app.buttons["player.like"]
        XCTAssertEqual(like.label, "Unlike this song")
        like.tap()
        waitFor("The heading must remove the like before Dislike is offered") { like.label == "Like this song" }

        openOptions(app)
        let dislike = app.buttons["Dislike song"]
        XCTAssertTrue(dislike.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["AirPlay"].exists)
        XCTAssertFalse(app.buttons["Like song"].exists)
        XCTAssertFalse(app.buttons["Add to queue"].exists)
        XCTAssertFalse(app.buttons["Play next"].exists)
        capture(app, "player-menu-iphone17pro")
        reveal(dislike, in: app.scrollViews["player.options.list"], app: app)
        dislike.tap()
        waitFor("Disliking a song must close options") { !app.otherElements["player.options.sheet"].exists }
        let skipped = NSPredicate { _, _ in MainActor.assumeIsolated {
            let current = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.")).firstMatch
            return current.exists && current.identifier != firstTitle
        }}
        expectation(for: skipped, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        app.buttons["player.playPause"].tap()
        capture(app, "player-after-dislike-iphone17pro")

        app.otherElements["player.screen"].swipeDown(velocity: .fast)
        let dismissed = NSPredicate { _, _ in MainActor.assumeIsolated { !close.exists && app.buttons["miniPlayer.open"].exists } }
        expectation(for: dismissed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    func testMiniPlayerOpensFullScreenWithThumbSizedControlsAndBottomOptions() throws {
        let app = launch(extra: ["--player"])
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 10))
        app.buttons["player.close"].tap()
        let mini = app.buttons["miniPlayer.open"]
        waitFor("Closing the player must reveal the mini-player") { mini.exists && !app.buttons["player.close"].exists }
        tapInWindow(mini, app: app)
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 5))
        assertFullScreen(app)
        assertThumbTargets(app)
        XCTAssertFalse(mini.isHittable)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        assertNoVolumeSlider(app)

        let player = app.otherElements["player.screen"]
        let menu = app.buttons["player.menu"]
        let window = app.windows.firstMatch.frame
        XCTAssertLessThan(menu.frame.midY, window.minY + window.height * 0.20)
        XCTAssertGreaterThan(menu.frame.midX, window.minX + window.width * 0.75)
        XCTAssertEqual(menu.frame.midY, app.buttons["player.close"].frame.midY, accuracy: 1)
        XCTAssertEqual(app.buttons.matching(identifier: "player.menu").count, 1)
        for id in ["player.lyrics", "player.album", "player.artist", "player.queue"] {
            XCTAssertGreaterThan(app.buttons[id].frame.midY, window.minY + window.height * 0.80)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.maxY, player.frame.maxY - 12)
        }
        XCTAssertGreaterThan(app.buttons["player.playPause"].frame.midY, window.minY + window.height * 0.70)
        XCTAssertGreaterThan(app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"].frame.minY, window.midY)

        let like = app.buttons["player.like"]
        like.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        waitFor("The edge of the Like target must respond") { like.label == "Like this song" }
        like.tap()
        waitFor("The fixture song must be liked again") { like.label == "Unlike this song" }
        capture(app, "full-screen-player-thumb-controls-iphone17pro")

        openOptions(app)
        let sheet = app.otherElements["player.options.sheet"]
        XCTAssertGreaterThan(sheet.frame.minY, window.minY + window.height * 0.20)
        XCTAssertLessThan(sheet.frame.minY, window.midY + 20)
        XCTAssertGreaterThanOrEqual(sheet.frame.maxY, window.maxY - 40)
        XCTAssertGreaterThan(sheet.frame.width, window.width * 0.90, "Options must rise from the bottom at sheet width.")
        XCTAssertGreaterThan(sheet.frame.height, window.height * 0.40, "Options use a native medium or large bottom sheet.")
        let list = app.scrollViews["player.options.list"]
        for id in ["player.options.artist", "player.options.playlist", "player.sleepTimer", "player.options.airplay", "player.options.share"] {
            let row = app.buttons[id]
            reveal(row, in: list, app: app)
            assertTarget(row, minimum: 52)
            XCTAssertGreaterThan(row.frame.width, sheet.frame.width * 0.80)
        }
        XCTAssertFalse(app.buttons["player.options.done"].exists)
        let done = app.buttons["player.options.toolbarDone"]
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThan(done.frame.midY, sheet.frame.midY)
        XCTAssertFalse(app.buttons["player.options.dislike"].exists)
        capture(app, "player-bottom-options-iphone17pro")
        closeOptions(app)
        assertFullScreen(app)
    }

    func testMiniPlayerHasLargerVisibleBarAndEdgeTargetsAboveNativeTabs() throws {
        let app = launch(extra: ["--player", "--slow-audio"])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        assertMiniPlayerLayout(app, exactHeight: 64)
        let container = app.otherElements["miniPlayer.container"]
        let before = container.frame
        capture(app, "mini-player-64pt-iphone17pro")

        tapInWindow(app.buttons["miniPlayer.open"], app: app, offset: CGVector(dx: 0.5, dy: 0.02))
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The newly exposed top edge must open the player.")
        close.tap()
        assertMiniPlayerLayout(app, exactHeight: 64)
        let play = app.buttons["miniPlayer.playPause"]
        tapInWindow(play, app: app, offset: CGVector(dx: 0.5, dy: 0.02))
        waitFor("The enlarged play target must start playback") { play.label == "Pause" }
        assertFrames([container.frame], equalTo: [before])
        tapInWindow(play, app: app, offset: CGVector(dx: 0.5, dy: 0.98))
        waitFor("The lower edge of the pause target must pause playback") { play.label == "Play" }
        tapInWindow(app.buttons["miniPlayer.next"], app: app, offset: CGVector(dx: 0.5, dy: 0.98))
        waitFor("The enlarged Next target must change songs") { app.buttons["miniPlayer.open"].label.contains("Kesariya") }

        for tab in ["Search", "Library", "Recap", "Home"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected)
            assertMiniPlayerLayout(app, exactHeight: 64)
        }
    }

    func testMiniPlayerGrowsForLargeTextAndReturnsAfterKeyboardDismissal() throws {
        let app = launch(extra: ["--player", "--light", "-UIPreferredContentSizeCategoryName",
                                 UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        assertMiniPlayerLayout(app)
        XCTAssertGreaterThan(app.otherElements["miniPlayer.container"].frame.height, 64,
                             "The bar must grow with the two lines of accessibility-sized text.")
        capture(app, "mini-player-large-text-iphone17pro")
        tapInWindow(app.buttons["miniPlayer.open"], app: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.textFields["search.field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.textFields["search.field"].tap()
        waitFor("Typing must make room for the keyboard") {
            app.keyboards.firstMatch.exists && !app.otherElements["miniPlayer.container"].exists
        }
        app.buttons["search.dismissKeyboard"].tap()
        waitFor("Dismissing the keyboard must restore the mini-player") {
            !app.keyboards.firstMatch.exists && app.otherElements["miniPlayer.container"].exists
        }
        assertMiniPlayerLayout(app)
    }

    func testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabs() throws {
        try assertTabScrollEnds(launchWithMiniPlayer())
    }

    func testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabsAtLargestTextSize() throws {
        try assertTabScrollEnds(launchWithMiniPlayer(largeText: true))
    }

    func testMiniPlayerKeepsPushedScrollAndListEndsAboveTheBar() throws {
        try assertPushedScrollEnds(launchWithMiniPlayer())
    }

    func testMiniPlayerKeepsPushedScrollAndListEndsAboveTheBarAtLargestTextSize() throws {
        try assertPushedScrollEnds(launchWithMiniPlayer(largeText: true))
    }

    func testHorizontalSeekAndShortDragsDoNotDismissTheFullScreenPlayer() throws {
        let app = launch(extra: ["--player"])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let slider = app.sliders["player.seek"]
        let elapsed = app.staticTexts["player.elapsed"]
        let initialFrames = [slider.frame, app.buttons["player.playPause"].frame, app.buttons["player.menu"].frame]
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        waitFor("A horizontal drag must seek within the paused recording") {
            guard let seconds = AppUIClock.seconds(elapsed.value as? String) else { return false }
            return abs(seconds - 131) <= 3
        }
        XCTAssertTrue(close.isHittable)
        XCTAssertEqual(app.buttons["player.playPause"].label, "Play")
        assertFrames([slider.frame, app.buttons["player.playPause"].frame, app.buttons["player.menu"].frame], equalTo: initialFrames)

        let player = app.otherElements["player.screen"]
        let artwork = player.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let position = try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String))
        artwork.tap()
        artwork.press(forDuration: 0.05, thenDragTo: artwork.withOffset(CGVector(dx: 0, dy: 55)),
                      withVelocity: .slow, thenHoldForDuration: 0.1)
        waitFor("A short drag must settle back to the original layout") { abs(slider.frame.minY - initialFrames[0].minY) <= 1 }
        XCTAssertTrue(close.isHittable, "A tap or short downward drag must not dismiss the player.")
        XCTAssertEqual(try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String)), position, accuracy: 1)
        assertFrames([slider.frame, app.buttons["player.playPause"].frame, app.buttons["player.menu"].frame], equalTo: initialFrames)

        artwork.press(forDuration: 0.05, thenDragTo: artwork.withOffset(CGVector(dx: 0, dy: 12)),
                      withVelocity: .fast, thenHoldForDuration: 0)
        waitFor("Tiny fast movements must not dismiss the player") { close.isHittable && abs(slider.frame.minY - initialFrames[0].minY) <= 1 }

        artwork.press(forDuration: 0.35, thenDragTo: artwork.withOffset(CGVector(dx: 0, dy: 85)),
                      withVelocity: .slow, thenHoldForDuration: 0.5)
        waitFor("A slow drag must dismiss even after holding still before release") {
            !close.exists && app.buttons["miniPlayer.open"].exists
        }
        tapInWindow(app.buttons["miniPlayer.open"], app: app)
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String)), position, accuracy: 1)
    }

    func testShortFastFlickDismissesThePlayerAfterRepeatedReopening() throws {
        let app = launch(extra: ["--player"])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        for hold in [0.0, 0.0, 0.0, 0.12] {
            let start = app.otherElements["player.screen"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 52)),
                        withVelocity: .fast, thenHoldForDuration: hold)
            waitFor("A short fast flick must dismiss without a long drag or release delay") {
                !close.exists && app.buttons["miniPlayer.open"].exists
            }
            tapInWindow(app.buttons["miniPlayer.open"], app: app)
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            assertFullScreen(app)
        }
    }

    func testHeldFastDragExpiresAndDoesNotQualifyTheNextSlowDrag() throws {
        let app = launch(extra: ["--player"])
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let controls = [app.buttons["player.playPause"], app.sliders["player.seek"], app.buttons["player.menu"]]
        let before = controls.map(\.frame)
        let elapsed = app.staticTexts["player.elapsed"]
        let position = try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String))
        let gestures: [(CGFloat, XCUIGestureVelocity, TimeInterval)] = [(52, .fast, 0.45), (55, .slow, 0.1)]
        for (distance, velocity, hold) in gestures {
            let start = app.otherElements["player.screen"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: velocity, thenHoldForDuration: hold)
            waitFor("A held flick or slow short drag must return to the player") {
                close.exists && abs(controls[0].frame.minY - before[0].minY) <= 1
            }
            assertFrames(controls.map(\.frame), equalTo: before)
            XCTAssertEqual(try XCTUnwrap(AppUIClock.seconds(elapsed.value as? String)), position, accuracy: 1)
        }
        assertFullScreen(app)
    }

    func testPlayerOptionsSleepTimerStaysInOneSheetAndKeepsItsAccessibleDeadline() throws {
        let app = launch(extra: ["--player"])
        XCTAssertTrue(app.buttons["player.menu"].waitForExistence(timeout: 10))
        openOptions(app)
        let sleep = app.buttons["player.sleepTimer"]
        reveal(sleep, in: app.scrollViews["player.options.list"], app: app)
        XCTAssertEqual(sleep.label, "Sleep timer")
        sleep.tap()
        XCTAssertTrue(app.navigationBars["Sleep timer"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "player.options.sheet").count, 1)
        let timerList = app.descendants(matching: .any).matching(identifier: "player.sleepTimer.list").firstMatch
        reveal(app.buttons["player.sleepTimer.120"], in: timerList, app: app)
        let duration = app.buttons["player.sleepTimer.15"]
        reveal(duration, in: timerList, app: app, towardTop: true)
        assertTarget(duration, minimum: 52)
        duration.tap()
        waitFor("Choosing a timer must dismiss the entire options sheet") {
            !app.otherElements["player.options.sheet"].exists && app.buttons["player.menu"].isHittable
        }

        openOptions(app)
        reveal(sleep, in: app.scrollViews["player.options.list"], app: app)
        XCTAssertTrue(sleep.label.hasPrefix("Sleep timer · stops at "))
        XCTAssertTrue(app.buttons["Cancel sleep timer"].exists)
        sleep.tap()
        XCTAssertTrue(app.navigationBars["Sleep timer"].waitForExistence(timeout: 5))
        reveal(app.buttons["player.sleepTimer.120"], in: timerList, app: app)
        let cancel = app.buttons["player.sleepTimer.cancel"]
        reveal(cancel, in: timerList, app: app, towardTop: true)
        assertTarget(cancel, minimum: 52)
        cancel.tap()
        waitFor("Cancelling a timer must dismiss the entire options sheet") { !app.otherElements["player.options.sheet"].exists }
        openOptions(app)
        XCTAssertEqual(sleep.label, "Sleep timer")
        XCTAssertFalse(app.buttons["Cancel sleep timer"].exists)
        closeOptions(app)
    }

    func testPlayerPlaylistSheetKeepsDraftAndAddsSongsToNewAndExistingPlaylists() throws {
        let app = launch(extra: ["--player"])
        XCTAssertTrue(app.buttons["player.menu"].waitForExistence(timeout: 10))
        openOptions(app)
        app.buttons["player.options.playlist"].tap()
        XCTAssertTrue(app.buttons["player.playlists.new"].waitForExistence(timeout: 5))
        app.buttons["player.playlists.new"].tap()
        let name = app.textFields["player.playlist.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Thumb mix")
        let create = app.buttons["player.playlist.create"]
        let editor = app.scrollViews["player.playlist.editor"]
        reveal(create, in: editor, app: app)
        assertTarget(create, minimum: 52)
        XCTAssertTrue(editor.buttons["player.playlist.create"].exists, "Create belongs to the scrolling form.")
        XCTAssertFalse(app.buttons["player.options.done"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(create.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Playlist creation belongs to the bottom sheet.")
        app.buttons["player.options.back"].tap()
        XCTAssertTrue(app.buttons["player.playlists.new"].waitForExistence(timeout: 5))
        app.buttons["player.playlists.new"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Thumb mix")
        reveal(create, in: editor, app: app)
        create.tap()
        waitFor("Creating a playlist must add the song and close options") { !app.otherElements["player.options.sheet"].exists }

        openOptions(app)
        app.buttons["player.options.playlist"].tap()
        let playlist = app.buttons["Thumb mix"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertFalse(playlist.isEnabled, "The song is already in the new playlist.")
        closeOptions(app)
        app.buttons["player.next"].tap()
        XCTAssertTrue(app.staticTexts["player.track.\(AppUIFixture.kesariya)"].waitForExistence(timeout: 5))
        openOptions(app)
        app.buttons["player.options.playlist"].tap()
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertTrue(playlist.isEnabled)
        assertTarget(playlist, minimum: 52)
        playlist.tap()
        waitFor("Adding to an existing playlist must close options") { !app.otherElements["player.options.sheet"].exists }
        openOptions(app)
        app.buttons["player.options.playlist"].tap()
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertFalse(playlist.isEnabled, "The second song must also be saved to the playlist.")
        capture(app, "player-playlist-added-iphone17pro")
        closeOptions(app)
    }

    func testPlayerOptionsArtistChoiceClosesBothSheetAndCover() throws {
        let app = launch(extra: ["--player"])
        XCTAssertTrue(app.buttons["player.next"].waitForExistence(timeout: 10))
        app.buttons["player.next"].tap()
        app.buttons["player.next"].tap()
        XCTAssertTrue(app.staticTexts["player.track.\(AppUIFixture.agarTumSaathHo)"].waitForExistence(timeout: 5))
        openOptions(app)
        app.buttons["player.options.artist"].tap()
        XCTAssertTrue(app.navigationBars["Go to artist"].waitForExistence(timeout: 5))
        let alka = app.buttons["player.artist.0"]
        let arijit = app.buttons["player.artist.1"]
        assertArtistsStartBelowTitle(app)
        assertTarget(alka, minimum: 52)
        assertTarget(arijit, minimum: 52)
        XCTAssertEqual(alka.label, "Alka Yagnik")
        XCTAssertEqual(arijit.label, "Arijit Singh")
        XCTAssertEqual(app.otherElements.matching(identifier: "player.options.sheet").count, 1)
        app.buttons["player.options.back"].tap()
        XCTAssertTrue(app.buttons["player.options.artist"].waitForExistence(timeout: 5))
        app.buttons["player.options.artist"].tap()
        XCTAssertTrue(alka.waitForExistence(timeout: 5))
        alka.tap()
        waitFor("Choosing an artist must close the sheet and full-screen player before showing the page") {
            !app.otherElements["player.options.sheet"].exists && !app.buttons["player.close"].exists
                && app.staticTexts["ARTIST"].exists && app.staticTexts["Alka Yagnik"].exists
                && app.buttons["collection.follow"].exists
        }
        capture(app, "player-options-artist-navigation-iphone17pro")
    }

    func testLargePlayerTextAndLightLandscapeKeepControlsReachable() throws {
        let app = launch(extra: ["--player", "--light"])
        let title = app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let standardHeight = title.frame.height
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(title.frame.height, standardHeight * 1.5)
        assertThumbTargets(app)
        XCTAssertEqual(app.otherElements["player.screen"].scrollViews.count, 0)
        capture(app, "player-light-accessibility-xxxl-iphone17pro")

        openOptions(app)
        let share = app.buttons["player.options.share"]
        reveal(share, in: app.scrollViews["player.options.list"], app: app)
        assertTarget(share, minimum: 52)
        XCTAssertFalse(app.buttons["player.options.done"].exists)
        capture(app, "player-light-options-accessibility-xxxl-iphone17pro")
        closeOptions(app)
        assertLowerSheetListsReachable(app)

        rotatePlayerToLandscape(app)
        assertThumbTargets(app)
        assertNoVolumeSlider(app)
        XCTAssertEqual(app.otherElements["player.screen"].scrollViews.count, 0)
        capture(app, "player-light-landscape-accessibility-xxxl-iphone17pro")
        assertLowerSheetListsReachable(app)
    }

    func testLowerSheetListsExpandAndSwipeDismissWithoutClosingThePlayer() throws {
        let app = launch(extra: ["--player"])
        XCTAssertTrue(app.buttons["player.menu"].waitForExistence(timeout: 10))
        openOptions(app)
        let sheet = app.otherElements["player.options.sheet"]
        let initialTop = sheet.frame.minY
        let list = app.scrollViews["player.options.list"]
        list.swipeUp(velocity: .slow)
        waitFor("Dragging sheet content upward must expand the sheet") { sheet.frame.minY < initialTop - 60 }
        reveal(app.buttons["player.options.share"], in: list, app: app)
        dismissOptionsBySwiping(app, content: list)
        assertLowerSheetListsReachable(app)

        rotatePlayerToLandscape(app)
        assertLowerSheetListsReachable(app)
    }

    func testAppIconPickerChangesTheHomeScreenIcon() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        app.buttons["home.settings"].tap()
        let row = app.buttons["settings.appIcon"]
        // Settings is a lazy list; the row below the account section only exists once scrolled into view.
        for _ in 0..<4 where !row.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        if !row.isHittable { app.swipeUp() }
        row.tap()
        let peacock = app.buttons["settings.icon.Peacock"]
        XCTAssertTrue(peacock.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.icon.Beat"].isSelected)
        capture(app, "settings-app-icons-iphone17pro")
        peacock.tap()
        // iOS confirms icon changes with its own alert, delivered through the springboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let ok = springboard.buttons["OK"]
        if ok.waitForExistence(timeout: 8) { ok.tap() }
        let selected = NSPredicate { _, _ in MainActor.assumeIsolated { peacock.isSelected } }
        expectation(for: selected, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.appIcon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.appIcon"].label.contains("Zephyr"))
        capture(app, "settings-app-icon-selected-iphone17pro")
        // Restore the default so other runs on this simulator start from the shipped icon.
        app.buttons["settings.appIcon"].tap()
        app.buttons["settings.icon.Beat"].tap()
        if ok.waitForExistence(timeout: 8) { ok.tap() }
    }

    func testPlayerIsFixedAndLoadingDoesNotMoveControls() throws {
        let app = launch(extra: ["--player", "--slow-audio"])
        let play = app.buttons["player.playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let ids = ["player.close", "player.previous", "player.next", "player.shuffle", "player.repeat",
                   "player.like", "player.lyrics", "player.queue", "player.artist", "player.artistName", "player.menu"]
        for id in ids {
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) must fit without scrolling")
        }
        let seek = app.sliders["player.seek"]
        XCTAssertTrue(seek.isHittable)
        let elements = ids.map { app.buttons[$0] } + [play, seek, app.staticTexts["player.elapsed"],
                                                     app.staticTexts["player.remaining"], app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"]]
        let before = elements.map(\.frame)
        capture(app, "fixed-player-paused-iphone17pro")
        play.tap()
        XCTAssertEqual(play.value as? String, "Loading")
        assertFrames(elements.map(\.frame), equalTo: before)
        XCTAssertFalse(app.staticTexts["Connecting to audio…"].exists)
        capture(app, "fixed-player-loading-iphone17pro")
        let ready = NSPredicate { _, _ in MainActor.assumeIsolated {
            (play.value as? String) != "Loading" && play.label == "Pause"
        }}
        expectation(for: ready, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        assertFrames(elements.map(\.frame), equalTo: before)
        let player = app.otherElements["player.screen"]
        XCTAssertEqual(player.scrollViews.count, 0)
        player.swipeUp()
        assertFrames(elements.map(\.frame), equalTo: before)
        assertNoVolumeSlider(app)
        capture(app, "fixed-player-playing-iphone17pro")
        play.tap()
    }

    private func openOptions(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let menu = app.buttons["player.menu"]
        waitFor("The player options button must be reachable", file: file, line: line) { menu.isHittable }
        menu.tap()
        XCTAssertTrue(app.otherElements["player.options.sheet"].waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(app.navigationBars["Song options"].exists, file: file, line: line)
    }

    private func assertMiniPlayerLayout(_ app: XCUIApplication, exactHeight: CGFloat? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let container = app.otherElements["miniPlayer.container"]
        waitFor("The mini-player must reserve its full visible height", file: file, line: line) {
            container.exists && container.frame.height >= 63.5 && !app.buttons["player.close"].exists
        }
        let frame = container.frame
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(frame), file: file, line: line)
        XCTAssertEqual(app.otherElements.matching(identifier: "miniPlayer.container").count, 1, file: file, line: line)
        if let exactHeight { XCTAssertEqual(frame.height, exactHeight, accuracy: 1, file: file, line: line) }
        for id in ["miniPlayer.open", "miniPlayer.playPause", "miniPlayer.next"] {
            let control = app.buttons[id]
            assertTarget(control, minimum: 52, requiresHittable: false, file: file, line: line)
            XCTAssertTrue(frame.insetBy(dx: -1, dy: -1).contains(control.frame),
                          "\(id) must fit inside the glass bar.", file: file, line: line)
        }
        for tab in ["Home", "Search", "Library", "Recap"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.isHittable, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, button.frame.minY, "The mini-player must not cover native navigation.", file: file, line: line)
        }
    }

    private func launchWithMiniPlayer(largeText: Bool = false) -> XCUIApplication {
        let textArguments = largeText
            ? ["--light", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue] : []
        let app = launch(extra: ["--player"] + textArguments)
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        assertMiniPlayerLayout(app, exactHeight: largeText ? nil : 64)
        if largeText { XCTAssertGreaterThan(app.otherElements["miniPlayer.container"].frame.height, 64) }
        return app
    }

    private func assertTabScrollEnds(_ app: XCUIApplication) throws {
        let discovery = app.descendants(matching: .any).matching(identifier: "home.group.discovery").firstMatch
        try revealAboveMiniPlayer(discovery.buttons["track.card.\(AppUIFixture.blindingLights)"], app: app)
        capture(app, "mini-player-home-scroll-end")

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        assertMiniPlayerLayout(app)
        let beforeKeyboard = app.otherElements["miniPlayer.container"].frame
        field.tap()
        waitFor("The keyboard must replace the player reservation while editing") {
            app.keyboards.firstMatch.exists && !app.otherElements["miniPlayer.container"].exists
        }
        field.typeText("Arijit")
        app.buttons["search.dismissKeyboard"].tap()
        waitFor("Finishing the search must restore the player and navigation") {
            !app.keyboards.firstMatch.exists && app.otherElements["miniPlayer.container"].exists
        }
        assertMiniPlayerLayout(app)
        assertFrames([app.otherElements["miniPlayer.container"].frame], equalTo: [beforeKeyboard])
        XCTAssertTrue(app.buttons["track.play.\(AppUIFixture.tumHiHo)"].waitForExistence(timeout: 5))
        try revealAboveMiniPlayer(app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"], app: app)
        capture(app, "mini-player-search-scroll-end-after-keyboard")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["library.createPlaylist"].waitForExistence(timeout: 5))
        let lastRecent = app.otherElements["library.recent.\(AppUIFixture.agarTumSaathHo)"]
        try revealAboveMiniPlayer(lastRecent, app: app, requiresHittable: false)
        XCTAssertTrue(app.buttons["library.resume.\(AppUIFixture.agarTumSaathHo)"].isHittable)
        capture(app, "mini-player-library-scroll-end")

        app.tabBars.buttons["Recap"].tap()
        let notes = app.descendants(matching: .any).matching(identifier: "recap.howCounted").firstMatch
        try revealAboveMiniPlayer(notes, app: app)
        tapInWindow(notes, app: app)
        let lastNote = app.staticTexts["Collaborations credit each named artist. The total listening time counts each session only once."]
        try revealAboveMiniPlayer(lastNote, app: app, requiresHittable: false)
        capture(app, "mini-player-recap-expanded-scroll-end")
    }

    private func assertPushedScrollEnds(_ app: XCUIApplication) throws {
        let recents = app.buttons["Recently played, see all"]
        try revealAboveMiniPlayer(recents, app: app)
        tapInWindow(recents, app: app)
        XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
        let lastRecent = app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try revealAboveMiniPlayer(lastRecent, app: app)
        let beforePresentation = lastRecent.frame
        tapInWindow(app.buttons["miniPlayer.open"], app: app)
        XCTAssertTrue(app.buttons["player.close"].waitForExistence(timeout: 5))
        app.buttons["player.close"].tap()
        assertMiniPlayerLayout(app)
        XCTAssertTrue(app.buttons["collection.actions"].isHittable)
        assertFrames([lastRecent.frame], equalTo: [beforePresentation])
        capture(app, "mini-player-direct-collection-scroll-end")
        app.navigationBars.buttons.firstMatch.tap()

        let customize = app.buttons["home.customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        tapInWindow(customize, app: app)
        XCTAssertTrue(app.navigationBars["Customize Home"].waitForExistence(timeout: 5))
        let customizationFooter = app.staticTexts["Hiding a section keeps your saved music and listening history."]
        try revealAboveMiniPlayer(customizationFooter, app: app, requiresHittable: false)
        capture(app, "mini-player-home-customization-list-end")
        app.navigationBars.buttons.firstMatch.tap()

        app.tabBars.buttons["Library"].tap()
        let likes = app.buttons["library.likes"]
        try revealAboveMiniPlayer(likes, app: app)
        tapInWindow(likes, app: app)
        XCTAssertTrue(app.navigationBars["Liked songs"].waitForExistence(timeout: 5))
        try revealAboveMiniPlayer(app.buttons["track.play.\(AppUIFixture.tumHiHo)"], app: app)
        capture(app, "mini-player-liked-songs-list-end")
        app.navigationBars.buttons.firstMatch.tap()

        let playlist = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@ AND label CONTAINS %@",
                                                        #"library\.playlist\.[0-9A-Fa-f-]{36}"#, AppUIFixture.seededPlaylist)).firstMatch
        try revealAboveMiniPlayer(playlist, app: app)
        tapInWindow(playlist, app: app)
        XCTAssertTrue(app.navigationBars[AppUIFixture.seededPlaylist].waitForExistence(timeout: 5))
        let lastPlaylistRow = app.otherElements["library.playlist.track.\(AppUIFixture.shapeOfYou)"]
        try revealAboveMiniPlayer(lastPlaylistRow, app: app, requiresHittable: false)
        let playlistFooter = app.staticTexts["Use Edit to reorder or remove songs."]
        try revealAboveMiniPlayer(playlistFooter, app: app, requiresHittable: false)
        capture(app, "mini-player-playlist-list-end")

        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Evening")
        app.buttons["search.dismissKeyboard"].tap()
        assertMiniPlayerLayout(app)
        tapInWindow(app.buttons["search.filter.albums"], app: app)
        let album = app.buttons["collection.\(AppUIFixture.album)"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        try revealAboveMiniPlayer(album, app: app)
        tapInWindow(album, app: app)
        XCTAssertTrue(app.buttons["collection.actions"].waitForExistence(timeout: 5))
        try revealAboveMiniPlayer(app.buttons["track.play.\(AppUIFixture.shapeOfYou)"], app: app)
        capture(app, "mini-player-value-collection-scroll-end")

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.navigationBars[AppUIFixture.seededPlaylist].waitForExistence(timeout: 5))
        try revealAboveMiniPlayer(playlistFooter, app: app, requiresHittable: false)
    }

    private func revealAboveMiniPlayer(_ element: XCUIElement, app: XCUIApplication, requiresHittable: Bool = true,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        assertMiniPlayerLayout(app, file: file, line: line)
        let candidates = app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
        let regions = candidates.compactMap { scroll -> (element: XCUIElement, viewport: CGRect)? in
            let viewport = miniPlayerContentViewport(app, scrollView: scroll)
            return usableFrame(viewport) && viewport.height > 50 ? (scroll, viewport) : nil
        }
        let scrollView = try XCTUnwrap(regions.max { $0.viewport.height < $1.viewport.height }?.element,
                                      "A navigation scroll view must be visible above the mini-player.", file: file, line: line)
        for attempt in 0...32 {
            let viewport = miniPlayerContentViewport(app, scrollView: scrollView)
            guard usableFrame(viewport), viewport.height > 50 else { break }
            let frame = element.exists ? element.frame : .null
            if usableFrame(frame), viewport.insetBy(dx: -1, dy: -1).contains(frame),
               !requiresHittable || element.isHittable { return }
            guard attempt < 32 else { break }

            let towardTop = usableFrame(frame) && frame.minY < viewport.minY
            let window = app.windows.firstMatch
            let bounds = window.frame
            guard usableFrame(bounds) else { break }
            let top = viewport.minY + viewport.height * 0.2
            let bottom = viewport.minY + viewport.height * 0.8
            let x = viewport.minX + min(12, viewport.width * 0.05)
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: x - bounds.minX, dy: (towardTop ? top : bottom) - bounds.minY))
            let end = origin.withOffset(CGVector(dx: x - bounds.minX, dy: (towardTop ? bottom : top) - bounds.minY))
            // Stay inside the content viewport and outside nested horizontal shelves; stop momentum before checking.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        let frame = element.exists ? element.frame : .null
        let viewport = miniPlayerContentViewport(app, scrollView: scrollView)
        let glass = app.otherElements["miniPlayer.container"].frame
        let report = XCTAttachment(string: "Row \(element.identifier): \(frame); viewport: \(viewport); glass: \(glass)")
        report.name = "mini-player-scroll-clearance"
        report.lifetime = .keepAlways
        add(report)
        capture(app, "mini-player-scroll-clearance-failure")
        XCTFail("The whole \(element.identifier) row must scroll above the mini-player, including its lower edge.", file: file, line: line)
    }

    private func miniPlayerContentViewport(_ app: XCUIApplication, scrollView: XCUIElement) -> CGRect {
        let bounds = scrollView.frame.intersection(app.windows.firstMatch.frame)
        let mini = app.otherElements["miniPlayer.container"]
        guard usableFrame(bounds), mini.exists, usableFrame(mini.frame) else { return .null }
        var top = bounds.minY
        for navigation in app.navigationBars.allElementsBoundByIndex {
            let frame = navigation.frame
            if usableFrame(frame), frame.intersects(bounds), frame.minY < bounds.midY { top = max(top, frame.maxY) }
        }
        let bottom = min(bounds.maxY, mini.frame.minY)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
    }

    private func tapInWindow(_ element: XCUIElement, app: XCUIApplication,
                             offset: CGVector = CGVector(dx: 0.5, dy: 0.5), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        let frame = element.frame
        let window = app.windows.firstMatch
        let bounds = window.frame
        guard [frame.minX, frame.minY, frame.width, frame.height, bounds.minX, bounds.minY,
               bounds.width, bounds.height, offset.dx, offset.dy].allSatisfy(\.isFinite),
              !frame.isEmpty, !frame.isNull, !bounds.isEmpty, !bounds.isNull else {
            XCTFail("Cannot tap \(element.identifier) with invalid geometry: \(frame)", file: file, line: line)
            return
        }
        let point = CGPoint(x: frame.minX + frame.width * offset.dx, y: frame.minY + frame.height * offset.dy)
        guard bounds.contains(point) else {
            XCTFail("Tap for \(element.identifier) falls outside the window.", file: file, line: line)
            return
        }
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - bounds.minX, dy: point.y - bounds.minY)).tap()
    }

    private func rotatePlayerToLandscape(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let before = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            AppUITestDriver.requestSceneGeometry(.landscapeLeft)
            let attachment = XCTAttachment(string: "Layout uses a public UIKit scene geometry request. Physical autorotation is not covered by this headless run.")
            attachment.name = "scene-geometry-request"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated {
            let frame = app.windows.firstMatch.frame
            return frame.width.isFinite && frame.height.isFinite && frame.width > frame.height
                && app.buttons["player.menu"].isHittable
        }}
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        if result != .completed {
            let report = "Requested landscapeLeft; XCUIDevice readback: \(XCUIDevice.shared.orientation.rawValue); window before: \(before); window after: \(app.windows.firstMatch.frame)."
            let attachment = XCTAttachment(string: report)
            attachment.name = "player-rotation-delivery"
            attachment.lifetime = .keepAlways
            add(attachment)
            capture(app, "player-rotation-failure")
        }
        XCTAssertEqual(result, .completed, "The player must fit the landscape window.", file: file, line: line)
    }

    private func closeOptions(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["player.options.toolbarDone"]
        XCTAssertTrue(done.isHittable, file: file, line: line)
        done.tap()
        waitFor("Done must close options and return to the player", file: file, line: line) {
            !app.otherElements["player.options.sheet"].exists && app.buttons["player.menu"].isHittable
        }
    }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, app: XCUIApplication,
                        towardTop: Bool = false, requiresHittable: Bool = true,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<20 {
            let viewport = sheetViewport(app, scrollView: scrollView)
            guard !viewport.isEmpty, !viewport.isNull else { break }
            var movement = viewport.height * (towardTop ? 0.4 : -0.4)
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty, viewport.insetBy(dx: -1, dy: -1).contains(frame), !requiresHittable || element.isHittable { return }
                if !frame.isEmpty, !frame.isNull {
                    movement = frame.minY < viewport.minY ? viewport.minY - frame.minY + 8 : viewport.maxY - frame.maxY - 8
                }
            }
            let sheet = app.otherElements["player.options.sheet"]
            if sheet.frame.height < app.windows.firstMatch.frame.height * 0.8 {
                scrollView.swipeUp(velocity: .slow)
                continue
            }
            // Full swipes can jump over an entire row in a short landscape sheet and oscillate indefinitely.
            let distance = min(max(abs(movement), 14), viewport.height * 0.45)
            let startY = movement > 0 ? viewport.minY + viewport.height * 0.2 : viewport.maxY - viewport.height * 0.2
            let window = app.windows.firstMatch
            let bounds = window.frame
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX - bounds.minX, dy: startY - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: movement > 0 ? distance : -distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        capture(app, "player-sheet-scroll-failure")
        XCTAssertTrue(element.exists, file: file, line: line)
        if requiresHittable { XCTAssertTrue(element.isHittable, file: file, line: line) }
        XCTAssertTrue(sheetViewport(app, scrollView: scrollView).insetBy(dx: -1, dy: -1).contains(element.frame),
                      "The whole \(element.identifier) row must be visible: \(element.frame), viewport: \(sheetViewport(app, scrollView: scrollView)).", file: file, line: line)
    }

    private func sheetViewport(_ app: XCUIApplication, scrollView: XCUIElement) -> CGRect {
        let bounds = scrollView.frame.intersection(app.otherElements["player.options.sheet"].frame)
            .intersection(app.windows.firstMatch.frame)
        let navigation = app.navigationBars.containing(.button, identifier: "player.options.toolbarDone").firstMatch
        let keyboard = app.keyboards.firstMatch
        let top = navigation.exists ? max(bounds.minY, navigation.frame.maxY) : bounds.minY
        let bottom = keyboard.exists ? min(bounds.maxY, keyboard.frame.minY) : bounds.maxY
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bottom - top))
    }

    private func assertArtistsStartBelowTitle(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let navigation = app.navigationBars["Go to artist"]
        let first = app.buttons["player.artist.0"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(first.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertGreaterThanOrEqual(first.frame.minY, navigation.frame.maxY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(first.frame.minY, navigation.frame.maxY + 28,
                                 "Artist choices must start below the title without a blank top section.", file: file, line: line)
    }

    private func dismissOptionsBySwiping(_ app: XCUIApplication, content: XCUIElement,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let sheet = app.otherElements["player.options.sheet"]
        XCTAssertFalse(app.buttons["player.options.done"].exists, file: file, line: line)
        for _ in 0..<6 where sheet.exists { content.swipeDown(velocity: .fast) }
        waitFor("Swiping sheet content downward must dismiss only the sheet", file: file, line: line) {
            !sheet.exists && app.buttons["player.close"].exists && app.buttons["player.menu"].isHittable
        }
        assertFullScreen(app, file: file, line: line)
    }

    private func assertLowerSheetListsReachable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openOptions(app, file: file, line: line)
        let options = app.scrollViews["player.options.list"]
        reveal(app.buttons["player.options.share"], in: options, app: app, file: file, line: line)
        dismissOptionsBySwiping(app, content: options, file: file, line: line)

        let duet = app.staticTexts["player.track.\(AppUIFixture.agarTumSaathHo)"]
        for _ in 0..<5 where !duet.exists { app.buttons["player.next"].tap() }
        XCTAssertTrue(duet.waitForExistence(timeout: 5), file: file, line: line)
        app.buttons["player.artist"].tap()
        assertArtistsStartBelowTitle(app, file: file, line: line)
        let artists = app.scrollViews["player.artists.list"]
        reveal(app.buttons["player.artist.1"], in: artists, app: app, file: file, line: line)
        dismissOptionsBySwiping(app, content: artists, file: file, line: line)

        openOptions(app, file: file, line: line)
        let playlistAction = app.buttons["player.options.playlist"]
        reveal(playlistAction, in: options, app: app, file: file, line: line)
        playlistAction.tap()
        let playlists = app.scrollViews["player.playlists.list"]
        reveal(app.buttons[AppUIFixture.seededPlaylist], in: playlists, app: app, requiresHittable: false, file: file, line: line)
        dismissOptionsBySwiping(app, content: playlists, file: file, line: line)

        openOptions(app, file: file, line: line)
        let sleepAction = app.buttons["player.sleepTimer"]
        reveal(sleepAction, in: options, app: app, file: file, line: line)
        sleepAction.tap()
        let timerList = app.descendants(matching: .any).matching(identifier: "player.sleepTimer.list").firstMatch
        reveal(app.buttons["player.sleepTimer.120"], in: timerList, app: app, file: file, line: line)
        dismissOptionsBySwiping(app, content: timerList, file: file, line: line)
    }

    private func assertFullScreen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let presentation = app.otherElements["player.presentation"]
        XCTAssertTrue(presentation.exists, file: file, line: line)
        let window = app.windows.firstMatch.frame
        waitFor("The full-screen presentation must finish moving into place", file: file, line: line) {
            window.insetBy(dx: -1, dy: -1).contains(presentation.frame)
                && presentation.frame.maxY >= window.maxY - 40
        }
        let frame = presentation.frame
        if window.width > window.height {
            // The landscape safe area excludes the sensor housing; the decorative backdrop stays edge to edge.
            XCTAssertEqual(frame.minX - window.minX, window.maxX - frame.maxX, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThan(frame.width, window.width * 0.85, file: file, line: line)
        } else {
            XCTAssertEqual(frame.minX, window.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.width, window.width, accuracy: 1, file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(frame.minY, window.minY, file: file, line: line)
        XCTAssertLessThan(frame.minY, window.minY + window.height * 0.12, file: file, line: line)
        XCTAssertGreaterThan(frame.height, window.height * 0.85, file: file, line: line)
        XCTAssertFalse(app.buttons["home.settings"].isHittable, file: file, line: line)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, file: file, line: line)
        let content = app.otherElements["player.screen"].frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(content), file: file, line: line)
        XCTAssertGreaterThan(content.height, window.height * 0.80, file: file, line: line)
    }

    private func assertThumbTargets(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
        for id in ["player.close", "player.like", "player.previous", "player.next", "player.shuffle", "player.repeat",
                   "player.lyrics", "player.artist", "player.queue", "player.menu"] {
            let control = app.buttons[id]
            assertTarget(control, minimum: 52, file: file, line: line)
            XCTAssertTrue(window.contains(control.frame), "\(id) must fit in the window.", file: file, line: line)
        }
        assertTarget(app.buttons["player.album"], minimum: 52, requiresHittable: false, file: file, line: line)
        assertTarget(app.buttons["player.playPause"], minimum: 80, file: file, line: line)
        assertTarget(app.buttons["player.artistName"], minimum: 44, file: file, line: line)
        assertTarget(app.sliders["player.seek"], minimum: 44, file: file, line: line)
        XCTAssertTrue(window.contains(app.buttons["player.playPause"].frame), file: file, line: line)
        XCTAssertTrue(window.contains(app.sliders["player.seek"].frame), file: file, line: line)
        XCTAssertTrue(app.staticTexts["player.elapsed"].isHittable, file: file, line: line)
        XCTAssertTrue(app.staticTexts["player.remaining"].isHittable, file: file, line: line)
    }

    private func assertTarget(_ element: XCUIElement, minimum: CGFloat, requiresHittable: Bool = true,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        if requiresHittable { XCTAssertTrue(element.isHittable, "\(element.identifier) must be hittable.", file: file, line: line) }
        XCTAssertGreaterThanOrEqual(element.frame.width, minimum - 0.5, "\(element.identifier) target width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, minimum - 0.5, "\(element.identifier) target height", file: file, line: line)
    }

    private func assertNoVolumeSlider(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "player.volume").firstMatch.exists, file: file, line: line)
        XCTAssertFalse(app.sliders.matching(NSPredicate(format: "label CONTAINS[c] 'volume'")).firstMatch.exists, file: file, line: line)
        XCTAssertEqual(app.otherElements["player.screen"].sliders.count, 1, "Only playback position belongs in the player.", file: file, line: line)
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                         condition: @escaping @MainActor () -> Bool) {
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file, line: line)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui"] + extra
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            app.launchArguments.append("--ui-scene-geometry")
        }
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_LAYOUT_DIAGNOSTICS"] == "1" {
            app.launchArguments.append("--ui-layout-diagnostics")
        }
        app.launchEnvironment["GANABAJANA_TEST_STORE"] = "refinement-\(UUID().uuidString)"
        app.launch()
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            AppUITestDriver.requestSceneGeometry(.portrait)
            waitFor("The test must begin with a portrait scene") {
                app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width
            }
        }
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        return app
    }

    private func assertFrames(_ actual: [CGRect], equalTo expected: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.minX, rhs.minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(lhs.minY, rhs.minY, accuracy: 1, file: file, line: line)
            XCTAssertEqual(lhs.width, rhs.width, accuracy: 1, file: file, line: line)
            XCTAssertEqual(lhs.height, rhs.height, accuracy: 1, file: file, line: line)
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
