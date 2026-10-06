import UIKit
import XCTest

@MainActor
final class GanaBajanaMiniPlayerProgressUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testBackgroundFillFollowsSeeksAndKeepsTransportControlsWorkingInDarkAppearance() throws {
        let ui = makeDriver()
        try ui.launch()
        try startPausedPlaylist(ui)
        let empty = try verifyProgressStages(ui, appearance: "dark", largeText: false)

        _ = try seekAndCapture(ui, fraction: 0.9, seconds: 235.8, name: "mini-progress-dark-filled-controls")
        let open = ui.app.buttons["miniPlayer.open"]
        let transport = ui.app.buttons["miniPlayer.playPause"]
        try ui.tap(transport)
        try ui.expectLabel(transport, "Pause")
        try ui.wait("The filled mini-player must start actual playback") {
            self.collapsedPosition(open, state: "Playing") != nil
        }
        let start = try XCTUnwrap(collapsedPosition(open, state: "Playing"))
        try ui.wait("Elapsed time must advance while the filled mini-player stays minimized") {
            guard let current = self.collapsedPosition(open, state: "Playing") else { return false }
            return current >= start + 1 && !ui.app.buttons["player.close"].exists
        }
        try ui.tap(transport)
        try ui.expectLabel(transport, "Play")
        let paused = try XCTUnwrap(collapsedPosition(open, state: "Paused"))
        try ui.openPlayer()
        try ui.expectPosition(paused)
        try ui.assertPausedPositionStaysPut()
        try ui.closePlayer()

        try ui.tap(ui.app.buttons["miniPlayer.next"])
        try ui.expectLabel(open, "Open player, Kesariya, Arijit Singh")
        try ui.expectValue(open, "Paused, 0:00 elapsed")
        try ui.expectLabel(transport, "Play")
        try revealPlaylistEndAboveGlass(ui)
        ui.capture("mini-progress-dark-next-song-reset")
        let next = try MiniPlayerPixels(ui.element("miniPlayer.container").screenshot())
        XCTAssertLessThan(try next.difference(from: empty, in: rightInterior), 0.015,
                          "Next must clear the fill behind the transport controls immediately.")
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.kesariya)
        try ui.expectPosition(0)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
    }

    func testBackgroundFillFollowsSeeksWithLargestTextInLightAppearance() throws {
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light", "-UIPreferredContentSizeCategoryName",
                                           UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue])
        try startPausedPlaylist(ui)
        _ = try verifyProgressStages(ui, appearance: "light-largest-text", largeText: true)
    }

    private let leftInterior = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.6)
    private let rightInterior = CGRect(x: 0.7, y: 0.2, width: 0.15, height: 0.6)

    private func startPausedPlaylist(_ ui: AppUITestDriver) throws {
        try ui.playSeededPlaylist()
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.waitForAdvance(from: 0, by: 1)
        try ui.pause()
        try ui.closePlayer()
    }

    private func verifyProgressStages(_ ui: AppUITestDriver, appearance: String,
                                      largeText: Bool) throws -> MiniPlayerPixels {
        let empty = try seekAndCapture(ui, fraction: 0, seconds: 0, name: "mini-progress-\(appearance)-start")
        let container = ui.element("miniPlayer.container")
        let bounds = container.frame
        if largeText {
            XCTAssertGreaterThan(bounds.height, 64, "The background must grow with accessibility-sized text.")
        } else {
            XCTAssertEqual(bounds.height, 64, accuracy: 1)
        }
        for id in ["miniPlayer.open", "miniPlayer.playPause", "miniPlayer.next"] {
            let button = ui.app.buttons[id]
            try ui.requireHittable(button)
            XCTAssertGreaterThanOrEqual(button.frame.width, 52 - 1e-6)
            XCTAssertGreaterThanOrEqual(button.frame.height, 52 - 1e-6)
            XCTAssertTrue(bounds.insetBy(dx: -1, dy: -1).contains(button.frame))
        }
        XCTAssertEqual(container.buttons.count, 3, "Progress must not add a separate interactive control.")
        try ui.assertMiniPlayerAboveTabs()

        let half = try seekAndCapture(ui, fraction: 0.5, seconds: 131, name: "mini-progress-\(appearance)-half")
        let late = try seekAndCapture(ui, fraction: 0.9, seconds: 235.8, name: "mini-progress-\(appearance)-near-end")

        // Interior image differences catch a bottom-line-only progress indicator without depending on an exact tint.
        XCTAssertGreaterThan(try half.difference(from: empty, in: leftInterior), 0.02,
                             "Halfway playback must visibly tint the body of the left half.")
        XCTAssertLessThan(try half.difference(from: empty, in: rightInterior), 0.015,
                          "The unplayed right side must retain its glass background.")
        XCTAssertLessThan(try late.difference(from: half, in: leftInterior), 0.015,
                          "Progress must extend the existing fill rather than intensifying it.")
        XCTAssertGreaterThan(try late.difference(from: half, in: rightInterior), 0.02,
                             "Late playback must extend the background behind the transport controls.")
        XCTAssertLessThan(try late.difference(from: empty, in: CGRect(x: 0.005, y: 0.025, width: 0.015, height: 0.05)),
                          0.015, "The fill must stay inside the capsule's rounded corner.")

        let reset = try seekAndCapture(ui, fraction: 0, seconds: 0, name: "mini-progress-\(appearance)-seek-back")
        XCTAssertLessThan(try reset.difference(from: empty, in: CGRect(x: 0.2, y: 0.2, width: 0.65, height: 0.6)),
                          0.015, "Seeking backward must clear the previous fill without leaving a trailing region.")
        return empty
    }

    private func seekAndCapture(_ ui: AppUITestDriver, fraction: CGFloat, seconds: TimeInterval,
                                name: String) throws -> MiniPlayerPixels {
        try ui.openPlayer()
        try ui.expectCurrentTrack(AppUIFixture.tumHiHo)
        try ui.expectLabel(ui.app.buttons["player.playPause"], "Play")
        XCTAssertEqual(try ui.duration(), 262, accuracy: 1)
        try ui.seek(to: fraction)
        try ui.expectPosition(seconds, tolerance: 2)
        let elapsed = try XCTUnwrap(ui.app.staticTexts["player.elapsed"].value as? String)
        try ui.closePlayer()
        try ui.wait("The full player must close before inspecting its minimized background") {
            !ui.app.buttons["player.close"].exists
        }
        try ui.expectLabel(ui.app.buttons["miniPlayer.open"], "Open player, Tum Hi Ho, Arijit Singh")
        try ui.expectValue(ui.app.buttons["miniPlayer.open"], "Paused, \(elapsed) elapsed")
        try ui.expectLabel(ui.app.buttons["miniPlayer.playPause"], "Play")
        try revealPlaylistEndAboveGlass(ui)
        ui.capture(name)
        return try MiniPlayerPixels(ui.element("miniPlayer.container").screenshot())
    }

    /// The seeded playlist sits under the capsule. Once its last row and footer clear the glass, only the flat page
    /// background passes beneath it, so every sample differs by the progress fill alone.
    private func revealPlaylistEndAboveGlass(_ ui: AppUITestDriver) throws {
        let glass = ui.element("miniPlayer.container")
        let lastRow = ui.element("library.playlist.track.\(AppUIFixture.shapeOfYou)")
        let footer = ui.app.staticTexts["Use Edit to reorder or remove songs."]
        let navigation = ui.app.navigationBars[AppUIFixture.seededPlaylist]
        let window = ui.app.windows.firstMatch
        var context = "The seeded playlist is not on screen"
        for _ in 0...16 {
            let glassFrame = glass.exists ? glass.frame : .null
            let content = [lastRow, footer].map { $0.exists ? $0.frame : CGRect.null }
            context = "glass: \(glassFrame), last row: \(content[0]), footer: \(content[1])"
            guard navigation.exists, usable(glassFrame) else { break }
            // Plain lists can pin a footer above rows still beneath the glass; the last row proves every row has cleared it.
            if content.allSatisfy({ usable($0) && $0.maxY <= glassFrame.minY + 1e-6 }) {
                // Sample only once any rubber-band motion has stopped moving the page under the glass.
                Thread.sleep(forTimeInterval: 0.3)
                if footer.exists, footer.frame == content[1] { return }
                continue
            }
            let bounds = window.frame
            let top = max(bounds.minY, navigation.frame.maxY)
            let height = glassFrame.minY - top
            guard usable(bounds), height > 88 else { break }
            // Centered drags stay inside the regular-width column and away from row menus and the glass.
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.width / 2, dy: glassFrame.minY - height * 0.2 - bounds.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: -height * 0.5))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        ui.captureFailure("mini-progress-backdrop", detail: context)
        throw AppUIWorkflowFailure(message: "The playlist's end must clear the mini-player before sampling its glass; \(context)")
    }

    private func usable(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    private func collapsedPosition(_ open: XCUIElement, state: String) -> TimeInterval? {
        let prefix = "\(state), "
        guard let value = open.value as? String, value.hasPrefix(prefix), value.hasSuffix(" elapsed") else { return nil }
        return AppUIClock.seconds(String(value.dropFirst(prefix.count).dropLast(" elapsed".count)))
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "mini-player-progress")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}

@MainActor
private struct MiniPlayerPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ screenshot: XCUIScreenshot) throws {
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
        rgba = bytes
    }

    func difference(from other: MiniPlayerPixels, in normalizedRect: CGRect) throws -> Double {
        guard width == other.width, height == other.height else {
            throw AppUIWorkflowFailure(message: "The mini-player's rendered size changed with playback progress.")
        }
        let left = max(0, Int(normalizedRect.minX * CGFloat(width)))
        let right = min(width, Int(normalizedRect.maxX * CGFloat(width)))
        let top = max(0, Int(normalizedRect.minY * CGFloat(height)))
        let bottom = min(height, Int(normalizedRect.maxY * CGFloat(height)))
        guard left < right, top < bottom else {
            throw AppUIWorkflowFailure(message: "The mini-player screenshot has no usable comparison region.")
        }
        var total = 0
        for y in top..<bottom {
            for x in left..<right {
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    total += abs(Int(rgba[offset + channel]) - Int(other.rgba[offset + channel]))
                }
            }
        }
        return Double(total) / Double((right - left) * (bottom - top) * 3 * 255)
    }
}
