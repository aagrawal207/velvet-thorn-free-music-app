import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class MixRefreshRegistrationTests: XCTestCase {
    // MARK: Schedule rule

    func testNextRefreshDateFromLateSundayIsMondayAtFourInTheNewWeek() {
        let calendar = libraryTestCalendar(timeZone: "Asia/Kolkata")
        let sunday = moment(2026, 9, 27, 23, 30, in: calendar)
        let next = MixRefreshRegistration.nextRefreshDate(after: sunday, calendar: calendar)
        XCTAssertEqual(next, moment(2026, 9, 28, 4, in: calendar))
        XCTAssertEqual(calendar.component(.weekday, from: next), 2, "Monday")
        XCTAssertNotEqual(RecommendationEngine.weekKey(for: next, calendar: calendar),
                          RecommendationEngine.weekKey(for: sunday, calendar: calendar))
        XCTAssertNotEqual(RecommendationEngine.dayKey(for: next, calendar: calendar),
                          RecommendationEngine.dayKey(for: sunday, calendar: calendar))
    }

    func testNextRefreshDateFromMondayMorningIsTuesdayAtFour() {
        let calendar = libraryTestCalendar(timeZone: "Asia/Kolkata")
        let monday = moment(2026, 9, 28, 5, in: calendar)
        XCTAssertEqual(MixRefreshRegistration.nextRefreshDate(after: monday, calendar: calendar),
                       moment(2026, 9, 29, 4, in: calendar))
        XCTAssertEqual(MixRefreshRegistration.nextRefreshDate(after: moment(2026, 9, 28, 4, in: calendar), calendar: calendar),
                       moment(2026, 9, 29, 4, in: calendar), "Exactly 04:00 is not strictly after itself")
    }

    func testNextRefreshDateBeforeFourStaysOnTheSameDay() {
        let calendar = libraryTestCalendar(timeZone: "Asia/Kolkata")
        XCTAssertEqual(MixRefreshRegistration.nextRefreshDate(after: moment(2026, 9, 28, 2, in: calendar), calendar: calendar),
                       moment(2026, 9, 28, 4, in: calendar), "Today's mixes are still stale at 02:00, so the same morning qualifies")
    }

    func testNextRefreshDateKeepsTheLocalHourAcrossDaylightSavingChanges() {
        let calendar = libraryTestCalendar(timeZone: "America/New_York")
        let beforeSpringForward = moment(2026, 3, 7, 23, 30, in: calendar)
        let spring = MixRefreshRegistration.nextRefreshDate(after: beforeSpringForward, calendar: calendar)
        XCTAssertEqual(spring, moment(2026, 3, 8, 4, in: calendar))
        XCTAssertEqual(spring.timeIntervalSince(beforeSpringForward), 3.5 * 3600, accuracy: 0.001,
                       "Clocks skip 02:00 to 03:00, so 04:00 arrives after 3.5 real hours, not 4.5")
        let beforeFallBack = moment(2026, 10, 31, 23, 30, in: calendar)
        let fall = MixRefreshRegistration.nextRefreshDate(after: beforeFallBack, calendar: calendar)
        XCTAssertEqual(fall, moment(2026, 11, 1, 4, in: calendar))
        XCTAssertEqual(fall.timeIntervalSince(beforeFallBack), 5.5 * 3600, accuracy: 0.001)
    }

    func testScheduleSubmitsTheMixIdentifierForTheNextRefreshDateAndReportsRefusals() {
        let calendar = libraryTestCalendar(timeZone: "Asia/Kolkata")
        let now = moment(2026, 9, 28, 5, in: calendar)
        var identifiers: [String] = []
        var dates: [Date] = []
        XCTAssertTrue(MixRefreshRegistration.schedule(now: now, calendar: calendar, submitter: { identifier, date in
            identifiers.append(identifier)
            dates.append(date)
        }))
        XCTAssertEqual(identifiers, ["com.agraabhi.ganabajana.mixes"])
        XCTAssertEqual(dates, [moment(2026, 9, 29, 4, in: calendar)])
        struct Refused: Error {}
        XCTAssertFalse(MixRefreshRegistration.schedule(now: now, calendar: calendar, submitter: { _, _ in throw Refused() }))
    }

    // MARK: Task handler

    func testHandlerUsesTheMainQueueAndCompletesWithTheOperationResultAfterRescheduling() async throws {
        var identifier: String?
        var queue: DispatchQueue?
        var launch: MixRefreshRegistration.LaunchHandler?
        var expiration: (@Sendable () -> Void)?
        var trace: [String] = []
        var completions: [Bool] = []
        let registered = MixRefreshRegistration.register(registrar: { id, target, handler in
            identifier = id
            queue = target
            launch = handler
            return true
        }, operation: {
            XCTAssertTrue(Thread.isMainThread)
            trace.append("refresh")
            return true
        }, reschedule: {
            trace.append("schedule")
        })
        XCTAssertTrue(registered)
        XCTAssertEqual(identifier, "com.agraabhi.ganabajana.mixes")
        let target = try XCTUnwrap(queue)
        XCTAssertTrue(target === DispatchQueue.main)
        let callback = try XCTUnwrap(launch)
        let handle = MixRefreshRegistration.TaskHandle(installExpiration: { expiration = $0 }, complete: {
            trace.append("complete")
            completions.append($0)
        })
        target.async { MainActor.assumeIsolated { callback(handle) } }
        try await PlaybackTestSupport.waitUntil { completions.count == 1 }
        XCTAssertNotNil(expiration)
        XCTAssertEqual(trace, ["refresh", "schedule", "complete"])
        XCTAssertEqual(completions, [true])
    }

    func testHandlerReportsAFailedRefreshAndStillReschedules() async throws {
        var launch: MixRefreshRegistration.LaunchHandler?
        var completed: [Bool] = []
        var reschedules = 0
        XCTAssertTrue(MixRefreshRegistration.register(registrar: { _, _, handler in
            launch = handler
            return true
        }, operation: { false }, reschedule: { reschedules += 1 }))
        let callback = try XCTUnwrap(launch)
        callback(MixRefreshRegistration.TaskHandle(installExpiration: { _ in }, complete: { completed.append($0) }))
        try await PlaybackTestSupport.waitUntil { completed.count == 1 }
        XCTAssertEqual(completed, [false])
        XCTAssertEqual(reschedules, 1)
    }

    func testExpirationCancelsTheRefreshAndCompletesWithFailureAfterRescheduling() async throws {
        var launch: MixRefreshRegistration.LaunchHandler?
        var expiration: (@Sendable () -> Void)?
        var completed: [Bool] = []
        var reschedules = 0
        var started = false
        var observedCancellation = false
        XCTAssertTrue(MixRefreshRegistration.register(registrar: { _, queue, handler in
            XCTAssertTrue(queue === DispatchQueue.main)
            launch = handler
            return true
        }, operation: {
            started = true
            do { try await Task.sleep(for: .seconds(30)) } catch { observedCancellation = Task.isCancelled }
            // A late true must not turn an expired run into a success.
            return true
        }, reschedule: { reschedules += 1 }))
        let callback = try XCTUnwrap(launch)
        callback(MixRefreshRegistration.TaskHandle(installExpiration: { expiration = $0 }, complete: { completed.append($0) }))
        try await PlaybackTestSupport.waitUntil { started }
        let expire = try XCTUnwrap(expiration)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                XCTAssertFalse(Thread.isMainThread)
                expire()
                continuation.resume()
            }
        }
        try await PlaybackTestSupport.waitUntil { completed.count == 1 }
        XCTAssertTrue(observedCancellation)
        XCTAssertEqual(completed, [false])
        XCTAssertEqual(reschedules, 1)
    }

    // MARK: Model hook

    func testBackgroundRefreshOnAColdProfileReturnsFalseWithoutProviderRequests() async throws {
        let context = try makeContext()
        let refreshed = await context.model.refreshMixesForBackgroundTask()
        XCTAssertFalse(refreshed)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertFalse(context.model.hasListeningProfile)
        XCTAssertTrue(context.library.mixes.isEmpty)
        let radios = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertTrue(radios.isEmpty)
        XCTAssertTrue(artists.isEmpty)
    }

    func testBackgroundRefreshReturnsFalseWhileMixGenerationIsDisabled() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let refreshed = await context.model.refreshMixesForBackgroundTask()
        XCTAssertFalse(refreshed)
        XCTAssertTrue(context.library.mixes.isEmpty)
        let radios = await context.catalog.autoplayRadios.requests
        XCTAssertTrue(radios.isEmpty)
    }

    func testBackgroundRefreshReturnsTrueOnceBothCurrentPeriodMixesAreSaved() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let run = Task { @MainActor in await context.model.refreshMixesForBackgroundTask() }
        let weekly = try await pendingHarvest(in: context, at: 0)
        XCTAssertTrue(context.model.isGeneratingMixes)
        let fresh = candidates("fresh")
        try await complete(weekly, with: fresh, in: context)
        let daily = try await pendingHarvest(in: context, at: 1)
        try await complete(daily, with: fresh, in: context)
        let refreshed = await run.value
        XCTAssertTrue(refreshed)
        let calendar = Calendar.autoupdatingCurrent
        XCTAssertEqual(context.model.discoverWeekly?.periodKey, RecommendationEngine.weekKey(for: Date(), calendar: calendar))
        XCTAssertEqual(context.model.dailyMix?.periodKey, RecommendationEngine.dayKey(for: Date(), calendar: calendar))
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertNil(context.library.errorMessage)

        // Current-period mixes make the next run a request-free no-op that still counts as a success.
        let requestsBefore = await context.catalog.autoplayRadios.requests.count
        let again = await context.model.refreshMixesForBackgroundTask()
        XCTAssertTrue(again)
        let requestsAfter = await context.catalog.autoplayRadios.requests.count
        XCTAssertEqual(requestsAfter, requestsBefore)
    }

    func testCancelledBackgroundRefreshStopsGenerationAndReturnsFalse() async throws {
        let context = try makeContext()
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let run = Task { @MainActor in await context.model.refreshMixesForBackgroundTask() }
        let weekly = try await pendingHarvest(in: context, at: 0)
        XCTAssertTrue(context.model.isGeneratingMixes)
        run.cancel()
        for request in weekly.radios {
            try await AppModelFixtures.eventually { await context.catalog.autoplayRadios.cancellations.contains(request.id) }
        }
        try await AppModelFixtures.eventually { await context.catalog.artists.cancellations.contains(weekly.artist.id) }
        try await complete(weekly, with: candidates("late"), in: context)
        let refreshed = await run.value
        XCTAssertFalse(refreshed)
        XCTAssertTrue(context.library.mixes.isEmpty, "Cancelled work must not publish a mix")
        XCTAssertFalse(context.model.isGeneratingMixes)
        let radios = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertEqual(radios.count, 2, "Cancelled weekly work must not start the daily phase")
        XCTAssertEqual(artists.count, 1)
    }

    // MARK: Support

    private struct Harvest {
        let radios: [AppModelRequestGate<Track, [Track]>.Request]
        let artist: AppModelRequestGate<String, ArtistPage>.Request
    }

    /// `seedListener` supplies two recordings and one linked artist per mix phase, with no related-artist fan-out.
    private func pendingHarvest(in context: AppModelTestContext, at index: Int) async throws -> Harvest {
        let radios = [try await context.catalog.autoplayRadios.request(at: index * 2),
                      try await context.catalog.autoplayRadios.request(at: index * 2 + 1)]
        let artist = try await context.catalog.artists.request(at: index)
        return Harvest(radios: radios, artist: artist)
    }

    private func complete(_ harvest: Harvest, with tracks: [Track], in context: AppModelTestContext) async throws {
        for request in harvest.radios { try await context.catalog.autoplayRadios.complete(request, with: .success(tracks)) }
        try await context.catalog.artists.complete(harvest.artist, with: .success(context.artistPage(harvest.artist.input, songs: tracks)))
    }

    private func candidates(_ prefix: String) -> [Track] {
        (0..<12).map { RecommendationFixtures.track("\(prefix)-\($0)", artist: "\(prefix) artist \($0)", language: .english) }
    }

    private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext(generatesMixes: true)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
