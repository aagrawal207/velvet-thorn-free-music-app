import UIKit
import XCTest

/// The progress bar spans the whole column and the like heart sits in the track heading: seeks are linear across
/// the bar, and liking stays a plain tap on a filled or outlined heart beside the title.
@MainActor
final class GanaBajanaPlayerProgressBarUITests: XCTestCase {
    private let fixtureDuration: TimeInterval = 262

    override func setUpWithError() throws { continueAfterFailure = false }

    func testBarSpansTheColumnAndTheHeartInTheHeadingStillLikes() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.searchAndPlayTumHiHo()
        try ui.openPlayer()
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        XCTAssertEqual(try ui.duration(), fixtureDuration, accuracy: 1)

        let like = ui.app.buttons["player.like"]
        try ui.requireHittable(like)
        assertBarAndHeadingGeometry(ui.app)
        XCTAssertGreaterThan(ui.app.buttons["player.playPause"].frame.minY, ui.app.sliders["player.seek"].frame.maxY)

        // The fixture song starts liked; the outline shows once it is not.
        XCTAssertEqual(like.label, "Unlike this song")
        XCTAssertTrue(like.isSelected)
        try ui.seek(to: 0.5)
        try ui.expectPosition(0.5 * fixtureDuration, tolerance: 6)
        ui.capture("player-bar-half")
        // Through the real mini-player flow the accent is the coral default.
        let heartFrame = like.frame
        let likedGlyph = try HeartGlyph(ui.app.screenshot(), frame: ui.app.frame, heart: heartFrame)
        XCTAssertTrue(likedGlyph.centre.isCoral, "A liked heart is a filled coral heart \(likedGlyph.centre)")
        XCTAssertGreaterThanOrEqual(likedGlyph.box.width, 16, "The heart glyph is about 22 points wide \(likedGlyph.box)")
        XCTAssertLessThanOrEqual(likedGlyph.box.width, 28)

        let position = try ui.position()
        try ui.tap(like)
        try ui.wait("Unliking must clear the heart") { like.label == "Like this song" }
        XCTAssertFalse(like.isSelected)
        try ui.expectPosition(position, tolerance: 1)
        let unlikedGlyph = try HeartGlyph(ui.app.screenshot(), frame: ui.app.frame, heart: heartFrame)
        XCTAssertFalse(unlikedGlyph.centre.isCoral, "An unliked heart is an outline over the backdrop \(unlikedGlyph.centre)")
        XCTAssertGreaterThanOrEqual(unlikedGlyph.box.width, 16, "The outline keeps the glyph's size \(unlikedGlyph.box)")
        ui.capture("player-bar-unliked")

        try ui.seek(to: 0.99)
        try ui.wait("A drag to the end of the bar must reach the last 8 seconds") {
            (ui.positionIfVisible() ?? 0) >= self.fixtureDuration - 8
        }
        XCTAssertEqual(try ui.position() + ui.remaining(), fixtureDuration, accuracy: 1)
        XCTAssertEqual(try ui.trailingTime().seconds, fixtureDuration, accuracy: 1, "The right label shows the song length by default")

        // A plain tap on the heart likes the song; it never seeks.
        let endPosition = try ui.position()
        try ui.tap(like)
        try ui.wait("Tapping the heart must like the song") { like.label == "Unlike this song" }
        XCTAssertTrue(like.isSelected)
        try ui.expectPosition(endPosition, tolerance: 1)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        ui.capture("player-bar-end-liked")

        try ui.seek(to: 0.2)
        try ui.expectPosition(0.2 * fixtureDuration, tolerance: 6)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
    }

    /// Opens the player directly over fixture artwork, so the heading, the bar and the container-free transport are
    /// checked on every device class and appearance without the phone tab bar.
    func testHeadingBarAndTransportSitOnTheArtworkBackdropInDarkAppearance() throws {
        try assertPlayerOverArtwork(light: false)
    }

    func testHeadingBarAndTransportSitOnTheArtworkBackdropInLightAppearance() throws {
        try assertPlayerOverArtwork(light: true)
    }

    private func assertPlayerOverArtwork(light: Bool) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-ui", "--skip-welcome", "--reset-ui", "--player", "--artwork-fixture"]
            + (light ? ["--light"] : [])
        app.launchEnvironment["GANABAJANA_TEST_STORE"] = "player-bar-\(UUID().uuidString)"
        app.launch()
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let appearance = light ? "light" : "dark"
        let seek = app.sliders["player.seek"]
        let like = app.buttons["player.like"]
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertTrue(like.waitForExistence(timeout: 15))
        XCTAssertTrue(seek.exists)
        assertBarAndHeadingGeometry(app)
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(like.frame))
        XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(seek.frame))

        // The transport keeps its geometry without a container: even spacing, shared center line, 80-point play.
        let previous = app.buttons["player.previous"].frame, play = app.buttons["player.playPause"].frame,
            next = app.buttons["player.next"].frame
        XCTAssertEqual(previous.midY, play.midY, accuracy: 1)
        XCTAssertEqual(next.midY, play.midY, accuracy: 1)
        XCTAssertEqual(play.minX - previous.maxX, next.minX - play.maxX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(play.width + 1e-6, 80)
        XCTAssertGreaterThan(play.minY, seek.frame.maxY)

        func drag(to progress: CGFloat) {
            let current = (AppUIClock.seconds(elapsed.value as? String) ?? 0) / fixtureDuration
            let start = seek.coordinate(withNormalizedOffset: CGVector(dx: min(app.playerSeekNormalizedX(forProgress: current), 0.98), dy: 0.5))
            let end = seek.coordinate(withNormalizedOffset: CGVector(dx: app.playerSeekNormalizedX(forProgress: progress), dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)
            waitFor("The drag must land at \(progress) of the fixture") {
                guard let seconds = AppUIClock.seconds(elapsed.value as? String) else { return false }
                return abs(seconds - progress * self.fixtureDuration) <= 6
            }
        }
        if like.label == "Like this song" {
            like.tap()
            waitFor("The fixture song must be liked to show the filled heart") { like.label == "Unlike this song" }
        }
        drag(to: 0.5)
        let likedShot = capture(app, "player-\(appearance)")
        let heartFrame = like.frame
        let liked = try HeartGlyph(likedShot, frame: app.frame, heart: heartFrame)
        // The direct launch must render the coral default, not the system blue the cover fell back to before.
        XCTAssertTrue(liked.centre.isCoral, "A liked heart is filled with the coral accent \(liked.centre)")
        XCTAssertGreaterThanOrEqual(liked.box.width, 16, "The heart glyph is about 22 points wide \(liked.box)")
        XCTAssertLessThanOrEqual(liked.box.width, 28)
        let bar = try HeartGlyph.pixels(likedShot, frame: app.frame)
            .color(at: CGPoint(x: seek.frame.minX + seek.frame.width * 0.25, y: seek.frame.midY))
        XCTAssertTrue(bar.isCoral, "The filled part of the bar is the coral accent \(bar)")

        like.tap()
        waitFor("Unliking must not move the position") {
            like.label == "Like this song" && abs((AppUIClock.seconds(elapsed.value as? String) ?? -1) - 0.5 * self.fixtureDuration) <= 6
        }
        let unlikedShot = capture(app, "player-\(appearance)-unliked")
        let unliked = try HeartGlyph(unlikedShot, frame: app.frame, heart: heartFrame)
        XCTAssertFalse(unliked.centre.isCoral, "An unliked heart is an outline over the backdrop \(unliked.centre)")
        XCTAssertGreaterThanOrEqual(unliked.box.width, 16, "The outline keeps the glyph's size \(unliked.box)")
        let backdrop = try HeartGlyph.pixels(unlikedShot, frame: app.frame)
            .color(at: CGPoint(x: heartFrame.midX, y: heartFrame.minY - 6))
        XCTAssertLessThanOrEqual(unliked.centre.distance(to: backdrop), 0.15,
                                 "The unliked interior shows the backdrop \(unliked.centre) vs \(backdrop)")
        like.tap()
        waitFor("The heart must like again on tap") { like.label == "Unlike this song" }
        drag(to: 0.99)
        capture(app, "player-\(appearance)-end")

        // Regular-width windows also use the side-by-side landscape player.
        guard window.width > 700 else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        if ProcessInfo.processInfo.environment["GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS"] == "1" {
            AppUITestDriver.requestSceneGeometry(.landscapeLeft)
        }
        waitFor("The window must turn landscape") {
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }
        waitFor("The row must settle in landscape") {
            abs(seek.frame.minX - elapsed.frame.minX) <= 1 && abs(seek.frame.maxX - app.buttons["player.trailingTime"].frame.maxX) <= 1
        }
        assertBarAndHeadingGeometry(app)
        XCTAssertGreaterThan(app.buttons["player.playPause"].frame.minY, seek.frame.maxY)
        capture(app, "player-\(appearance)-landscape")
    }

    /// The bar spans the column between the time labels and the heart sits beside the title and artist lines.
    private func assertBarAndHeadingGeometry(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let seek = app.sliders["player.seek"].frame
        let like = app.buttons["player.like"].frame
        let elapsed = app.staticTexts["player.elapsed"].frame
        let trailingTime = app.buttons["player.trailingTime"].frame
        let title = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.track.")).firstMatch.frame
        let artist = app.buttons["player.artistName"].frame
        XCTAssertEqual(seek.minX, elapsed.minX, accuracy: 1, "The bar starts at the column's leading edge", file: file, line: line)
        XCTAssertEqual(seek.maxX, trailingTime.maxX, accuracy: 1, "The bar ends at the column's trailing edge", file: file, line: line)
        XCTAssertGreaterThanOrEqual(seek.height + 1e-6, 44, "The bar keeps a thumb-sized target", file: file, line: line)
        XCTAssertLessThan(seek.height, 60, "The bar no longer carries the heart's row", file: file, line: line)
        XCTAssertGreaterThan(seek.minY, artist.maxY, "The bar follows the heading", file: file, line: line)
        XCTAssertLessThan(elapsed.minY + 1e-6, trailingTime.maxY, file: file, line: line)
        XCTAssertGreaterThanOrEqual(elapsed.minY + 1e-6, seek.midY, "The time labels sit under the bar", file: file, line: line)
        XCTAssertGreaterThan(like.midY, title.minY, "The heart is centred on the title and artist block", file: file, line: line)
        XCTAssertLessThan(like.midY, artist.maxY, file: file, line: line)
        XCTAssertEqual(like.maxX, trailingTime.maxX, accuracy: 1, "The heart ends the heading at the column's trailing edge", file: file, line: line)
        XCTAssertEqual(like.width, 52, accuracy: 1, file: file, line: line)
        XCTAssertEqual(like.height, 52, accuracy: 1, file: file, line: line)
        XCTAssertLessThanOrEqual(title.maxX, like.minX + 1e-6, "The title shrinks to make room for the heart", file: file, line: line)
        XCTAssertLessThanOrEqual(artist.maxX, like.minX + 4 + 1e-6, file: file, line: line)
    }

    private func waitFor(_ message: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                         condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail(message, file: file, line: line)
    }

    @discardableResult
    private func capture(_ app: XCUIApplication, _ name: String) -> XCUIScreenshot {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return screenshot
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "player-bar")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

/// The heart glyph inside the like button's frame, found as the pixels that differ from the button's backdrop.
@MainActor
struct HeartGlyph {
    /// Bounding box of the glyph in screen points.
    let box: CGRect
    /// Colour at the centre of the glyph's box: the fill of a liked heart, the backdrop inside an outline.
    let centre: ScreenPixels.Color

    init(_ screenshot: XCUIScreenshot, frame: CGRect, heart: CGRect) throws {
        let pixels = try ScreenPixels(screenshot, frame: frame)
        // The button's corners are backdrop; the median of the whole slot is the colour the glyph stands out from.
        var samples: [ScreenPixels.Color] = []
        var stepX = heart.minX
        while stepX < heart.maxX {
            var stepY = heart.minY
            while stepY < heart.maxY {
                samples.append(pixels.color(at: CGPoint(x: stepX, y: stepY)))
                stepY += 1
            }
            stepX += 1
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let backdrop = ScreenPixels.Color(red: median(samples.map(\.red)), green: median(samples.map(\.green)),
                                          blue: median(samples.map(\.blue)))
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        stepX = heart.minX
        while stepX < heart.maxX {
            var stepY = heart.minY
            while stepY < heart.maxY {
                // Half-covered edge pixels sit near 0.4 from the backdrop; the gradient across the slot stays well under.
                if pixels.color(at: CGPoint(x: stepX, y: stepY)).distance(to: backdrop) > 0.35 {
                    minX = min(minX, stepX); maxX = max(maxX, stepX)
                    minY = min(minY, stepY); maxY = max(maxY, stepY)
                }
                stepY += 1
            }
            stepX += 1
        }
        guard minX.isFinite else { throw AppUIWorkflowFailure(message: "No heart glyph was found inside \(heart)") }
        box = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        centre = pixels.color(at: CGPoint(x: box.midX, y: box.midY))
    }

    static func pixels(_ screenshot: XCUIScreenshot, frame: CGRect) throws -> ScreenPixels {
        try ScreenPixels(screenshot, frame: frame)
    }
}

@MainActor
struct ScreenPixels {
    struct Color: CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double

        var saturation: Double { max(red, green, blue) - min(red, green, blue) }
        var description: String { String(format: "(%.2f, %.2f, %.2f)", red, green, blue) }

        /// The coral accent in either appearance: red leads clearly over green and blue.
        var isCoral: Bool { red > 0.7 && red - green > 0.3 && red - blue > 0.25 }

        func distance(to other: Color) -> Double {
            max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
        }
    }

    private let width: Int
    private let height: Int
    private let bytes: [UInt8]
    private let frame: CGRect

    /// `frame` is the screen-point rectangle the screenshot covers, normally the application's frame.
    init(_ screenshot: XCUIScreenshot, frame: CGRect) throws {
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                     | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
        self.width = width
        self.height = height
        self.bytes = bytes
        self.frame = frame
    }

    func color(at point: CGPoint) -> Color {
        let x = Int(((point.x - frame.minX) / frame.width * CGFloat(width)).rounded(.down))
        let y = Int(((point.y - frame.minY) / frame.height * CGFloat(height)).rounded(.down))
        let offset = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Color(red: Double(bytes[offset]) / 255, green: Double(bytes[offset + 1]) / 255, blue: Double(bytes[offset + 2]) / 255)
    }
}
