import SwiftUI

/// Grid of every bundled icon; choosing one changes the home-screen icon through iOS.
@MainActor
struct AppIconPickerView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(AppIconController.self) private var icons

    private var selectedID: String {
        let saved = model.library.preferences.appIconID
        return saved.isEmpty ? icons.current.id : AppIcons.option(named: "AppIcon-\(saved)").id
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 22) {
                    ForEach(AppIcons.all) { option in
                        Button {
                            model.selectAppIcon(option)
                        } label: {
                            VStack(spacing: 8) {
                                Image(option.previewImageName)
                                    .resizable()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(option.id == selectedID ? AppTheme.accent : AppTheme.secondaryText.opacity(0.25),
                                                          lineWidth: option.id == selectedID ? 3 : 1)
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        if option.id == selectedID {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(AppTheme.onAccent, AppTheme.accent)
                                                .offset(x: 8, y: -8)
                                        }
                                    }
                                Text(option.title)
                                    .appFont(.footnote, weight: option.id == selectedID ? .semibold : .regular)
                                    .foregroundStyle(AppTheme.primaryText)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(option.id == selectedID ? .isSelected : [])
                        .accessibilityIdentifier("settings.icon.\(option.id)")
                    }
                }
                if icons.isApplying {
                    ProgressView("Changing app icon…")
                        .appFont(.footnote)
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("settings.icon.pending")
                }
                if let error = icons.errorMessage {
                    VStack(spacing: 4) {
                        Text(error)
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("settings.icon.error")
                        if let option = AppIcons.all.first(where: { $0.id == selectedID }) {
                            Button {
                                model.selectAppIcon(option)
                            } label: {
                                Text("Retry")
                                    .appFont(.body, weight: .semibold)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .tint(AppTheme.accent)
                            .accessibilityIdentifier("settings.icon.retry")
                        }
                    }
                }
            }
            .padding(20)
            .disabled(icons.isApplying || !icons.supportsAlternateIcons)
        }
        .background(AppTheme.background)
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}
