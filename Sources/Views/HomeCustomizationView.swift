import SwiftUI

@MainActor
struct HomeCustomizationView: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        List {
            Section {
                Text("Choose your sections. Drag the handles to change their order.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                ForEach(model.library.preferences.homeLayout.orderedSections) { section in
                    Toggle(isOn: visibility(for: section)) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title).appFont(.body, weight: .medium)
                            Text(section.detail)
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 52, alignment: .leading)
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityIdentifier("home.customization.show.\(section.rawValue)")
                }
                .onMove { offsets, destination in
                    model.updatePreferences { $0.homeLayout.move(from: offsets, to: destination) }
                }
            }
            .listRowBackground(AppTheme.surface)

            Section {
                Button {
                    model.updatePreferences { $0.homeLayout.reset() }
                } label: {
                    Label("Reset to default", systemImage: "arrow.counterclockwise")
                        .appFont(.body)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(model.library.preferences.homeLayout.isDefault)
                .accessibilityIdentifier("home.customization.reset")
                Text("Hiding a section keeps your saved music and listening history.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .listRowBackground(AppTheme.surface)
        }
        .environment(\.editMode, .constant(.active))
        .tint(AppTheme.accent)
        .foregroundStyle(AppTheme.primaryText)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Customize Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("home.customization")
    }

    private func visibility(for section: HomeSectionKind) -> Binding<Bool> {
        Binding {
            model.library.preferences.homeLayout.isVisible(section)
        } set: { visible in
            model.updatePreferences { $0.homeLayout.setVisible(visible, for: section) }
        }
    }
}
