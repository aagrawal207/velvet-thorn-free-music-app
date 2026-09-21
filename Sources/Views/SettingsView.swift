import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingClearHistory = false
    @State private var isSigningIn = false
    @State private var icons = AppIconController()

    var body: some View {
        Form {
            Section {
                crossfadeRow
                described("Gapless playback", "No silence between songs from the same album or mix.",
                          isOn: preference(\.gaplessPlayback), id: "settings.gapless")
                described("Automix", "Blends the end of one song into the start of the next in playlists and mixes, even when Crossfade is off.",
                          isOn: preference(\.automix), id: "settings.automix")
                described("Autoplay", "Keeps similar songs coming when your queue ends.",
                          isOn: preference(\.autoplay), id: "settings.autoplay")
                described("Normalize volume", "Turns louder songs down to a similar level. Quieter songs are not boosted.",
                          isOn: preference(\.normalizeVolume), id: "settings.normalize")
            } header: {
                Text("Playback")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                AppNavigationLink {
                    StorageSettingsView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Storage", systemImage: "internaldrive")
                        description("Temporary audio, artwork and saved data on this iPhone.")
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("settings.storage")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                accountRows
            } header: {
                Text("YouTube account")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                described("New release alerts", "Notifies you when an artist you follow releases something new. Checked when you open the app and occasionally in the background.",
                          isOn: preference(\.newReleaseAlerts), id: "settings.releaseAlerts")
                LabeledContent("Following", value: followingCount)
            } header: {
                Text("Following")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                AppNavigationLink {
                    HomeCustomizationView()
                } label: {
                    Label("Customize Home", systemImage: "rectangle.3.group")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.customizeHome")
                AppNavigationLink {
                    AppIconPickerView()
                        .environment(icons)
                } label: {
                    HStack(spacing: 12) {
                        Image(icons.current.previewImageName)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6.3))
                            .accessibilityHidden(true)
                        Text("App icon")
                        Spacer()
                        Text(icons.current.title)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.appIcon")
                AppNavigationLink {
                    AccentSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(model.library.preferences.accent.color)
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                        Text("Accent color")
                        Spacer(minLength: 8)
                        Text(model.library.preferences.accent.title)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .appFont(.body)
                    .frame(minHeight: 52)
                }
                .accessibilityLabel("Accent color")
                .accessibilityValue(model.library.preferences.accent.title)
                .accessibilityIdentifier("settings.accent")
                Picker("Appearance", selection: preference(\.appearance)) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings.appearance")
                AppNavigationLink {
                    LanguageSettingsView()
                } label: {
                    LabeledContent("Discovery languages", value: languagesSummary)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.languages")
            } header: {
                Text("Make it yours")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                described("Save listening history", model.library.preferences.saveListeningHistory
                          ? "Builds your recents, mixes and recap. Saved locally and may be included in device backups."
                          : "New listening won't appear in your history or recap. Existing history stays until you clear it.",
                          isOn: preference(\.saveListeningHistory), id: "settings.history")

                Button(role: .destructive) {
                    AppNavigationIntent.perform(in: model) { isConfirmingClearHistory = true }
                } label: {
                    Label("Clear listening history", systemImage: "trash")
                        .frame(minHeight: 44)
                }
                .disabled(model.library.events.isEmpty && model.library.recentlyPlayed.isEmpty)
                .accessibilityIdentifier("settings.clearHistory")
            } header: {
                Text("Listening history")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                described("Remote playback fallback", "Off by default. YouTubeKit’s service (remote-production.youtubekit.dev) can help resolve audio. It receives the recording ID and requested provider responses, including headers.",
                          isOn: preference(\.allowRemoteFallback), id: "settings.remoteFallback")
                described("Encrypted DNS", "Uses your system’s encrypted DNS when available, with Cloudflare as a fallback. Turn off if this network blocks it. Applies to new connections.",
                          isOn: preference(\.useEncryptedDNS), id: "settings.encryptedDNS")
            } header: {
                Text("Advanced")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            if let error = model.library.errorMessage {
                Section {
                    Label {
                        Text(error)
                            .appFont(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(AppTheme.accent)
                    if model.library.requiresReload {
                        LibraryReloadButton(identifier: "settings.library.reload")
                    }
                } header: {
                    Text("Library storage")
                        .appFont(.caption)
                }
                .listRowBackground(AppTheme.surface)
            }

            Section {
                AppNavigationLink {
                    TipJarView(tips: model.tips)
                } label: {
                    Label("Support development", systemImage: "heart.circle")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("settings.tipJar")
                if let support = URL(string: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md"),
                   let privacy = URL(string: "https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md") {
                    Link(destination: support) {
                        Label("Help & feedback", systemImage: "questionmark.circle").frame(minHeight: 44)
                    }
                    .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                    .accessibilityIdentifier("settings.support")
                    Link(destination: privacy) {
                        Label("Privacy policy", systemImage: "hand.raised").frame(minHeight: 44)
                    }
                    .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                    .accessibilityIdentifier("settings.privacy")
                }
                providerLink("Catalog", provider: "YouTube Music", url: "https://music.youtube.com")
                providerLink("On-device audio lookup", provider: "YouTubeKit", url: "https://github.com/alexeichhorn/YouTubeKit")
                providerLink("Lyrics", provider: "LRCLIB", url: "https://lrclib.net")
                AppNavigationLink {
                    AcknowledgementsView()
                } label: {
                    Text("Acknowledgements")
                }
                .accessibilityIdentifier("settings.acknowledgements")
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Version", value: version)
                        .foregroundStyle(AppTheme.secondaryText)
                    description("Your library and history are saved locally and may be backed up. Music and artwork belong to their respective owners.")
                }
            } header: {
                Text("About Breezy")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)
        }
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.account.refreshDiagnostics() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { AppNavigationIntent.perform(in: model) { dismiss() } }
                    .appFont(.body, weight: .semibold)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings.done")
            }
        }
        .sheet(isPresented: AppNavigationIntent.binding($isSigningIn, in: model)) {
            YouTubeSignInView()
                .preferredColorScheme(preferredColorScheme)
                .presentationDragIndicator(.visible)
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
            Text("This removes recently played songs and resets your personal listening mixes and recap. Your likes and playlists stay in your library.")
        }
    }

    private var crossfadeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                Text("Crossfade")
                Slider(value: crossfadeBinding, in: UserPreferences.crossfadeRange, step: 1) {
                    Text("Crossfade")
                }
                .accessibilityValue(crossfadeLabel)
                .accessibilityIdentifier("settings.crossfade")
                .frame(minHeight: 44)
                Text(crossfadeLabel)
                    .appFont(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(minWidth: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            description("Overlaps the end of one song with the start of the next.")
        }
        .padding(.vertical, 2)
    }

    private var crossfadeLabel: String {
        "\(Int(model.library.preferences.crossfadeSeconds.rounded())) s"
    }

    @ViewBuilder
    private var accountRows: some View {
        if model.account.isSignOutPending {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("YouTube", value: "Sign-out pending")
                    .accessibilityIdentifier("settings.youtubeStatus")
                description("Your account isn't being used. Retry to finish signing out on this iPhone.")
                accountError
            }
            .padding(.vertical, 2)
            Button("Retry sign-out", role: .destructive) {
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.youtubeSignOutRetry")
        } else if let session = model.account.session {
            let expired = model.account.isExpired
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("YouTube", value: "Signed in")
                    .accessibilityIdentifier("settings.youtubeStatus")
                description(expired ? "Sign-in expired. Sign in again."
                            : "Signed in \(session.signedInAt.formatted(.relative(presentation: .named))). Google may limit an account that loads a lot of songs.")
                accountError
            }
            .padding(.vertical, 2)
            if expired {
                Button("Sign in again") {
                    AppNavigationIntent.perform(in: model) { isSigningIn = true }
                }
                .frame(minHeight: 44)
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeSignIn")
            }
            Button("Sign out", role: .destructive) {
                if model.account.signOut() { model.showToast("Signed out of YouTube") }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("settings.youtubeSignOut")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // The form paints labels in primary text; the accent marks this row as an action, not a status.
                Button("Sign in to YouTube") {
                    AppNavigationIntent.perform(in: model) { isSigningIn = true }
                }
                .frame(minHeight: 44)
                .foregroundStyle(AppTheme.accent)
                .accessibilityIdentifier("settings.youtubeSignIn")
                description("Optional. May help when YouTube asks for sign-in. Google can refuse playback and associate requests with your account. Breezy does not send watch-history updates.")
                if let checkedAt = model.account.lastBotCheckAt {
                    description("YouTube asked for this check \(checkedAt.formatted(.relative(presentation: .named))).")
                }
                accountError
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var accountError: some View {
        if let error = model.account.errorMessage {
            Text(error)
                .appFont(.caption)
                .foregroundStyle(AppTheme.accent)
                .fixedSize(horizontal: false, vertical: true)
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

    private func described(_ title: String, _ text: String, isOn: Binding<Bool>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .frame(minHeight: 44)
                .accessibilityIdentifier(id)
            description(text)
        }
        .padding(.vertical, 2)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var languagesSummary: String {
        MusicLanguage.allCases.filter(model.library.preferences.languages.contains).map(\.title).joined(separator: ", ")
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
    private func providerLink(_ title: String, provider: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .foregroundStyle(AppTheme.primaryText)
                    Spacer(minLength: 4)
                    Text(provider)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.trailing)
                    Image(systemName: "arrow.up.right")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
            .accessibilityLabel("\(title), \(provider), website")
        }
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
