import Foundation

/// Credited listening for the current session; a session ends with at most one signal.
struct ListeningSignalSession {
    private(set) var seconds: TimeInterval = 0
    private(set) var isClosed = false

    mutating func credit(_ delta: TimeInterval) {
        guard delta.isFinite, delta > 0, (seconds + delta).isFinite else { return }
        seconds += delta
    }

    /// False once the session has already ended, so a later transition cannot add a second signal.
    mutating func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        return true
    }
}

/// Skip times on the monotonic clock, kept only for this process.
struct ListeningSignalSkipWindow {
    private var times: [TimeInterval] = []

    /// Records one skip and reports whether it is at least the `rapidCount`th inside `rapidWindow`.
    mutating func record(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite else { return false }
        times.removeAll { $0 > uptime || uptime - $0 > ListeningSignalWeights.rapidWindow }
        times.append(uptime)
        if times.count > ListeningSignalWeights.rapidCount {
            times.removeFirst(times.count - ListeningSignalWeights.rapidCount)
        }
        return times.count >= ListeningSignalWeights.rapidCount
    }
}

extension ListeningSignal {
    /// Bounded metric value for the skip's base strength; origin and rapid context are logged separately.
    var strengthName: String {
        guard ending == .skipped else { return "none" }
        switch ListeningSignalWeights.skipStrength(listenedSeconds: listenedSeconds, duration: duration) {
        case ListeningSignalWeights.strongSkip: return "strong"
        case ListeningSignalWeights.mildSkip: return "mild"
        case ListeningSignalWeights.lightSkip: return "light"
        default: return "none"
        }
    }
}
