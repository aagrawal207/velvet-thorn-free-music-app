import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibrarySyncPlaybackDiscoveryPreferencesTests: XCTestCase {
    private let shuffleKey = LibrarySyncKey(.preference, "shuffleStyle")
    private let familiarityKey = LibrarySyncKey(.preference, "discoveryFamiliarity")

    func testCloudShuffleOnlyChangeDoesNotHideContentOrPrivacyChanges() async throws {
        for additionalChange in ["none", "favorite", "history", "familiarity"] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            let song = libraryTestTrack("retained-listen")
            XCTAssertTrue(a.library.recordListening(track: song, sessionID: UUID(),
                                                    startedAt: LibrarySyncTestData.now, seconds: 60))
            try b.library.mergeCloudState(a.state())
            b.library.preferences.shuffleStyle = .fewerRepeats
            switch additionalChange {
            case "favorite": b.library.toggleFavorite(libraryTestTrack("new-favorite"))
            case "history": b.library.clearHistory()
            case "familiarity": b.library.preferences.discoveryFamiliarity = .newMusic
            default: break
            }
            let preparation = try await a.library.prepareCloudMerge(b.state())
            XCTAssertEqual(preparation.recommendationsChanged, additionalChange != "none", additionalChange)
            var notifications: [Bool] = []
            a.library.onCloudSyncApplied = { [weak a] previous, changed in
                XCTAssertEqual(previous.shuffleStyle, .random)
                XCTAssertEqual(try? a?.saved().preferences.shuffleStyle, .fewerRepeats)
                notifications.append(changed)
            }
            XCTAssertTrue(try a.library.applyCloudMerge(preparation))
            XCTAssertEqual(notifications, [additionalChange != "none"])
        }
    }

    func testV1AndV2SparseReplicasDefaultMissingChoicesWithoutRestampingRevisionsOrBoundaries() throws {
        for version in [1, 2] {
            var state = LibrarySyncState()
            state.historyReset = LibrarySyncTestData.revision(1)
            state.historyRetirement = LibrarySyncTestData.revision(2)
            state.searchReset = LibrarySyncTestData.revision(3)
            state.searchFloor = LibrarySyncSearchBoundary(revision: LibrarySyncTestData.revision(4), key: "expired query")
            state.clock = LibrarySyncTestData.revision(8)
            state.put(LibrarySyncKey(.preference, "autoplay"), value: Data("false".utf8), revision: LibrarySyncTestData.revision(5))
            state.put(LibrarySyncKey(.search, "kept query"), value: try LibrarySyncCodec.encode("Kept query"), revision: LibrarySyncTestData.revision(6))
            if version == 2 {
                let selection = SearchSelection.track(libraryTestTrack("Kept"))
                state.searchSelectionFloor = LibrarySyncSearchBoundary(revision: LibrarySyncTestData.revision(5), key: "track:Expired")
                state.put(LibrarySyncKey(.searchSelection, selection.id), value: try LibrarySyncCodec.encode(selection), revision: LibrarySyncTestData.revision(7))
            }
            state.put(LibrarySyncKey(.reaction, "removed"), value: nil, revision: LibrarySyncTestData.revision(8))
            state.version = version
            let replica = LibrarySyncReplica(version: version, replicaID: LibrarySyncTestData.a, state: state)
            let bytes = try LibrarySyncCodec.encodeReplica(replica)
            let decoded = try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: replica.replicaID, now: LibrarySyncTestData.now)
            var expected = state
            expected.version = LibrarySyncState.currentVersion
            XCTAssertEqual(decoded.version, LibrarySyncReplica.currentVersion)
            XCTAssertEqual(decoded.state, expected)
            XCTAssertNil(decoded.state.registers[shuffleKey])
            XCTAssertNil(decoded.state.registers[familiarityKey])
            let rendered = try LibrarySyncTestData.rendered(decoded.state)
            XCTAssertEqual(rendered.preferences.shuffleStyle, .random)
            XCTAssertEqual(rendered.preferences.discoveryFamiliarity, .balanced)
            XCTAssertFalse(rendered.preferences.autoplay)
            XCTAssertEqual(rendered.recentSearches, ["Kept query"])
            XCTAssertEqual(rendered.recentSearchSelections.map(\.id), version == 2 ? ["track:Kept"] : [])
            if version == LibrarySyncReplica.currentVersion {
                XCTAssertEqual(try LibrarySyncCodec.encodeReplica(decoded), bytes)
            }
        }
    }

    func testConcurrentOfflineChoicesMergeIndependentlyWithoutChangingOtherRegistersOrSyncOptOut() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.sync.setEnabled(false)
        b.sync.setEnabled(false)
        var preferences = a.library.preferences
        preferences.saveListeningHistory = false
        preferences.autoplay = false
        preferences.newReleaseAlerts = false
        preferences.appIconID = "Sonnet"
        preferences.languageNudges[.hindi] = .less
        preferences.homeLayout.setVisible(false, for: .charts)
        a.library.preferences = preferences
        let song = libraryTestTrack("saved")
        a.library.toggleFavorite(song)
        a.library.createPlaylist(name: "Saved playlist", tracks: [song])
        a.library.recordSearch("Kept query")
        XCTAssertTrue(a.library.recordSearchSelection(.track(song)))
        let baseline = try a.state()
        try b.library.mergeCloudState(baseline)
        a.library.updatePlayback(PlaybackSnapshot(queue: [song, song], currentIndex: 1, position: 19, repeatMode: .one))
        b.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("b-queue")], position: 31))
        let aPlayback = try LibrarySyncCodec.encode(a.library.playback)
        let bPlayback = try LibrarySyncCodec.encode(b.library.playback)
        a.library.preferences.shuffleStyle = .fewerRepeats
        b.library.preferences.discoveryFamiliarity = .newMusic
        let left = try a.state()
        let right = try b.state()
        XCTAssertEqual(left.registers.filter { $0.key != shuffleKey }, baseline.registers)
        XCTAssertEqual(right.registers.filter { $0.key != familiarityKey }, baseline.registers)
        XCTAssertNil(left.registers[familiarityKey])
        XCTAssertNil(right.registers[shuffleKey])
        try a.library.mergeCloudState(right)
        try b.library.mergeCloudState(left)
        preferences.shuffleStyle = .fewerRepeats
        preferences.discoveryFamiliarity = .newMusic
        for device in [a, b] {
            XCTAssertEqual(device.library.preferences, preferences)
            XCTAssertEqual(try device.saved().preferences, preferences)
            XCTAssertEqual(device.library.recentSearches, ["Kept query"])
            XCTAssertEqual(device.library.recentSearchSelections, [.track(song)])
            XCTAssertFalse(device.sync.isEnabled)
            XCTAssertFalse(device.configuration.value.enabled)
            XCTAssertEqual(device.transport.publicationAttempts, 0)
        }
        let merged = try a.state()
        XCTAssertEqual(merged, try b.state())
        XCTAssertEqual(merged.registers.filter { $0.key != shuffleKey && $0.key != familiarityKey }, baseline.registers)
        XCTAssertEqual(merged.registers[shuffleKey], left.registers[shuffleKey])
        XCTAssertEqual(merged.registers[familiarityKey], right.registers[familiarityKey])
        XCTAssertNil(merged.registers[shuffleKey]?.generation)
        XCTAssertNil(merged.registers[familiarityKey]?.generation)
        XCTAssertEqual(try LibrarySyncCodec.encode(a.library.playback), aPlayback)
        XCTAssertEqual(try LibrarySyncCodec.encode(b.library.playback), bPlayback)
        let saved = try Data(contentsOf: a.fileURL)
        XCTAssertFalse(try a.library.mergeCloudState(baseline))
        XCTAssertFalse(try a.library.mergeCloudState(LibrarySyncState()))
        XCTAssertEqual(a.library.preferences, preferences)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), saved)
    }

    func testIndependentExplicitDefaultResetsSurviveClockRollbackRestartAndStaleReplicas() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.preferences.shuffleStyle = .fewerRepeats
        a.library.preferences.discoveryFamiliarity = .familiar
        let stale = try a.state()
        try b.library.mergeCloudState(stale)
        harness.clock.advance(by: -3600)
        a.library.preferences.shuffleStyle = .random
        b.library.preferences.discoveryFamiliarity = .balanced
        let left = try a.state()
        let right = try b.state()
        try a.library.mergeCloudState(right)
        try b.library.mergeCloudState(left)
        for device in [a, b] {
            XCTAssertFalse(try device.library.mergeCloudState(stale))
            let reopened = LibraryStore(directory: device.directory, now: { LibrarySyncTestData.now })
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.preferences.shuffleStyle, .random)
            XCTAssertEqual(reopened.preferences.discoveryFamiliarity, .balanced)
            let state = try device.state()
            XCTAssertEqual(state.registers[shuffleKey]?.value, Data("\"random\"".utf8))
            XCTAssertEqual(state.registers[familiarityKey]?.value, Data("\"balanced\"".utf8))
            XCTAssertGreaterThan(try XCTUnwrap(state.registers[shuffleKey]?.revision), try XCTUnwrap(stale.registers[shuffleKey]?.revision))
            XCTAssertGreaterThan(try XCTUnwrap(state.registers[familiarityKey]?.revision), try XCTUnwrap(stale.registers[familiarityKey]?.revision))
        }
        XCTAssertEqual(try a.state(), try b.state())
    }

    func testPreferenceTombstonesRestoreDefaultsAndRemainDurableWithoutSyntheticEdits() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.preferences.shuffleStyle = .fewerRepeats
        a.library.preferences.discoveryFamiliarity = .newMusic
        let stale = try a.state()
        var reset = stale
        let revision = try reset.nextRevision(now: LibrarySyncTestData.now, writer: LibrarySyncTestData.b)
        for key in [shuffleKey, familiarityKey] { reset.put(key, value: nil, revision: revision) }
        XCTAssertTrue(try a.library.mergeCloudState(reset))
        XCTAssertEqual(a.library.preferences.shuffleStyle, .random)
        XCTAssertEqual(a.library.preferences.discoveryFamiliarity, .balanced)
        XCTAssertEqual(try a.state(), reset)
        XCTAssertEqual(try a.saved().syncState, reset)
        XCTAssertFalse(try a.library.mergeCloudState(stale))
        XCTAssertEqual(try a.state(), reset)
    }

    func testEachNewPreferenceEditRejectsAPreparedMergeAndRetryKeepsTheLocalChoice() async throws {
        for field in ["shuffleStyle", "discoveryFamiliarity"] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            a.library.toggleFavorite(libraryTestTrack("local"))
            b.library.preferences.appearance = .light
            let incoming = try b.state()
            let prepared = try await a.library.prepareCloudMerge(incoming)
            var localChanges = 0
            var applied: [UserPreferences] = []
            a.library.onSyncChange = { localChanges += 1 }
            a.library.onCloudSyncApplied = { previous, _ in applied.append(previous) }
            if field == "shuffleStyle" { a.library.preferences.shuffleStyle = .fewerRepeats }
            else { a.library.preferences.discoveryFamiliarity = .newMusic }
            var expected = a.library.preferences
            let saved = try Data(contentsOf: a.fileURL)
            let state = try a.state()
            XCTAssertThrowsError(try a.library.applyCloudMerge(prepared)) {
                XCTAssertEqual($0 as? LibrarySyncError, .localChangedDuringSync)
            }
            XCTAssertEqual(a.library.preferences, expected)
            XCTAssertEqual(try Data(contentsOf: a.fileURL), saved)
            XCTAssertEqual(try a.state(), state)
            XCTAssertTrue(applied.isEmpty)
            XCTAssertEqual(localChanges, 1)
            let retry = try await a.library.prepareCloudMerge(incoming)
            XCTAssertTrue(try a.library.applyCloudMerge(retry))
            XCTAssertEqual(applied, [expected])
            expected.appearance = .light
            XCTAssertEqual(a.library.preferences, expected)
            XCTAssertEqual(try a.saved().preferences, expected)
            XCTAssertEqual(localChanges, 1)
        }
    }

    func testFailedRemoteWritePublishesNothingAndRetryCallsBackOnlyAfterDurabilityWithoutEcho() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("local"))
        a.library.preferences.shuffleStyle = .fewerRepeats
        a.library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack("playing")], position: 52, repeatMode: .one))
        b.library.preferences.discoveryFamiliarity = .newMusic
        let incoming = try b.state()
        let before = a.library.preferences
        let state = try a.state()
        let playback = try LibrarySyncCodec.encode(a.library.playback)
        let ownBytes = try LibrarySyncCodec.encodeReplica(a.library.cloudReplica(replicaID: a.id))
        let remoteBytes = try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))
        let cloud = [a.id: ownBytes, b.id: remoteBytes]
        harness.cloud.accounts["account-a"] = cloud
        let prepared = try await a.library.prepareCloudMerge(incoming)
        let saved = try Data(contentsOf: a.fileURL)
        let backup = a.directory.appendingPathComponent("saved.json")
        var localChanges = 0
        var applied: [UserPreferences] = []
        a.library.onSyncChange = { localChanges += 1 }
        a.library.onHistoryCleared = { XCTFail("Preference-only sync cannot clear listening history") }
        a.library.onCloudSyncApplied = { [weak a] previous, _ in
            applied.append(previous)
            XCTAssertEqual(try? a?.saved().preferences.shuffleStyle, .fewerRepeats)
            XCTAssertEqual(try? a?.saved().preferences.discoveryFamiliarity, .newMusic)
        }
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try a.library.applyCloudMerge(prepared))
        await a.sync.syncNow()
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertTrue(a.transport.writes.isEmpty)
        XCTAssertEqual(harness.cloud.accounts["account-a"], cloud)
        XCTAssertEqual(a.library.preferences, before)
        XCTAssertEqual(try LibrarySyncCodec.encode(a.library.playback), playback)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(localChanges, 0)
        XCTAssertEqual(try Data(contentsOf: backup), saved)
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.moveItem(at: backup, to: a.fileURL)
        XCTAssertEqual(try a.state(), state)
        XCTAssertTrue(try a.library.applyCloudMerge(prepared))
        XCTAssertEqual(applied, [before])
        XCTAssertEqual(localChanges, 0)
        XCTAssertEqual(try LibrarySyncCodec.encode(a.library.playback), playback)
        let merged = try a.state()
        XCTAssertEqual(merged.registers[shuffleKey], state.registers[shuffleKey])
        XCTAssertEqual(merged.registers[familiarityKey], incoming.registers[familiarityKey])
        let durable = try Data(contentsOf: a.fileURL)
        XCTAssertFalse(try a.library.mergeCloudState(incoming))
        XCTAssertEqual(try Data(contentsOf: a.fileURL), durable)
        XCTAssertEqual(applied.count, 1)
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertNotNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.transport.publicationAttempts, 1)
        XCTAssertEqual(a.transport.writes.count, 1)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(localChanges, 0)
        XCTAssertEqual(harness.cloud.accounts["account-a"]?[b.id], remoteBytes)
        let published = try XCTUnwrap(harness.cloud.accounts["account-a"]?[a.id])
        XCTAssertEqual(try LibrarySyncCodec.decodeReplica(published, expectedReplicaID: a.id, now: LibrarySyncTestData.now).state, merged)
    }

    func testUninterpretableOrInconsistentLocalPreferenceRegistersPreserveTheWholeFile() throws {
        let invalids: [(String, Data?)] = [
            ("shuffleStyle", Data("\"future-shuffle\"".utf8)),
            ("discoveryFamiliarity", Data("\"future-familiarity\"".utf8)),
            ("shuffleStyle", Data("null".utf8)),
            ("discoveryFamiliarity", Data("null".utf8)),
            ("futurePreference", Data("true".utf8)),
            ("futurePreference", nil),
            ("shuffleStyle", Data("\"fewerRepeats\"".utf8)),
            ("discoveryFamiliarity", Data("\"newMusic\"".utf8))
        ]
        for (field, value) in invalids {
            try withLibraryTestDirectory { directory in
                let now = LibrarySyncTestData.now
                var document = LibraryDocument()
                document.favorites = [libraryTestTrack("kept")]
                var state = try LibrarySyncJournal.seed(document, now: now, writer: LibrarySyncTestData.a)
                let revision = try state.nextRevision(now: now, writer: LibrarySyncTestData.b)
                state.put(LibrarySyncKey(.preference, field), value: value, revision: revision)
                document.syncState = state
                let bytes = try LibraryPersistence.encode(document)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(bytes, to: url, replacing: nil)
                XCTAssertThrowsError(try LibraryPersistence.decode(bytes, now: now))
                let library = LibraryStore(directory: directory, now: { now })
                XCTAssertTrue(library.requiresReload)
                XCTAssertFalse(library.hasLoadedDocument)
                library.preferences.shuffleStyle = .fewerRepeats
                library.preferences.discoveryFamiliarity = .newMusic
                XCTAssertThrowsError(try library.mergeCloudState(LibrarySyncState()))
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
    }

    func testUnknownFutureEnumsRegistersAndCorruptCloudFilesBlockTheWholeBatchBeforePublication() async throws {
        let revision = LibrarySyncTestData.revision(0, writer: LibrarySyncTestData.b)
        let invalidRegisters: [(String, Data?)] = [
            ("shuffleStyle", Data("\"future-shuffle\"".utf8)),
            ("discoveryFamiliarity", Data("\"future-familiarity\"".utf8)),
            ("shuffleStyle", Data("null".utf8)),
            ("discoveryFamiliarity", Data("null".utf8)),
            ("futurePreference", Data("true".utf8)),
            ("futurePreference", nil)
        ]
        var invalids = [Data("{broken".utf8)]
        for (field, value) in invalidRegisters {
            var state = LibrarySyncState()
            state.clock = revision
            state.put(LibrarySyncKey(.preference, field), value: value, revision: revision)
            invalids.append(try LibrarySyncCodec.encodeReplica(LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: state)))
        }
        let valid = try LibrarySyncTestData.single(.preference, "shuffleStyle", value: "fewerRepeats", revision: revision)
        var future = LibrarySyncReplica(replicaID: LibrarySyncTestData.b, state: valid)
        future.version += 1
        invalids.append(try LibrarySyncCodec.encodeReplica(future))
        future.version = LibrarySyncReplica.currentVersion
        future.state.version += 1
        invalids.append(try LibrarySyncCodec.encodeReplica(future))
        for bytes in invalids {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let c = harness.device(LibrarySyncTestData.c)
            a.library.preferences.shuffleStyle = .fewerRepeats
            a.library.preferences.discoveryFamiliarity = .newMusic
            a.library.toggleFavorite(libraryTestTrack("local"))
            c.library.preferences.appearance = .light
            let before = a.library.preferences
            let state = try a.state()
            let saved = try Data(contentsOf: a.fileURL)
            let cloud = [a.id: try LibrarySyncCodec.encodeReplica(a.library.cloudReplica(replicaID: a.id)),
                         LibrarySyncTestData.b: bytes,
                         c.id: try LibrarySyncCodec.encodeReplica(c.library.cloudReplica(replicaID: c.id))]
            harness.cloud.accounts["account-a"] = cloud
            var callbacks = 0
            a.library.onCloudSyncApplied = { _, _ in callbacks += 1 }
            a.library.onSyncChange = { callbacks += 1 }
            XCTAssertThrowsError(try LibrarySyncCodec.decodeReplica(bytes, expectedReplicaID: LibrarySyncTestData.b, now: LibrarySyncTestData.now))
            await a.sync.syncNow()
            XCTAssertNotNil(a.sync.errorMessage)
            XCTAssertNil(a.sync.lastSyncDate)
            XCTAssertEqual(a.transport.publicationAttempts, 0)
            XCTAssertTrue(a.transport.writes.isEmpty)
            XCTAssertEqual(harness.cloud.accounts["account-a"], cloud)
            XCTAssertEqual(a.library.preferences, before)
            XCTAssertEqual(try a.state(), state)
            XCTAssertEqual(try Data(contentsOf: a.fileURL), saved)
            XCTAssertEqual(callbacks, 0)
        }
    }
}
