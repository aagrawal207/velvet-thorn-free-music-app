import XCTest
@testable import GanaBajana

@MainActor
final class ListeningLanguagePersistenceTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    func testNudgeDefaultsAndCodableInventoryHaveFiveFixedIndependentFields() throws {
        XCTAssertEqual(LanguageRecommendationNudge.allCases.map(\.title), ["Automatic", "More", "Less"])
        let defaults = UserPreferences()
        XCTAssertTrue(defaults.languageNudges.isAutomatic)
        let fields = try LibrarySyncPreferences.fields(defaults)
        let paths = ["bengali", "english", "hindi", "tamil", "telugu"].map { "languageNudges/\($0)" }
        XCTAssertEqual(Set(fields.keys.filter { $0.hasPrefix("languageNudges/") }), Set(paths))
        for path in paths { XCTAssertEqual(fields[path], Data("\"automatic\"".utf8)) }
        for language in ArtistSongLanguage.allCases {
            var nudges = LanguageRecommendationNudges()
            nudges[language] = .more
            XCTAssertFalse(nudges.isAutomatic)
            let restored = try LibrarySyncCodec.decode(LanguageRecommendationNudges.self, from: LibrarySyncCodec.encode(nudges))
            XCTAssertEqual(restored, nudges)
            XCTAssertEqual(restored[language], .more)
            XCTAssertTrue(ArtistSongLanguage.allCases.filter { $0 != language }.allSatisfy { restored[$0] == .automatic })
            nudges[language] = .automatic
            XCTAssertTrue(nudges.isAutomatic)
        }
    }

    func testMissingNudgeFieldsDefaultWithoutConvertingLegacyLanguageChoices() throws {
        for json in [#"{"languages":["english"]}"#, #"{"languages":["english"],"languageNudges":null}"#] {
            let preferences = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.languages, [.english])
            XCTAssertTrue(preferences.languageNudges.isAutomatic)
            let profile = ListeningLanguageProfile(nudges: preferences.languageNudges, fallback: preferences.languages)
            XCTAssertFalse(profile.isLearned)
            XCTAssertEqual(profile.summary, .init())
        }
        let partial = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(#"{"languageNudges":{"tamil":"more"}}"#.utf8))
        XCTAssertEqual(partial.languageNudges[.tamil], .more)
        XCTAssertEqual(partial.languageNudges[.english], .automatic)
        XCTAssertEqual(partial.languageNudges[.hindi], .automatic)
        XCTAssertEqual(try LibrarySyncPreferences.fields(partial).keys.filter { $0.hasPrefix("languageNudges/") }.count, 5)
        for json in [#"{"languageNudges":true}"#, #"{"languageNudges":{"english":"boost"}}"#,
                     #"{"languageNudges":{"hindi":2}}"#] {
            XCTAssertThrowsError(try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8)))
        }
    }

    func testLegacyV1AndV2LibrariesAndJournalsRoundTripWithoutInventingNudgesOrPlays() throws {
        for (version, journal) in [(1, false), (2, false), (2, true)] {
            try withLibraryTestDirectory { directory in
                let now = LibrarySyncTestData.now
                let song = Fixtures.track("legacy-unknown")
                let favorite = Fixtures.track("legacy-favorite", language: .hindi)
                var legacy = LibraryDocument()
                legacy.version = version
                legacy.preferences.languages = [.english]
                legacy.preferences.appearance = .light
                legacy.preferences.saveListeningHistory = false
                legacy.events = [Fixtures.event(song, daysAgo: 1, seconds: 30, now: now)]
                legacy.favorites = [favorite]
                legacy.recentlyPlayed = [RecentListen(track: favorite, playedAt: now, position: 150)]
                legacy.playback = PlaybackSnapshot(queue: [favorite], position: 150)
                legacy.recordingLanguageOverrides = ["another-recording": "future-code"]
                if journal { legacy.syncState = try LibrarySyncJournal.seed(legacy, now: now, writer: LibrarySyncTestData.a) }
                if let state = legacy.syncState {
                    XCTAssertFalse(state.registers.keys.contains { $0.collection == .preference && $0.id.hasPrefix("languageNudges/") })
                    let replica = LibrarySyncReplica(replicaID: LibrarySyncTestData.a, state: state)
                    let roundTrip = try LibrarySyncCodec.decodeReplica(LibrarySyncCodec.encodeReplica(replica),
                                                                      expectedReplicaID: replica.replicaID, now: now)
                    XCTAssertEqual(roundTrip, replica)
                }
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(legacy)) as? [String: Any])
                var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
                preferences.removeValue(forKey: "languageNudges")
                object["preferences"] = preferences
                let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)

                let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.a)
                XCTAssertNil(library.errorMessage)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertEqual(library.preferences.languages, [.english])
                XCTAssertTrue(library.preferences.languageNudges.isAutomatic)
                let summary = library.languageSummary(for: .week, now: now)
                XCTAssertEqual(summary.totalPlays, 1)
                XCTAssertEqual(summary.unclassifiedPlays, 1)
                XCTAssertFalse(ListeningLanguageProfile(summary: summary, fallback: library.preferences.languages).isLearned)
                let decoded = try LibraryPersistence.decode(bytes, now: now)
                XCTAssertEqual(try LibraryPersistence.decode(LibraryPersistence.encode(decoded), now: now).preferences, decoded.preferences)

                library.preferences.languageNudges[.bengali] = .more
                XCTAssertNil(library.errorMessage)
                let reopened = LibraryStore(directory: directory, now: { now })
                XCTAssertNil(reopened.errorMessage)
                XCTAssertEqual(reopened.preferences.languageNudges[.bengali], .more)
                XCTAssertEqual(reopened.preferences.languages, [.english])
                XCTAssertEqual(reopened.preferences.appearance, .light)
                XCTAssertFalse(reopened.preferences.saveListeningHistory)
                XCTAssertEqual(reopened.events.first?.id, legacy.events.first?.id)
                XCTAssertEqual(reopened.events.first?.listenedSeconds, 30)
                XCTAssertEqual(reopened.favorites, legacy.favorites)
                XCTAssertEqual(reopened.playback.queue, legacy.playback.queue)
                XCTAssertEqual(reopened.playback.position, 150)
                XCTAssertEqual(reopened.recentlyPlayed.first?.position, 150)
                XCTAssertEqual(reopened.recordingLanguageOverrides, legacy.recordingLanguageOverrides)
                let saved = try LibraryPersistence.decode(Data(contentsOf: url), now: now)
                XCTAssertEqual(saved.version, LibraryPersistence.currentVersion)
                try LibrarySyncValidation.validateLocal(saved, now: now)
                XCTAssertEqual(try LibrarySyncPreferences.fields(saved.preferences)["languages"], Data("[\"english\"]".utf8))
            }
        }
    }

    func testConcurrentNudgeEditsMergePerLanguageWithoutChangingOtherPreferenceRegisters() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences.languages = [.english]
        a.library.toggleFavorite(libraryTestTrack())
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.preferences.languageNudges[.hindi] = .less
        b.library.preferences.languageNudges[.tamil] = .more
        let left = try a.state()
        let right = try b.state()
        try a.library.mergeCloudState(right)
        try b.library.mergeCloudState(left)
        for library in [a.library, b.library] {
            XCTAssertEqual(library.preferences.languageNudges[.hindi], .less)
            XCTAssertEqual(library.preferences.languageNudges[.tamil], .more)
            XCTAssertEqual(library.preferences.languageNudges[.english], .automatic)
            XCTAssertEqual(library.preferences.languages, [.english])
        }
        let merged = try a.state()
        XCTAssertEqual(merged, try b.state())
        XCTAssertEqual(Set(merged.registers.keys.filter { $0.collection == .preference && $0.id.hasPrefix("languageNudges/") }), [
            LibrarySyncKey(.preference, "languageNudges/hindi"), LibrarySyncKey(.preference, "languageNudges/tamil")
        ])
        XCTAssertEqual(merged.registers[LibrarySyncKey(.preference, "languages")], baseline.registers[LibrarySyncKey(.preference, "languages")])
        XCTAssertEqual(merged.registers[LibrarySyncKey(.reaction, "song-a")], baseline.registers[LibrarySyncKey(.reaction, "song-a")])
        XCTAssertEqual(try a.saved().preferences.languageNudges, b.library.preferences.languageNudges)
        XCTAssertEqual(try b.saved().preferences.languageNudges, a.library.preferences.languageNudges)
    }

    func testResetToAutomaticIsDurableAndCannotBeUndoneByAStaleReplica() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences.languageNudges[.telugu] = .more
        let stale = try a.state()
        try b.library.mergeCloudState(stale)
        b.library.preferences.languageNudges[.english] = .less
        a.library.preferences.languageNudges[.telugu] = .automatic
        let reset = try a.state()
        let key = LibrarySyncKey(.preference, "languageNudges/telugu")
        XCTAssertEqual(reset.registers[key]?.value, Data("\"automatic\"".utf8))
        XCTAssertGreaterThan(try XCTUnwrap(reset.registers[key]?.revision), try XCTUnwrap(stale.registers[key]?.revision))
        try a.library.mergeCloudState(b.state())
        try b.library.mergeCloudState(reset)
        for library in [a.library, b.library] {
            try library.mergeCloudState(stale)
            XCTAssertEqual(library.preferences.languageNudges[.telugu], .automatic)
            XCTAssertEqual(library.preferences.languageNudges[.english], .less)
        }
        XCTAssertEqual(try a.saved().preferences.languageNudges[.telugu], .automatic)
        XCTAssertEqual(try b.saved().preferences.languageNudges[.telugu], .automatic)
    }

    func testFailedNudgeWriteKeepsAppliedPreferenceJournalAndCallbacksUnchangedUntilRetry() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            library.toggleFavorite(libraryTestTrack())
            let state = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = directory.appendingPathComponent("saved-library.json")
            let bytes = try Data(contentsOf: url)
            var callbacks = 0
            library.onSyncChange = { callbacks += 1 }
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            library.preferences.languageNudges[.tamil] = .more
            XCTAssertNotNil(library.errorMessage)
            XCTAssertTrue(library.preferences.languageNudges.isAutomatic)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            XCTAssertEqual(try library.cloudReplica(replicaID: LibrarySyncTestData.a).state, state)
            library.preferences.languageNudges[.tamil] = .more
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(LibraryStore(directory: directory, now: { now }).preferences.languageNudges[.tamil], .more)
        }
    }

    func testMalformedNudgeStoreIsPreservedAndCannotClaimAnAppliedChange() throws {
        try withLibraryTestDirectory { directory in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
            var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
            preferences["languageNudges"] = ["english": "future-nudge"]
            object["preferences"] = preferences
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let library = LibraryStore(directory: directory)
            XCTAssertTrue(library.requiresReload)
            XCTAssertFalse(library.hasLoadedDocument)
            library.preferences.languageNudges[.english] = .more
            XCTAssertTrue(library.preferences.languageNudges.isAutomatic)
            XCTAssertEqual(library.languageSummary(for: .year), .init())
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testRecentsQueueFavoritesAndProviderPlayCountsDoNotCreateLanguageListeningStats() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            var song = Fixtures.track("popular", language: .english)
            song.playCount = Int64.max
            library.recordRecent(track: song, position: 200)
            library.updatePlayback(PlaybackSnapshot(queue: [song], position: 200))
            library.toggleFavorite(song)
            library.preferences.languages = [.english]
            library.preferences.languageNudges[.hindi] = .more
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(library.languageSummary(for: .year, now: now), .init())
            XCTAssertEqual(LibraryStore(directory: directory, now: { now }).languageSummary(for: .year, now: now), .init())
        }
    }

    func testAcknowledgedDeltasQualifyOnePlayPerSessionAcrossReload() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            let song = Fixtures.track("checkpoint", language: .hindi)
            let session = UUID()
            let start = now.addingTimeInterval(-300)
            XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            XCTAssertEqual(library.languageSummary(for: .week, now: now), .init())
            XCTAssertTrue(library.recordListening(track: song, sessionID: session, startedAt: start, seconds: 15))
            XCTAssertEqual(library.languageSummary(for: .week, now: now).totalPlays, 1)
            let requestKey = ListeningLanguageProfile(summary: library.languageSummary(for: .week, now: now)).requestKey
            let reopened = LibraryStore(directory: directory, now: { now })
            XCTAssertTrue(reopened.recordListening(track: song, sessionID: session, startedAt: start, seconds: 100))
            XCTAssertEqual(reopened.languageSummary(for: .week, now: now).totalPlays, 1)
            XCTAssertEqual(ListeningLanguageProfile(summary: reopened.languageSummary(for: .week, now: now)).requestKey, requestKey)
            XCTAssertTrue(reopened.recordListening(track: song, sessionID: UUID(), startedAt: start, seconds: 30))
            let result = reopened.languageSummary(for: .week, now: now)
            XCTAssertEqual(result.totalPlays, 2)
            XCTAssertEqual(result.totalSongs, 1)
            XCTAssertEqual(result.rows, [LanguageListeningStat(language: .hindi, plays: 2, songs: 1, share: 1)])
        }
    }

    func testStoreWrapperAppliesCurrentCorrectionsAheadOfSuppliedEvidence() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            let song = Fixtures.track("inferred")
            let evidence: [LyricsRequestKey: ArtistSongLanguageResult] = [LyricsRequestKey(song): .identified(.telugu, source: .linkedLyrics)]
            XCTAssertTrue(library.recordListening(track: song, sessionID: UUID(), startedAt: now, seconds: 30))
            XCTAssertEqual(library.languageSummary(for: .week, now: now, evidence: evidence).rows.first?.language, .telugu)
            XCTAssertTrue(library.setRecordingLanguageOverride("bn", for: song.id))
            XCTAssertEqual(library.languageSummary(for: .week, now: now, evidence: evidence).rows.first?.language, .bengali)
            XCTAssertTrue(library.setRecordingLanguageOverride("und", for: song.id))
            XCTAssertEqual(library.languageSummary(for: .week, now: now, evidence: evidence).unclassifiedPlays, 1)
            XCTAssertTrue(library.setRecordingLanguageOverride(nil, for: song.id))
            XCTAssertEqual(library.languageSummary(for: .week, now: now, evidence: evidence).rows.first?.language, .telugu)
            let reopened = LibraryStore(directory: directory, now: { now })
            XCTAssertEqual(reopened.languageSummary(for: .week, now: now).unclassifiedPlays, 1, "Automatic evidence stays memory-only")
        }
    }

    func testHistoryClearResetsDerivedCountsAndRejectsStaleHistoryWhileKeepingNudges() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let now = LibrarySyncTestData.now
        let song = Fixtures.track("clear", language: .english)
        a.library.preferences.languageNudges[.tamil] = .more
        XCTAssertTrue(a.library.setRecordingLanguageOverride("bn", for: song.id))
        XCTAssertTrue(a.library.recordListening(track: song, sessionID: UUID(), startedAt: now, seconds: 30))
        a.library.recordRecent(track: song, position: 30)
        a.library.toggleFavorite(song)
        let before = a.library.languageSummary(for: .week, now: now)
        XCTAssertEqual(before.rows.first?.language, .bengali)
        XCTAssertTrue(ListeningLanguageProfile(summary: before).isLearned)
        let stale = try a.state()
        a.library.clearHistory()
        XCTAssertNil(a.library.errorMessage)
        try a.library.mergeCloudState(stale)
        let reopened = LibraryStore(directory: a.directory, now: { now })
        XCTAssertEqual(reopened.languageSummary(for: .year, now: now), .init())
        XCTAssertTrue(reopened.recentlyPlayed.isEmpty)
        XCTAssertEqual(reopened.preferences.languageNudges[.tamil], .more)
        XCTAssertEqual(reopened.recordingLanguageOverrides[song.id], "bn")
        XCTAssertTrue(reopened.isFavorite(song))
        let profile = ListeningLanguageProfile(summary: reopened.languageSummary(for: .week, now: now),
                                               nudges: reopened.preferences.languageNudges)
        XCTAssertFalse(profile.isLearned)
        XCTAssertEqual(profile.summary.totalPlays, 0)
    }

    func testDisabledHistoryStopsNewLearningWithoutDeletingSavedCountsOrNudges() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now })
            let english = Fixtures.track("saved", language: .english)
            let hindi = Fixtures.track("disabled", language: .hindi)
            let session = UUID()
            XCTAssertTrue(library.recordListening(track: english, sessionID: session, startedAt: now, seconds: 30))
            library.preferences.languageNudges[.hindi] = .less
            let before = library.languageSummary(for: .week, now: now)
            library.preferences.saveListeningHistory = false
            XCTAssertTrue(library.recordListening(track: english, sessionID: session, startedAt: now, seconds: 100))
            XCTAssertTrue(library.recordListening(track: hindi, sessionID: UUID(), startedAt: now, seconds: 300))
            library.recordRecent(track: hindi, position: 200)
            XCTAssertEqual(library.languageSummary(for: .week, now: now), before)
            XCTAssertTrue(library.recentlyPlayed.isEmpty)
            let reopened = LibraryStore(directory: directory, now: { now })
            XCTAssertEqual(reopened.languageSummary(for: .week, now: now), before)
            XCTAssertEqual(reopened.preferences.languageNudges[.hindi], .less)
            reopened.preferences.saveListeningHistory = true
            XCTAssertTrue(reopened.recordListening(track: hindi, sessionID: UUID(), startedAt: now, seconds: 30))
            let after = reopened.languageSummary(for: .week, now: now)
            XCTAssertEqual(after.totalPlays, 2)
            XCTAssertEqual(after.totalSongs, 2)
            XCTAssertTrue(after.rows.allSatisfy { $0.plays == 1 && $0.share == 0.5 })
        }
    }
}
