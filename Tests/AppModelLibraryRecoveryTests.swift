import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class AppModelLibraryRecoveryTests: XCTestCase {
    func testRecoveryReplaysFifteenSecondCallbackOnceOverTwentySavedSecondsAndKeepsLiveQueue() async throws {
        let context = try makeAudioContext()
        let song = AppModelFixtures.track("recovery-current")
        let other = AppModelFixtures.track("recovery-next")
        let favorite = AppModelFixtures.track("external-favorite")
        let diskSong = AppModelFixtures.track("external-queue")
        let library = context.library
        let directory = context.directory
        let installed = try XCTUnwrap(context.player.onListeningProgress)
        let saveSnapshot = try XCTUnwrap(context.player.onSnapshotChanged)
        var firstCheckpoint: ListeningEvent?
        var lastMeasuredSeconds: TimeInterval?
        var retainedSeconds: TimeInterval?
        var savedRetries = 0
        var liveSnapshot: PlaybackSnapshot?
        context.player.onSnapshotChanged = { snapshot in
            liveSnapshot = snapshot
            saveSnapshot(snapshot)
        }
        context.player.onListeningProgress = { track, session, started, measuredSeconds in
            if firstCheckpoint == nil {
                firstCheckpoint = ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: measuredSeconds)
                XCTAssertTrue(installed(track, session, started, 20))
                let external = LibraryStore(directory: directory)
                external.toggleFavorite(favorite)
                external.updatePlayback(PlaybackSnapshot(queue: [diskSong], position: 70))
                XCTAssertNil(external.errorMessage)
            }
            XCTAssertEqual(session, firstCheckpoint?.id)
            XCTAssertEqual(started, firstCheckpoint?.startedAt)
            lastMeasuredSeconds = measuredSeconds
            if let retainedSeconds { XCTAssertEqual(measuredSeconds, retainedSeconds, accuracy: 0.001) }
            // Fixed callback amounts isolate exact-once accounting; the real player owns the retained retry.
            let saved = installed(track, session, started, 15)
            if saved { savedRetries += 1 }
            return saved
        }

        context.model.play([song, other, song])
        try await pauseAfterAdvance(context)
        retainedSeconds = try XCTUnwrap(lastMeasuredSeconds)
        context.player.flushListeningProgress()
        XCTAssertTrue(library.requiresReload)
        XCTAssertEqual(library.events.first?.listenedSeconds, 20)
        XCTAssertEqual(savedRetries, 0)
        context.player.moveQueue(from: IndexSet(integer: 0), to: 3)
        context.player.cycleRepeatMode()
        let live = try XCTUnwrap(liveSnapshot)
        let selected = context.player.currentTrack
        let stream = context.player.currentStreamURL
        XCTAssertEqual(live.currentIndex, 2)

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertFalse(library.requiresReload)
        XCTAssertEqual(savedRetries, 1)
        XCTAssertEqual(context.player.queue, live.queue)
        XCTAssertEqual(context.player.currentIndex, live.currentIndex)
        XCTAssertEqual(context.player.currentTrack, selected)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertEqual(context.player.position, live.position)
        XCTAssertEqual(context.player.repeatMode, live.repeatMode)
        XCTAssertFalse(context.player.isPlaying)
        context.player.flushListeningProgress()
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        context.player.flushListeningProgress()
        XCTAssertEqual(savedRetries, 1)

        let restored = LibraryStore(directory: directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.favorites, [favorite])
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(restored.events.first?.id, firstCheckpoint?.id)
        XCTAssertEqual(restored.events.first?.listenedSeconds, 35)
        XCTAssertEqual(restored.playback.queue, live.queue)
        XCTAssertEqual(restored.playback.currentIndex, live.currentIndex)
        XCTAssertEqual(restored.playback.originalQueue, live.originalQueue)
        XCTAssertEqual(restored.playback.position, live.position, accuracy: 0.001)
        XCTAssertEqual(restored.recentlyPlayed.first?.track.id, song.id)
    }

    func testRecoveryWithRealListeningBacklogKeepsPlayingAndAppliesExternalTransitions() async throws {
        let context = try makeAudioContext()
        let song = AppModelFixtures.track("live-recovery")
        let next = AppModelFixtures.track("live-next")
        let installed = try XCTUnwrap(context.player.onListeningProgress)
        var accepted: [ListeningEvent] = []
        var rejected: [ListeningEvent] = []
        context.player.onListeningProgress = { track, session, started, seconds in
            let event = ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)
            let saved = installed(track, session, started, seconds)
            if saved { accepted.append(event) } else { rejected.append(event) }
            return saved
        }
        context.model.play([song, next])
        try await pauseAfterAdvance(context)
        let first = try XCTUnwrap(context.library.events.first)
        let external = LibraryStore(directory: context.directory)
        let favorite = AppModelFixtures.track("live-external-favorite")
        external.toggleFavorite(favorite)
        external.preferences.crossfadeSeconds = 2
        external.preferences.normalizeVolume = false
        external.updatePlayback(PlaybackSnapshot(queue: [AppModelFixtures.track("disk-only")], position: 90))
        XCTAssertNil(external.errorMessage)
        let boundary = context.player.position
        context.player.resumePlayback()
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > boundary + 0.7 }
        context.player.flushListeningProgress()
        XCTAssertTrue(context.library.requiresReload)
        let failed = try XCTUnwrap(rejected.last)
        XCTAssertEqual(failed.id, first.id)
        XCTAssertGreaterThan(failed.listenedSeconds, 0.5)
        let position = context.player.position
        let stream = context.player.currentStreamURL

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertTrue(context.player.isPlaying)
        XCTAssertEqual(context.player.currentTrack, song)
        XCTAssertEqual(context.player.queue, [song, next])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertGreaterThanOrEqual(context.player.position, position)
        XCTAssertEqual(context.player.settings.crossfadeSeconds, 2)
        XCTAssertFalse(context.player.settings.normalizeVolume)
        try await pauseAfterAdvance(context, from: position)
        context.player.flushListeningProgress()

        let restored = LibraryStore(directory: context.directory)
        XCTAssertEqual(restored.events.count, 1)
        XCTAssertEqual(restored.events.first?.id, first.id)
        XCTAssertEqual(try XCTUnwrap(restored.events.first?.listenedSeconds), accepted.reduce(0) { $0 + $1.listenedSeconds }, accuracy: 0.001)
        XCTAssertEqual(restored.favorites, [favorite])
        XCTAssertEqual(restored.playback.queue, [song, next])
        XCTAssertEqual(restored.playback.position, context.player.position, accuracy: 0.05)
        XCTAssertNil(context.library.errorMessage)
    }

    func testExternalClearOrHistoryToggleRetiresRealBacklogBeforeRecoveryWritesResume() async throws {
        for change in ["clear", "disable", "disable-and-enable"] {
            let context = try makeAudioContext()
            let song = AppModelFixtures.track("privacy-recovery")
            let installed = try XCTUnwrap(context.player.onListeningProgress)
            var rejected: [ListeningEvent] = []
            context.player.onListeningProgress = { track, session, started, seconds in
                let saved = installed(track, session, started, seconds)
                if !saved { rejected.append(ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)) }
                return saved
            }
            context.model.play(song)
            try await pauseAfterAdvance(context)
            let original = try XCTUnwrap(context.library.events.first)
            let external = LibraryStore(directory: context.directory)
            if change == "clear" { external.clearHistory() }
            else {
                external.preferences.saveListeningHistory = false
                if change == "disable-and-enable" { external.preferences.saveListeningHistory = true }
            }
            XCTAssertNil(external.errorMessage)
            let firstPosition = context.player.position
            context.player.resumePlayback()
            try await pauseAfterAdvance(context, from: firstPosition)
            XCTAssertTrue(context.library.requiresReload)
            XCTAssertEqual(rejected.last?.id, original.id)
            XCTAssertGreaterThan(rejected.last?.listenedSeconds ?? 0, 0.5)
            let recoveredAt = Date()

            XCTAssertEqual(context.model.reloadSavedLibrary(), .historyBoundary)
            context.player.flushListeningProgress()
            let position = context.player.position
            XCTAssertEqual(context.player.queue, [song])
            XCTAssertEqual(context.player.currentTrack, song)
            XCTAssertFalse(context.player.isPlaying)
            if change == "clear" {
                XCTAssertTrue(context.library.events.isEmpty)
                XCTAssertTrue(context.library.recentlyPlayed.isEmpty)
            } else {
                XCTAssertEqual(context.library.events.count, 1)
                XCTAssertEqual(context.library.events.first?.listenedSeconds, original.listenedSeconds)
            }
            context.model.updatePreferences { $0.saveListeningHistory = true }
            context.player.resumePlayback()
            try await pauseAfterAdvance(context, from: position)
            context.player.flushListeningProgress()
            let restored = LibraryStore(directory: context.directory)
            let fresh = try XCTUnwrap(restored.events.first { $0.id != original.id })
            XCTAssertGreaterThanOrEqual(fresh.startedAt, recoveredAt.addingTimeInterval(-0.05))
            XCTAssertGreaterThan(fresh.listenedSeconds, 0.5)
            XCTAssertLessThanOrEqual(fresh.listenedSeconds, context.player.position - position + 0.05)
            XCTAssertEqual(restored.events.count, change == "clear" ? 1 : 2)
            if change != "clear" {
                XCTAssertEqual(restored.events.first { $0.id == original.id }?.listenedSeconds, original.listenedSeconds)
            }
        }
    }

    func testRejectedCorruptOrFutureReloadLeavesRealBacklogRetryableAfterRepair() async throws {
        for invalid in [Data("{broken library".utf8), Data("{\"version\":9999,\"future\":\"keep\"}".utf8)] {
            let context = try makeAudioContext()
            let song = AppModelFixtures.track("failed-reload")
            let installed = try XCTUnwrap(context.player.onListeningProgress)
            var attempts = 0
            var accepted: [ListeningEvent] = []
            var rejected: [ListeningEvent] = []
            context.player.onListeningProgress = { track, session, started, seconds in
                attempts += 1
                let event = ListeningEvent(id: session, track: track, startedAt: started, listenedSeconds: seconds)
                let saved = installed(track, session, started, seconds)
                if saved { accepted.append(event) } else { rejected.append(event) }
                return saved
            }
            context.model.play(song)
            try await pauseAfterAdvance(context)
            let original = try XCTUnwrap(context.library.events.first)
            let external = LibraryStore(directory: context.directory)
            let favorite = AppModelFixtures.track("repaired-external-favorite")
            external.toggleFavorite(favorite)
            external.preferences.crossfadeSeconds = 4
            let url = context.directory.appendingPathComponent(LibraryPersistence.fileName)
            let repaired = try Data(contentsOf: url)
            try invalid.write(to: url, options: .atomic)
            let firstPosition = context.player.position
            context.player.resumePlayback()
            try await pauseAfterAdvance(context, from: firstPosition)
            let settings = context.player.settings
            let preferences = context.library.preferences
            let attemptsBeforeReload = attempts
            let failed = try XCTUnwrap(rejected.last)

            XCTAssertEqual(context.model.reloadSavedLibrary(), .failed)
            XCTAssertEqual(attempts, attemptsBeforeReload, "Rejected input must not trigger a listening replay")
            XCTAssertEqual(context.player.settings, settings)
            XCTAssertEqual(context.library.preferences, preferences)
            XCTAssertEqual(context.player.queue, [song])
            XCTAssertEqual(context.library.events.first?.listenedSeconds, original.listenedSeconds)
            XCTAssertTrue(context.library.requiresReload)
            XCTAssertEqual(context.model.toast, context.library.errorMessage)
            XCTAssertEqual(try Data(contentsOf: url), invalid)
            context.player.flushListeningProgress()
            XCTAssertGreaterThan(attempts, attemptsBeforeReload)
            XCTAssertEqual(rejected.last?.id, failed.id)

            try repaired.write(to: url, options: .atomic)
            let acceptedBeforeRecovery = accepted.count
            XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
            context.player.flushListeningProgress()
            XCTAssertEqual(accepted.count, acceptedBeforeRecovery + 1)
            XCTAssertEqual(context.player.settings.crossfadeSeconds, 4)
            let restored = LibraryStore(directory: context.directory)
            XCTAssertEqual(restored.events.count, 1)
            XCTAssertEqual(restored.events.first?.id, original.id)
            XCTAssertEqual(try XCTUnwrap(restored.events.first?.listenedSeconds), original.listenedSeconds + failed.listenedSeconds, accuracy: 0.001)
            XCTAssertEqual(restored.favorites, [favorite])
            XCTAssertFalse(context.library.requiresReload)
            XCTAssertNil(context.library.errorMessage)
        }
    }

    func testRecoveryReconcilesExternalPreferencesCachePolicyAndRemoteFallback() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let extraction = AppModelRequestGate<Bool, [URL]>()
        addTeardownBlock { await extraction.close() }
        let resolver = YouTubeStreamResolver(extract: { _, remote in try await extraction.receive(remote) },
                                             validate: { _ in }, audioCache: fixture.cache)
        let first = AppModelFixtures.track("fsiPzT50ZiM")
        let other = AppModelFixtures.track("NJAv_7lHUIU")
        let snapshot = PlaybackSnapshot(queue: [first, other, first], currentIndex: 2, position: 47.25,
                                        shuffleEnabled: true, repeatMode: .all, originalQueue: [first, first, other])
        let context = try makeContext(snapshot: snapshot, resolver: resolver)
        addTeardownBlock { @MainActor in LyricsDNSConfiguration.configure(enabled: false) }
        try await PlaybackTestSupport.waitUntil { !context.player.isUpdatingAudioCacheLimit }
        let external = LibraryStore(directory: context.directory)
        var preferences = external.preferences
        preferences.languages = [.hindi]
        preferences.appearance = .light
        preferences.accent = .mint
        preferences.homeLayout.setVisible(false, for: .charts)
        preferences.audioCacheLimit = .mb250
        preferences.crossfadeSeconds = 6
        preferences.gaplessPlayback = false
        preferences.automix = false
        preferences.autoplay = false
        preferences.normalizeVolume = false
        preferences.allowRemoteFallback = true
        preferences.useEncryptedDNS = true
        preferences.newReleaseAlerts = false
        external.preferences = preferences
        external.updatePlayback(PlaybackSnapshot(queue: [other], position: 1))
        XCTAssertNil(external.errorMessage)
        context.library.recordSearch("rejected-before-reload")
        XCTAssertTrue(context.library.requiresReload)

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertEqual(context.library.preferences, preferences)
        XCTAssertEqual(context.player.settings, PlaybackTransitionSettings(preferences))
        XCTAssertEqual(context.player.queue, snapshot.queue)
        XCTAssertEqual(context.player.currentIndex, snapshot.currentIndex)
        XCTAssertEqual(context.player.position, snapshot.position)
        XCTAssertEqual(context.player.shuffleEnabled, snapshot.shuffleEnabled)
        XCTAssertEqual(context.player.repeatMode, snapshot.repeatMode)
        XCTAssertEqual(context.library.playback.originalQueue, snapshot.originalQueue)
        XCTAssertFalse(context.player.isPlaying)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        try await PlaybackTestSupport.waitUntil { !context.player.isUpdatingAudioCacheLimit }
        let usage = try await context.player.audioCacheUsage()
        XCTAssertEqual(usage?.capacityBytes, AudioCacheLimit.mb250.bytes)
        XCTAssertEqual(usage?.maximumSongs, AudioCacheLimit.mb250.maximumSongs)
        XCTAssertNil(context.player.audioCacheLimitError)

        context.model.play(AppModelFixtures.track("JGwWNGJdvx8"))
        let local = try await extraction.request(at: 0)
        XCTAssertFalse(local.input)
        try await extraction.complete(local, with: .success([]))
        let remote = try await extraction.request(at: 1)
        XCTAssertTrue(remote.input, "The player's next resolution must honor the reloaded opt-in")
        try await extraction.complete(remote, with: .success([]))
        try await PlaybackTestSupport.waitUntil { context.player.errorMessage != nil }
    }

    func testRecoveryRetiresOldHomeAndArtistWorkAndInvalidatesTheHomeCache() async throws {
        let context = try makeContext()
        let cached = AppModelFixtures.section("cached")
        await context.catalog.discoveries.enqueue(.success([cached]))
        await context.charts.charts.enqueue(.success(AppModelFixtures.chart("cached-chart")))
        await context.model.loadHome()
        let oldHome = context.start { await $0.loadHome(force: true) }
        let oldDiscovery = try await context.catalog.discoveries.request(at: 1)
        let oldChart = try await context.charts.charts.request(at: 1)
        let artist = MusicCollection(id: "UC-recovery-artist", title: "Recovery Artist", kind: .artist)
        let oldArtist = context.start { await $0.openArtist(ArtistCredit(name: artist.title)) }
        let lookup = try await context.catalog.searches.request(at: 0)
        let external = LibraryStore(directory: context.directory)
        external.toggleDislike(cached.tracks[0])
        external.toggleFavorite(AppModelFixtures.track("external-favorite"))

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertFalse(context.model.isLoadingHome)
        XCTAssertFalse(context.model.isArtistLookupPending)
        XCTAssertEqual(context.model.homeSections.map(\.id), [cached.id])
        XCTAssertTrue(context.model.homeSections.flatMap(\.tracks).isEmpty)
        let currentHome = context.start { await $0.loadHome() }
        let currentDiscovery = try await context.catalog.discoveries.request(at: 2)
        let currentChart = try await context.charts.charts.request(at: 2)
        try await context.catalog.discoveries.complete(oldDiscovery, with: .success([AppModelFixtures.section("obsolete")]))
        try await context.charts.charts.complete(oldChart, with: .success(AppModelFixtures.chart("obsolete-chart")))
        try await context.catalog.searches.complete(lookup, with: .success(CatalogPage(collections: [artist])))
        await oldHome.value
        await oldArtist.value
        XCTAssertTrue(context.model.isLoadingHome)
        XCTAssertTrue(context.model.navigationPaths.isEmpty)
        XCTAssertEqual(context.model.homeSections.map(\.id), [cached.id])

        try await context.catalog.discoveries.complete(currentDiscovery, with: .success([AppModelFixtures.section("current")]))
        try await context.charts.charts.complete(currentChart, with: .success(AppModelFixtures.chart("current-chart")))
        await currentHome.value
        XCTAssertEqual(context.model.homeSections.map(\.id), ["current"])
        XCTAssertEqual(context.model.charts.map(\.id), ["current-chart"])
        XCTAssertFalse(context.model.isLoadingHome)
    }

    func testRecoveryRetiresMixGenerationEvenWhenDiscoveryLanguagesAreUnchanged() async throws {
        let context = try makeContext(generatesMixes: true)
        let seed = context.seedListener(primary: AppModelFixtures.track("recovery-seed"))
        let mix = try XCTUnwrap(context.model.refreshMixes())
        let radios = [try await context.catalog.radios.request(at: 0), try await context.catalog.radios.request(at: 1)]
        let artist = try await context.catalog.artists.request(at: 0)
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(seed)

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertFalse(context.model.isGeneratingMixes)
        let candidates = (0..<12).map { RecommendationFixtures.track("obsolete-\($0)", artist: "Artist \($0)", language: .english) }
        for request in radios { try await context.catalog.radios.complete(request, with: .success(candidates)) }
        try await context.catalog.artists.complete(artist, with: .success(context.artistPage(artist.input, songs: candidates)))
        await mix.value
        XCTAssertTrue(context.library.mixes.isEmpty)
        XCTAssertTrue(context.model.hasListeningProfile)
        let retry = try XCTUnwrap(context.model.refreshMixes())
        retry.cancel()
        await retry.value
        XCTAssertFalse(context.model.isGeneratingMixes)
    }

    func testRecoveryCancelsPendingRadioWithoutReplacingTheActiveStation() async throws {
        let context = try makeAudioContext()
        let f = ExperienceRadioFixtures.self
        let active = context.model.startRadio(f.melancholy)
        try await f.answerSearches(context, from: 0, with: f.melancholySearches)
        try await f.answerRadios(context, from: 0, with: f.melancholyRadios)
        await active.value
        try await pauseAfterAdvance(context)
        context.player.flushListeningProgress()
        let queue = context.player.queue
        let position = context.player.position
        let stream = context.player.currentStreamURL
        let obsolete = context.model.startRadio(f.gym, languages: [.hindi])
        try await f.answerSearches(context, from: 2, with: f.gymSearches)
        _ = try await context.catalog.autoplayRadios.request(at: 3)
        let external = LibraryStore(directory: context.directory)
        external.toggleFavorite(AppModelFixtures.track("radio-external-favorite"))

        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertNil(context.model.radioError)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertEqual(context.model.selectedRadioExperience, f.melancholy)
        XCTAssertEqual(context.player.queue, queue)
        XCTAssertEqual(context.player.position, position)
        XCTAssertEqual(context.player.currentStreamURL, stream)
        XCTAssertFalse(context.player.isPlaying)
        let replacement = context.model.startRadio(f.gym, languages: [.hindi])
        _ = try await context.catalog.searches.request(at: 5)
        try await f.answerRadios(context, from: 2, with: f.gymRadios)
        await obsolete.value
        XCTAssertTrue(context.model.isLoadingRadio)
        XCTAssertEqual(context.model.selectedRadioExperience, f.gym)
        XCTAssertEqual(context.model.activeRadioExperience, f.melancholy)
        XCTAssertEqual(context.player.queue, queue)
        try await f.answerSearches(context, from: 4, with: f.gymSearches)
        try await f.answerRadios(context, from: 4, with: f.gymRadios)
        await replacement.value
        XCTAssertFalse(context.model.isLoadingRadio)
        XCTAssertEqual(context.model.activeRadioExperience, f.gym)
    }

    func testReleaseChecksHonorReloadedAlertPreferencesAndPendingDeliveries() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let directory = fixture.root.appendingPathComponent("Library", isDirectory: true)
        let library = LibraryStore(directory: directory)
        library.preferences.newReleaseAlerts = false
        library.preferences.useEncryptedDNS = false
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        addTeardownBlock {
            await catalog.close()
            await charts.charts.close()
        }
        let notifier = ReleaseNotifierMock()
        let player = PlayerController(resolver: AppModelStreamResolver())
        defer { player.pause() }
        let model = MusicAppModel(library: library, player: player, catalog: catalog, charts: charts,
                                  lyrics: AppModelLyricsProvider(), releaseNotifier: notifier,
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  generatesMixes: false)
        let followed = FollowedArtist(id: "UC-recovery-follow", name: "Followed Artist", knownReleaseIDs: ["baseline"], lastCheckedAt: Date())
        library.follow(followed)
        let external = LibraryStore(directory: directory)
        external.preferences.newReleaseAlerts = true
        let release = ArtistRelease(id: "recovered-release", title: "Recovered release", subtitle: "Single",
                                    artistID: followed.id, artistName: followed.name, discoveredAt: Date())
        XCTAssertTrue(external.recordReleaseCheck(artistID: followed.id, knownReleaseIDs: [release.id], newReleases: [release]))

        XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
        XCTAssertTrue(library.preferences.newReleaseAlerts)
        _ = await model.checkForNewReleases()
        var notified = await notifier.notified
        XCTAssertEqual(notified.map(\.id), [release.id])
        XCTAssertTrue(library.pendingReleaseNotifications.isEmpty)

        let disablingWriter = LibraryStore(directory: directory)
        let suppressed = ArtistRelease(id: "suppressed-release", title: "Suppressed release", subtitle: "Single",
                                       artistID: followed.id, artistName: followed.name, discoveredAt: Date())
        XCTAssertTrue(disablingWriter.recordReleaseCheck(artistID: followed.id, knownReleaseIDs: [suppressed.id], newReleases: [suppressed]))
        disablingWriter.preferences.newReleaseAlerts = false
        XCTAssertEqual(model.reloadSavedLibrary(), .reloaded)
        _ = await model.checkForNewReleases()
        notified = await notifier.notified
        XCTAssertEqual(notified.map(\.id), [release.id])
        XCTAssertFalse(library.preferences.newReleaseAlerts)
        XCTAssertTrue(library.pendingReleaseNotifications.isEmpty)
        let requests = await catalog.artists.requests
        XCTAssertTrue(requests.isEmpty, "Reloaded delivery state does not require another throttled artist fetch")
    }

    func testFailedInitialLoadRecoversPausedShuffledSnapshotWithoutPublishingThePlaceholder() async throws {
        let song = AppModelFixtures.track("cold-start-current")
        let other = AppModelFixtures.track("cold-start-other")
        let snapshot = PlaybackSnapshot(queue: [other, song, song], currentIndex: 2, position: 47.375,
                                        shuffleEnabled: true, repeatMode: .all, originalQueue: [song, other, song])
        for savesHistory in [true, false] {
            let fixture = try makeFailedInitialLoad(snapshot: snapshot, saveListeningHistory: savesHistory)
            let model = fixture.model
            XCTAssertFalse(model.library.hasLoadedDocument)
            XCTAssertTrue(model.library.requiresReload)
            XCTAssertTrue(model.player.queue.isEmpty)
            let clearHistory = try XCTUnwrap(model.library.onHistoryCleared)
            var historyBoundaries = 0
            model.library.onHistoryCleared = {
                historyBoundaries += 1
                clearHistory()
            }
            model.player.flushListeningProgress()
            model.player.pause()
            XCTAssertEqual(model.reloadSavedLibrary(), .failed)
            XCTAssertFalse(model.library.hasLoadedDocument)

            let file = fixture.file
            let saved = fixture.saved
            try saved.write(to: file, options: .atomic)
            let persist = try XCTUnwrap(model.player.onSnapshotChanged)
            var checkpoints = 0
            model.player.onSnapshotChanged = { checkpoint in
                persist(checkpoint)
                checkpoints += 1
                XCTAssertEqual(try? Data(contentsOf: file), saved,
                               "Even restore's intermediate flush must leave the repaired snapshot intact")
            }

            XCTAssertEqual(model.reloadSavedLibrary(), savesHistory ? .reloaded : .historyBoundary)
            XCTAssertTrue(model.library.hasLoadedDocument)
            XCTAssertFalse(model.library.requiresReload)
            XCTAssertNil(model.library.errorMessage)
            XCTAssertGreaterThan(checkpoints, 0)
            XCTAssertEqual(historyBoundaries, savesHistory ? 0 : 1)
            XCTAssertEqual(model.player.queue, snapshot.queue)
            XCTAssertEqual(model.player.currentIndex, snapshot.currentIndex)
            XCTAssertEqual(model.player.currentTrack, song)
            XCTAssertEqual(model.player.position, snapshot.position)
            XCTAssertEqual(model.player.shuffleEnabled, snapshot.shuffleEnabled)
            XCTAssertEqual(model.player.repeatMode, snapshot.repeatMode)
            XCTAssertFalse(model.player.isPlaying)
            XCTAssertFalse(model.player.isLoading)
            XCTAssertNil(model.player.currentStreamURL)
            let requests = await fixture.streams.streams.requests
            XCTAssertTrue(requests.isEmpty, "Recovery must restore paused without resolving or starting audio")

            let restored = LibraryStore(directory: file.deletingLastPathComponent())
            XCTAssertEqual(restored.playback.queue, snapshot.queue)
            XCTAssertEqual(restored.playback.currentIndex, snapshot.currentIndex)
            XCTAssertEqual(restored.playback.position, snapshot.position)
            XCTAssertEqual(restored.playback.shuffleEnabled, snapshot.shuffleEnabled)
            XCTAssertEqual(restored.playback.repeatMode, snapshot.repeatMode)
            XCTAssertEqual(restored.playback.originalQueue, snapshot.originalQueue)
            XCTAssertTrue(restored.events.isEmpty)
            XCTAssertTrue(restored.recentlyPlayed.isEmpty)
        }
    }

    func testPlaybackIntentAfterFailedInitialLoadWinsEvenWhenTheQueueIsCleared() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 12)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let diskSong = AppModelFixtures.track("cold-start-disk-song")
        let snapshot = PlaybackSnapshot(queue: [diskSong], position: 47.375)
        for intent in ["enqueue", "play", "enqueue-and-clear", "play-and-clear", "repeat-and-reset"] {
            let fixture = try makeFailedInitialLoad(snapshot: snapshot, resolver: PlaybackFileResolver(url: url, duration: 12))
            let model = fixture.model
            let song = AppModelFixtures.track("cold-start-user-song")
            let persist = try XCTUnwrap(model.player.onSnapshotChanged)
            var latestSnapshot: PlaybackSnapshot?
            model.player.onSnapshotChanged = { checkpoint in
                latestSnapshot = checkpoint
                persist(checkpoint)
            }
            if intent.hasPrefix("enqueue") {
                model.player.enqueue(song)
                if intent.hasSuffix("clear") { model.player.removeFromQueue(at: 0) }
            } else if intent.hasPrefix("play") {
                model.play(song)
                try await PlaybackTestSupport.waitUntil { model.player.isPlaying && model.player.position > 0.7 }
                model.player.pause()
                if intent.hasSuffix("clear") { model.player.play([]) }
            } else {
                for _ in 0..<3 { model.player.cycleRepeatMode() }
            }
            let chosen = try XCTUnwrap(latestSnapshot)
            XCTAssertFalse(model.library.hasLoadedDocument)
            if intent.hasSuffix("clear") || intent == "repeat-and-reset" { XCTAssertTrue(chosen.queue.isEmpty) }

            try fixture.saved.write(to: fixture.file, options: .atomic)
            XCTAssertEqual(model.reloadSavedLibrary(), .reloaded, intent)
            XCTAssertEqual(model.player.queue, chosen.queue, intent)
            XCTAssertEqual(model.player.currentIndex, chosen.currentIndex, intent)
            XCTAssertEqual(model.player.position, chosen.position, accuracy: 0.05, intent)
            XCTAssertEqual(model.player.shuffleEnabled, chosen.shuffleEnabled, intent)
            XCTAssertEqual(model.player.repeatMode, chosen.repeatMode, intent)
            XCTAssertFalse(model.player.isPlaying)
            let restored = LibraryStore(directory: fixture.file.deletingLastPathComponent())
            XCTAssertEqual(restored.playback.queue, chosen.queue, intent)
            XCTAssertEqual(restored.playback.currentIndex, chosen.currentIndex, intent)
            XCTAssertEqual(restored.playback.position, model.player.position, accuracy: 0.001, intent)
            XCTAssertEqual(restored.playback.originalQueue, chosen.originalQueue, intent)
            XCTAssertNil(restored.errorMessage)
            if intent.hasPrefix("play") {
                XCTAssertEqual(restored.events.count, 1)
                XCTAssertEqual(restored.events.first?.track.id, song.id)
                XCTAssertGreaterThan(restored.events.first?.listenedSeconds ?? 0, 0.5)
            }
        }
    }

    func testFailedReloadOfAnEstablishedEmptyPlayerDoesNotBecomeAStartupRestore() throws {
        let context = try makeContext()
        XCTAssertTrue(context.library.hasLoadedDocument)
        let external = LibraryStore(directory: context.directory)
        external.updatePlayback(PlaybackSnapshot(queue: [AppModelFixtures.track("external-queue")], position: 47.375))
        let file = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let repaired = try Data(contentsOf: file)
        try Data("{broken library".utf8).write(to: file, options: .atomic)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .failed)
        XCTAssertTrue(context.library.hasLoadedDocument)

        try repaired.write(to: file, options: .atomic)
        XCTAssertEqual(context.model.reloadSavedLibrary(), .reloaded)
        XCTAssertTrue(context.player.queue.isEmpty)
        XCTAssertEqual(context.player.position, 0)
        XCTAssertTrue(LibraryStore(directory: context.directory).playback.queue.isEmpty)
    }

    private func makeFailedInitialLoad(snapshot: PlaybackSnapshot, saveListeningHistory: Bool = true,
                                       resolver: (any StreamResolving)? = nil) throws
        -> (model: MusicAppModel, file: URL, saved: Data, streams: AppModelStreamResolver) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-ColdRecovery-\(UUID())", isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let savedLibrary = LibraryStore(directory: directory)
        var preferences = savedLibrary.preferences
        preferences.languages = [.english]
        preferences.useEncryptedDNS = false
        preferences.newReleaseAlerts = false
        preferences.autoplay = false
        preferences.gaplessPlayback = false
        preferences.automix = false
        preferences.saveListeningHistory = saveListeningHistory
        savedLibrary.preferences = preferences
        savedLibrary.updatePlayback(snapshot)
        if let error = savedLibrary.errorMessage { throw AppModelTestFailure.storage(error) }
        let file = directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: file)
        try Data("{broken library".utf8).write(to: file, options: .atomic)
        let catalog = AppModelCatalogProvider()
        let charts = AppModelChartsProvider()
        let streams = AppModelStreamResolver()
        let model = MusicAppModel(library: LibraryStore(directory: directory), player: PlayerController(resolver: resolver ?? streams),
                                  catalog: catalog, charts: charts, lyrics: AppModelLyricsProvider(), releaseNotifier: ReleaseNotifierMock(),
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.player.pause()
            model.cancelPendingRadio()
            await catalog.close()
            await charts.charts.close()
            await streams.streams.close()
            LyricsDNSConfiguration.configure(enabled: false)
        }
        return (model, file, saved, streams)
    }

    private func pauseAfterAdvance(_ context: AppModelTestContext, from position: TimeInterval = 0) async throws {
        try await PlaybackTestSupport.waitUntil { context.player.isPlaying && context.player.position > position + 0.7 }
        context.player.pause()
    }

    private func makeAudioContext() throws -> AppModelTestContext {
        let url = try PlaybackTestSupport.audioFile(seconds: 12)
        addTeardownBlock { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try makeContext(resolver: PlaybackFileResolver(url: url, duration: 12))
        context.model.updatePreferences {
            $0.autoplay = false
            $0.gaplessPlayback = false
            $0.automix = false
            $0.newReleaseAlerts = false
        }
        return context
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot(), resolver: (any StreamResolving)? = nil,
                             generatesMixes: Bool = false) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot, resolver: resolver, generatesMixes: generatesMixes)
        addTeardownBlock { @MainActor in
            context.model.cancelPendingRadio()
            try await context.close()
        }
        return context
    }
}
