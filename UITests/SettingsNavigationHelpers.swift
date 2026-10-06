import XCTest

/// The six Settings pages behind the root list, with the rows each one holds.
enum SettingsPageID: String, CaseIterable {
    case playback, library, appearance, discovery, account, about

    var title: String {
        switch self {
        case .playback: "Playback"
        case .library: "Library & iCloud"
        case .appearance: "Appearance"
        case .discovery: "Discovery"
        case .account: "Account & Connection"
        case .about: "About Velvet Thorn"
        }
    }

    var summary: String {
        switch self {
        case .playback: "Quality, equalizer, crossfade and shuffle"
        case .library: "iCloud, downloads, storage and history"
        case .appearance: "Theme, accent color and app icon"
        case .discovery: "Home, mixes, languages and sources"
        case .account: "YouTube sign-in and network"
        case .about: "Support, help, privacy and credits"
        }
    }

    var rowID: String { "settings.page.\(rawValue)" }
    var sectionID: String { "settings.section.\(rawValue)" }

    /// The page that holds a Settings row, so a test can open it before revealing the row.
    static func containing(_ row: String) -> SettingsPageID? {
        let pages: [SettingsPageID: Set<String>] = [
            .playback: ["settings.audioQuality", "settings.equalizer", "settings.normalize", "settings.transitions",
                        "settings.crossfade", "settings.automix", "settings.gapless", "settings.autoplay",
                        "settings.playerSwipeUp", "settings.sponsorBlock", "settings.shuffleStyle"],
            .library: ["settings.icloud", "settings.downloadsCellular", "settings.autoDownloadLiked", "settings.storage",
                       "settings.library.error", "settings.library.reload", "settings.history", "settings.clearHistory"],
            .appearance: ["settings.appearance", "settings.accent", "settings.appIcon", "settings.playerBackground"],
            .discovery: ["settings.discoveryFamiliarity", "settings.customizeHome", "settings.languages", "settings.genres",
                         "settings.following", "settings.releaseAlerts", "settings.sources"],
            .account: ["settings.youtubeSignIn", "settings.youtubeStatus", "settings.youtubeImport", "settings.youtubeSignOut",
                       "settings.youtubeSignOutRetry", "settings.youtubeError", "settings.encryptedDNS", "settings.remoteFallback"],
            .about: ["settings.tipJar", "settings.support", "settings.privacy", "settings.version", "settings.provider.catalog",
                     "settings.provider.audio", "settings.provider.lyrics", "settings.acknowledgements"],
        ]
        return pages.first { $0.value.contains(row) }?.key
    }
}

extension AppUITestDriver {
    /// Opens a Settings page from anywhere inside the Settings sheet: Back returns to the root list first.
    func openSettingsPage(_ page: SettingsPageID) throws {
        if isShowingSettingsPage(page) { return }
        try returnToSettingsRoot()
        let row = app.buttons[page.rowID]
        // A captioned root list outgrows the screen at accessibility sizes; an off-screen row has no frame to aim at.
        if (try? reveal(row, direction: .down)) == nil { try reveal(row, direction: .up) }
        try tap(row)
        try wait("Settings must open the \(page.title) page") {
            self.isShowingSettingsPage(page) && self.element(page.sectionID).exists
        }
    }

    /// Opens the page that holds `row`.
    func openSettingsPage(containing row: String) throws {
        guard let page = SettingsPageID.containing(row) else {
            throw AppUIWorkflowFailure(message: "No Settings page lists \(row)")
        }
        try openSettingsPage(page)
    }

    /// Pops pushed Settings pages until the root list with its six page rows is visible.
    func returnToSettingsRoot() throws {
        for _ in 0..<4 {
            if isShowingSettingsRoot { return }
            let navigation = settingsNavigationBar
            let title = navigation.identifier
            let back = navigation.buttons.firstMatch
            guard back.exists, back.identifier != "settings.done", back.label != "Done" else {
                throw AppUIWorkflowFailure(message: "No Back control in Settings at \(title)")
            }
            try tap(back)
            try wait("Back must leave \(title)") { self.settingsNavigationBar.identifier != title }
        }
        try wait("Settings must show its root list") {
            self.isShowingSettingsRoot
        }
    }

    /// The visible Settings navigation bar, whichever page it belongs to.
    var settingsNavigationBar: XCUIElement {
        app.navigationBars.allElementsBoundByIndex.last { $0.isHittable } ?? app.navigationBars.firstMatch
    }

    private var isShowingSettingsRoot: Bool {
        // The first row can be outside a lazy Form's tree when Back restores a scrolled root.
        settingsNavigationBar.identifier == "Settings"
            && app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.page.")).firstMatch.exists
    }

    private func isShowingSettingsPage(_ page: SettingsPageID) -> Bool {
        let done = app.buttons["settings.done"]
        return settingsNavigationBar.identifier == page.title && done.exists && done.isHittable
    }
}

extension AppUITestDriver {
    /// While the Settings sheet is up, moves to the page that holds `row` unless it is already showing.
    func openSettingsPageIfNeeded(for row: String) throws {
        guard let page = SettingsPageID.containing(row), app.buttons["settings.done"].exists,
              !isShowingSettingsPage(page) else { return }
        try openSettingsPage(page)
    }
}

/// The Settings footer rhythm from docs/SETTINGS.md.
enum SettingsLayout {
    static let rowToFooter: CGFloat = 10
    static let footerToHeader: CGFloat = 24
}
