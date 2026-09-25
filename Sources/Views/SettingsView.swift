import SwiftUI

@MainActor
struct SettingsView: View {
    // Controls own their 44-point height; only descriptive rows add space below their text.
    private static let rowInsets = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    private static let descriptionSpacing: CGFloat = 4
    private static let descriptionBottomInset: CGFloat = 8
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isConfirmingClearHistory = false
    @State private var isSigningIn = false
    private var icons: AppIconController { model.appIcons }

    var body: some View {
        Form {
            playbackSection
            librarySection
            appearanceSection
            discoverySection
            accountSection
            aboutSection
        }
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .listRowSpacing(0)
        .listSectionSpacing(20)
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.form")
        .onAppear { model.account.refreshDiagnostics() }
        .appSheetDoneButton(id: "settings.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        .sheet(isPresented: AppNavigationIntent.binding($isSigningIn, in: model)) {
            YouTubeSignInView()
                .preferredColorScheme(preferredColorScheme)
                .appSheetChrome()
        }
        .alert("Clear your listening history?", isPresented: AppNavigationIntent.binding($isConfirmingClearHistory, in: model)) {
            Button("Clear history", role: .destructive) {
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

    private var playbackSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                crossfadeRow
                Divider()
                described("Automix", "Adds a short blend between queued songs when Crossfade is 0 s. Leave both off for no overlap.", systemImage: "wand.and.stars",
                          isOn: preference(\.automix), id: "settings.automix")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.transitions")
            described("Gapless playback", "No silence between songs from the same album or mix.", systemImage: "forward.end",
                      isOn: preference(\.gaplessPlayback), id: "settings.gapless")
            described("Autoplay", "Keeps the music going with similar songs when your queue ends.", systemImage: "infinity",
                      isOn: preference(\.autoplay), id: "settings.autoplay")
            described("Normalize volume", "Turns louder songs down to a similar level. Quieter songs are not boosted.", systemImage: "speaker.wave.2",
                      isOn: preference(\.normalizeVolume), id: "settings.normalize")
            describedRow(shuffleDescription, id: "settings.shuffleStyle") {
                menuPicker("Shuffle order", systemImage: "shuffle", selection: preference(\.shuffleStyle),
                           value: model.library.preferences.shuffleStyle.title, id: "settings.shuffleStyle") {
                    ForEach(ShuffleStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                            .accessibilityIdentifier("settings.shuffleStyle.choice.\(style.rawValue)")
                    }
                }
            }
        } header: {
            sectionHeader("Playback", id: "playback")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var librarySection: some View {
        Section {
            iCloudRow
            described("Save listening history", model.library.preferences.saveListeningHistory
                       ? "Builds your recents, language stats, mixes and recap. Syncs with iCloud when enabled and may be included in device backups."
                       : "New listening won't be added to recents, language stats or recap. Existing history stays until you clear it.", systemImage: "clock.arrow.circlepath",
                      isOn: preference(\.saveListeningHistory), id: "settings.history")
            Button(role: .destructive) {
                AppNavigationIntent.perform(in: model) { isConfirmingClearHistory = true }
            } label: {
                rowLabel("Clear listening history", systemImage: "trash")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(model.library.events.isEmpty && model.library.recentlyPlayed.isEmpty)
            .accessibilityIdentifier("settings.clearHistory")
            AppNavigationLink {
                StorageSettingsView()
            } label: {
                describedRow("Temporary audio, artwork and saved data on this device.", id: "settings.storage") {
                    rowLabel("Storage", systemImage: "internaldrive")
                }
            }
            .accessibilityIdentifier("settings.storage")
            libraryRecoveryRows
        } header: {
            sectionHeader("Library & iCloud", id: "library")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var iCloudRow: some View {
        AppNavigationLink {
            ICloudSyncSettingsView()
        } label: {
            describedRow(model.cloudSync.statusText, id: "settings.icloud") {
                LabeledContent {
                    Text(model.cloudSync.isEnabled ? "On" : "Off")
                } label: {
                    ICloudSyncPreferenceLabel(title: "iCloud sync", isEnabled: model.cloudSync.isEnabled)
                        .labelStyle(SettingsRowLabelStyle())
                }
            }
        }
        .accessibilityLabel("iCloud sync")
        .accessibilityValue("\(model.cloudSync.isEnabled ? "On" : "Off"). Status: \(model.cloudSync.statusText)")
        .accessibilityHint("Shows iCloud availability, activity and sync controls.")
        .accessibilityIdentifier("settings.icloud")
    }

    @ViewBuilder
    private var libraryRecoveryRows: some View {
        if let error = model.library.errorMessage {
            describedRow(error, id: "settings.library.error") {
                rowLabel("Library storage", systemImage: "exclamationmark.triangle")
            }
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("settings.library.error")
            if model.library.requiresReload {
                LibraryReloadButton(identifier: "settings.library.reload")
                    .labelStyle(SettingsRowLabelStyle())
            }
        }
    }

    private var appearanceSection: some View {
        Section {
            menuPicker("Appearance", systemImage: "circle.lefthalf.filled", selection: preference(\.appearance),
                       value: model.library.preferences.appearance.title, id: "settings.appearance") {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            AppNavigationLink {
                AccentSettingsView()
            } label: {
                LabeledContent {
                    Text(model.library.preferences.accent.title)
                        .foregroundStyle(AppTheme.secondaryText)
                } label: {
                    Label {
                        Text("Accent color")
                    } icon: {
                        Circle()
                            .fill(model.library.preferences.accent.color)
                            .frame(width: 28, height: 28)
                    }
                    .labelStyle(SettingsRowLabelStyle())
                }
                .appFont(.body)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Accent color")
            .accessibilityValue(model.library.preferences.accent.title)
            .accessibilityIdentifier("settings.accent")
            // Mac (Designed for iPad) cannot change the Home Screen icon; the picker would only show an error.
            if icons.supportsAlternateIcons {
                AppNavigationLink {
                    AppIconPickerView()
                        .environment(icons)
                } label: {
                    LabeledContent {
                        Text(icons.current.title)
                            .foregroundStyle(AppTheme.secondaryText)
                    } label: {
                        Label {
                            Text("App icon")
                        } icon: {
                            Image(icons.current.previewImageName)
                                .resizable()
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6.3))
                        }
                        .labelStyle(SettingsRowLabelStyle())
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.appIcon")
            }
        } header: {
            sectionHeader("Appearance", id: "appearance")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var discoverySection: some View {
        Section {
            describedRow("Applies to new Home recommendations and future mixes. Existing mixes keep their songs.",
                         id: "settings.discoveryFamiliarity") {
                menuPicker("Discovery balance", systemImage: "slider.horizontal.3", selection: preference(\.discoveryFamiliarity),
                           value: model.library.preferences.discoveryFamiliarity.title, id: "settings.discoveryFamiliarity") {
                    ForEach(DiscoveryFamiliarity.allCases, id: \.self) { familiarity in
                        Text(familiarity.title).tag(familiarity)
                            .accessibilityIdentifier("settings.discoveryFamiliarity.choice.\(familiarity.rawValue)")
                    }
                }
            }
            AppNavigationLink {
                HomeCustomizationView()
            } label: {
                rowLabel("Customize Home", systemImage: "rectangle.3.group")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.customizeHome")
            AppNavigationLink {
                ListeningLanguagesView()
            } label: {
                describedRow("Your last 30 days, with optional recommendation adjustments.", id: "settings.languages") {
                    rowLabel("Listening languages", systemImage: "character.bubble")
                }
            }
            .accessibilityIdentifier("settings.languages")
            LabeledContent {
                Text(followingCount)
            } label: {
                rowLabel("Following", systemImage: "person.2")
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Following")
            .accessibilityValue(followingCount)
            .accessibilityIdentifier("settings.following")
            described("New release alerts", "Notifies you when an artist you follow releases something new. Checked when you open the app and occasionally in the background.", systemImage: "bell.badge",
                      isOn: preference(\.newReleaseAlerts), id: "settings.releaseAlerts")
        } header: {
            sectionHeader("Discovery", id: "discovery")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var accountSection: some View {
        Section {
            accountRows
            described("Encrypted DNS", "Keeps the music sites this app looks up private from the network you are on, such as public Wi-Fi. Uses your system’s encrypted DNS when available, with Cloudflare as a fallback. Turn off if a network blocks it.", systemImage: "lock.shield",
                      isOn: preference(\.useEncryptedDNS), id: "settings.encryptedDNS")
            described("Remote playback fallback", "Off by default. YouTubeKit’s service (remote-production.youtubekit.dev) can help resolve audio. It receives the recording ID and requested provider responses, including headers.", systemImage: "network",
                      isOn: preference(\.allowRemoteFallback), id: "settings.remoteFallback")
        } header: {
            sectionHeader("Account & connection", id: "account")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var aboutSection: some View {
        Section {
            AppNavigationLink {
                TipJarView(tips: model.tips)
            } label: {
                rowLabel("Support development", systemImage: "heart.circle")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.tipJar")
            if let support = URL(string: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md"),
               let privacy = URL(string: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md") {
                Link(destination: support) {
                    rowLabel("Help & feedback", systemImage: "questionmark.circle").frame(minHeight: 44)
                }
                .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                .accessibilityIdentifier("settings.support")
                Link(destination: privacy) {
                    rowLabel("Privacy policy", systemImage: "hand.raised").frame(minHeight: 44)
                }
                .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                .accessibilityIdentifier("settings.privacy")
            }
            providerLink("Catalog", systemImage: "music.note.list", provider: "YouTube Music", url: "https://music.youtube.com", id: "settings.provider.catalog")
            providerLink("On-device audio lookup", systemImage: "waveform", provider: "YouTubeKit", url: "https://github.com/alexeichhorn/YouTubeKit", id: "settings.provider.audio")
            providerLink("Lyrics", systemImage: "text.quote", provider: "LRCLIB", url: "https://lrclib.net", id: "settings.provider.lyrics")
            AppNavigationLink {
                AcknowledgementsView()
            } label: {
                rowLabel("Acknowledgements", systemImage: "doc.text").frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.acknowledgements")
            describedRow("Your library is saved on this device, syncs with iCloud when enabled and may be backed up. Music and artwork belong to their respective owners.",
                         id: "settings.version") {
                LabeledContent {
                    Text(version)
                } label: {
                    rowLabel("Version", systemImage: "info.circle")
                }
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version")
                .accessibilityValue(version)
                .accessibilityIdentifier("settings.version")
            }
        } header: {
            sectionHeader("About Breezy", id: "about")
        }
        .listRowBackground(AppTheme.surface)
        .listRowInsets(Self.rowInsets)
    }

    private var crossfadeRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.descriptionSpacing))
            : AnyLayout(HStackLayout(spacing: 14))
        return describedRow("Sets how many seconds songs overlap. At 0 s, only Automix can add a blend.", id: "settings.crossfade") {
            layout {
                rowLabel("Crossfade", systemImage: "arrow.triangle.merge")
                HStack(spacing: 14) {
                    Slider(value: crossfadeBinding, in: UserPreferences.crossfadeRange, step: 1) {
                        Text("Crossfade")
                    }
                    .accessibilityValue(crossfadeLabel)
                    .accessibilityIdentifier("settings.crossfade")
                    .frame(minWidth: 44, minHeight: 44)
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
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SettingsRowLabelStyle.textInset : 0)
            }
        }
    }

    private var crossfadeLabel: String {
        "\(Int(model.library.preferences.crossfadeSeconds.rounded())) s"
    }

    private var shuffleDescription: String {
        if !model.library.preferences.saveListeningHistory {
            return "Shuffle is random while Save listening history is off. Your choice is saved without changing the current queue."
        }
        return "Fewer repeats uses the last 7 days of saved plays to favor other songs on your next shuffle. Your current queue stays the same."
    }

    @ViewBuilder
    private var accountRows: some View {
        if model.account.isSignOutPending {
            VStack(alignment: .leading, spacing: Self.descriptionSpacing) {
                accountStatus("Sign-out pending")
                description("Your account isn't being used. Retry to finish signing out on this device.")
                accountError
            }
            .padding(.bottom, Self.descriptionBottomInset)
            Button(role: .destructive) {
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            } label: {
                rowLabel("Retry sign-out", systemImage: "arrow.clockwise")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.youtubeSignOutRetry")
        } else if let session = model.account.session {
            let expired = model.account.isExpired
            VStack(alignment: .leading, spacing: Self.descriptionSpacing) {
                accountStatus("Signed in")
                description(expired ? "Sign-in expired. Sign in again."
                            : "Signed in \(session.signedInAt.formatted(.relative(presentation: .named))). Google may limit an account that loads a lot of songs.")
                accountError
            }
            .padding(.bottom, Self.descriptionBottomInset)
            if expired {
                Button {
                    AppNavigationIntent.perform(in: model) { isSigningIn = true }
                } label: {
                    rowLabel("Sign in again", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeSignIn")
            }
            Button(role: .destructive) {
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            } label: {
                rowLabel("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settings.youtubeSignOut")
        } else {
            VStack(alignment: .leading, spacing: Self.descriptionSpacing) {
                // The form paints labels in primary text; the accent marks this row as an action, not a status.
                Button {
                    AppNavigationIntent.perform(in: model) { isSigningIn = true }
                } label: {
                    rowLabel("Sign in to YouTube", systemImage: "person.crop.circle.badge.plus")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeSignIn")
                description("Optional. May help when YouTube asks for sign-in. Google can refuse playback and associate requests with your account. Breezy does not send watch-history updates.")
                    .accessibilityIdentifier("settings.youtubeSignIn.description")
                if let checkedAt = model.account.lastBotCheckAt {
                    description("YouTube asked for this check \(checkedAt.formatted(.relative(presentation: .named))).")
                }
                accountError
            }
            .padding(.bottom, Self.descriptionBottomInset)
        }
    }

    private func accountStatus(_ status: String) -> some View {
        LabeledContent {
            Text(status)
        } label: {
            rowLabel("YouTube", systemImage: "person.crop.circle")
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("settings.youtubeStatus")
    }

    @ViewBuilder
    private var accountError: some View {
        if let error = model.account.errorMessage {
            Text(error)
                .appFont(.footnote)
                .foregroundStyle(AppTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, SettingsRowLabelStyle.textInset)
                .accessibilityIdentifier("settings.youtubeError")
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.library.preferences.appearance {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(SettingsRowLabelStyle())
    }

    private func described(_ title: String, _ text: String, systemImage: String, isOn: Binding<Bool>, id: String) -> some View {
        describedRow(text, id: id) {
            Toggle(isOn: isOn) {
                rowLabel(title, systemImage: systemImage)
            }
            .toggleStyle(CompactSwitchToggleStyle())
            .accessibilityLabel(title)
            .accessibilityIdentifier(id)
        }
    }

    private func menuPicker<Selection: Hashable, Choices: View>(_ title: String, systemImage: String,
                                                               selection: Binding<Selection>, value: String, id: String,
                                                               @ViewBuilder choices: () -> Choices) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Self.descriptionSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return Menu {
            Picker(title, selection: selection) { choices() }
        } label: {
            layout {
                rowLabel(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down")
                        .appFont(.caption)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SettingsRowLabelStyle.textInset : 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }

    private func describedRow<Content: View>(_ text: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Self.descriptionSpacing) {
            content()
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            description(text)
                .accessibilityIdentifier("\(id).description")
        }
        .padding(.bottom, Self.descriptionBottomInset)
    }

    private func sectionHeader(_ title: String, id: String) -> some View {
        Text(title)
            .appFont(.caption, weight: .semibold)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 24, alignment: .leading)
            .accessibilityIdentifier("settings.section.\(id)")
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .appFont(.footnote)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SettingsRowLabelStyle.textInset)
    }

    private var crossfadeBinding: Binding<TimeInterval> {
        Binding {
            model.library.preferences.crossfadeSeconds
        } set: { value in
            let range = UserPreferences.crossfadeRange
            let clamped = value.isFinite ? min(max(value.rounded(), range.lowerBound), range.upperBound) : 0
            model.updatePreferences { $0.crossfadeSeconds = clamped }
        }
    }

    private var followingCount: String {
        let count = model.library.followedArtists.count
        return count == 1 ? "1 artist" : "\(count.formatted()) artists"
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<UserPreferences, Value>) -> Binding<Value> {
        Binding {
            model.library.preferences[keyPath: keyPath]
        } set: { value in
            model.updatePreferences { $0[keyPath: keyPath] = value }
        }
    }

    @ViewBuilder
    private func providerLink(_ title: String, systemImage: String, provider: String, url: String, id: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                LabeledContent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(provider)
                            .foregroundStyle(AppTheme.secondaryText)
                        Image(systemName: "arrow.up.right")
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityHidden(true)
                    }
                } label: {
                    rowLabel(title, systemImage: systemImage)
                        .foregroundStyle(AppTheme.primaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
            }
            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
            .accessibilityLabel("\(title), \(provider), website")
            .accessibilityIdentifier(id)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let release = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        guard let build = info?["CFBundleVersion"] as? String else { return release }
        return "\(release) (\(build))"
    }
}

private struct SettingsRowLabelStyle: LabelStyle {
    private static let iconWidth: CGFloat = 28
    private static let spacing: CGFloat = 12
    static let textInset = iconWidth + spacing

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Self.spacing) {
            // Decorative glyphs keep a fixed column so large text retains the available row width.
            configuration.icon
                .font(.system(size: 20))
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
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
