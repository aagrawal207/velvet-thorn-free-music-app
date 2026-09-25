import XCTest

@MainActor
final class GanaBajanaWidgetLinksUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testMediumLikedPreviewAndURLLaunchesUseTheUpdatedSavedList() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(family: "medium", kind: "likedSongs", arguments: WidgetUIFixture.cacheArguments)
        try widget.expectTrackPreview(kind: "likedSongs", heading: "Liked songs", indices: [0], count: "5 songs")
        try widget.capturePreview("medium-liked-dark", light: false)
        try widget.ui.tap(widget.link("widget.open.likedSongs"))
        try widget.expectPreviewDismissed()
        let originalList = try widget.expectSavedList("likes", count: 5)
        widget.expectNoPlayback()
        XCTAssertTrue(widget.app.buttons["library.likes.search"].exists)

        let song = originalList.buttons["track.play.\(AppUIFixture.tumHiHo)"]
        try widget.reveal(song, in: originalList)
        let started = ProcessInfo.processInfo.systemUptime
        try widget.ui.tap(song)
        try widget.ui.tap(widget.app.buttons["miniPlayer.open"])
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 0, actionStartedAt: started)
        let heart = widget.player.buttons["player.like"]
        try widget.ui.expectLabel(heart, "Unlike this song")
        try widget.ui.tap(heart)
        try widget.ui.expectLabel(heart, "Like this song")
        try widget.closePlayer()
        let changedList = try widget.expectSavedList("likes", count: 4)
        XCTAssertFalse(changedList.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists,
                       "The heading must open a dynamic liked list that reflects the real player edit")
        try widget.expectCacheBoundary(localPlayback: true)

        try widget.relaunchPreview()
        try widget.expectTrackPreview(kind: "likedSongs", heading: "Liked songs", indices: [1], count: "4 songs")
        try widget.capturePreview("medium-liked-dark-after-unlike", light: false)
        let linkStarted = ProcessInfo.processInfo.systemUptime
        try widget.ui.tap(widget.link("widget.track.likedSongs.\(AppUIFixture.kesariya)"))
        try widget.expectPreviewDismissed()
        let position = try widget.expectPlaybackAndPause(id: AppUIFixture.kesariya, startingAt: 0, actionStartedAt: linkStarted)
        let remainingCached = [AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo]
        try widget.expectQueue(remainingCached, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)

        try widget.openURL("ganabajana://widget/open?kind=likedSongs", cold: true)
        XCTAssertFalse(widget.app.launchArguments.contains("--reset-ui"))
        XCTAssertFalse(widget.app.launchArguments.contains("--widget-preview"))
        XCTAssertEqual(widget.app.launchEnvironment["GANABAJANA_TEST_STORE"], widget.ui.storeName)
        let restoredList = try widget.expectSavedList("likes", count: 4)
        XCTAssertFalse(restoredList.buttons["track.play.\(AppUIFixture.tumHiHo)"].exists)
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.open"], "Open player, Kesariya, Arijit Singh")
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.playPause"], "Play")
        XCTAssertFalse(widget.player.exists, "Cold collection activation must restore playback paused without presenting it")
        try widget.expectCacheBoundary()

        try widget.selectTab("home")
        try widget.openURL("ganabajana://widget/play?source=likedSongs&id=\(AppUIFixture.tumHiHo)")
        _ = try widget.expectSavedList("likes", count: 4)
        XCTAssertFalse(widget.player.exists, "A stale widget URI must browse the current list rather than resurrect an unlike")
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.open"], "Open player, Kesariya, Arijit Singh")
        try widget.ui.expectLabel(widget.app.buttons["miniPlayer.playPause"], "Play")
        try widget.ui.tap(widget.app.buttons["miniPlayer.open"])
        try widget.ui.requireHittable(widget.player.buttons["player.close"])
        XCTAssertEqual(try XCTUnwrap(widget.elapsed()), position, accuracy: 1)
        try widget.expectQueue(remainingCached, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary()

        let warmStarted = ProcessInfo.processInfo.systemUptime
        try widget.openURL("ganabajana://widget/play?source=likedSongs&id=\(AppUIFixture.agarTumSaathHo)")
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.agarTumSaathHo, startingAt: 0, actionStartedAt: warmStarted)
        try widget.expectQueue(remainingCached, current: 1)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)
        widget.ui.capture("widget-url-updated-likes-after-platform-launches")
    }

    func testUncachedRecentURLLaunchesPreserveTheSavedSelectionPositionAndQueue() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(arguments: WidgetUIFixture.cacheArguments)
        let started = ProcessInfo.processInfo.systemUptime
        try widget.openURL("ganabajana://widget/play?source=recentlyPlayed&id=\(AppUIFixture.tumHiHo)")
        let position = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 12, actionStartedAt: started)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)

        for id in [AppUIFixture.blindingLights, AppUIFixture.shapeOfYou] {
            try widget.openURL("ganabajana://widget/play?source=recentlyPlayed&id=\(id)")
            try widget.ui.expectLabel(widget.app.staticTexts["message.text"],
                                     "This song isn’t cached. Choose a cached song to keep listening offline.")
            XCTAssertFalse(widget.player.exists, "An unavailable selection must not replace or present the player")
            try widget.ui.expectLabel(widget.app.buttons["miniPlayer.open"], "Open player, Tum Hi Ho, Arijit Singh")
            try widget.ui.expectLabel(widget.app.buttons["miniPlayer.playPause"], "Play")
            try widget.expectCacheBoundary()
            if widget.app.buttons["message.dismiss"].exists { try widget.ui.tap(widget.app.buttons["message.dismiss"]) }
        }
        try widget.ui.tap(widget.app.buttons["miniPlayer.open"])
        try widget.ui.requireHittable(widget.player.buttons["player.close"])
        XCTAssertEqual(try XCTUnwrap(widget.elapsed()), position, accuracy: 1,
                       "Neither the unfinished copy nor the incompatible copy may seek the existing player")
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary()
    }
}
