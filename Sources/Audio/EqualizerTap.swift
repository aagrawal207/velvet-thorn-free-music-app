import AVFoundation
import Foundation
import OSLog

/// Registry of live and standby items sharing one tap each for EQ and normalization gain-up.
/// Lazy installation avoids the native tap's gapless priming cost when neither effect is needed.
@MainActor
final class EqualizerTapInstaller {
    struct Status: Equatable, Sendable {
        /// Live items known to the installer, with or without a tap.
        var registered = 0
        var attached = 0
        var pending = 0
        var bypassed = 0
        var processedFrames = 0
        var normalizationFrames = 0
        var limiterClips = 0
    }

    enum GainMode: String, Equatable, Sendable {
        case unity, attenuation, gainUpPending = "gain_up_pending", gainUp = "gain_up", unsupported
    }

    struct NormalizationStatus: Equatable, Sendable {
        var requestedGain: Double = 1
        var attenuationGain: Double = 1
        var mode: GainMode = .unity
    }

    private enum State { case registered, pending, attached, bypassed }

    private final class Attachment {
        weak var item: AVPlayerItem?
        var processor: EqualizerProcessor?
        var state = State.registered
        var task: Task<Void, Never>?
        var normalizationGain = 1.0
        var allowsGainUp = true
        var reportedMode: GainMode?
        var reportedClips = 0
        var reportedInvalidSamples = 0

        init(item: AVPlayerItem) { self.item = item }
    }

    /// Whether the React to Music backdrop can read the item's level.
    enum MeterAvailability: Equatable, Sendable {
        /// Tap attached or still loading its track; the meter publishes once audio flows.
        case available
        /// No tap: HLS, live, unsupported PCM, a foreign mix, or metering not requested.
        case unavailable
    }

    private(set) var settings = EqualizerSettings()
    /// One meter shared by every processor; the backdrop reads it at its own frame rate.
    let levelMeter = PlaybackLevelMeter()
    private var revision: UInt64 = 0
    private var attachments: [Attachment] = []
    private var lastMetricsAt: ContinuousClock.Instant?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Equalizer")

    var status: Status {
        prune()
        var status = Status()
        for attachment in attachments {
            status.registered += 1
            switch attachment.state {
            case .registered: break
            case .pending: status.pending += 1
            case .attached: status.attached += 1
            case .bypassed: status.bypassed += 1
            }
            status.processedFrames += attachment.processor?.processedFrames.load(ordering: .relaxed) ?? 0
            status.normalizationFrames += attachment.processor?.normalizationFrames.load(ordering: .relaxed) ?? 0
            status.limiterClips += attachment.processor?.limiterClips.load(ordering: .relaxed) ?? 0
        }
        return status
    }

    /// Idempotent. Live taps ramp to the new curve; enabling installs taps on every registered item.
    func update(_ settings: EqualizerSettings) {
        guard settings != self.settings || revision == 0 else { return }
        self.settings = settings
        revision &+= 1
        prune()
        for attachment in attachments {
            attachment.processor?.apply(settings, revision: revision)
            if needsTap(attachment), attachment.state == .registered { install(attachment) }
        }
        let preamp = settings.preamp == 0 ? "auto" : "manual"
        log.info("event=equalizer_settings enabled=\(settings.isEnabled ? 1 : 0) preset=\(settings.preset.rawValue, privacy: .public) preamp=\(preamp, privacy: .public)")
    }

    /// Safe to call repeatedly for the same item. With the equalizer on, the mix is installed once the asset's
    /// audio track ID is known; otherwise the item is only remembered for a later enable.
    func attach(to item: AVPlayerItem) {
        prune()
        guard !attachments.contains(where: { $0.item === item }) else { return }
        let attachment = register(item)
        if needsTap(attachment) { install(attachment) }
    }

    /// Total requested linear gain, independently retained for each item. AVPlayer owns only min(1, gain).
    /// Set allowsGainUp to false for a known live/unsupported path; unknown metadata must supply unity.
    func setNormalizationGain(_ gain: Double, for item: AVPlayerItem, allowsGainUp: Bool = true) {
        prune()
        // Registered before deciding on a tap so a live item's allowsGainUp is known before metering can claim it.
        let attachment = attachments.first(where: { $0.item === item }) ?? register(item)
        let gain = gain.isFinite && gain > 0 ? min(pow(10, GainLimiter.maximumGainDb / 20), gain) : 1
        let changed = attachment.normalizationGain != gain || attachment.allowsGainUp != allowsGainUp
        if changed {
            attachment.normalizationGain = gain
            attachment.allowsGainUp = allowsGainUp
            attachment.processor?.setNormalizationGain(allowsGainUp ? gain : 1)
        }
        if needsTap(attachment), attachment.state == .registered { install(attachment) }
        if changed { report(attachment) }
    }

    /// Idempotent. Requesting installs taps on registered items that may carry one; withdrawing stops the
    /// measurement but leaves installed taps passing audio through, like EQ Off.
    func setMetering(_ requested: Bool) {
        guard requested != levelMeter.isEnabled else { return }
        levelMeter.setEnabled(requested)
        prune()
        guard requested else { return }
        for attachment in attachments where needsTap(attachment) && attachment.state == .registered {
            install(attachment)
        }
    }

    func meterAvailability(for item: AVPlayerItem) -> MeterAvailability {
        guard levelMeter.isEnabled, let attachment = attachments.first(where: { $0.item === item }) else { return .unavailable }
        switch attachment.state {
        case .pending: return .available
        case .attached: return attachment.processor?.formatBypassed.load(ordering: .relaxed) == true ? .unavailable : .available
        case .registered, .bypassed: return .unavailable
        }
    }

    func normalizationStatus(for item: AVPlayerItem) -> NormalizationStatus {
        guard let attachment = attachments.first(where: { $0.item === item }) else { return NormalizationStatus() }
        return normalizationStatus(attachment)
    }

    /// Call on an existing playback tick. Logging is coalesced to five seconds, never from the audio callback.
    func reportMetrics() {
        let now = ContinuousClock.now
        if let lastMetricsAt, lastMetricsAt.duration(to: now) < .seconds(5) { return }
        lastMetricsAt = now
        prune()
        attachments.forEach { report($0) }
    }

    private func needsTap(_ attachment: Attachment) -> Bool {
        Self.needsTap(equalizerEnabled: settings.isEnabled, normalizationGain: attachment.normalizationGain,
                      allowsGainUp: attachment.allowsGainUp, meteringRequested: levelMeter.isEnabled)
    }

    /// Metering shares the gain-up gate: a known live or unsupported path never takes a tap just to measure.
    nonisolated static func needsTap(equalizerEnabled: Bool, normalizationGain: Double, allowsGainUp: Bool,
                                     meteringRequested: Bool) -> Bool {
        equalizerEnabled || (allowsGainUp && (normalizationGain > 1 || meteringRequested))
    }

    private func register(_ item: AVPlayerItem) -> Attachment {
        let attachment = Attachment(item: item)
        attachments.append(attachment)
        return attachment
    }

    private func normalizationStatus(_ attachment: Attachment) -> NormalizationStatus {
        let gain = attachment.normalizationGain
        let mode: GainMode
        if gain <= 1 {
            mode = gain < 1 ? .attenuation : .unity
        } else if !attachment.allowsGainUp || attachment.state == .bypassed
                    || attachment.processor?.formatBypassed.load(ordering: .relaxed) == true {
            mode = .unsupported
        } else if (attachment.processor?.renderedNormalizationGainDb.load(ordering: .relaxed) ?? 0) > 0,
                  (attachment.processor?.preparedChannels.load(ordering: .relaxed) ?? 0) > 0 {
            mode = .gainUp
        } else {
            mode = .gainUpPending
        }
        return NormalizationStatus(requestedGain: gain, attenuationGain: min(1, gain), mode: mode)
    }

    private func report(_ attachment: Attachment) {
        let mode = normalizationStatus(attachment).mode
        if attachment.reportedMode != mode {
            attachment.reportedMode = mode
            log.info("event=normalization_gain mode=\(mode.rawValue, privacy: .public)")
        }
        let clips = attachment.processor?.limiterClips.load(ordering: .relaxed) ?? 0
        let invalid = attachment.processor?.invalidSamples.load(ordering: .relaxed) ?? 0
        let delta = clips - attachment.reportedClips
        let invalidDelta = invalid - attachment.reportedInvalidSamples
        attachment.reportedClips = clips
        attachment.reportedInvalidSamples = invalid
        if delta > 0 || invalidDelta > 0 {
            log.info("event=normalization_limiter limiter_clips=\(max(0, delta)) invalid_samples=\(max(0, invalidDelta))")
        }
    }

    private func install(_ attachment: Attachment) {
        guard attachment.state == .registered, let item = attachment.item else { return }
        let processor = EqualizerProcessor(settings: settings, revision: revision, meter: levelMeter)
        processor.setNormalizationGain(attachment.allowsGainUp ? attachment.normalizationGain : 1)
        attachment.processor = processor
        attachment.state = .pending
        guard let asset = item.asset as? AVURLAsset else {
            bypass(attachment, reason: .assetType)
            return
        }
        guard asset.url.pathExtension.lowercased() != "m3u8" else {
            bypass(attachment, reason: .noAudioTrack)
            return
        }
        guard item.audioMix == nil else {
            bypass(attachment, reason: .existingMix)
            return
        }
        attachment.task = Task { @MainActor [weak self, weak attachment] in
            let trackID: CMPersistentTrackID?
            var failed = false
            do { trackID = try await Self.firstAudioTrackID(of: asset) } catch { trackID = nil; failed = true }
            guard let self, let attachment, attachment.state == .pending else { return }
            attachment.task = nil
            guard let item = attachment.item else { return self.bypass(attachment, reason: .itemReleased) }
            guard let trackID else { return self.bypass(attachment, reason: failed ? .tracksFailed : .noAudioTrack) }
            guard self.needsTap(attachment) else {
                attachment.processor = nil
                attachment.state = .registered
                return
            }
            guard item.audioMix == nil else { return self.bypass(attachment, reason: .existingMix) }
            guard let tap = processor.makeTap() else { return self.bypass(attachment, reason: .tapCreate) }
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = trackID
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
            attachment.state = .attached
            self.log.info("event=equalizer_attached path=tap")
        }
    }

    private func bypass(_ attachment: Attachment, reason: EqualizerProcessor.BypassReason) {
        attachment.state = .bypassed
        report(attachment)
        attachment.processor = nil
        log.notice("event=equalizer_bypass reason=\(reason.rawValue, privacy: .public)")
    }

    /// Items are owned by the players; a released item takes its mix and tap with it.
    private func prune() {
        attachments.removeAll { attachment in
            guard attachment.item == nil else { return false }
            attachment.task?.cancel()
            report(attachment)
            return true
        }
    }

    private nonisolated static func firstAudioTrackID(of asset: AVURLAsset) async throws -> CMPersistentTrackID? {
        try await asset.loadTracks(withMediaType: .audio).first?.trackID
    }
}
