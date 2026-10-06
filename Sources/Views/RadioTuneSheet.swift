import SwiftUI

struct RadioTuneSelection: Identifiable {
    let id: UUID
    let seed: RadioSeed
    let tuning: RadioTuning
}

@MainActor
struct RadioTuneSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: RadioTuneSelection
    @State private var draft: RadioTuning

    init(selection: RadioTuneSelection) {
        self.selection = selection
        _draft = State(initialValue: selection.tuning)
    }

    private var isCurrentSession: Bool {
        model.seedRadioSessionID == selection.id && model.activeRadioSeed?.id == selection.seed.id
            && !model.isStartingSeedRadio
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SettingsMenuRow(title: "Discovery", selection: $draft.familiarity,
                                    value: draft.familiarity.radioTitle, id: "radio.tune.familiarity") {
                        ForEach(DiscoveryFamiliarity.allCases) { familiarity in
                            Text(familiarity.radioTitle).tag(familiarity)
                                .accessibilityIdentifier("radio.tune.familiarity.\(familiarity.rawValue)")
                        }
                    }
                    SettingsMenuRow(title: "Language", selection: $draft.language,
                                    value: draft.language?.title ?? "Automatic", id: "radio.tune.language") {
                        Text("Automatic").tag(Optional<ArtistSongLanguage>.none)
                            .accessibilityIdentifier("radio.tune.language.automatic")
                        ForEach(ArtistSongLanguage.allCases) { language in
                            Text(language.title).tag(Optional(language))
                                .accessibilityIdentifier("radio.tune.language.\(language.rawValue)")
                        }
                    }
                } header: {
                    Text(selection.seed.radioTitle)
                        .textCase(nil)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choosing a language excludes songs whose language is unknown.")
                        Text("Applies to future radio additions. Songs already queued keep their place.")
                    }
                }
                .disabled(!isCurrentSession)

                if !isCurrentSession {
                    Text("This radio session has changed. Reopen Tune Radio for the current session.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("radio.tune.stale")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .navigationTitle("Tune Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                }
            }
            .appSheetDoneButton(id: "radio.tune.done") {
                if isCurrentSession { model.tuneRadio(draft) }
                AppNavigationIntent.perform(in: model) { dismiss() }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationCompactAdaptation(.sheet)
        .appSheetChrome()
        .accessibilityIdentifier("radio.tune.sheet")
    }

    private var cancelButton: some View {
        Button { AppNavigationIntent.perform(in: model) { dismiss() } } label: {
            Text("Cancel")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 70, minHeight: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("radio.tune.cancel")
    }
}
