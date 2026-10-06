import SwiftUI

/// Settings > Playback > Equalizer, and More controls from the player's equalizer sheet. Global edits go through
/// `model.updatePreferences`; drags are throttled to about ten writes a second and always write once on lift.
@MainActor
struct EqualizerView: View {
    enum Mode: String, CaseIterable { case simple, advanced }

    private static let writeInterval: Duration = .milliseconds(100)
    private static let sliderHeight: CGFloat = 150
    private static let columnWidth: CGFloat = 52

    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Settings passes the global preference; the player sheet passes the song's override when it has one.
    var target: EqualizerTarget = .global
    /// Device-local view choice; the curve itself is the same in both modes.
    @AppStorage("equalizer.mode") private var mode = Mode.simple
    /// The band under the finger, shown from the drag so the knob never waits for a throttled write.
    @State private var bandDrag: (band: Int, value: Double)?
    @State private var simpleDrag: (control: SimpleEqualizer.Control, value: Double)?
    @State private var preampDrag: Double?
    @State private var lastWrite = ContinuousClock.now
    @State private var trailingWrite: Task<Void, Never>?
    @State private var isNamingPreset = false
    @State private var presetName = ""

    private var settings: EqualizerSettings { model.equalizerSettings(for: target) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsRowLabel(title: "Equalizer", systemImage: "slider.vertical.3")
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .accessibilityLabel("Equalizer")
                .accessibilityIdentifier("equalizer.enabled")
                presetRow
                Text(settings.preset.describedTitle)
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("equalizer.preset.description")
            } footer: {
                footnote("Off keeps your curve for later. Presets and bands can be changed while a song plays. Gapless albums can pause briefly between songs while it is on.", id: "equalizer.footer.enabled")
            }
            .settingsSectionRows()

            Section {
                Picker("Mode", selection: $mode) {
                    Text("Simple").tag(Mode.simple).accessibilityIdentifier("equalizer.mode.simple")
                    Text("Advanced").tag(Mode.advanced).accessibilityIdentifier("equalizer.mode.advanced")
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("equalizer.mode")
                VStack(spacing: 4) {
                    EqualizerResponseCurve(gains: displayedGains)
                        .frame(height: 72)
                        .accessibilityHidden(true)
                    EqualizerCurveAxis()
                }
                .equalizerDelightLine(gains: settings.effectiveGains, isAdjusting: bandDrag != nil || simpleDrag != nil)
                .padding(.vertical, 8)
                if mode == .simple {
                    EqualizerSimpleSliders(values: displayedSimpleControls) { control, value, final in
                        changeSimple(control, to: value, final: final)
                    }
                } else {
                    bands
                        .padding(.bottom, 4)
                }
                EqualizerBandHints()
            } header: {
                header("Bands", id: "bands")
            } footer: {
                if mode == .simple {
                    footnote("Simple sliders reshape the whole curve. Advanced shows all ten bands.", id: "equalizer.footer.simple")
                }
            }
            .settingsSectionRows()

            Section {
                preampRow
                Button {
                    model.updateEqualizer(target) { $0.reset() }
                } label: {
                    SettingsRowLabel(title: "Reset", systemImage: "arrow.counterclockwise")
                        .settingsRowTarget()
                }
                .disabled(!canReset)
                .accessibilityIdentifier("equalizer.reset")
            } header: {
                header("Level", id: "level")
            } footer: {
                footnote("At 0 dB the preamp lowers boosted curves by their largest boost so they never clip. Any other value is applied as set.", id: "equalizer.footer.level")
            }
            .settingsSectionRows()

            Section {
                Button {
                    presetName = ""
                    isNamingPreset = true
                } label: {
                    SettingsRowLabel(title: "Save as Preset", systemImage: "square.and.arrow.down")
                        .settingsRowTarget()
                }
                .disabled(model.equalizerProfiles.presets.count >= EqualizerProfileStore.presetCapacity)
                .accessibilityIdentifier("equalizer.savePreset")
                ForEach(model.equalizerProfiles.presets) { saved in
                    Text(saved.name)
                        .appFont(.body)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.leading, SettingsRowMetrics.textInset)
                        .swipeActions {
                            Button("Delete", role: .destructive) { model.equalizerProfiles.deletePreset(named: saved.name) }
                        }
                        .accessibilityIdentifier("equalizer.saved.\(saved.name)")
                }
            } header: {
                header("Your Presets", id: "saved")
            } footer: {
                footnote("Up to 20 presets, kept on this device. Swipe a preset to delete it.", id: "equalizer.footer.saved")
            }
            .settingsSectionRows()

            Section {
                DisclosureGroup {
                    ForEach(EqualizerPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.settingsTitle).appFont(.subheadline, weight: .medium)
                            Text(preset.summaryDescription)
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("equalizer.guide.\(preset.rawValue)")
                    }
                } label: {
                    SettingsRowLabel(title: "What the Presets Do", systemImage: "questionmark.circle")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("equalizer.guide")
            }
            .settingsSectionRows()
        }
        .settingsFormChrome()
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.equalizer.content")
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

    // MARK: Rows

    private var presetRow: some View {
        EqualizerPresetMenuRow(target: target)
    }

    /// One row of ten columns where it fits (iPad, landscape); two rows of five on phones.
    private var bands: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { bandColumns(0..<10) }
            VStack(spacing: 12) {
                HStack(spacing: 0) { bandColumns(0..<5) }
                HStack(spacing: 0) { bandColumns(5..<10) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("equalizer.bands")
    }

    private func bandColumns(_ range: Range<Int>) -> some View {
        ForEach(Array(range), id: \.self) { band in
            VStack(spacing: 6) {
                Text(EqualizerSettings.formattedGain(displayedGains[band]).replacingOccurrences(of: " dB", with: ""))
                    .appFont(.caption2, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityHidden(true)
                EqualizerBandSlider(band: band, value: displayedGains[band], height: Self.sliderHeight,
                                    columnWidth: Self.columnWidth) { value, final in
                    changeBand(band, to: value, final: final)
                }
                VStack(spacing: 1) {
                    Text(EqualizerPreset.bandNames[band])
                        .appFont(.caption2, weight: .medium)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(EqualizerPreset.bandLabels[band])
                        .appFont(.caption2)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .accessibilityHidden(true)
            }
            .frame(minWidth: Self.columnWidth, idealWidth: Self.columnWidth, maxWidth: .infinity)
        }
    }

    private var preampRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            SettingsRowLabel(title: "Preamp", systemImage: "speaker.wave.2")
            HStack(spacing: 14) {
                Slider(value: preampBinding, in: EqualizerSettings.gainRange, step: 0.5) {
                    Text("Preamp")
                } onEditingChanged: { editing in
                    if !editing, let value = preampDrag {
                        preampDrag = nil
                        write(final: true) { $0.preamp = value }
                    }
                }
                .accessibilityValue(preampLabel)
                .accessibilityIdentifier("equalizer.preamp")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.interaction, Rectangle())
                .contentShape(.accessibility, Rectangle())
                Text(preampLabel)
                    .appFont(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize()
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? SettingsRowMetrics.textInset : 0)
        }
        .frame(minHeight: 44)
    }

    private func header(_ title: String, id: String) -> some View {
        SettingsSectionHeader(title: title, id: "equalizer.section.\(id)")
    }

    private func footnote(_ text: String, id: String) -> some View {
        SettingsFooter(id: id) { Text(text) }
    }

    // MARK: State

    private var displayedGains: [Double] {
        var gains = settings.effectiveGains
        if let bandDrag, gains.indices.contains(bandDrag.band) { gains[bandDrag.band] = bandDrag.value }
        return gains
    }

    private var displayedSimpleControls: [Double] {
        var controls = settings.simpleControls
        if let simpleDrag { controls[simpleDrag.control.rawValue] = simpleDrag.value }
        return controls
    }

    private var displayedPreamp: Double { preampDrag ?? settings.preamp }

    private var preampLabel: String {
        let preamp = displayedPreamp
        if preamp == 0, settings.resolvedPreamp != 0 {
            return "Auto " + EqualizerSettings.formattedGain(settings.resolvedPreamp)
        }
        return EqualizerSettings.formattedGain(preamp)
    }

    private var canReset: Bool {
        settings.preset != .flat || !settings.isFlat || settings.preamp != 0
    }

    private var enabledBinding: Binding<Bool> {
        Binding { settings.isEnabled } set: { enabled in
            model.updateEqualizer(target) { $0.isEnabled = enabled }
        }
    }

    private var preampBinding: Binding<Double> {
        Binding { displayedPreamp } set: { value in
            let clamped = EqualizerSettings.clampedGain((value * 2).rounded() / 2)
            preampDrag = clamped
            write(final: false) { $0.preamp = clamped }
        }
    }

    private func changeBand(_ band: Int, to value: Double, final: Bool) {
        bandDrag = final ? nil : (band, value)
        write(final: final) { $0.setGain(value, band: band) }
    }

    private func changeSimple(_ control: SimpleEqualizer.Control, to value: Double, final: Bool) {
        simpleDrag = final ? nil : (control, value)
        write(final: final) { $0.setSimple(control, to: value) }
    }

    private func savePreset() {
        switch model.equalizerProfiles.savePreset(named: presetName, from: settings) {
        case .saved, .replaced:
            let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
            model.showToast("Saved \(name)")
        case .full: model.showToast("You can keep up to 20 presets")
        case .invalidName: model.showToast("Choose a different name")
        }
    }

    /// Throttled during drags so library writes stay near ten a second; the final change always lands.
    private func write(final: Bool, _ change: @escaping (inout EqualizerSettings) -> Void) {
        let now = ContinuousClock.now
        trailingWrite?.cancel()
        trailingWrite = nil
        guard final || now - lastWrite >= Self.writeInterval else {
            // A lone adjustment without a lift (VoiceOver, automation) still lands once the interval passes.
            let target = target
            trailingWrite = Task { @MainActor in
                try? await Task.sleep(for: Self.writeInterval)
                guard !Task.isCancelled else { return }
                lastWrite = ContinuousClock.now
                model.updateEqualizer(target, change)
                bandDrag = nil
                simpleDrag = nil
            }
            return
        }
        lastWrite = now
        model.updateEqualizer(target, change)
    }
}

/// A 44-point-plus column with a vertical track; 0 dB sits in the middle and the fill grows toward the value.
private struct EqualizerBandSlider: View {
    let band: Int
    let value: Double
    let height: CGFloat
    let columnWidth: CGFloat
    let onChange: (Double, Bool) -> Void

    private let knobSize: CGFloat = 26
    private var range: ClosedRange<Double> { EqualizerSettings.gainRange }
    private var trackLength: CGFloat { height - knobSize }

    var body: some View {
        ZStack {
            Capsule()
                .fill(AppTheme.secondaryText.opacity(0.3))
                .frame(width: 4, height: trackLength)
            Rectangle()
                .fill(AppTheme.secondaryText.opacity(0.6))
                .frame(width: 14, height: 1)
            Capsule()
                .fill(AppTheme.accent)
                .frame(width: 4, height: max(0, abs(knobOffset)))
                .offset(y: knobOffset / 2)
            Circle()
                .fill(AppTheme.surface)
                .overlay(Circle().strokeBorder(AppTheme.accent, lineWidth: 2.5))
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .offset(y: knobOffset)
        }
        .frame(width: max(44, columnWidth), height: height)
        .contentShape(Rectangle())
        // The column wins over the form's scroll so a touch that starts on a band moves that band.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onChange(value(at: $0.location.y), false) }
                .onEnded { onChange(value(at: $0.location.y), true) }
        )
        .accessibilityElement()
        .accessibilityLabel(EqualizerPreset.bandAccessibilityTitle(band))
        .accessibilityValue(EqualizerSettings.formattedGain(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(range.upperBound, value + 1), true)
            case .decrement: onChange(max(range.lowerBound, value - 1), true)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("equalizer.band.\(band)")
    }

    /// Vertical offset of the knob from the column's center; negative is up (a boost).
    private var knobOffset: CGFloat {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(0.5 - fraction) * trackLength
    }

    private func value(at y: CGFloat) -> Double {
        let top = knobSize / 2
        let fraction = min(max(Double((height - top - y) / trackLength), 0), 1)
        let raw = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return EqualizerSettings.clampedGain((raw * 2).rounded() / 2)
    }
}

/// Band-only magnitude response from 20 Hz to 20 kHz on a log axis, drawn with the bank's own coefficients.
struct EqualizerResponseCurve: View {
    let gains: [Double]
    private static let limit: Double = 13

    var body: some View {
        Canvas { context, size in
            let zero = size.height / 2
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: zero))
            baseline.addLine(to: CGPoint(x: size.width, y: zero))
            context.stroke(baseline, with: .color(AppTheme.secondaryText.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let points = 96
            var curve = Path()
            for index in 0...points {
                let fraction = Double(index) / Double(points)
                let frequency = 20 * pow(1000, fraction)
                let db = min(max(BiquadBank.responseDb(gainsDb: gains, at: frequency), -Self.limit), Self.limit)
                let point = CGPoint(x: size.width * fraction, y: zero - CGFloat(db / Self.limit) * zero)
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var fill = curve
            fill.addLine(to: CGPoint(x: size.width, y: zero))
            fill.addLine(to: CGPoint(x: 0, y: zero))
            fill.closeSubpath()
            context.fill(fill, with: .color(AppTheme.accent.opacity(0.18)))
            context.stroke(curve, with: .color(AppTheme.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}

/// Built-in presets, then "Your presets" when any are saved. A saved preset shows its name while the curve matches.
@MainActor
struct EqualizerPresetMenuRow: View {
    @Environment(MusicAppModel.self) private var model
    let target: EqualizerTarget

    var body: some View {
        let settings = model.equalizerSettings(for: target)
        SettingsMenuRow(title: "Preset", systemImage: "waveform.path", selection: choice,
                        value: model.equalizerPresetChoice(for: settings).settingsTitle, id: "equalizer.preset") {
            ForEach(EqualizerPreset.allCases, id: \.self) { preset in
                Text(preset.settingsTitle).tag(EqualizerPresetChoice.builtIn(preset))
                    .accessibilityIdentifier("equalizer.preset.choice.\(preset.rawValue)")
            }
            if !model.equalizerProfiles.presets.isEmpty {
                Section("Your Presets") {
                    ForEach(Array(model.equalizerProfiles.presets.enumerated()), id: \.element.id) { index, saved in
                        Text(saved.name).tag(EqualizerPresetChoice.saved(saved.name))
                            .accessibilityIdentifier("equalizer.preset.saved.\(index)")
                    }
                }
            }
        }
    }

    private var choice: Binding<EqualizerPresetChoice> {
        Binding { model.equalizerPresetChoice(for: model.equalizerSettings(for: target)) } set: { choice in
            model.applyEqualizerChoice(choice, to: target)
        }
    }
}

extension EqualizerPreset {
    var settingsTitle: String {
        switch self {
        case .bassBoost: "Bass Boost"
        case .bassReducer: "Bass Reducer"
        case .trebleBoost: "Treble Boost"
        default: title
        }
    }
}

extension EqualizerPresetChoice {
    var settingsTitle: String {
        switch self {
        case .builtIn(let preset): preset.settingsTitle
        case .saved(let name): name
        }
    }
}

/// Bass, Mids and Treble as native sliders; the caller maps them onto the ten bands with `SimpleEqualizer`.
@MainActor
struct EqualizerSimpleSliders: View {
    let values: [Double]
    let onChange: (SimpleEqualizer.Control, Double, Bool) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SimpleEqualizer.Control.allCases, id: \.self) { control in
                row(control)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("equalizer.simple")
    }

    private func row(_ control: SimpleEqualizer.Control) -> some View {
        let value = values.indices.contains(control.rawValue) ? values[control.rawValue] : 0
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(control.title)
                .appFont(.body, weight: .medium)
                .frame(minWidth: 64, alignment: .leading)
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                Slider(value: Binding { value } set: { onChange(control, ($0 * 2).rounded() / 2, false) },
                       in: EqualizerSettings.gainRange) {
                    Text(control.title)
                } onEditingChanged: { editing in
                    if !editing { onChange(control, value, true) }
                }
                .accessibilityLabel(control.title)
                .accessibilityValue(EqualizerSettings.formattedGain(value))
                .accessibilityIdentifier(control.identifier)
                .frame(minHeight: 44)
                Text(EqualizerSettings.formattedGain(value))
                    .appFont(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(minWidth: 52, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Low, Mid and High under the response curve, placed at 20 Hz, about 630 Hz and 20 kHz on its log axis.
struct EqualizerCurveAxis: View {
    var body: some View {
        HStack {
            Text("Low")
            Spacer()
            Text("Mid")
            Spacer()
            Text("High")
        }
        .appFont(.caption2)
        .foregroundStyle(AppTheme.secondaryText)
        .accessibilityHidden(true)
        .accessibilityIdentifier("equalizer.curve.axis")
    }
}

/// One line per region so the band names mean something without audio vocabulary.
struct EqualizerBandHints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SimpleEqualizer.Control.allCases, id: \.self) { control in
                Text(control.hint)
            }
        }
        .appFont(.caption)
        .foregroundStyle(AppTheme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("equalizer.hints")
    }
}
