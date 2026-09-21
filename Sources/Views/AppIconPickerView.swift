import SwiftUI

/// Grid of every bundled icon; choosing one changes the home-screen icon through iOS.
@MainActor
struct AppIconPickerView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(AppIconController.self) private var icons
    @State private var pending: AppIconOption?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 22) {
                ForEach(AppIcons.all) { option in
                    Button {
                        select(option)
                    } label: {
                        VStack(spacing: 8) {
                            Image(option.previewImageName)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(option == icons.current ? AppTheme.accent : AppTheme.secondaryText.opacity(0.25),
                                                      lineWidth: option == icons.current ? 3 : 1)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if option == icons.current {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(AppTheme.onAccent, AppTheme.accent)
                                            .offset(x: 8, y: -8)
                                    }
                                }
                            Text(option.title)
                                .appFont(.footnote, weight: option == icons.current ? .semibold : .regular)
                                .foregroundStyle(AppTheme.primaryText)
                        }
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pending != nil)
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(option == icons.current ? .isSelected : [])
                    .accessibilityIdentifier("settings.icon.\(option.id)")
                }
            }
            .padding(20)
        }
        .background(AppTheme.background)
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ option: AppIconOption) {
        guard pending == nil, option != icons.current else { return }
        pending = option
        Task {
            defer { pending = nil }
            do { try await icons.select(option) }
            catch { model.showToast(error.localizedDescription) }
        }
    }
}
