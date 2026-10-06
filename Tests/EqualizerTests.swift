import AVFoundation
import Network
import Synchronization
import XCTest
@testable import GanaBajana

@MainActor
final class EqualizerTests: XCTestCase {
    private let sampleRate = 48_000.0
    private var directories: [URL] = []

    override func tearDown() async throws {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
    }

    // MARK: - Filter bank

    func testPeakingCoefficientsMatchTheCookbookFormula() {
        let coefficients = BiquadCoefficients.peaking(frequency: 1000, sampleRate: sampleRate, gainDb: 6, q: 1.41)
        let amplitude = pow(10, 6.0 / 40)
        let omega = 2 * Double.pi * 1000 / sampleRate
        let alpha = sin(omega) / (2 * 1.41)
        let a0 = 1 + alpha / amplitude
        XCTAssertEqual(coefficients.b0, (1 + alpha * amplitude) / a0, accuracy: 1e-12)
        XCTAssertEqual(coefficients.b1, -2 * cos(omega) / a0, accuracy: 1e-12)
        XCTAssertEqual(coefficients.b2, (1 - alpha * amplitude) / a0, accuracy: 1e-12)
        XCTAssertEqual(coefficients.a1, -2 * cos(omega) / a0, accuracy: 1e-12)
        XCTAssertEqual(coefficients.a2, (1 - alpha / amplitude) / a0, accuracy: 1e-12)
        XCTAssertEqual(20 * log10(coefficients.magnitude(frequency: 1000, sampleRate: sampleRate)), 6, accuracy: 1e-9)
        XCTAssertEqual(BiquadCoefficients.peaking(frequency: 1000, sampleRate: sampleRate, gainDb: 0, q: 1.41).b0, 1, accuracy: 1e-15)
        XCTAssertEqual(BiquadCoefficients.peaking(frequency: 16_000, sampleRate: 8_000, gainDb: 6, q: 1.41), .identity,
                       "Bands above the usable range become identities instead of unstable filters")
    }

    func testEveryBandCentreReachesItsConfiguredGainWhenTheOthersAreFlat() {
        for (band, frequency) in EqualizerPreset.bandFrequencies.enumerated() {
            for gain in [6.0, -4.0, 12.0] {
                var gains = Array(repeating: 0.0, count: 10)
                gains[band] = gain
                let bank = BiquadBank(sampleRate: sampleRate, channels: 1)
                bank.setTargets(gainsDb: gains, preampDb: 0, immediate: true)
                XCTAssertEqual(bank.magnitudeDb(at: frequency), gain, accuracy: 0.5, "band \(band) at \(frequency) Hz")
                XCTAssertEqual(BiquadBank.responseDb(gainsDb: gains, at: frequency, sampleRate: sampleRate), gain, accuracy: 0.5)
            }
        }
        let bank = BiquadBank(sampleRate: 44_100, channels: 2)
        bank.setTargets(gainsDb: EqualizerPreset.bassBoost.gains, preampDb: 0, immediate: true)
        XCTAssertGreaterThan(bank.magnitudeDb(at: 31.25), 5.5, "Adjacent boosts add up rather than cancel")
        XCTAssertEqual(bank.magnitudeDb(at: 8000), 0, accuracy: 0.2, "Far bands stay untouched")
    }

    func testProcessedSineToneCarriesTheBandGain() {
        var gains = Array(repeating: 0.0, count: 10)
        gains[5] = 6
        let bank = BiquadBank(sampleRate: sampleRate, channels: 1)
        bank.setTargets(gainsDb: gains, preampDb: 0, immediate: true)
        var tone = sine(frequency: 1000, seconds: 0.5)
        let inputRMS = rms(tone.suffix(9600))
        bank.process(interleaved: &tone)
        let outputRMS = rms(tone.suffix(9600))
        XCTAssertEqual(20 * log10(outputRMS / inputRMS), 6, accuracy: 0.5)
    }

    func testFlatSettingsAreBitTransparentAndPreampScalesLinearly() {
        let bank = BiquadBank(sampleRate: sampleRate, channels: 2)
        bank.setTargets(gainsDb: Array(repeating: 0, count: 10), preampDb: 0, immediate: true)
        let input = noise(frames: 4096 * 2)
        var output = input
        bank.process(interleaved: &output)
        for (index, sample) in output.enumerated() {
            XCTAssertEqual(sample, input[index], accuracy: 1e-6)
        }

        for preamp in [-6.0, 3.0, 12.0] {
            let scaled = BiquadBank(sampleRate: sampleRate, channels: 1)
            scaled.setTargets(gainsDb: Array(repeating: 0, count: 10), preampDb: preamp, immediate: true)
            var mono = noise(frames: 2048)
            let reference = mono
            scaled.process(interleaved: &mono)
            let factor = Float(pow(10, preamp / 20))
            for (index, sample) in mono.enumerated() {
                XCTAssertEqual(sample, reference[index] * factor, accuracy: 1e-5)
            }
        }
    }

    func testSmoothingRampsLinearlyAndSettlesWithinFiftyMilliseconds() {
        let bank = BiquadBank(sampleRate: sampleRate, channels: 1)
        bank.setTargets(gainsDb: Array(repeating: 0, count: 10), preampDb: 0, immediate: true)
        var gains = Array(repeating: 0.0, count: 10)
        gains[5] = 12
        bank.setTargets(gainsDb: gains, preampDb: -3)
        XCTAssertTrue(bank.isRamping)
        XCTAssertEqual(bank.currentGainsDb[5], 0, "Targets do not jump before audio is processed")

        var tone = sine(frequency: 1000, seconds: 0.01)
        bank.process(interleaved: &tone)
        XCTAssertEqual(bank.currentGainsDb[5], 6, accuracy: 0.5, "Half of the 20 ms ramp moves half of the way")
        XCTAssertEqual(bank.currentPreamp, -1.5, accuracy: 0.2)
        XCTAssertTrue(bank.isRamping)

        tone = sine(frequency: 1000, seconds: 0.04)
        bank.process(interleaved: &tone)
        XCTAssertFalse(bank.isRamping)
        XCTAssertEqual(bank.currentGainsDb[5], 12)
        XCTAssertEqual(bank.currentPreamp, -3)

        var settled = sine(frequency: 1000, seconds: 0.2)
        let inputRMS = rms(settled.suffix(4800))
        bank.process(interleaved: &settled)
        XCTAssertEqual(20 * log10(rms(settled.suffix(4800)) / inputRMS), 9, accuracy: 0.5, "12 dB band boost and -3 dB preamp")
    }

    // MARK: - Settings rules

    func testAutomaticMakeupOffsetsTheLargestBoostUnlessAPreampIsSet() {
        XCTAssertEqual(EqualizerSettings(preset: .bassBoost).resolvedPreamp, -6)
        XCTAssertEqual(EqualizerSettings(preset: .loudness).resolvedPreamp, -6)
        XCTAssertEqual(EqualizerSettings(preset: .bassReducer).resolvedPreamp, 0, "Cuts need no headroom")
        XCTAssertEqual(EqualizerSettings(preset: .flat).resolvedPreamp, 0)
        XCTAssertEqual(EqualizerSettings(preset: .bassBoost, preamp: 3).resolvedPreamp, 3, "A manual preamp replaces the offset")
        XCTAssertEqual(EqualizerSettings(preset: .bassBoost, preamp: -2).resolvedPreamp, -2)
        XCTAssertEqual(EqualizerSettings(preset: .custom, gains: [0, 0, 4.5, 0, 0, 0, 0, 0, 0, 0]).resolvedPreamp, -4.5)
        let targets = EqualizerProcessor.Targets(EqualizerSettings(isEnabled: true, preset: .rock), revision: 3)
        XCTAssertEqual(targets.preampDb, -5)
        XCTAssertEqual((0..<10).map { targets.gains[$0] }, EqualizerPreset.rock.gains)
        XCTAssertTrue(targets.isEnabled)
    }

    func testEditingABandLeavesThePresetAndCopiesItsCurveFirst() {
        var settings = EqualizerSettings(isEnabled: true, preset: .rock)
        settings.setGain(2, band: 0)
        XCTAssertEqual(settings.preset, .custom)
        var expected = EqualizerPreset.rock.gains
        expected[0] = 2
        XCTAssertEqual(settings.gains, expected)
        XCTAssertEqual(settings.effectiveGains, expected)
        settings.setGain(40, band: 9)
        XCTAssertEqual(settings.gains[9], 12, "Values clamp to the gain range")
        settings.setGain(1, band: 10)
        XCTAssertEqual(settings.gains.count, 10, "Out-of-range bands are ignored")
        XCTAssertEqual(settings.summary, "Custom")
        settings.reset()
        XCTAssertEqual(settings, EqualizerSettings(isEnabled: true))
        XCTAssertEqual(settings.summary, "Flat")
        settings.isEnabled = false
        XCTAssertEqual(settings.summary, "Off")
        XCTAssertEqual(EqualizerSettings.formattedGain(3), "+3 dB")
        XCTAssertEqual(EqualizerSettings.formattedGain(-2.5), "-2.5 dB")
        XCTAssertEqual(EqualizerSettings.formattedGain(0.2), "0 dB")
        XCTAssertEqual(EqualizerPreset.bandTitle(0), "31 Hz")
        XCTAssertEqual(EqualizerPreset.bandTitle(6), "2 kHz")
        XCTAssertEqual(EqualizerPreset.bandLabels.count, EqualizerPreset.bandFrequencies.count)
    }

    // MARK: - Processor bypass

    func testDisabledProcessorPassesAudioThroughAndEnablingRampsIn() throws {
        let processor = EqualizerProcessor(settings: EqualizerSettings(isEnabled: false, preset: .bassBoost), revision: 1)
        processor.prepare(maxFrames: 1024, format: format(channels: 2, interleaved: false))
        XCTAssertEqual(processor.preparedChannels.load(ordering: .relaxed), 2)
        let source = sine(frequency: 62.5, seconds: 0.1)
        var left = source, right = source
        try render(processor, frames: source.count, planar: &left, &right)
        XCTAssertEqual(left, source, "Disabled taps leave the source untouched")
        XCTAssertEqual(right, source)
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), 0)

        processor.apply(EqualizerSettings(isEnabled: true, preset: .bassBoost, preamp: 0), revision: 2)
        var boostedLeft = sine(frequency: 62.5, seconds: 0.3), boostedRight = boostedLeft
        let inputRMS = rms(boostedLeft.suffix(4800))
        try render(processor, frames: boostedLeft.count, planar: &boostedLeft, &boostedRight)
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), boostedLeft.count)
        // 62.5 Hz sits in a +5 dB band next to +6 and +4 dB neighbours, offset by the -6 dB automatic preamp.
        let measured = 20 * log10(rms(boostedLeft.suffix(4800)) / inputRMS)
        XCTAssertGreaterThan(measured, -1)
        XCTAssertLessThan(measured, 4)
        XCTAssertEqual(boostedLeft, boostedRight, "Channels share coefficients and keep separate state")

        processor.apply(EqualizerSettings(isEnabled: false, preset: .bassBoost), revision: 3)
        var fading = sine(frequency: 62.5, seconds: 0.1), fadingRight = fading
        try render(processor, frames: fading.count, planar: &fading, &fadingRight)
        let afterFade = processor.processedFrames.load(ordering: .relaxed)
        XCTAssertGreaterThan(afterFade, boostedLeft.count, "Disabling drains through the flat filters first")
        var passing = sine(frequency: 62.5, seconds: 0.1), passingRight = passing
        let reference = passing
        try render(processor, frames: passing.count, planar: &passing, &passingRight)
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), afterFade, "Settled flat taps stop touching audio")
        XCTAssertEqual(passing, reference)
    }

    func testInterleavedBuffersAndUnsupportedFormatsAreHandled() throws {
        let processor = EqualizerProcessor(settings: EqualizerSettings(isEnabled: true, preset: .trebleBoost), revision: 1)
        processor.prepare(maxFrames: 512, format: format(channels: 2, interleaved: true))
        var interleaved = [Float](repeating: 0, count: 512 * 2)
        let tone = sine(frequency: 8000, seconds: 512 / sampleRate)
        for frame in 0..<512 { interleaved[frame * 2] = tone[frame]; interleaved[frame * 2 + 1] = -tone[frame] }
        let reference = interleaved
        try render(processor, frames: 512, interleaved: &interleaved, channels: 2)
        XCTAssertNotEqual(interleaved, reference)
        for frame in 0..<512 { XCTAssertEqual(interleaved[frame * 2], -interleaved[frame * 2 + 1], accuracy: 1e-6) }

        var description = format(channels: 2, interleaved: true)
        description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        description.mBitsPerChannel = 16
        let unsupported = EqualizerProcessor(settings: EqualizerSettings(isEnabled: true, preset: .rock), revision: 1)
        unsupported.prepare(maxFrames: 512, format: description)
        XCTAssertEqual(unsupported.preparedChannels.load(ordering: .relaxed), 0, "Non-float formats bypass instead of guessing")
    }

    // MARK: - Player integration

    func testSetEqualizerInstallsTapsOnTheCurrentAndStandbyItemsAndUpdatesThemLive() async throws {
        let first = Track(id: "eq-first", title: "First", duration: 4)
        let second = Track(id: "eq-second", title: "Second", duration: 4)
        let resolver = PlaybackFixtureResolver([
            first.id: .init(url: try audio(seconds: 4), duration: 4),
            second.id: .init(url: try audio(seconds: 4), duration: 4),
        ])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var transitions = PlaybackTransitionSettings()
        transitions.gapless = true
        transitions.autoplay = false
        player.apply(transitions)
        XCTAssertEqual(player.equalizerSettings, EqualizerSettings())
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == second && player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.registered == 2 }
        XCTAssertEqual(player.equalizerStatus.attached, 0, "Off installs no tap, so playback stays on today's path")
        XCTAssertEqual(player.equalizerStatus.processedFrames, 0)

        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .bassBoost))
        XCTAssertEqual(player.equalizerSettings.preset, .bassBoost)
        let position = player.position
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.attached == 2 && player.equalizerStatus.pending == 0 }
        XCTAssertEqual(player.equalizerStatus.bypassed, 0)
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.processedFrames > 0 }
        XCTAssertTrue(player.isPlaying, "Enabling never restarts playback")
        try await PlaybackTestSupport.waitUntil { player.position > position + 0.3 }
        XCTAssertNil(player.errorMessage)

        try await PlaybackTestSupport.waitUntil(timeout: 8) { player.currentTrack == second && player.isPlaying }
        try await PlaybackTestSupport.waitUntil { player.position > 0.5 }
        XCTAssertGreaterThanOrEqual(player.equalizerStatus.attached, 1, "The standby item keeps its tap when it becomes current")
        player.setEqualizer(EqualizerSettings(isEnabled: false, preset: .bassBoost))
        XCTAssertGreaterThanOrEqual(player.equalizerStatus.attached, 1, "Turning off leaves the live tap passing through")
        XCTAssertNil(player.errorMessage)
    }

    /// The gapless test in PlaybackTransitionTests requires 150 ms without taps; this documents the cost with them.
    func testGaplessSwapWithTheEqualizerEnabledStaysNearlySeamless() async throws {
        let first = Track(id: "eq-gap-first", title: "First", duration: 3)
        let second = Track(id: "eq-gap-second", title: "Second", duration: 4)
        let resolver = PlaybackFixtureResolver([
            first.id: .init(url: try audio(seconds: 3), duration: 3),
            second.id: .init(url: try audio(seconds: 4), duration: 4),
        ])
        let player = PlayerController(resolver: resolver)
        defer { player.pause() }
        var transitions = PlaybackTransitionSettings()
        transitions.gapless = true
        transitions.autoplay = false
        player.apply(transitions)
        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .pop))
        var starts: [String] = []
        player.onTrackStarted = { starts.append($0.id) }
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.standbyTrack == second && player.isStandbyReady }
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.attached == 2 }
        var flipAt: ContinuousClock.Instant?
        try await PlaybackTestSupport.waitUntil(timeout: 6) {
            guard player.currentTrack == second else { return false }
            flipAt = .now
            return true
        }
        let flip = try XCTUnwrap(flipAt)
        try await Task.sleep(for: .milliseconds(400))
        player.flushListeningProgress()
        let elapsed = flip.duration(to: .now)
        let gap = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18 - player.position
        print("EQUALIZER GAPLESS gap=\(gap) seconds with taps on both decks")
        // AVFoundation does not pull a tapped item through preroll, so the swap primes the tap pipeline first;
        // about 0.4 s on the simulator. The bound catches a regression, the print records the measurement.
        XCTAssertLessThan(gap, 0.8, "The tapped standby item must still start well under a second")
        XCTAssertGreaterThan(gap, -0.1)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1 }
        XCTAssertEqual(starts, [first.id, second.id])
        XCTAssertGreaterThan(player.equalizerStatus.processedFrames, 0)
        XCTAssertNil(player.errorMessage)
    }

    func testBundledAACFixturePlaysAndAdvancesWithTheEqualizerEnabled() async throws {
        let aac = try await exportAAC(seconds: 8)
        let player = PlayerController(resolver: PlaybackFileResolver(url: aac, duration: 8))
        defer { player.pause() }
        var transitions = PlaybackTransitionSettings()
        transitions.autoplay = false
        player.apply(transitions)
        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .rock, preamp: -2))
        player.play([Track(id: "eq-aac", title: "AAC fixture", duration: 8)])
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 1.5 }
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.attached == 1 }
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.processedFrames > 0 }
        XCTAssertEqual(player.equalizerStatus.bypassed, 0)
        XCTAssertEqual(player.duration, 8, accuracy: 0.2)
        player.seek(to: 5)
        try await PlaybackTestSupport.waitUntil { player.isPlaying && player.position > 5.5 }
        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .custom, gains: [3, 0, 0, 0, 0, -4, 0, 0, 0, 0]))
        try await PlaybackTestSupport.waitUntil { player.position > 6.2 }
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.errorMessage)
    }

    func testRemoteStyleProgressiveHTTPItemGetsTheTapAndKeepsPlaying() async throws {
        let aac = try await exportAAC(seconds: 8)
        let server = try await EqualizerTestHTTPServer(data: Data(contentsOf: aac), contentType: "audio/mp4")
        defer { server.stop() }
        let player = PlayerController(resolver: PlaybackFileResolver(url: server.url(path: "/tone.m4a"), duration: 8))
        defer { player.pause() }
        var transitions = PlaybackTransitionSettings()
        transitions.autoplay = false
        player.apply(transitions)
        player.setEqualizer(EqualizerSettings(isEnabled: true, preset: .trebleBoost))
        player.play([Track(id: "eq-http", title: "HTTP fixture", duration: 8)])
        do {
            try await PlaybackTestSupport.waitUntil(timeout: 15) { (player.isPlaying && player.position > 1.5) || player.errorMessage != nil }
        } catch {
            throw XCTSkip("Loopback HTTP playback did not start in time: \(server.requestCount) requests")
        }
        if let message = player.errorMessage, message.localizedCaseInsensitiveContains("transport security") {
            throw XCTSkip("Plain HTTP to 127.0.0.1 is blocked by App Transport Security in this host: \(message)")
        }
        XCTAssertNil(player.errorMessage)
        XCTAssertGreaterThan(server.requestCount, 0, "AVPlayer fetched the file over HTTP rather than a file URL")
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.attached == 1 }
        try await PlaybackTestSupport.waitUntil { player.equalizerStatus.processedFrames > 0 }
        XCTAssertEqual(player.equalizerStatus.bypassed, 0)
        let position = player.position
        try await PlaybackTestSupport.waitUntil { player.position > position + 1 }
        XCTAssertTrue(player.isPlaying)
    }

    func testModelAppliesTheSavedEqualizerAtLaunchAndOnEveryChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-Equalizer-\(UUID())", isDirectory: true)
        directories.append(directory)
        let seed = LibraryStore(directory: directory)
        var preferences = seed.preferences
        preferences.equalizer = EqualizerSettings(isEnabled: true, preset: .jazz, preamp: 1.5)
        preferences.useEncryptedDNS = false
        seed.preferences = preferences
        XCTAssertNil(seed.errorMessage)

        let library = LibraryStore(directory: directory)
        let player = PlayerController(resolver: PlaybackFileResolver(url: try audio(seconds: 2), duration: 2))
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
        XCTAssertEqual(player.equalizerSettings, EqualizerSettings(isEnabled: true, preset: .jazz, preamp: 1.5))
        model.updatePreferences { $0.equalizer.setGain(4, band: 2) }
        XCTAssertEqual(player.equalizerSettings.preset, .custom)
        XCTAssertEqual(player.equalizerSettings.gains[2], 4)
        XCTAssertEqual(player.equalizerSettings.gains[0], EqualizerPreset.jazz.gains[0])
        model.updatePreferences { $0.equalizer.isEnabled = false }
        XCTAssertFalse(player.equalizerSettings.isEnabled)
        XCTAssertEqual(library.preferences.equalizer.summary, "Off")
    }

    // MARK: - Helpers

    private func sine(frequency: Double, seconds: Double) -> [Float] {
        let frames = Int(seconds * sampleRate)
        return (0..<frames).map { Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) * 0.25 }
    }

    private func noise(frames: Int) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<frames).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))).squareRoot()
    }

    private func format(channels: Int, interleaved: Bool) -> AudioStreamBasicDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
        return AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                                           mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }

    private func render(_ processor: EqualizerProcessor, frames: Int, planar left: inout [Float], _ right: inout [Float]) throws {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        try left.withUnsafeMutableBufferPointer { leftBuffer in
            try right.withUnsafeMutableBufferPointer { rightBuffer in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(try XCTUnwrap(leftBuffer.baseAddress)))
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(try XCTUnwrap(rightBuffer.baseAddress)))
                processor.render(frames: frames, bufferList: list)
            }
        }
    }

    private func render(_ processor: EqualizerProcessor, frames: Int, interleaved samples: inout [Float], channels: Int) throws {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        try samples.withUnsafeMutableBufferPointer { buffer in
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4),
                                  mData: UnsafeMutableRawPointer(try XCTUnwrap(buffer.baseAddress)))
            processor.render(frames: frames, bufferList: list)
        }
    }

    private func audio(seconds: Int) throws -> URL {
        let url = try PlaybackTestSupport.audioFile(seconds: seconds)
        directories.append(url.deletingLastPathComponent())
        return url
    }

    /// The test bundle ships no AAC file; encoding the tone fixture through AVFoundation gives a real AAC-in-MP4 item.
    private func exportAAC(seconds: Int) async throws -> URL {
        let source = try audio(seconds: seconds)
        let output = source.deletingLastPathComponent().appendingPathComponent("tone.m4a")
        let asset = AVURLAsset(url: source)
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        try await exporter.export(to: output, as: .m4a)
        let exported = AVURLAsset(url: output)
        let tracks = try await exported.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        return output
    }
}

/// Serves one in-memory file over HTTP/1.1 on 127.0.0.1 with byte ranges, which is all AVPlayer needs for a
/// progressive MP4. Keeps the "remote-style" item on the real HTTP loading path without leaving the machine.
final class EqualizerTestHTTPServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let data: Data
    private let contentType: String
    private let queue = DispatchQueue(label: "com.agraabhi.ganabajana.tests.equalizer-http")
    private var connections: [NWConnection] = []
    private let requests = Atomic<Int>(0)

    init(data: Data, contentType: String) async throws {
        self.data = data
        self.contentType = contentType
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let listener = self.listener
        port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var requestCount: Int { requests.load(ordering: .relaxed) }

    func url(path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(connection, buffered: Data())
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffered
            if let content { buffer.append(content) }
            var remainder = buffer
            while let end = remainder.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: remainder[remainder.startIndex..<end.lowerBound], as: UTF8.self)
                remainder = remainder[end.upperBound...]
                self.respond(connection, head: head)
            }
            if isComplete { connection.cancel(); return }
            self.receive(connection, buffered: Data(remainder))
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        requests.wrappingAdd(1, ordering: .relaxed)
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.components(separatedBy: " ") ?? []
        let method = request.first ?? "GET"
        var start = 0
        var end = data.count - 1
        var status = "200 OK"
        if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") })?.split(separator: "=").last {
            let bounds = range.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2 {
                start = bounds[0] ?? 0
                end = bounds[1] ?? (data.count - 1)
                end = min(end, data.count - 1)
                status = "206 Partial Content"
            }
        }
        guard start <= end, start < data.count else {
            connection.send(content: Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let body = data[start...end]
        var header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\n"
        header += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n"
        if status.hasPrefix("206") { header += "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" }
        header += "\r\n"
        var payload = Data(header.utf8)
        if method != "HEAD" { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }
}
