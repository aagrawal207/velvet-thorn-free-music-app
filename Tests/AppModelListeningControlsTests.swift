import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelListeningControlsTests: XCTestCase {
    func testLoadedListeningPreferencesPreservePausedRestoredQueue() async throws {
        let harness = LibrarySyncTestHarness()
        addTeardownBlock { @MainActor in harness.remove() }
        let device = harness.device()
        var preferences = device.library.preferences
        preferences.useEncryptedDNS = false
        preferences.chooseShuffleStyle(.random)
        preferences.discoveryFamiliarity = .newMusic
        device.library.preferences = preferences
        let song = AppModelFixtures.track("restored-song")
        let other = AppModelFixtures.track("restored-other")
        let saved = PlaybackSnapshot(queue: [other, song, song], currentIndex: 2, position: 47.375,
                                     shuffleEnabled: true, repeatMode: .one, originalQueue: [song, other, song])
        device.library.updatePlayback(saved)
        XCTAssertNil(device.library.errorMessage)

        let library = LibraryStore(directory: device.directory)
        let (model, streams) = makeModel(library: library)
        XCTAssertEqual(model.player.shuffleStyle, .random)
        XCTAssertEqual(library.preferences.discoveryFamiliarity, .newMusic)
        model.player.handleLifecycleCheckpoint()
        model.updatePreferences {
            $0.shuffleStyle = .fewerRepeats
            $0.discoveryFamiliarity = .familiar
        }
        XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
        XCTAssertEqual(model.player.queue, saved.queue)
        XCTAssertEqual(model.player.currentIndex, saved.currentIndex)
        XCTAssertEqual(model.player.currentTrack, song)
        XCTAssertEqual(model.player.position, saved.position)
        XCTAssertEqual(model.player.repeatMode, saved.repeatMode)
        XCTAssertTrue(model.player.shuffleEnabled)
        XCTAssertFalse(model.player.isPlaying)
        XCTAssertFalse(model.player.isLoading)
        XCTAssertNil(model.player.currentStreamURL)
        let restored = LibraryStore(directory: device.directory)
        XCTAssertEqual(restored.playback.queue, saved.queue)
        XCTAssertEqual(restored.playback.originalQueue, saved.originalQueue)
        XCTAssertEqual(restored.playback.currentIndex, saved.currentIndex)
        XCTAssertEqual(restored.playback.position, saved.position)
        XCTAssertEqual(restored.preferences, library.preferences)
        let requests = await streams.streams.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: Shuffle preference preservation

    func testFreshInstallDefaultsToFewerRepeatsWithoutAMigrationWrite() throws {
        try withLibraryTestDirectory { directory in
            let file = directory.appendingPathComponent(LibraryPersistence.fileName)
            let library = LibraryStore(directory: directory)
            let existedBefore = FileManager.default.fileExists(atPath: file.path)
            let before = existedBefore ? try Data(contentsOf: file) : nil
            let (model, _) = makeModel(library: library)
            XCTAssertEqual(library.preferences.shuffleStyle, .fewerRepeats)
            XCTAssertFalse(library.preferences.shuffleDefaultMigrated, "A default does not establish prior user intent")
            XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), existedBefore)
            if let before { XCTAssertEqual(try Data(contentsOf: file), before, "A fresh install writes nothing at launch") }
        }
    }

    func testMissingShuffleStyleDefaultsToFewerRepeatsWithoutLaunchOrReloadWrites() throws {
        for version in [1, 2, 3] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.version = version
                // Reload flushes playback; keep its empty original queue checkpoint-stable before removing preference fields.
                document.playback = PlaybackSnapshot(originalQueue: [])
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: LibrarySyncTestData.legacyDocumentBytes(document)) as? [String: Any])
                var preferences = try XCTUnwrap(object["preferences"] as? [String: Any])
                preferences.removeValue(forKey: "shuffleStyle")
                preferences.removeValue(forKey: "shuffleDefaultMigrated")
                object["preferences"] = preferences
                let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                let file = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: file, replacing: nil)

                let (model, _) = makeModel(library: LibraryStore(directory: directory))
                XCTAssertNil(model.library.errorMessage)
                XCTAssertEqual(model.library.preferences.shuffleStyle, .fewerRepeats)
                XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
                XCTAssertFalse(model.library.preferences.shuffleDefaultMigrated)
                XCTAssertEqual(try Data(contentsOf: file), bytes)
                XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
                XCTAssertEqual(model.library.preferences.shuffleStyle, .fewerRepeats)
                XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
                XCTAssertFalse(model.library.preferences.shuffleDefaultMigrated)
                XCTAssertEqual(try Data(contentsOf: file), bytes, "Missing fields do not require a durable migration")
                XCTAssertNil(try LibraryPersistence.decode(Data(contentsOf: file), now: Date()).syncState)
            }
        }
    }

    func testSavedRandomPreservesBytesAndRevisionsOnLaunchAndReloadRegardlessOfMarker() throws {
        for marker in [nil, false, true] as [Bool?] {
            let harness = LibrarySyncTestHarness()
            addTeardownBlock { @MainActor in harness.remove() }
            let device = harness.device()
            // An absent original queue becomes [] on a playback checkpoint, independently of shuffle preferences.
            device.library.updatePlayback(PlaybackSnapshot(originalQueue: []))
            var preferences = device.library.preferences
            preferences.shuffleStyle = .random
            preferences.shuffleDefaultMigrated = marker ?? false
            device.library.preferences = preferences
            XCTAssertNil(device.library.errorMessage)
            var bytes = try Data(contentsOf: device.fileURL)
            if marker == nil {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                var savedPreferences = try XCTUnwrap(object["preferences"] as? [String: Any])
                savedPreferences.removeValue(forKey: "shuffleDefaultMigrated")
                object["preferences"] = savedPreferences
                let withoutMarker = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
                try LibraryPersistence.write(withoutMarker, to: device.fileURL, replacing: bytes)
                bytes = withoutMarker
            }
            let before = try XCTUnwrap(device.saved().syncState)

            let (model, _) = makeModel(library: LibraryStore(directory: device.directory, writerID: device.id))
            XCTAssertEqual(model.library.preferences, preferences)
            XCTAssertEqual(model.player.shuffleStyle, .random)
            XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes, "A stored Random cannot be inferred to be an old default")
            XCTAssertEqual(try device.saved().syncState, before)

            XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
            XCTAssertEqual(model.library.preferences, preferences)
            XCTAssertEqual(model.player.shuffleStyle, .random)
            XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes)
            XCTAssertEqual(try device.saved().syncState, before, "Reload must not stamp style or compatibility-marker revisions")

            let (again, _) = makeModel(library: LibraryStore(directory: device.directory, writerID: device.id))
            XCTAssertEqual(again.library.preferences, preferences)
            XCTAssertEqual(again.player.shuffleStyle, .random)
            XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes)
            XCTAssertEqual(try device.saved().syncState, before)
        }
    }

    func testRandomChosenOnFreshInstallStaysRandomWithoutRepeatedWrites() throws {
        let harness = LibrarySyncTestHarness()
        addTeardownBlock { @MainActor in harness.remove() }
        let device = harness.device()
        let (model, _) = makeModel(library: device.library)
        XCTAssertEqual(model.library.preferences.shuffleStyle, .fewerRepeats)
        XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
        // Establish the ordinary playback checkpoint before measuring writes caused by choosing or reloading preferences.
        model.player.handleLifecycleCheckpoint()
        XCTAssertEqual(device.library.playback.originalQueue, [])
        XCTAssertNil(device.library.playback.originalQueueIndices)
        model.updatePreferences { $0.chooseShuffleStyle(.random) }
        XCTAssertNil(model.library.errorMessage)
        XCTAssertEqual(model.library.preferences.shuffleStyle, .random)
        XCTAssertEqual(model.player.shuffleStyle, .random)
        let bytes = try Data(contentsOf: device.fileURL)
        let before = try XCTUnwrap(device.saved().syncState)
        model.updatePreferences { $0.chooseShuffleStyle(.random) }
        XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes, "Selecting the saved choice again is a no-op")
        XCTAssertEqual(try device.saved().syncState, before)

        let (reopened, _) = makeModel(library: LibraryStore(directory: device.directory, writerID: device.id))
        XCTAssertEqual(reopened.library.preferences.shuffleStyle, .random)
        XCTAssertEqual(reopened.player.shuffleStyle, .random)
        XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes)
        XCTAssertEqual(reopened.reloadSavedLibrary(), .reloaded)
        XCTAssertEqual(reopened.library.preferences.shuffleStyle, .random)
        XCTAssertEqual(reopened.player.shuffleStyle, .random)
        XCTAssertEqual(try Data(contentsOf: device.fileURL), bytes)
        XCTAssertEqual(try device.saved().syncState, before)
    }

    func testCompatibilityMarkerDecodesAndSyncsWithoutInferringShuffleIntent() async throws {
        for (json, expected) in [(#"{}"#, false), (#"{"shuffleDefaultMigrated":true}"#, true),
                                 (#"{"shuffleDefaultMigrated":false}"#, false), (#"{"shuffleDefaultMigrated":null}"#, false),
                                 (#"{"shuffleDefaultMigrated":"yes"}"#, false), (#"{"shuffleDefaultMigrated":1}"#, false)] {
            var preferences = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.shuffleDefaultMigrated, expected, json)
            XCTAssertEqual(preferences.shuffleStyle, .fewerRepeats, json)
            preferences.shuffleStyle = .random
            let before = preferences
            XCTAssertFalse(preferences.migrateShuffleDefault(), json)
            XCTAssertFalse(preferences.migrateShuffleDefault(), "Repeated compatibility calls are also no-ops")
            XCTAssertEqual(preferences, before, "The compatibility marker cannot establish prior intent")
            let fields = try LibrarySyncPreferences.fields(preferences)
            XCTAssertEqual(fields["shuffleDefaultMigrated"], Data((expected ? "true" : "false").utf8))
            XCTAssertEqual(fields["shuffleStyle"], Data("\"random\"".utf8))
            XCTAssertEqual(try LibrarySyncPreferences.applying(fields, to: UserPreferences()), before)
        }

        let harness = LibrarySyncTestHarness()
        addTeardownBlock { @MainActor in harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        // Playback is device-local; a remote preference merge must not have to normalize the next local checkpoint.
        b.library.updatePlayback(PlaybackSnapshot(originalQueue: []))
        let (model, _) = makeModel(library: b.library)
        XCTAssertEqual(model.player.shuffleStyle, .fewerRepeats)
        a.library.preferences.shuffleStyle = .random
        let randomState = try a.state()
        let flagKey = LibrarySyncKey(.preference, "shuffleDefaultMigrated")
        for marker in [false, true] {
            if marker { a.library.preferences.shuffleDefaultMigrated = true }
            XCTAssertNil(a.library.errorMessage)
            let incoming = try a.state()
            XCTAssertEqual(incoming.registers.filter { $0.key != flagKey }, randomState.registers.filter { $0.key != flagKey },
                           "A compatibility-marker edit must not restamp the saved Random")
            if marker { XCTAssertEqual(incoming.registers[flagKey]?.value, Data("true".utf8)) }
            let preparation = try await b.library.prepareCloudMerge(incoming)
            XCTAssertFalse(preparation.recommendationsChanged, "Shuffle and marker-only merges leave Home alone")
            XCTAssertTrue(try b.library.applyCloudMerge(preparation))
            XCTAssertEqual(b.library.preferences.shuffleStyle, .random)
            XCTAssertEqual(b.library.preferences.shuffleDefaultMigrated, marker)
            XCTAssertEqual(model.player.shuffleStyle, .random)
            XCTAssertEqual(try b.saved().syncState, incoming, "Remote revisions are adopted without local preference edits")

            let bytes = try Data(contentsOf: b.fileURL)
            let repeated = try await b.library.prepareCloudMerge(incoming)
            XCTAssertNil(repeated.encoded, "An identical remote state requires no write")
            XCTAssertFalse(try b.library.applyCloudMerge(repeated))
            XCTAssertEqual(try Data(contentsOf: b.fileURL), bytes)
            XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
            XCTAssertEqual(b.library.preferences.shuffleStyle, .random)
            XCTAssertEqual(b.library.preferences.shuffleDefaultMigrated, marker)
            XCTAssertEqual(model.player.shuffleStyle, .random)
            XCTAssertEqual(try Data(contentsOf: b.fileURL), bytes)

            let (other, _) = makeModel(library: LibraryStore(directory: b.directory, writerID: b.id))
            XCTAssertEqual(other.library.preferences.shuffleStyle, .random)
            XCTAssertEqual(other.library.preferences.shuffleDefaultMigrated, marker)
            XCTAssertEqual(other.player.shuffleStyle, .random)
            XCTAssertEqual(try Data(contentsOf: b.fileURL), bytes, "Launching after sync must not infer a new shuffle choice")
            XCTAssertEqual(try b.saved().syncState, incoming)
        }
    }

    func testShuffleHistoryReadsCurrentDurableEventsAndHonorsPrivacyBoundaries() throws {
        let song = AppModelFixtures.track("history-song")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [song], position: 17))
        let history = try XCTUnwrap(context.player.shuffleHistoryProvider)
        let checkpoint = try XCTUnwrap(context.player.onListeningProgress)
        XCTAssertTrue(try XCTUnwrap(history()).isEmpty)
        let session = UUID()
        let started = Date().addingTimeInterval(-120)
        XCTAssertTrue(checkpoint(song, session, started, 30))
        XCTAssertEqual(history()?.map(\.id), [session])
        XCTAssertTrue(checkpoint(song, session, started, 10))
        XCTAssertEqual(history()?.first?.listenedSeconds, 40)
        let second = UUID()
        XCTAssertTrue(checkpoint(AppModelFixtures.track("later-history"), second, started.addingTimeInterval(30), 35))
        let ids = Set([session, second])
        XCTAssertEqual(Set(try XCTUnwrap(history()).map(\.id)), ids)
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: file)
        _ = history()
        _ = history()
        XCTAssertEqual(try Data(contentsOf: file), saved, "Reading shuffle evidence cannot record another listen")
        let durable = LibraryStore(directory: context.directory)
        XCTAssertEqual(Set(durable.events.map(\.id)), ids)
        XCTAssertEqual(durable.events.first { $0.id == session }?.listenedSeconds, 40)

        context.model.updatePreferences { $0.saveListeningHistory = false }
        XCTAssertNil(history())
        XCTAssertTrue(checkpoint(song, UUID(), started, 40))
        XCTAssertEqual(Set(context.library.events.map(\.id)), ids)
        context.model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertEqual(Set(try XCTUnwrap(history()).map(\.id)), ids)
        context.library.clearHistory()
        XCTAssertTrue(try XCTUnwrap(history()).isEmpty, "Enabled, cleared history differs from unavailable history")
        XCTAssertTrue(LibraryStore(directory: context.directory).events.isEmpty)
        XCTAssertEqual(context.player.queue, [song])
        XCTAssertEqual(context.player.position, 17)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertNil(context.library.errorMessage)
    }

    func testShuffleHistoryFailsClosedDuringStartupAndEstablishedLibraryRecovery() throws {
        let context = try makeContext()
        context.seedHistory(AppModelFixtures.track("before-recovery"))
        let history = try XCTUnwrap(context.player.shuffleHistoryProvider)
        XCTAssertEqual(try XCTUnwrap(history()).count, 1)
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: file)
        try Data("{broken library".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .failed)
        XCTAssertTrue(context.library.hasLoadedDocument)
        XCTAssertTrue(context.library.requiresReload)
        XCTAssertEqual(context.library.events.count, 1)
        XCTAssertNil(history(), "Retained in-memory events are not usable while disk recovery is required")

        let (startup, _) = makeModel(library: LibraryStore(directory: context.directory))
        let startupHistory = try XCTUnwrap(startup.player.shuffleHistoryProvider)
        XCTAssertFalse(startup.library.hasLoadedDocument)
        XCTAssertTrue(startup.library.requiresReload)
        XCTAssertNil(startupHistory())
        try saved.write(to: file, options: .atomic)
        let repair = LibraryStore(directory: context.directory)
        XCTAssertTrue(repair.recordListening(track: AppModelFixtures.track("repaired-history"), sessionID: UUID(),
                                             startedAt: Date().addingTimeInterval(-60), seconds: 40))
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertNotEqual(startup.reloadSavedLibrary(), .failed)
        let expected = Set(["before-recovery", "repaired-history"])
        XCTAssertEqual(Set(try XCTUnwrap(history()).map(\.track.id)), expected)
        XCTAssertEqual(Set(try XCTUnwrap(startupHistory()).map(\.track.id)), expected)
        XCTAssertFalse(context.library.requiresReload)
        XCTAssertTrue(startup.library.hasLoadedDocument)
        XCTAssertFalse(startup.library.requiresReload)
    }

    func testFailedListeningPreferenceSaveKeepsPlayerAndPendingMixGenerationEffective() async throws {
        let snapshot = PlaybackSnapshot(queue: [AppModelFixtures.track("paused")], position: 23, shuffleEnabled: true)
        let context = try makeContext(snapshot: snapshot, generatesMixes: true)
        _ = context.seedListener(primary: AppModelFixtures.track("seed"))
        let preferences = context.library.preferences
        let task = try XCTUnwrap(context.model.refreshMixes())
        defer { task.cancel() }
        let weekly = try await pendingMix(in: context, at: 0)
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: file)
        try context.withBlockedLibraryFile {
            context.model.updatePreferences {
                $0.shuffleStyle = .random
                $0.discoveryFamiliarity = .newMusic
            }
            XCTAssertNotNil(context.library.errorMessage)
            XCTAssertEqual(context.library.preferences, preferences)
            XCTAssertEqual(context.player.shuffleStyle, preferences.shuffleStyle)
            XCTAssertTrue(context.model.isGeneratingMixes)
            XCTAssertFalse(task.isCancelled)
            XCTAssertEqual(context.player.queue, snapshot.queue)
            XCTAssertEqual(context.player.position, snapshot.position)
            XCTAssertTrue(context.player.shuffleEnabled)
            XCTAssertFalse(context.player.isPlaying)
        }
        XCTAssertEqual(try Data(contentsOf: file), saved)
        let fresh = candidates("accepted")
        try await completeMix(weekly, with: fresh, in: context)
        let daily = try await pendingMix(in: context, at: 1)
        try await completeMix(daily, with: fresh, in: context)
        await task.value
        XCTAssertEqual(Set(context.model.discoverWeekly?.tracks.map(\.id) ?? []), Set(fresh.map(\.id)))
        XCTAssertNotNil(context.model.dailyMix)
        XCTAssertFalse(context.model.isGeneratingMixes)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences, preferences)
        XCTAssertNil(context.library.errorMessage)
    }

    func testOrdinaryAndShuffledListSelectionNeverPublishARearrangedOldQueue() async throws {
        let a = AppModelFixtures.track("old-a")
        let b = AppModelFixtures.track("old-b")
        let first = AppModelFixtures.track("new-first")
        let source = [first, AppModelFixtures.track("new-second"), first]
        for shuffle in [false, true] {
            let original = [a, b, a]
            let old = shuffle ? original : [b, a, a]
            let snapshot = PlaybackSnapshot(queue: old, currentIndex: 2, position: 25,
                                            shuffleEnabled: !shuffle, originalQueue: original)
            let context = try makeContext(snapshot: snapshot)
            context.seedHistory(first)
            context.model.updatePreferences { $0.shuffleStyle = .fewerRepeats }
            let player = context.player
            let history = try XCTUnwrap(player.shuffleHistoryProvider)
            var reads = 0
            player.shuffleHistoryProvider = { [weak player] in
                reads += 1
                XCTAssertEqual(player?.queue, old)
                return history()
            }
            let persist = try XCTUnwrap(player.onSnapshotChanged)
            var publications: [PlaybackSnapshot] = []
            player.onSnapshotChanged = { publications.append($0); persist($0) }

            context.model.play(source, shuffle: shuffle)
            let selected = try XCTUnwrap(player.currentTrack)
            XCTAssertEqual(reads, shuffle ? 1 : 0)
            XCTAssertEqual(player.shuffleEnabled, shuffle)
            XCTAssertEqual(player.currentIndex, 0)
            XCTAssertEqual(player.position, 0)
            XCTAssertEqual(player.queue.map(\.id).sorted(), source.map(\.id).sorted())
            if !shuffle { XCTAssertEqual(player.queue, source) }
            let checkpoints = publications.filter { $0.queue == old }
            XCTAssertFalse(checkpoints.isEmpty, "Retiring playback still publishes its normal checkpoint")
            for checkpoint in checkpoints {
                XCTAssertEqual(checkpoint.shuffleEnabled, snapshot.shuffleEnabled)
                XCTAssertEqual(checkpoint.currentIndex, snapshot.currentIndex)
                XCTAssertEqual(checkpoint.position, snapshot.position)
                XCTAssertEqual(checkpoint.originalQueue, original)
            }
            XCTAssertTrue(publications.allSatisfy { $0.queue == old || $0.queue == player.queue })
            XCTAssertEqual(publications.last?.originalQueue, source)
            XCTAssertEqual(context.library.playback.queue, player.queue)
            XCTAssertEqual(context.library.events.count, 1)
            let request = try await context.streams.streams.request(at: 0)
            XCTAssertEqual(request.input.track, selected)
            let durable = LibraryStore(directory: context.directory)
            XCTAssertEqual(durable.playback.queue, player.queue)
            XCTAssertEqual(durable.playback.originalQueue, source)
        }
    }

    func testHomePassesFamiliarityToBothShelvesAndRefreshesTheCachedSelection() async throws {
        let context = try makeContext()
        let seed = context.seedListener(primary: AppModelFixtures.track("home-seed"))
        let known = RecommendationFixtures.track("saved-home-song", artist: "Saved artist", language: .english)
        let fresh = RecommendationFixtures.track("new-home-song", artist: "New artist", language: .english)
        context.library.recordRecent(track: known, position: 5)
        for (index, mode) in [DiscoveryFamiliarity.familiar, .newMusic].enumerated() {
            if index == 0 { context.model.updatePreferences { $0.discoveryFamiliarity = mode } }
            // A direct durable edit keeps the warm cache, so its key must include familiarity.
            else { context.library.preferences.discoveryFamiliarity = mode }
            let task = context.start { await $0.loadHome() }
            let radio = try await context.catalog.autoplayRadios.request(at: index)
            let artist = try await context.catalog.artists.request(at: index)
            let chart = try await context.charts.charts.request(at: index)
            XCTAssertEqual(radio.input.id, seed.id)
            XCTAssertEqual(artist.input, seed.artistID)
            try await context.catalog.autoplayRadios.complete(radio, with: .success([fresh, known]))
            try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: [fresh, known])))
            try await context.charts.charts.complete(chart, with: .success(AppModelFixtures.chart("home-chart")))
            await task.value
            XCTAssertEqual(Set(context.model.homeSections.map(\.id)), ["personal.UChome-seed", "discovery.language.en"])
            for section in context.model.homeSections {
                XCTAssertEqual(section.tracks, mode == .familiar ? [known, fresh] : [fresh, known], section.id)
            }
            XCTAssertFalse(context.model.isLoadingHome)
            XCTAssertNil(context.model.homeError)
        }
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.discoveryFamiliarity, .newMusic)
        let radios = await context.catalog.autoplayRadios.requests
        let artists = await context.catalog.artists.requests
        XCTAssertEqual(radios.count, 2)
        XCTAssertEqual(artists.count, 2)
    }

    func testNewMixesUseFamiliarityWhileCurrentPeriodSavedMixesStayStable() async throws {
        var dailyFamiliarCounts: [Int] = []
        for mode in [DiscoveryFamiliarity.familiar, .newMusic] {
            let context = try makeContext(generatesMixes: true)
            let seed = context.seedListener(primary: AppModelFixtures.track("mix-seed"))
            let known = candidates("saved", count: 24)
            for track in known { context.library.recordRecent(track: track, position: 5) }
            let heardIDs = Set(known.map(\.id) + context.library.events.map(\.track.id))
            let neighbor = RecommendationFixtures.track("unheard-known-artist", artist: seed.artistName,
                                                        artistID: seed.artistID, language: .english)
            let fresh = candidates("unheard", count: 29)
            // A known artist's first five top songs are likely known and leave the Weekly; the neighbor sits just past them.
            let hits = (0..<5).map { RecommendationFixtures.track("known-artist-hit-\($0)", artist: seed.artistName,
                                                                  artistID: seed.artistID, language: .english) }
            context.model.updatePreferences { $0.discoveryFamiliarity = mode }
            let task = try XCTUnwrap(context.model.refreshMixes())
            defer { task.cancel() }
            for index in 0..<2 {
                let harvest = try await pendingMix(in: context, at: index)
                try await completeMix(harvest, with: [neighbor] + fresh, artistTracks: hits + [neighbor], in: context)
            }
            await task.value
            let weekly = try XCTUnwrap(context.model.discoverWeekly)
            let daily = try XCTUnwrap(context.model.dailyMix)
            XCTAssertEqual(weekly.tracks.count, 30)
            XCTAssertTrue(Set(weekly.tracks.map(\.id)).isDisjoint(with: heardIDs))
            XCTAssertTrue(Set(weekly.tracks.map(\.id)).isDisjoint(with: hits.map(\.id)))
            XCTAssertEqual(mode == .familiar ? weekly.tracks.first?.id : weekly.tracks.last?.id, neighbor.id)
            XCTAssertEqual(daily.tracks.count, 25)
            dailyFamiliarCounts.append(daily.tracks.filter { heardIDs.contains($0.id) }.count)
            let saved = context.library.mixes
            context.model.updatePreferences { $0.discoveryFamiliarity = mode == .familiar ? .newMusic : .familiar }
            XCTAssertNil(context.model.refreshMixes())
            XCTAssertEqual(context.library.mixes, saved)
            let durable = LibraryStore(directory: context.directory)
            XCTAssertEqual(durable.mixes.map(\.tracks), saved.map(\.tracks))
            XCTAssertEqual(durable.mixes.map(\.periodKey), saved.map(\.periodKey))
            XCTAssertNil(durable.errorMessage)
            let radios = await context.catalog.autoplayRadios.requests
            let artists = await context.catalog.artists.requests
            XCTAssertEqual(radios.count, 4)
            XCTAssertEqual(artists.count, 2)
        }
        XCTAssertGreaterThan(dailyFamiliarCounts[0], dailyFamiliarCounts[1], "The model must forward the preference to Daily Mix too")
    }

    func testFamiliarityChangesRejectLateHomeIncludingAFlipBack() async throws {
        for flipBack in [false, true] {
            let context = try makeContext()
            let oldTask = context.start { await $0.loadHome() }
            let oldSearch = try await context.catalog.searches.request(at: 0)
            let oldChart = try await context.charts.charts.request(at: 0)
            let replacement: Task<Void, Never>?
            if flipBack {
                context.model.updatePreferences { $0.discoveryFamiliarity = .newMusic }
                context.model.updatePreferences { $0.discoveryFamiliarity = .balanced }
                XCTAssertFalse(context.model.isLoadingHome)
                replacement = context.start { await $0.loadHome() }
                _ = try await context.catalog.searches.request(at: 1)
                _ = try await context.charts.charts.request(at: 1)
            } else {
                // Keep the request generation alive to exercise the post-await preference check itself.
                context.library.preferences.discoveryFamiliarity = .newMusic
                XCTAssertFalse(oldTask.isCancelled)
                replacement = nil
            }
            try await context.catalog.searches.complete(oldSearch, with: .success(CatalogPage(tracks: [AppModelFixtures.track("obsolete")])))
            try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("obsolete-chart")))
            await oldTask.value
            XCTAssertEqual(context.model.isLoadingHome, flipBack, "Retired cleanup must not clear the replacement's loading state")
            XCTAssertTrue(context.model.homeSections.isEmpty)
            XCTAssertTrue(context.model.charts.isEmpty)
            let currentTask = replacement ?? context.start { await $0.loadHome() }
            let currentSearch = try await context.catalog.searches.request(at: 1)
            let currentChart = try await context.charts.charts.request(at: 1)
            let current = AppModelFixtures.track("current-home")
            try await context.catalog.searches.complete(currentSearch, with: .success(CatalogPage(tracks: [current])))
            try await context.charts.charts.complete(currentChart, with: .success(AppModelFixtures.chart("current-chart")))
            await currentTask.value
            XCTAssertEqual(context.model.homeSections.flatMap(\.tracks), [current])
            XCTAssertEqual(context.model.charts.map(\.id), ["current-chart"])
            XCTAssertFalse(context.model.isLoadingHome)
            XCTAssertNil(context.model.homeError)
        }
    }

    func testFamiliarityFlipBackRetiresLateWeeklyAndDailyMixesWithoutStoppingReplacement() async throws {
        for duringDaily in [false, true] {
            let context = try makeContext(generatesMixes: true)
            _ = context.seedListener(primary: AppModelFixtures.track("seed"))
            let oldTask = try XCTUnwrap(context.model.refreshMixes())
            defer { oldTask.cancel() }
            let weekly = try await pendingMix(in: context, at: 0)
            let pending: MixHarvest
            if duringDaily {
                try await completeMix(weekly, with: candidates("saved-weekly"), in: context)
                pending = try await pendingMix(in: context, at: 1)
            } else { pending = weekly }
            let savedWeekly = context.model.discoverWeekly
            let profileKey = context.model.listeningLanguageProfile.requestKey
            context.model.updatePreferences { $0.discoveryFamiliarity = .newMusic }
            context.model.updatePreferences { $0.discoveryFamiliarity = .balanced }
            XCTAssertEqual(context.model.listeningLanguageProfile.requestKey, profileKey)
            XCTAssertEqual(context.library.preferences.discoveryFamiliarity, .balanced)
            XCTAssertTrue(oldTask.isCancelled)
            XCTAssertFalse(context.model.isGeneratingMixes)
            let currentTask = try XCTUnwrap(context.model.refreshMixes())
            defer { currentTask.cancel() }
            let current = try await pendingMix(in: context, at: duringDaily ? 2 : 1)
            try await completeMix(pending, with: candidates("obsolete"), in: context)
            await oldTask.value
            XCTAssertTrue(context.model.isGeneratingMixes)
            XCTAssertEqual(context.model.discoverWeekly, savedWeekly)
            XCTAssertNil(context.model.dailyMix)
            let fresh = candidates("current")
            try await completeMix(current, with: fresh, in: context)
            if !duringDaily {
                let daily = try await pendingMix(in: context, at: 2)
                try await completeMix(daily, with: fresh, in: context)
            }
            await currentTask.value
            XCTAssertNotNil(context.model.dailyMix)
            XCTAssertEqual(context.library.mixes.count, 2)
            XCTAssertFalse(context.library.mixes.flatMap(\.tracks).contains { $0.id.hasPrefix("obsolete") })
            if duringDaily { XCTAssertEqual(context.model.discoverWeekly, savedWeekly) }
            XCTAssertFalse(context.model.isGeneratingMixes)
            let durable = LibraryStore(directory: context.directory)
            XCTAssertEqual(durable.mixes.map(\.tracks), context.library.mixes.map(\.tracks))
            XCTAssertNil(durable.errorMessage)
        }
    }

    func testMixWorkRechecksFamiliarityBeforeStartingAndAfterProviderAwait() async throws {
        for started in [false, true] {
            let context = try makeContext(generatesMixes: true)
            _ = context.seedListener(primary: AppModelFixtures.track("seed"))
            let task = try XCTUnwrap(context.model.refreshMixes())
            defer { task.cancel() }
            let harvest: MixHarvest?
            if started { harvest = try await pendingMix(in: context, at: 0) }
            else { harvest = nil }
            // Direct durable edits leave the task uncancelled so its own preference fences are exercised.
            context.library.preferences.discoveryFamiliarity = .newMusic
            XCTAssertFalse(task.isCancelled)
            if let harvest { try await completeMix(harvest, with: candidates("stale"), in: context) }
            await task.value
            XCTAssertTrue(context.library.mixes.isEmpty)
            XCTAssertFalse(context.model.isGeneratingMixes)
            let radios = await context.catalog.autoplayRadios.requests
            let artists = await context.catalog.artists.requests
            XCTAssertEqual(radios.count, started ? 2 : 0)
            XCTAssertEqual(artists.count, started ? 1 : 0, "Obsolete weekly work cannot start the daily phase")
        }
    }

    func testCloudAndReloadApplyListeningPreferencesWithoutReplacingNativeAudio() async throws {
        for reload in [false, true] {
            let tracks = [AppModelFixtures.track("native-current"), AppModelFixtures.track("native-next")]
            let (context, resolver) = try makeAudioContext(tracks: tracks)
            let onStarted = try XCTUnwrap(context.player.onTrackStarted)
            var starts = 0
            context.player.onTrackStarted = { starts += 1; onStarted($0) }
            context.model.play(tracks)
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > 0.7 }
            context.player.toggleShuffle()
            context.player.cycleRepeatMode()
            if reload { context.player.pause() }
            let order = context.player.queue
            let index = context.player.currentIndex
            let position = context.player.position
            let stream = try XCTUnwrap(context.player.currentStreamURL)
            let requests = await resolver.requests
            let change: (inout UserPreferences) -> Void = {
                $0.chooseShuffleStyle(.random)
                $0.discoveryFamiliarity = .newMusic
            }
            if reload {
                let external = LibraryStore(directory: context.directory)
                var preferences = external.preferences
                change(&preferences)
                external.preferences = preferences
                external.updatePlayback(PlaybackSnapshot(queue: [AppModelFixtures.track("disk-only")], position: 90))
                XCTAssertNil(external.errorMessage)
                XCTAssertEqual(context.model.reloadSavedLibrary(), .historyBoundary,
                               "History-off recovery retires pending listening while preserving live audio")
            } else {
                let incoming = try cloudPreferences(from: context.library, change: change)
                XCTAssertTrue(try context.library.mergeCloudState(incoming))
            }
            XCTAssertEqual(context.player.shuffleStyle, .random)
            XCTAssertEqual(context.library.preferences.discoveryFamiliarity, .newMusic)
            XCTAssertEqual(context.player.queue, order)
            XCTAssertEqual(context.player.currentIndex, index)
            XCTAssertEqual(context.player.currentTrack, tracks[0])
            XCTAssertEqual(context.player.currentStreamURL, stream)
            XCTAssertTrue(context.player.shuffleEnabled)
            XCTAssertEqual(context.player.repeatMode, .all)
            XCTAssertEqual(context.player.isPlaying, !reload)
            XCTAssertFalse(context.player.isLoading)
            if reload {
                XCTAssertEqual(context.player.position, position, accuracy: 0.05)
                context.player.resumePlayback()
            }
            try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.3 }
            context.player.pause()
            let after = await resolver.requests
            XCTAssertEqual(after, requests)
            XCTAssertEqual(starts, 1)
            XCTAssertEqual(context.player.currentStreamURL, stream)
            let durable = LibraryStore(directory: context.directory)
            XCTAssertEqual(durable.preferences.shuffleStyle, .random)
            XCTAssertEqual(durable.preferences.discoveryFamiliarity, .newMusic)
            XCTAssertEqual(durable.playback.queue, order)
            XCTAssertEqual(durable.playback.originalQueue, tracks)
            XCTAssertNil(context.player.errorMessage)
        }
    }

    func testShuffleStyleOnlyEditsPreserveHomeRequestsCacheAndRadio() async throws {
        let old = AppModelFixtures.track("old-selection")
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [old], position: 17))
        let home = context.start { await $0.loadHome() }
        let search = try await context.catalog.searches.request(at: 0)
        let chart = try await context.charts.charts.request(at: 0)
        let anchor = RecommendationFixtures.track("radio-anchor", artist: "Anchor artist", language: .english)
        let station = RadioExperience(id: "listening-controls-radio", title: "Controls radio", description: "Fixture", symbol: "radio",
                                      discoveryLanguages: [.english], contentLabel: "English",
                                      seeds: [.init(recording: anchor, artist: anchor.credits[0])])
        let radio = context.model.startRadio(station)
        defer { radio.cancel() }
        let request = try await context.catalog.autoplayRadios.request(at: 0)
        XCTAssertEqual(request.input.id, anchor.id)
        context.model.updatePreferences { $0.shuffleStyle = .random }
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertTrue(context.model.isLoadingRadio)
        XCTAssertEqual(context.model.selectedRadioExperience, station)
        XCTAssertEqual(context.player.queue, [old])
        XCTAssertEqual(context.player.position, 17)
        let homeSong = AppModelFixtures.track("cached-home")
        let homeChart = AppModelFixtures.chart("cached-chart")
        try await context.catalog.searches.complete(search, with: .success(CatalogPage(tracks: [homeSong])))
        try await context.charts.charts.complete(chart, with: .success(homeChart))
        await home.value
        try await context.catalog.autoplayRadios.complete(request, with: .success(candidates("station", count: 3)))
        await radio.value
        XCTAssertEqual(context.model.activeRadioExperience, station)
        XCTAssertNil(context.model.radioError)
        let order = context.player.queue
        XCTAssertEqual(order.count, 4)

        for cloud in [false, true] {
            if cloud {
                let incoming = try cloudPreferences(from: context.library) { $0.shuffleStyle = .random }
                XCTAssertTrue(try context.library.mergeCloudState(incoming))
            } else { context.model.updatePreferences { $0.shuffleStyle = .fewerRepeats } }
            XCTAssertEqual(context.model.homeSections.flatMap(\.tracks), [homeSong], "A shuffle-only edit cannot retire Home")
            XCTAssertEqual(context.model.charts.map(\.id), [homeChart.id])
            XCTAssertEqual(context.model.activeRadioExperience, station)
            XCTAssertEqual(context.model.selectedRadioExperience, station)
            XCTAssertEqual(context.player.queue, order)
            XCTAssertTrue(context.player.isRadioSession)
            // Unexpected refetches complete immediately so the cache assertion fails without stranding a request.
            await context.catalog.searches.enqueue(.success(CatalogPage(tracks: [homeSong])))
            await context.charts.charts.enqueue(.success(homeChart))
            await context.model.loadHome()
            let searches = await context.catalog.searches.requests
            let charts = await context.charts.charts.requests
            let radios = await context.catalog.autoplayRadios.requests
            XCTAssertEqual(searches.count, 1)
            XCTAssertEqual(charts.count, 1)
            XCTAssertEqual(radios.count, 1)
        }
    }

    private typealias MixHarvest = (radios: [AppModelRequestGate<Track, [Track]>.Request],
                                   artist: AppModelRequestGate<String, ArtistPage>.Request)

    private func pendingMix(in context: AppModelTestContext, at index: Int) async throws -> MixHarvest {
        // seedListener has two affinity recordings and one linked artist; recents add no provider seeds.
        let radios = [try await context.catalog.autoplayRadios.request(at: index * 2),
                      try await context.catalog.autoplayRadios.request(at: index * 2 + 1)]
        let artist = try await context.catalog.artists.request(at: index)
        return (radios, artist)
    }

    private func completeMix(_ harvest: MixHarvest, with tracks: [Track], artistTracks: [Track]? = nil,
                             in context: AppModelTestContext) async throws {
        for request in harvest.radios { try await context.catalog.autoplayRadios.complete(request, with: .success(tracks)) }
        let page = context.artistPage(harvest.artist.input, songs: artistTracks ?? tracks)
        try await context.catalog.artists.complete(harvest.artist, with: .success(page))
    }

    private func candidates(_ prefix: String, count: Int = 12) -> [Track] {
        (0..<count).map { RecommendationFixtures.track("\(prefix)-\($0)", artist: "\(prefix) artist \($0)", language: .english) }
    }

    private func cloudPreferences(from library: LibraryStore, change: (inout UserPreferences) -> Void) throws -> LibrarySyncState {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        harness.clock.advance(by: Date().timeIntervalSince(harness.clock.now))
        let remote = harness.device(LibrarySyncTestData.b)
        try remote.library.mergeCloudState(library.cloudReplica(replicaID: LibrarySyncTestData.a).state)
        var preferences = remote.library.preferences
        change(&preferences)
        remote.library.preferences = preferences
        remote.library.updatePlayback(PlaybackSnapshot(queue: [AppModelFixtures.track("remote-only")], position: 90))
        if let error = remote.library.errorMessage { throw AppModelTestFailure.storage(error) }
        return try remote.state()
    }

    private func makeAudioContext(tracks: [Track]) throws -> (AppModelTestContext, PlaybackFixtureResolver) {
        let url = try PlaybackTestSupport.audioFile(seconds: 20)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let resolver = PlaybackFixtureResolver(Dictionary(uniqueKeysWithValues: tracks.map {
            ($0.id, PlaybackFixtureResolver.Entry(url: url, duration: 20))
        }))
        let context = try makeContext(resolver: resolver)
        context.model.updatePreferences {
            $0.autoplay = false
            $0.gaplessPlayback = false
            $0.automix = false
            $0.saveListeningHistory = false
            $0.newReleaseAlerts = false
        }
        return (context, resolver)
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot(), resolver: (any StreamResolving)? = nil,
                             generatesMixes: Bool = false) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot, resolver: resolver, generatesMixes: generatesMixes)
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }

    private func makeModel(library: LibraryStore) -> (MusicAppModel, AppModelStreamResolver) {
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        let streams = AppModelStreamResolver()
        let lyrics = AppModelLyricsProvider()
        let service = ArtistSpotlightLanguageService(provider: lyrics)
        let model = MusicAppModel(library: library, player: PlayerController(resolver: streams), catalog: catalog,
                                  charts: charts, lyrics: lyrics, releaseNotifier: ReleaseNotifierMock(),
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  recordingLanguageService: service, generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.cancelPendingRadio()
            model.deactivateDeviceServices()
            model.player.pause()
            await catalog.close()
            await charts.charts.close()
            await streams.streams.close()
            await model.languageDiscovery.waitForChecks()
            LyricsDNSConfiguration.configure(enabled: false)
        }
        return (model, streams)
    }
}
