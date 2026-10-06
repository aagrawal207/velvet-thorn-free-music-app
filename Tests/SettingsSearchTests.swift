import XCTest
@testable import GanaBajana

final class SettingsSearchTests: XCTestCase {
    func testEveryWordMustMatchAndTitleMatchesRankFirst() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "cross").first?.id, "crossfade")
        XCTAssertEqual(SettingsSearchIndex.results(for: "dark mode").map(\.id), ["appearance"])
        XCTAssertEqual(SettingsSearchIndex.results(for: "Clear listening").first?.id, "clearHistory")
        XCTAssertTrue(SettingsSearchIndex.results(for: "dark zebra").isEmpty)
    }

    func testKeywordsFindSettingsByEverydayWords() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "eq").map(\.id).contains("equalizer"))
        XCTAssertTrue(SettingsSearchIndex.results(for: "cache").map(\.id).contains("storage"))
        XCTAssertTrue(SettingsSearchIndex.results(for: "sign in").map(\.id).contains("youtubeAccount"))
        XCTAssertTrue(SettingsSearchIndex.results(for: "SAAVN").map(\.id).contains("sources"))
    }

    func testSignInOnlyRowsAreOfferedOnlyWithASession() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "import").map(\.id).contains("youtubeImport"))
        XCTAssertFalse(SettingsSearchIndex.results(for: "import", signedIn: false).map(\.id).contains("youtubeImport"))
    }

    func testBlankQueriesShowNoResultsAndEntriesAreUnique() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "   ").isEmpty)
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(SettingsSearchIndex.entries.map(\.page)), Set(SettingsPage.allCases))
    }
}
