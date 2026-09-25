import XCTest
@testable import GanaBajana

final class PlaybackShufflePolicyTests: XCTestCase {
    private let recent = Track(id: "shuffle-recent", title: "Recent", duration: 180)
    private let halfway = Track(id: "shuffle-halfway", title: "Halfway", duration: 180)
    private let fresh = Track(id: "shuffle-fresh", title: "Fresh", duration: 180)

    func testLastQualifiedListenSetsTheLinearWeightAndUnheardSongsKeepFullWeight() {
        let policy = policy([
            event(recent, ageDays: 6), event(recent, ageDays: 0),
            event(halfway, ageDays: 3.5), event(halfway, ageDays: 1, seconds: 29.999)
        ])
        XCTAssertEqual(policy.weight(for: recent), 0.1, accuracy: 0.000_001)
        XCTAssertEqual(policy.weight(for: halfway), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(policy.weight(for: fresh), 1)
    }

    func testSevenDayBoundaryUsesElapsedSecondsAndDoesNotInventASessionEnd() {
        let now = PlaybackShuffleTestSupport.now
        var beforeBoundary = event(recent, ageDays: 7, seconds: 3_600)
        beforeBoundary.startedAt = now.addingTimeInterval(-7 * 86_400 + 1)
        let policy = policy([beforeBoundary, event(halfway, ageDays: 7, seconds: 3_600), event(fresh, ageDays: 8)])
        XCTAssertEqual(policy.weight(for: recent), 1 - 0.9 / (7 * 86_400), accuracy: 0.000_000_001)
        XCTAssertEqual(policy.weight(for: halfway), 1, "Credited seconds do not move the saved session start")
        XCTAssertEqual(policy.weight(for: fresh), 1)
        XCTAssertEqual(self.policy([event(recent, ageDays: 1)]).weight(for: recent), 0.1 + 0.9 / 7, accuracy: 0.000_001)
    }

    func testQualificationUsesThirtySecondsOrHalfTheSavedTrackDuration() {
        let short = Track(id: "shuffle-short", title: "Short", duration: 20)
        let unknown = Track(id: "shuffle-unknown", title: "Unknown duration")
        let under = policy([event(short, ageDays: 0, seconds: 9.999), event(unknown, ageDays: 0, seconds: 29.999),
                            event(recent, ageDays: 0, seconds: 29.999)])
        XCTAssertEqual(under.weight(for: short), 1)
        XCTAssertEqual(under.weight(for: unknown), 1)
        XCTAssertEqual(under.weight(for: recent), 1)
        let qualified = policy([event(short, ageDays: 0, seconds: 10), event(unknown, ageDays: 0, seconds: 30),
                                event(recent, ageDays: 0, seconds: 30)])
        for track in [short, unknown, recent] { XCTAssertEqual(qualified.weight(for: track), 0.1, accuracy: 0.000_001) }
    }

    func testInvalidFutureAndUnqualifiedEvidenceDoesNotOverrideAnOlderQualifiedListen() {
        let now = PlaybackShuffleTestSupport.now
        var events = [event(recent, ageDays: 3.5)]
        for seconds in [0, -1, .nan, .infinity, now.timeIntervalSince1970 + 1] {
            events.append(event(recent, ageDays: 0, seconds: seconds))
        }
        for date in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .nan),
                     Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: 253_402_300_800),
                     now.addingTimeInterval(0.001)] {
            var invalid = event(recent, ageDays: 0)
            invalid.startedAt = date
            events.append(invalid)
        }
        let invalidDurations: [TimeInterval] = [0, -1, .nan, .infinity]
        for duration in invalidDurations {
            var invalid = recent
            invalid.duration = duration
            events.append(event(invalid, ageDays: 0))
        }
        var blankTitle = recent
        blankTitle.title = "  "
        events.append(event(blankTitle, ageDays: 0))
        let blankID = Track(id: "  ", title: "Invalid identity", duration: 180)
        events.append(event(blankID, ageDays: 0))
        events.append(event(recent, ageDays: 0, seconds: 0.5))
        let policy = policy(events)
        XCTAssertEqual(policy.weight(for: recent), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(policy.weight(for: blankID), 1)
        for date in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: -1),
                     Date(timeIntervalSince1970: 253_402_300_800)] {
            XCTAssertEqual(PlaybackShufflePolicy(style: .fewerRepeats, history: events, now: date).weight(for: recent), 1)
        }
    }

    func testDuplicateCheckpointsUseTheLargestTotalWithoutAddingSecondsOrCountingAgain() {
        let id = UUID()
        let partial = event(recent, ageDays: 0, seconds: 20, id: id)
        let full = event(recent, ageDays: 0, seconds: 30, id: id)
        XCTAssertEqual(policy([partial, partial]).weight(for: recent), 1)
        XCTAssertEqual(policy([partial, event(recent, ageDays: 0, seconds: 20)]).weight(for: recent), 1)
        for events in [[partial, full, full], [full, partial, full]] {
            let policy = policy(events)
            XCTAssertEqual(policy.weight(for: recent), 0.1, accuracy: 0.000_001)
            var generator = PlaybackShuffleTestSupport.Generator(seed: 1)
            let order = policy.order(PlaybackShuffleTestSupport.entries([recent, fresh]), using: &generator)
            XCTAssertEqual(order.recentCount, 1)
        }
    }

    func testConflictingSessionIdentityIsExcludedBeforeWindowAndQualificationFiltering() {
        let id = UUID()
        let original = event(recent, ageDays: 0, id: id)
        let conflicts = [event(fresh, ageDays: 0, id: id), event(recent, ageDays: 1, id: id),
                         event(recent, ageDays: 8, id: id), event(recent, ageDays: -1, id: id),
                         event(fresh, ageDays: 0, seconds: 1, id: id)]
        for conflict in conflicts {
            for events in [[original, conflict, original], [conflict, original, conflict]] {
                let policy = policy(events)
                XCTAssertEqual(policy.weight(for: recent), 1)
                XCTAssertEqual(policy.weight(for: fresh), 1)
                let independent = self.policy(events + [event(recent, ageDays: 3.5)])
                XCTAssertEqual(independent.weight(for: recent), 0.55, accuracy: 0.000_001)
            }
        }
    }

    func testDuplicateMetadataCannotMakeQualificationDependOnInputOrder() {
        var short = recent
        short.duration = 20
        let id = UUID()
        let smallThreshold = event(short, ageDays: 0, seconds: 20, id: id)
        let fullThreshold = event(recent, ageDays: 0, seconds: 20, id: id)
        for events in [[smallThreshold, fullThreshold], [fullThreshold, smallThreshold]] {
            XCTAssertEqual(policy(events).weight(for: recent), 1)
            XCTAssertEqual(policy(events + [event(recent, ageDays: 0, seconds: 30, id: id)]).weight(for: recent),
                           0.1, accuracy: 0.000_001)
        }
    }

    func testProviderPlayCountsDoNotSupplyListeningEvidenceOrChangeWeights() {
        var popular = fresh
        popular.playCount = .max
        var unpopular = fresh
        unpopular.playCount = 0
        let unheard = policy([])
        XCTAssertEqual(unheard.weight(for: popular), 1)
        XCTAssertEqual(unheard.weight(for: unpopular), 1)
        let heard = policy([event(popular, ageDays: 3.5)])
        XCTAssertEqual(heard.weight(for: unpopular), 0.55, accuracy: 0.000_001)
        XCTAssertEqual(heard.weight(for: popular), heard.weight(for: unpopular))
    }

    func testRandomEmptyUnavailableAndOldHistoryUseTheSameUniformFallback() {
        let entries = PlaybackShuffleTestSupport.entries([recent, fresh, halfway, recent])
        let cases: [(ShuffleStyle, [ListeningEvent]?, PlaybackShufflePolicy.HistoryAvailability)] = [
            (.random, [event(recent, ageDays: 0)], .available),
            (.fewerRepeats, [], .empty), (.fewerRepeats, nil, .unavailable),
            (.fewerRepeats, [event(recent, ageDays: 7)], .available)
        ]
        var expectedGenerator = PlaybackShuffleTestSupport.Generator(seed: 42)
        let expected = entries.shuffled(using: &expectedGenerator).map(\.id)
        for (style, history, availability) in cases {
            let policy = PlaybackShufflePolicy(style: style, history: history, now: PlaybackShuffleTestSupport.now)
            var generator = PlaybackShuffleTestSupport.Generator(seed: 42)
            let order = policy.order(entries, using: &generator)
            XCTAssertEqual(policy.historyAvailability, availability)
            XCTAssertEqual(order.entries.map(\.id), expected)
            XCTAssertEqual(order.effectiveStyle, .random)
            XCTAssertFalse(order.weighted)
            XCTAssertEqual(order.recentCount, style == .random ? 2 : 0)
        }
    }

    func testDeterministicWeightedOrderSamplesFirstAndTailWithOneDrawPerOccurrence() {
        let otherFresh = Track(id: "shuffle-another-fresh", title: "Another fresh song")
        let entries = PlaybackShuffleTestSupport.entries([recent, fresh, halfway, otherFresh])
        let policy = policy([event(recent, ageDays: 0), event(halfway, ageDays: 3.5)])
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: Array(repeating: UInt64.max / 2, count: 4))
        let result = policy.order(entries, using: &generator)
        XCTAssertEqual(result.entries.map(\.track), [fresh, otherFresh, halfway, recent])
        XCTAssertEqual(Set(result.entries.map(\.id)), Set(entries.map(\.id)))
        XCTAssertEqual(result.recentCount, 2)
        XCTAssertTrue(result.weighted)
        XCTAssertEqual(result.effectiveStyle, .fewerRepeats)
        XCTAssertEqual(generator.draws, entries.count)
    }

    func testRecentSongStillCanLeadAndExtremeRandomValuesPreserveEveryOccurrence() {
        let entries = PlaybackShuffleTestSupport.entries([recent, fresh, recent])
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: [.max, 0, 0])
        let result = policy([event(recent, ageDays: 0)]).order(entries, using: &generator)
        XCTAssertEqual(result.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(result.entries.first?.track, recent, "Fewer repeats is a soft preference")
        XCTAssertEqual(result.recentCount, 2, "Counts refer to candidate occurrences, including duplicates")
    }

    func testMidpointBucketsIgnoreLowTwelveBitsAndBreakExactTiesByOccurrence() {
        let entries = PlaybackShuffleTestSupport.entries([recent, recent, recent])
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: [0, 0x0fff, 0x1000])
        let result = policy([event(recent, ageDays: 0)]).order(entries, using: &generator)
        XCTAssertEqual(result.entries.map(\.id), [entries[2].id, entries[0].id, entries[1].id])
        XCTAssertEqual(generator.draws, 3)
    }

    func testSeededSamplingPrefersUnheardStartsWithoutBanningRecentlyHeardStarts() {
        let entries = PlaybackShuffleTestSupport.entries([recent, fresh])
        let policy = policy([event(recent, ageDays: 0)])
        var generator = PlaybackShuffleTestSupport.Generator(seed: 0x7273_6875_6666_6c65)
        var recentStarts = 0
        for _ in 0..<4_096 {
            let result = policy.order(entries, using: &generator)
            if result.entries.first?.track == recent { recentStarts += 1 }
            XCTAssertEqual(Set(result.entries.map(\.id)), Set(entries.map(\.id)))
        }
        let share = Double(recentStarts) / 4_096
        XCTAssertGreaterThan(share, 0.07)
        XCTAssertLessThan(share, 0.12, "The expected first-place share is 0.1 / 1.1, not a fixed recency sort")
    }

    func testEmptyAndSingletonOrdersHaveNoWeightedChoiceAndNeedNoRandomDraws() {
        let policy = policy([event(recent, ageDays: 0)])
        var generator = PlaybackShuffleTestSupport.ScriptedGenerator(values: [])
        let empty = policy.order([], using: &generator)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertFalse(empty.weighted)
        XCTAssertEqual(empty.recentCount, 0)
        let singleton = policy.order(PlaybackShuffleTestSupport.entries([recent]), using: &generator)
        XCTAssertEqual(singleton.entries.map(\.track), [recent])
        XCTAssertFalse(singleton.weighted)
        XCTAssertEqual(singleton.recentCount, 1)
        XCTAssertEqual(generator.draws, 0)
    }

    private func policy(_ events: [ListeningEvent]) -> PlaybackShufflePolicy {
        PlaybackShufflePolicy(style: .fewerRepeats, history: events, now: PlaybackShuffleTestSupport.now)
    }

    private func event(_ track: Track, ageDays: Double, seconds: TimeInterval = 30, id: UUID = UUID()) -> ListeningEvent {
        PlaybackShuffleTestSupport.event(track, ageDays: ageDays, seconds: seconds, id: id)
    }
}

enum PlaybackShuffleTestSupport {
    static let now = Date(timeIntervalSince1970: 1_789_819_200)

    static func event(_ track: Track, ageDays: Double, seconds: TimeInterval = 30, id: UUID = UUID()) -> ListeningEvent {
        ListeningEvent(id: id, track: track, startedAt: now.addingTimeInterval(-ageDays * 86_400), listenedSeconds: seconds)
    }

    static func entries(_ tracks: [Track]) -> [PlaybackQueue.Entry] {
        tracks.map { .init(id: UUID(), track: $0) }
    }

    struct ScriptedGenerator: RandomNumberGenerator {
        let values: [UInt64]
        private(set) var draws = 0

        mutating func next() -> UInt64 {
            precondition(draws < values.count, "Missing deterministic shuffle draw")
            defer { draws += 1 }
            return values[draws]
        }
    }

    struct Generator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
            value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
            return value ^ (value >> 31)
        }
    }
}
