import XCTest
@testable import GanaBajana

@MainActor
final class YouTubeDataAPILiveTests: XCTestCase {
    func testBundledRestrictedCredentialLoadsRecordingMetadataAndSkipsClassification() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Select the live scheme for the real YouTube Data API check.")
        let credential = try XCTUnwrap(YouTubeDataAPI.bundledCredentials(), "Configure the ignored local API credential before a live run.")
        let api = YouTubeDataAPI(apiKey: credential.key, bundleIdentifier: credential.bundleIdentifier)
        let metadata = try await api.metadata(for: CatalogFixtures.englishID)
        XCTAssertEqual(metadata?.duration, 202)
        XCTAssertEqual(metadata?.language, .identified(.english, source: .youTubeAudioLanguage))
        let lyrics = ArtistSpotlightLyricsFixture()
        addTeardownBlock { await lyrics.requests.close() }
        let service = ArtistSpotlightLanguageService(provider: lyrics,
            recordingMetadataLookup: { try await api.recordingLanguage(for: $0) })
        let classified = try await service.classification(for: ArtistSpotlightTestSupport.track(CatalogFixtures.englishID))
        XCTAssertEqual(classified, .identified(.english, source: .youTubeAudioLanguage))
        let requests = await lyrics.requests.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
