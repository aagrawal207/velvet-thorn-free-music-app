import AVFoundation
import Foundation
import XCTest
@testable import GanaBajana

enum MomentMixFixtures {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static let start = date("2026-09-01T00:00:00Z")
    static let now = date("2026-09-24T09:00:00Z")
    static func track(_ id: String) -> Track {
        Track(id: id, title: "Song \(id)", artists: ["Artist"], duration: 180, isAudioRecording: true)
    }
    static func event(_ id: String, at: Date, seconds: Double = 30, session: UUID = UUID()) -> ListeningEvent {
        ListeningEvent(id: session, track: track(id), startedAt: at, listenedSeconds: seconds)
    }
    static var recurring: [ListeningEvent] {
        ["2026-09-21T08:00:00Z", "2026-09-22T08:00:00Z", "2026-09-23T08:00:00Z"].enumerated().map {
            event("song\($0.offset)", at: date($0.element))
        }
    }
    static func evidence(_ event: ListeningEvent, route: MomentRoute = .general) -> MomentEvidence {
        MomentEvidence(eventID: event.id, trackID: event.track.id, startedAt: event.startedAt,
                       endedAt: event.startedAt.addingTimeInterval(30),
                       localDay: MomentLearning.dayKey(event.startedAt, calendar: calendar),
                       context: .at(event.startedAt, route: route, calendar: calendar))
    }
}

final class MomentMixLearningTests: XCTestCase {
    private typealias F = MomentMixFixtures

    func testThreeSeparateDaysUnlockButTwoDoNot() throws {
        let evidence = F.recurring.map { F.evidence($0) }
        XCTAssertFalse(try XCTUnwrap(MomentLearning.summaries(Array(evidence.prefix(2))).first).isRecurring)
        let summary = try XCTUnwrap(MomentLearning.summaries(evidence).first)
        XCTAssertEqual(summary.sessions, 3)
        XCTAssertEqual(summary.days, 3)
        XCTAssertTrue(summary.isRecurring)
    }

    func testCheckpointCopiesAndSameSessionTracksNeverMultiplyRecurrences() throws {
        let start = F.recurring[0].startedAt
        let first = F.event("a", at: start)
        let second = F.event("b", at: start.addingTimeInterval(180))
        let third = F.event("a", at: start.addingTimeInterval(400))
        let evidence = [first, first, second, third].map { F.evidence($0) }
        let summary = try XCTUnwrap(MomentLearning.summaries(evidence).first)
        XCTAssertEqual(summary.sessions, 1)
        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.trackSessions, ["a": 1, "b": 1])
        XCTAssertFalse(summary.isRecurring)
    }

    func testSeparateSessionsOnOneDayStillDoNotUnlock() throws {
        let date = F.recurring[0].startedAt
        let events = (0..<3).map { F.event("\($0)", at: date.addingTimeInterval(Double($0) * 3_600)) }
        let summary = try XCTUnwrap(MomentLearning.summaries(events.map { F.evidence($0) }).first)
        XCTAssertEqual(summary.sessions, 3)
        XCTAssertEqual(summary.days, 1)
        XCTAssertFalse(summary.isRecurring)
    }

    func testTimeBoundariesAndCalendarWeekend() {
        let pairs: [(String, MomentTime)] = [
            ("04:59:59", .night), ("05:00:00", .morning), ("10:59:59", .morning),
            ("11:00:00", .afternoon), ("16:59:59", .afternoon), ("17:00:00", .evening),
            ("21:59:59", .evening), ("22:00:00", .night), ("00:00:00", .night)
        ]
        for (time, expected) in pairs {
            XCTAssertEqual(MomentTime.at(F.date("2026-09-21T\(time)Z"), calendar: F.calendar), expected)
        }
        XCTAssertFalse(MomentContext.at(F.date("2026-09-25T23:59:59Z"), calendar: F.calendar).weekend)
        XCTAssertTrue(MomentContext.at(F.date("2026-09-26T00:00:00Z"), calendar: F.calendar).weekend)
    }

    func testLocalMidnightAndDSTRepeatedHourUseOneLocalDay() {
        var calendar = F.calendar
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let first = F.date("2026-11-01T08:30:00Z"), repeated = F.date("2026-11-01T09:30:00Z")
        XCTAssertEqual(MomentLearning.dayKey(first, calendar: calendar), MomentLearning.dayKey(repeated, calendar: calendar))
        XCTAssertEqual(MomentContext.at(first, calendar: calendar), MomentContext.at(repeated, calendar: calendar))
        XCTAssertNotEqual(MomentLearning.dayKey(F.date("2026-09-22T06:59:59Z"), calendar: calendar),
                          MomentLearning.dayKey(F.date("2026-09-22T07:00:00Z"), calendar: calendar))
    }

    func testGenericBluetoothDoesNotClaimCarHeadphonesOrGym() {
        XCTAssertEqual(MomentAudioRoute.classify([.bluetoothA2DP]), .general)
        XCTAssertEqual(MomentAudioRoute.classify([.bluetoothHFP]), .general)
        XCTAssertEqual(MomentAudioRoute.classify([.airPlay]), .general)
        XCTAssertEqual(MomentAudioRoute.classify([.headphones]), .headphones)
        XCTAssertEqual(MomentAudioRoute.classify([.carAudio, .headphones]), .car)
        XCTAssertTrue(MomentContext.all.allSatisfy { !$0.title.lowercased().contains("gym") && !$0.title.lowercased().contains("commute") })
    }

    func testGenerationUsesLocalSongsAndExcludesDislikesVideoAndDisabledMix() throws {
        let events = F.recurring
        let summary = try XCTUnwrap(MomentLearning.summaries(events.map { F.evidence($0) }).first)
        let extra = F.track("extra")
        var video = F.track("video")
        video.isAudioRecording = false
        let disliked = DislikedSong(id: events[0].track.id, title: events[0].track.title,
                                   artists: events[0].track.artists, dislikedAt: F.now)
        let profile = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], disliked: [disliked], now: F.now)
        let library = events.map(\.track) + [extra, video, extra]
        let mix = try XCTUnwrap(MomentLearning.collection(for: summary, library: library, profile: profile,
                                                         preferences: .init(), periodKey: "today"))
        XCTAssertEqual(Set(mix.tracks.map(\.id)), ["song1", "song2", "extra"])
        XCTAssertEqual(mix.tracks.count, 3)
        var preferences = MomentMixPreferences()
        preferences.disabledMixIDs.insert(summary.id)
        XCTAssertNil(MomentLearning.collection(for: summary, library: library, profile: profile, preferences: preferences, periodKey: "today"))
        preferences.disabledMixIDs = []
        preferences.learningEnabled = false
        XCTAssertNil(MomentLearning.collection(for: summary, library: library, profile: profile, preferences: preferences, periodKey: "today"))
    }

    func testGenerationIsDeterministicBoundedAndNeedsThreeAvailableSongs() throws {
        let events = F.recurring
        let summary = try XCTUnwrap(MomentLearning.summaries(events.map { F.evidence($0) }).first)
        let profile = TasteProfile.build(events: events, favorites: [], playlists: [], recents: [], now: F.now)
        let library = events.map(\.track) + (0..<50).map { F.track("extra\($0)") }
        func mix(_ tracks: [Track]) -> MusicCollection? {
            MomentLearning.collection(for: summary, library: tracks, profile: profile, preferences: .init(), periodKey: "today")
        }
        XCTAssertEqual(mix(library)?.tracks.map(\.id), mix(Array(library.reversed()))?.tracks.map(\.id))
        XCTAssertEqual(mix(library)?.tracks.count, 25)
        XCTAssertNil(mix(Array(events.prefix(2).map(\.track))))
    }

    func testUnknownArtistsCannotFillAContextWithUnrelatedSongs() throws {
        var seed = F.track("seed")
        seed.artists = [" "]
        let events = F.recurring.map { ListeningEvent(id: $0.id, track: seed, startedAt: $0.startedAt, listenedSeconds: 30) }
        let summary = try XCTUnwrap(MomentLearning.summaries(events.map { F.evidence($0) }).first)
        let others = ["a", "b", "c"].map { Track(id: $0, title: $0, artists: [" "], isAudioRecording: true) }
        let profile = TasteProfile.build(events: events, favorites: others, playlists: [], recents: [], now: F.now)
        XCTAssertNil(MomentLearning.collection(for: summary, library: [seed] + others, profile: profile,
                                               preferences: .init(), periodKey: "today"))
    }
}
