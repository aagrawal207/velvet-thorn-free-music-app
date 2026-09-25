import XCTest

@MainActor
final class GanaBajanaWidgetPreviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSmallRecentPreviewResumesCachedSongInPlayer() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "small", arguments: WidgetUIFixture.cacheArguments)
        let link = try widget.expectLink("widgetPreview.smallLink", label: "Recently played. Play Tum Hi Ho, Arijit Singh")
        try widget.capturePreview("small-recent-dark", light: false)
        let started = ProcessInfo.processInfo.systemUptime
        try widget.ui.tap(link)
        try widget.expectPreviewDismissed()
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 12, actionStartedAt: started)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        widget.ui.capture("widget-preview-recent-resumed-player")
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)
    }

    func testSmallDailyMixPreviewBrowsesTheSavedFiveSongCollection() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "small", kind: "mixes", arguments: ["--light"])
        let link = try widget.expectLink("widgetPreview.smallLink", label: "Daily Mix. 5 songs. Open mix in Breezy.")
        XCTAssertFalse(widget.link("widget.mix.play").exists, "The small mix surface browses rather than starting playback")
        try widget.capturePreview("small-daily-mix-light", light: true)
        try widget.ui.tap(link)
        try widget.expectPreviewDismissed()
        try widget.expectSavedMix(title: "Your Daily Mix")
        widget.expectNoPlayback()
        widget.ui.capture("widget-preview-small-daily-mix-saved-collection")
    }

    func testMediumDailyMixPreviewPlaysTheSavedCachedOrder() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "medium", kind: "mixes", arguments: ["--light"] + WidgetUIFixture.cacheArguments)
        try widget.expectMixPreview(title: "Daily Mix")
        try widget.capturePreview("medium-daily-mix-light", light: true)
        let started = ProcessInfo.processInfo.systemUptime
        try widget.ui.tap(widget.link("widget.mix.play"))
        try widget.expectPreviewDismissed()
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 0, actionStartedAt: started)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)
    }

    func testLargeWeeklyMixPreviewPlaysThenBrowsesWithoutReplacingItsSavedQueue() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "large", kind: "mixes", arguments: ["--widget-weekly"] + WidgetUIFixture.cacheArguments)
        try widget.expectMixPreview(title: "Discover Weekly")
        try widget.capturePreview("large-weekly-mix-dark", light: false)
        let started = ProcessInfo.processInfo.systemUptime
        try widget.ui.tap(widget.link("widget.mix.play"))
        try widget.expectPreviewDismissed()
        let position = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 0, actionStartedAt: started)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)

        // Real playback establishes that asynchronous AAC preparation finished before this store is reopened.
        try widget.relaunchPreview()
        try widget.expectMixPreview(title: "Discover Weekly")
        try widget.ui.tap(widget.link("widget.open.mixes"))
        try widget.expectPreviewDismissed()
        try widget.expectSavedMix(title: "Discover Weekly")
        XCTAssertFalse(widget.player.exists, "Browsing the saved mix must preserve the paused player without presenting it")
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.open"], "Open player, Tum Hi Ho, Arijit Singh")
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.playPause"], "Play")
        try widget.ui.tap(widget.app.buttons["miniPlayer.open"])
        try widget.ui.requireHittable(widget.player.buttons["player.close"])
        XCTAssertEqual(try XCTUnwrap(widget.elapsed()), position, accuracy: 1)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary()
    }

    func testLongTitlePreviewsKeepNativeLinksContainedAtLargestTextInEveryFamily() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "large", kind: "likedSongs", arguments: ["--light"])
        let standardRows = try widget.expectTrackPreview(kind: "likedSongs", heading: "Liked songs", indices: [0, 1, 2, 3, 4], count: "5 songs")
        let standardRowHeight = try XCTUnwrap(standardRows.first).frame.height
        let standardHeadingHeight = widget.screen.staticTexts["Widget preview"].frame.height
        XCTAssertGreaterThan(standardHeadingHeight, 0)
        try widget.capturePreview("large-liked-light-standard-text", light: true)

        for family in ["small", "medium", "large"] {
            let light = family != "medium"
            let kind = family == "small" ? "recentlyPlayed" : "likedSongs"
            try widget.launch(family: family, kind: kind, arguments: ["--widget-long-titles"]
                              + WidgetUIFixture.largestTextArguments + (light ? ["--light"] : []))
            XCTAssertGreaterThan(widget.screen.staticTexts["Widget preview"].frame.height, standardHeadingHeight * 1.5,
                                 "The system text-size override must enlarge native text")
            if family == "small" {
                try widget.expectLink("widgetPreview.smallLink",
                                      label: "Recently played. Play \(WidgetUIFixture.title(at: 0, long: true)), \(WidgetUIFixture.longArtist)")
            } else {
                let rows = try widget.expectTrackPreview(kind: kind, heading: "Liked songs",
                                                        indices: family == "large" ? [0, 1, 2] : [0], count: "5 songs", long: true)
                XCTAssertGreaterThan(try XCTUnwrap(rows.first).frame.height, standardRowHeight,
                                     "Large text must consume real row height rather than shrinking to the standard font")
            }
            try widget.capturePreview("\(family)-long-titles-accessibility-xxxl-\(light ? "light" : "dark")", light: light)
            try widget.ui.tap(widget.screen.buttons["widgetPreview.done"])
            try widget.expectPreviewDismissed()
            widget.expectNoPlayback()
        }
    }

    func testEmptyLikedPreviewHasNoSavedMetadataAndOpensAnActionableEmptyList() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "medium", kind: "likedSongs", arguments: ["--widget-empty", "--light"])
        let link = try widget.expectLink("widget.empty.likedSongs",
                                         label: "Liked songs. No liked songs yet. Like a song in Breezy to find it here.")
        try widget.assertNoPreviewMetadata()
        try widget.capturePreview("medium-empty-liked-light", light: true)
        try widget.ui.tap(link)
        try widget.expectPreviewDismissed()
        let list = try widget.expectSavedList("likes", count: 0)
        XCTAssertFalse(list.buttons["library.likes.play"].isEnabled)
        XCTAssertFalse(list.buttons["library.likes.shuffle"].isEnabled)
        XCTAssertTrue(list.staticTexts["Save a song you love"].exists)
        let findMusic = list.buttons["library.likes.findMusic"]
        try widget.reveal(findMusic, in: list)
        try widget.ui.tap(findMusic)
        try widget.ui.requireHittable(widget.app.textFields["search.field"])
        XCTAssertTrue(widget.app.buttons["tab.search"].firstMatch.isSelected)
        widget.expectNoPlayback()
    }

    func testHistoryOffRecentPreviewHidesMetadataAndCanReenableHistory() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "small", arguments: ["--widget-history-off"])
        let link = try widget.expectLink("widgetPreview.smallLink",
                                         label: "Recently played. History is off. Recently played stays hidden while listening history is off.")
        try widget.assertNoPreviewMetadata()
        try widget.capturePreview("small-history-off-dark", light: false)
        try widget.ui.tap(link)
        try widget.expectPreviewDismissed()
        let list = try widget.expectSavedList("recents", count: 5)
        let enable = list.buttons["library.history.enable"]
        try widget.reveal(enable, in: list)
        try widget.ui.tap(enable)
        try widget.ui.wait("Turning on listening history must remove its paused notice") { !enable.exists }
        widget.expectNoPlayback()

        try widget.relaunchPreview()
        try widget.expectLink("widgetPreview.smallLink", label: "Recently played. Play Tum Hi Ho, Arijit Singh")
        try widget.capturePreview("small-history-reenabled-dark", light: false)
    }

    func testUnavailableLikedPreviewHidesMetadataAndOpensSavedSongs() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "large", kind: "likedSongs", arguments: ["--widget-unavailable", "--light"])
        let link = try widget.expectLink("widget.empty.likedSongs",
                                         label: "Liked songs. Can't load music. Open Breezy to refresh your saved music.")
        try widget.assertNoPreviewMetadata()
        try widget.capturePreview("large-unavailable-liked-light", light: true)
        try widget.ui.tap(link)
        try widget.expectPreviewDismissed()
        let list = try widget.expectSavedList("likes", count: 5)
        let song = list.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try widget.reveal(song, in: list)
        XCTAssertTrue(song.label.contains("Tum Hi Ho"))
        widget.expectNoPlayback()
    }
}
