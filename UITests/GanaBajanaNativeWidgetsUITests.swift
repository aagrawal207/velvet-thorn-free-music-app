import XCTest

@MainActor
final class GanaBajanaNativeWidgetsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRecentlyPlayedWidgetCanBeAddedAndOpensCachedPlaybackFromHomeScreen() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(arguments: ["--widget-sharing-fixture", "--artwork-fixture"] + WidgetUIFixture.cacheArguments)
        try widget.ui.expectValue(widget.app.staticTexts["widgetFixture.availability"], "ready")
        try widget.ui.expectValue(widget.app.staticTexts["widgetFixture.artwork"], "5")

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer { attach(springboard, named: "native-widget-home-final") }
        attach(springboard, named: "native-widget-home-initial")
        let existing = springboard.descendants(matching: .any).matching(identifier: "widget.small.recentlyPlayed").firstMatch
        if !existing.waitForExistence(timeout: 3) { try addWidget(using: widget, springboard: springboard) }
        let recentLinks = springboard.links.matching(identifier: "widget.small.recentlyPlayed")
        let recent = recentLinks.firstMatch
        try widget.ui.wait("WidgetKit must render the shared recent song on the Home Screen", timeout: 30) {
            recent.exists && recent.isHittable && recent.value as? String == "r8-small-card-v2"
        }
        attach(springboard, named: "native-widget-recent-home")
        XCTAssertEqual(recentLinks.count, 1)
        XCTAssertEqual(recent.label, "Recently played. Play Tum Hi Ho, Arijit Singh")
        XCTAssertGreaterThanOrEqual(recent.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(recent.frame.height + 1e-6, 44)
        let started = ProcessInfo.processInfo.systemUptime
        recent.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).tap()
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 12, actionStartedAt: started)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)
    }

    func testMixWidgetCanChooseDiscoverWeeklyAndPlayItsSavedCachedSongs() throws {
        let widget = WidgetUITestSupport(testCase: self)
        try widget.launch(arguments: ["--widget-sharing-fixture", "--artwork-fixture"] + WidgetUIFixture.cacheArguments)
        try widget.ui.expectValue(widget.app.staticTexts["widgetFixture.availability"], "ready")
        try widget.ui.expectValue(widget.app.staticTexts["widgetFixture.artwork"], "5")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer { attach(springboard, named: "native-mix-final") }
        let existing = springboard.descendants(matching: .any).matching(identifier: "widget.open.mixes").firstMatch
        if existing.waitForExistence(timeout: 3), existing.isHittable {
            existing.press(forDuration: 0.6)
            let edit = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Edit Widget")).firstMatch
            try widget.ui.wait("The existing Mix widget must offer its native editor") { edit.exists && edit.isHittable }
            edit.tap()
        } else {
            try addWidget(using: widget, springboard: springboard, page: 8, title: "Mix", finishEditing: false)
            attach(springboard, named: "native-mix-added")
            let hosts = springboard.icons.matching(NSPredicate(format: "label == %@ AND value == %@", "Breezy", "Widget"))
            try widget.ui.wait("The saved Mix widget must be hosted on the Home Screen") {
                hosts.allElementsBoundByAccessibilityElement.contains { $0.frame.width > $0.frame.height && $0.isHittable }
            }
            // Home editing hides widget descendants; the medium widget just added occupies the first wide slot.
            let host = try XCTUnwrap(hosts.allElementsBoundByAccessibilityElement.filter { $0.frame.width > $0.frame.height }
                .min { $0.frame.minY < $1.frame.minY })
            host.tap()
        }
        attach(springboard, named: "native-mix-editor")
        let selectedButton = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Mix", "Daily Mix", "Discover Weekly"])).firstMatch
        try widget.ui.wait("The native Mix configuration must expose its selected value") {
            selectedButton.exists && selectedButton.isHittable
        }
        selectedButton.tap()
        attach(springboard, named: "native-mix-choices")
        let weeklyButton = springboard.buttons["Discover Weekly"].firstMatch
        let weeklyCell = springboard.cells.matching(NSPredicate(format: "label CONTAINS %@", "Discover Weekly")).firstMatch
        try widget.ui.wait("The native picker must offer Discover Weekly") {
            (weeklyButton.exists && weeklyButton.isHittable) || (weeklyCell.exists && weeklyCell.isHittable)
        }
        if weeklyButton.exists && weeklyButton.isHittable { weeklyButton.tap() } else { weeklyCell.tap() }
        attach(springboard, named: "native-mix-weekly-selection")
        // Dismiss the editor without navigating away from the Home Screen page containing this widget.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let done = springboard.buttons["Done"].firstMatch
        if done.exists && done.isHittable { try finishHomeEditing(using: widget, springboard: springboard) }
        let play = springboard.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "widget.mix.play", "Play Discover Weekly"
        )).firstMatch
        try widget.ui.wait("The configured widget must reload with Discover Weekly", timeout: 30) { play.exists && play.isHittable }
        XCTAssertGreaterThanOrEqual(play.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(play.frame.height + 1e-6, 44)
        attach(springboard, named: "native-mix-weekly-home")
        let started = ProcessInfo.processInfo.systemUptime
        play.tap()
        _ = try widget.expectPlaybackAndPause(id: AppUIFixture.tumHiHo, startingAt: 0, actionStartedAt: started)
        try widget.expectQueue(WidgetUIFixture.cachedIDs, current: 0)
        try widget.closePlayer()
        try widget.expectCacheBoundary(localPlayback: true)
    }

    private func addWidget(using widget: WidgetUITestSupport, springboard: XCUIApplication,
                           page: Int = 1, title: String = "Recently played", finishEditing: Bool = true) throws {
        let icons = springboard.icons.matching(NSPredicate(format: "identifier == %@ AND (value == nil OR value != %@)", "Breezy", "Widget"))
        try widget.ui.wait("The installed Breezy icon must be available on the QA Home Screen", timeout: 20) { icons.count > 0 }
        // iPad also exposes the recent-app Dock icon, whose menu contains window actions instead of Home editing.
        let icon = try XCTUnwrap(icons.allElementsBoundByAccessibilityElement.filter { !$0.frame.isEmpty }
            .min { $0.frame.minY < $1.frame.minY })
        icon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.6)
        let editHome = springboard.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label ENDSWITH %@", "com.apple.springboardhome.application-shortcut-item.rearrange-icons", "Edit Home Screen"
        )).firstMatch
        let smallWidget = springboard.buttons["Small widget"].firstMatch
        if page == 1, smallWidget.exists && smallWidget.isHittable {
            smallWidget.tap()
            let done = springboard.buttons["Done"].firstMatch
            if done.exists && done.isHittable { try finishHomeEditing(using: widget, springboard: springboard) }
            return
        }
        let options = springboard.buttons["Options"].firstMatch
        if !editHome.exists, options.exists && options.isHittable { options.tap() }
        try widget.ui.wait("The native app menu must offer Edit Home Screen") { editHome.exists }
        editHome.tap()
        let edit = springboard.buttons["Edit"].firstMatch
        try widget.ui.wait("Home Screen editing must be active") { edit.exists }
        edit.tap()
        let add = springboard.buttons["Add Widget"].firstMatch
        try widget.ui.wait("The native Home Screen menu must offer Add Widget") { add.exists }
        add.tap()
        let search = springboard.searchFields.firstMatch
        try widget.ui.wait("The native widget gallery must show search", timeout: 20) { search.exists }
        search.tap()
        search.typeText("Breezy")
        let typingIntroduction = springboard.otherElements["UIContinuousPathIntroductionView"]
        if typingIntroduction.exists { typingIntroduction.buttons["Continue"].tap() }
        attach(springboard, named: "native-widget-gallery-search")
        let result = springboard.collectionViews["add-sheet-collection-view"].cells["Breezy"]
        try widget.ui.wait("The embedded Breezy extension must appear in the widget gallery", timeout: 30) {
            result.exists && result.isHittable
        }
        result.tap()
        let galleryAdd = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Add Widget")).firstMatch
        try widget.ui.wait("The Breezy widget gallery must present Add Widget", timeout: 20) { galleryAdd.exists }
        for target in 2...max(2, page) where target <= page {
            let previews = springboard.buttons.matching(NSPredicate(format: "value BEGINSWITH %@", "Widget, "))
            let current = try XCTUnwrap(previews.allElementsBoundByAccessibilityElement.first { $0.isHittable })
            current.swipeLeft()
            let indicator = springboard.pageIndicators.matching(NSPredicate(format: "value == %@", "page \(target) of 9")).firstMatch
            try widget.ui.wait("The native gallery must select widget page \(target)") { indicator.exists }
        }
        XCTAssertTrue(springboard.staticTexts[title].firstMatch.exists)
        attach(springboard, named: "native-widget-\(title)-gallery")
        galleryAdd.tap()
        if finishEditing { try finishHomeEditing(using: widget, springboard: springboard) }
    }

    private func finishHomeEditing(using widget: WidgetUITestSupport, springboard: XCUIApplication) throws {
        let done = springboard.buttons["Done"].firstMatch
        try widget.ui.wait("The widget must be placed in Home Screen editing mode", timeout: 20) { done.exists }
        // A tap can first dismiss the configuration overlay before the Home Screen's Done action is reachable.
        for _ in 0..<2 where done.exists { done.tap() }
        try widget.ui.wait("Home Screen editing must finish before the widget is used") {
            !done.exists || !done.isHittable
        }
    }

    private func attach(_ app: XCUIApplication, named name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
