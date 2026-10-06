import XCTest

/// Settings search: each result opens the page that holds its row. The table mirrors `SettingsSearchIndex`
/// (signed out, so the sign-in-only import row is absent); a renamed or moved row fails here.
@MainActor
final class GanaBajanaSettingsSearchUITests: XCTestCase {
    private let entries: [(query: String, id: String, row: String, page: SettingsPageID)] = [
        ("Audio Quality", "audioQuality", "settings.audioQuality", .playback),
        ("Equalizer", "equalizer", "settings.equalizer", .playback),
        ("Normalize Volume", "normalize", "settings.normalize", .playback),
        ("Crossfade", "crossfade", "settings.crossfade", .playback),
        ("Automix", "automix", "settings.automix", .playback),
        ("Gapless Playback", "gapless", "settings.gapless", .playback),
        ("Autoplay", "autoplay", "settings.autoplay", .playback),
        ("Swipe Up on the Player", "playerSwipeUp", "settings.playerSwipeUp", .playback),
        ("Skip Non-Music Sections", "sponsorBlock", "settings.sponsorBlock", .playback),
        ("Shuffle Order", "shuffleStyle", "settings.shuffleStyle", .playback),
        ("iCloud Sync", "icloud", "settings.icloud", .library),
        ("Download over Cellular", "downloadsCellular", "settings.downloadsCellular", .library),
        ("Download Liked Songs", "autoDownloadLiked", "settings.autoDownloadLiked", .library),
        ("Storage & Cached Songs", "storage", "settings.storage", .library),
        ("Save Listening History", "history", "settings.history", .library),
        ("Clear Listening History", "clearHistory", "settings.clearHistory", .library),
        ("Appearance", "appearance", "settings.appearance", .appearance),
        ("Accent Color", "accent", "settings.accent", .appearance),
        ("App Icon", "appIcon", "settings.appIcon", .appearance),
        ("Player Background", "playerBackground", "settings.playerBackground", .appearance),
        ("Discovery Balance", "discoveryFamiliarity", "settings.discoveryFamiliarity", .discovery),
        ("Customize Home", "customizeHome", "settings.customizeHome", .discovery),
        ("Moment Mixes", "moments", "settings.moments.open", .discovery),
        ("Listening Languages", "languages", "settings.languages", .discovery),
        ("Listening Genres", "genres", "settings.genres", .discovery),
        ("New Release Alerts", "releaseAlerts", "settings.releaseAlerts", .discovery),
        ("Following", "following", "settings.following", .discovery),
        ("Catalog Sources", "sources", "settings.sources", .discovery),
        ("YouTube Account", "youtubeAccount", "settings.section.account", .account),
        ("YouTube Changes", "youtubeChanges", "settings.youtubeChanges", .account),
        ("Encrypted DNS", "encryptedDNS", "settings.encryptedDNS", .account),
        ("Remote Playback Fallback", "remoteFallback", "settings.remoteFallback", .account),
        ("Extractor Updates", "extractorUpdates", "settings.extractorUpdates", .account),
        ("Support Development", "tipJar", "settings.tipJar", .about),
        ("Help & Feedback", "support", "settings.support", .about),
        ("Privacy Policy", "privacy", "settings.privacy", .about),
        ("Version", "version", "settings.version", .about),
        ("Acknowledgements", "acknowledgements", "settings.acknowledgements", .about),
        ("Catalog, Audio and Lyrics Credits", "providers", "settings.provider.catalog", .about),
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 1_200
    }

    func testEverySearchResultOpensThePageThatShowsItsRow() throws {
        let ui = AppUITestDriver(testCase: self, prefix: "settings-search")
        addTeardownBlock { await ui.finish() }
        try ui.launch()
        try ui.openSettings()
        let field = ui.app.searchFields["Search Settings"]
        try ui.requireHittable(field)
        for entry in entries {
            try search(entry.query, in: field, ui: ui)
            let result = ui.app.buttons["settings.search.result.\(entry.id)"]
            try ui.requireHittable(result)
            XCTAssertEqual(ui.app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.search.result.")).firstMatch.identifier,
                           result.identifier, "\(entry.query) must rank its own setting first")
            try ui.tap(result)
            try ui.wait("\(entry.query) must open \(entry.page.title)") { ui.settingsNavigationBar.identifier == entry.page.title }
            try ui.reveal(ui.element(entry.row), maxSwipes: 24)
            try ui.tap(ui.settingsNavigationBar.buttons.firstMatch)
            try ui.wait("Back must return to the search results") { ui.settingsNavigationBar.identifier == "Settings" }
        }
    }

    func testEverydayWordsNoMatchAndClearingInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let ui = AppUITestDriver(testCase: self, prefix: "settings-search-\(appearance)")
            addTeardownBlock { await ui.finish() }
            try ui.launch(additionalArguments: appearance == "light" ? ["--light"] : [])
            try ui.openSettings()
            let field = ui.app.searchFields["Search Settings"]
            try search("dark mode", in: field, ui: ui)
            try ui.requireHittable(ui.app.buttons["settings.search.result.appearance"])
            XCTAssertEqual(ui.app.buttons["settings.search.result.appearance"].value as? String, "Appearance › Theme")
            try search("cache", in: field, ui: ui)
            try ui.requireHittable(ui.app.buttons["settings.search.result.storage"])
            try search("import", in: field, ui: ui)
            XCTAssertFalse(ui.app.buttons["settings.search.result.youtubeImport"].exists, "Import needs a signed-in account")
            try search("zzqx", in: field, ui: ui)
            try ui.requireHittable(ui.element("settings.search.empty"))
            ui.capture("settings-search-empty-\(appearance)")
            try search("eq", in: field, ui: ui)
            ui.capture("settings-search-results-\(appearance)")
            field.buttons["Clear text"].tap()
            try ui.wait("Clearing the query must restore the page list") { ui.app.buttons["settings.page.playback"].exists }
        }
    }

    private func search(_ query: String, in field: XCUIElement, ui: AppUITestDriver) throws {
        try ui.tap(field)
        if let current = field.value as? String, !current.isEmpty, current != "Search Settings" {
            field.buttons["Clear text"].tap()
            // iPad's form sheet drops keyboard focus when the field is cleared.
            try ui.tap(field)
        }
        try ui.wait("The search field must have keyboard focus") { field.hasKeyboardFocusForTyping }
        field.typeText(query)
    }
}

private extension XCUIElement {
    var hasKeyboardFocusForTyping: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) == true }
}

