import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryPlaybackDiscoveryPreferencesTests: XCTestCase {
    func testStableChoicesTitlesAndAbsentFieldDefaults() throws {
        XCTAssertEqual(ShuffleStyle.allCases.map(\.rawValue), ["random", "fewerRepeats"])
        XCTAssertEqual(ShuffleStyle.allCases.map(\.id), ["random", "fewerRepeats"])
        XCTAssertEqual(ShuffleStyle.allCases.map(\.title), ["Random", "Fewer repeats"])
        XCTAssertEqual(DiscoveryFamiliarity.allCases.map(\.rawValue), ["familiar", "balanced", "newMusic"])
        XCTAssertEqual(DiscoveryFamiliarity.allCases.map(\.id), ["familiar", "balanced", "newMusic"])
        XCTAssertEqual(DiscoveryFamiliarity.allCases.map(\.title), ["More familiar", "Balanced", "More new"])
        XCTAssertEqual(UserPreferences().shuffleStyle, .fewerRepeats)
        XCTAssertFalse(UserPreferences().shuffleDefaultMigrated)
        XCTAssertEqual(UserPreferences().discoveryFamiliarity, .balanced)
        let cases: [(String, ShuffleStyle, DiscoveryFamiliarity)] = [
            (#"{}"#, .fewerRepeats, .balanced),
            (#"{"shuffleStyle":"fewerRepeats"}"#, .fewerRepeats, .balanced),
            (#"{"shuffleStyle":"random"}"#, .random, .balanced),
            (#"{"discoveryFamiliarity":"familiar"}"#, .fewerRepeats, .familiar)
        ]
        for (json, shuffle, familiarity) in cases {
            let preferences = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.shuffleStyle, shuffle)
            XCTAssertEqual(preferences.discoveryFamiliarity, familiarity)
            XCTAssertFalse(preferences.automix)
            XCTAssertEqual(preferences.crossfadeSeconds, 0)
        }
    }

    func testPlayerQualityEqualizerAndSourceChoicesHaveStableRawValuesTitlesAndDefaults() throws {
        XCTAssertEqual(TrailingTimeStyle.allCases.map(\.rawValue), ["songLength", "remaining"])
        XCTAssertEqual(TrailingTimeStyle.allCases.map(\.title), ["Song length", "Time remaining"])
        XCTAssertEqual(AudioQualityPreference.allCases.map(\.rawValue), ["best", "balanced", "dataSaver"])
        XCTAssertEqual(AudioQualityPreference.allCases.map(\.title), ["Best available", "Balanced", "Data saver"])
        XCTAssertEqual(AudioQualityPreference.allCases.map(\.maximumBitRate), [nil, 160_000, 64_000])
        XCTAssertEqual(AudioQualityPreference.best.detail, "Highest bitrate offered, including higher tiers when available")
        XCTAssertEqual(AudioQualityPreference.balanced.detail, "Up to 160 kbps")
        XCTAssertEqual(AudioQualityPreference.dataSaver.detail, "Up to 64 kbps")
        XCTAssertEqual(EqualizerPreset.bandFrequencies, [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
        XCTAssertEqual(EqualizerPreset.allCases.map(\.rawValue),
                       ["flat", "bassBoost", "bassReducer", "trebleBoost", "vocal", "rock", "pop", "jazz",
                        "electronic", "acoustic", "loudness", "custom"])
        XCTAssertEqual(EqualizerSettings.gainRange, -12...12)
        for preset in EqualizerPreset.allCases {
            XCTAssertEqual(preset.gains.count, EqualizerPreset.bandFrequencies.count, preset.rawValue)
            XCTAssertTrue(preset.gains.allSatisfy { EqualizerSettings.gainRange.contains($0) }, preset.rawValue)
            XCTAssertFalse(preset.title.isEmpty, preset.rawValue)
        }
        XCTAssertEqual(EqualizerPreset.flat.gains, Array(repeating: 0, count: 10))
        XCTAssertEqual(EqualizerPreset.custom.gains, Array(repeating: 0, count: 10))
        XCTAssertEqual(EqualizerPreset.bassBoost.gains, [6, 5, 4, 2, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(EqualizerPreset.loudness.gains, [6, 4, 0, 0, -2, 0, -1, -5, 5, 1])
        XCTAssertEqual(MusicSource.allCases.map(\.rawValue), ["youtube", "saavn", "gaana"])
        XCTAssertEqual(MusicSource.allCases.map(\.id), ["youtube", "saavn", "gaana"])
        XCTAssertEqual(MusicSource.allCases.map(\.title), ["YouTube Music", "JioSaavn", "Gaana"])

        let defaults = UserPreferences()
        XCTAssertEqual(defaults.trailingTimeStyle, .songLength)
        XCTAssertEqual(defaults.audioQuality, .best)
        XCTAssertEqual(defaults.equalizer, EqualizerSettings())
        XCTAssertFalse(defaults.equalizer.isEnabled)
        XCTAssertEqual(defaults.equalizer.preset, .flat)
        XCTAssertEqual(defaults.equalizer.gains, Array(repeating: 0, count: 10))
        XCTAssertEqual(defaults.equalizer.preamp, 0)
        XCTAssertEqual(defaults.equalizer.effectiveGains, Array(repeating: 0, count: 10))
        XCTAssertFalse(defaults.downloadsOverCellular)
        XCTAssertFalse(defaults.autoDownloadLikedSongs)
        XCTAssertEqual(defaults.enabledCatalogSources, MusicSource.allCases)
        XCTAssertFalse(defaults.sponsorBlockSkipping)

        var equalizer = EqualizerSettings(isEnabled: true, preset: .rock, gains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], preamp: -3)
        XCTAssertEqual(equalizer.effectiveGains, EqualizerPreset.rock.gains, "A named preset ignores the stored custom curve")
        equalizer.preset = .custom
        XCTAssertEqual(equalizer.effectiveGains, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    func testEveryChoicePairRoundTripsAsIndependentScalarsOutsideThePlaybackSnapshot() throws {
        for shuffle in ShuffleStyle.allCases {
            for familiarity in DiscoveryFamiliarity.allCases {
                try withLibraryTestDirectory { directory in
                    let now = LibrarySyncTestData.now
                    let library = LibraryStore(directory: directory, now: { now })
                    let first = libraryTestTrack("first")
                    let second = libraryTestTrack("second")
                    let playback = PlaybackSnapshot(queue: [second, first, second], currentIndex: 1, position: 27.25,
                                                    shuffleEnabled: true, repeatMode: .one, originalQueue: [first, second, second])
                    library.updatePlayback(playback)
                    var preferences = library.preferences
                    preferences.shuffleStyle = shuffle
                    preferences.discoveryFamiliarity = familiarity
                    preferences.saveListeningHistory = false
                    preferences.autoplay = false
                    preferences.newReleaseAlerts = false
                    preferences.useEncryptedDNS = false
                    library.preferences = preferences
                    XCTAssertNil(library.errorMessage)
                    let reopened = LibraryStore(directory: directory, now: { now })
                    XCTAssertNil(reopened.errorMessage)
                    XCTAssertEqual(reopened.preferences, preferences)
                    XCTAssertEqual(try LibrarySyncCodec.encode(reopened.playback), try LibrarySyncCodec.encode(playback))
                    let fields = try LibrarySyncPreferences.fields(reopened.preferences)
                    XCTAssertEqual(fields["shuffleStyle"], Data("\"\(shuffle.rawValue)\"".utf8))
                    XCTAssertEqual(fields["discoveryFamiliarity"], Data("\"\(familiarity.rawValue)\"".utf8))
                    XCTAssertEqual(try LibrarySyncPreferences.applying(fields, to: UserPreferences()), preferences)
                    let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(reopened.playback)) as? [String: Any])
                    XCTAssertNil(snapshot["shuffleStyle"])
                    XCTAssertNil(snapshot["discoveryFamiliarity"])
                }
            }
        }
    }

    func testV1V2AndV3LibrariesDefaultMissingChoicesWithoutWritingOrRestampingOldJournals() throws {
        let formats: [(Int, Int?)] = [(1, nil), (2, nil), (2, 1), (3, nil), (3, 1), (3, 2)]
        for (version, journalVersion) in formats {
            try withLibraryTestDirectory { directory in
                let now = LibrarySyncTestData.now
                let song = libraryTestTrack("legacy")
                let other = libraryTestTrack("other")
                var legacy = LibraryDocument()
                legacy.version = version
                legacy.favorites = [song]
                legacy.playlists = [UserPlaylist(id: LibrarySyncTestData.c, name: "Saved songs", tracks: [song, other],
                                                createdAt: now, updatedAt: now)]
                legacy.events = [ListeningEvent(id: LibrarySyncTestData.b, track: song, startedAt: now, listenedSeconds: 45.25)]
                legacy.recentlyPlayed = [RecentListen(track: song, playedAt: now, position: 31.5)]
                legacy.recentSearches = ["Beyoncé", "Earlier query"]
                if version == 3, journalVersion != 1 { legacy.recentSearchSelections = [.track(song)] }
                legacy.playback = PlaybackSnapshot(queue: [other, song, other], currentIndex: 1, position: 31.5,
                                                   shuffleEnabled: true, repeatMode: .one, originalQueue: [song, other, other])
                legacy.preferences.languages = [.english]
                legacy.preferences.languageNudges[.bengali] = .more
                legacy.preferences.languageNudges[.hindi] = .less
                legacy.preferences.appearance = .light
                legacy.preferences.accent = try XCTUnwrap(AppAccent.allCases.first { $0 != legacy.preferences.accent })
                legacy.preferences.appIconID = "Sonnet"
                legacy.preferences.hasCompletedWelcome = true
                legacy.preferences.saveListeningHistory = false
                legacy.preferences.allowRemoteFallback = true
                legacy.preferences.useEncryptedDNS = false
                legacy.preferences.autoplay = false
                legacy.preferences.gaplessPlayback = false
                legacy.preferences.normalizeVolume = false
                legacy.preferences.automix = true
                legacy.preferences.crossfadeSeconds = 3.25
                legacy.preferences.audioCacheLimit = try XCTUnwrap(AudioCacheLimit.allCases.first { $0 != legacy.preferences.audioCacheLimit })
                legacy.preferences.homeLayout.setVisible(false, for: .charts)
                legacy.preferences.homeLayout.move(from: IndexSet(integer: 0), to: 3)
                legacy.lyricsOffsets = [song.id: -0.125]
                legacy.recordingLanguageOverrides = [song.id: "future-language-code"]
                legacy.disliked = [DislikedSong(id: "disliked", title: "Disliked song", artists: ["Artist"], dislikedAt: now)]
                legacy.followedArtists = [FollowedArtist(id: "artist", name: "Artist", followedAt: now,
                                                        knownReleaseIDs: ["release"], hasEstablishedReleaseBaseline: true)]
                legacy.releases = [ArtistRelease(id: "release", title: "Release", subtitle: "", artistID: "artist",
                                                 artistName: "Artist", discoveredAt: now)]
                legacy.mixes = [GeneratedPlaylist(kind: .dailyMix, tracks: [song], generatedAt: now, periodKey: "saved-day", seedArtists: [])]
                legacy.tipTransactions = ["123": true, "456": false]
                legacy.pendingReleaseNotificationIDs = ["release"]
                legacy.listeningHistoryEpoch = LibrarySyncTestData.c
                if let journalVersion {
                    var state = try LibrarySyncJournal.seed(legacy, now: now, writer: LibrarySyncTestData.a)
                    state.version = journalVersion
                    state.registers = state.registers.filter { $0.key.collection != .lifetimeSession }
                    legacy.syncState = state
                }
                let bytes = try withoutNewPreferences(legacy)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.a)
                XCTAssertNil(library.errorMessage, "Library v\(version), journal \(String(describing: journalVersion))")
                XCTAssertEqual(library.preferences, legacy.preferences)
                XCTAssertEqual(library.preferences.shuffleStyle, .fewerRepeats)
                XCTAssertFalse(library.preferences.shuffleDefaultMigrated)
                XCTAssertEqual(library.preferences.discoveryFamiliarity, .balanced)
                let decoded = try LibraryPersistence.decode(bytes, now: now)
                XCTAssertEqual(decoded.version, LibraryPersistence.currentVersion)
                XCTAssertEqual(decoded.syncState?.registers.filter { $0.key.collection != .lifetimeSession }, legacy.syncState?.registers)
                XCTAssertEqual(decoded.lifetimeListening.summary.seconds, 45.25)
                XCTAssertEqual(decoded.lifetimeListening.summary.plays, 1)
                if let state = legacy.syncState {
                    let receiptKey = LibrarySyncKey(.lifetimeSession, LibrarySyncTestData.b.uuidString)
                    XCTAssertEqual(decoded.syncState?.registers[receiptKey]?.revision,
                                   state.registers[LibrarySyncKey(.event, LibrarySyncTestData.b.uuidString)]?.revision)
                    XCTAssertEqual(decoded.syncState?.registers.count, state.registers.count + 1)
                }
                XCTAssertEqual(decoded.syncState?.clock, legacy.syncState?.clock)
                if legacy.syncState != nil {
                    XCTAssertEqual(try library.cloudReplica(replicaID: LibrarySyncTestData.a).state, decoded.syncState)
                }
                let unchanged = library.preferences
                library.preferences = unchanged
                library.updatePlayback(library.playback)
                XCTAssertEqual(try Data(contentsOf: url), bytes)

                library.preferences.shuffleStyle = .random
                XCTAssertNil(library.errorMessage)
                let saved = try LibraryPersistence.decode(Data(contentsOf: url), now: now)
                var expected = legacy
                for event in expected.events { try expected.lifetimeListening.include(event) }
                expected.preferences.shuffleStyle = .random
                XCTAssertEqual(try LibrarySyncProjection.values(saved), try LibrarySyncProjection.values(expected))
                XCTAssertEqual(saved.playlists, legacy.playlists)
                XCTAssertEqual(saved.recentSearches, legacy.recentSearches)
                XCTAssertEqual(saved.recentSearchSelections, legacy.recentSearchSelections)
                XCTAssertEqual(try LibrarySyncCodec.encode(saved.playback), try LibrarySyncCodec.encode(legacy.playback))
                XCTAssertEqual(saved.tipTransactions, legacy.tipTransactions)
                XCTAssertEqual(saved.pendingReleaseNotificationIDs, legacy.pendingReleaseNotificationIDs)
                XCTAssertEqual(saved.listeningHistoryEpoch, legacy.listeningHistoryEpoch)
                XCTAssertEqual(saved.syncState?.version, LibrarySyncState.currentVersion)
                let shuffleKey = LibrarySyncKey(.preference, "shuffleStyle")
                XCTAssertEqual(saved.syncState?.registers[shuffleKey]?.value, Data("\"random\"".utf8))
                XCTAssertNil(saved.syncState?.registers[LibrarySyncKey(.preference, "discoveryFamiliarity")])
                if let original = legacy.syncState {
                    XCTAssertEqual(saved.syncState?.registers.filter { $0.key != shuffleKey }, decoded.syncState?.registers)
                    XCTAssertEqual(saved.syncState?.historyRetirement, original.historyRetirement)
                }
                XCTAssertEqual(LibraryStore(directory: directory, now: { now }).preferences, expected.preferences)
            }
        }
    }

    func testCurrentSparseJournalKeepsSearchFloorsGenerationsAndTombstonesThroughFirstPreferenceEdit() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let song = libraryTestTrack("Selected")
            let selection = SearchSelection.track(song)
            let event = ListeningEvent(id: LibrarySyncTestData.c, track: song, startedAt: now, listenedSeconds: 40)
            var state = LibrarySyncState()
            state.historyReset = LibrarySyncTestData.revision(1)
            state.historyRetirement = LibrarySyncTestData.revision(2)
            state.searchReset = LibrarySyncTestData.revision(3)
            state.searchFloor = LibrarySyncSearchBoundary(revision: LibrarySyncTestData.revision(4), key: "expired query")
            state.searchSelectionFloor = LibrarySyncSearchBoundary(revision: LibrarySyncTestData.revision(5), key: "track:Expired")
            state.clock = LibrarySyncTestData.revision(9)
            state.put(LibrarySyncKey(.preference, "saveListeningHistory"), value: Data("false".utf8), revision: LibrarySyncTestData.revision(6))
            state.put(LibrarySyncKey(.search, "kept query"), value: try LibrarySyncCodec.encode("Kept query"), revision: LibrarySyncTestData.revision(7))
            state.put(LibrarySyncKey(.searchSelection, selection.id), value: try LibrarySyncCodec.encode(selection), revision: LibrarySyncTestData.revision(8))
            state.put(LibrarySyncKey(.event, event.id.uuidString), value: try LibrarySyncCodec.encode(event), revision: LibrarySyncTestData.revision(9))
            state.put(LibrarySyncKey(.lifetimeSession, event.id.uuidString),
                      value: try LibrarySyncCodec.encode(LifetimeListeningContribution(event)), revision: LibrarySyncTestData.revision(9))
            state.put(LibrarySyncKey(.reaction, "removed"), value: nil, revision: LibrarySyncTestData.revision(9))
            var legacy = try LibrarySyncTestData.rendered(state)
            legacy.listeningHistoryEpoch = LibrarySyncTestData.b
            let bytes = try withoutNewPreferences(legacy)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(bytes, to: url, replacing: nil)
            let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.b)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(try library.cloudReplica(replicaID: LibrarySyncTestData.b).state, state)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            var localChanges = 0
            var remoteChanges = 0
            var historyClears = 0
            library.onSyncChange = { localChanges += 1 }
            library.onCloudSyncApplied = { _, _ in remoteChanges += 1 }
            library.onHistoryCleared = { historyClears += 1 }
            var preferences = library.preferences
            preferences.shuffleStyle = .random
            preferences.discoveryFamiliarity = .newMusic
            library.preferences = preferences
            XCTAssertNil(library.errorMessage)
            let saved = try LibraryPersistence.decode(Data(contentsOf: url), now: now)
            var retained = try XCTUnwrap(saved.syncState)
            XCTAssertEqual(retained.registers.removeValue(forKey: LibrarySyncKey(.preference, "shuffleStyle"))?.value, Data("\"random\"".utf8))
            XCTAssertEqual(retained.registers.removeValue(forKey: LibrarySyncKey(.preference, "discoveryFamiliarity"))?.value, Data("\"newMusic\"".utf8))
            XCTAssertGreaterThan(try XCTUnwrap(retained.clock), try XCTUnwrap(state.clock))
            retained.clock = state.clock
            XCTAssertEqual(retained, state)
            XCTAssertEqual(saved.listeningHistoryEpoch, legacy.listeningHistoryEpoch)
            XCTAssertEqual(saved.recentSearches, ["Kept query"])
            XCTAssertEqual(saved.recentSearchSelections, [selection])
            XCTAssertEqual(saved.events.first?.listenedSeconds, 40)
            XCTAssertFalse(saved.preferences.saveListeningHistory)
            XCTAssertEqual(localChanges, 1)
            XCTAssertEqual(remoteChanges, 0)
            XCTAssertEqual(historyClears, 0)
        }
    }

    func testFailedLocalPreferenceWritePublishesNeitherChoiceJournalNorCallbacksAndCanRetry() throws {
        try withLibraryTestDirectory { directory in
            let now = LibrarySyncTestData.now
            let library = LibraryStore(directory: directory, now: { now }, writerID: LibrarySyncTestData.a)
            library.toggleFavorite(libraryTestTrack())
            library.preferences.shuffleStyle = .random
            library.preferences.discoveryFamiliarity = .familiar
            let before = library.preferences
            let state = try library.cloudReplica(replicaID: LibrarySyncTestData.a).state
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = directory.appendingPathComponent("saved.json")
            let bytes = try Data(contentsOf: url)
            var callbacks = 0
            library.onSyncChange = { callbacks += 1 }
            library.onCloudSyncApplied = { _, _ in XCTFail("A local edit cannot acknowledge a remote merge") }
            library.onHistoryCleared = { XCTFail("These choices do not clear listening history") }
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            var desired = before
            desired.shuffleStyle = .fewerRepeats
            desired.discoveryFamiliarity = .newMusic
            library.preferences = desired
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(library.preferences, before)
            XCTAssertEqual(library.storageBytes, Int64(bytes.count))
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            XCTAssertEqual(try library.cloudReplica(replicaID: LibrarySyncTestData.a).state, state)
            library.preferences = desired
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(LibraryStore(directory: directory, now: { now }).preferences, desired)
        }
    }

    func testUnknownNullAndMalformedChoicesAndCorruptOrFutureLibrariesArePreserved() throws {
        var document = LibraryDocument()
        document.favorites = [libraryTestTrack("keep")]
        var invalids = [Data("{broken".utf8), Data("{\"version\":9999,\"future\":true}".utf8)]
        let payloads: [Any] = ["future-choice", "", NSNull(), true, 1, ["choice": "random"], ["balanced"]]
        for field in ["shuffleStyle", "discoveryFamiliarity"] {
            for payload in payloads {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
                preferences[field] = payload
                object["preferences"] = preferences
                invalids.append(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
            }
        }
        for bytes in invalids {
            try withLibraryTestDirectory { directory in
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                XCTAssertThrowsError(try LibraryPersistence.decode(bytes, now: LibrarySyncTestData.now))
                let library = LibraryStore(directory: directory, now: { LibrarySyncTestData.now })
                XCTAssertTrue(library.requiresReload)
                XCTAssertFalse(library.hasLoadedDocument)
                var callbacks = 0
                library.onSyncChange = { callbacks += 1 }
                library.onCloudSyncApplied = { _, _ in callbacks += 1 }
                library.preferences.shuffleStyle = .random
                library.preferences.discoveryFamiliarity = .newMusic
                XCTAssertThrowsError(try library.cloudReplica(replicaID: LibrarySyncTestData.a))
                XCTAssertThrowsError(try library.mergeCloudState(LibrarySyncState()))
                XCTAssertEqual(library.preferences.shuffleStyle, .fewerRepeats)
                XCTAssertEqual(library.preferences.discoveryFamiliarity, .balanced)
                XCTAssertEqual(callbacks, 0)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    private func withoutNewPreferences(_ document: LibraryDocument) throws -> Data {
        let data = try (document.version < 4 ? LibrarySyncTestData.legacyDocumentBytes(document) : LibraryPersistence.encode(document))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
        preferences.removeValue(forKey: "shuffleStyle")
        preferences.removeValue(forKey: "discoveryFamiliarity")
        preferences.removeValue(forKey: "shuffleDefaultMigrated")
        object["preferences"] = preferences
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }
}
