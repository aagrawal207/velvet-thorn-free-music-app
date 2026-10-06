import Foundation

/// What an equalizer screen edits: the global preference or one song's override.
enum EqualizerTarget: Hashable {
    case global
    case song(String)
}

/// A preset menu entry: a built-in preset or one of the listener's saved presets.
enum EqualizerPresetChoice: Hashable {
    case builtIn(EqualizerPreset)
    case saved(String)
}

extension MusicAppModel {
    /// A song with an override edits that override; every other song edits the global preference.
    func equalizerTarget(for track: Track?) -> EqualizerTarget {
        guard let track, equalizerProfiles.hasOverride(for: track.id) else { return .global }
        return .song(track.id)
    }

    func equalizerSettings(for target: EqualizerTarget) -> EqualizerSettings {
        switch target {
        case .global: library.preferences.equalizer
        case .song(let id): equalizerProfiles.override(for: id) ?? library.preferences.equalizer
        }
    }

    /// Global edits go through `updatePreferences` so they sync; song edits stay on this device.
    func updateEqualizer(_ target: EqualizerTarget, _ change: (inout EqualizerSettings) -> Void) {
        switch target {
        case .global:
            updatePreferences { change(&$0.equalizer) }
        case .song(let id):
            var settings = equalizerSettings(for: target)
            change(&settings)
            equalizerProfiles.setOverride(settings, for: id)
            player.refreshEqualizer()
        }
    }

    /// On copies the current global settings for this song; off returns it to the global setting.
    func setSongEqualizer(_ enabled: Bool, for track: Track) {
        if enabled {
            guard !equalizerProfiles.hasOverride(for: track.id) else { return }
            equalizerProfiles.setOverride(library.preferences.equalizer, for: track.id)
        } else {
            equalizerProfiles.removeOverride(for: track.id)
        }
        player.refreshEqualizer()
    }

    func equalizerPresetChoice(for settings: EqualizerSettings) -> EqualizerPresetChoice {
        if settings.preset == .custom, let name = equalizerProfiles.presetName(matching: settings) { return .saved(name) }
        return .builtIn(settings.preset)
    }

    func equalizerPresetTitle(for settings: EqualizerSettings) -> String {
        switch equalizerPresetChoice(for: settings) {
        case .builtIn(let preset): preset.title
        case .saved(let name): name
        }
    }

    func applyEqualizerChoice(_ choice: EqualizerPresetChoice, to target: EqualizerTarget) {
        switch choice {
        case .builtIn(let preset):
            updateEqualizer(target) { $0.preset = preset }
        case .saved(let name):
            guard let saved = equalizerProfiles.preset(named: name) else { return }
            updateEqualizer(target) {
                $0.preset = .custom
                $0.gains = saved.gains
                $0.preamp = saved.preamp
            }
        }
    }

    /// More sheet row value: "This song" for an override, otherwise Off, the preset or saved name, or Custom.
    func equalizerSummary(for track: Track?) -> String {
        if let track, equalizerProfiles.hasOverride(for: track.id) { return "This song" }
        let settings = library.preferences.equalizer
        return settings.isEnabled ? equalizerPresetTitle(for: settings) : "Off"
    }
}
