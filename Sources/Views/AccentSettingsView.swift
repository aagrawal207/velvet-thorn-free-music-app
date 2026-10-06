import SwiftUI

@MainActor
struct AccentSettingsView: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(AppAccent.allCases) { accent in
                    colorRow(accent)
                }
            } header: {
                SettingsSectionHeader(title: "Buttons and Highlights", id: "settings.accent.section")
            }
            .settingsSectionRows()
        }
        .settingsFormChrome()
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.accent.list")
    }

    private func colorRow(_ accent: AppAccent) -> some View {
        let selected = model.library.preferences.accent == accent
        return Button {
            model.updatePreferences { $0.accent = accent }
        } label: {
            SettingsRowContent {
                Label {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(accent.title)
                            .appFont(.body, weight: selected ? .semibold : .regular)
                        if accent == .coral {
                            Text("Default")
                                .appFont(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                } icon: {
                    Circle()
                        .fill(accent.color)
                        .frame(width: SettingsRowMetrics.iconSize, height: SettingsRowMetrics.iconSize)
                }
                .labelStyle(SettingsRowLabelStyle())
            } trailing: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .appFont(.title2, weight: .semibold)
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.accent.\(accent.rawValue)")
    }
}
