import AVFoundation
import MediaToolbox
import XCTest
@testable import GanaBajana

@MainActor
final class GainUpNormalizationTests: XCTestCase {
    func testKnownLoudnessUsesProviderOffsetAndCapsBoostAtSixDb() {
        for (loudness, expectedDb) in [(6.0, -6.0), (20, -20), (-3, 3), (-6, 6), (-60, 6), (60, -60), (0, 0)] {
            XCTAssertEqual(PlaybackNormalization.gainDb(loudnessDb: loudness, enabled: true), expectedDb)
        }
        XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: -60, enabled: true), 1.995_262_315, accuracy: 1e-9)
        XCTAssertEqual(PlaybackNormalization.attenuationGain(loudnessDb: 6, enabled: true), 0.501_187_234, accuracy: 1e-9)
        XCTAssertEqual(PlaybackNormalization.attenuationGain(loudnessDb: -6, enabled: true), 1)
    }

    func testUnknownInvalidOutOfRangeAndDisabledMetadataNeverBoost() {
        let values: [Double?] = [nil, .nan, .infinity, -.infinity, -60.001, 60.001, .greatestFiniteMagnitude]
        for value in values {
            XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: value, enabled: true), 1)
        }
        for value in [-60.0, -3, 6, 60] {
            XCTAssertEqual(PlaybackNormalization.gain(loudnessDb: value, enabled: false), 1)
        }
        var preferences = UserPreferences()
        preferences.normalizeVolume = false
        XCTAssertFalse(PlaybackTransitionSettings(preferences).normalizeVolume)
        preferences.normalizeVolume = true
        XCTAssertTrue(PlaybackTransitionSettings(preferences).normalizeVolume)
    }

    func testLimiterZeroFramesSilenceAndUnityAreTransparent() {
        let limiter = GainLimiter(sampleRate: 48_000)
        var empty: [Float] = []
        XCTAssertEqual(process(limiter, &empty).limitedFrames, 0)
        var unity: [Float] = [0, 0.2, -0.5, 0.8]
        let original = unity
        XCTAssertEqual(process(limiter, &unity).limitedFrames, 0)
        XCTAssertEqual(unity, original)
        limiter.setGainDb(6, immediate: true)
        var silence = [Float](repeating: 0, count: 4096)
        let measurement = process(limiter, &silence)
        XCTAssertEqual(silence, [Float](repeating: 0, count: 4096))
        XCTAssertEqual(measurement.inputEnergy, 0)
        XCTAssertEqual(measurement.outputEnergy, 0)
        XCTAssertEqual(measurement.limitedFrames, 0)
        limiter.setGainDb(-6, immediate: true)
        var attenuated: [Float] = [0.5, -0.25]
        process(limiter, &attenuated)
        XCTAssertEqual(attenuated[0], 0.250_593_62, accuracy: 1e-7)
        XCTAssertEqual(attenuated[1], -0.125_296_81, accuracy: 1e-7)
    }

    func testLimiterPeaksAreBoundedAndStereoChannelsShareOneEnvelope() {
        let limiter = GainLimiter(sampleRate: 48_000)
        limiter.setGainDb(6, immediate: true)
        var samples: [Float] = [0.9, -0.45, -1, 0.5, 0.2, -0.1, 1, -0.5]
        let measurement = process(limiter, &samples, channels: 2)
        XCTAssertEqual(measurement.limitedFrames, 4, "Counts linked frames, not individual channels")
        XCTAssertEqual(samples[0], 0.98, accuracy: 1e-6)
        for frame in 0..<4 {
            XCTAssertEqual(samples[frame * 2 + 1], -0.5 * samples[frame * 2], accuracy: 1e-6)
        }
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.980_001 })
        XCTAssertLessThan(limiter.reduction, 1)
        var release = [Float](repeating: 0.01, count: 96_000)
        process(limiter, &release)
        XCTAssertEqual(limiter.reduction, 1)
        XCTAssertEqual(release.last!, 0.019_952_623, accuracy: 1e-7)
    }

    func testLimiterSanitizesNonfiniteAudioAndGainsAndSurvivesHugeFinitePeaks() {
        let limiter = GainLimiter(sampleRate: .nan)
        limiter.setGainDb(.infinity, immediate: true)
        XCTAssertEqual(limiter.currentGainDb, 0)
        limiter.setGainDb(600, immediate: true)
        XCTAssertEqual(limiter.currentGainDb, 6)
        var samples: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 0]
        let measurement = process(limiter, &samples)
        XCTAssertEqual(measurement.invalidSamples, 3)
        XCTAssertEqual(Array(samples.prefix(3)), [0, 0, 0])
        XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 0.980_001 })
        XCTAssertTrue(measurement.inputEnergy.isFinite)
        XCTAssertTrue(measurement.outputEnergy.isFinite)
        limiter.setGainDb(.nan)
        var silence = [Float](repeating: 0, count: 960)
        process(limiter, &silence)
        XCTAssertEqual(limiter.currentGainDb, 0)
    }

    func testGainChangesRampInDbAndRetargetFromTheCurrentLevel() {
        let limiter = GainLimiter(sampleRate: 48_000)
        limiter.setGainDb(6)
        var firstHalf = [Float](repeating: 0.1, count: 480)
        process(limiter, &firstHalf)
        XCTAssertEqual(limiter.currentGainDb, 3, accuracy: 1e-9)
        XCTAssertLessThan(firstHalf[0], 0.1001)
        XCTAssertEqual(firstHalf.last!, 0.141_253_75, accuracy: 1e-6)
        limiter.setGainDb(0)
        var secondHalf = [Float](repeating: 0.1, count: 480)
        process(limiter, &secondHalf)
        XCTAssertEqual(limiter.currentGainDb, 1.5, accuracy: 1e-9)
        var finish = [Float](repeating: 0.1, count: 480)
        process(limiter, &finish)
        XCTAssertEqual(limiter.currentGainDb, 0)
        XCTAssertEqual(finish.last!, 0.1)
        XCTAssertFalse(limiter.isActive)
    }

    func testNormalizationOnlyTapRampsWithEQDisabledAndDrainsToPassThrough() throws {
        let processor = EqualizerProcessor()
        processor.prepare(maxFrames: 1024, format: format(channels: 2))
        processor.setNormalizationGain(1.995_262_315)
        var samples = [Float](repeating: 0.1, count: 1920)
        try render(processor, &samples, channels: 2)
        XCTAssertLessThan(samples[0], 0.1001)
        XCTAssertEqual(samples.last!, 0.199_526_23, accuracy: 1e-6)
        XCTAssertEqual(processor.normalizationFrames.load(ordering: .relaxed), 960)
        XCTAssertEqual(processor.limiterClips.load(ordering: .relaxed), 0)
        processor.setNormalizationGain(1)
        samples = [Float](repeating: 0.1, count: 1920)
        try render(processor, &samples, channels: 2)
        XCTAssertGreaterThan(samples[0], 0.199)
        XCTAssertEqual(samples.last!, 0.1)
        let processed = processor.processedFrames.load(ordering: .relaxed)
        let original: [Float] = [0.1, -0.2, 0.3, -0.4]
        samples = original
        try render(processor, &samples, channels: 2)
        XCTAssertEqual(samples, original)
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), processed)
    }

    func testEQPreampAppliesOnceAndEQChangesPreserveNormalization() throws {
        let processor = EqualizerProcessor(settings: EqualizerSettings(isEnabled: true, preamp: -6))
        processor.setNormalizationGain(pow(10, 6.0 / 20))
        processor.prepare(maxFrames: 1024, format: format(channels: 1))
        var samples = [Float](repeating: 0.1, count: 4800)
        try render(processor, &samples)
        XCTAssertEqual(samples.last!, 0.1, accuracy: 1e-6, "-6 dB preamp and +6 dB normalization cancel once")
        processor.apply(EqualizerSettings(isEnabled: false, preamp: -6), revision: 1)
        samples = [Float](repeating: 0.1, count: 4800)
        try render(processor, &samples)
        XCTAssertEqual(samples.last!, 0.199_526_23, accuracy: 1e-6)
        processor.setNormalizationGain(0.5)
        samples = [Float](repeating: 0.1, count: 4800)
        try render(processor, &samples)
        XCTAssertEqual(samples.last!, 0.1, accuracy: 1e-6, "Attenuation is not applied twice inside the tap")
    }

    func testPlanarStereoLimiterLinksChannelsAfterEQAndMatchesInterleaved() throws {
        let settings = EqualizerSettings(isEnabled: true, preamp: 3)
        let planar = EqualizerProcessor(settings: settings)
        let interleaved = EqualizerProcessor(settings: settings)
        planar.setNormalizationGain(2)
        interleaved.setNormalizationGain(2)
        planar.prepare(maxFrames: 1024, format: format(channels: 2, planar: true))
        interleaved.prepare(maxFrames: 1024, format: format(channels: 2))
        var left = [Float](repeating: 0.8, count: 2048)
        var right = [Float](repeating: -0.2, count: 2048)
        var packed = (0..<2048).flatMap { _ in [Float(0.8), Float(-0.2)] }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count * 4), mData: l.baseAddress.map { UnsafeMutableRawPointer($0) })
                list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count * 4), mData: r.baseAddress.map { UnsafeMutableRawPointer($0) })
                planar.render(frames: l.count, bufferList: list)
            }
        }
        try render(interleaved, &packed, channels: 2)
        for frame in 0..<2048 {
            XCTAssertEqual(left[frame], packed[frame * 2])
            XCTAssertEqual(right[frame], packed[frame * 2 + 1])
            XCTAssertEqual(right[frame], -left[frame] / 4, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(left[frame]), 0.980_001)
        }
        XCTAssertEqual(planar.limiterClips.load(ordering: .relaxed), 2048)
    }

    func testMalformedAndUnsupportedBuffersBypassWithoutReadingPastStorage() throws {
        let processor = EqualizerProcessor()
        processor.setNormalizationGain(2)
        processor.prepare(maxFrames: 1024, format: format(channels: 1))
        var samples: [Float] = [0.1, 0.2]
        try render(processor, &samples, requestedFrames: Int.max)
        XCTAssertEqual(samples, [0.1, 0.2])
        XCTAssertEqual(processor.processedFrames.load(ordering: .relaxed), 0)
        var invalid = format(channels: 1)
        invalid.mSampleRate = .nan
        processor.prepare(maxFrames: 1024, format: invalid)
        XCTAssertTrue(processor.formatBypassed.load(ordering: .relaxed))
        XCTAssertEqual(processor.preparedChannels.load(ordering: .relaxed), 0)
        try render(processor, &samples)
        XCTAssertEqual(samples, [0.1, 0.2])
        invalid = format(channels: 1)
        invalid.mBitsPerChannel = 16
        processor.prepare(maxFrames: 1024, format: invalid)
        XCTAssertTrue(processor.formatBypassed.load(ordering: .relaxed))
        processor.prepare(maxFrames: 1024, format: format(channels: 1))
        XCTAssertFalse(processor.formatBypassed.load(ordering: .relaxed))
        processor.unprepare()
        XCTAssertEqual(processor.preparedChannels.load(ordering: .relaxed), 0)
    }

    func testNonfiniteInputDoesNotPoisonTheEQState() {
        let bank = BiquadBank(sampleRate: 48_000, channels: 1)
        bank.setTargets(gainsDb: EqualizerPreset.rock.gains, preampDb: -5, immediate: true)
        var input: [Float] = [.nan, .infinity, -.infinity]
        input += [Float](repeating: 0.1, count: 4800)
        bank.process(interleaved: &input)
        XCTAssertTrue(input.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(abs(input.last!), 0.01)
    }

    func testInstallerKeepsOneSharedTapAndIndependentDeckGainsAcrossToggles() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let live = AVPlayerItem(url: url)
        let standby = AVPlayerItem(url: url)
        let installer = EqualizerTapInstaller()
        installer.attach(to: live)
        installer.attach(to: standby)
        XCTAssertEqual(installer.status.attached, 0)
        installer.setNormalizationGain(1.4, for: live)
        installer.setNormalizationGain(1.9, for: standby)
        try await PlaybackTestSupport.waitUntil { installer.status.attached == 2 }
        let liveProcessor = try processor(for: live)
        let standbyProcessor = try processor(for: standby)
        installer.update(EqualizerSettings(isEnabled: true, preset: .rock))
        installer.update(EqualizerSettings())
        installer.setNormalizationGain(1, for: live)
        XCTAssertTrue(try processor(for: live) === liveProcessor)
        XCTAssertTrue(try processor(for: standby) === standbyProcessor)
        XCTAssertEqual(installer.normalizationStatus(for: live).requestedGain, 1)
        XCTAssertEqual(installer.normalizationStatus(for: standby).requestedGain, 1.9)
        XCTAssertEqual(live.audioMix?.inputParameters.count, 1)
        XCTAssertEqual(standby.audioMix?.inputParameters.count, 1)
        let future = AVPlayerItem(url: url)
        installer.setNormalizationGain(1, for: future)
        XCTAssertNil(future.audioMix)
        XCTAssertEqual(installer.status.pending, 0)
    }

    func testUnsupportedHLSAndExistingMixRetainUnityFallbackWithoutReplacingAudio() {
        let installer = EqualizerTapInstaller()
        let hls = AVPlayerItem(url: URL(string: "https://example.invalid/live.m3u8")!)
        installer.setNormalizationGain(2, for: hls)
        XCTAssertNil(hls.audioMix)
        XCTAssertEqual(installer.normalizationStatus(for: hls).mode, .unsupported)
        XCTAssertEqual(installer.normalizationStatus(for: hls).attenuationGain, 1)
        installer.setNormalizationGain(0.5, for: hls)
        XCTAssertEqual(installer.normalizationStatus(for: hls).mode, .attenuation)
        XCTAssertEqual(installer.normalizationStatus(for: hls).attenuationGain, 0.5)
        XCTAssertNil(hls.error)
        let existing = AVPlayerItem(url: URL(fileURLWithPath: "/unused.m4a"))
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = 123
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        existing.audioMix = mix
        installer.setNormalizationGain(2, for: existing)
        XCTAssertEqual(installer.normalizationStatus(for: existing).mode, .unsupported)
        XCTAssertEqual(existing.audioMix?.inputParameters.first?.trackID, 123)
        let live = AVPlayerItem(url: URL(string: "https://example.invalid/live")!)
        installer.setNormalizationGain(2, for: live, allowsGainUp: false)
        XCTAssertEqual(installer.normalizationStatus(for: live).mode, .unsupported)
        XCTAssertNil(live.audioMix)
        installer.setNormalizationGain(.nan, for: live)
        XCTAssertEqual(installer.normalizationStatus(for: live).mode, .unity)
    }

    func testDisablingDuringPendingInstallationLeavesTheItemUntapped() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = AVPlayerItem(url: url)
        let installer = EqualizerTapInstaller()
        installer.setNormalizationGain(2, for: item)
        XCTAssertEqual(installer.status.pending, 1)
        installer.setNormalizationGain(1, for: item)
        try await PlaybackTestSupport.waitUntil { installer.status.pending == 0 }
        XCTAssertNil(item.audioMix)
        XCTAssertEqual(installer.status.bypassed, 0)
        installer.setNormalizationGain(2, for: item)
        try await PlaybackTestSupport.waitUntil { installer.status.attached == 1 }
        XCTAssertNotNil(item.audioMix)
    }

    func testStandbyConfigurationHasItsOwnCallbackAndUsesLatestPreference() async throws {
        let url = try PlaybackTestSupport.audioFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFileResolver(url: url, duration: 8, loudnessDb: -3)
        let deck = StandbyDeck(resolver: resolver, preroll: { _, completion in completion(true) })
        defer { deck.invalidate() }
        var changes = 0
        var gains: [Double] = []
        deck.onChange = { changes += 1 }
        deck.onConfigureAudio = { _, gain in gains.append(gain) }
        let entry = UUID()
        deck.prepare(track: Track(id: "normalization-standby", title: "Fixture"), entryID: entry, forceRefresh: false, after: nil)
        deck.normalizeVolume = false
        try await PlaybackTestSupport.waitUntil { deck.isReady }
        XCTAssertEqual(gains, [1])
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(deck.player?.volume, 0)
        deck.normalizeVolume = true
        XCTAssertEqual(gains.last!, 1.412_538, accuracy: 0.000_001)
        let prepared = try XCTUnwrap(deck.take(entryID: entry, transitionAt: Date()))
        XCTAssertEqual(prepared.stream.loudnessDb, -3)
        deck.normalizeVolume = false
        XCTAssertEqual(gains.count, 2, "A lent player is not retargeted through the empty standby deck")
        deck.reclaim(prepared.player)
        XCTAssertNil(deck.player?.currentItem)
    }

    func testCrossfadeUsesAttenuationOnlyAndNeverSendsBoostToPlayerVolume() {
        let outgoing = PlaybackAudioRoute.makePlayer()
        let incoming = PlaybackAudioRoute.makePlayer()
        let fade = PlaybackCrossfade(outgoing: outgoing, incoming: incoming, duration: 1, outgoingGain: 2, incomingGain: .nan)
        XCTAssertEqual(fade.outgoingGain, 1)
        XCTAssertEqual(fade.incomingGain, 1)
        let attenuated = PlaybackCrossfade(outgoing: outgoing, incoming: incoming, duration: 1, outgoingGain: 0.5, incomingGain: 1)
        XCTAssertEqual(attenuated.outgoingGain, 0.5)
    }

    func testNativeTapReadsKnownPCMAndAppliesLiveGainAndEQChanges() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 12)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let installer = EqualizerTapInstaller()
        let item = AVPlayerItem(url: url)
        installer.setNormalizationGain(pow(10, 6.0 / 20), for: item)
        try await PlaybackTestSupport.waitUntil { installer.status.attached == 1 }
        let processor = try processor(for: item)
        let player = PlaybackAudioRoute.makePlayer()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: 1)
        try await PlaybackTestSupport.waitUntil {
            processor.normalizationFrames.load(ordering: .relaxed) > 4000
                && abs(processor.renderedNormalizationGainDb.load(ordering: .relaxed) - 6) < 0.001
        }
        let inputRMS = processor.lastInputRMS.load(ordering: .relaxed)
        XCTAssertEqual(inputRMS, 1000 / 32768.0 / sqrt(2), accuracy: 0.002, "The native callback actually pulled the known PCM source")
        XCTAssertEqual(processor.lastOutputRMS.load(ordering: .relaxed) / inputRMS, 1.995_262, accuracy: 0.03)
        XCTAssertEqual(installer.normalizationStatus(for: item).mode, .gainUp)
        XCTAssertEqual(player.volume, 1)
        XCTAssertEqual(processor.limiterClips.load(ordering: .relaxed), 0)
        installer.update(EqualizerSettings(isEnabled: true, preamp: -6))
        installer.setNormalizationGain(pow(10, 3.0 / 20), for: item)
        let previousFrames = processor.processedFrames.load(ordering: .relaxed)
        try await PlaybackTestSupport.waitUntil {
            processor.processedFrames.load(ordering: .relaxed) > previousFrames + 4000
                && abs(processor.renderedNormalizationGainDb.load(ordering: .relaxed) - 3) < 0.001
        }
        XCTAssertEqual(processor.lastInputRMS.load(ordering: .relaxed) / inputRMS, 0.501_187, accuracy: 0.03)
        XCTAssertEqual(processor.lastOutputRMS.load(ordering: .relaxed) / inputRMS, 0.707_946, accuracy: 0.03)
        XCTAssertTrue(try self.processor(for: item) === processor, "Live edits reuse the native tap")
        installer.setNormalizationGain(1, for: item)
        installer.update(EqualizerSettings())
        try await PlaybackTestSupport.waitUntil { processor.renderedNormalizationGainDb.load(ordering: .relaxed) == 0 }
        XCTAssertNil(item.error)
        XCTAssertEqual(player.volume, 1)
    }

    // MARK: - Buffer fixtures

    @discardableResult
    private func process(_ limiter: GainLimiter, _ samples: inout [Float], channels: Int = 1) -> GainLimiter.Measurement {
        samples.withUnsafeMutableBufferPointer { buffer in
            let starts: [UnsafeMutablePointer<Float>?] = (0..<channels).map { channel in buffer.baseAddress.map { $0 + channel } }
            return starts.withUnsafeBufferPointer {
                limiter.process(frames: buffer.count / channels, channels: channels, channelStarts: $0.baseAddress!, stride: channels)
            }
        }
    }

    private func format(channels: UInt32, planar: Bool = false) -> AudioStreamBasicDescription {
        let bytes: UInt32 = planar ? 4 : 4 * channels
        let flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0)
        return AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                           mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    private func render(_ processor: EqualizerProcessor, _ samples: inout [Float], channels: Int = 1,
                        requestedFrames: Int? = nil) throws {
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(list.unsafeMutablePointer) }
        try samples.withUnsafeMutableBufferPointer { buffer in
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(buffer.count * 4),
                                  mData: UnsafeMutableRawPointer(try XCTUnwrap(buffer.baseAddress)))
            processor.render(frames: requestedFrames ?? buffer.count / channels, bufferList: list)
        }
    }

    private func processor(for item: AVPlayerItem) throws -> EqualizerProcessor {
        let tap = try XCTUnwrap(item.audioMix?.inputParameters.first?.audioTapProcessor)
        return Unmanaged<EqualizerProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }
}
