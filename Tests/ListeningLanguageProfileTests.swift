import XCTest
@testable import GanaBajana

final class ListeningLanguageProfileTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testQualifiedSessionsUseThirtySecondsOrHalfAShortSongAndExcludeUnqualifiedSongs() {
        let examples: [(TimeInterval?, TimeInterval)] = [
            (240, 29.999), (240, 30), (40, 19.999), (40, 20), (nil, 29.999), (nil, 30), (60, 30)
        ]
        let events = examples.enumerated().map { index, example in
            Fixtures.event(Fixtures.track("threshold-\(index)", duration: example.0, language: .english),
                           daysAgo: 1, seconds: example.1)
        }
        let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now)
        XCTAssertEqual(result.totalPlays, 4)
        XCTAssertEqual(result.totalSongs, 4)
        XCTAssertEqual(result.rows, [LanguageListeningStat(language: .english, plays: 4, songs: 4, share: 1)])
        XCTAssertEqual(result.unclassifiedPlays, 0)
        XCTAssertEqual(result.totalPlays, ListeningAnalytics.summary(events: events, for: .week, now: Fixtures.now).plays)
    }

    func testDistinctSessionsCountRepeatsButDuplicateInputAndPartialSessionsDoNotInventPlays() {
        let song = Fixtures.track("repeat", language: .hindi)
        let first = Fixtures.event(song, daysAgo: 1, seconds: 30)
        let events = [first, first, Fixtures.event(song, daysAgo: 2, seconds: 200),
                      Fixtures.event(song, daysAgo: 3, seconds: 15), Fixtures.event(song, daysAgo: 4, seconds: 15)]
        let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now)
        XCTAssertEqual(result.totalPlays, 2)
        XCTAssertEqual(result.totalSongs, 1)
        XCTAssertEqual(result.rows, [LanguageListeningStat(language: .hindi, plays: 2, songs: 1, share: 1)])
    }

    func testUnknownLikelyMixedAndFailedEvidenceStayInTheDenominator() throws {
        let english = Fixtures.track("english", language: .english)
        let tamil = Fixtures.track("tamil")
        let unknown = Fixtures.track("unknown")
        let likely = Fixtures.track("likely")
        let mixed = Fixtures.track("mixed")
        let failed = Fixtures.track("failed")
        let events = [english, english, tamil, unknown, likely, mixed, failed].map {
            Fixtures.event($0, daysAgo: 1, seconds: 30)
        }
        let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [
            LyricsRequestKey(tamil): .identified(.tamil, source: .linkedLyrics),
            LyricsRequestKey(likely): .likely(.english, source: .titleLabel),
            LyricsRequestKey(mixed): .unclassified(.conflictingEvidence),
            LyricsRequestKey(failed): .unclassified(.lookupFailed)
        ]
        let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now, evidence: evidence)
        XCTAssertEqual(result.totalPlays, 7)
        XCTAssertEqual(result.totalSongs, 6)
        XCTAssertEqual(result.identifiedPlays, 3)
        XCTAssertEqual(result.unclassifiedPlays, 4)
        XCTAssertEqual(result.unclassifiedSongs, 4)
        XCTAssertEqual(result.rows.map(\.language), [.english, .tamil])
        let englishRow = try XCTUnwrap(result.rows.first)
        XCTAssertEqual(englishRow.plays, 2)
        XCTAssertEqual(englishRow.songs, 1)
        XCTAssertEqual(englishRow.share, 2.0 / 7, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.rows.last).share, 1.0 / 7, accuracy: 1e-12)
        let profile = ListeningLanguageProfile(summary: result, evidence: evidence)
        for track in [unknown, likely, mixed, failed] {
            XCTAssertNil(profile.language(for: track))
            XCTAssertEqual(profile.multiplier(for: track), 1)
        }
    }

    func testAutomaticEvidenceRequiresTheRecordingIDAndMatchingMetadata() {
        var original = Fixtures.track("recording")
        original.albumTitle = "Original album"
        var title = original
        title.title = "Different title"
        var artist = original
        artist.artists = ["Different artist"]
        var duration = original
        duration.duration = 180
        var album = original
        album.albumTitle = "Different album"
        var recording = original
        recording.id = "another-recording"
        let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [
            LyricsRequestKey(original): .identified(.bengali, source: .matchedLyrics)
        ]
        let profile = ListeningLanguageProfile(evidence: evidence)
        XCTAssertEqual(profile.language(for: original), .bengali)
        for changed in [title, artist, duration, album, recording] {
            XCTAssertNil(profile.language(for: changed))
            let result = ListeningAnalytics.languageSummary(
                events: [Fixtures.event(changed, daysAgo: 1, seconds: 30)], for: .week, now: Fixtures.now, evidence: evidence)
            XCTAssertEqual(result.unclassifiedPlays, 1)
            XCTAssertTrue(result.rows.isEmpty)
        }
        let updatedHistory = [Fixtures.event(original, daysAgo: 2, seconds: 30),
                              Fixtures.event(title, daysAgo: 1, seconds: 30)]
        let latest = ListeningAnalytics.languageSummary(events: updatedHistory, for: .week, now: Fixtures.now, evidence: evidence)
        XCTAssertEqual(latest.unclassifiedPlays, 2, "The recap's latest metadata cannot reuse an older recording key")
        XCTAssertEqual(latest.totalSongs, 1)
    }

    func testCorrectionThenVerifiedMetadataThenIdentifiedAutomaticEvidenceDetermineLanguage() {
        let song = Fixtures.track("precedence", language: .english)
        let events = [Fixtures.event(song, daysAgo: 1, seconds: 30)]
        let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [
            LyricsRequestKey(song): .identified(.tamil, source: .matchedLyrics)
        ]
        let metadata = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now, evidence: evidence)
        XCTAssertEqual(metadata.rows.first?.language, .english)
        XCTAssertEqual(ListeningLanguageProfile(evidence: evidence).language(for: song), .english)
        let corrected = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now,
                                                           evidence: evidence, overrides: [song.id: "te"])
        XCTAssertEqual(corrected.rows.first?.language, .telugu)
        XCTAssertEqual(ListeningLanguageProfile(evidence: evidence, overrides: [song.id: "te"]).language(for: song), .telugu)
        for code in ["und", "future-code"] {
            let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now,
                                                            evidence: evidence, overrides: [song.id: code])
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertEqual(result.unclassifiedPlays, 1)
            let profile = ListeningLanguageProfile(evidence: evidence, overrides: [song.id: code])
            XCTAssertNil(profile.language(for: song))
            XCTAssertEqual(profile.multiplier(for: song), 1)
        }
    }

    func testDateBoundariesInvalidInputAndSessionDeduplicationFollowTheExistingRecap() throws {
        let cutoff = try XCTUnwrap(Fixtures.calendar.date(byAdding: .day, value: -7, to: Fixtures.now))
        let song = Fixtures.track("boundary", language: .english)
        let boundary = ListeningEvent(id: UUID(), track: song, startedAt: cutoff, listenedSeconds: 30)
        var events = [boundary, boundary, ListeningEvent(id: UUID(), track: song, startedAt: Fixtures.now, listenedSeconds: 30)]
        for date in [cutoff.addingTimeInterval(-0.001), Fixtures.now.addingTimeInterval(0.001),
                     Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .nan)] {
            events.append(ListeningEvent(id: UUID(), track: song, startedAt: date, listenedSeconds: 30))
        }
        for seconds in [0.0, -1, .nan, .infinity, 1e300] {
            events.append(Fixtures.event(song, daysAgo: 1, seconds: seconds))
        }
        for invalid in [Fixtures.track("", language: .english), Fixtures.track("empty-title", title: " ", language: .english),
                        Fixtures.track("bad-duration", duration: 0, language: .english)] {
            events.append(Fixtures.event(invalid, daysAgo: 1, seconds: 30))
        }
        let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now, calendar: Fixtures.calendar)
        XCTAssertEqual(result.totalPlays, 2)
        XCTAssertEqual(result.totalSongs, 1)
        XCTAssertEqual(result.rows.first?.plays, 2)
        XCTAssertEqual(result.totalPlays, ListeningAnalytics.summary(events: events, for: .week,
                                                                     now: Fixtures.now, calendar: Fixtures.calendar).plays)
        XCTAssertEqual(ListeningAnalytics.languageSummary(events: events, for: .week, now: Date(timeIntervalSince1970: .nan)), .init())
    }

    func testLanguageWindowsUseSevenThirtyAnd365Days() {
        let events = [1.0, 8, 29, 31, 364, 366].enumerated().map { index, age in
            Fixtures.event(Fixtures.track("age-\(index)", language: .hindi), daysAgo: age, seconds: 30)
        }
        for (window, expected) in [(ListeningWindow.week, 1), (.month, 3), (.year, 5)] {
            let result = ListeningAnalytics.languageSummary(events: events, for: window, now: Fixtures.now, calendar: Fixtures.calendar)
            XCTAssertEqual(result.totalPlays, expected)
            XCTAssertEqual(result.totalSongs, expected)
        }
    }

    func testAllFiveRecordingLanguagesHaveExactCountsAndStableTieOrdering() {
        let tracks = ArtistSongLanguage.allCases.map { Fixtures.track($0.rawValue) }
        let evidence = Dictionary(uniqueKeysWithValues: zip(tracks, ArtistSongLanguage.allCases).map {
            (LyricsRequestKey($0.0), ArtistSongLanguageResult.identified($0.1, source: .matchedLyrics))
        })
        let events = tracks.reversed().map { Fixtures.event($0, daysAgo: 1, seconds: 30) }
        let result = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now, evidence: evidence)
        XCTAssertEqual(result.rows.map(\.id), ["bn", "en", "hi", "ta", "te"])
        XCTAssertTrue(result.rows.allSatisfy { $0.plays == 1 && $0.songs == 1 && $0.share == 0.2 })
        XCTAssertEqual(result.totalPlays, 5)
        XCTAssertEqual(result.totalSongs, 5)
        XCTAssertEqual(MusicLanguage.allCases, [.hindi, .english])
    }

    func testColdStartUsesFallbackWithoutInventingCountsAndKnownPlaysReplaceIt() {
        let cold = ListeningLanguageProfile(fallback: [.english])
        XCTAssertFalse(cold.isLearned)
        XCTAssertEqual(cold.summary, .init())
        XCTAssertEqual(cold.weights, [.english: 1])
        XCTAssertEqual(ListeningLanguageProfile(fallback: []).weights, [.english: 0.5, .hindi: 0.5])
        let unknown = summary([], unclassified: 20)
        let noKnown = ListeningLanguageProfile(summary: unknown, fallback: [.hindi])
        XCTAssertFalse(noKnown.isLearned)
        XCTAssertEqual(noKnown.weights, [.hindi: 1])
        XCTAssertEqual(noKnown.summary.unclassifiedPlays, 20)
        let learned = ListeningLanguageProfile(summary: summary([(.bengali, 1)]), fallback: [.english])
        XCTAssertTrue(learned.isLearned)
        XCTAssertEqual(learned.weights, [.bengali: 1])
    }

    func testLearnedWeightsUseQualifiedPlayCountsInsteadOfSecondsOrProviderPopularity() throws {
        var english = Fixtures.track("short-listens", language: .english)
        english.playCount = 1
        var hindi = Fixtures.track("long-listen", language: .hindi)
        hindi.playCount = Int64.max
        let events = [Fixtures.event(english, daysAgo: 1, seconds: 30), Fixtures.event(english, daysAgo: 2, seconds: 30),
                      Fixtures.event(hindi, daysAgo: 1, seconds: 3_600)]
        let counts = ListeningAnalytics.languageSummary(events: events, for: .week, now: Fixtures.now)
        let profile = ListeningLanguageProfile(summary: counts)
        XCTAssertEqual(counts.totalPlays, 3)
        XCTAssertEqual(try XCTUnwrap(counts.rows.first).share, 2.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(profile.weights[.english]), 0.65, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(profile.weights[.hindi]), 0.35, accuracy: 1e-12)
        XCTAssertEqual(profile.orderedLanguages, [.english, .hindi])
    }

    func testMoreActivatesAnUnseenLanguageWithoutInventingStatsOrCertifyingSongs() throws {
        let counts = summary([(.english, 10)])
        var nudges = LanguageRecommendationNudges()
        nudges[.tamil] = .more
        let profile = ListeningLanguageProfile(summary: counts, nudges: nudges)
        XCTAssertEqual(profile.summary, counts)
        XCTAssertEqual(profile.summary.rows.map(\.language), [.english])
        XCTAssertEqual(try XCTUnwrap(profile.weights[.english]), 1 / 1.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(profile.weights[.tamil]), 0.2 / 1.2, accuracy: 1e-12)
        XCTAssertNil(profile.weights[.hindi])
        XCTAssertEqual(profile.scheduledLanguages(count: 3), [.english, .tamil, .english])
        let unknown = Fixtures.track("unknown", title: "A song (Tamil Version)")
        XCTAssertNil(profile.language(for: unknown))
        XCTAssertEqual(profile.multiplier(for: unknown), 1)
        let cold = ListeningLanguageProfile(nudges: nudges, fallback: [.english])
        XCTAssertFalse(cold.isLearned)
        XCTAssertEqual(cold.summary, .init())
        XCTAssertEqual(Set(cold.orderedLanguages), [.english, .tamil])
    }

    func testMoreDoublesObservedWeightAndLessUsesASoftQuarterWeight() throws {
        let counts = summary([(.english, 4), (.hindi, 4)])
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .more
        let more = ListeningLanguageProfile(summary: counts, nudges: nudges)
        XCTAssertEqual(try XCTUnwrap(more.weights[.hindi]), 2.0 / 3, accuracy: 1e-12)
        nudges[.hindi] = .less
        let less = ListeningLanguageProfile(summary: counts, nudges: nudges, overrides: ["bengali": "bn"])
        XCTAssertEqual(try XCTUnwrap(less.weights[.hindi]), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(less.weights[.english]), 0.8, accuracy: 1e-12)
        XCTAssertEqual(less.multiplier(for: Fixtures.track("hindi", language: .hindi)), 0.88, accuracy: 1e-12)
        XCTAssertEqual(less.multiplier(for: Fixtures.track("bengali")), 0.6)
        XCTAssertEqual(less.multiplier(for: Fixtures.track("unclassified")), 1)
        XCTAssertEqual(less.summary, counts)
        XCTAssertEqual(more.summary, counts)
        for track in [Fixtures.track("english", language: .english), Fixtures.track("hindi", language: .hindi),
                      Fixtures.track("bengali")] {
            XCTAssertTrue((0.6...2).contains(less.multiplier(for: track)))
        }
    }

    func testLessDoesNotActivateUnobservedLanguagesOrBanTheOnlyObservedLanguage() {
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .less
        nudges[.telugu] = .less
        let profile = ListeningLanguageProfile(summary: summary([(.hindi, 3)]), nudges: nudges)
        XCTAssertEqual(profile.weights, [.hindi: 1])
        XCTAssertEqual(profile.scheduledLanguages(count: 3), [.hindi, .hindi, .hindi])
        XCTAssertEqual(profile.multiplier(for: Fixtures.track("hindi", language: .hindi)), 2)
    }

    func testSchedulingPreservesProportionsBudgetAndDeterministicTies() {
        let counts = summary([(.hindi, 1), (.english, 2)])
        let profile = ListeningLanguageProfile(summary: counts)
        let scheduled = profile.scheduledLanguages(count: 20)
        XCTAssertEqual(scheduled.count, 20)
        XCTAssertEqual(scheduled.filter { $0 == .english }.count, 13)
        XCTAssertEqual(scheduled.filter { $0 == .hindi }.count, 7)
        var reversed = counts
        reversed.rows.reverse()
        XCTAssertEqual(scheduled, ListeningLanguageProfile(summary: reversed).scheduledLanguages(count: 20))
        XCTAssertTrue(profile.scheduledLanguages(count: 0).isEmpty)
        XCTAssertTrue(profile.scheduledLanguages(count: -1).isEmpty)
        let tied = ListeningLanguageProfile(summary: summary([(.tamil, 1), (.english, 1), (.bengali, 1)]))
        XCTAssertEqual(tied.orderedLanguages, [.bengali, .english, .tamil])
        XCTAssertEqual(tied.scheduledLanguages(count: 5), [.bengali, .english, .tamil, .bengali, .english])
        for budget in 1...40 {
            XCTAssertEqual(tied.scheduledLanguages(count: budget).count, budget)
            XCTAssertEqual(profile.scheduledLanguages(count: budget).count, budget)
        }
    }

    func testSecondActiveLanguageGetsAnExistingSlotWhenTheBudgetIsAtLeastThree() {
        var nudges = LanguageRecommendationNudges()
        nudges[.hindi] = .less
        let profile = ListeningLanguageProfile(summary: summary([(.english, 999), (.hindi, 1)]), nudges: nudges)
        XCTAssertEqual(profile.scheduledLanguages(count: 2), [.english, .english])
        XCTAssertEqual(profile.scheduledLanguages(count: 3), [.english, .hindi, .english])
        for budget in 3...12 {
            let scheduled = profile.scheduledLanguages(count: budget)
            XCTAssertEqual(scheduled.count, budget)
            XCTAssertTrue(scheduled.contains(.hindi))
        }
    }

    func testRequestKeyUsesQuantizedWeightsAndNudgesRatherThanCountsOrEvidenceIdentity() {
        let original = ListeningLanguageProfile(summary: summary([(.english, 9), (.hindi, 1)]))
        let scaled = ListeningLanguageProfile(summary: summary([(.english, 90), (.hindi, 10)]))
        let nearby = ListeningLanguageProfile(summary: summary([(.english, 901), (.hindi, 99)], unclassified: 200))
        XCTAssertEqual(original.requestKey, scaled.requestKey)
        XCTAssertEqual(original.requestKey, nearby.requestKey)
        let song = Fixtures.track("sensitive-recording-identity")
        let changedEvidence = ListeningLanguageProfile(summary: original.summary,
            evidence: [LyricsRequestKey(song): .identified(.telugu, source: .linkedLyrics)], overrides: [song.id: "te"])
        XCTAssertEqual(original.requestKey, changedEvidence.requestKey)
        XCTAssertFalse(changedEvidence.requestKey.contains(song.id))
        XCTAssertLessThanOrEqual(changedEvidence.requestKey.utf8.count, 128)
        var nudges = LanguageRecommendationNudges()
        nudges[.bengali] = .less
        XCTAssertNotEqual(original.requestKey, ListeningLanguageProfile(summary: original.summary, nudges: nudges).requestKey)
        XCTAssertNotEqual(original.requestKey, ListeningLanguageProfile(summary: summary([(.hindi, 9), (.english, 1)])).requestKey)
    }

    private func summary(_ counts: [(ArtistSongLanguage, Int)], unclassified: Int = 0) -> ListeningLanguageSummary {
        let total = counts.reduce(unclassified) { $0 + $1.1 }
        let rows = counts.map { LanguageListeningStat(language: $0.0, plays: $0.1, songs: 1,
                                                      share: Double($0.1) / Double(max(1, total))) }
        return ListeningLanguageSummary(rows: rows, unclassifiedPlays: unclassified,
            unclassifiedSongs: unclassified > 0 ? 1 : 0, totalPlays: total, totalSongs: rows.count + (unclassified > 0 ? 1 : 0))
    }
}
