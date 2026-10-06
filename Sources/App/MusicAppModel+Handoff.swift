import Foundation
import OSLog

@MainActor
extension MusicAppModel {
    private static let handoffLog = Logger(subsystem: "com.agraabhi.ganabajana", category: "handoff")

    /// Lets the receiver ignore the activity this process advertises itself.
    nonisolated static var handoffSenderID: UUID { PlaybackHandoffCodec.localSenderID }

    /// Replaces the local selection with another device's, paused at `position` unless `startPlaying`.
    @discardableResult
    func continuePlayback(from snapshot: PlaybackSnapshot, at position: TimeInterval, startPlaying: Bool,
                          origin: PlaybackContinuationOrigin) -> Bool {
        var adjusted = snapshot
        adjusted.position = PlaybackTiming.position(position)
        guard position.isFinite, PlaybackHandoffCodec.isValid(adjusted) else {
            Self.handoffLog.notice("event=playback_continued outcome=rejected origin=\(origin.rawValue, privacy: .public) reason=invalid_snapshot")
            return false
        }
        cancelPendingArtistLookup()
        dismissSearchKeyboard()
        retireSessionsForContinuation()
        player.restore(adjusted)
        // Restore declines while listening progress cannot be flushed; the earlier selection then stays in place.
        guard player.queue.map(\.id) == adjusted.queue.map(\.id), player.currentIndex == adjusted.currentIndex,
              player.currentTrack?.id == adjusted.queue[adjusted.currentIndex].id else {
            Self.handoffLog.notice("event=playback_continued outcome=rejected origin=\(origin.rawValue, privacy: .public) reason=restore_declined")
            return false
        }
        if startPlaying { player.resumePlayback() }
        Self.handoffLog.info("event=playback_continued origin=\(origin.rawValue, privacy: .public) playing=\(startPlaying ? 1 : 0) queue_count=\(PlaybackHandoffCodec.countBucket(adjusted.queue.count), privacy: .public)")
        return true
    }

    /// Continues a Handoff activity: playing when the sender was playing, since tapping Handoff is the explicit request.
    @discardableResult
    func acceptHandoff(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == PlaybackHandoffCodec.activityType else { return false }
        let payload: PlaybackHandoff
        do {
            payload = try PlaybackHandoffCodec.decode(userInfo: activity.userInfo)
        } catch {
            let reason = (error as? PlaybackHandoffCodec.Failure)?.rawValue ?? "malformed"
            Self.handoffLog.notice("event=handoff_received outcome=rejected reason=\(reason, privacy: .public)")
            return false
        }
        guard payload.senderID != Self.handoffSenderID else {
            Self.handoffLog.debug("event=handoff_received outcome=ignored reason=own_activity")
            return false
        }
        let applied = continuePlayback(from: payload.snapshot, at: payload.resumePosition(now: Date(), duration: nil),
                                       startPlaying: payload.wasPlaying, origin: .handoff)
        if applied { showToast("Picked up from your other device.") }
        return applied
    }
}
