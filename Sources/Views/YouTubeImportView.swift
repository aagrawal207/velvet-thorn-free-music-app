import SwiftUI

/// Settings > Account & connection > Import from YouTube Music. Read-only, additive copy of the signed-in account's
/// library; the account itself is never changed.
@MainActor
struct YouTubeImportView: View {
    @Environment(MusicAppModel.self) private var model
    @State private var kinds = Set(YouTubeLibraryKind.allCases.filter(\.isOnByDefault))
    /// Playlists start selected; remembering exclusions keeps a list that loads later fully selected.
    @State private var excludedPlaylistIDs: Set<String> = []

    private var importer: YouTubeLibraryImporter { model.youTubeImport }

    var body: some View {
        Form {
            introSection
            if importer.hasSession {
                kindsSection
                if kinds.contains(.playlists) { playlistsSection }
                actionSection
                if !importer.progress.isEmpty { progressSection }
            } else {
                Section {
                    Text("Sign in to YouTube in Settings first.")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44, alignment: .leading)
                        .accessibilityIdentifier("import.noSession")
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .settingsFormChrome()
        .navigationTitle("Import from YouTube Music")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("import.content")
        .onAppear { if kinds.contains(.playlists) { importer.loadPlaylists() } }
        .onChange(of: kinds.contains(.playlists)) { _, wantsPlaylists in
            if wantsPlaylists { importer.loadPlaylists() }
        }
    }

    private var introSection: some View {
        Section {
            Text("Copies liked songs, playlists, followed artists and recent history from the signed-in YouTube Music account into this device's library. Nothing is changed on the account.")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import.intro")
            SettingsRowContent {
                Text("Last Import")
            } trailing: {
                SettingsRowValue(text: Self.lastImportText(importer.lastImportedAt))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("import.lastImport")
        } footer: {
            SettingsFooter(id: "import.footer.intro") {
                Text("Google can see these requests on your account. Imports only add: songs, playlists and follows you remove on YouTube stay here.")
                    .accessibilityIdentifier("import.warning")
            }
        }
        .listRowBackground(AppTheme.surface)
    }

    private var kindsSection: some View {
        Section {
            ForEach(YouTubeLibraryKind.allCases) { kind in
                Toggle(isOn: binding(for: kind)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.settingsTitle).appFont(.body, weight: .medium)
                        Text(kind.detail)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .disabled(importer.isRunning)
                .accessibilityLabel(kind.settingsTitle)
                .accessibilityIdentifier("import.kind.\(kind.rawValue)")
            }
        } header: {
            SettingsSectionHeader(title: "What to Import", id: "import.section.kinds")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var playlistsSection: some View {
        Section {
            if importer.isLoadingPlaylists, importer.remotePlaylists.isEmpty {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text("Loading playlists")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("import.playlists.loading")
            } else if let error = importer.playlistsError, importer.remotePlaylists.isEmpty {
                Text(error)
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.playlists.error")
                Button {
                    importer.loadPlaylists()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("import.playlists.retry")
            } else if importer.hasLoadedPlaylists, importer.remotePlaylists.isEmpty {
                Text("No playlists on the account.")
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("import.playlists.empty")
            } else {
                ForEach(Array(importer.remotePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    playlistRow(playlist, index: index)
                }
            }
        } header: {
            SettingsSectionHeader(title: "Playlists", id: "import.section.playlists")
        } footer: {
            if !importer.remotePlaylists.isEmpty {
                SettingsFooter(id: "import.footer.playlists") {
                    Text(selectionText)
                        .accessibilityIdentifier("import.playlists.selection")
                }
            }
        }
        .listRowBackground(AppTheme.surface)
    }

    private func playlistRow(_ playlist: MusicCollection, index: Int) -> some View {
        let selected = !excludedPlaylistIDs.contains(playlist.id)
        return Button {
            if selected { excludedPlaylistIDs.insert(playlist.id) } else { excludedPlaylistIDs.remove(playlist.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.title)
                        .foregroundStyle(AppTheme.primaryText)
                    if !playlist.subtitle.isEmpty {
                        Text(playlist.subtitle)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importer.isRunning)
        .accessibilityLabel(playlist.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("import.playlist.\(index)")
    }

    private var actionSection: some View {
        Section {
            if importer.isRunning {
                HStack(spacing: 12) {
                    ProgressView().accessibilityHidden(true)
                    Text("Importing")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("import.running")
                Button(role: .destructive) {
                    importer.cancel()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("import.cancel")
            } else {
                Button {
                    importer.start(YouTubeImportSelection(kinds: kinds, playlistIDs: selectedPlaylistIDs))
                } label: {
                    Label("Start Import", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(kinds.isEmpty || !importer.hasSession)
                .accessibilityIdentifier("import.start")
            }
            if importer.needsSignIn {
                Text("YouTube did not accept the saved sign-in. Sign in again in Settings, then retry.")
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.signInAgain")
            }
            if let error = importer.errorMessage {
                Text(error)
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.error")
            }
        }
        .listRowBackground(AppTheme.surface)
    }

    private var progressSection: some View {
        Section {
            ForEach(YouTubeLibraryKind.allCases.filter { importer.progress[$0] != nil }) { kind in
                let progress = importer.progress[kind] ?? YouTubeImportKindProgress()
                LabeledContent {
                    Text(Self.progressText(kind, progress))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(kind.settingsTitle)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("import.progress.\(kind.rawValue)")
            }
            if let summary = importer.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("import.summary")
            }
        } header: {
            SettingsSectionHeader(title: "Progress", id: "import.section.progress")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var selectedPlaylistIDs: Set<String> {
        Set(importer.remotePlaylists.map(\.id)).subtracting(excludedPlaylistIDs)
    }

    private var selectionText: String {
        "\(selectedPlaylistIDs.count) of \(importer.remotePlaylists.count) selected. Each playlist copies up to 1,000 songs."
    }

    private func binding(for kind: YouTubeLibraryKind) -> Binding<Bool> {
        Binding {
            kinds.contains(kind)
        } set: { enabled in
            if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
        }
    }

    static func lastImportText(_ date: Date?) -> String {
        guard let date else { return "Not imported" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func progressText(_ kind: YouTubeLibraryKind, _ progress: YouTubeImportKindProgress) -> String {
        let counts = countsText(kind, progress)
        switch progress.status {
        case .pending: return "Waiting"
        case .running: return counts.isEmpty ? "Reading" : counts
        case .done: return counts.isEmpty ? "Nothing new" : counts
        case .failed(let message): return counts.isEmpty ? message : "\(counts). \(message)"
        case .unauthorized: return "Sign in again"
        case .rateLimited: return "YouTube is busy. Try again later."
        case .cancelled: return counts.isEmpty ? "Cancelled" : "\(counts). Cancelled"
        }
    }

    private static func countsText(_ kind: YouTubeLibraryKind, _ progress: YouTubeImportKindProgress) -> String {
        guard progress.fetched > 0 || progress.applied > 0 || progress.updated > 0 else { return "" }
        let verb: String = switch kind {
        case .likes: "liked"
        case .playlists, .history: "added"
        case .subscriptions: "followed"
        }
        var parts = ["\(progress.fetched.formatted()) read", "\(progress.applied.formatted()) \(verb)"]
        if progress.updated > 0 { parts.append("\(progress.updated.formatted()) updated") }
        return parts.joined(separator: ", ")
    }
}
