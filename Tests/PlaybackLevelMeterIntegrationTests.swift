import Foundation
import XCTest
@testable import GanaBajana

/// The level meter through a real AVPlayer item, so React to Music is proven to see the song being played.
@MainActor
final class PlaybackLevelMeterIntegrationTests: XCTestCase {
    func testMeteringReadsThePlayingSongAndStopsWhenTurnedOff() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 8)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 8))
        defer { player.pause() }
        player.setLevelMetering(true)
        player.play([Track(id: "local-meter", title: "Meter test")])
        try await PlaybackTestSupport.waitUntil(timeout: 10) { player.isPlaying && player.position > 0.3 }

        let first = player.levelMeter.read()
        try await PlaybackTestSupport.waitUntil(timeout: 5) {
            let reading = player.levelMeter.read()
            return reading.sequence != first.sequence && reading.level > 0.01
        }
        XCTAssertEqual(player.levelMeterAvailability, .available)
        let playing = player.levelMeter.read()
        XCTAssertTrue(playing.level.isFinite)

        player.setLevelMetering(false)
        try await Task.sleep(for: .milliseconds(300))
        let stopped = player.levelMeter.read().sequence
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(player.levelMeter.read().sequence, stopped, "Turning metering off stops publishing")
        XCTAssertNil(player.errorMessage)
    }
}
