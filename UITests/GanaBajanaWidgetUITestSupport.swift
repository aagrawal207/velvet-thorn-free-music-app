import UIKit
import XCTest

enum WidgetUIFixture {
    static let savedIDs = [AppUIFixture.tumHiHo, AppUIFixture.kesariya, AppUIFixture.agarTumSaathHo,
                           AppUIFixture.blindingLights, AppUIFixture.shapeOfYou]
    static let cachedIDs = Array(savedIDs.prefix(3))
    static let cacheArguments = ["--cache-fixture", "--offline-fixture"]
    static let largestTextArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    static let titles = ["Tum Hi Ho", "Kesariya", "Agar Tum Saath Ho", "Blinding Lights", "Shape of You"]
    static let artists = ["Arijit Singh", "Arijit Singh", "Alka Yagnik, Arijit Singh", "The Weeknd", "Ed Sheeran"]
    static let longArtist = "The extraordinarily long artist name and accompanying orchestra"

    static func title(at index: Int, long: Bool = false) -> String {
        long ? "A long evening song title with संगीत and a quiet piano recording \(index + 1)" : titles[index]
    }
}

// This host renders MusicWidgetView in the app; WidgetKit gallery and SpringBoard acceptance have their own suite.
@MainActor
final class WidgetUITestSupport {
    let ui: AppUITestDriver
    private unowned let testCase: XCTestCase
    private var family = "small"

    var app: XCUIApplication { ui.app }
    var screen: XCUIElement { app.otherElements["widgetPreview.screen"].firstMatch }
    var canvas: XCUIElement { screen.descendants(matching: .any).matching(identifier: "widgetPreview.canvas").firstMatch }
    var player: XCUIElement { app.otherElements["player.screen"].firstMatch }

    init(testCase: XCTestCase) {
        self.testCase = testCase
        let driver = AppUITestDriver(testCase: testCase, prefix: "r8-widget")
        ui = driver
        testCase.addTeardownBlock { await driver.finish() }
    }

    func launch(family: String? = nil, kind: String = "recentlyPlayed", arguments: [String] = []) throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        // Supply one content-size override, so a simulator's previous accessibility setting cannot leak into a case.
        let textSize = arguments.contains("-UIPreferredContentSizeCategoryName") ? []
            : ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments = ["--uitesting", "--seed-ui", "--widget-fixture", "--reset-ui"] + textSize
        if let family {
            self.family = family
            app.launchArguments += ["--widget-preview", "--widget-family", family, "--widget-kind", kind]
        }
        app.launchArguments += arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["GANABAJANA_TEST_STORE": ui.storeName]
        app.launch()
        if family != nil { try expectPreview() }
        else { try ui.requireHittable(app.buttons["tab.home"].firstMatch, timeout: 25) }
    }

    func relaunchPreview() throws {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-ui" }
        app.launch()
        try expectPreview()
    }

    func openURL(_ string: String, cold: Bool = false) throws {
        let url = try XCTUnwrap(URL(string: string))
        // XCTest's URL launcher can replace the process even from background; never replay fixture initialization.
        app.launchArguments.removeAll { $0 == "--reset-ui" || $0 == "--widget-preview" }
        if cold {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
        } else {
            XCTAssertEqual(app.state, .runningForeground)
            XCUIDevice.shared.press(.home)
            try ui.wait("The running app must background before warm URL activation") {
                self.app.state == .runningBackground || self.app.state == .runningBackgroundSuspended
            }
        }
        // The native Home Screen suite covers warm widget delivery; this API verifies real URL launches and restored state.
        app.open(url)
        try ui.wait("The URL must activate Velvet Thorn", timeout: 25) { self.app.state == .runningForeground }
    }

    func expectPreview() throws {
        try ui.wait("The exact shared widget preview must be visible", timeout: 25) {
            let done = self.screen.buttons["widgetPreview.done"]
            return self.screen.exists && self.canvas.exists && done.exists && done.isHittable
        }
        let bounds = canvas.frame
        // Accessibility rounds outer canvases to device pixels; native action targets below still require 44 points.
        let canvasAccuracy = 1 / UIScreen.main.scale + 1e-6
        XCTAssertEqual(bounds.width, family == "small" ? 160 : min(360, screen.frame.width - 32), accuracy: canvasAccuracy)
        XCTAssertEqual(bounds.height, family == "large" ? 360 : 160, accuracy: canvasAccuracy)
        assertContained(bounds, in: screen.frame)
        assertContained(bounds, in: app.windows.firstMatch.frame)
    }

    func link(_ identifier: String) -> XCUIElement {
        canvas.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func expectLink(_ identifier: String, label: String, value: String? = nil) throws -> XCUIElement {
        let element = link(identifier)
        try ui.expectLabel(element, label)
        if let value { try ui.expectValue(element, value) }
        XCTAssertTrue(element.elementType == .link || element.elementType == .button,
                      "Measure the native Link control, not a surrounding layout container: \(identifier)")
        try ui.requireHittable(element)
        XCTAssertTrue(element.isEnabled)
        XCTAssertGreaterThanOrEqual(element.frame.width + 1e-6, 44)
        XCTAssertGreaterThanOrEqual(element.frame.height + 1e-6, 44)
        assertContained(element.frame, in: canvas.frame)
        return element
    }

    @discardableResult
    func expectTrackPreview(kind: String, heading: String, indices: [Int], count: String?, long: Bool = false) throws -> [XCUIElement] {
        let headingLink = try expectLink("widget.open.\(kind)", label: "Open \(heading)", value: count ?? "")
        let query = canvas.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "widget.track.\(kind)."
        ))
        XCTAssertEqual(query.count, indices.count, "The visible rows and the saved collection's total are different quantities")
        var previous = headingLink.frame
        var rows: [XCUIElement] = []
        for index in indices {
            let title = WidgetUIFixture.title(at: index, long: long)
            let artist = long ? WidgetUIFixture.longArtist : WidgetUIFixture.artists[index]
            let row = try expectLink("widget.track.\(kind).\(WidgetUIFixture.savedIDs[index])", label: "Play \(title), \(artist)")
            XCTAssertGreaterThanOrEqual(row.frame.minY + 1e-6, previous.maxY, "Widget links must not overlap")
            previous = row.frame
            rows.append(row)
        }
        XCTAssertFalse(link("widget.empty.\(kind)").exists)
        return rows
    }

    func expectMixPreview(title: String) throws {
        let heading = try expectLink("widget.open.mixes", label: "Open \(title)", value: "5 songs")
        let play = try expectLink("widget.mix.play", label: "Play \(title)")
        XCTAssertGreaterThanOrEqual(play.frame.minY + 1e-6, heading.frame.maxY)
        XCTAssertTrue(canvas.staticTexts["5 songs"].exists, "The saved mix count must be rendered as well as announced")
        XCTAssertFalse(link("widget.empty.mixes").exists)
    }

    func assertNoPreviewMetadata() throws {
        var pending = [try canvas.snapshot()]
        var text: [String] = []
        while let node = pending.popLast() {
            text += [node.identifier, node.label, node.value as? String ?? ""]
            pending += node.children
        }
        let exposed = text.joined(separator: "\n")
        let forbidden = WidgetUIFixture.savedIDs + WidgetUIFixture.titles + WidgetUIFixture.artists
            + [WidgetUIFixture.longArtist, WidgetUIFixture.title(at: 0, long: true), "5 songs", "widget.track.", "widget.mix.play"]
        for value in forbidden {
            XCTAssertFalse(exposed.contains(value), "A private or unavailable preview leaked \(value)")
        }
    }

    func capturePreview(_ name: String, light: Bool) throws {
        try expectPreview()
        let screenshot = canvas.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "widget-preview-\(name)-canvas"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
        ui.note("widget-preview-\(name)-bounds", "Native preview canvas: \(canvas.frame)\nWindow: \(app.windows.firstMatch.frame)\nStore: \(ui.storeName)\nArguments: \(app.launchArguments)")
        let brightness = try paddingBrightness(screenshot)
        if light { XCTAssertGreaterThan(brightness, 0.8, "The native capture must actually use the light surface") }
        else { XCTAssertLessThan(brightness, 0.2, "The native capture must actually use the dark surface") }
    }

    func expectPreviewDismissed() throws {
        try ui.wait("Following the preview link must dismiss its overlay") { !self.screen.exists }
    }

    func expectNoPlayback() {
        XCTAssertFalse(player.exists)
        XCTAssertFalse(app.buttons["miniPlayer.open"].exists, "Browsing a widget must not create a playback selection")
    }

    func selectTab(_ tab: String) throws {
        let button = app.buttons["tab.\(tab)"].firstMatch
        try ui.tap(button)
        try ui.wait("The native \(tab) tab must be selected") { button.isSelected }
    }

    func expectSavedList(_ kind: String, count: Int) throws -> XCUIElement {
        let title = kind == "likes" ? "Liked Songs" : "Recently Played"
        try ui.wait("The widget must open the live \(title) destination") { self.app.navigationBars[title].exists }
        let identifier = "library.\(kind).count"
        let lists = app.collectionViews.containing(.staticText, identifier: identifier)
        try ui.wait("The saved list must expose its actual count") { lists.firstMatch.exists }
        let matches = lists.allElementsBoundByAccessibilityElement
        XCTAssertEqual(matches.count, 1)
        let list = try XCTUnwrap(matches.first)
        try reveal(list.staticTexts[identifier], in: list)
        try ui.expectLabel(list.staticTexts[identifier], "\(count) songs")
        XCTAssertTrue(app.buttons["tab.library"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["collection.play"].exists, "Saved lists must remain live library destinations")
        return list
    }

    func expectSavedMix(title: String) throws {
        let content = app.scrollViews.containing(.staticText, identifier: "collection.title").firstMatch
        try ui.wait("The mix route must open its saved collection") { content.exists }
        try reveal(content.staticTexts["collection.title"], in: content)
        try ui.expectLabel(content.staticTexts["collection.title"], title)
        XCTAssertTrue(content.staticTexts["MIX"].exists)
        XCTAssertTrue(app.buttons["tab.home"].firstMatch.isSelected)
        let rows = content.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track.play."))
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.identifier), WidgetUIFixture.savedIDs.map { "track.play.\($0)" })
        for index in WidgetUIFixture.savedIDs.indices {
            let row = content.buttons["track.play.\(WidgetUIFixture.savedIDs[index])"]
            try reveal(row, in: content)
            XCTAssertTrue(row.label.contains(WidgetUIFixture.titles[index]))
        }
        let summary = content.staticTexts["collection.summary"]
        try reveal(summary, in: content)
        try ui.expectLabel(summary, "5 songs · 21:49")
    }

    @discardableResult
    func expectPlaybackAndPause(id: String, startingAt position: TimeInterval, actionStartedAt: TimeInterval) throws -> TimeInterval {
        let title = player.staticTexts["player.track.\(id)"]
        let transport = player.buttons["player.playPause"]
        try ui.wait("The widget selection must start real cached playback", timeout: 45) {
            title.exists && transport.exists && transport.label == "Pause" && transport.value as? String != "Loading"
                && self.elapsed() != nil
        }
        // Waiting until elapsed reaches the saved value would let a broken resume pass after playing from zero.
        let baseline = try XCTUnwrap(elapsed())
        XCTAssertGreaterThanOrEqual(baseline, position - 1, "The first ready player position must include the saved resume offset")
        let index = try XCTUnwrap(WidgetUIFixture.savedIDs.firstIndex(of: id))
        XCTAssertEqual(title.label, WidgetUIFixture.titles[index])
        XCTAssertTrue(player.staticTexts["player.offline"].exists)
        XCTAssertFalse(player.buttons["player.retry"].exists)
        try ui.wait("The local AAC file must advance AVPlayer's elapsed time", timeout: 15) {
            (self.elapsed() ?? -1) >= baseline + 1 && transport.label == "Pause"
        }
        try ui.tap(transport)
        try ui.expectLabel(transport, "Play")
        let stopped = try XCTUnwrap(elapsed())
        XCTAssertGreaterThanOrEqual(stopped, position + 1)
        XCTAssertLessThanOrEqual(stopped, position + ProcessInfo.processInfo.systemUptime - actionStartedAt + 2,
                                 "Resume must honor the saved position, allowing for elapsed UI automation time")
        return stopped
    }

    func elapsed() -> TimeInterval? {
        let time = player.staticTexts["player.elapsed"]
        guard time.exists else { return nil }
        return AppUIClock.seconds(time.value as? String)
    }

    func expectQueue(_ ids: [String], current: Int) throws {
        try ui.tap(player.buttons["player.queue"])
        let queue = app.collectionViews["queue.list"]
        try ui.requireHittable(app.navigationBars["Queue"].buttons["queue.done"])
        let rows = queue.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue.play."))
        try ui.wait("The queue must contain exactly the saved selection's compatible cached recordings") { rows.count == ids.count }
        let expected = ids.enumerated().map { "queue.play.\($0.offset).\($0.element)" }
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.identifier), expected)
        XCTAssertFalse(queue.buttons["player.shuffle"].isSelected)
        XCTAssertTrue(queue.staticTexts["\(ids.count) songs · \(current + 1) of \(ids.count)"].exists)
        for (index, identifier) in expected.enumerated() {
            let row = queue.buttons[identifier]
            try reveal(row, in: queue)
            XCTAssertEqual(row.label.hasPrefix("Current song, "), index == current)
        }
        ui.capture("widget-route-exact-cached-queue")
        try ui.tap(app.navigationBars["Queue"].buttons["queue.done"])
        try ui.wait("Queue must close back to the player") {
            let close = self.player.buttons["player.close"]
            return !queue.exists && close.exists && close.isHittable
        }
    }

    func closePlayer() throws {
        try ui.tap(player.buttons["player.close"])
        try ui.wait("The player must dismiss before checking the root fixture counters") { !self.player.exists }
        try ui.requireHittable(app.buttons["miniPlayer.open"])
    }

    func expectCacheBoundary(localPlayback: Bool = false) throws {
        let requests = app.staticTexts["cacheFixture.networkRequests"]
        try ui.wait("The isolated cache fixture must expose its forbidden-network counter") { requests.exists }
        XCTAssertEqual(requests.value as? String, "0", "Widget navigation and playback must not extract or request remote audio")
        XCTAssertFalse(app.staticTexts["cacheFixture.setupError"].exists)
        if localPlayback { try ui.expectValue(app.staticTexts["cacheFixture.playbackSource"], "local") }
    }

    func reveal(_ element: XCUIElement, in content: XCUIElement) throws {
        let window = app.windows.firstMatch
        for attempt in 0...8 {
            var viewport = content.frame.intersection(window.frame)
            let bar = app.navigationBars.firstMatch
            if bar.exists, bar.isHittable, bar.frame.intersects(viewport) {
                let top = max(viewport.minY, bar.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            if !player.exists {
                // Rows pass beneath the mini-player's glass, so its capsule, not the inset open button, bounds the viewport.
                for control in [app.buttons["tab.home"].firstMatch, app.otherElements["miniPlayer.container"]] where control.exists {
                    let frame = control.frame
                    if frame.intersects(viewport), frame.midY > viewport.midY {
                        viewport.size.height = max(0, frame.minY - viewport.minY)
                    }
                }
            }
            guard !viewport.isEmpty, !viewport.isNull,
                  [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite) else {
                throw AppUIWorkflowFailure(message: "The widget destination has no usable scroll viewport")
            }
            let frame = element.exists ? element.frame : .null
            if !frame.isNull, !frame.isEmpty, viewport.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), element.isHittable { return }
            guard attempt < 8 else { break }
            let down = !frame.isNull && frame.minY < viewport.minY
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.minX + 10 - window.frame.minX,
                                                  dy: viewport.minY + viewport.height * (down ? 0.3 : 0.7) - window.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: viewport.height * (down ? 0.4 : -0.4)))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        throw AppUIWorkflowFailure(message: "The widget destination could not reveal \(element.identifier) within eight scoped drags")
    }

    private func assertContained(_ frame: CGRect, in bounds: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(frame.isEmpty || frame.isNull, file: file, line: line)
        XCTAssertTrue([frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite), file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX + 1e-6, bounds.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY + 1e-6, bounds.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1e-6, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 1e-6, file: file, line: line)
    }

    private func paddingBrightness(_ screenshot: XCUIScreenshot) throws -> Double {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        // The middle of the six-point bottom padding contains only the native surface, away from text and rounded corners.
        let scale = CGFloat(image.height) / canvas.frame.height
        let patch = try XCTUnwrap(image.cropping(to: CGRect(x: CGFloat(image.width) / 2 - 1,
                                                          y: CGFloat(image.height) - 6 * scale, width: 3, height: 3)))
        var bytes = [UInt8](repeating: 0, count: 3 * 3 * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 3, height: 3, bitsPerComponent: 8,
                                                 bytesPerRow: 12, space: colorSpace,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(patch, in: CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        let total = stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Int(bytes[$1]) + Int(bytes[$1 + 1]) + Int(bytes[$1 + 2]) }
        return Double(total) / Double(3 * 3 * 3 * 255)
    }
}
