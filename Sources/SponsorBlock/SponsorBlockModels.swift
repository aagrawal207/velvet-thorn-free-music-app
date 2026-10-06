import Foundation

/// The categories Velvet Thorn requests from SponsorBlock. Unknown categories in a response never reach the skipper.
enum SponsorBlockCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case musicOfftopic = "music_offtopic"
    case sponsor, selfpromo, intro, outro, interaction, preview

    /// Bounded log value: the music-relevant categories keep their names, everything else folds into "other".
    var logValue: String {
        switch self {
        case .musicOfftopic, .sponsor, .selfpromo: rawValue
        case .intro, .outro, .interaction, .preview: "other"
        }
    }
}

/// One stretch of a YouTube upload to jump over, in seconds from the start of the recording.
struct SponsorBlockSegment: Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var category: SponsorBlockCategory

    var duration: TimeInterval { end - start }
}

/// A community submission as the API describes it, before Velvet Thorn applies its own eligibility rules.
struct SponsorBlockSubmission: Equatable, Sendable {
    var category: String
    var actionType: String
    var start: TimeInterval
    var end: TimeInterval
    var votes: Int
    var locked: Bool
    var videoDuration: TimeInterval?
}

enum SponsorBlockSegments {
    static let minimumDuration: TimeInterval = 1
    /// A submission covering most of the recording is a mislabelled song, not a section to skip.
    static let maximumCoverage = 0.8
    static let maximumCount = 32

    /// Keeps skip submissions with non-negative votes or a lock, at least 1 s long and under 80% of the track,
    /// then merges overlaps. `duration` is the player's known length; a submission's own `videoDuration` is the fallback.
    static func usable(_ submissions: [SponsorBlockSubmission], duration: TimeInterval?) -> [SponsorBlockSegment] {
        let known = PlaybackTiming.validDuration(duration)
        let candidates = submissions.compactMap { submission -> SponsorBlockSegment? in
            guard submission.actionType == "skip", submission.votes >= 0 || submission.locked,
                  let category = SponsorBlockCategory(rawValue: submission.category),
                  submission.start.isFinite, submission.end.isFinite, submission.start >= 0,
                  submission.end - submission.start >= minimumDuration else { return nil }
            let segment = SponsorBlockSegment(start: submission.start, end: submission.end, category: category)
            guard covers(segment, within: known ?? PlaybackTiming.validDuration(submission.videoDuration)) else { return nil }
            return segment
        }
        var merged: [SponsorBlockSegment] = []
        for segment in candidates.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = merged.last, segment.start <= last.end {
                merged[merged.count - 1].end = max(last.end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        let fallbackDuration = submissions.compactMap { PlaybackTiming.validDuration($0.videoDuration) }.max()
        return Array(merged.filter { covers($0, within: known ?? fallbackDuration) }.prefix(maximumCount))
    }

    /// Unknown total length cannot prove overreach, so the coverage rule only applies when a duration exists.
    private static func covers(_ segment: SponsorBlockSegment, within duration: TimeInterval?) -> Bool {
        guard let duration else { return true }
        return segment.duration <= duration * maximumCoverage
    }
}
