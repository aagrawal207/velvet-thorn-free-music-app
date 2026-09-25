import XCTest

@MainActor
final class GanaBajanaWatchConnectivityUITests: XCTestCase {
    func testPairedPhonePlaybackUsesRealWatchConnectivity() throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_WATCH_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt in with a paired iPhone running the isolated --ui-watch-connectivity fixture.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let playPause = app.buttons["watch.playPause"]
        try wait("The paired iPhone must confirm its paused fixture queue", timeout: 30) {
            playPause.exists && playPause.isEnabled && playPause.label == "Play on iPhone"
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Tum Hi Ho")).firstMatch.exists)
        playPause.tap()
        try wait("A real Watch Connectivity command must start iPhone playback") {
            playPause.isEnabled && playPause.label == "Pause on iPhone"
                && !app.descendants(matching: .any)["watch.pending"].exists
        }
        let playing = XCTAttachment(screenshot: app.screenshot())
        playing.name = "Paired Watch Connectivity - iPhone playback confirmed"
        playing.lifetime = .keepAlways
        add(playing)

        app.buttons["watch.next"].tap()
        try wait("Next must select the iPhone queue's second recording") {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Kesariya")).firstMatch.exists
                && playPause.isEnabled && playPause.label == "Pause on iPhone"
        }
        playPause.tap()
        try wait("Pause must be acknowledged by the paired iPhone") {
            playPause.isEnabled && playPause.label == "Play on iPhone"
        }
        let paused = XCTAttachment(screenshot: app.screenshot())
        paused.name = "Paired Watch Connectivity - next song paused on iPhone"
        paused.lifetime = .keepAlways
        add(paused)
    }

    private func wait(_ message: String, timeout: TimeInterval = 12,
                      condition: @escaping @MainActor @Sendable () -> Bool) throws {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            let hierarchy = XCTAttachment(string: XCUIApplication().debugDescription)
            hierarchy.name = "Paired Watch Connectivity failure"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            throw ConnectivityFailure(description: "\(message): \(result)")
        }
    }
}

private struct ConnectivityFailure: Error, CustomStringConvertible {
    let description: String
}
