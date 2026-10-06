import Foundation

enum EqualizerPreset: String, Codable, CaseIterable, Sendable {
    case flat, bassBoost, bassReducer, trebleBoost, vocal, rock, pop, jazz, electronic, acoustic, loudness, custom

    /// ISO octave band centers in Hz; every gains array has one value per band, in this order.
    static let bandFrequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    var title: String {
        switch self {
        case .flat: "Flat"
        case .bassBoost: "Bass boost"
        case .bassReducer: "Bass reducer"
        case .trebleBoost: "Treble boost"
        case .vocal: "Vocal"
        case .rock: "Rock"
        case .pop: "Pop"
        case .jazz: "Jazz"
        case .electronic: "Electronic"
        case .acoustic: "Acoustic"
        case .loudness: "Loudness"
        case .custom: "Custom"
        }
    }

    /// Band gains in dB. Custom owns no curve of its own; the listener's values live in EqualizerSettings.gains.
    var gains: [Double] {
        switch self {
        case .flat, .custom: Array(repeating: 0, count: Self.bandFrequencies.count)
        case .bassBoost: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]
        case .bassReducer: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
        case .vocal: [-2, -3, -3, 1, 4, 4, 3, 1, 0, -1]
        case .rock: [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]
        case .pop: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -1]
        case .jazz: [4, 3, 1, 2, -2, -2, 0, 1, 3, 4]
        case .electronic: [4, 4, 1, 0, -2, 2, 1, 1, 4, 5]
        case .acoustic: [5, 5, 4, 1, 2, 2, 3, 4, 3, 2]
        case .loudness: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]
        }
    }
}

struct EqualizerSettings: Codable, Equatable, Sendable {
    static let gainRange: ClosedRange<Double> = -12...12

    var isEnabled = false
    var preset: EqualizerPreset = .flat
    /// The listener's own curve, applied only while `preset` is `.custom`.
    var gains: [Double] = Array(repeating: 0, count: EqualizerPreset.bandFrequencies.count)
    var preamp: Double = 0

    var effectiveGains: [Double] { preset == .custom ? gains : preset.gains }

    private enum CodingKeys: String, CodingKey { case isEnabled, preset, gains, preamp }
}

extension EqualizerSettings {
    // Lives in an extension so the memberwise initializer stays available.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? values.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        preset = (try? values.decodeIfPresent(EqualizerPreset.self, forKey: .preset)) ?? .flat
        gains = Self.normalizedGains((try? values.decodeIfPresent([Double].self, forKey: .gains)) ?? [])
        preamp = Self.clampedGain((try? values.decodeIfPresent(Double.self, forKey: .preamp)) ?? 0)
    }

    static func clampedGain(_ gain: Double) -> Double {
        guard gain.isFinite else { return 0 }
        return min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }

    /// One clamped value per band: extra values are dropped and missing bands read as 0 dB.
    static func normalizedGains(_ gains: [Double]) -> [Double] {
        (0..<EqualizerPreset.bandFrequencies.count).map { $0 < gains.count ? clampedGain(gains[$0]) : 0 }
    }
}

extension EqualizerPreset {
    /// Slider captions in `bandFrequencies` order; short enough for a 44-point column.
    static let bandLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    /// Spoken band name, such as "31 Hz" or "2 kHz".
    static func bandTitle(_ index: Int) -> String {
        guard bandFrequencies.indices.contains(index) else { return "" }
        let hertz = bandFrequencies[index]
        return hertz >= 1000 ? "\(Int(hertz / 1000)) kHz" : "\(Int(hertz.rounded())) Hz"
    }
}

extension EqualizerSettings {
    /// A manual preamp is applied as set. At 0 the largest boost is offset instead, so boosted curves keep the
    /// headroom of the flat signal; cuts need no offset.
    var resolvedPreamp: Double {
        if preamp != 0 { return preamp }
        return -max(0, effectiveGains.max() ?? 0)
    }

    var isFlat: Bool { effectiveGains.allSatisfy { $0 == 0 } }

    /// Settings row value: Off, a preset title, or Custom.
    var summary: String { isEnabled ? preset.title : "Off" }

    /// Editing a band leaves the named preset: its curve is copied first so the other bands keep their sound.
    mutating func setGain(_ gain: Double, band: Int) {
        guard EqualizerPreset.bandFrequencies.indices.contains(band) else { return }
        if preset != .custom {
            gains = preset.gains
            preset = .custom
        }
        gains[band] = Self.clampedGain(gain)
    }

    /// Flat curve and no preamp; the on/off choice is kept.
    mutating func reset() {
        preset = .flat
        gains = Array(repeating: 0, count: EqualizerPreset.bandFrequencies.count)
        preamp = 0
    }

    /// "+3 dB", "-2.5 dB" or "0 dB" for slider values and accessibility.
    static func formattedGain(_ gain: Double) -> String {
        let rounded = (gain * 2).rounded() / 2
        if rounded == 0 { return "0 dB" }
        let magnitude = rounded == rounded.rounded() ? String(Int(abs(rounded))) : String(format: "%.1f", abs(rounded))
        return (rounded > 0 ? "+" : "-") + magnitude + " dB"
    }
}

// MARK: Plain-language names (R14)

extension EqualizerPreset {
    /// Listener-facing band names in `bandFrequencies` order.
    static let bandNames = ["Sub-bass", "Bass", "Bass", "Low mids", "Mids", "Mids", "Upper mids", "Presence", "Treble", "Air"]

    /// Spoken band name with its frequency, such as "Sub-bass, 31 Hz".
    static func bandAccessibilityTitle(_ index: Int) -> String {
        guard bandNames.indices.contains(index) else { return "" }
        return "\(bandNames[index]), \(bandTitle(index))"
    }

    /// One plain sentence per preset, shown under the preset row and in the preset guide.
    var summaryDescription: String {
        switch self {
        case .flat: "No change to the sound"
        case .bassBoost: "More thump for hip hop and EDM"
        case .bassReducer: "Less boom on small speakers"
        case .trebleBoost: "Brighter, crisper highs"
        case .vocal: "Brings voices forward"
        case .rock: "Punchy drums and bright guitars"
        case .pop: "Clear vocals with a lift in the mids"
        case .jazz: "Warm lows and airy cymbals"
        case .electronic: "Deep bass and sparkling highs"
        case .acoustic: "Natural warmth for guitars and piano"
        case .loudness: "Fuller lows and highs at low volume"
        case .custom: "Your own curve"
        }
    }

    /// "Bass boost: more thump for hip hop and EDM".
    var describedTitle: String {
        let text = summaryDescription
        return "\(title): \(text.prefix(1).lowercased())\(text.dropFirst())"
    }
}

/// Simple mode: three controls spread over the ten bands. Each band's weights sum to 1, so equal Bass, Mids and
/// Treble values give a flat shift of that size; neighbours at 125 Hz, 250 Hz, 500 Hz, 2 kHz and 4 kHz overlap.
enum SimpleEqualizer {
    enum Control: Int, CaseIterable, Sendable {
        case bass, mids, treble

        var title: String {
            switch self {
            case .bass: "Bass"
            case .mids: "Mids"
            case .treble: "Treble"
            }
        }

        var hint: String {
            switch self {
            case .bass: "Bass: thump and warmth"
            case .mids: "Mids: vocals and guitars"
            case .treble: "Treble: clarity and cymbals"
            }
        }

        var identifier: String { "equalizer.simple.\(String(describing: self))" }
    }

    /// Rows are bands 31 Hz to 16 kHz; columns are Bass, Mids, Treble.
    static let weights: [[Double]] = [
        [1, 0, 0],       // 31 Hz
        [1, 0, 0],       // 62 Hz
        [0.9, 0.1, 0],   // 125 Hz
        [0.5, 0.5, 0],   // 250 Hz
        [0.1, 0.9, 0],   // 500 Hz
        [0, 1, 0],       // 1 kHz
        [0, 0.5, 0.5],   // 2 kHz
        [0, 0.1, 0.9],   // 4 kHz
        [0, 0, 1],       // 8 kHz
        [0, 0, 1],       // 16 kHz
    ]

    /// Ten clamped band gains, rounded to the 0.5 dB slider step.
    static func gains(bass: Double, mids: Double, treble: Double) -> [Double] {
        let controls = [bass, mids, treble].map(EqualizerSettings.clampedGain)
        return weights.map { row in
            let value = zip(row, controls).reduce(0) { $0 + $1.0 * $1.1 }
            return EqualizerSettings.clampedGain((value * 2).rounded() / 2)
        }
    }

    /// Least-squares Bass, Mids and Treble for any ten-band curve; exact for curves made by `gains`, up to rounding.
    static func controls(for gains: [Double]) -> [Double] {
        let bands = EqualizerSettings.normalizedGains(gains)
        var normal = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        var rhs = Array(repeating: 0.0, count: 3)
        for (row, gain) in zip(weights, bands) {
            for i in 0..<3 {
                rhs[i] += row[i] * gain
                for j in 0..<3 { normal[i][j] += row[i] * row[j] }
            }
        }
        let determinant = det(normal)
        guard abs(determinant) > 1e-9 else { return [0, 0, 0] }
        return (0..<3).map { column in
            var replaced = normal
            for row in 0..<3 { replaced[row][column] = rhs[row] }
            let value = det(replaced) / determinant
            return EqualizerSettings.clampedGain((value * 2).rounded() / 2)
        }
    }

    private static func det(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
}

extension EqualizerSettings {
    /// Bass, Mids and Treble read from the effective curve.
    var simpleControls: [Double] { SimpleEqualizer.controls(for: effectiveGains) }

    /// Moving one Simple control rebuilds the whole curve from the three values, so the preset becomes Custom.
    mutating func setSimple(_ control: SimpleEqualizer.Control, to value: Double) {
        var controls = simpleControls
        controls[control.rawValue] = Self.clampedGain(value)
        gains = SimpleEqualizer.gains(bass: controls[0], mids: controls[1], treble: controls[2])
        preset = .custom
    }
}
