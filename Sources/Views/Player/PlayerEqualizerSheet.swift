import SwiftUI

/// The player's compact equalizer, pushed from More. With "Use for this song" on, every control edits this song's
/// device-local override; otherwise it edits the global equalizer that Settings shows.
@MainActor
struct PlayerEqualizerSheet: View {
    private static let writeInterval: Duration = .milliseconds(100)

    @Environment(MusicAppModel.self) private var model
    let track: Track
    let onMoreControls: () -> Void
    @State private var simpleDrag: (control: SimpleEqualizer.Control, value: Double)?
    @State private var lastWrite = ContinuousClock.now
    @State private var trailingWrite: Task<Void, Never>?
    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var target: EqualizerTarget { model.equalizerTarget(for: track) }
    private var settings: EqualizerSettings { model.equalizerSettings(for: target) }
    private var usesSongSettings: Bool { model.equalizerProfiles.hasOverride(for: track.id) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding { settings.isEnabled } set: { enabled in
                    model.updateEqualizer(target) { $0.isEnabled = enabled }
                }) {
                    SettingsRowLabel(title: "Equalizer", systemImage: "slider.vertical.3")
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .accessibilityLabel("Equalizer")
                .accessibilityIdentifier("equalizer.enabled")
                EqualizerPresetMenuRow(target: target)
                Text(settings.preset.describedTitle)
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("equalizer.preset.description")
            }
            .settingsSectionRows()

            Section {
                VStack(spacing: 4) {
                    EqualizerResponseCurve(gains: settings.effectiveGains)
                        .frame(height: 56)
                        .accessibilityHidden(true)
                    EqualizerCurveAxis()
                }
                .equalizerDelightLine(gains: settings.effectiveGains, isAdjusting: simpleDrag != nil)
                .padding(.vertical, 6)
                EqualizerSimpleSliders(values: displayedControls) { control, value, final in
                    changeSimple(control, to: value, final: final)
                }
                EqualizerBandHints()
            } header: {
                SettingsSectionHeader(title: "Sound", id: "equalizer.section.sound")
            }
            .settingsSectionRows()

            Section {
                Toggle(isOn: Binding { usesSongSettings } set: { model.setSongEqualizer($0, for: track) }) {
                    SettingsRowLabel(title: "Use for This Song", systemImage: "music.note")
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .accessibilityLabel("Use for This Song")
                .accessibilityIdentifier("equalizer.song.toggle")
                Button {
                    presetName = ""
                    isNamingPreset = true
                } label: {
                    SettingsRowLabel(title: "Save as Preset", systemImage: "square.and.arrow.down")
                        .settingsRowTarget()
                }
                .disabled(model.equalizerProfiles.presets.count >= EqualizerProfileStore.presetCapacity)
                .accessibilityIdentifier("equalizer.savePreset")
                Button(action: onMoreControls) {
                    HStack {
                        SettingsRowLabel(title: "More Controls", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .settingsRowTarget()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("equalizer.moreControls")
            } footer: {
                SettingsFooter(id: "equalizer.footer.song") {
                    Text(usesSongSettings
                         ? "This song plays with its own settings on this device. Other songs use your equalizer."
                         : "Turn on to keep these settings for this song only, on this device.")
                }
            }
            .settingsSectionRows()
        }
        .settingsFormChrome()
        .accessibilityIdentifier("player.equalizer.content")
        .alert("Save as Preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $presetName)
                .accessibilityIdentifier("equalizer.savePreset.name")
            Button("Cancel", role: .cancel) { }
            Button("Save") { savePreset() }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Saves the current curve and preamp.")
        }
    }

    private var displayedControls: [Double] {
        var controls = settings.simpleControls
        if let simpleDrag { controls[simpleDrag.control.rawValue] = simpleDrag.value }
        return controls
    }

    /// Throttled like the full page; a lone adjustment without a lift still lands after the interval.
    private func changeSimple(_ control: SimpleEqualizer.Control, to value: Double, final: Bool) {
        simpleDrag = final ? nil : (control, value)
        trailingWrite?.cancel()
        trailingWrite = nil
        let target = target
        let now = ContinuousClock.now
        guard final || now - lastWrite >= Self.writeInterval else {
            trailingWrite = Task { @MainActor in
                try? await Task.sleep(for: Self.writeInterval)
                guard !Task.isCancelled else { return }
                lastWrite = ContinuousClock.now
                model.updateEqualizer(target) { $0.setSimple(control, to: value) }
                simpleDrag = nil
            }
            return
        }
        lastWrite = now
        model.updateEqualizer(target) { $0.setSimple(control, to: value) }
    }

    private func savePreset() {
        switch model.equalizerProfiles.savePreset(named: presetName, from: settings) {
        case .saved, .replaced: model.showToast("Saved \(presetName.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .full: model.showToast("You can keep up to 20 presets")
        case .invalidName: model.showToast("Choose a different name")
        }
    }
}
