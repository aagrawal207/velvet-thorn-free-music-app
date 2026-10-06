import SwiftUI

/// Settings > Discovery > Catalog sources. YouTube Music is not listed: it is the primary catalog and always searched.
@MainActor
struct CatalogSourcesSettingsView: View {
    @Environment(MusicAppModel.self) private var model

    /// Sources a listener can switch; a source listed here before its catalog ships stays disabled with "Coming later".
    private static let switchable: [MusicSource] = [.jioSaavn, .gaana]
    private static let available: Set<MusicSource> = [.jioSaavn, .gaana]

    var body: some View {
        Form {
            Section {
                ForEach(Self.switchable) { source in
                    let available = Self.available.contains(source)
                    Toggle(isOn: binding(for: source)) {
                        SettingsRowContent {
                            SettingsRowLabel(title: source.title, systemImage: "square.stack.3d.up")
                        } trailing: {
                            if !available {
                                SettingsRowValue(text: "Coming later")
                            }
                        }
                    }
                    .toggleStyle(CompactSwitchToggleStyle())
                    .disabled(!available)
                    .accessibilityLabel(source.title)
                    .accessibilityHint(available ? "" : "Coming later")
                    .accessibilityIdentifier("settings.sources.\(source.rawValue)")
                }
            } footer: {
                SettingsFooter(id: "settings.sources.footer") {
                    Text("Searches ask each enabled service. Results show where a song comes from. Songs you already saved stay playable.")
                    ForEach(Self.switchable.filter { Self.available.contains($0) }) { source in
                        Text("\(source.title): \(detail(for: source)).")
                    }
                }
            }
            .settingsSectionRows()
        }
        .settingsFormChrome()
        .navigationTitle("Catalog Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("settings.sources.content")
    }

    private func detail(for source: MusicSource) -> String {
        switch source {
        case .jioSaavn: "search, albums, artists and playlists, streams up to 320 kbps"
        case .gaana: "search, albums, artists and playlists, streams up to 128 kbps"
        case .youTubeMusic: source.title
        }
    }

    private func binding(for source: MusicSource) -> Binding<Bool> {
        Binding {
            Self.available.contains(source) && model.library.preferences.enabledCatalogSources.contains(source)
        } set: { enabled in
            model.updatePreferences { preferences in
                // Keep the register in `MusicSource` order so two devices agree on one canonical form after a sync.
                var sources = Set(preferences.enabledCatalogSources)
                if enabled { sources.insert(source) } else { sources.remove(source) }
                preferences.enabledCatalogSources = MusicSource.allCases.filter { sources.contains($0) }
            }
        }
    }
}
