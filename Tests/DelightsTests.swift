import Foundation
import XCTest
@testable import GanaBajana

/// The hidden delights: pure rules first, then the model hooks that deliver them. docs/DELIGHTS.md maps each case to
/// its trigger, copy and flag.
@MainActor
final class DelightsTests: XCTestCase {
    private let utc = libraryTestCalendar(timeZone: "UTC")

    // MARK: Equalizer

    func testEqualizerLineNeedsEveryBandAtOneEndOfTheRange() {
        let bands = EqualizerPreset.bandFrequencies.count
        XCTAssertEqual(EqualizerExtreme(gains: Array(repeating: 12, count: bands)), .maximum)
        XCTAssertEqual(EqualizerExtreme(gains: Array(repeating: -12, count: bands)), .minimum)
        var almost = Array(repeating: 12.0, count: bands)
        almost[bands - 1] = 11.5
        XCTAssertNil(EqualizerExtreme(gains: almost), "One band off the top keeps the line hidden")
        XCTAssertNil(EqualizerExtreme(gains: Array(repeating: 12, count: 5) + Array(repeating: -12, count: 5)))
        XCTAssertNil(EqualizerExtreme(gains: Array(repeating: 0, count: bands)))
        XCTAssertNil(EqualizerExtreme(gains: Array(repeating: 12, count: bands - 1)), "A partial curve never qualifies")
        XCTAssertNil(EqualizerExtreme(gains: []))

        // Both pages reach it: Advanced band by band, Simple with equal Bass, Mids and Treble.
        var settings = EqualizerSettings()
        for band in 0..<bands { settings.setGain(12, band: band) }
        XCTAssertEqual(EqualizerExtreme(gains: settings.effectiveGains), .maximum)
        XCTAssertEqual(EqualizerExtreme(gains: SimpleEqualizer.gains(bass: -12, mids: -12, treble: -12)), .minimum)
        XCTAssertNil(EqualizerExtreme(gains: EqualizerPreset.loudness.gains), "No built-in preset sits at an end")

        XCTAssertEqual(EqualizerExtreme.maximum.message, "Every band at max. Your neighbours have been notified.")
        XCTAssertEqual(EqualizerExtreme.minimum.message, "Every band at minimum. Bold of you to call this music.")
        XCTAssertEqual(EqualizerExtreme.maximum.kind.rawValue, "equalizerMax")
        XCTAssertEqual(EqualizerExtreme.minimum.kind.rawValue, "equalizerMin")
    }

    // MARK: Late night

    func testLateNightLineCoversTwoToFourLocalTime() {
        XCTAssertNil(LateNightEyebrow.line(at: date(2026, 10, 3, 1, 59, 59), calendar: utc))
        XCTAssertNotNil(LateNightEyebrow.line(at: date(2026, 10, 3, 2, 0), calendar: utc))
        XCTAssertNotNil(LateNightEyebrow.line(at: date(2026, 10, 3, 3, 59, 59), calendar: utc))
        XCTAssertNil(LateNightEyebrow.line(at: date(2026, 10, 3, 4, 0), calendar: utc))
        XCTAssertNil(LateNightEyebrow.line(at: date(2026, 10, 3, 14, 0), calendar: utc))

        // The window follows the listener's clock: 21:00 UTC is 2:30 in Kolkata.
        let instant = date(2026, 10, 2, 21, 0)
        XCTAssertNil(LateNightEyebrow.line(at: instant, calendar: utc))
        XCTAssertNotNil(LateNightEyebrow.line(at: instant, calendar: libraryTestCalendar(timeZone: "Asia/Kolkata")))
    }

    func testLateNightLineStaysForTheNightAndMovesOnTheNextNight() throws {
        let early = try XCTUnwrap(LateNightEyebrow.line(at: date(2026, 10, 3, 2, 0), calendar: utc))
        let late = try XCTUnwrap(LateNightEyebrow.line(at: date(2026, 10, 3, 3, 59), calendar: utc))
        XCTAssertEqual(early.option, late.option, "One night keeps one line")
        let nextNight = try XCTUnwrap(LateNightEyebrow.line(at: date(2026, 10, 4, 2, 0), calendar: utc))
        XCTAssertNotEqual(nextNight.option, early.option)

        var options = Set<Int>()
        for day in 1...LateNightEyebrow.optionCount {
            let line = try XCTUnwrap(LateNightEyebrow.line(at: date(2026, 11, day, 2, 15), calendar: utc))
            options.insert(line.option)
            XCTAssertEqual(line.text, line.text.uppercased(), "The eyebrow stays in capitals")
            XCTAssertFalse(line.spokenText.isEmpty, "VoiceOver reads a sentence-case line")
            XCTAssertFalse(line.text.contains("—") || line.spokenText.contains("—"))
            XCTAssertEqual(LateNightEyebrow.line(at: date(2026, 11, day, 2, 15), calendar: utc), line, "Deterministic")
        }
        XCTAssertEqual(options.count, LateNightEyebrow.optionCount, "Consecutive nights rotate through every line")

        // The bold-choice line names the hour it is shown in.
        let boldNight = try XCTUnwrap((1...LateNightEyebrow.optionCount).map { date(2026, 11, $0, 2, 15) }
            .first { LateNightEyebrow.line(at: $0, calendar: utc)?.option == 2 })
        XCTAssertEqual(LateNightEyebrow.line(at: boldNight, calendar: utc)?.text, "2 A.M. BOLD CHOICE")
        XCTAssertEqual(LateNightEyebrow.line(at: boldNight.addingTimeInterval(3_600), calendar: utc)?.text, "3 A.M. BOLD CHOICE")
    }

    // MARK: 100th like

    func testCenturyCelebratesTheExplicitLikeThatReachesOneHundredOnce() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let defaults = try makeDefaults()
        model.delights = DelightController(model: model, defaults: defaults)
        let songs = (1...100).map { libraryTestTrack("century-\($0)") }
        XCTAssertEqual(model.library.addFavorites(Array(songs.prefix(99))), 99)
        XCTAssertNil(model.toast, "Importing likes is not a celebration")

        model.toggleLike(songs[99], surface: .player)
        XCTAssertEqual(model.library.favorites.count, 100)
        XCTAssertEqual(model.toast, "Century! 100 liked songs. Sachin would be proud.")
        XCTAssertNotNil(model.delights.heartBurst, "The hearts fly with the toast")
        XCTAssertEqual(model.delights.toastSymbol(for: DelightCopy.likesCentury), "heart.fill")
        XCTAssertTrue(defaults.bool(forKey: DelightController.Key.likesCenturyShown))

        model.toast = nil
        model.toggleLike(songs[99], surface: .player)
        model.toggleLike(songs[99], surface: .menu)
        XCTAssertEqual(model.library.favorites.count, 100)
        XCTAssertNil(model.toast, "Once per installation")
        model.delights = DelightController(model: model, defaults: defaults)
        model.toggleLike(songs[99], surface: .library)
        model.toggleLike(songs[99], surface: .library)
        XCTAssertNil(model.toast, "A relaunched controller reads the saved flag")
    }

    func testCenturyIgnoresImportsAndPromotionsButCountsASuperLikedNewSong() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let defaults = try makeDefaults()
        model.delights = DelightController(model: model, defaults: defaults)
        let songs = (1...102).map { libraryTestTrack("hundred-\($0)") }
        XCTAssertEqual(model.library.addFavorites(Array(songs.prefix(100))), 100)
        XCTAssertNil(model.toast, "An import that lands on 100 stays quiet")
        model.toggleSuperLike(songs[0], surface: .player)
        XCTAssertTrue(model.library.isSuperLiked(songs[0]))
        XCTAssertNil(model.toast, "Promoting a liked song leaves the count at 100")
        model.toggleLike(songs[100], surface: .menu)
        XCTAssertEqual(model.library.favorites.count, 101)
        XCTAssertNil(model.toast, "Only exactly 100 counts")
        model.toggleLike(songs[100], surface: .menu)
        XCTAssertEqual(model.library.favorites.count, 100)
        XCTAssertNil(model.toast, "Unliking down to 100 is not a like")
        XCTAssertFalse(defaults.bool(forKey: DelightController.Key.likesCenturyShown))

        model.toggleLike(songs[1], surface: .menu)
        model.toggleSuperLike(songs[101], surface: .player)
        XCTAssertEqual(model.library.favorites.count, 100)
        XCTAssertEqual(model.toast, DelightCopy.likesCentury, "Super liking a new song is an explicit like too")
    }

    func testCenturyDuringLikeAllSongsKeepsTheBannerFromTheBulkConfirmation() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        model.delights = DelightController(model: model, defaults: try makeDefaults())
        let songs = (1...101).map { libraryTestTrack("like-all-\($0)") }
        XCTAssertEqual(model.library.addFavorites(Array(songs.prefix(98))), 98)
        XCTAssertFalse(model.delights.isShowingCentury)
        // The collection page's Like All Songs: one toggleLike per song, then a confirmation unless the century took the banner.
        for song in songs.suffix(3) where !model.library.isFavorite(song) { model.toggleLike(song, surface: .menu) }
        XCTAssertEqual(model.library.favorites.count, 101)
        XCTAssertTrue(model.delights.isShowingCentury, "Like All Songs skips its confirmation")
        XCTAssertEqual(model.toast, DelightCopy.likesCentury)
        model.toast = nil
        XCTAssertFalse(model.delights.isShowingCentury)
    }

    // MARK: Tenth repeat

    func testRepeatStreakCelebratesTheTenthStartInARowOnce() {
        var streak = RepeatStreak()
        let occurrence = UUID()
        let results = (1...20).map { _ in streak.trackStarted(trackID: "loop", occurrence: occurrence, repeatMode: .one) }
        XCTAssertEqual(results.firstIndex(of: true), 9, "The tenth start celebrates")
        XCTAssertEqual(results.filter { $0 }.count, 1, "Once per song per session")
        XCTAssertEqual(streak.count, 20)
    }

    func testRepeatStreakResetsOnAnotherSongAndIgnoresRepeatAll() {
        var streak = RepeatStreak()
        let first = UUID(), second = UUID()
        for _ in 1...9 { XCTAssertFalse(streak.trackStarted(trackID: "a", occurrence: first, repeatMode: .one)) }
        XCTAssertFalse(streak.trackStarted(trackID: "b", occurrence: second, repeatMode: .one), "Another song restarts the count")
        XCTAssertEqual(streak.count, 1)
        for _ in 1...9 { XCTAssertFalse(streak.trackStarted(trackID: "a", occurrence: first, repeatMode: .one)) }
        XCTAssertTrue(streak.trackStarted(trackID: "a", occurrence: first, repeatMode: .one))

        var looping = RepeatStreak()
        for _ in 1...15 { XCTAssertFalse(looping.trackStarted(trackID: "c", occurrence: second, repeatMode: .all)) }
        XCTAssertEqual(looping.count, 0, "Repeat All replays do not count")
        XCTAssertFalse(looping.trackStarted(trackID: "c", occurrence: nil, repeatMode: .one), "No occurrence, no streak")
        XCTAssertEqual(looping.count, 0)
    }

    func testRepeatStreakCountsThePlayThatTurnedRepeatOneOnAndEndsOnOtherModes() {
        var streak = RepeatStreak()
        let occurrence = UUID()
        XCTAssertFalse(streak.trackStarted(trackID: "a", occurrence: occurrence, repeatMode: .off))
        streak.repeatModeChanged(to: .one)
        XCTAssertEqual(streak.count, 1, "The play under way is the first of the streak")
        let results = (2...10).map { _ in streak.trackStarted(trackID: "a", occurrence: occurrence, repeatMode: .one) }
        XCTAssertEqual(results.last, true, "Ten starts in a row, counting that first play")
        XCTAssertEqual(results.filter { $0 }.count, 1)

        var interrupted = RepeatStreak()
        for _ in 1...5 { _ = interrupted.trackStarted(trackID: "b", occurrence: occurrence, repeatMode: .one) }
        interrupted.repeatModeChanged(to: .all)
        XCTAssertEqual(interrupted.count, 0, "Leaving Repeat One ends the streak")
        interrupted.repeatModeChanged(to: .one)
        XCTAssertEqual(interrupted.count, 1)
    }

    func testTenthRepeatOneStartShowsTheToastThroughThePlayerCallback() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        model.delights = DelightController(model: model, defaults: try makeDefaults())
        let song = AppModelFixtures.track("repeat-one")
        context.player.play([song])
        context.player.cycleRepeatMode()
        context.player.cycleRepeatMode()
        XCTAssertEqual(context.player.repeatMode, .one)
        // The streak hears mode changes through observation, one main-actor turn later.
        try await Task.sleep(for: .milliseconds(50))
        for start in 1...9 {
            context.player.onTrackStarted?(song)
            XCTAssertNil(model.toast, "Start \(start) is not ten in a row yet")
        }
        context.player.onTrackStarted?(song)
        XCTAssertEqual(model.toast, "Ten times in a row. The song is flattered. Slightly concerned, but flattered.")
        model.toast = nil
        for _ in 1...10 { context.player.onTrackStarted?(song) }
        XCTAssertNil(model.toast, "Each song is celebrated once per session")
    }

    // MARK: About

    func testAboutNeedsSevenQuickTapsAndTheSecondRoundChangesItsLine() {
        var counter = AboutTapCounter()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func tap(after gap: TimeInterval) -> String? {
            clock = clock.addingTimeInterval(gap)
            return counter.tap(at: clock)
        }
        for _ in 1...6 { XCTAssertNil(tap(after: 0.3)) }
        XCTAssertEqual(tap(after: 0.3), "There’s no secret menu. Nice try, though.")
        for _ in 1...6 { XCTAssertNil(tap(after: 0.4)) }
        XCTAssertEqual(tap(after: 0.4), "Still no secret menu. Persistence noted.")

        for _ in 1...14 { XCTAssertNil(tap(after: AboutTapCounter.maximumGap + 0.5), "Slow taps never finish a round") }
        // The last slow tap is tap one of a new round, so five quick taps reach six.
        for _ in 1...5 { XCTAssertNil(tap(after: 0.2)) }
        XCTAssertNil(tap(after: 3), "A pause restarts the count at one")
        for _ in 1...5 { XCTAssertNil(tap(after: 0.2)) }
        XCTAssertEqual(tap(after: 0.2), DelightCopy.aboutAgain)
        XCTAssertEqual(counter.rounds, 3)
    }

    func testVersionTapsPlayTheFlourishAndShowTheToast() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = DelightController(model: context.model, defaults: try makeDefaults(), clock: { now })
        var flourishes = 0
        controller.playFlourish = { flourishes += 1 }
        context.model.delights = controller
        for _ in 1...6 {
            now = now.addingTimeInterval(0.25)
            controller.versionTapped()
        }
        XCTAssertNil(context.model.toast)
        now = now.addingTimeInterval(0.25)
        controller.versionTapped()
        XCTAssertEqual(context.model.toast, DelightCopy.aboutFirst)
        XCTAssertEqual(flourishes, 1)
        XCTAssertEqual(controller.aboutFlourishes, 1, "The Version row's haptic follows each round")
        for _ in 1...7 {
            now = now.addingTimeInterval(0.25)
            controller.versionTapped()
        }
        XCTAssertEqual(context.model.toast, DelightCopy.aboutAgain)
        XCTAssertEqual(flourishes, 2)
    }

    func testTablaFlourishIsAShortMonoPCMWave() {
        let data = TablaFlourish.wavData()
        let bytes = [UInt8](data)
        func text(_ offset: Int) -> String { String(decoding: bytes[offset..<offset + 4], as: UTF8.self) }
        func uint16(_ offset: Int) -> Int {
            let low = Int(bytes[offset])
            let high = Int(bytes[offset + 1])
            return low | (high << 8)
        }
        func uint32(_ offset: Int) -> Int { uint16(offset) | (uint16(offset + 2) << 16) }
        XCTAssertEqual(text(0), "RIFF")
        XCTAssertEqual(uint32(4), bytes.count - 8)
        XCTAssertEqual(text(8), "WAVE")
        XCTAssertEqual(text(12), "fmt ")
        XCTAssertEqual(uint32(16), 16)
        XCTAssertEqual(uint16(20), 1, "Linear PCM")
        XCTAssertEqual(uint16(22), 1, "Mono")
        XCTAssertEqual(uint32(24), TablaFlourish.sampleRate)
        XCTAssertEqual(uint32(28), TablaFlourish.sampleRate * 2, "Byte rate")
        XCTAssertEqual(uint16(32), 2, "Block alignment")
        XCTAssertEqual(uint16(34), 16, "Bits per sample")
        XCTAssertEqual(text(36), "data")
        XCTAssertEqual(uint32(40), bytes.count - 44)
        XCTAssertEqual(bytes.count, TablaFlourish.byteCount, "The cache check compares this size")

        let seconds = Double(uint32(40)) / Double(TablaFlourish.sampleRate * 2)
        XCTAssertLessThan(seconds, 1, "A flourish, not a concert")
        XCTAssertGreaterThan(seconds, 0.3)
        let samples = TablaFlourish.samples()
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 20_000, "Normalized to a clearly audible level")
        XCTAssertLessThan(peak, Int(Int16.max), "Headroom left, nothing clips")
        for (index, onset) in [0.0, 0.17, 0.29].enumerated() {
            let start = Int(onset * Double(TablaFlourish.sampleRate))
            let strike = samples[start..<(start + 441)].map { abs(Int($0)) }.max() ?? 0
            let before = samples[max(0, start - 441)..<start].map { abs(Int($0)) }.max() ?? 0
            XCTAssertGreaterThan(strike, 4_000, "Stroke \(index + 1) is struck at \(onset) s")
            XCTAssertGreaterThan(strike, 2 * before, "Stroke \(index + 1) rises above the ring it lands on")
        }
        XCTAssertLessThan(samples.suffix(20).map { abs(Int($0)) }.max() ?? 0, 400, "The last stroke fades out instead of clicking")
        XCTAssertEqual(TablaFlourish.wavData(), data, "The same bytes on every device")
    }

    // MARK: Sleep timer

    func testSleepMessagesForTheForegroundAndForAReturnWithinTwelveHours() throws {
        XCTAssertEqual(DelightCopy.sleepForeground, "Shh. Paused for you.")
        let pausedAt = date(2026, 10, 3, 1, 12)
        let english = Locale(identifier: "en_US")
        func message(after elapsed: TimeInterval) -> String? {
            SleepPauseMessage.background(pausedAt: pausedAt, now: pausedAt.addingTimeInterval(elapsed),
                                         locale: english, timeZone: utc.timeZone)
        }
        XCTAssertEqual(spaced(try XCTUnwrap(message(after: 6 * 3_600))),
                       "Paused at 1:12 AM, like you asked. You were asleep anyway.")
        XCTAssertNotNil(message(after: 12 * 3_600), "Twelve hours still counts")
        XCTAssertNil(message(after: 12 * 3_600 + 1), "Older news is dropped")
        XCTAssertNil(message(after: -60), "A clock moved backwards drops the line")
    }

    func testSleepTimerToastsInTheForegroundAndWaitsForTheNextActivationInTheBackground() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let player = context.player
        let defaults = try makeDefaults()
        var now = date(2026, 10, 3, 1, 12)
        let controller = DelightController(model: model, defaults: defaults, clock: { now })
        controller.calendar = utc
        controller.locale = Locale(identifier: "en_US")
        model.delights = controller
        let song = AppModelFixtures.track("sleep-song")
        func fireTimer() throws {
            player.setSleepTimer(minutes: 1)
            let deadline = try XCTUnwrap(player.sleepUntil)
            player.expireSleepTimer(expected: deadline, now: deadline.addingTimeInterval(1))
        }

        try fireTimer()
        XCTAssertNil(model.toast, "A timer that finds the music paused stays quiet")

        player.play([song])
        XCTAssertTrue(player.isLoading)
        try fireTimer()
        XCTAssertEqual(model.toast, "Shh. Paused for you.")
        XCTAssertEqual(controller.toastSymbol(for: DelightCopy.sleepForeground), "moon.zzz.fill")
        XCTAssertFalse(player.isLoading, "The timer still pauses")

        model.toast = nil
        player.play([song])
        model.deactivateDeviceServices()
        try fireTimer()
        XCTAssertNil(model.toast, "In the background the line waits for the app to return")
        XCTAssertNotNil(defaults.object(forKey: DelightController.Key.sleepPausedAt))
        now = now.addingTimeInterval(7 * 3_600)
        controller.sceneDidBecomeActive()
        let returned = try XCTUnwrap(model.toast)
        XCTAssertEqual(spaced(returned), "Paused at 1:12 AM, like you asked. You were asleep anyway.")
        XCTAssertEqual(controller.toastSymbol(for: returned), "moon.zzz.fill")
        model.toast = nil
        controller.sceneDidBecomeActive()
        XCTAssertNil(model.toast, "Shown once")

        player.play([song])
        controller.sceneDidResignActive()
        try fireTimer()
        now = now.addingTimeInterval(13 * 3_600)
        controller.sceneDidBecomeActive()
        XCTAssertNil(model.toast, "A pause more than twelve hours old is dropped quietly")
        XCTAssertNil(defaults.object(forKey: DelightController.Key.sleepPausedAt))
    }

    // MARK: Anniversary

    func testAnniversaryCardShowsForSevenDaysFromEachAnniversary() throws {
        let first = date(2025, 3, 10, 21, 30)
        func card(day: Int, dismissed: Int? = nil, history: Bool = true, firstSong: String? = "Kesariya") -> AnniversaryCard? {
            AnniversaryDelight.card(origin: ListeningOrigin(startedAt: first, firstSongTitle: firstSong),
                                    lifetimeSeconds: 42 * 3_600 + 1_800, historyEnabled: history, dismissedYear: dismissed,
                                    now: first.addingTimeInterval(Double(day) * 86_400), calendar: utc)
        }
        XCTAssertNil(card(day: 364))
        let anniversary = try XCTUnwrap(card(day: 365))
        XCTAssertEqual(anniversary.years, 1)
        XCTAssertEqual(anniversary.anniversaryYear, 2026)
        XCTAssertEqual(anniversary.title, "One year of Velvet Thorn.")
        XCTAssertEqual(anniversary.message, "42 hours together. Your first song was Kesariya, and honestly, it shows.")
        XCTAssertEqual(card(day: 366), anniversary)
        XCTAssertNotNil(card(day: 371))
        XCTAssertNil(card(day: 372), "Seven days, then the card steps aside")
        XCTAssertNil(card(day: 365, history: false), "History off hides the card")
        XCTAssertNil(card(day: 366, dismissed: 2026), "A dismissed anniversary stays dismissed")
        XCTAssertNotNil(card(day: 366, dismissed: 2025))

        let second = try XCTUnwrap(card(day: 731, dismissed: 2026))
        XCTAssertEqual(second.years, 2)
        XCTAssertEqual(second.anniversaryYear, 2027)
        XCTAssertEqual(second.title, "Two years of Velvet Thorn.")
        XCTAssertEqual(AnniversaryDelight.title(years: 3), "Three years of Velvet Thorn.")
        XCTAssertEqual(AnniversaryDelight.title(years: 21), "Twenty-one years of Velvet Thorn.")

        let unnamed = try XCTUnwrap(card(day: 365, firstSong: nil))
        XCTAssertEqual(unnamed.message, "42 hours together.", "No retained first song, no sentence about it")
        XCTAssertEqual(AnniversaryDelight.message(hours: 1, firstSongTitle: "  "), "1 hour together.")
        XCTAssertEqual(AnniversaryDelight.message(hours: 0, firstSongTitle: nil), "Less than an hour together.")
        XCTAssertNil(AnniversaryDelight.card(origin: nil, lifetimeSeconds: 0, historyEnabled: true, dismissedYear: nil,
                                             now: first, calendar: utc))
        XCTAssertFalse(anniversary.title.contains("—") || anniversary.message.contains("—"))
    }

    func testListeningOriginNamesTheFirstSongOnlyWhileItsDetailSurvives() {
        let first = date(2025, 3, 10, 21, 30)
        let earliest = ListeningEvent(id: UUID(), track: libraryTestTrack("first-song"),
                                      startedAt: first.addingTimeInterval(0.0004), listenedSeconds: 200)
        let later = ListeningEvent(id: UUID(), track: libraryTestTrack("later-song"),
                                   startedAt: first.addingTimeInterval(86_400), listenedSeconds: 200)
        XCTAssertEqual(ListeningOrigin.make(coverageStartedAt: first, events: [later, earliest]),
                       ListeningOrigin(startedAt: first, firstSongTitle: "Song first-song"),
                       "A millisecond receipt and its retained event name the first song")
        let expired = first.addingTimeInterval(-40 * 86_400)
        XCTAssertEqual(ListeningOrigin.make(coverageStartedAt: expired, events: [later, earliest]),
                       ListeningOrigin(startedAt: expired, firstSongTitle: nil),
                       "Only a receipt survives the first session, so no song is named")
        XCTAssertEqual(ListeningOrigin.make(coverageStartedAt: nil, events: [later, earliest])?.firstSongTitle, "Song first-song")
        XCTAssertEqual(ListeningOrigin.make(coverageStartedAt: first, events: []), ListeningOrigin(startedAt: first, firstSongTitle: nil))
        XCTAssertNil(ListeningOrigin.make(coverageStartedAt: nil, events: []))
    }

    func testAnniversaryCardReadsTheLibraryAndHidesWhileHistoryIsOffOrOnceDismissed() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let defaults = try makeDefaults()
        let controller = DelightController(model: model, defaults: defaults)
        model.delights = controller
        let now = Date()
        XCTAssertNil(controller.anniversaryCard(at: now), "No listening, no anniversary")
        let first = try XCTUnwrap(controller.calendar.date(byAdding: .year, value: -1, to: now)).addingTimeInterval(-60)
        XCTAssertTrue(model.library.recordListening(track: libraryTestTrack("first-listen"), sessionID: UUID(),
                                                    startedAt: first, seconds: 3 * 3_600))
        XCTAssertTrue(model.library.recordListening(track: libraryTestTrack("lately"), sessionID: UUID(),
                                                    startedAt: now.addingTimeInterval(-3_600), seconds: 2 * 3_600))
        let card = try XCTUnwrap(controller.anniversaryCard(at: now))
        XCTAssertEqual(card.title, "One year of Velvet Thorn.")
        XCTAssertEqual(card.message, "5 hours together. Your first song was Song first-listen, and honestly, it shows.",
                       "Hours come from lifetime totals; the song from the earliest retained event")

        model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertFalse(model.library.preferences.saveListeningHistory)
        XCTAssertNil(controller.anniversaryCard(at: now), "History off hides the card")
        model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertEqual(controller.anniversaryCard(at: now), card)

        controller.dismissAnniversary(card)
        XCTAssertNil(controller.anniversaryCard(at: now))
        XCTAssertEqual(defaults.integer(forKey: DelightController.Key.anniversaryDismissed), card.anniversaryYear)
        XCTAssertNil(DelightController(model: model, defaults: defaults).anniversaryCard(at: now), "Dismissal survives a relaunch")
    }

    // MARK: Helpers

    private func makeDefaults() throws -> UserDefaults {
        let name = "GanaBajana.DelightsTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// Time formats can separate the minute and the AM marker with a narrow no-break space.
    private func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
