import XCTest
@testable import GanaBajana

@MainActor
final class ICloudLibrarySyncTests: XCTestCase {
    func testFreshConfigurationIsEnabledAndStartsSyncWithoutAnOptInToggle() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .seconds(1000))
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertFalse(a.transport.observing)
        XCTAssertEqual(a.sync.statusText, "Waiting to sync with iCloud")
        a.library.toggleFavorite(libraryTestTrack())
        XCTAssertNotNil(try a.saved().syncState)
        a.sync.refresh()
        XCTAssertEqual(a.transport.reads, 0)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.configuration.saveCount, 0)

        a.sync.start()
        await a.sync.syncNow()
        XCTAssertTrue(a.transport.observing)
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertEqual(a.transport.publicationAttempts, 1)
        XCTAssertNotNil(harness.cloud.accounts["account-a"]?[a.id])
        XCTAssertEqual(a.sync.lastSyncDate, harness.clock.now)
        XCTAssertNil(a.sync.errorMessage)
    }

    func testUnitHostCannotStartDefaultEnabledNativeSyncEvenWithManualRetry() async throws {
        _ = try XCTUnwrap(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        library.toggleFavorite(libraryTestTrack("local"))
        let fileURL = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        let original = try Data(contentsOf: fileURL)
        let configurationURL = try XCTUnwrap(library.syncDeviceConfigurationURL)
        let transports: [(any LibrarySyncTransport)?] = [nil, ICloudDriveLibraryTransport()]
        for transport in transports {
            let sync = ICloudLibrarySync(library: library, transport: transport, debounce: .zero)
            XCTAssertTrue(sync.isEnabled)

            sync.refresh()
            await sync.syncNow()
            sync.start()
            sync.refresh()
            await sync.syncNow()

            XCTAssertEqual(sync.statusText, "Waiting to sync with iCloud")
            XCTAssertFalse(sync.isSyncing)
            XCTAssertNil(sync.lastSyncDate)
            XCTAssertNil(sync.errorMessage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: configurationURL.path))
            XCTAssertEqual(try Data(contentsOf: fileURL), original)
        }
    }

    func testPersistedOffSurvivesRestartAndKeepsLocalEditsWithoutTransportWork() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let transport = LibrarySyncTestTransport(cloud: harness.cloud)
        let sync = ICloudLibrarySync(library: library, transport: transport)
        XCTAssertTrue(sync.isEnabled)
        sync.setEnabled(false)
        library.toggleFavorite(libraryTestTrack("kept-local"))
        let configurationURL = try XCTUnwrap(library.syncDeviceConfigurationURL)
        let savedConfiguration = try Data(contentsOf: configurationURL)
        let fileURL = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        let savedLibrary = try Data(contentsOf: fileURL)

        let restoredLibrary = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let restoredTransport = LibrarySyncTestTransport(cloud: harness.cloud)
        let restored = ICloudLibrarySync(library: restoredLibrary, transport: restoredTransport)
        XCTAssertFalse(restored.isEnabled)
        restored.start()
        restored.refresh()
        await restored.syncNow()

        XCTAssertEqual(restoredTransport.reads, 0)
        XCTAssertEqual(restoredTransport.publicationAttempts, 0)
        XCTAssertTrue(harness.cloud.accounts.isEmpty)
        XCTAssertNil(restored.lastSyncDate)
        XCTAssertTrue(restored.statusText.contains("off"))
        XCTAssertEqual(restoredLibrary.favorites.map(\.id), ["kept-local"])
        XCTAssertEqual(try Data(contentsOf: fileURL), savedLibrary)
        XCTAssertEqual(try Data(contentsOf: configurationURL), savedConfiguration)
        XCTAssertNotNil(try LibraryPersistence.decode(savedLibrary, now: LibrarySyncTestData.now).syncState)
    }

    func testTwoOfflineDevicesMergeBeforePublishingAndConvergeWithoutEchoWrites() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("a"))
        a.library.preferences.appearance = .light
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        b.library.toggleFavorite(libraryTestTrack("b"))
        b.library.preferences.useEncryptedDNS = false
        b.transport.beforeReadReturns = {
            XCTAssertEqual(b.library.favorites.map(\.id), ["b"])
            XCTAssertNil(harness.cloud.accounts["account-a"]?[b.id], "Offline edits cannot be uploaded before reading other replicas")
        }
        b.sync.setEnabled(true)
        await b.sync.syncNow()
        b.transport.beforeReadReturns = nil
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertNil(b.sync.errorMessage)
        XCTAssertEqual(Set(a.library.favorites.map(\.id)), ["a", "b"])
        XCTAssertEqual(a.library.preferences, b.library.preferences)
        XCTAssertEqual(try a.state(), try b.state())
        XCTAssertEqual(Set(harness.cloud.accounts["account-a"]?.keys.map { $0 } ?? []), [a.id, b.id])
        let writes = a.transport.writes.count
        let bytes = try Data(contentsOf: a.fileURL)
        await a.sync.syncNow()
        XCTAssertEqual(a.transport.writes.count, writes)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), bytes)
        XCTAssertEqual(a.sync.lastSyncDate, harness.clock.now)
        XCTAssertTrue(a.sync.statusText.contains("Handed to iCloud"))
    }

    func testOfflineEditsAfterDisableRemainJournalledAndReenableMergesThem() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("old"))
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        b.sync.setEnabled(true)
        await b.sync.syncNow()
        a.sync.setEnabled(false)
        let cloudBefore = harness.cloud.accounts["account-a"]?[a.id]
        a.library.toggleFavorite(libraryTestTrack("old"))
        a.library.toggleFavorite(libraryTestTrack("offline"))
        b.library.preferences.appearance = .light
        await b.sync.syncNow()
        XCTAssertEqual(harness.cloud.accounts["account-a"]?[a.id], cloudBefore)
        XCTAssertNotNil(try a.saved().syncState?.registers[LibrarySyncKey(.reaction, "old")])
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        await b.sync.syncNow()
        XCTAssertEqual(a.library.favorites.map(\.id), ["offline"])
        XCTAssertEqual(b.library.favorites.map(\.id), ["offline"])
        XCTAssertEqual(a.library.preferences.appearance, .light)
    }

    func testMissingAccountIsAvailabilityAndSameAccountReconnectKeepsTheReplicaIdentity() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack())
        let original = try Data(contentsOf: a.fileURL)
        a.transport.account = nil
        await a.sync.syncNow()
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertEqual(a.transport.reads, 0)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertTrue(a.sync.statusText.contains("Sign in"))
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), original)
        XCTAssertNil(a.configuration.value.boundAccount)
        a.transport.account = "account-a"
        await a.sync.syncNow()
        let replica = a.configuration.value.replicaID
        XCTAssertEqual(a.configuration.value.boundAccount, "account-a")
        let cloud = harness.cloud.accounts
        a.transport.account = nil
        await a.sync.syncNow()
        XCTAssertEqual(harness.cloud.accounts, cloud)
        XCTAssertEqual(a.library.favorites.count, 1)
        a.transport.account = "account-a"
        await a.sync.syncNow()
        XCTAssertEqual(a.configuration.value.replicaID, replica)
        XCTAssertNil(a.sync.errorMessage)
    }

    func testUnavailableICloudKeepsDefaultEnabledAndLocalDataUntilRetry() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("kept-local"))
        a.library.preferences.appearance = .light
        let original = try Data(contentsOf: a.fileURL)
        a.transport.readError = LibrarySyncError.unavailable
        await a.sync.syncNow()

        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertTrue(a.configuration.value.enabled)
        XCTAssertFalse(a.sync.isSyncing)
        XCTAssertEqual(a.sync.statusText, "Waiting for iCloud Drive")
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertTrue(harness.cloud.accounts.isEmpty)
        XCTAssertEqual(a.library.favorites.map(\.id), ["kept-local"])
        XCTAssertEqual(a.library.preferences.appearance, .light)
        XCTAssertEqual(try Data(contentsOf: a.fileURL), original)

        a.transport.readError = nil
        await a.sync.syncNow()
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(a.sync.lastSyncDate, harness.clock.now)
        XCTAssertTrue(a.sync.statusText.contains("Other devices may update later"))
        XCTAssertEqual(a.library.favorites.map(\.id), ["kept-local"])
    }

    func testDifferentAccountDisablesUntilExplicitOptInAndNeverAutomaticallyUploadsOldAccountData() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("kept-local"))
        await a.sync.syncNow()
        let firstAccount = harness.cloud.accounts["account-a"]
        a.transport.account = "account-b"
        await a.sync.syncNow()
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertFalse(a.configuration.value.enabled)
        XCTAssertNil(harness.cloud.accounts["account-b"])
        XCTAssertEqual(a.library.favorites.map(\.id), ["kept-local"])
        XCTAssertTrue(a.sync.statusText.contains("Account changed"))
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertEqual(a.configuration.value.boundAccount, "account-b")
        XCTAssertNotEqual(a.configuration.value.replicaID, a.id)
        XCTAssertNotNil(harness.cloud.accounts["account-b"]?[a.configuration.value.replicaID])
        XCTAssertEqual(harness.cloud.accounts["account-a"], firstAccount)
    }

    func testSavedAccountBindingPausesOnRestartAndPauseSurvivesAnotherRestart() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        library.toggleFavorite(libraryTestTrack("kept-local"))
        let firstTransport = LibrarySyncTestTransport(cloud: harness.cloud)
        let first = ICloudLibrarySync(library: library, transport: firstTransport, now: { LibrarySyncTestData.now })
        await first.syncNow()
        XCTAssertNil(first.errorMessage)
        let configurationURL = try XCTUnwrap(library.syncDeviceConfigurationURL)
        let originalConfiguration = try LibrarySyncDeviceConfigurationStore(fileURL: configurationURL).load()
        XCTAssertEqual(originalConfiguration.boundAccount, "account-a")
        let firstAccount = try XCTUnwrap(harness.cloud.accounts["account-a"])
        let fileURL = harness.root.appendingPathComponent(LibraryPersistence.fileName)
        let savedLibrary = try Data(contentsOf: fileURL)

        let restoredLibrary = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let changedTransport = LibrarySyncTestTransport(cloud: harness.cloud)
        changedTransport.account = "account-b"
        let restored = ICloudLibrarySync(library: restoredLibrary, transport: changedTransport)
        XCTAssertTrue(restored.isEnabled)
        restored.start()
        await restored.syncNow()

        XCTAssertFalse(restored.isEnabled)
        XCTAssertTrue(restored.statusText.contains("Account changed"))
        XCTAssertNil(restored.lastSyncDate)
        XCTAssertEqual(changedTransport.reads, 0)
        XCTAssertEqual(changedTransport.publicationAttempts, 0)
        XCTAssertEqual(try Data(contentsOf: fileURL), savedLibrary)
        let pausedConfiguration = try LibrarySyncDeviceConfigurationStore(fileURL: configurationURL).load()
        XCTAssertFalse(pausedConfiguration.enabled)
        XCTAssertEqual(pausedConfiguration.boundAccount, "account-a")
        XCTAssertEqual(pausedConfiguration.replicaID, originalConfiguration.replicaID)
        XCTAssertNil(pausedConfiguration.lastSyncDate)

        let pausedLibrary = LibraryStore(directory: harness.root, now: { LibrarySyncTestData.now })
        let pausedTransport = LibrarySyncTestTransport(cloud: harness.cloud)
        pausedTransport.account = "account-b"
        let paused = ICloudLibrarySync(library: pausedLibrary, transport: pausedTransport, now: { LibrarySyncTestData.now })
        paused.start()
        paused.refresh()
        await paused.syncNow()
        XCTAssertFalse(paused.isEnabled)
        XCTAssertEqual(pausedTransport.reads, 0)
        XCTAssertEqual(pausedTransport.publicationAttempts, 0)
        XCTAssertNil(harness.cloud.accounts["account-b"])
        XCTAssertEqual(pausedLibrary.favorites.map(\.id), ["kept-local"])

        paused.setEnabled(true)
        await paused.syncNow()
        let rebound = try LibrarySyncDeviceConfigurationStore(fileURL: configurationURL).load()
        XCTAssertTrue(paused.isEnabled)
        XCTAssertNil(paused.errorMessage)
        XCTAssertEqual(rebound.boundAccount, "account-b")
        XCTAssertNotEqual(rebound.replicaID, originalConfiguration.replicaID)
        XCTAssertNotNil(harness.cloud.accounts["account-b"]?[rebound.replicaID])
        XCTAssertEqual(harness.cloud.accounts["account-a"], firstAccount)
    }

    func testDisableRejectsAStaleReadCompletionWithoutApplyingRemoteState() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("local"))
        b.library.preferences.appearance = .light
        harness.cloud.accounts["account-a"] = [b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))]
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        a.sync.setEnabled(true)
        let operation = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        a.sync.setEnabled(false)
        gate.open()
        await operation.value
        XCTAssertEqual(a.library.preferences.appearance, .dark)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertFalse(a.sync.isSyncing)
    }

    func testDisableInvalidatesAPublicationAlreadyWaitingAtTheTransportBoundary() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack())
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforePublication = { await gate.wait() }
        a.sync.setEnabled(true)
        let operation = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        a.sync.setEnabled(false)
        gate.open()
        await operation.value
        XCTAssertTrue(a.transport.writes.isEmpty)
        XCTAssertNil(harness.cloud.accounts["account-a"])
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertFalse(a.configuration.value.enabled)
    }

    func testNewGenerationCompletesBeforeAnOldReadAndTheOldReadCannotOverwriteIt() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        b.library.preferences.appearance = .light
        harness.cloud.accounts["account-a"] = [b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))]
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        a.sync.setEnabled(true)
        let old = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        a.sync.setEnabled(false)
        b.library.preferences.appearance = .dark
        b.library.toggleFavorite(libraryTestTrack("fresh"))
        harness.cloud.accounts["account-a"]?[b.id] = try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))
        a.transport.beforeReadReturns = nil
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        let latest = try Data(contentsOf: a.fileURL)
        gate.open()
        await old.value
        XCTAssertEqual(a.library.preferences.appearance, .dark)
        XCTAssertEqual(a.library.favorites.map(\.id), ["fresh"])
        XCTAssertEqual(try Data(contentsOf: a.fileURL), latest)
        XCTAssertEqual(a.transport.writes.count, 1)
    }

    func testIdentityNotificationInvalidatesAnOldAccountReadAndPausesTheNewAccount() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .seconds(1000))
        let b = harness.device(LibrarySyncTestData.b)
        a.library.toggleFavorite(libraryTestTrack("local"))
        b.library.toggleFavorite(libraryTestTrack("account-a-remote"))
        harness.cloud.accounts["account-a"] = [b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))]
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        a.sync.start()
        a.sync.setEnabled(true)
        let old = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        a.transport.account = "account-b"
        a.transport.emit(.identityChanged)
        await a.sync.syncNow()
        gate.open()
        await old.value
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertEqual(a.library.favorites.map(\.id), ["local"])
        XCTAssertTrue(a.transport.writes.isEmpty)
        XCTAssertNil(harness.cloud.accounts["account-b"])
    }

    func testCorruptOrNewerReplicaBlocksAllRemoteApplyAndPublication() async throws {
        for invalid in [Data("not JSON".utf8), Data("{\"version\":9999,\"future\":true}".utf8)] {
            let harness = LibrarySyncTestHarness()
            defer { harness.remove() }
            let a = harness.device()
            let b = harness.device(LibrarySyncTestData.b)
            a.library.toggleFavorite(libraryTestTrack("local"))
            b.library.preferences.appearance = .light
            let original = try Data(contentsOf: a.fileURL)
            harness.cloud.accounts["account-a"] = [
                a.id: invalid,
                b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))
            ]
            a.sync.setEnabled(true)
            await a.sync.syncNow()
            XCTAssertNotNil(a.sync.errorMessage)
            XCTAssertNil(a.sync.lastSyncDate)
            XCTAssertEqual(a.transport.publicationAttempts, 0)
            XCTAssertEqual(a.library.preferences.appearance, .dark)
            XCTAssertEqual(try Data(contentsOf: a.fileURL), original)
            XCTAssertEqual(harness.cloud.accounts["account-a"]?[a.id], invalid)
        }
    }

    func testDownloadsWaitForMetadataUpdatesAndConflictingVersionsParticipateInTheMerge() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .seconds(1000))
        let b = harness.device(LibrarySyncTestData.b)
        b.library.toggleFavorite(libraryTestTrack("base"))
        let firstVersion = try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))
        b.library.preferences.appearance = .light
        let conflict = try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))
        harness.cloud.accounts["account-a"] = [b.id: firstVersion]
        a.transport.additionalFiles = [LibrarySyncRemoteFile(replicaID: b.id, data: conflict)]
        a.transport.pendingDownloads = 1
        a.sync.start()
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertTrue(a.library.favorites.isEmpty)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertTrue(a.sync.statusText.contains("download"))
        a.transport.pendingDownloads = 0
        a.transport.emit(.filesChanged)
        await a.sync.syncNow()
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(a.library.favorites.map(\.id), ["base"])
        XCTAssertEqual(a.library.preferences.appearance, .light)
        XCTAssertEqual(a.transport.additionalFiles.count, 1, "Validated conflict input is not deleted as a side effect of publication")
    }

    func testPublicationFailureHasNoSuccessDateAndManualRetryDoesNotRestampRemoteChanges() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let b = harness.device(LibrarySyncTestData.b)
        b.library.preferences.appearance = .light
        harness.cloud.accounts["account-a"] = [b.id: try LibrarySyncCodec.encodeReplica(b.library.cloudReplica(replicaID: b.id))]
        a.transport.publishError = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue,
                                           userInfo: [NSLocalizedDescriptionKey: "iCloud storage is full."])
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.sync.statusText, "iCloud storage is full")
        XCTAssertEqual(try a.saved().preferences.appearance, .light, "Remote state is already durable locally even if upload fails")
        let merged = try a.state()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(a.transport.reads, 1)
        a.transport.publishError = nil
        await a.sync.syncNow()
        XCTAssertEqual(try a.state(), merged)
        XCTAssertNotNil(a.sync.lastSyncDate)
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(a.transport.writes.count, 1)
    }

    func testLocalStorageFailurePreventsRemoteAcknowledgementAndCloudPublication() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.library.toggleFavorite(libraryTestTrack("saved"))
        let original = try Data(contentsOf: a.fileURL)
        let backup = a.directory.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: a.fileURL, to: backup)
        try FileManager.default.createDirectory(at: a.fileURL, withIntermediateDirectories: false)
        a.library.toggleFavorite(libraryTestTrack("failed-edit"))
        XCTAssertNotNil(a.library.errorMessage)
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertNil(a.sync.lastSyncDate)
        XCTAssertEqual(a.library.favorites.map(\.id), ["saved"])
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testDebounceCoalescesChangesAndOwnMetadataUpdatesDoNotCreateEchoWrites() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .milliseconds(30))
        a.sync.start()
        a.sync.setEnabled(true)
        for index in 0..<8 { a.library.toggleFavorite(libraryTestTrack("\(index)")); a.sync.refresh() }
        try await PlaybackTestSupport.waitUntil { a.transport.writes.count == 1 && !a.sync.isSyncing }
        XCTAssertEqual(a.transport.reads, 1)
        let state = try a.state()
        for _ in 0..<10 { a.transport.emit(.filesChanged) }
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 2 && !a.sync.isSyncing }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(a.transport.reads, 2)
        XCTAssertEqual(a.transport.writes.count, 1)
        XCTAssertEqual(try a.state(), state)
        a.sync.setEnabled(false)
    }

    func testTimeoutIsVisibleBoundedAndCannotPublishAfterTheLateReadCompletes() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(timeout: .milliseconds(40))
        a.library.toggleFavorite(libraryTestTrack())
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        a.sync.setEnabled(true)
        let operation = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered && !a.sync.isSyncing && a.sync.errorMessage != nil }
        XCTAssertTrue(a.sync.statusText.contains("timed out"))
        gate.open()
        await operation.value
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        XCTAssertNil(a.sync.lastSyncDate)
    }

    func testObserverAndBackgroundTaskDoNotRetainTheController() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let library = LibraryStore(directory: harness.root.appendingPathComponent("deinit"))
        let transport = LibrarySyncTestTransport(cloud: harness.cloud)
        let configuration = LibrarySyncTestConfiguration(replicaID: LibrarySyncTestData.a)
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        transport.beforeReadReturns = { await gate.wait() }
        var sync: ICloudLibrarySync? = ICloudLibrarySync(library: library, transport: transport, configuration: configuration, debounce: .zero)
        weak var weakSync = sync
        sync?.start()
        sync?.setEnabled(true)
        try await PlaybackTestSupport.waitUntil { gate.entered }
        sync = nil
        XCTAssertNil(weakSync)
        XCTAssertFalse(transport.observing)
        XCTAssertFalse(try XCTUnwrap(transport.lastScope).lease.isValid)
        gate.open()
    }

    func testConfigurationFailuresKeepSyncOffAndCannotWriteCloudFiles() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        let savedConfiguration = a.configuration.value
        a.configuration.saveError = CocoaError(.fileWriteNoPermission)
        a.sync.setEnabled(false)
        a.sync.start()
        a.sync.refresh()
        await a.sync.syncNow()
        XCTAssertFalse(a.sync.isEnabled)
        XCTAssertEqual(a.configuration.value, savedConfiguration, "A failed disable must not pretend the opt-out was saved")
        XCTAssertNotNil(a.sync.errorMessage)
        XCTAssertEqual(a.transport.reads, 0)
        XCTAssertEqual(a.transport.publicationAttempts, 0)
        let corrupt = LibrarySyncTestConfiguration(replicaID: LibrarySyncTestData.c)
        corrupt.loadError = LibrarySyncError.newerVersion
        let controller = ICloudLibrarySync(library: a.library, transport: a.transport, configuration: corrupt)
        controller.setEnabled(true)
        await controller.syncNow()
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(corrupt.saveCount, 0)
        XCTAssertEqual(a.transport.reads, 0)
    }

    func testEquivalentAccountTokensDoNotTriggerARebindOrNewReplica() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device()
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        a.transport.accountAliases["account-a-new-encoding"] = "account-a"
        a.transport.account = "account-a-new-encoding"
        await a.sync.syncNow()
        XCTAssertTrue(a.sync.isEnabled)
        XCTAssertNil(a.sync.errorMessage)
        XCTAssertEqual(a.configuration.value.boundAccount, "account-a")
        XCTAssertEqual(a.configuration.value.replicaID, a.id)
    }

    func testConcurrentRequestsSerializeAndQueueOnlyOneFollowupForChangesDuringARead() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .milliseconds(20))
        let gate = LibrarySyncTestGate()
        defer { gate.open() }
        a.transport.beforeReadReturns = { await gate.wait() }
        a.sync.start()
        a.sync.setEnabled(true)
        let first = Task { await a.sync.syncNow() }
        try await PlaybackTestSupport.waitUntil { gate.entered }
        let second = Task { await a.sync.syncNow() }
        for index in 0..<5 {
            a.library.toggleFavorite(libraryTestTrack("during-read-\(index)"))
            a.sync.refresh()
        }
        XCTAssertEqual(a.transport.reads, 1)
        a.transport.beforeReadReturns = nil
        gate.open()
        await first.value
        await second.value
        try await PlaybackTestSupport.waitUntil { a.transport.reads == 2 && !a.sync.isSyncing }
        XCTAssertEqual(a.library.favorites.count, 5)
        XCTAssertEqual(a.transport.writes.count, 1)
        a.sync.setEnabled(false)
    }

    func testReadFailureDoesNotRetryAutomaticallyButForegroundRefreshCanRecover() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let a = harness.device(debounce: .milliseconds(10))
        a.transport.readError = URLError(.timedOut)
        a.sync.start()
        a.sync.setEnabled(true)
        await a.sync.syncNow()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(a.transport.reads, 1)
        XCTAssertNotNil(a.sync.errorMessage)
        a.transport.readError = nil
        a.sync.refresh()
        try await PlaybackTestSupport.waitUntil { a.sync.lastSyncDate != nil && !a.sync.isSyncing }
        XCTAssertEqual(a.transport.reads, 2)
        XCTAssertNil(a.sync.errorMessage)
        a.sync.setEnabled(false)
    }
}
