import BackgroundTasks
import Foundation
import OSLog

/// Overnight regeneration of Discover Weekly and the Daily Mixes so a new day or ISO week can have its mixes before
/// Home opens. Opportunistic like release refresh: iOS may run it late or never, so `loadHome` stays primary.
@MainActor
enum MixRefreshRegistration {
    static let identifier = "com.agraabhi.ganabajana.mixes"
    /// Local hour for `earliestBeginDate`: the period keys roll at midnight (Monday's also rolls the ISO week) and
    /// the device is usually idle and charging by then.
    static let refreshHour = 4

    // Same BGTask boundary as release refresh; one handle type keeps both registrations testable the same way.
    typealias TaskHandle = ReleaseRefreshRegistration.TaskHandle
    typealias LaunchHandler = ReleaseRefreshRegistration.LaunchHandler
    typealias Registrar = ReleaseRefreshRegistration.Registrar
    typealias Submitter = @MainActor (_ identifier: String, _ earliestBeginDate: Date) throws -> Void

    /// The next `refreshHour` local strictly after `now`. Calendar arithmetic keeps the wall-clock hour across DST
    /// changes; a fixed 86,400-second step would drift by an hour twice a year.
    static func nextRefreshDate(after now: Date, calendar: Calendar) -> Date {
        let target = DateComponents(hour: refreshHour, minute: 0, second: 0)
        return calendar.nextDate(after: now, matching: target, matchingPolicy: .nextTime, direction: .forward)
            ?? calendar.date(byAdding: .day, value: 1, to: now)
            ?? now
    }

    @discardableResult
    static func register(identifier: String = MixRefreshRegistration.identifier, registrar: Registrar? = nil,
                         operation: @escaping @MainActor () async -> Bool,
                         reschedule: @escaping @MainActor () -> Void) -> Bool {
        let register = registrar ?? registerWithSystem
        // The SDK callback inherits main-actor isolation; its queue must match before the callback enters.
        return register(identifier, .main) { handle in
            let work = Task { @MainActor in
                var refreshed = false
                if !Task.isCancelled { refreshed = await operation() }
                reschedule()
                // An expired run reports failure even when the operation returned true after cancellation.
                handle.complete(refreshed && !Task.isCancelled)
            }
            handle.installExpiration { @Sendable in work.cancel() }
        }
    }

    /// Submits (or replaces) the pending request for the next refresh date. iOS may refuse, coalesce or drop it, so
    /// callers never wait on the result.
    @discardableResult
    static func schedule(identifier: String = MixRefreshRegistration.identifier, now: Date = Date(),
                         calendar: Calendar = .autoupdatingCurrent, submitter: Submitter? = nil) -> Bool {
        let submit = submitter ?? submitToSystem
        do {
            try submit(identifier, nextRefreshDate(after: now, calendar: calendar))
            return true
        } catch {
            return false
        }
    }

    private static func registerWithSystem(identifier: String, queue: DispatchQueue,
                                           launch: @escaping LaunchHandler) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: queue) { task in
            launch(TaskHandle(installExpiration: { task.expirationHandler = $0 },
                              complete: { task.setTaskCompleted(success: $0) }))
        }
    }

    private static func submitToSystem(identifier: String, earliestBeginDate: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
}

extension MusicAppModel {
    /// Background-task entry: regenerates stale mixes exactly like a Home load and reports whether both
    /// current-period mixes exist afterwards. Cancelling the caller cancels the shared generation task.
    func refreshMixesForBackgroundTask() async -> Bool {
        let status: String
        if let pending = refreshMixes() {
            await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
            status = Task.isCancelled ? "expired" : "ran"
        } else {
            status = "skipped"
        }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let weekly = discoverWeekly?.periodKey == RecommendationEngine.weekKey(for: now, calendar: calendar)
        let daily = dailyMix?.periodKey == RecommendationEngine.dayKey(for: now, calendar: calendar)
        RecommendationEngine.discoveryLog.info("event=mix_background_refresh status=\(status, privacy: .public) weekly=\(weekly ? 1 : 0, privacy: .public) daily=\(daily ? 1 : 0, privacy: .public)")
        return weekly && daily
    }
}
