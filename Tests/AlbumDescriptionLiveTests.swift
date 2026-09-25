import XCTest
@testable import GanaBajana

@MainActor
final class AlbumDescriptionLiveTests: XCTestCase {
    func testLiveEnglishAndHindiAlbumHeadersSupplyAttributedDescriptions() async throws {
        guard ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Enable live provider tests to read public YouTube Music album descriptions.")
        }
        let provider = YouTubeMusicService()
        let albums = [("MPREb_KCNeTnK02S7", "Graduation", "Graduation_(album)"),
                      ("MPREb_E4GfUXfDfhy", "Aashiqui 2", "Aashiqui_2_(soundtrack)")]
        for (id, title, article) in albums {
            let result = try await provider.albumDescription(id: id)
            let description = try XCTUnwrap(result, "The recorded reference album no longer supplies an accepted description")
            XCTAssertEqual(description.albumID, id)
            XCTAssertEqual(description.albumTitle, title)
            XCTAssertTrue(description.text.hasPrefix(title + " is "))
            XCTAssertFalse(description.credits.isEmpty)
            XCTAssertEqual(description.sourceURL, URL(string: "https://en.wikipedia.org/wiki/" + article))
            XCTAssertEqual(description.licenseURL.host, "creativecommons.org")
            XCTAssertFalse(description.text.contains("From Wikipedia"))
            print("ALBUM DESCRIPTION LIVE id=\(id) source=\(description.sourceURL.absoluteString) license=\(description.license.title) characters=\(description.text.count)")
        }
    }
}
