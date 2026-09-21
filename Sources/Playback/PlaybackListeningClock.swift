import Foundation

struct PlaybackListeningClock {
    private var lastPosition: TimeInterval?
    private var lastUptime: TimeInterval?
    private var wasAdvancing = false
    private(set) var pending: TimeInterval = 0

    @discardableResult
    mutating func sample(position: TimeInterval, uptime: TimeInterval, advancing: Bool) -> TimeInterval {
        guard position.isFinite, position >= 0, uptime.isFinite else {
            discontinuity()
            return 0
        }
        defer {
            lastPosition = position
            lastUptime = uptime
            wasAdvancing = advancing
        }
        guard wasAdvancing, let lastPosition, let lastUptime else { return 0 }
        let mediaDelta = position - lastPosition
        let wallDelta = uptime - lastUptime
        // Wall time caps credit; implausible timeline jumps are seeks, never listening.
        guard wallDelta > 0, mediaDelta > 0, mediaDelta <= wallDelta + 0.25 else { return 0 }
        let delta = min(mediaDelta, wallDelta)
        pending += delta
        return delta
    }

    mutating func discontinuity() {
        lastPosition = nil
        lastUptime = nil
        wasAdvancing = false
    }

    mutating func drain() -> TimeInterval {
        let delta = pending
        pending = 0
        return delta
    }
}

/// Unacknowledged deltas retain the original listening session even after playback moves to another song.
struct PlaybackListeningBuffer {
    static let defaultMaximumSessions = 128
    let maximumSessions: Int
    private(set) var checkpoints: [ListeningEvent] = []

    init(maximumSessions: Int = PlaybackListeningBuffer.defaultMaximumSessions) {
        self.maximumSessions = max(1, maximumSessions)
    }

    func canRecord(sessionID: UUID) -> Bool {
        checkpoints.count < maximumSessions || checkpoints.contains { $0.id == sessionID }
    }

    mutating func append(_ checkpoint: ListeningEvent) -> Bool {
        guard checkpoint.listenedSeconds.isFinite, checkpoint.listenedSeconds > 0 else { return false }
        if let index = checkpoints.firstIndex(where: { $0.id == checkpoint.id }) {
            guard checkpoints[index].track.id == checkpoint.track.id,
                  checkpoints[index].startedAt == checkpoint.startedAt else { return false }
            let total = checkpoints[index].listenedSeconds + checkpoint.listenedSeconds
            guard total.isFinite else { return false }
            checkpoints[index].listenedSeconds = total
        } else {
            guard checkpoints.count < maximumSessions else { return false }
            checkpoints.append(checkpoint)
        }
        return true
    }

    mutating func acknowledge(_ checkpoint: ListeningEvent) {
        guard let index = checkpoints.firstIndex(where: { $0.id == checkpoint.id }),
              checkpoints[index].track.id == checkpoint.track.id, checkpoints[index].startedAt == checkpoint.startedAt,
              checkpoint.listenedSeconds > 0, checkpoint.listenedSeconds <= checkpoints[index].listenedSeconds else { return }
        checkpoints[index].listenedSeconds -= checkpoint.listenedSeconds
        if checkpoints[index].listenedSeconds == 0 { checkpoints.remove(at: index) }
    }

    mutating func discard() { checkpoints.removeAll() }
}

struct PlaybackInterruption {
    private(set) var active = false
    private var resumeGeneration: UInt64?

    mutating func begin(wantsPlayback: Bool, generation: UInt64) {
        guard !active else { return }
        active = true
        resumeGeneration = wantsPlayback ? generation : nil
    }

    mutating func cancelResume() { resumeGeneration = nil }

    mutating func end(shouldResume: Bool, generation: UInt64) -> Bool {
        let resume = active && shouldResume && resumeGeneration == generation
        active = false
        resumeGeneration = nil
        return resume
    }
}
