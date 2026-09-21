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
                Text("Buttons and highlights")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)
        }
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 52)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .navigationTitle("Accent color")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.accent.list")
    }

    private func colorRow(_ accent: AppAccent) -> some View {
        let selected = model.library.preferences.accent == accent
        return Button {
            model.updatePreferences { $0.accent = accent }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(accent.color)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(accent.title)
                    .appFont(.body, weight: selected ? .semibold : .regular)
                if accent == .coral {
                    Text("Default")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .appFont(.title2, weight: .semibold)
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accent.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.accent.\(accent.rawValue)")
    }
}
