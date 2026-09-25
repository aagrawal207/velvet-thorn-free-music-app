import Foundation
import UIKit
import XCTest

final class GanaBajanaWorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchFiltersClearAndPlayAResult() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.wait("Home discovery must contain a playable recommendation") {
            ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.card.")).firstMatch.exists
        }
        ui.capture("home-dark-discovery")
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        for id in [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo] {
            try ui.reveal(ui.app.buttons["track.play.\(id)"])
        }
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.blindingLights)"].exists)
        ui.capture("search-dark-hindi-results")

        for filter in ["albums", "artists", "playlists"] {
            try ui.selectSearchFilter(filter)
            let collection = ui.app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "collection.", "Evening favorites"
            )).firstMatch
            try ui.wait("The \(filter) filter must show a catalog collection") {
                collection.exists
            }
            XCTAssertTrue(ui.app.buttons["search.filter.\(filter)"].isSelected)
            XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
            try ui.reveal(collection)
            try ui.tap(collection)
            let kind = filter == "artists" ? "ARTIST" : filter == "playlists" ? "PLAYLIST" : "ALBUM"
            try ui.wait("The \(filter) filter must open a \(kind.lowercased()), not a different collection type") {
                ui.app.staticTexts[kind].exists
            }
            ui.capture("search-dark-\(filter)-collection")
            let back = ui.app.navigationBars.buttons.matching(NSPredicate(
                format: "label == %@ OR label == %@", "Back", "Search"
            )).firstMatch
            try ui.tap(back)
            try ui.requireHittable(ui.app.textFields["search.field"])
        }
        try ui.selectSearchFilter("songs")
        try ui.clearSearch()
        try ui.dismissSearchKeyboard()
        try ui.requireHittable(ui.app.buttons["search.library.likes"])
        try ui.requireHittable(ui.app.buttons["search.library.cached"])
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)
        XCTAssertFalse(ui.app.staticTexts["Start somewhere good"].exists)
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)

        let recentPlaylist = ui.app.buttons["search.recent.collection:playlist:\(AppUIFixture.album)"]
        try ui.reveal(recentPlaylist)
        XCTAssertTrue(recentPlaylist.label.contains("Evening favorites, Playlist"))
        XCTAssertFalse(ui.app.buttons["search.recent.arijit"].exists)
        try ui.tap(recentPlaylist)
        try ui.wait("A recent playlist must reopen the selected result rather than rerun its query") {
            ui.app.staticTexts["PLAYLIST"].exists && ui.app.buttons["collection.play"].exists
        }
        try ui.tap(ui.app.navigationBars.buttons.firstMatch)
        try ui.requireHittable(ui.app.textFields["search.field"])
        let emptyField = ui.app.textFields["search.field"]
        XCTAssertTrue((emptyField.value as? String ?? "").isEmpty || emptyField.value as? String == emptyField.placeholderValue)
        XCTAssertFalse(ui.app.buttons["search.filter.songs"].exists)

        try ui.replaceSearchQuery("no-such-ganabajana-recording-72819")
        try ui.wait("An unmatched search must have an explicit empty state") {
            ui.app.staticTexts["No songs found"].exists
        }
        try ui.replaceSearchQuery("Arijit", dismissKeyboard: false)
        try ui.clearSearch()
        ui.app.textFields["search.field"].typeText("Blinding Lights")
        try ui.dismissSearchKeyboard()
        try ui.waitForSearchResults()
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.blindingLights)"])
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists,
                       "An earlier query must not replace the latest results.")

        try ui.replaceSearchQuery("Tum Hi Ho")
        try ui.playSearchResult(id: AppUIFixture.tumHiHo, title: "Tum Hi Ho")
        try ui.assertMiniPlayerAboveTabs()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 2)
        try ui.pause()
        ui.capture("player-dark-from-search")
    }

    @MainActor
    func testLikesSurviveRelaunchAndRestorePausedPlayer() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        let heart = ui.app.buttons["player.like"]
        try ui.expectLabel(heart, "Unlike this song")
        try ui.tap(heart)
        try ui.expectLabel(heart, "Like this song")
        try ui.closePlayer()
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.staticTexts["4 songs"])
        for id in [AppUIFixture.shapeOfYou, AppUIFixture.blindingLights, AppUIFixture.agarTumSaathHo, AppUIFixture.kesariya] {
            try ui.reveal(ui.app.buttons["track.play.\(id)"])
        }
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        ui.capture("library-dark-unliked-song-removed")

        try ui.relaunch()
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Play")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(heart, "Like this song")
        try ui.assertPausedPositionStaysPut()
        try ui.tap(heart)
        try ui.expectLabel(heart, "Unlike this song")
        try ui.relaunch()
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"])
        try ui.reveal(ui.app.staticTexts["5 songs"], direction: .down)
        ui.capture("library-dark-likes-restored-after-relaunch")
    }

    @MainActor
    func testCreateRenameAddAndDeletePlaylist() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.selectTab("library")
        try ui.tap(ui.app.buttons["library.createPlaylist"])
        let name = ui.app.textFields["library.playlist.name"]
        try ui.requireHittable(name)
        XCTAssertFalse(ui.app.buttons["library.playlist.save"].isEnabled)
        name.typeText("Morning window")
        try ui.tap(ui.app.buttons["library.playlist.save"])
        try ui.wait("The playlist editor must close after saving") { !name.exists }
        try ui.openPlaylist(named: "Morning window")
        try ui.wait("An empty playlist must have a disabled play action") {
            let play = ui.app.buttons["library.playlist.play"]
            return play.exists && !play.isEnabled
        }

        try ui.reveal(ui.app.buttons["library.playlist.addSongs"])
        try ui.tap(ui.app.buttons["library.playlist.addSongs"])
        let addTum = ui.app.buttons["library.playlist.add.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(addTum)
        try ui.tap(addTum)
        try ui.wait("An added song must be marked added and cannot be duplicated") {
            addTum.exists && !addTum.isEnabled && addTum.label.hasPrefix("Added Tum Hi Ho")
        }
        try ui.tap(ui.app.buttons["library.playlist.addDone"])
        try ui.tap(ui.app.buttons["library.playlist.menu"])
        try ui.tap(ui.app.buttons["library.playlist.rename"])
        try ui.replaceSelectedText(in: name, with: "Morning favorites")
        try ui.tap(ui.app.buttons["library.playlist.save"])
        try ui.wait("The renamed playlist must be the current destination") {
            ui.app.navigationBars["Morning favorites"].exists
        }

        try ui.search("Blinding Lights")
        try ui.waitForSearchResults()
        let options = ui.app.buttons["track.options.\(AppUIFixture.blindingLights)"]
        try ui.reveal(options)
        try ui.tap(options)
        try ui.tap(ui.app.buttons["Add to playlist"])
        try ui.tap(ui.app.buttons["Morning favorites"])
        try ui.selectTab("library")
        try ui.reveal(ui.element("library.playlist.track.\(AppUIFixture.blindingLights)"))
        try ui.reveal(ui.app.staticTexts["2 songs · Made by you"], direction: .down)
        ui.capture("library-dark-created-renamed-and-populated-playlist")

        try ui.relaunch()
        try ui.selectTab("library")
        try ui.openPlaylist(named: "Morning favorites")
        try ui.reveal(ui.element("library.playlist.track.\(AppUIFixture.tumHiHo)"))
        try ui.reveal(ui.element("library.playlist.track.\(AppUIFixture.blindingLights)"))
        try ui.tap(ui.app.buttons["library.playlist.menu"])
        try ui.tap(ui.app.buttons["library.playlist.delete"])
        try ui.confirmPlaylistDeletion()
        try ui.wait("Deleting the playlist must return to the library") {
            ui.app.buttons["library.createPlaylist"].exists
        }
        try ui.relaunch()
        try ui.selectTab("library")
        try ui.reveal(ui.playlist(named: AppUIFixture.seededPlaylist))
        XCTAssertFalse(ui.playlist(named: "Morning favorites").exists)
        try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
        try ui.tap(ui.app.buttons["library.likes"])
        try ui.reveal(ui.app.staticTexts["5 songs"])
    }

    @MainActor
    func testQueueReorderRemovePlayAndRestore() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        let tum = ui.queueSong(id: AppUIFixture.tumHiHo)
        let kesariya = ui.queueSong(id: AppUIFixture.kesariya)
        try ui.requireHittable(tum)
        try ui.requireHittable(kesariya)
        XCTAssertLessThan(tum.frame.minY, kesariya.frame.minY)
        try ui.tap(ui.app.buttons["queue.edit"])
        try ui.moveQueueSong(kesariya, before: tum)
        try ui.wait("Dragging Kesariya above Tum Hi Ho must change queue order") {
            kesariya.exists && tum.exists && kesariya.frame.minY < tum.frame.minY
        }
        try ui.finishQueueEditing()

        let agar = ui.queueSong(id: AppUIFixture.agarTumSaathHo)
        try ui.reveal(agar)
        try ui.removeQueueSong(agar)
        try ui.wait("Removing a queued song must remove its row") { !agar.exists }
        ui.capture("player-dark-queue-reordered-and-removed")
        try ui.reveal(kesariya, direction: .down)
        try ui.tap(kesariya)
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.reveal(ui.app.buttons["player.next"])
        try ui.tap(ui.app.buttons["player.next"])
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()

        try ui.relaunch()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.requireHittable(kesariya)
        try ui.requireHittable(tum)
        XCTAssertLessThan(kesariya.frame.minY, tum.frame.minY)
        XCTAssertFalse(agar.exists)
        try ui.wait("The restored queue must contain four songs with Tum Hi Ho selected second") {
            ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "4 songs · 2 of 4")).firstMatch.exists
        }
    }

    @MainActor
    func testPlayerSeekTransportRepeatAndSleepTimer() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 2)
        try ui.pause()
        try ui.assertPausedPositionStaysPut()
        XCTAssertEqual(try ui.duration(), 262, accuracy: 1)
        try ui.seek(to: 0.5)
        try ui.expectPosition(131, tolerance: 4)
        try ui.assertPausedPositionStaysPut()
        try ui.closePlayer()
        try ui.openPlayer()
        try ui.expectPosition(131, tolerance: 4)
        XCTAssertEqual(try ui.position() + ui.remaining(), 262, accuracy: 1)

        // A tap a quarter of the way along the bar lands short of a quarter of the song: the trail continues
        // around the heart, so the bar alone covers less than the whole recording.
        let quarterBar = try ui.seekPosition(atNormalizedX: 0.25)
        XCTAssertLessThan(quarterBar, 65.5)
        XCTAssertGreaterThan(quarterBar, 40)
        ui.app.sliders["player.seek"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        try ui.expectPosition(quarterBar, tolerance: 1)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.closePlayer()
        try ui.openPlayer()
        try ui.expectPosition(quarterBar, tolerance: 1)

        let slider = ui.app.sliders["player.seek"]
        let seekY = slider.frame.minY
        let lowerControl = ui.app.buttons["player.queue"]
        let needsScrolling = lowerControl.exists && lowerControl.frame.maxY > ui.app.windows.firstMatch.frame.maxY
        let verticalStart = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        verticalStart.press(forDuration: 0.05, thenDragTo: verticalStart.withOffset(CGVector(dx: 0, dy: -120)),
                            withVelocity: .slow, thenHoldForDuration: 0.1)
        if needsScrolling {
            XCTAssertLessThan(slider.frame.minY, seekY - 20,
                              "Vertical swipes across the seek bar must scroll the player.")
        }
        try ui.reveal(ui.app.staticTexts["player.elapsed"], direction: .down)
        try ui.expectPosition(quarterBar, tolerance: 1)
        try ui.reveal(ui.app.buttons["player.next"])
        try ui.tap(ui.app.buttons["player.next"])
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.expectPosition(0, tolerance: 1)
        try ui.play()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.seek(to: 0)
        try ui.expectPosition(0, tolerance: 1)
        try ui.tap(ui.app.buttons["player.previous"])
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.expectPosition(0, tolerance: 1)
        try ui.play()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()

        // Shuffle and repeat live in the Queue sheet; the fixed transport row keeps previous, play, and next.
        XCTAssertFalse(ui.app.buttons["player.shuffle"].exists, "Shuffle must not sit in the main transport row.")
        XCTAssertFalse(ui.app.buttons["player.repeat"].exists, "Repeat must not sit in the main transport row.")
        try ui.openPlayerSheet("queue", title: "Queue")
        let shuffle = ui.app.buttons["player.shuffle"]
        try ui.expectLabel(shuffle, "Turn shuffle on")
        XCTAssertFalse(shuffle.isSelected)
        try ui.tap(shuffle)
        try ui.expectLabel(shuffle, "Turn shuffle off")
        XCTAssertTrue(shuffle.isSelected)
        try ui.wait("Turning shuffle on must keep the current song in place") {
            ui.queueSong(id: AppUIFixture.tumHiHo).label.hasPrefix("Current song")
        }
        try ui.tap(shuffle)
        try ui.expectLabel(shuffle, "Turn shuffle on")
        XCTAssertFalse(shuffle.isSelected)

        let repeatButton = ui.app.buttons["player.repeat"]
        try ui.expectLabel(repeatButton, "Repeat off. Repeat queue next.")
        XCTAssertFalse(repeatButton.isSelected)
        try ui.tap(repeatButton)
        try ui.expectLabel(repeatButton, "Repeating queue. Repeat song next.")
        XCTAssertTrue(repeatButton.isSelected)
        try ui.tap(repeatButton)
        try ui.expectLabel(repeatButton, "Repeating song. Turn repeat off next.")
        ui.capture("player-dark-queue-shuffle-repeat-controls")
        try ui.closeSheet("Queue")
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.seek(to: 0.99)
        try ui.wait("The seek must reach the recording's end before testing repeat") {
            (ui.positionIfVisible() ?? 0) >= 254
        }
        try ui.play()
        try ui.wait("Repeat-one must restart the same recording", timeout: 25) {
            guard let position = ui.positionIfVisible() else { return false }
            return position < 8 && ui.app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"].exists
                && ui.app.buttons["player.playPause"].label == "Pause"
        }
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        try ui.tap(repeatButton)
        try ui.expectLabel(repeatButton, "Repeat off. Repeat queue next.")
        try ui.closeSheet("Queue")
        ui.capture("player-dark-seek-transport-controls")

        try ui.openSleepTimerSheet()
        try ui.tap(ui.app.buttons["15 minutes"])
        try ui.wait("Choosing a sleep timer must close the sheet") { !ui.app.navigationBars["Sleep timer"].exists }
        try ui.openPlayerMenu()
        let sleepItem = ui.sleepTimerMenuItem
        try ui.wait("The player menu must show when music stops") {
            sleepItem.exists && sleepItem.label.hasPrefix("Sleep timer · stops at ")
        }
        XCTAssertTrue(ui.app.buttons["Cancel sleep timer"].exists, "An active timer adds a cancel action to the menu.")
        ui.capture("player-dark-menu-sleep-timer-active")
        try ui.tap(sleepItem)
        try ui.wait("The Sleep timer sheet must open") { ui.app.navigationBars["Sleep timer"].exists }
        // The sheet's "Timer active" section is the only place this button exists while the menu is closed.
        try ui.tap(ui.app.buttons["Cancel sleep timer"])
        try ui.wait("Cancelling the sleep timer must close the sheet") { !ui.app.navigationBars["Sleep timer"].exists }
        try ui.openPlayerMenu()
        try ui.wait("Cancelling the sleep timer must clear its deadline") {
            sleepItem.exists && sleepItem.label == "Sleep timer" && !ui.app.buttons["Cancel sleep timer"].exists
        }
    }

    @MainActor
    func testLyricsSeekAndOffsetsPersistPerRecording() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics()
        let line = ui.app.buttons["lyrics.line.2"]
        try ui.reveal(line)
        try ui.tap(line)
        try ui.expectCurrentLyric("lyrics.line.2")
        ui.capture("lyrics-dark-synthetic-timed-line")
        try ui.closeSheet("Lyrics")
        try ui.expectPosition(40, tolerance: 1)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")

        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics()
        let earlier = ui.app.buttons["lyrics.offset.earlier"]
        let later = ui.app.buttons["lyrics.offset.later"]
        let resetTiming = ui.app.buttons["Reset lyric timing"]
        try ui.requireHittable(earlier)
        // The timing controls share one 44-point row so the lyrics keep the rest of the sheet.
        XCTAssertEqual(earlier.frame.midY, later.frame.midY, accuracy: 1)
        XCTAssertEqual(earlier.frame.midY, resetTiming.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(earlier.frame.height, 44 - 1e-6)
        XCTAssertLessThanOrEqual(earlier.frame.height, 48)
        XCTAssertGreaterThanOrEqual(resetTiming.frame.width, 44 - 1e-6)
        for _ in 0..<4 { try ui.tap(later) }
        try ui.expectLyricTiming("2s later")
        try ui.expectCurrentLyric("lyrics.line.1")
        try ui.reveal(line)
        try ui.tap(line)
        try ui.expectCurrentLyric("lyrics.line.2")
        try ui.closeSheet("Lyrics")
        try ui.expectPosition(42, tolerance: 1)

        try ui.relaunch(adding: ["--light"])
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        ui.capture("player-light-restored-lyric-seek")
        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics()
        try ui.expectLyricTiming("2s later")
        ui.capture("lyrics-light-persisted-recording-offset")
        try ui.closeSheet("Lyrics")
        try ui.closePlayer()

        try ui.search("Kesariya")
        try ui.waitForSearchResults()
        ui.capture("search-light-kesariya")
        try ui.playSearchResult(id: AppUIFixture.kesariya, title: "Kesariya")
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics()
        try ui.expectLyricTiming("On time")
        for _ in 0..<2 { try ui.tap(ui.app.buttons["lyrics.offset.earlier"]) }
        try ui.expectLyricTiming("1s earlier")
        let reset = ui.app.buttons["Reset lyric timing"]
        try ui.tap(reset)
        try ui.expectLyricTiming("On time")
        XCTAssertFalse(reset.isEnabled)
    }

    @MainActor
    func testDatedChartsRecapWindowsAndSavedResume() throws {
        let ui = makeDriver()
        try ui.launch()
        let chart = ui.app.buttons["mix.chart:fixture.chart.hindi"]
        try ui.reveal(chart, maxSwipes: 10)
        XCTAssertTrue(chart.label.contains("Weekly picks"))
        XCTAssertTrue(chart.label.contains("India"))
        XCTAssertNotNil(chart.label.range(of: #"[A-Za-z]{3} \d{1,2} – [A-Za-z]{3} \d{1,2}"#, options: .regularExpression),
                        "The Home tile shows the reporting period without the year: \(chart.label)")
        try ui.tap(chart)
        // The detail page carries the full provenance: source plus the dated period including the year.
        try ui.wait("The chart page must show its source and dated reporting period") {
            ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label MATCHES %@", "Test fixture",
                                                    #".*[A-Za-z]{3} \d{1,2}, \d{4} – [A-Za-z]{3} \d{1,2}, \d{4}.*"#)).firstMatch.exists
        }
        try ui.reveal(ui.app.buttons["collection.play"])
        XCTAssertTrue(ui.app.buttons["collection.play"].isEnabled)
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"])
        ui.capture("home-dark-dated-weekly-chart-detail")

        try ui.selectTab("recap")
        // All seeded sessions fit inside every window: 5,359 seconds across 20 completed plays.
        for (window, days) in [("week", 7), ("month", 30), ("year", 365)] {
            let selector = ui.app.buttons["recap.window.\(window)"]
            try ui.reveal(selector, direction: .down)
            try ui.tap(selector)
            try ui.wait("The recap must switch to a rolling \(days)-day window") {
                selector.exists && selector.isSelected && ui.app.staticTexts["YOUR LAST \(days) DAYS"].exists
            }
            try ui.expectMetric("recap.totalListening", number: 89, description: "minutes listened")
            try ui.expectMetric("recap.plays", number: 20, description: "Counted plays")
            try ui.expectMetric("recap.songs", number: 5, description: "Different songs")
            try ui.expectMetric("recap.artists", number: 4, description: "Artists")
            try ui.reveal(ui.element("recap.topArtist"), direction: .down)
            XCTAssertTrue(ui.accessibleText(ui.element("recap.topArtist")).contains("Arijit Singh"))
            try ui.reveal(selector, direction: .down)
            ui.capture("recap-dark-rolling-\(days)-days")
        }

        try ui.selectTab("library")
        let resume = ui.app.buttons["library.resume.\(AppUIFixture.shapeOfYou)"]
        try ui.reveal(resume)
        XCTAssertTrue(resume.label.contains("0:48"))
        ui.capture("library-dark-saved-resume-position")
        let resumeStarted = ProcessInfo.processInfo.systemUptime
        try ui.tap(resume)
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.shapeOfYou)
        try ui.waitForAdvance(from: 48, by: 1)
        try ui.pause()
        let elapsed = ProcessInfo.processInfo.systemUptime - resumeStarted
        XCTAssertLessThanOrEqual(try ui.position(), 48 + elapsed + 2,
                                 "Resume must advance from the saved position, allowing for UI automation time.")
    }

    @MainActor
    func testAppearanceAndHistoryPrivacySurviveRelaunch() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        ui.capture("settings-dark-defaults")
        try ui.setAppearance("Light")
        try ui.setSwitch("settings.history", to: false)
        try ui.setSwitch("settings.remoteFallback", to: true)
        try ui.setSwitch("settings.remoteFallback", to: false)
        ui.capture("settings-light-history-paused")
        try ui.tap(ui.app.buttons["settings.done"])
        ui.capture("home-light-discovery")
        try ui.selectTab("library")
        try ui.reveal(ui.app.buttons["library.history.enable"])
        ui.capture("library-light-history-paused")
        try ui.selectTab("recap")
        try ui.expectMetric("recap.totalListening", number: 89, description: "minutes listened")
        ui.capture("recap-light-earlier-history-preserved")

        try ui.openSettings()
        let clear = ui.app.buttons["settings.clearHistory"]
        try ui.reveal(clear, maxSwipes: 24)
        try ui.tap(clear)
        try ui.tap(ui.app.buttons["Cancel"])
        try ui.wait("Cancelling the confirmation must preserve saved history") { clear.exists && clear.isEnabled }
        try ui.tap(clear)
        try ui.tap(ui.app.buttons["Clear history"])
        try ui.wait("Confirmed history deletion must disable the empty-history action") { clear.exists && !clear.isEnabled }
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 2)
        try ui.pause()
        try ui.closePlayer()
        try ui.selectTab("recap")
        try ui.reveal(ui.element("recap.empty"))
        XCTAssertFalse(ui.element("recap.totalListening").exists,
                       "Playing with history disabled must not rebuild the cleared recap.")

        try ui.relaunch()
        try ui.openSettings()
        try ui.reveal(ui.element("settings.appearance"), maxSwipes: 24)
        XCTAssertTrue(ui.accessibleText(ui.element("settings.appearance")).contains("Light"))
        try ui.expectSwitch("settings.history", isOn: false)
        try ui.reveal(ui.app.buttons["settings.clearHistory"], maxSwipes: 24)
        XCTAssertFalse(ui.app.buttons["settings.clearHistory"].isEnabled)
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.selectTab("library")
        try ui.reveal(ui.playlist(named: AppUIFixture.seededPlaylist))
        XCTAssertEqual(ui.playlists(named: AppUIFixture.seededPlaylist).count, 1,
                       "Relaunching after clearing history must not seed another playlist.")
        try ui.reveal(ui.app.buttons["library.likes"], direction: .down)
        XCTAssertTrue(ui.accessibleText(ui.app.buttons["library.likes"]).contains("5 songs"),
                      "Clearing history and relaunching must preserve every like.")
        try ui.selectTab("recap")
        try ui.reveal(ui.element("recap.empty"))
        ui.capture("recap-light-cleared-history-after-relaunch")

        try ui.selectTab("library")
        try ui.reveal(ui.app.buttons["library.history.enable"], direction: .down)
        try ui.tap(ui.app.buttons["library.history.enable"])
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 2)
        try ui.pause()
        let listened = try ui.position()
        try ui.seek(to: 0.8)
        try ui.expectPosition(210, tolerance: 4)
        try ui.closePlayer()
        try ui.selectTab("recap")
        try ui.reveal(ui.element("recap.totalListening"))
        let total = try ui.recapSeconds()
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(total, listened + 3, "A paused seek must not be counted as listening time.")
    }

    @MainActor
    func testLargeDynamicTypeKeepsLibraryPlayerLyricsAndSettingsReachable() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.selectTab("library")
        let libraryTitle = ui.app.staticTexts["Your library"]
        try ui.requireHittable(libraryTitle)
        let standardTitleHeight = libraryTitle.frame.height
        ui.capture("library-compact-standard-text-baseline")

        let category = UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue
        try ui.relaunch(adding: ["-UIPreferredContentSizeCategoryName", category])
        try ui.selectTab("library")
        try ui.requireHittable(libraryTitle)
        XCTAssertGreaterThan(libraryTitle.frame.height, standardTitleHeight * 1.5,
                             "The system launch argument must enlarge the rendered text.")
        ui.note("large-dynamic-type-configuration", "Category: \(category)\nWindow: \(ui.app.windows.firstMatch.frame)")
        ui.capture("library-compact-accessibility-xxxl")
        try ui.reveal(ui.app.buttons["library.likes"])
        try ui.tap(ui.app.buttons["library.likes"])
        let song = ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try ui.reveal(song)
        ui.capture("library-compact-accessibility-xxxl-liked-song")
        try ui.tap(song)
        try ui.wait("Playing a liked song must update the mini-player") {
            let mini = ui.app.buttons["miniPlayer.open"]
            return mini.exists && mini.label.contains("Tum Hi Ho")
        }
        try ui.tap(ui.app.navigationBars["Liked songs"].buttons["Back"])
        try ui.assertMiniPlayerAboveTabs()

        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.reveal(ui.app.staticTexts["player.track.\(AppUIFixture.tumHiHo)"], direction: .down)
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.seek(to: 0.5)
        try ui.expectPosition(131, tolerance: 4)
        try ui.assertPausedPositionStaysPut()
        try ui.reveal(ui.app.buttons["player.playPause"])
        try ui.requireHittable(ui.app.buttons["player.previous"])
        try ui.requireHittable(ui.app.buttons["player.next"])
        ui.capture("player-compact-accessibility-xxxl-controls")

        try ui.openPlayerSheet("lyrics", title: "Lyrics")
        try ui.requireSyncedLyrics()
        let line = ui.app.buttons["lyrics.line.2"]
        try ui.reveal(line, direction: .down)
        try ui.tap(line)
        try ui.expectCurrentLyric("lyrics.line.2")
        for _ in 0..<2 { try ui.tap(ui.app.buttons["lyrics.offset.later"]) }
        try ui.expectLyricTiming("1s later")
        try ui.reveal(line)
        try ui.tap(line)
        try ui.expectCurrentLyric("lyrics.line.2")
        ui.capture("lyrics-compact-accessibility-xxxl-seek-and-offset")
        try ui.closeSheet("Lyrics")
        try ui.expectPosition(41, tolerance: 1)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        try ui.closePlayer()

        try ui.openSettings()
        try ui.setAppearance("Light")
        try ui.setSwitch("settings.history", to: false)
        ui.capture("settings-compact-accessibility-xxxl-history-paused")
        try ui.tap(ui.app.buttons["settings.done"])
        try ui.selectTab("library")
        let enableHistory = ui.app.buttons["library.history.enable"]
        try ui.reveal(enableHistory, direction: .down)
        ui.capture("library-compact-accessibility-xxxl-history-action")
        try ui.tap(enableHistory)
        try ui.wait("Library must resume listening history") { !enableHistory.exists }
        try ui.assertMiniPlayerAboveTabs()
        try ui.openSettings()
        try ui.expectSwitch("settings.history", isOn: true)
        try ui.tap(ui.app.buttons["settings.done"])
    }

    @MainActor
    func testWelcomeStartsWithoutLanguageSelectionAndLandscapeKeyboardRemainsReachable() throws {
        let ui = makeDriver()
        try ui.launch(skipWelcome: false)
        let start = ui.app.buttons["welcome.continue"]
        try ui.expectLabel(start, "Start listening")
        XCTAssertTrue(start.isEnabled)
        XCTAssertGreaterThanOrEqual(start.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(start.frame.height + 1e-6, 44)
        XCTAssertFalse(ui.app.buttons["welcome.hindi"].exists)
        XCTAssertFalse(ui.app.buttons["welcome.english"].exists)
        ui.capture("welcome-dark-single-start-action")
        try ui.tap(start)
        try ui.requireHittable(ui.app.tabBars.buttons["Home"])

        try ui.relaunch()
        XCTAssertFalse(ui.app.buttons["welcome.continue"].exists,
                       "This relaunch omits --skip-welcome to verify persisted completion.")
        try ui.openSettings()
        let languages = ui.app.buttons["settings.languages"]
        try ui.reveal(languages, maxSwipes: 24)
        XCTAssertTrue(languages.label.contains("Listening languages"))
        try ui.tap(languages)
        try ui.wait("Language statistics must open without a required preference form") {
            ui.app.navigationBars["Listening languages"].exists
        }
        XCTAssertFalse(ui.app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.language.")).firstMatch.exists)
        let tuning = ui.app.buttons["listeningLanguages.tune"]
        try ui.reveal(tuning)
        try ui.expectValue(tuning, "Collapsed")
        try ui.tap(tuning)
        for code in ["hi", "en"] {
            let menu = ui.app.buttons["listeningLanguages.nudge.\(code)"]
            try ui.reveal(menu)
            try ui.expectValue(menu, "Automatic")
            XCTAssertTrue(menu.isEnabled)
        }
        try ui.tap(ui.app.navigationBars["Listening languages"].buttons.firstMatch)
        try ui.tap(ui.app.buttons["settings.done"])

        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
        try ui.assertMiniPlayerAboveTabs()
        try ui.rotateToLandscape()
        let field = ui.app.textFields["search.field"]
        try ui.tap(field)
        try ui.wait("The search keyboard must be visible in landscape") { ui.app.keyboards.firstMatch.exists }
        XCTAssertLessThanOrEqual(field.frame.maxY, ui.app.keyboards.firstMatch.frame.minY + 1)
        try ui.clearSearch()
        field.typeText("Kesariya")
        try ui.requireHittable(ui.app.buttons["Done"])
        ui.capture("search-landscape-keyboard-input-and-done-reachable")
        try ui.dismissSearchKeyboard()
        try ui.playSearchResult(id: AppUIFixture.kesariya, title: "Kesariya")
        try ui.assertMiniPlayerAboveTabs()
        ui.capture("search-landscape-mini-player-above-navigation")

        try ui.rotateToPortrait()
        try ui.openPlayer()
        try ui.reveal(ui.app.buttons["player.playPause"])
        try ui.requireHittable(ui.app.buttons["player.previous"])
        try ui.requireHittable(ui.app.buttons["player.next"])
        ui.capture("player-portrait-controls-reachable-after-rotation")
    }

    @MainActor
    func testPlayerArtistNameOpensDirectlyAndBrowseOffersMultipleCredits() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        let artistLine = ui.app.buttons["player.artistName"]
        try ui.expectLabel(artistLine, "Go to artist, Arijit Singh")
        try ui.tap(artistLine)
        try ui.expectArtistPage(named: "Arijit Singh")
        ui.capture("search-dark-artist-page-from-player")

        // The duet sits in the artist's top songs; playing it there queues the page's songs.
        let duet = ui.app.buttons["track.play.\(AppUIFixture.agarTumSaathHo)"]
        try ui.reveal(duet)
        try ui.tap(duet)
        try ui.wait("Playing the duet must update the mini-player") {
            ui.app.buttons["miniPlayer.open"].exists && ui.app.buttons["miniPlayer.open"].label.contains("Agar Tum Saath Ho")
        }
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.agarTumSaathHo)
        try ui.expectLabel(artistLine, "Go to artist, Alka Yagnik, Arijit Singh")
        try ui.tap(ui.app.buttons["player.browse"])
        try ui.wait("Browse must offer every credited artist immediately") {
            ui.app.buttons["player.artist.0"].exists && ui.app.buttons["player.artist.1"].exists
                && ui.app.navigationBars["Album and artists"].exists
        }
        let picker = ui.element("player.browse.sheet")
        XCTAssertTrue(picker.exists, "Album and artists opens its own sheet rather than the options sheet.")
        XCTAssertFalse(ui.element("player.options.sheet").exists)
        XCTAssertFalse(ui.app.buttons["player.browse.album"].exists, "An album title alone must not invent an album destination.")
        try ui.requireHittable(ui.app.buttons["player.artist.1"])
        XCTAssertLessThan(picker.frame.maxY - ui.app.buttons["player.artist.1"].frame.maxY, 80,
                          "Two credits must open a sheet sized to its rows, not a half-height sheet.")
        ui.capture("player-dark-choose-artist")
        try ui.tap(ui.app.buttons["player.artist.0"])
        try ui.expectArtistPage(named: "Alka Yagnik")
        try ui.reveal(duet)
        XCTAssertFalse(ui.app.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists,
                       "Alka Yagnik's page lists only songs that credit her.")
        ui.capture("search-dark-artist-page-from-credit-choice")
    }

    @MainActor
    func testAlbumPageArtistLinkOpensTheArtistPage() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        try ui.selectSearchFilter("albums")
        let album = ui.app.buttons["collection.\(AppUIFixture.album)"]
        try ui.wait("The albums filter must show the fixture album") { album.exists }
        try ui.reveal(album)
        try ui.tap(album)
        try ui.wait("The album page must open") { ui.app.staticTexts["ALBUM"].exists }
        let artistLink = ui.app.buttons["collection.artist.\(AppUIFixture.arijitSinghID)"]
        try ui.wait("The album header must link its credited artist once the catalog page loads") { artistLink.exists }
        try ui.expectLabel(artistLink, "Go to artist, Arijit Singh")
        ui.capture("search-dark-album-artist-link")
        try ui.reveal(artistLink)
        try ui.tap(artistLink)
        try ui.expectArtistPage(named: "Arijit Singh")
        try ui.reveal(ui.app.buttons["track.play.\(AppUIFixture.kesariya)"])
    }

    @MainActor
    func testSearchResultPlaysAloneAndAutoplayFillsTheQueue() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.search("Arijit")
        try ui.waitForSearchResults()
        for id in [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo] {
            try ui.reveal(ui.app.buttons["track.play.\(id)"])
        }
        try ui.playSearchResult(id: AppUIFixture.kesariya, title: "Kesariya")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.openPlayerSheet("queue", title: "Queue")
        // The other results were not queued behind Kesariya; its radio fills the queue instead.
        try ui.requireHittable(ui.element("queue.play.0.\(AppUIFixture.kesariya)"))
        try ui.wait("Autoplay must follow the tapped song with the provider radio") {
            ui.app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "5 songs · 1 of 5")).firstMatch.exists
                && ui.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Autoplay")).firstMatch.exists
        }
        let next = ui.app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play.1.")).firstMatch
        try ui.requireHittable(next)
        XCTAssertTrue(next.label.hasSuffix(", Autoplay"), "Songs after the tapped result must be marked as Autoplay: \(next.label)")
        ui.capture("player-dark-search-result-autoplay-queue")
    }

    @MainActor
    private func makeDriver() -> AppUITestDriver {
        let driver = AppUITestDriver(testCase: self, prefix: "workflow")
        addTeardownBlock { await driver.finish() }
        return driver
    }
}

enum AppUIFixture {
    static let tumHiHo = "fsiPzT50ZiM"
    static let kesariya = "NJAv_7lHUIU"
    static let agarTumSaathHo = "FOA9iyxsW_A"
    static let blindingLights = "J7p4bzqLvCw"
    static let shapeOfYou = "xTvyyoF_LZY"
    static let album = "fixture.album"
    static let arijitSinghID = "UCfixtureArijitSingh0001"
    static let alkaYagnikID = "UCfixtureAlkaYagnik00001"
    static let seededPlaylist = "Late night favorites"
}

@MainActor
final class AppUITestDriver {
    enum Mode: Equatable { case fixtures, live }
    enum ScrollDirection: Equatable { case up, down }

    let app = XCUIApplication()
    let storeName: String
    private unowned let testCase: XCTestCase
    private var mode: Mode = .fixtures
    private var skipWelcome = true
    private var additionalArguments: [String] = []
    private var hasCapturedFailure = false

    init(testCase: XCTestCase, prefix: String) {
        self.testCase = testCase
        storeName = "\(prefix)-\(UUID().uuidString)"
    }

    func launch(mode: Mode = .fixtures, skipWelcome: Bool = true, reset: Bool = true,
                additionalArguments: [String] = []) throws {
        self.mode = mode
        self.skipWelcome = skipWelcome
        self.additionalArguments = additionalArguments
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--uitesting"]
            + (ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" ? ["--ui-scene-geometry"] : [])
            + (ProcessInfo.processInfo.environment["GANABAJANA_UI_LAYOUT_DIAGNOSTICS"] == "1" ? ["--ui-layout-diagnostics"] : [])
            + (mode == .fixtures ? ["--seed-ui"] : [])
            + (skipWelcome ? ["--skip-welcome"] : [])
            + (reset ? ["--reset-ui"] : [])
            + additionalArguments
            + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["GANABAJANA_TEST_STORE": storeName]
        app.launch()
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            Self.requestSceneGeometry(.portrait)
            try wait("The test must begin with a portrait scene") {
                let frame = self.app.windows.firstMatch.frame
                return frame.height > frame.width
            }
        }
        let initial = reset && !skipWelcome ? app.buttons["welcome.continue"] : app.tabBars.buttons["Home"]
        try requireHittable(initial, timeout: 25)
    }

    func relaunch(adding arguments: [String] = []) throws {
        app.terminate()
        try launch(mode: mode, skipWelcome: skipWelcome, reset: false,
                   additionalArguments: additionalArguments + arguments)
    }

    func finish() {
        if (testCase.testRun?.failureCount ?? 0) > 0 || (testCase.testRun?.unexpectedExceptionCount ?? 0) > 0 {
            captureFailure("test-failure")
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func wait(_ message: String, timeout: TimeInterval = 10,
              condition: @escaping @MainActor @Sendable () -> Bool) throws {
        if condition() { return }
        let predicate = NSPredicate { _, _ in MainActor.assumeIsolated { condition() } }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            captureFailure("wait-failure", detail: message)
            throw AppUIWorkflowFailure(message: "\(message) (wait result: \(result.rawValue), store: \(storeName))")
        }
    }

    func requireHittable(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        try wait("The requested UI element must exist and be reachable", timeout: timeout) {
            self.isReachable(element)
        }
    }

    /// The tab-bar accessory animates in and out; hittability queries during that window raise XCTest errors.
    private func hasSettledFrame(_ element: XCUIElement) -> Bool {
        let first = element.frame
        guard usableFrame(first) else { return false }
        Thread.sleep(forTimeInterval: 0.25)
        let second = element.frame
        return usableFrame(second) && abs(first.minY - second.minY) < 0.5 && abs(first.height - second.height) < 0.5
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
            && !frame.isEmpty && !frame.isNull
    }

    private func isReachable(_ element: XCUIElement, within viewport: CGRect? = nil) -> Bool {
        guard element.exists else { return false }
        let isAccessory = element.identifier.hasPrefix("miniPlayer.")
        if isAccessory, !hasSettledFrame(element) { return false }
        let frame = element.frame
        let viewport = viewport ?? app.windows.firstMatch.frame
        // Lazy controls can exist with invalid geometry; asking XCTest for hittability then raises an exception.
        guard usableFrame(frame), usableFrame(viewport),
              viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        let visible = frame.intersection(viewport)
        guard visible.width >= min(frame.width, 44), visible.height >= min(frame.height, 44) else { return false }
        // The system tab accessory has no stable activation point while it settles, so its frame is the proof.
        return isAccessory || element.isHittable
    }

    private func scrollViewport(_ region: XCUIElement) -> CGRect {
        let frame = region.frame
        guard usableFrame(frame) else { return .null }
        var viewport = frame.intersection(app.windows.firstMatch.frame)
        guard usableFrame(viewport) else { return .null }
        let indicators = region.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Vertical scroll bar"))
            .allElementsBoundByIndex.map(\.frame).filter { usableFrame($0) && $0.intersects(viewport) }
        if let indicator = indicators.max(by: { $0.height < $1.height }) {
            // Scroll indicators have their own top padding, even when the first content row is fully visible.
            viewport.size.height = max(0, min(viewport.maxY, indicator.maxY) - viewport.minY)
        }
        for bar in app.navigationBars.allElementsBoundByIndex {
            let barFrame = bar.frame
            if usableFrame(barFrame), barFrame.intersects(viewport), barFrame.minY < viewport.midY {
                let top = max(viewport.minY, barFrame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width,
                                  height: max(0, viewport.maxY - top))
            }
        }
        var bottom = viewport.maxY
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, usableFrame(keyboard.frame), keyboard.frame.intersects(viewport) {
            bottom = min(bottom, keyboard.frame.minY)
        }
        for id in ["search.dismissKeyboard.toolbar", "radio.setup.dismissKeyboard"] {
            let footer = app.buttons[id]
            if footer.exists, usableFrame(footer.frame), footer.frame.intersects(viewport) {
                bottom = min(bottom, footer.frame.minY)
            }
        }
        let tabs = app.tabBars.firstMatch
        if tabs.exists, usableFrame(tabs.frame), tabs.isHittable, tabs.frame.intersects(viewport) {
            bottom = min(bottom, tabs.frame.minY)
            let mini = app.buttons["miniPlayer.open"]
            if mini.exists, usableFrame(mini.frame), mini.frame.intersects(viewport) {
                bottom = min(bottom, mini.frame.minY)
            }
        }
        viewport.size.height = max(0, bottom - viewport.minY)
        return viewport
    }

    private func contains(_ region: XCUIElement, element: XCUIElement) -> Bool {
        guard region.exists, element.exists else { return false }
        let identifier = element.identifier
        if !identifier.isEmpty {
            return region.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
        }
        let descendants = region.descendants(matching: element.elementType)
        let label = element.label
        let frame = element.frame
        guard usableFrame(frame) else { return false }
        let matches = label.isEmpty ? descendants : descendants.matching(NSPredicate(format: "label == %@", label))
        return matches.allElementsBoundByIndex.contains { $0.frame == frame }
    }

    func tap(_ element: XCUIElement) throws {
        try requireHittable(element)
        guard element.isEnabled else {
            throw AppUIWorkflowFailure(message: "Expected an enabled control: \(element.identifier), \(element.label)")
        }
        if element.identifier.hasPrefix("miniPlayer.") {
            let window = app.windows.firstMatch
            let frame = element.frame, bounds = window.frame
            guard usableFrame(frame), usableFrame(bounds), bounds.contains(frame) else {
                throw AppUIWorkflowFailure(message: "The mini-player target moved outside the window before tapping.")
            }
            // Native accessory snapshots can lose their coordinate origin during a transition.
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX - bounds.minX, dy: frame.midY - bounds.minY)).tap()
        } else {
            element.tap()
        }
    }

    func scrollable() throws -> XCUIElement {
        try scrollRegion().element
    }

    private func scrollRegion(containing target: XCUIElement? = nil) throws -> (element: XCUIElement, viewport: CGRect, containsTarget: Bool) {
        let existingTarget = target?.exists == true ? target : nil
        let candidates = app.scrollViews.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        let regions = candidates.compactMap { region -> (element: XCUIElement, viewport: CGRect, containsTarget: Bool)? in
            guard region.exists else { return nil }
            let viewport = scrollViewport(region)
            let ownsTarget = existingTarget.map { contains(region, element: $0) } ?? false
            return (region, viewport, ownsTarget)
        }.sorted { $0.viewport.height > $1.viewport.height }
        // Ownership is independent of container hittability; clipping must never fall back to the window.
        if let owner = regions.first(where: { $0.containsTarget }) { return owner }
        let visibleRegions = regions.filter { usableFrame($0.viewport) && $0.viewport.height > 50 }
        if let region = visibleRegions.first(where: { isReachable($0.element, within: $0.viewport) }) {
            return region
        }
        for region in visibleRegions {
            if region.element.buttons.allElementsBoundByIndex.contains(where: { isReachable($0, within: region.viewport) })
                || region.element.staticTexts.allElementsBoundByIndex.contains(where: { isReachable($0, within: region.viewport) }) {
                return region
            }
        }
        throw AppUIWorkflowFailure(message: "No visible scroll container on the current screen.")
    }

    func reveal(_ element: XCUIElement, direction: ScrollDirection = .up, maxSwipes: Int = 8) throws {
        // Fixed player controls are outside the covered collection's scroller, which can remain in the AX tree.
        let player = app.otherElements["player.screen"]
        if player.exists, contains(player, element: element), isReachable(element, within: player.frame) { return }
        var lastContext = "No scroll container"
        for attempt in 0...maxSwipes {
            var context = try? scrollRegion(containing: element)
            if let current = context, current.containsTarget, !usableFrame(current.viewport) {
                try wait("The destination's owning scroll viewport must finish laying out") {
                    guard let ready = try? self.scrollRegion(containing: element) else { return false }
                    return ready.containsTarget && self.usableFrame(ready.viewport)
                }
                context = try? scrollRegion(containing: element)
            }
            let constrainedViewport = context?.containsTarget == true ? context?.viewport : nil
            if isReachable(element, within: constrainedViewport) { return }
            guard attempt < maxSwipes, let context else { break }
            let viewport = context.viewport
            lastContext = "Scroll \(context.element.identifier), owns target: \(context.containsTarget), viewport: \(viewport)"
            let window = app.windows.firstMatch
            let windowFrame = window.frame
            guard usableFrame(viewport), viewport.height > 50, usableFrame(windowFrame) else { break }
            var scrollDirection = direction
            if element.exists, usableFrame(element.frame) {
                scrollDirection = element.frame.midY < viewport.midY ? .down : .up
            }
            let top = viewport.minY + viewport.height * 0.3
            let bottom = viewport.minY + viewport.height * 0.7
            let x = viewport.minX + min(12, viewport.width * 0.05)
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: x - windowFrame.minX,
                                                  dy: (scrollDirection == .up ? bottom : top) - windowFrame.minY))
            let end = origin.withOffset(CGVector(dx: x - windowFrame.minX,
                                                dy: (scrollDirection == .up ? top : bottom) - windowFrame.minY))
            // Hold before lifting so momentum cannot skip a lazy row between visibility checks.
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        captureFailure("reveal-failure", detail: "The requested element could not be scrolled into the visible content area: \(element). \(lastContext)")
        throw AppUIWorkflowFailure(message: "The requested UI element could not be reached by scrolling.")
    }

    func selectTab(_ tab: String) throws {
        if app.buttons["search.dismissKeyboard"].exists { try dismissSearchKeyboard() }
        let button = app.tabBars.buttons[tab.capitalized]
        try tap(button)
        if tab == "search" {
            try wait("The Search tab must show the search field") {
                self.app.textFields["search.field"].exists
            }
            try dismissKeyboardIntroduction()
        } else {
            try wait("The \(tab) tab must become selected") { button.exists && button.isSelected }
        }
    }

    func dismissKeyboardIntroduction() throws {
        let introduction = app.otherElements["UIContinuousPathIntroductionView"]
        if introduction.exists {
            try tap(introduction.buttons["Continue"])
            try wait("The system keyboard introduction must close") { !introduction.exists }
        }
    }

    func search(_ query: String, dismissKeyboard: Bool = true) throws {
        try selectTab("search")
        try replaceSearchQuery(query, dismissKeyboard: dismissKeyboard)
    }

    func replaceSearchQuery(_ query: String, dismissKeyboard: Bool = true) throws {
        let field = app.textFields["search.field"]
        try requireHittable(field)
        if app.buttons["Clear search"].exists { try clearSearch() }
        else { try tap(field) }
        field.typeText(query)
        if dismissKeyboard { try dismissSearchKeyboard() }
    }

    func clearSearch() throws {
        try tap(app.buttons["Clear search"])
        try wait("The clear control must empty the search field") {
            let field = self.app.textFields["search.field"]
            guard field.exists, let value = field.value as? String else { return false }
            return value.isEmpty || value == field.placeholderValue
        }
    }

    func dismissSearchKeyboard() throws {
        let field = app.textFields["search.field"]
        let done = app.buttons["search.dismissKeyboard"]
        try requireHittable(done)
        let entered = field.value as? String
        try tap(done)
        try wait("Done must end search editing, preserve the query, and restore tab navigation") {
            guard !done.exists, self.isReachable(self.app.tabBars.buttons["Search"]), field.exists else { return false }
            let current = field.value as? String
            let wasEmpty = entered == "" || entered == field.placeholderValue
            let isEmpty = current == "" || current == field.placeholderValue
            return current == entered || (wasEmpty && isEmpty)
        }
    }

    func selectSearchFilter(_ filter: String) throws {
        guard !element("search.offline").exists else {
            throw AppUIWorkflowFailure(message: "Offline Search uses saved results and has no catalog filter chips.")
        }
        try wait("Catalog filters must appear after the current query has executed") {
            self.app.buttons["search.filter.songs"].exists
        }
        let strips = app.scrollViews.containing(.button, identifier: "search.filter.songs").allElementsBoundByIndex
        guard let strip = strips.min(by: { $0.frame.height < $1.frame.height }) else {
            throw AppUIWorkflowFailure(message: "Search filter scroll row is missing.")
        }
        try reveal(strip, direction: .down)
        let button = app.buttons["search.filter.\(filter)"]
        for _ in 0..<4 {
            if button.exists && button.isHittable { break }
            if button.exists && button.frame.minX < strip.frame.minX { strip.swipeRight() }
            else { strip.swipeLeft() }
        }
        try tap(button)
        try wait("The \(filter) search filter must be selected") { button.exists && button.isSelected }
    }

    func waitForSearchResults(timeout: TimeInterval = 10) throws {
        let results = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                       "track.play.", "collection."))
        let empty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "No ", " found")).firstMatch
        try wait("Search must finish with results or an explicit error", timeout: timeout) {
            results.firstMatch.exists || self.app.staticTexts["Search couldn't finish"].exists || empty.exists
        }
        if app.staticTexts["Search couldn't finish"].exists || empty.exists {
            captureFailure("search-failure", detail: "Expected playable catalog results.")
            throw AppUIWorkflowFailure(message: "Search returned an error or no songs; see the accessibility attachment.")
        }
    }

    func playSearchResult(id: String, title: String, timeout: TimeInterval = 10) throws {
        try waitForSearchResults(timeout: timeout)
        let row = app.buttons["track.play.\(id)"]
        try reveal(row)
        try tap(row)
        try wait("Playing \(title) must update the mini-player") {
            self.app.buttons["miniPlayer.open"].exists && self.app.buttons["miniPlayer.open"].label.contains(title)
        }
    }

    func searchAndPlayTumHiHo() throws {
        try search("Tum Hi Ho")
        try playSearchResult(id: AppUIFixture.tumHiHo, title: "Tum Hi Ho")
    }

    func openPlayer() throws {
        try tap(app.buttons["miniPlayer.open"])
        try requireHittable(app.buttons["player.close"])
        try reveal(app.buttons["player.playPause"])
        try reveal(app.staticTexts["Elapsed time"], direction: .down)
    }

    func closePlayer() throws {
        try tap(app.buttons["player.close"])
        try requireHittable(app.buttons["miniPlayer.open"])
    }

    func expectCurrentTrack(_ id: String) throws {
        try wait("The visible player must select recording \(id)") {
            let title = self.app.staticTexts["player.track.\(id)"]
            return self.app.buttons["player.close"].exists && title.exists && title.isHittable
        }
    }

    func pause() throws {
        let button = app.buttons["player.playPause"]
        try reveal(button, direction: .down)
        try expectLabel(button, "Pause")
        try tap(button)
        try expectLabel(button, "Play")
    }

    func play() throws {
        let button = app.buttons["player.playPause"]
        try reveal(button, direction: .down)
        try expectLabel(button, "Play")
        try tap(button)
        try expectLabel(button, "Pause")
    }

    func seek(to fraction: CGFloat) throws {
        let slider = app.sliders["player.seek"]
        try reveal(slider, direction: .down)
        guard slider.isEnabled else {
            throw AppUIWorkflowFailure(message: "Playback seek is disabled despite a known recording duration.")
        }
        let total = try duration()
        guard total > 0 else { throw AppUIWorkflowFailure(message: "The seek slider has no usable range.") }
        // The drag starts on the bar and may end past it: the last stretch of the song lies along the heart outline.
        let targetFraction = min(max(fraction, 0), 1)
        let currentFraction = min(max(try position() / total, 0), 1)
        let startX = min(app.playerSeekNormalizedX(forProgress: currentFraction), 0.98)
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: app.playerSeekNormalizedX(forProgress: targetFraction), dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Playback position the app seeks to for a tap or release at the normalized offset within the seek element.
    func seekPosition(atNormalizedX dx: CGFloat) throws -> TimeInterval {
        try duration() * app.playerSeekProgress(atNormalizedX: dx)
    }

    func positionIfVisible() -> TimeInterval? {
        let elapsed = app.staticTexts["player.elapsed"]
        guard elapsed.exists else { return nil }
        let frame = elapsed.frame
        guard !frame.isEmpty, app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return AppUIClock.seconds(elapsed.value as? String)
    }

    func position() throws -> TimeInterval {
        guard let result = positionIfVisible() else {
            throw AppUIWorkflowFailure(message: "The visible Elapsed time accessibility value is missing or invalid.")
        }
        return result
    }

    func remaining() throws -> TimeInterval {
        let remaining = app.staticTexts["Remaining time"]
        guard remaining.exists, let result = AppUIClock.seconds(remaining.value as? String) else {
            throw AppUIWorkflowFailure(message: "The visible Remaining time accessibility value is missing or invalid.")
        }
        return result
    }

    func duration() throws -> TimeInterval {
        let slider = app.sliders["player.seek"]
        guard slider.exists, let description = slider.value as? String,
              description.contains(" of "), let total = description.components(separatedBy: " of ").last,
              let duration = AppUIClock.seconds(total) else {
            throw AppUIWorkflowFailure(message: "player.seek must describe elapsed and total duration as displayed in the player.")
        }
        return duration
    }

    func expectPosition(_ expected: TimeInterval, tolerance: TimeInterval = 1) throws {
        try wait("The committed player position must be \(expected) ± \(tolerance) seconds") {
            guard let value = self.positionIfVisible() else { return false }
            return abs(value - expected) <= tolerance
        }
    }

    func waitForAdvance(from start: TimeInterval, by seconds: TimeInterval, timeout: TimeInterval = 15) throws {
        let baseline = max(start, positionIfVisible() ?? start)
        try wait("Playback must advance from \(baseline) by at least \(seconds) seconds", timeout: timeout) {
            guard let value = self.positionIfVisible(), self.app.buttons["player.playPause"].exists else { return false }
            return value >= baseline + seconds && self.app.buttons["player.playPause"].label == "Pause"
        }
    }

    func assertPausedPositionStaysPut(for interval: TimeInterval = 2.5) throws {
        try expectLabel(app.buttons["player.playPause"], "Play")
        let initial = try position()
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                guard let current = self.positionIfVisible() else { return false }
                return abs(current - initial) > 1
            }
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.isInverted = true
        guard XCTWaiter.wait(for: [expectation], timeout: interval) == .completed else {
            throw AppUIWorkflowFailure(message: "Playback advanced while paused, from \(initial) seconds.")
        }
        try expectLabel(app.buttons["player.playPause"], "Play")
        XCTAssertEqual(try position(), initial, accuracy: 1)
    }

    func openPlayerSheet(_ id: String, title: String) throws {
        let button = app.buttons["player.\(id)"]
        try reveal(button)
        try tap(button)
        try wait("The \(title) sheet must open") { self.app.navigationBars[title].exists }
    }

    func openPlayerMenu() throws {
        try tap(app.buttons["player.menu"])
        try wait("The player menu must open") { self.app.buttons["Add to playlist"].exists }
    }

    /// The sleep timer lives in the player menu; its label carries the deadline while a timer runs.
    var sleepTimerMenuItem: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label BEGINSWITH %@",
                                         "player.sleepTimer", "Sleep timer")).firstMatch
    }

    func openSleepTimerSheet() throws {
        try openPlayerMenu()
        try tap(sleepTimerMenuItem)
        try wait("The Sleep timer sheet must open") { self.app.navigationBars["Sleep timer"].exists }
    }

    /// Artist pages open on the current tab and close the player first.
    func expectArtistPage(named name: String) throws {
        try wait("The artist page for \(name) must open") {
            !self.app.buttons["player.close"].exists && self.app.staticTexts["ARTIST"].exists
                && self.app.staticTexts[name].exists && self.app.buttons["collection.follow"].exists
        }
    }

    func closeSheet(_ title: String) throws {
        try tap(app.navigationBars[title].buttons["Done"])
        try wait("The \(title) sheet must close") { !self.app.navigationBars[title].exists }
        try reveal(app.staticTexts["Elapsed time"], direction: .down)
    }

    func requireSyncedLyrics(timeout: TimeInterval = 15) throws {
        try wait("Lyrics must finish loading with an explicit state", timeout: timeout) {
            self.element("lyrics.synced").exists || self.element("lyrics.plain").exists
                || self.element("lyrics.instrumental").exists || self.element("lyrics.unavailable").exists
                || self.app.buttons["lyrics.retry"].exists
        }
        guard element("lyrics.synced").exists else {
            captureFailure("lyrics-not-synced", detail: "This recording is expected to have synchronized lyrics.")
            throw AppUIWorkflowFailure(message: "Expected synchronized lyrics, but received a plain, instrumental, unavailable, or failed state. See lyrics-not-synced attachments.")
        }
    }

    func expectCurrentLyric(_ id: String) throws {
        try wait("The synchronized lyric \(id) must follow playback position") {
            self.app.buttons[id].exists && self.app.buttons[id].value as? String == "Current line"
        }
    }

    func expectLyricTiming(_ text: String) throws {
        try wait("Lyric timing must show \(text)") {
            self.app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", "Lyric timing", text
            )).firstMatch.exists
        }
    }

    func openSettings() throws {
        try selectTab("home")
        try reveal(app.buttons["home.settings"], direction: .down, maxSwipes: 12)
        try tap(app.buttons["home.settings"])
        try requireHittable(app.buttons["settings.done"])
    }

    func openHomeCustomization() throws {
        try openSettings()
        let link = app.buttons["settings.customizeHome"]
        try reveal(link, maxSwipes: 24)
        try tap(link)
        try wait("Settings must open the Home customization editor") { self.app.navigationBars["Customize Home"].exists }
    }

    func closeHomeCustomization() throws {
        try tap(app.navigationBars["Customize Home"].buttons.firstMatch)
        try wait("Back from customization must return to Settings") { self.app.navigationBars["Settings"].exists }
        try tap(app.buttons["settings.done"])
        try requireHittable(app.buttons["home.settings"])
    }

    func setAppearance(_ appearance: String) throws {
        try reveal(element("settings.appearance"), maxSwipes: 24)
        try tap(element("settings.appearance"))
        try tap(app.buttons[appearance])
        try wait("Appearance must change to \(appearance)") {
            self.accessibleText(self.element("settings.appearance")).contains(appearance)
        }
    }

    func expectSwitch(_ id: String, isOn: Bool) throws {
        let control = app.switches[id]
        try reveal(control, maxSwipes: 24)
        try wait("\(id) must be \(isOn ? "on" : "off")") {
            control.exists && control.value as? String == (isOn ? "1" : "0")
        }
    }

    func setSwitch(_ id: String, to enabled: Bool) throws {
        let row = app.switches[id]
        try reveal(row, maxSwipes: 24)
        let current = row.value as? String
        guard current == "0" || current == "1" else {
            throw AppUIWorkflowFailure(message: "\(id) does not expose a native switch value: \(String(describing: current))")
        }
        if current != (enabled ? "1" : "0") {
            let nativeSwitch = row.switches.firstMatch
            // Native accessibility representations can contain zero-sized virtual children; use the visible switch row.
            try tap(isReachable(nativeSwitch) ? nativeSwitch : row)
        }
        try expectSwitch(id, isOn: enabled)
    }

    func playlists(named name: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier MATCHES %@ AND label CONTAINS %@",
                                         #"library\.playlist\.[0-9A-Fa-f-]{36}"#, name))
    }

    func playlist(named name: String) -> XCUIElement { playlists(named: name).firstMatch }

    func openPlaylist(named name: String) throws {
        let row = playlist(named: name)
        try reveal(row)
        try tap(row)
        try wait("The playlist \(name) must open") { self.app.navigationBars[name].exists }
    }

    func confirmPlaylistDeletion() throws {
        let buttons = app.alerts.buttons.matching(identifier: "library.playlist.confirmDelete")
        try wait("Playlist deletion must require confirmation") { buttons.count > 0 }
        guard let action = buttons.allElementsBoundByIndex.last else {
            throw AppUIWorkflowFailure(message: "The playlist deletion alert has no action button.")
        }
        try tap(action)
    }

    func playSeededPlaylist() throws {
        try selectTab("library")
        try openPlaylist(named: AppUIFixture.seededPlaylist)
        try reveal(app.buttons["library.playlist.play"])
        try tap(app.buttons["library.playlist.play"])
        try requireHittable(app.buttons["miniPlayer.open"])
    }

    func replaceSelectedText(in field: XCUIElement, with text: String) throws {
        try requireHittable(field)
        field.press(forDuration: 1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        try tap(selectAll)
        field.typeText(text)
        try expectValue(field, text)
    }

    func queueSong(title: String, artist: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@",
                                         "Play \(title), \(artist)", "Current song, \(title), \(artist)")).firstMatch
    }

    func queueSong(id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "queue.play.", ".\(id)"
        )).firstMatch
    }

    func moveQueueSong(_ song: XCUIElement, before target: XCUIElement) throws {
        try requireHittable(song)
        let cell = app.cells.containing(.any, identifier: song.identifier).firstMatch
        try requireHittable(cell)
        let handle = cell.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder")).firstMatch
        try requireHittable(handle)
        try requireHittable(target)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = target.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.1))
        start.press(forDuration: 0.6, thenDragTo: destination)
    }

    func finishQueueEditing() throws {
        let edit = app.buttons["queue.edit"]
        try expectLabel(edit, "Done")
        try tap(edit)
        try expectLabel(edit, "Edit")
    }

    func removeQueueSong(_ song: XCUIElement) throws {
        try requireHittable(song)
        let start = song.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let end = song.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        try tap(app.buttons["Delete"])
    }

    func expectMetric(_ id: String, number: Int, description: String) throws {
        let metric = element(id)
        try reveal(metric)
        try wait("\(id) must show \(number) \(description)") {
            let text = self.accessibleText(metric)
            let numbers = text.split(whereSeparator: { !$0.isNumber }).map(String.init)
            return text.contains(description) && numbers.contains(String(number))
        }
    }

    func recapSeconds() throws -> TimeInterval {
        let text = accessibleText(element("recap.totalListening"))
        guard let token = text.split(whereSeparator: { !$0.isNumber }).first, let number = Double(token) else {
            throw AppUIWorkflowFailure(message: "Recap listening total is not readable: \(text)")
        }
        if text.contains("seconds listened") { return number }
        if text.contains("minutes listened") { return number * 60 }
        throw AppUIWorkflowFailure(message: "Recap listening total has no unit: \(text)")
    }

    func expectLabel(_ element: XCUIElement, _ label: String) throws {
        try wait("Expected control label ‘\(label)’") { element.exists && element.label == label }
    }

    func expectValue(_ element: XCUIElement, _ value: String) throws {
        try wait("Expected accessibility value ‘\(value)’") { element.exists && element.value as? String == value }
    }

    func accessibleText(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    func assertMiniPlayerAboveTabs() throws {
        let mini = app.buttons["miniPlayer.open"]
        // The bottom accessory animates in; hittability is undefined mid-flight, so settle on geometry first.
        try wait("The mini-player must be laid out above the tab bar") {
            mini.exists && self.usableFrame(mini.frame) && mini.frame.height >= 30
        }
        try requireHittable(mini)
        for tab in ["home", "search", "library", "recap"] {
            let button = app.tabBars.buttons[tab.capitalized]
            try requireHittable(button)
            try wait("The mini-player must sit above the \(tab) navigation target") {
                let miniFrame = mini.frame, tabFrame = button.frame
                return self.usableFrame(miniFrame) && self.usableFrame(tabFrame) && miniFrame.maxY <= tabFrame.minY
            }
        }
    }

    func rotateToLandscape() throws {
        try rotate(to: .landscapeLeft)
    }

    func rotateToPortrait() throws {
        try rotate(to: .portrait)
    }

    private func rotate(to orientation: UIDeviceOrientation) throws {
        let before = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = orientation
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            Self.requestSceneGeometry(orientation)
            note("scene-geometry-request", "Layout uses UIKit scene geometry because this headless simulator does not deliver orientation events. Physical autorotation is not covered by this run.")
        }
        do {
            try wait("The app must lay out in \(orientation.isLandscape ? "landscape" : "portrait")") {
                let frame = self.app.windows.firstMatch.frame
                guard frame.width.isFinite, frame.height.isFinite, !frame.isEmpty else { return false }
                return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
            }
        } catch {
            note("rotation-delivery", "Requested \(orientation.rawValue); XCUIDevice readback: \(XCUIDevice.shared.orientation.rawValue); window before: \(before); window after: \(app.windows.firstMatch.frame).")
            throw error
        }
    }

    static func requestSceneGeometry(_ orientation: UIDeviceOrientation) {
        let direction = orientation.isLandscape ? "landscape" : "portrait"
        let name = CFNotificationName(rawValue: "com.agraabhi.ganabajana.uitests.geometry.\(direction)" as CFString)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    func note(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    func captureFailure(_ name: String, detail: String = "") {
        guard !hasCapturedFailure else { return }
        hasCapturedFailure = true
        capture("\(name)-screenshot")
        note("\(name)-accessibility", """
        \(detail)
        Store: \(storeName)
        Arguments: \(app.launchArguments)
        Application state: \(app.state.rawValue)
        \(app.debugDescription)
        """)
    }
}

struct AppUIWorkflowFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppUIClock {
    static func seconds(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let fields = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        let numbers = fields.compactMap { Double($0) }
        guard numbers.count == fields.count,
              numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }
}
