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
                .accessibilityLabel("Sync with iCloud")
                .accessibilityHint("Allows this device to sync. Check Status for iCloud availability and activity.")
                .accessibilityIdentifier("settings.icloud.enabled")
            } footer: {
                SettingsFooter(id: "settings.icloud.footer.preference") {
                    Text("Keeps your library and preferences together on devices using the same Apple Account. Requires iCloud Drive.")
                }
            }
            .settingsSectionRows()

            Section {
                let status = SettingsCloudSyncStatus(model.cloudSync)
                HStack(spacing: SettingsRowMetrics.iconSpacing) {
                    SettingsRowIcon(systemImage: status.symbolName)
                    Text(status.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.icloud.status")
                    Spacer(minLength: 0)
                    if status.isSyncing { ProgressView().accessibilityHidden(true) }
                }
                .frame(minHeight: SettingsRowMetrics.minHeight)
                if let error = model.cloudSync.errorMessage {
                    Text(error)
                        .appFont(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
                        .accessibilityIdentifier("settings.icloud.error")
                }
                if let date = model.cloudSync.lastSyncDate {
                    SettingsRowContent {
                        Text("Last Saved for Sync")
                    } trailing: {
                        SettingsRowValue(text: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.icloud.lastSaved")
                }
                if model.cloudSync.isEnabled {
                    Button {
                        Task { await model.cloudSync.syncNow() }
                    } label: {
                        SettingsRowLabel(title: model.cloudSync.errorMessage == nil ? "Sync Now" : "Retry Sync",
                                         systemImage: "arrow.triangle.2.circlepath")
                            .settingsRowTarget()
                    }
                    .disabled(model.cloudSync.isSyncing)
                    .accessibilityIdentifier("settings.icloud.syncNow")
                }
            } header: {
                SettingsSectionHeader(title: "Status", id: "settings.icloud.section.status")
            } footer: {
                SettingsFooter(id: "settings.icloud.footer.status") {
                    Text("The green cloud means sync is on. Saving to iCloud Drive does not confirm upload or delivery to your other devices.")
                        .accessibilityIdentifier("settings.icloud.deliveryNote")
                }
            }
            .settingsSectionRows()

            Section {
                SettingsRowLabel(title: "Likes, playlists, follows, dislikes, history, recent searches, mixes, song details, language corrections and lyric timing.",
                                 systemImage: "music.note.list")
                    .padding(.vertical, 10)
                    .frame(minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
                SettingsRowLabel(title: "Playback preferences, appearance, accent, app icon, Home layout, listening-language adjustments and other settings.",
                                 systemImage: "slider.horizontal.3")
                    .padding(.vertical, 10)
                    .frame(minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
            } header: {
                SettingsSectionHeader(title: "What Syncs", id: "settings.icloud.section.contents")
            } footer: {
                SettingsFooter(id: "settings.icloud.footer.contents") {
                    Text("Your current queue, downloaded audio, sign-in and tip records stay on this device. Turning sync off keeps your local library and the existing iCloud copy. Removing items or clearing history while sync is off will sync when you turn it back on.")
                }
            }
            .settingsSectionRows()
        }
        .settingsFormChrome()
        .navigationTitle("iCloud Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ICloudSyncPreferenceLabel: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        // Green means enabled; the footer status reports actual availability and activity.
        SettingsRowLabel(title: title, systemImage: isEnabled ? "icloud.fill" : "icloud.slash",
                         tint: isEnabled ? Color.green : Color.gray)
    }
}

// MARK: - Settings summary

/// What the Settings summary reads. `ICloudLibrarySync` supplies it; the DEBUG status fixture can stand in.
@MainActor
protocol CloudSyncStatusReporting: AnyObject {
    var isEnabled: Bool { get }
    var isSyncing: Bool { get }
    var statusText: String { get }
    var errorMessage: String? { get }
}

extension ICloudLibrarySync: CloudSyncStatusReporting {}

@MainActor
enum SettingsCloudSyncSource {
    static func current(for model: MusicAppModel) -> any CloudSyncStatusReporting {
        #if DEBUG
        if let fixture = DebugCloudSyncStatusFixture.shared { return fixture }
        #endif
        return model.cloudSync
    }
}

/// One projection of the sync state so the row and the footer status agree on glyph and wording.
struct SettingsCloudSyncStatus: Equatable, Sendable {
    /// A state must hold this long before the footer shows it, so Checking that turns into Reading never flashes.
    static let holdDuration: Duration = .milliseconds(700)
    /// Every status string fits two footnote lines up to the largest non-accessibility size on the smallest phone.
    static let reservedLines = 2

    var isEnabled: Bool
    var isSyncing: Bool
    var hasError: Bool
    var text: String

    init(isEnabled: Bool, isSyncing: Bool, hasError: Bool, text: String) {
        self.isEnabled = isEnabled
        self.isSyncing = isSyncing
        self.hasError = hasError
        self.text = text
    }

    @MainActor
    init(_ source: any CloudSyncStatusReporting) {
        self.init(isEnabled: source.isEnabled, isSyncing: source.isSyncing,
                  hasError: source.errorMessage != nil, text: source.statusText)
    }

    var symbolName: String {
        if !isEnabled { return "icloud.slash" }
        if isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if hasError { return "exclamationmark.icloud" }
        return "icloud"
    }

    /// Lines the slot reserves; accessibility sizes wrap freely because a fixed slot would truncate meaning.
    static func reservedLineCount(for size: DynamicTypeSize) -> Int? {
        size.isAccessibilitySize ? nil : reservedLines
    }
}

/// The iCloud row reads the enabled flag for its glyph and value; the footer slot owns the status text.
@MainActor
struct SettingsCloudSyncRow: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        let source = SettingsCloudSyncSource.current(for: model)
        let enabled = source.isEnabled
        AppNavigationLink {
            ICloudSyncSettingsView()
        } label: {
            SettingsRowContent {
                ICloudSyncPreferenceLabel(title: "iCloud Sync", isEnabled: enabled)
            } trailing: {
                SettingsRowValue(text: enabled ? "On" : "Off")
            }
        }
        .accessibilityLabel("iCloud Sync")
        .accessibilityValue("\(enabled ? "On" : "Off"). Status: \(source.statusText)")
        .accessibilityHint("Shows iCloud availability, activity and sync controls.")
        .accessibilityIdentifier("settings.icloud")
    }
}

/// Observes the sync state on its own so status changes re-render this slot and nothing else in the form.
/// The slot keeps a fixed two-line height and shows a state only after it has held for 700 ms.
@MainActor
struct SettingsCloudSyncStatusLine: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var displayed: SettingsCloudSyncStatus?
    private let id: String
    /// Only the Library page's slot feeds the flicker fixture's counter; the root summary would double it.
    private let countsFixtureTransitions: Bool
    /// A fixed glyph column keeps the text origin still while the symbol changes; it scales with the footnote.
    @ScaledMetric(relativeTo: .footnote) private var glyphWidth: CGFloat = 16

    init(id: String = "settings.icloud.summary", countsFixtureTransitions: Bool = true) {
        self.id = id
        self.countsFixtureTransitions = countsFixtureTransitions
    }

    var body: some View {
        let live = SettingsCloudSyncStatus(SettingsCloudSyncSource.current(for: model))
        let shown = displayed ?? live
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: shown.symbolName)
                .frame(width: glyphWidth)
                .accessibilityHidden(true)
            statusText(shown.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("iCloud status")
        .accessibilityValue(accessibilityValue(for: shown))
        .accessibilityIdentifier(id)
        .task(id: live) {
            guard displayed != nil else { displayed = live; return }
            guard displayed != live else { return }
            try? await Task.sleep(for: SettingsCloudSyncStatus.holdDuration)
            guard !Task.isCancelled else { return }
            displayed = live
            #if DEBUG
            if countsFixtureTransitions { DebugCloudSyncStatusFixture.shared?.displayedTransitions += 1 }
            #endif
        }
    }

    @ViewBuilder
    private func statusText(_ text: String) -> some View {
        if let lines = SettingsCloudSyncStatus.reservedLineCount(for: dynamicTypeSize) {
            Text(text).lineLimit(lines, reservesSpace: true)
        } else {
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accessibilityValue(for status: SettingsCloudSyncStatus) -> String {
        #if DEBUG
        if let fixture = DebugCloudSyncStatusFixture.shared {
            return "\(status.text) (changes \(fixture.displayedTransitions))"
        }
        #endif
        return status.text
    }
}
