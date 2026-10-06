import SwiftUI

@MainActor
struct ArtistSpotlightSongRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.secondaryTextColor) private var secondaryText
    let track: Track
    let tracks: [Track]
    let loader: ArtistSpotlightLoader
    @State private var isChoosingLanguage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackRow(track: track, tracks: tracks, showsDuration: true)
                .contextMenu {
                    Button("Song Language", systemImage: "globe") { chooseLanguage() }
                }
                .accessibilityAction(named: Text("Review Song Language")) { chooseLanguage() }
            if loader.isBrowsingLanguages {
                languageButton
            }
        }
        .sheet(isPresented: AppNavigationIntent.binding($isChoosingLanguage, in: model)) {
            NavigationStack { ArtistSpotlightLanguageSheet(track: track, loader: loader) }
                .appPresentationEnvironment(model)
                .appSheetChrome()
        }
    }

    private var languageButton: some View {
        Button { chooseLanguage() } label: {
            HStack(spacing: 6) {
                let result = loader.languageResult(for: track)
                Text(result?.title ?? "Unclassified").appFont(.caption, weight: .semibold)
                if let source = result?.source { Text("· \(source.title)").appFont(.caption).lineLimit(2) }
                Image(systemName: "pencil").font(.caption)
            }
            .foregroundStyle(secondaryText)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 65)
        .accessibilityLabel("Language for \(track.title), \(loader.languageResult(for: track)?.title ?? "Unclassified")")
        .accessibilityValue(loader.languageResult(for: track)?.source?.title ?? "")
        .accessibilityHint("Review the source or set the recording's language")
        .accessibilityIdentifier("artist.spotlight.correctLanguage.\(track.id)")
    }

    private func chooseLanguage() {
        AppNavigationIntent.perform(in: model) { isChoosingLanguage = true }
    }
}

@MainActor
private struct ArtistSpotlightLanguageSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let loader: ArtistSpotlightLoader

    var body: some View {
        Form {
            Section {
                Text(track.title).appFont(.headline)
                let result = loader.languageResult(for: track)
                Text(result?.title ?? "Unclassified").appFont(.body)
                Text(result?.explanation ?? "You can check more languages or set this recording's language yourself.")
                    .appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                if let source = result?.source {
                    Text(source.title).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                    if case .musicBrainzWork(let recordingID, let workID) = source,
                       let recordingURL = URL(string: "https://musicbrainz.org/recording/\(recordingID)"),
                       let workURL = URL(string: "https://musicbrainz.org/work/\(workID)") {
                        Link("Matched recording on MusicBrainz", destination: recordingURL).appFont(.body)
                            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                        Link("Lyrics language of the work", destination: workURL).appFont(.body)
                            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                    }
                    if source == .linkedLyrics, let url = track.shareURL {
                        Link("Recording on YouTube Music", destination: url).appFont(.body)
                            .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
            Section {
                ForEach(ArtistSongLanguage.allCases) { language in
                    Button { save(language.rawValue) } label: {
                        HStack {
                            Text(language.title).appFont(.body)
                            Spacer()
                            if model.library.recordingLanguageOverrides[track.id] == language.rawValue { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("artist.spotlight.setLanguage.\(language.rawValue)")
                }
                Button("Keep Unclassified") { save("und") }.appFont(.body)
                    .accessibilityIdentifier("artist.spotlight.setLanguage.und")
            } header: {
                Text("Set This Recording's Language").appFont(.footnote)
            } footer: {
                Text("Saved in your library. Your choice takes priority over automatic detection.").appFont(.footnote)
            }
            .listRowBackground(AppTheme.surface)
            if model.library.recordingLanguageOverrides[track.id] != nil {
                Button("Clear My Correction") { save(nil) }.appFont(.body)
                    .accessibilityIdentifier("artist.spotlight.clearLanguage")
                    .listRowBackground(AppTheme.surface)
            }
            if let error = model.library.errorMessage {
                Text(error).appFont(.caption).foregroundStyle(AppTheme.accent)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .tint(AppTheme.accent)
        .navigationTitle("Song Language")
        .navigationBarTitleDisplayMode(.inline)
        .appSheetDoneButton(id: "songLanguage.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
    }

    private func save(_ code: String?) {
        guard model.library.setRecordingLanguageOverride(code, for: track.id) else { return }
        AppNavigationIntent.perform(in: model) { dismiss() }
    }
}
