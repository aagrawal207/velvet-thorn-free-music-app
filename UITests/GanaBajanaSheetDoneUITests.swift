import XCTest

/// Extra B (R13): every sheet's toolbar Done keeps a real 44-point target on iOS 26 glass toolbars.
@MainActor
final class GanaBajanaSheetDoneUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsSheetDoneKeepsA44PointTargetWhoseEdgesDismiss() throws {
        let ui = makeDriver()
        try ui.launch()
        try ui.openSettings()
        let done = ui.app.buttons["settings.done"]
        let bar = ui.app.navigationBars["Settings"]
        try ui.requireHittable(done)
        let frame = done.frame
        XCTAssertGreaterThanOrEqual(frame.width + 1e-6, 44, "\(frame)")
        XCTAssertGreaterThanOrEqual(frame.height + 1e-6, 44, "\(frame)")
        XCTAssertTrue(ui.app.windows.firstMatch.frame.insetBy(dx: -1e-6, dy: -1e-6).contains(frame), "\(frame)")
        // The bar includes the Search Settings drawer, so centring is measured against its title row.
        let title = bar.staticTexts["Settings"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(abs(frame.midY - title.frame.midY), 6, "The target stays centred on the title row: \(frame) beside \(title.frame)")
        ui.capture("settings-sheet-done-target")

        // The glass capsule is about 36 points tall; taps just inside the 44-point edges must still count.
        for offset in [CGVector(dx: 0.5, dy: 0.03), CGVector(dx: 0.5, dy: 0.97), CGVector(dx: 0.5, dy: 0.5)] {
            if !bar.exists {
                try ui.openSettings()
                try ui.requireHittable(done)
            }
            done.coordinate(withNormalizedOffset: offset).tap()
            try ui.wait("A tap at \(offset) inside the 44-point target must dismiss the sheet") { !bar.exists }
        }
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "sheet-done")
        addTeardownBlock { await ui.finish() }
        return ui
    }
}
