import Foundation

struct WatchSnapshotState {
    enum Source: Equatable { case reply, applicationContext }

    static let confirmationLifetime: TimeInterval = 20

    private(set) var snapshot: CompanionSnapshot?
    private var confirmedAt: TimeInterval?
    private var canMessage = false
    private var foreground = false
    private var anchorPosition: Double = 0
    private var anchorUptime: TimeInterval = 0
    private var retiredSessions: [UUID: TimeInterval] = [:]

    mutating func setAvailability(reachable: Bool, foreground: Bool, at uptime: TimeInterval) {
        anchorPosition = position(at: uptime)
        anchorUptime = uptime
        if !reachable || !foreground { confirmedAt = nil }
        canMessage = reachable
        self.foreground = foreground
    }

    mutating func invalidate(at uptime: TimeInterval) {
        anchorPosition = position(at: uptime)
        anchorUptime = uptime
        confirmedAt = nil
    }

    @discardableResult
    mutating func receive(_ incoming: CompanionSnapshot, source: Source, at uptime: TimeInterval) -> Bool {
        // Retain retired processes beyond the client's eight-second reply deadline, including concurrent read replies.
        retiredSessions = retiredSessions.filter { uptime - $0.value < Self.confirmationLifetime }
        if retiredSessions[incoming.sessionID] != nil { return false }
        if let current = snapshot {
            // Cached contexts cannot establish a different phone process; a correlated live reply must confirm it.
            if current.sessionID != incoming.sessionID, source == .applicationContext { return false }
            if current.sessionID == incoming.sessionID, incoming.sequence <= current.sequence {
                if source == .reply, canMessage, foreground {
                    anchorPosition = incoming.sequence == current.sequence && confirmedAt == nil
                        ? Self.boundedPosition(incoming.nowPlaying?.position ?? 0, duration: incoming.nowPlaying?.duration ?? 0)
                        : position(at: uptime)
                    anchorUptime = uptime
                    confirmedAt = uptime
                }
                return false
            }
            if current.sessionID != incoming.sessionID { retiredSessions[current.sessionID] = uptime }
        }
        if snapshot?.sessionID != incoming.sessionID { confirmedAt = nil }
        snapshot = incoming
        anchorPosition = Self.boundedPosition(incoming.nowPlaying?.position ?? 0, duration: incoming.nowPlaying?.duration ?? 0)
        anchorUptime = uptime
        if source == .reply, canMessage, foreground { confirmedAt = uptime }
        return true
    }

    func isCurrent(at uptime: TimeInterval) -> Bool {
        guard canMessage, foreground, let confirmedAt, snapshot != nil else { return false }
        return uptime >= confirmedAt && uptime - confirmedAt < Self.confirmationLifetime
    }

    func isPlaying(at uptime: TimeInterval) -> Bool {
        guard isCurrent(at: uptime), let track = snapshot?.nowPlaying else { return false }
        return track.isPlaying && !track.isLoading && track.errorMessage == nil
    }

    func position(at uptime: TimeInterval) -> Double {
        guard let track = snapshot?.nowPlaying else { return 0 }
        var position = anchorPosition
        if canMessage, foreground, track.isPlaying, !track.isLoading, track.errorMessage == nil,
           let confirmedAt {
            let end = min(uptime, confirmedAt + Self.confirmationLifetime)
            position += max(0, end - anchorUptime)
        }
        return Self.boundedPosition(position, duration: track.duration)
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(min(seconds, 359_999))
        if whole >= 3_600 { return String(format: "%d:%02d:%02d", whole / 3_600, whole / 60 % 60, whole % 60) }
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private static func boundedPosition(_ position: Double, duration: Double) -> Double {
        guard position.isFinite else { return 0 }
        if duration.isFinite, duration > 0 { return max(0, min(position, duration)) }
        return max(0, position)
    }
}
