import SwiftUI

/// The root list: a status summary and one row per page. Each page owns its rows, alerts and sheets.
@MainActor
struct SettingsView: View {
    @Environment(MusicAppModel.self) private var model
    @State private var query = ""

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            if isSearching {
                SettingsSearchResults(query: query)
            } else {
                summaryAndPages
            }
        }
        .settingsPageChrome("Settings", model: model)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onAppear { model.account.refreshDiagnostics() }
    }

    @ViewBuilder
    private var summaryAndPages: some View {
            Section {
                SettingsRowContent {
                    SettingsRowLabel(title: "YouTube", systemImage: "person.crop.circle")
                } trailing: {
                    SettingsRowValue(text: accountStatus)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("YouTube")
                .accessibilityValue(accountStatus)
                .accessibilityIdentifier("settings.summary.account")
            } footer: {
                SettingsFooter(id: "settings.summary") {
                    // Its own view observes sync status, so status changes never re-render this list.
                    SettingsCloudSyncStatusLine(id: "settings.summary.icloud", countsFixtureTransitions: false)
                }
            }
            .settingsSectionRows()

            Section {
                ForEach(SettingsPage.allCases) { page in
                    AppNavigationLink {
                        page.destination
                    } label: {
                        SettingsRowLabel(title: page.title, subtitle: page.summary, systemImage: page.systemImage)
                            .settingsRowTarget()
                    }
                    .accessibilityIdentifier("settings.page.\(page.rawValue)")
                }
            }
            .settingsSectionRows()
    }

    private var accountStatus: String {
        if model.account.isSignOutPending { return "Sign-out pending" }
        guard model.account.session != nil else { return "Not signed in" }
        return model.account.isExpired ? "Sign-in expired" : "Signed in"
    }
}
