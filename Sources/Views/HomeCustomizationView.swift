import SwiftUI

@MainActor
struct HomeCustomizationView: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.library.preferences.homeLayout.orderedSections) { section in
                    Toggle(isOn: visibility(for: section)) {
                        VStack(alignment: .leading, spacing: SettingsRowMetrics.stackedSpacing) {
                            Text(section.settingsTitle)
                            Text(section.detail)
                                .appFont(.footnote)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .toggleStyle(CompactSwitchToggleStyle())
                    .accessibilityLabel(section.settingsTitle)
                    .accessibilityIdentifier("home.customization.show.\(section.rawValue)")
                }
                .onMove { offsets, destination in
                    model.updatePreferences { $0.homeLayout.move(from: offsets, to: destination) }
                }
            } footer: {
                SettingsFooter(id: "home.customization.footer.sections") {
                    Text("Choose your sections. Drag the handles to change their order. Hiding a section keeps your saved music and listening history.")
                }
            }
            .settingsSectionRows()

            Section {
                Button {
                    model.updatePreferences { $0.homeLayout.reset() }
                } label: {
                    SettingsRowLabel(title: "Reset to Default", systemImage: "arrow.counterclockwise")
                        .settingsRowTarget()
                }
                .disabled(model.library.preferences.homeLayout.isDefault)
                .accessibilityIdentifier("home.customization.reset")
            }
            .settingsSectionRows()
        }
        .environment(\.editMode, .constant(.active))
        .settingsFormChrome()
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
