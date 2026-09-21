import XCTest
@testable import GanaBajana

@MainActor
final class LyricsFallbackLiveTests: XCTestCase {
    func testLiveYouTubeRecordingLinksReturnAttributedPlainLyrics() async throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Enable the live provider tests to inspect public recording-linked lyrics.")
        }
        let catalog = YouTubeMusicService()
        var found = 0
        for track in [CatalogDiscovery.starters(for: .hindi)[0], CatalogDiscovery.starters(for: .english)[0]] {
            let document = try await catalog.lyrics(for: track)
            XCTAssertEqual(document.trackID, track.id)
            XCTAssertTrue(document.lines.isEmpty)
            XCTAssertTrue(document.kind == .plain || document.kind == .unavailable)
            if document.kind == .plain {
                XCTAssertFalse(document.plainText?.isEmpty ?? true)
                XCTAssertTrue(document.providerSource?.isRecordingLinked == true)
                XCTAssertEqual(document.sourceURL, track.shareURL)
                found += 1
            }
            print("LYRICS FALLBACK LIVE id=\(track.id) kind=\(document.kind.rawValue) source=\(document.source) characters=\(document.plainText?.count ?? 0)")
        }
        if found == 0 { throw XCTSkip("The provider omitted lyrics for both reference recordings.") }
    }
}
