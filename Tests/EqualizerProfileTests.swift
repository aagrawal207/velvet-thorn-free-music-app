import XCTest
@testable import GanaBajana

@MainActor
final class EqualizerProfileTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    // MARK: - Simple mode matrix

    func testSimpleWeightsCoverEveryBandAndSumToOne() {
        XCTAssertEqual(SimpleEqualizer.weights.count, EqualizerPreset.bandFrequencies.count)
        for (band, row) in SimpleEqualizer.weights.enumerated() {
            XCTAssertEqual(row.count, 3, "band \(band)")
            XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-12, "band \(band) keeps equal controls flat")
            XCTAssertTrue(row.allSatisfy { $0 >= 0 }, "band \(band)")
        }
        XCTAssertEqual(SimpleEqualizer.gains(bass: 4, mids: 4, treble: 4), Array(repeating: 4, count: 10))
    }

    func testSimpleControlsMapToTheirRegionsWithGentleOverlap() {
        XCTAssertEqual(SimpleEqualizer.gains(bass: 6, mids: 0, treble: 0), [6, 6, 5.5, 3, 0.5, 0, 0, 0, 0, 0])
        XCTAssertEqual(SimpleEqualizer.gains(bass: 0, mids: 6, treble: 0), [0, 0, 0.5, 3, 5.5, 6, 3, 0.5, 0, 0])
        XCTAssertEqual(SimpleEqualizer.gains(bass: 0, mids: 0, treble: -6), [0, 0, 0, 0, 0, 0, -3, -5.5, -6, -6])
        XCTAssertEqual(SimpleEqualizer.gains(bass: 30, mids: -30, treble: 0).max(), 12, "Controls clamp to the band range")
        XCTAssertEqual(SimpleEqualizer.gains(bass: 30, mids: -30, treble: 0).min(), -12)
    }

    func testSimpleControlsRoundTripThroughTheBands() {
        for (bass, mids, treble) in [(0.0, 0.0, 0.0), (6, 0, 0), (-4, 2, 5), (3.5, -2.5, 1), (12, -12, 12)] {
            let gains = SimpleEqualizer.gains(bass: bass, mids: mids, treble: treble)
            XCTAssertEqual(SimpleEqualizer.controls(for: gains), [bass, mids, treble], "\(bass) \(mids) \(treble)")
        }
        // A detailed curve projects onto the nearest three-control shape.
        let bassBoost = SimpleEqualizer.controls(for: EqualizerPreset.bassBoost.gains)
        XCTAssertGreaterThan(bassBoost[0], 3)
        XCTAssertEqual(bassBoost[2], 0)
    }

    func testMovingASimpleControlKeepsTheOtherTwoAndSwitchesToCustom() {
        var settings = EqualizerSettings(isEnabled: true)
        settings.setSimple(.treble, to: 4)
        settings.setSimple(.bass, to: -3)
        XCTAssertEqual(settings.preset, .custom)
        XCTAssertEqual(settings.simpleControls, [-3, 0, 4])
        XCTAssertEqual(settings.gains, SimpleEqualizer.gains(bass: -3, mids: 0, treble: 4))
        settings.setSimple(.mids, to: 2.5)
        XCTAssertEqual(settings.simpleControls, [-3, 2.5, 4])
    }

    func testBandNamesAndPresetDescriptionsArePlain() {
        XCTAssertEqual(EqualizerPreset.bandNames.count, 10)
        XCTAssertEqual(EqualizerPreset.bandAccessibilityTitle(0), "Sub-bass, 31 Hz")
        XCTAssertEqual(EqualizerPreset.bandAccessibilityTitle(7), "Presence, 4 kHz")
        XCTAssertEqual(EqualizerPreset.bandAccessibilityTitle(9), "Air, 16 kHz")
        XCTAssertEqual(EqualizerPreset.bassBoost.describedTitle, "Bass boost: more thump for hip hop and EDM")
        for preset in EqualizerPreset.allCases {
            XCTAssertFalse(preset.summaryDescription.isEmpty)
            XCTAssertFalse(preset.summaryDescription.contains("\u{2014}"), "No em dashes in copy")
        }
    }

    // MARK: - Profile store

    func testStoreKeepsAtMostOneThousandSongsDroppingTheLeastRecentlyUsed() {
        var clock = Date(timeIntervalSince1970: 1_000)
        let store = EqualizerProfileStore(url: nil, now: { clock })
        let settings = EqualizerSettings(isEnabled: true, preset: .rock)
        for index in 0..<EqualizerProfileStore.songCapacity {
            clock += 1
            store.setOverride(settings, for: "song-\(index)")
        }
        clock += 1
        store.markUsed("song-0")
        clock += 1
        store.setOverride(settings, for: "song-new")
        XCTAssertEqual(store.songOverrideCount, 1_000)
        XCTAssertTrue(store.hasOverride(for: "song-0"), "A recently played override survives")
        XCTAssertFalse(store.hasOverride(for: "song-1"), "The least recently used override is dropped")
        XCTAssertTrue(store.hasOverride(for: "song-new"))
        store.removeOverride(for: "song-new")
        XCTAssertNil(store.override(for: "song-new"))
        store.setOverride(settings, for: "")
        XCTAssertFalse(store.hasOverride(for: ""))
    }

    func testStoreKeepsTwentyNamedPresetsAndRejectsBuiltInNames() {
        let store = EqualizerProfileStore(url: nil)
        var custom = EqualizerSettings(isEnabled: true)
        custom.setGain(3, band: 4)
        for index in 0..<EqualizerProfileStore.presetCapacity {
            XCTAssertEqual(store.savePreset(named: "Mine \(index)", from: custom), .saved)
        }
        XCTAssertEqual(store.savePreset(named: "One too many", from: custom), .full)
        XCTAssertEqual(store.savePreset(named: "  mine 3 ", from: EqualizerSettings(preset: .jazz)), .replaced)
        XCTAssertEqual(store.preset(named: "mine 3")?.gains, EqualizerPreset.jazz.gains, "Saving a preset stores its effective curve")
        XCTAssertEqual(store.savePreset(named: "Bass Boost", from: custom), .invalidName)
        XCTAssertEqual(store.savePreset(named: "   ", from: custom), .invalidName)
        XCTAssertEqual(store.presets.count, 20)
        XCTAssertEqual(store.presetName(matching: custom), "Mine 0")
        store.deletePreset(named: "Mine 0")
        XCTAssertEqual(store.presets.count, 19)
        XCTAssertEqual(store.savePreset(named: String(repeating: "x", count: 60), from: custom), .saved)
        XCTAssertEqual(store.presets.last?.name.count, EqualizerProfileStore.nameLimit)
    }

    func testStorePersistsAtomicallyAndIgnoresUnreadableFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-EQProfiles-\(UUID())", isDirectory: true)
        directories.append(directory)
        let url = directory.appendingPathComponent(EqualizerProfileStore.fileName)
        let override = EqualizerSettings(isEnabled: true, preset: .vocal, preamp: -2)
        do {
            let store = EqualizerProfileStore(url: url)
            store.setOverride(override, for: "abcdefghijk")
            XCTAssertEqual(store.savePreset(named: "Night", from: EqualizerSettings(preset: .loudness)), .saved)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reopened = EqualizerProfileStore(url: url)
        XCTAssertEqual(reopened.override(for: "abcdefghijk"), override)
        XCTAssertEqual(reopened.presets.map(\.name), ["Night"])
        XCTAssertEqual(reopened.presets.first?.gains, EqualizerPreset.loudness.gains)

        try Data("not json".utf8).write(to: url)
        let damaged = EqualizerProfileStore(url: url)
        XCTAssertEqual(damaged.songOverrideCount, 0)
        XCTAssertTrue(damaged.presets.isEmpty)
    }

    func testDefaultLocationIsApplicationSupport() throws {
        let url = try XCTUnwrap(EqualizerProfileStore.defaultURL())
        XCTAssertEqual(url.lastPathComponent, "equalizer-profiles.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "GanaBajana")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    // MARK: - Track change selection

    func testPlayerPicksTheSongOverrideOnTrackChangeAndTheGlobalSettingOtherwise() throws {
        let first = Track(id: "eq-profile-a", title: "First", duration: 3)
        let second = Track(id: "eq-profile-b", title: "Second", duration: 3)
        let audio = try PlaybackTestSupport.audioFile(seconds: 3)
        directories.append(audio.deletingLastPathComponent())
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 3))
        defer { player.pause() }
        var transitions = PlaybackTransitionSettings()
        transitions.autoplay = false
        player.apply(transitions)
        let global = EqualizerSettings(isEnabled: true, preset: .bassBoost)
        let songOnly = EqualizerSettings(isEnabled: true, preset: .trebleBoost)
        var lookups: [String] = []
        player.equalizerSongOverride = { id in
            lookups.append(id)
            return id == second.id ? songOnly : nil
        }
        player.setEqualizer(global)
        player.play([first, second])
        XCTAssertEqual(player.currentTrack, first)
        XCTAssertEqual(player.equalizerSettings, global)
        XCTAssertFalse(player.isEqualizerSongOverrideActive)

        player.next()
        XCTAssertEqual(player.currentTrack, second)
        XCTAssertEqual(player.equalizerSettings, songOnly, "The override applies when its song plays")
        XCTAssertTrue(player.isEqualizerSongOverrideActive)

        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .rock))
        XCTAssertEqual(player.equalizerSettings, songOnly, "A global change does not replace the playing song's override")

        player.previous()
        if player.currentTrack == second { player.previous() }
        XCTAssertEqual(player.currentTrack, first)
        XCTAssertEqual(player.equalizerSettings.preset, .rock, "Other songs follow the latest global setting")
        XCTAssertFalse(player.isEqualizerSongOverrideActive)
        XCTAssertTrue(lookups.contains(second.id))
    }

    func testModelSongToggleSavesTheGlobalCurveAndEditsOnlyThatSong() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-EQModel-\(UUID())", isDirectory: true)
        directories.append(directory)
        let library = LibraryStore(directory: directory)
        library.preferences.useEncryptedDNS = false
        let audio = try PlaybackTestSupport.audioFile(seconds: 3)
        directories.append(audio.deletingLastPathComponent())
        let player = PlayerController(resolver: PlaybackFileResolver(url: audio, duration: 3))
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        let lyrics = AppModelLyricsProvider()
        let languageService = ArtistSpotlightLanguageService(provider: lyrics)
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts, lyrics: lyrics,
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  recordingLanguageService: languageService,
                                  languageDiscovery: ListeningLanguageDiscovery(service: languageService), generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.cancelPendingRadio()
            model.deactivateDeviceServices()
            player.pause()
            await catalog.close()
            await charts.charts.close()
        }
        var transitions = PlaybackTransitionSettings()
        transitions.autoplay = false
        player.apply(transitions)
        let first = Track(id: "eq-model-a", title: "First", duration: 3)
        let second = Track(id: "eq-model-b", title: "Second", duration: 3)
        model.updatePreferences { $0.equalizer = EqualizerSettings(isEnabled: true, preset: .pop) }
        player.play([first, second])
        XCTAssertEqual(model.equalizerSummary(for: first), "Pop")
        XCTAssertEqual(model.equalizerTarget(for: first), .global)

        model.setSongEqualizer(true, for: first)
        XCTAssertEqual(model.equalizerTarget(for: first), .song(first.id))
        XCTAssertEqual(model.equalizerSummary(for: first), "This song")
        model.updateEqualizer(.song(first.id)) { $0.setSimple(.bass, to: 6) }
        XCTAssertEqual(library.preferences.equalizer.preset, .pop, "Song edits never touch the synced preference")
        XCTAssertEqual(player.equalizerSettings.preset, .custom)

        player.next()
        XCTAssertEqual(player.equalizerSettings, library.preferences.equalizer)
        XCTAssertEqual(model.equalizerSummary(for: second), "Pop")
        player.previous()
        if player.currentTrack == second { player.previous() }
        XCTAssertEqual(player.currentTrack, first)
        XCTAssertEqual(player.equalizerSettings.simpleControls[0], 6, "Coming back applies the saved override")

        model.equalizerProfiles.savePreset(named: "Warm", from: player.equalizerSettings)
        model.setSongEqualizer(false, for: first)
        XCTAssertEqual(player.equalizerSettings, library.preferences.equalizer)
        model.applyEqualizerChoice(.saved("Warm"), to: .global)
        XCTAssertEqual(model.equalizerPresetTitle(for: library.preferences.equalizer), "Warm")
        XCTAssertEqual(model.equalizerSummary(for: first), "Warm")
    }
}
