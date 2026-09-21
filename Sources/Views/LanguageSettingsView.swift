import SwiftUI

/// Home discovery languages. One must stay on; the list grows as languages are added.
@MainActor
struct LanguageSettingsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Form {
            Section {
                ForEach(MusicLanguage.allCases) { language in
                    Toggle(isOn: binding(language)) {
                        HStack(spacing: 12) {
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(language == .hindi ? "अ" : "Aa")
                                    .appFont(.title2, weight: .semibold)
                                    .foregroundStyle(language == .hindi ? AppTheme.gold : AppTheme.violet)
                                    .frame(width: 30)
                                    .accessibilityHidden(true)
                            }
                            Text(language.title)
                                .appFont(.body)
                        }
                    }
                    .tint(language == .hindi ? AppTheme.gold : AppTheme.violet)
                    .disabled(model.library.preferences.languages == [language])
                    .accessibilityIdentifier("settings.language.\(language.rawValue)")
                }
            } footer: {
                Text("Used for Home and radio discovery. Search covers every language.")
                    .appFont(.footnote)
            }
            .listRowBackground(AppTheme.surface)
        }
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Discovery languages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ language: MusicLanguage) -> Binding<Bool> {
        Binding {
            model.library.preferences.languages.contains(language)
        } set: { selected in
            var languages = model.library.preferences.languages
            if selected {
                languages.insert(language)
            } else if languages.count > 1 {
                languages.remove(language)
            }
            model.updatePreferences { $0.languages = languages }
        }
    }
}
