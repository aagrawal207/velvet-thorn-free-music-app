import Foundation

/// Decides when the live player should jump over a known segment. Pure state driven by the controller's tick;
/// the controller performs the seek and owns the listening clock.
struct SegmentSkipper: Sendable {
    /// Positions this close to a segment's end are left alone: the remainder is shorter than a tick.
    static let endGuard: TimeInterval = 0.25
    /// A manual seek means the listener chose that position; nothing skips until the grace has passed.
    static let manualSeekGrace: TimeInterval = 10

    private(set) var segments: [SponsorBlockSegment]
    private(set) var skippedCount = 0
    private var consumed: Set<SponsorBlockSegment> = []
    private var manualSeekUptime: TimeInterval?

    init(segments: [SponsorBlockSegment] = []) {
        self.segments = segments
    }

    /// Replaces the segments for the current play. The seek grace survives because it describes the listener, not the data.
    mutating func install(_ segments: [SponsorBlockSegment]) {
        self.segments = segments
        consumed = []
        skippedCount = 0
    }

    /// A fresh play of the same recording may skip every segment once more.
    mutating func restart() {
        consumed = []
        skippedCount = 0
        manualSeekUptime = nil
    }

    mutating func noteManualSeek(uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        manualSeekUptime = uptime
    }

    /// The segment to leave from `position`, or nil. A returned segment is consumed, so seeking back into it later
    /// plays it through; the caller seeks to its `end`.
    mutating func skipTarget(at position: TimeInterval, uptime: TimeInterval) -> SponsorBlockSegment? {
        guard position.isFinite, uptime.isFinite else { return nil }
        if let manualSeekUptime, uptime - manualSeekUptime < Self.manualSeekGrace { return nil }
        guard let segment = segments.first(where: {
            !consumed.contains($0) && position >= $0.start && position <= $0.end - Self.endGuard
        }) else { return nil }
        consumed.insert(segment)
        skippedCount += 1
        return segment
    }
}
