import SwiftUI

/// One searchable setting: where it lives and the words people use for it. Titles match the rows on each page.
struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let page: SettingsPage
    let section: String
    let systemImage: String
    let keywords: [String]
    /// The row exists only while a YouTube session is active, so search offers it only then.
    var requiresSignIn = false

    var location: String { "\(page.title) › \(section)" }

    /// The accessibility identifier of the row on its page; the search UI test opens each result and finds it.
    var rowIdentifier: String {
        switch id {
        case "youtubeAccount": "settings.section.account"
        case "moments": "settings.moments.open"
        case "providers": "settings.provider.catalog"
        default: "settings.\(id)"
        }
    }
}

enum SettingsSearchIndex {
    static let entries: [SettingsSearchEntry] = [
        entry("audioQuality", "Audio Quality", .playback, "Sound", "waveform", ["quality", "bitrate", "data saver", "best", "streaming"]),
        entry("equalizer", "Equalizer", .playback, "Sound", "slider.vertical.3", ["eq", "bass", "treble", "preset", "preamp", "sound"]),
        entry("normalize", "Normalize Volume", .playback, "Sound", "speaker.wave.2", ["loudness", "volume", "gain", "boost"]),
        entry("crossfade", "Crossfade", .playback, "Transitions", "arrow.triangle.merge", ["fade", "overlap", "blend"]),
        entry("automix", "Automix", .playback, "Transitions", "wand.and.stars", ["blend", "mix", "transition"]),
        entry("gapless", "Gapless Playback", .playback, "Transitions", "forward.end", ["gap", "silence", "album"]),
        entry("autoplay", "Autoplay", .playback, "Transitions", "infinity", ["continue", "keep playing", "radio", "queue"]),
        entry("playerSwipeUp", "Swipe Up on the Player", .playback, "Player", "hand.draw", ["gesture", "queue", "lyrics", "more options"]),
        entry("sponsorBlock", "Skip Non-Music Sections", .playback, "Player", "forward.frame", ["sponsorblock", "intro", "outro", "talk", "skip"]),
        entry("shuffleStyle", "Shuffle Order", .playback, "Shuffle", "shuffle", ["random", "repeats", "shuffle"]),
        entry("icloud", "iCloud Sync", .library, "iCloud", "icloud", ["sync", "cloud", "backup", "devices"]),
        entry("downloadsCellular", "Download over Cellular", .library, "Downloads", "antenna.radiowaves.left.and.right", ["mobile data", "cellular", "wifi", "offline"]),
        entry("autoDownloadLiked", "Download Liked Songs", .library, "Downloads", "arrow.down.heart", ["offline", "auto download", "super like", "likes"]),
        entry("storage", "Storage & Cached Songs", .library, "Storage", "internaldrive", ["cache", "space", "clear cache", "audio cache limit", "disk", "delete"]),
        entry("history", "Save Listening History", .library, "History", "clock.arrow.circlepath", ["history", "privacy", "recently played", "stats"]),
        entry("clearHistory", "Clear Listening History", .library, "History", "trash", ["delete history", "reset stats", "erase", "privacy"]),
        entry("appearance", "Appearance", .appearance, "Theme", "circle.lefthalf.filled", ["dark mode", "light mode", "theme", "system"]),
        entry("accent", "Accent Color", .appearance, "Theme", "paintpalette", ["color", "tint", "colour"]),
        entry("appIcon", "App Icon", .appearance, "Theme", "app.badge", ["icon", "home screen"]),
        entry("playerBackground", "Player Background", .appearance, "Player", "sparkles.rectangle.stack",
              ["animated", "animation", "motion", "artwork colors", "beat", "visualizer", "react to music"]),
        entry("discoveryFamiliarity", "Discovery Balance", .discovery, "Home and Mixes", "slider.horizontal.3", ["familiar", "new music", "recommendations"]),
        entry("customizeHome", "Customize Home", .discovery, "Home and Mixes", "rectangle.3.group", ["home sections", "reorder", "hide", "shelves", "layout"]),
        entry("moments", "Moment Mixes", .discovery, "Home and Mixes", "sparkles", ["motion", "time of day", "activity", "workout"]),
        entry("languages", "Listening Languages", .discovery, "Languages and Genres", "character.bubble", ["language", "hindi", "english", "punjabi"]),
        entry("genres", "Listening Genres", .discovery, "Languages and Genres", "music.note.list", ["genre", "style", "pop", "rock"]),
        entry("releaseAlerts", "New Release Alerts", .discovery, "Artists", "bell.badge", ["notifications", "releases", "new music", "alerts"]),
        entry("following", "Following", .discovery, "Artists", "person.2", ["followed artists", "follow", "artists"]),
        entry("sources", "Catalog Sources", .discovery, "Sources", "square.stack.3d.up", ["jiosaavn", "saavn", "gaana", "providers", "catalog"]),
        entry("youtubeAccount", "YouTube Account", .account, "YouTube", "person.crop.circle", ["sign in", "sign out", "google", "login", "account"]),
        entry("youtubeChanges", "YouTube Changes", .account, "YouTube", "arrow.up.arrow.down", ["write back", "sync to youtube", "likes"]),
        entry("youtubeImport", "Import from YouTube Music", .account, "YouTube", "square.and.arrow.down.on.square", ["import", "playlists", "transfer"],
              requiresSignIn: true),
        entry("encryptedDNS", "Encrypted DNS", .account, "Connection", "lock.shield", ["dns", "privacy", "network", "wifi"]),
        entry("remoteFallback", "Remote Playback Fallback", .account, "Connection", "network", ["youtubekit", "fallback", "playback errors"]),
        entry("extractorUpdates", "Extractor Updates", .account, "Connection", "arrow.triangle.2.circlepath", ["extractor", "update", "playback fix"]),
        entry("tipJar", "Support Development", .about, "Velvet Thorn", "heart.circle", ["tip", "donate", "support"]),
        entry("support", "Help & Feedback", .about, "Velvet Thorn", "questionmark.circle", ["help", "contact", "bug", "feedback"]),
        entry("privacy", "Privacy Policy", .about, "Velvet Thorn", "hand.raised", ["privacy", "data"]),
        entry("version", "Version", .about, "Velvet Thorn", "info.circle", ["build", "version", "about"]),
        entry("acknowledgements", "Acknowledgements", .about, "Credits", "doc.text", ["licenses", "open source", "credits"]),
        entry("providers", "Catalog, Audio and Lyrics Credits", .about, "Credits", "music.note.list", ["lrclib", "lyrics", "youtube music", "credits"]),
    ]

    private static func entry(_ id: String, _ title: String, _ page: SettingsPage, _ section: String, _ image: String,
                              _ keywords: [String], requiresSignIn: Bool = false) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, title: title, page: page, section: section, systemImage: image, keywords: keywords,
                            requiresSignIn: requiresSignIn)
    }

    /// Every query word must start a word in the title, keywords, page or section. Title matches rank first.
    static func results(for query: String, signedIn: Bool = true) -> [SettingsSearchEntry] {
        let terms = words(query)
        guard !terms.isEmpty else { return [] }
        return entries.filter { signedIn || !$0.requiresSignIn }.compactMap { entry -> (SettingsSearchEntry, Int)? in
            let title = words(entry.title)
            let other = words(([entry.page.title, entry.section] + entry.keywords).joined(separator: " "))
            var score = 0
            for term in terms {
                if title.contains(where: { $0.hasPrefix(term) }) { score += 2 }
                else if other.contains(where: { $0.hasPrefix(term) }) { score += 1 }
                else { return nil }
            }
            if fold(entry.title).hasPrefix(fold(query)) { score += 10 }
            return (entry, score)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
        .map(\.0)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Search results in place of the Settings list; a result opens the page that holds the setting.
@MainActor
struct SettingsSearchResults: View {
    @Environment(MusicAppModel.self) private var model
    let query: String

    var body: some View {
        let signedIn = model.account.session != nil && !model.account.isSignOutPending
        let results = SettingsSearchIndex.results(for: query, signedIn: signedIn)
        if results.isEmpty {
            Section {
                Text("No Settings Match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings.search.empty")
            }
            .settingsSectionRows()
        } else {
            Section {
                ForEach(results) { entry in
                    AppNavigationLink {
                        entry.page.destination
                    } label: {
                        SettingsRowContent {
                            SettingsRowLabel(title: entry.title, systemImage: entry.systemImage)
                        } trailing: {
                            SettingsRowValue(text: entry.page.title)
                        }
                        .settingsRowTarget()
                    }
                    .accessibilityLabel(entry.title)
                    .accessibilityValue(entry.location)
                    .accessibilityIdentifier("settings.search.result.\(entry.id)")
                }
            } header: {
                SettingsSectionHeader(title: results.count == 1 ? "1 Result" : "\(results.count) Results",
                                      id: "settings.search.header")
            }
            .settingsSectionRows()
        }
    }
}
