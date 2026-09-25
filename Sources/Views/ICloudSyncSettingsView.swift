import SwiftUI

@MainActor
struct ICloudSyncSettingsView: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.cloudSync.isEnabled },
                    set: { model.cloudSync.setEnabled($0) }
                )) {
                    HStack(spacing: 8) {
                        ICloudSyncPreferenceLabel(title: "Sync with iCloud", isEnabled: model.cloudSync.isEnabled)
                        Spacer(minLength: 0)
                        Text(model.cloudSync.isEnabled ? "On" : "Off")
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .frame(minHeight: 44)
                .accessibilityLabel("Sync with iCloud")
                .accessibilityHint("Allows this device to sync. Check Status for iCloud availability and activity.")
                .accessibilityIdentifier("settings.icloud.enabled")
            } footer: {
                Text("Keep your library and preferences together on devices using the same Apple Account. Requires iCloud Drive.")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)

            Section {
                HStack(spacing: 12) {
                    if model.cloudSync.isSyncing { ProgressView().accessibilityHidden(true) }
                    Text(model.cloudSync.statusText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.icloud.status")
                }
                if let error = model.cloudSync.errorMessage {
                    Text(error)
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("settings.icloud.error")
                }
                if let date = model.cloudSync.lastSyncDate {
                    LabeledContent("Last saved for sync", value: date.formatted(date: .abbreviated, time: .shortened))
                        .appFont(.subheadline)
                        .accessibilityIdentifier("settings.icloud.lastSaved")
                }
                if model.cloudSync.isEnabled {
                    Button {
                        Task { await model.cloudSync.syncNow() }
                    } label: {
                        Label(model.cloudSync.errorMessage == nil ? "Sync now" : "Retry sync", systemImage: "arrow.triangle.2.circlepath")
                            .frame(minHeight: 44)
                    }
                    .disabled(model.cloudSync.isSyncing)
                    .accessibilityIdentifier("settings.icloud.syncNow")
                }
            } header: {
                Text("Status").appFont(.caption)
            } footer: {
                Text("The green cloud means sync is on. Saving to iCloud Drive does not confirm upload or delivery to your other devices.")
                    .appFont(.caption)
                    .accessibilityIdentifier("settings.icloud.deliveryNote")
            }
            .listRowBackground(AppTheme.surface)

            Section {
                Text("Likes, playlists, follows, dislikes, history, recent searches, mixes, song details, language corrections and lyric timing.")
                Text("Playback preferences, appearance, accent, app icon, Home layout, listening-language adjustments and other settings.")
            } header: {
                Text("What syncs").appFont(.caption)
            } footer: {
                Text("Your current queue, downloaded audio, sign-in and tip records stay on this device. Turning sync off keeps your local library and the existing iCloud copy. Removing items or clearing history while sync is off will sync when you turn it back on.")
                    .appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)
        }
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("iCloud sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ICloudSyncPreferenceLabel: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        Label {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: isEnabled ? "icloud.fill" : "icloud.slash")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isEnabled ? Color.green : Color.gray)
                .accessibilityHidden(true)
        }
    }
}
