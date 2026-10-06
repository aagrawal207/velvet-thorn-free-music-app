import SwiftUI

/// The six Settings pages the root list opens. Raw values name the `settings.page.<id>` rows and the
/// `settings.section.<id>` header each page carries on its first group.
enum SettingsPage: String, CaseIterable, Identifiable {
    case playback, library, appearance, discovery, account, about

    var id: String { rawValue }

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

    /// Root-list caption naming what the page holds, in the page's own group order.
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

    var systemImage: String {
        switch self {
        case .playback: "play.circle"
        case .library: "books.vertical"
        case .appearance: "paintbrush"
        case .discovery: "sparkles"
        case .account: "person.crop.circle"
        case .about: "info.circle"
        }
    }

    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .playback: SettingsPlaybackPage()
        case .library: SettingsLibraryPage()
        case .appearance: SettingsAppearancePage()
        case .discovery: SettingsDiscoveryPage()
        case .account: SettingsAccountPage()
        case .about: SettingsAboutPage()
        }
    }
}

extension View {
    /// Chrome shared by the root list and every page. Done closes the whole sheet from any depth, so it cannot
    /// use the page's `dismiss`, which would only pop the page.
    func settingsPageChrome(_ title: String, model: MusicAppModel) -> some View {
        settingsFormChrome()
            .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("settings.form")
            .appSheetDoneButton(id: "settings.done") {
                AppNavigationIntent.perform(in: model) { model.isSettingsPresented = false }
            }
    }
}

/// Row builders shared by the pages; every write goes through `updatePreferences`.
@MainActor
struct SettingsControls {
    let model: MusicAppModel

    func preference<Value>(_ keyPath: WritableKeyPath<UserPreferences, Value>) -> Binding<Value> {
        let model = model
        return Binding {
            model.library.preferences[keyPath: keyPath]
        } set: { value in
            model.updatePreferences { $0[keyPath: keyPath] = value }
        }
    }

    func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            SettingsRowLabel(title: title, systemImage: systemImage)
        }
        .toggleStyle(CompactSwitchToggleStyle())
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    func toggleRow(_ title: String, systemImage: String, _ keyPath: WritableKeyPath<UserPreferences, Bool>, id: String) -> some View {
        toggleRow(title, systemImage: systemImage, isOn: preference(keyPath), id: id)
    }

    func menuRow<Choice: SettingsChoice>(_ title: String, systemImage: String, _ keyPath: WritableKeyPath<UserPreferences, Choice>,
                                         id: String, selection: Binding<Choice>? = nil) -> some View {
        SettingsMenuRow(title: title, systemImage: systemImage, selection: selection ?? preference(keyPath),
                        value: model.library.preferences[keyPath: keyPath].settingsTitle, id: id) {
            ForEach(Array(Choice.allCases), id: \.self) { choice in
                Text(choice.settingsTitle).tag(choice)
                    .accessibilityIdentifier("\(id).choice.\(choice.rawValue)")
            }
        }
    }

    /// A navigation row with a tile, title and optional trailing value.
    func navigationRow<Destination: View>(_ title: String, systemImage: String, value: String? = nil, id: String,
                                          @ViewBuilder destination: () -> Destination) -> some View {
        AppNavigationLink {
            destination()
        } label: {
            SettingsRowContent {
                SettingsRowLabel(title: title, systemImage: systemImage)
            } trailing: {
                if let value { SettingsRowValue(text: value) }
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    func externalLink(_ title: String, systemImage: String, value: String?, url: String, id: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                SettingsRowContent {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                        .foregroundStyle(AppTheme.primaryText)
                } trailing: {
                    SettingsRowValue(text: value ?? "", systemImage: "arrow.up.right")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
            .accessibilityLabel(value.map { "\(title), \($0), website" } ?? "\(title), website")
            .accessibilityIdentifier(id)
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch model.library.preferences.appearance {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// String-backed preference enums that a Settings menu row can list with per-choice identifiers.
protocol SettingsChoice: Hashable, CaseIterable, RawRepresentable where RawValue == String {
    var title: String { get }
    var settingsTitle: String { get }
}

extension SettingsChoice {
    var settingsTitle: String { title }
}

extension ShuffleStyle: SettingsChoice {
    var settingsTitle: String { self == .fewerRepeats ? "Fewer Repeats" : title }
}
extension AudioQualityPreference: SettingsChoice {
    var settingsTitle: String {
        switch self {
        case .best: "Best Available"
        case .balanced: "Balanced"
        case .dataSaver: "Data Saver"
        }
    }
}
extension PlayerSwipeUpAction: SettingsChoice {
    var settingsTitle: String { self == .moreOptions ? "More Options" : title }
}
extension DiscoveryFamiliarity: SettingsChoice {
    var settingsTitle: String {
        switch self {
        case .familiar: "More Familiar"
        case .balanced: "Balanced"
        case .newMusic: "More New"
        }
    }
}
extension AppAppearance: SettingsChoice {}
extension AutoDownloadScope: SettingsChoice {}
extension PlayerBackgroundMotion: SettingsChoice {}

extension HomeSectionKind {
    var settingsTitle: String {
        switch self {
        case .recentlyPlayed: "Recently Played"
        case .madeForYou: "Made for You"
        case .newReleases: "New Releases"
        case .becauseYouLike: "Because You Like"
        case .charts: "Charts"
        case .discovery: "Discovery"
        case .superLiked: "Super Liked"
        }
    }
}

extension YouTubeLibraryKind {
    var settingsTitle: String {
        switch self {
        case .likes: "Liked Songs"
        case .playlists: "Playlists"
        case .subscriptions: "Followed Artists"
        case .history: "Recent History"
        }
    }
}

// MARK: Playback

@MainActor
struct SettingsPlaybackPage: View {
    @Environment(MusicAppModel.self) private var model
    private var controls: SettingsControls { SettingsControls(model: model) }

    var body: some View {
        Form {
            Section {
                controls.menuRow("Audio Quality", systemImage: "waveform", \.audioQuality, id: "settings.audioQuality")
                equalizerRow
                controls.toggleRow("Normalize Volume", systemImage: "speaker.wave.2", \.normalizeVolume, id: "settings.normalize")
            } header: {
                SettingsSectionHeader(title: "Sound", id: "settings.section.playback")
            } footer: {
                SettingsFooter(id: "settings.footer.playback.sound") {
                    Text(audioQualityDescription)
                        .accessibilityIdentifier("settings.audioQuality.description")
                    Text("Normalize Volume lowers loud songs and raises quiet ones by up to 6 dB using source loudness information. Peak limiting can reduce the boost. Songs without that information stay unchanged. Boost is unavailable for live radio and unsupported streams.")
                        .accessibilityIdentifier("settings.normalize.description")
                }
            }
            .settingsSectionRows()

            Section {
                VStack(spacing: 0) {
                    SettingsCrossfadeRow()
                    Divider().padding(.leading, SettingsRowMetrics.textInset)
                    controls.toggleRow("Automix", systemImage: "wand.and.stars", \.automix, id: "settings.automix")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.transitions")
                controls.toggleRow("Gapless Playback", systemImage: "forward.end", \.gaplessPlayback, id: "settings.gapless")
                controls.toggleRow("Autoplay", systemImage: "infinity", \.autoplay, id: "settings.autoplay")
            } header: {
                SettingsSectionHeader(title: "Transitions", id: "settings.group.playback.transitions")
            } footer: {
                SettingsFooter(id: "settings.footer.playback.transitions") {
                    Text("Crossfade sets how many seconds songs overlap. At 0 s, only Automix adds a short blend between songs.")
                        .accessibilityIdentifier("settings.automix.description")
                }
            }
            .settingsSectionRows()

            Section {
                controls.menuRow("Swipe Up on the Player", systemImage: "hand.draw", \.playerSwipeUpAction, id: "settings.playerSwipeUp")
                controls.toggleRow("Skip Non-Music Sections", systemImage: "forward.frame", \.sponsorBlockSkipping, id: "settings.sponsorBlock")
            } header: {
                SettingsSectionHeader(title: "Player", id: "settings.group.playback.player")
            } footer: {
                SettingsFooter(id: "settings.footer.playback.player") {
                    Text("Skip non-music sections uses SponsorBlock's community markers to skip intros, outros and talk in YouTube uploads.")
                        .accessibilityIdentifier("settings.sponsorBlock.description")
                }
            }
            .settingsSectionRows()

            Section {
                controls.menuRow("Shuffle Order", systemImage: "shuffle", \.shuffleStyle, id: "settings.shuffleStyle",
                                 selection: shuffleBinding)
            } header: {
                SettingsSectionHeader(title: "Shuffle", id: "settings.group.playback.shuffle")
            } footer: {
                SettingsFooter(id: "settings.footer.playback.shuffle") {
                    Text(shuffleDescription)
                        .accessibilityIdentifier("settings.shuffleStyle.description")
                }
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.playback.title, model: model)
    }

    private var equalizerRow: some View {
        let settings = model.library.preferences.equalizer
        return controls.navigationRow("Equalizer", systemImage: "slider.vertical.3",
                               value: settings.isEnabled ? model.equalizerPresetChoice(for: settings).settingsTitle : "Off",
                               id: "settings.equalizer") {
            EqualizerView()
        }
    }

    /// Keep the compatibility marker when saving a choice that older builds might otherwise reinterpret.
    private var shuffleBinding: Binding<ShuffleStyle> {
        let model = model
        return Binding {
            model.library.preferences.shuffleStyle
        } set: { style in
            model.updatePreferences { $0.chooseShuffleStyle(style) }
        }
    }

    private var shuffleDescription: String {
        if !model.library.preferences.saveListeningHistory {
            return "Shuffle is random while Save listening history is off. Your choice is saved without changing the current queue."
        }
        return "Fewer repeats uses the last 7 days of saved plays to favor other songs on your next shuffle. Your current queue stays the same."
    }

    private var audioQualityDescription: String {
        let quality = model.library.preferences.audioQuality
        return "Audio quality applies from the next song. \(quality.title): \(quality.detail.prefix(1).lowercased() + quality.detail.dropFirst())."
    }
}

@MainActor
private struct SettingsCrossfadeRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SettingsRowMetrics.stackedSpacing))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            SettingsRowLabel(title: "Crossfade", systemImage: "arrow.triangle.merge")
            HStack(spacing: 14) {
                Slider(value: crossfadeBinding, in: UserPreferences.crossfadeRange, step: 1) {
                    Text("Crossfade")
                }
                .accessibilityValue(crossfadeLabel)
                .accessibilityIdentifier("settings.crossfade")
                .frame(minWidth: 44, minHeight: SettingsRowMetrics.minHeight)
                .contentShape(.interaction, Rectangle())
                .contentShape(.accessibility, Rectangle())
                Text(crossfadeLabel)
                    .appFont(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize()
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.leading, stacked ? SettingsRowMetrics.textInset : 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
    }

    private var crossfadeLabel: String {
        "\(Int(model.library.preferences.crossfadeSeconds.rounded())) s"
    }

    private var crossfadeBinding: Binding<TimeInterval> {
        let model = model
        return Binding {
            model.library.preferences.crossfadeSeconds
        } set: { value in
            let range = UserPreferences.crossfadeRange
            let clamped = value.isFinite ? min(max(value.rounded(), range.lowerBound), range.upperBound) : 0
            model.updatePreferences { $0.crossfadeSeconds = clamped }
        }
    }
}

// MARK: Library & iCloud

@MainActor
struct SettingsLibraryPage: View {
    @Environment(MusicAppModel.self) private var model
    @State private var isConfirmingClearHistory = false
    private var controls: SettingsControls { SettingsControls(model: model) }

    var body: some View {
        Form {
            Section {
                SettingsCloudSyncRow()
            } header: {
                SettingsSectionHeader(title: "iCloud", id: "settings.section.library")
            } footer: {
                SettingsFooter(id: "settings.footer.library.icloud") {
                    SettingsCloudSyncStatusLine()
                }
            }
            .settingsSectionRows()

            Section {
                controls.toggleRow("Download over Cellular", systemImage: "antenna.radiowaves.left.and.right",
                                   \.downloadsOverCellular, id: "settings.downloadsCellular")
                DownloadLikedSongsToggle(identifier: "settings.autoDownloadLiked")
            } header: {
                SettingsSectionHeader(title: "Downloads", id: "settings.group.library.downloads")
            } footer: {
                SettingsFooter(id: "settings.footer.library.downloads") {
                    Text("Downloads wait for Wi-Fi unless Download over cellular is on.")
                        .accessibilityIdentifier("settings.downloadsCellular.description")
                    Text("Download Liked Songs saves each new like to this device. Super Liked Only saves only your super likes. Changing it never removes a download.")
                        .accessibilityIdentifier("settings.autoDownloadLiked.description")
                    Text("Transfers already submitted to iOS continue in the background. Audio preparation waits until you return. Force-quitting stops transfers until you reopen Velvet Thorn.")
                        .accessibilityIdentifier("settings.downloads.background.description")
                }
            }
            .settingsSectionRows()

            Section {
                AppNavigationLink {
                    StorageSettingsView()
                } label: {
                    SettingsRowLabel(title: "Storage & Cached Songs", systemImage: "internaldrive")
                        .settingsRowTarget()
                }
                .accessibilityHint("Browse cached songs and manage data on this device.")
                .accessibilityIdentifier("settings.storage")
                recoveryRows
            } header: {
                SettingsSectionHeader(title: "Storage", id: "settings.group.library.storage")
            } footer: {
                if let error = model.library.errorMessage {
                    SettingsFooter(id: "settings.footer.library.storage") {
                        Text(error)
                            .foregroundStyle(AppTheme.accent)
                            .accessibilityIdentifier("settings.library.error.description")
                    }
                }
            }
            .settingsSectionRows()

            Section {
                controls.toggleRow("Save Listening History", systemImage: "clock.arrow.circlepath", \.saveListeningHistory,
                                   id: "settings.history")
                Button(role: .destructive) {
                    AppNavigationIntent.perform(in: model) { isConfirmingClearHistory = true }
                } label: {
                    SettingsRowLabel(title: "Clear Listening History", systemImage: "trash")
                        .settingsRowTarget()
                }
                .disabled(model.library.events.isEmpty && model.library.recentlyPlayed.isEmpty)
                .accessibilityIdentifier("settings.clearHistory")
            } header: {
                SettingsSectionHeader(title: "History", id: "settings.group.library.history")
            } footer: {
                SettingsFooter(id: "settings.footer.library.history") {
                    Text(historyDescription)
                        .accessibilityIdentifier("settings.history.description")
                }
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.library.title, model: model)
        .alert("Clear Your Listening History?", isPresented: AppNavigationIntent.binding($isConfirmingClearHistory, in: model)) {
            Button("Clear History", role: .destructive) {
                model.player.flushListeningProgress()
                model.library.clearHistory()
                if model.library.errorMessage == nil {
                    model.showToast("Listening history cleared.")
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes recently played songs and resets your language stats, personal listening mixes and recap. The clear also syncs to your other devices when iCloud sync is enabled. Your likes, playlists and recommendation adjustments stay.")
        }
    }

    @ViewBuilder
    private var recoveryRows: some View {
        if model.library.errorMessage != nil {
            SettingsRowContent {
                SettingsRowLabel(title: "Library Storage", systemImage: "exclamationmark.triangle")
            } trailing: {
                SettingsRowValue(text: "Needs attention")
            }
            .foregroundStyle(AppTheme.accent)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.library.error")
            if model.library.requiresReload {
                LibraryReloadButton(identifier: "settings.library.reload")
                    .labelStyle(SettingsRowLabelStyle())
            }
        }
    }

    private var historyDescription: String {
        model.library.preferences.saveListeningHistory
            ? "Listening history builds your recents, language stats, mixes and recap. It syncs with iCloud when enabled and may be included in device backups."
            : "New listening is not added to recents, language stats or recap while history is off. Existing history stays until you clear it."
    }
}

/// Both entry points confirm the same backlog and persist the same preference. The choice is a menu over
/// `autoDownloadScope`; only a scope with a backlog waits for the alert, so Cancel leaves the saved scope alone.
@MainActor
struct DownloadLikedSongsToggle: View {
    @Environment(MusicAppModel.self) private var model
    @State private var pendingScope: AutoDownloadScope?
    let identifier: String

    var body: some View {
        SettingsControls(model: model).menuRow("Download Liked Songs", systemImage: "arrow.down.heart", \.autoDownloadScope,
                                              id: identifier, selection: scopeBinding)
            .alert(confirmationTitle, isPresented: isConfirming, presenting: pendingScope) { scope in
                Button("Download") {
                    model.updatePreferences { $0.autoDownloadScope = scope }
                    guard model.library.preferences.autoDownloadScope == scope else { return }
                    model.downloadPendingAutoDownloads(for: scope)
                }
                .accessibilityIdentifier("\(identifier).confirm")
                Button("Cancel", role: .cancel) { }
                    .accessibilityIdentifier("\(identifier).cancel")
            } message: { scope in
                Text(explanation(for: scope))
            }
    }

    private var scopeBinding: Binding<AutoDownloadScope> {
        let model = model
        return Binding {
            model.library.preferences.autoDownloadScope
        } set: { scope in
            guard scope != model.library.preferences.autoDownloadScope else { return }
            if scope != .off, !model.pendingAutoDownloads(for: scope).isEmpty {
                AppNavigationIntent.perform(in: model) { pendingScope = scope }
            } else {
                model.updatePreferences { $0.autoDownloadScope = scope }
            }
        }
    }

    private var isConfirming: Binding<Bool> {
        AppNavigationIntent.binding(Binding(get: { pendingScope != nil }, set: { if !$0 { pendingScope = nil } }), in: model)
    }

    private var confirmationTitle: String {
        pendingScope == .superLiked ? "Download Super Liked Songs?" : "Download Liked Songs?"
    }

    private func explanation(for scope: AutoDownloadScope) -> String {
        let count = model.pendingAutoDownloads(for: scope).count
        let tier = scope == .superLiked ? "super liked" : "liked"
        let songs = count == 1 ? "1 \(tier) song" : "\(count.formatted()) \(tier) songs"
        let follow = scope == .superLiked ? "New super likes will follow." : "New likes will follow."
        return "\(songs) will be queued for download to this device. \(follow) Downloads wait for Wi-Fi unless cellular is allowed. Transfers already submitted to iOS continue in the background; audio preparation waits until you return. Force-quitting stops transfers until you reopen Velvet Thorn."
    }
}

// MARK: Appearance

@MainActor
struct SettingsAppearancePage: View {
    @Environment(MusicAppModel.self) private var model
    private var controls: SettingsControls { SettingsControls(model: model) }
    private var icons: AppIconController { model.appIcons }

    var body: some View {
        Form {
            Section {
                controls.menuRow("Appearance", systemImage: "circle.lefthalf.filled", \.appearance, id: "settings.appearance")
                AppNavigationLink {
                    AccentSettingsView()
                } label: {
                    SettingsRowContent {
                        Label {
                            Text("Accent Color")
                        } icon: {
                            Circle()
                                .fill(model.library.preferences.accent.color)
                                .frame(width: SettingsRowMetrics.iconSize, height: SettingsRowMetrics.iconSize)
                        }
                        .labelStyle(SettingsRowLabelStyle())
                    } trailing: {
                        SettingsRowValue(text: model.library.preferences.accent.title)
                    }
                }
                .accessibilityLabel("Accent Color")
                .accessibilityValue(model.library.preferences.accent.title)
                .accessibilityIdentifier("settings.accent")
                // Mac (Designed for iPad) cannot change the Home Screen icon; the picker would only show an error.
                if icons.supportsAlternateIcons {
                    AppNavigationLink {
                        AppIconPickerView()
                            .environment(icons)
                    } label: {
                        SettingsRowContent {
                            Label {
                                Text("App Icon")
                            } icon: {
                                Image(icons.current.previewImageName)
                                    .resizable()
                                    .frame(width: SettingsRowMetrics.iconSize, height: SettingsRowMetrics.iconSize)
                                    .clipShape(RoundedRectangle(cornerRadius: 6.3))
                            }
                            .labelStyle(SettingsRowLabelStyle())
                        } trailing: {
                            SettingsRowValue(text: icons.current.title)
                        }
                    }
                    .accessibilityIdentifier("settings.appIcon")
                }
            } header: {
                SettingsSectionHeader(title: "Theme", id: "settings.section.appearance")
            }
            .settingsSectionRows()

            Section {
                controls.menuRow("Player Background", systemImage: "sparkles.rectangle.stack", \.playerBackgroundMotion,
                                 id: "settings.playerBackground")
            } header: {
                SettingsSectionHeader(title: "Player", id: "settings.group.appearance.player")
            } footer: {
                SettingsFooter(id: "settings.footer.appearance.player") {
                    Text("Animates the full-screen player with the artwork's colors. Drift flows slowly, Pulse breathes while a song plays and React to Music follows the song. It uses more battery.")
                        .accessibilityIdentifier("settings.playerBackground.description")
                    PlayerBackgroundHoldNote(style: model.library.preferences.playerBackgroundMotion)
                }
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.appearance.title, model: model)
    }
}

// MARK: Discovery

@MainActor
struct SettingsDiscoveryPage: View {
    @Environment(MusicAppModel.self) private var model
    private var controls: SettingsControls { SettingsControls(model: model) }

    var body: some View {
        Form {
            Section {
                controls.menuRow("Discovery Balance", systemImage: "slider.horizontal.3", \.discoveryFamiliarity,
                                 id: "settings.discoveryFamiliarity")
                AppNavigationLink {
                    HomeCustomizationView()
                } label: {
                    SettingsRowLabel(title: "Customize Home", systemImage: "rectangle.3.group")
                        .settingsRowTarget()
                }
                .accessibilityIdentifier("settings.customizeHome")
                controls.navigationRow("Moment Mixes", systemImage: "sparkles", id: "settings.moments.open") {
                    MomentMixesSettingsView(controller: model.momentMixes)
                }
            } header: {
                SettingsSectionHeader(title: "Home and Mixes", id: "settings.section.discovery")
            } footer: {
                SettingsFooter(id: "settings.footer.discovery.home") {
                    Text("Discovery balance applies to new Home recommendations and future mixes. Existing mixes keep their songs.")
                        .accessibilityIdentifier("settings.discoveryFamiliarity.description")
                    Text("Super liked songs count more in Daily Mixes and seed Discover Weekly.")
                        .accessibilityIdentifier("settings.superLikes.description")
                }
            }
            .settingsSectionRows()

            Section {
                AppNavigationLink {
                    ListeningLanguagesView()
                } label: {
                    SettingsRowLabel(title: "Listening Languages", systemImage: "character.bubble")
                        .settingsRowTarget()
                }
                .accessibilityIdentifier("settings.languages")
                controls.navigationRow("Listening Genres", systemImage: "music.note.list", value: topGenreTitle, id: "settings.genres") {
                    ListeningGenresView()
                }
            } header: {
                SettingsSectionHeader(title: "Languages and Genres", id: "settings.group.discovery.languages")
            } footer: {
                SettingsFooter(id: "settings.footer.discovery.languages") {
                    Text("Listening languages and genres come from your last 30 days of plays, with optional recommendation adjustments.")
                }
            }
            .settingsSectionRows()

            Section {
                followingRow
                controls.toggleRow("New Release Alerts", systemImage: "bell.badge", \.newReleaseAlerts, id: "settings.releaseAlerts")
            } header: {
                SettingsSectionHeader(title: "Artists", id: "settings.group.discovery.artists")
            } footer: {
                SettingsFooter(id: "settings.footer.discovery.artists") {
                    Text("New release alerts are checked when you open the app and occasionally in the background.")
                        .accessibilityIdentifier("settings.releaseAlerts.description")
                }
            }
            .settingsSectionRows()

            Section {
                controls.navigationRow("Catalog Sources", systemImage: "square.stack.3d.up", value: catalogSourcesValue,
                                       id: "settings.sources") {
                    CatalogSourcesSettingsView()
                }
            } header: {
                SettingsSectionHeader(title: "Sources", id: "settings.group.discovery.sources")
            } footer: {
                SettingsFooter(id: "settings.footer.discovery.sources") {
                    Text(catalogSourcesDescription)
                        .accessibilityIdentifier("settings.sources.description")
                }
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.discovery.title, model: model)
    }

    /// Following lives in Library, so the row leaves Settings instead of pushing a page of its own.
    private var followingRow: some View {
        Button {
            AppNavigationIntent.perform(in: model) { model.openFollowingInLibrary() }
        } label: {
            SettingsRowContent {
                SettingsRowLabel(title: "Following", systemImage: "person.2")
                    .foregroundStyle(AppTheme.primaryText)
            } trailing: {
                SettingsRowValue(text: followingCount, systemImage: "chevron.right")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
        .accessibilityLabel("Following")
        .accessibilityValue(followingCount)
        .accessibilityHint("Opens the artists you follow in Library.")
        .accessibilityIdentifier("settings.following")
    }

    private var followingCount: String {
        let count = model.library.followedArtists.count
        return count == 1 ? "1 artist" : "\(count.formatted()) artists"
    }

    /// The strongest family after nudges, or "Learning" until classified plays exist.
    private var topGenreTitle: String {
        let profile = model.listeningGenreProfile
        return profile.isLearned ? profile.topFamily?.title ?? "Learning" : "Learning"
    }

    /// Switchable sources beyond YouTube Music, which is always searched.
    private var extraCatalogSources: [String] {
        model.library.preferences.enabledCatalogSources.filter { $0 != .youTubeMusic }.map(\.title)
    }

    private var catalogSourcesValue: String {
        let extra = extraCatalogSources
        return extra.isEmpty ? "YouTube Music" : "\(extra.count + 1) sources"
    }

    private var catalogSourcesDescription: String {
        let extra = extraCatalogSources
        guard let last = extra.last else {
            return "Searches ask YouTube Music only. Turn on more catalog sources to search them too."
        }
        let names = (["YouTube Music"] + extra.dropLast()).joined(separator: ", ")
        return "Searches ask \(names) and \(last). Results show where a song comes from."
    }
}

// MARK: Account & connection

@MainActor
struct SettingsAccountPage: View {
    @Environment(MusicAppModel.self) private var model
    @State private var isSigningIn = false
    private var controls: SettingsControls { SettingsControls(model: model) }

    var body: some View {
        Form {
            Section {
                accountRows
                controls.navigationRow("YouTube Changes", systemImage: "arrow.up.arrow.down", id: "settings.youtubeChanges") {
                    YouTubeAccountWriteView(controller: model.youTubeWrite, context: model.youTubeWrite.context,
                        onDone: { AppNavigationIntent.perform(in: model) { model.isSettingsPresented = false } })
                }
            } header: {
                SettingsSectionHeader(title: "YouTube", id: "settings.section.account")
            } footer: {
                SettingsFooter(id: "settings.footer.account.youtube") {
                    accountNotes
                }
            }
            .settingsSectionRows()

            Section {
                controls.toggleRow("Encrypted DNS", systemImage: "lock.shield", \.useEncryptedDNS, id: "settings.encryptedDNS")
                controls.toggleRow("Remote Playback Fallback", systemImage: "network", \.allowRemoteFallback, id: "settings.remoteFallback")
                controls.navigationRow("Extractor Updates", systemImage: "arrow.triangle.2.circlepath", id: "settings.extractorUpdates") {
                    ExtractorUpdatesView(controller: model.extractorUpdates)
                }
                if let nearby = model.nearbyDevices {
                    controls.navigationRow("Devices", systemImage: "laptopcomputer.and.iphone", value: devicesValue(nearby),
                                           id: "settings.devices") {
                        NearbyDevicesList(controller: nearby)
                            .settingsPageChrome("Devices", model: model)
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Connection", id: "settings.group.account.connection")
            } footer: {
                SettingsFooter(id: "settings.footer.account.connection") {
                    Text("Encrypted DNS keeps the music sites this app looks up private from the network you are on, such as public Wi-Fi. It uses your system's encrypted DNS when available, with Cloudflare as a fallback. Turn it off if a network blocks it.")
                        .accessibilityIdentifier("settings.encryptedDNS.description")
                    Text("Remote playback fallback is off by default. YouTubeKit's service (remote-production.youtubekit.dev) can help resolve audio. It receives the recording ID and requested provider responses, including headers.")
                        .accessibilityIdentifier("settings.remoteFallback.description")
                    Text("Devices finds Velvet Thorn on your other iPhone, iPad or Mac on the same network, so you can control them and move playback between them. Playback control and transfers stay on your local network. The connection key syncs through iCloud Keychain.")
                        .accessibilityIdentifier("settings.devices.description")
                }
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.account.title, model: model)
        .onAppear { model.account.refreshDiagnostics() }
        .sheet(isPresented: AppNavigationIntent.binding($isSigningIn, in: model)) {
            YouTubeSignInView()
                .appPresentationEnvironment(model)
                .preferredColorScheme(controls.preferredColorScheme)
                .appSheetChrome()
        }
    }

    private func devicesValue(_ nearby: NearbyDevicesController) -> String {
        guard nearby.isEnabled else { return "Off" }
        return nearby.peers.isEmpty ? "On" : "\(nearby.peers.count) Nearby"
    }

    @ViewBuilder
    private var accountRows: some View {
        if model.account.isSignOutPending {
            accountStatus("Sign-out pending")
            Button(role: .destructive) {
                model.stopTVLyricsForSignOut()
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            } label: {
                SettingsRowLabel(title: "Retry Sign-Out", systemImage: "arrow.clockwise")
                    .settingsRowTarget()
            }
            .accessibilityIdentifier("settings.youtubeSignOutRetry")
        } else if model.account.session != nil {
            accountStatus("Signed in")
            if model.account.isExpired {
                Button {
                    AppNavigationIntent.perform(in: model) { isSigningIn = true }
                } label: {
                    SettingsRowLabel(title: "Sign In Again", systemImage: "person.crop.circle.badge.plus")
                        .settingsRowTarget()
                }
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeSignIn")
            }
            controls.navigationRow("Import from YouTube Music", systemImage: "square.and.arrow.down.on.square",
                                   value: youTubeImportValue, id: "settings.youtubeImport") {
                YouTubeImportView()
            }
            Button(role: .destructive) {
                model.stopTVLyricsForSignOut()
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            } label: {
                SettingsRowLabel(title: "Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .settingsRowTarget()
            }
            .accessibilityIdentifier("settings.youtubeSignOut")
        } else {
            // The form paints labels in primary text; the accent marks this row as an action, not a status.
            Button {
                AppNavigationIntent.perform(in: model) { isSigningIn = true }
            } label: {
                SettingsRowLabel(title: "Sign In to YouTube", systemImage: "person.crop.circle.badge.plus")
                    .settingsRowTarget()
            }
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("settings.youtubeSignIn")
        }
    }

    @ViewBuilder
    private var accountNotes: some View {
        if model.account.isSignOutPending {
            Text("Your account is not being used. Retry to finish signing out on this device.")
        } else if let session = model.account.session {
            Text(model.account.isExpired
                 ? "Sign-in expired. Sign in again."
                 : "Signed in \(session.signedInAt.formatted(.relative(presentation: .named))). Google may limit an account that loads a lot of songs.")
        } else {
            Text("Signing in is optional. Google can associate requests with your account. Velvet Thorn does not send watch-history updates.")
                .accessibilityIdentifier("settings.youtubeSignIn.description")
            if let checkedAt = model.account.lastBotCheckAt {
                Text("YouTube asked for this check \(checkedAt.formatted(.relative(presentation: .named))).")
            }
        }
        Text(YouTubeConnectionCopy.importExplanation)
            .accessibilityIdentifier("settings.youtubeImport.description")
        Text(YouTubeConnectionCopy.playbackExplanation)
            .accessibilityIdentifier("settings.youtubePlayback.description")
        if let error = model.account.errorMessage {
            Text(error)
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeError")
        }
    }

    private func accountStatus(_ status: String) -> some View {
        SettingsRowContent {
            SettingsRowLabel(title: "YouTube", systemImage: "person.crop.circle")
        } trailing: {
            SettingsRowValue(text: status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.youtubeStatus")
    }

    private var youTubeImportValue: String {
        model.youTubeImport.lastImportedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not imported"
    }
}

// MARK: About

@MainActor
struct SettingsAboutPage: View {
    @Environment(MusicAppModel.self) private var model
    private var controls: SettingsControls { SettingsControls(model: model) }

    var body: some View {
        Form {
            Section {
                AppNavigationLink {
                    TipJarView(tips: model.tips)
                } label: {
                    SettingsRowLabel(title: "Support Development", systemImage: "heart.circle")
                        .settingsRowTarget()
                }
                .accessibilityIdentifier("settings.tipJar")
                controls.externalLink("Help & Feedback", systemImage: "questionmark.circle", value: nil,
                                      url: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md", id: "settings.support")
                controls.externalLink("Privacy Policy", systemImage: "hand.raised", value: nil,
                                      url: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md", id: "settings.privacy")
                SettingsRowContent {
                    SettingsRowLabel(title: "Version", systemImage: "info.circle")
                } trailing: {
                    SettingsRowValue(text: version)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.delights.versionTapped() }
                .sensoryFeedback(.impact(weight: .light), trigger: model.delights.aboutFlourishes)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version")
                .accessibilityValue(version)
                .accessibilityIdentifier("settings.version")
            } header: {
                SettingsSectionHeader(title: "Velvet Thorn", id: "settings.section.about")
            } footer: {
                SettingsFooter(id: "settings.footer.about.breezy") {
                    Text("Your library is saved on this device, syncs with iCloud when enabled and may be backed up. Music and artwork belong to their respective owners.")
                        .accessibilityIdentifier("settings.version.description")
                }
            }
            .settingsSectionRows()

            Section {
                controls.externalLink("Catalog", systemImage: "music.note.list", value: "YouTube Music", url: "https://music.youtube.com",
                                      id: "settings.provider.catalog")
                controls.externalLink("On-Device Audio Lookup", systemImage: "waveform", value: "YouTubeKit",
                                      url: "https://github.com/alexeichhorn/YouTubeKit", id: "settings.provider.audio")
                controls.externalLink("Lyrics", systemImage: "text.quote", value: "LRCLIB", url: "https://lrclib.net", id: "settings.provider.lyrics")
                AppNavigationLink {
                    AcknowledgementsView()
                } label: {
                    SettingsRowLabel(title: "Acknowledgements", systemImage: "doc.text")
                        .settingsRowTarget()
                }
                .accessibilityIdentifier("settings.acknowledgements")
            } header: {
                SettingsSectionHeader(title: "Credits", id: "settings.group.about.credits")
            }
            .settingsSectionRows()
        }
        .settingsPageChrome(SettingsPage.about.title, model: model)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let release = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        guard let build = info?["CFBundleVersion"] as? String else { return release }
        return "\(release) (\(build))"
    }
}

private struct AcknowledgementsView: View {
    private let text = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        ?? "Acknowledgements couldn't be loaded."

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .appFont(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.acknowledgements.content")
    }
}
