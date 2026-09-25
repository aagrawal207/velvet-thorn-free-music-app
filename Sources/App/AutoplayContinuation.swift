import Foundation

/// Attempt policy for ordinary-queue Autoplay: which seeds to ask, how many provider calls, and how a dead end reads.
/// Radio sessions keep their own continuation state and never use this.
enum AutoplayContinuation {
    /// Songs appended per exhaustion event at most.
    static let limit = 20
    /// Fewer usable songs than this from the ending song's radio earns one alternative seed.
    static let minimumBatch = 5
    /// The ending song, one alternative queue seed, one fresh retry of the ending song.
    static let maximumProviderCalls = 3
    /// Gap before the fresh retry so a momentary provider hiccup has passed; host cooldowns stay with the transport.
    static let retryDelay: Duration = .seconds(1)

    enum Failure: String, Sendable {
        case empty, busy, unreachable

        var message: String {
            switch self {
            case .empty: "Couldn’t find more songs to play."
            case .busy: "Autoplay paused because the music service is busy. Try again in a moment."
            case .unreachable: "Autoplay couldn’t load more songs. Check your connection and try again."
            }
        }
    }

    /// The listener's most recently played queue song other than the ending one, else the nearest earlier song.
    /// Autoplay's own additions seed only when nothing the listener chose remains.
    static func fallbackSeed(queue: [Track], after last: Track, recentIDs: [String], autoplayIDs: Set<String>,
                             disliked: Set<String>) -> Track? {
        let candidates = queue.filter { $0.id != last.id && !disliked.contains($0.id) && $0.isAudioRecording != false }
        let chosen = candidates.filter { !autoplayIDs.contains($0.id) }
        let pool = chosen.isEmpty ? candidates : chosen
        let ids = Set(pool.map(\.id))
        if let recent = recentIDs.first(where: { ids.contains($0) }) { return pool.last { $0.id == recent } }
        return pool.last
    }

    /// A host cooldown fails every further call before it leaves the device.
    static func endsAttempts(_ error: any Error) -> Bool { isRateLimited(error) }

    /// Transport and provider failures may pass on a fresh request; cooldowns and cancellation cannot.
    static func allowsFreshRetry(_ error: any Error) -> Bool {
        if error is CancellationError || isRateLimited(error) { return false }
        return error is MusicServiceError || error is URLError
    }

    /// `primarySucceeded` means the ending song's radio answered; its dead end is exhaustion, not an outage.
    static func failure(primarySucceeded: Bool, errors: [any Error]) -> Failure {
        if errors.contains(where: isRateLimited) { return .busy }
        return primarySucceeded ? .empty : .unreachable
    }

    private static func isRateLimited(_ error: any Error) -> Bool {
        if case .rateLimited? = error as? MusicServiceError { return true }
        return false
    }
}
