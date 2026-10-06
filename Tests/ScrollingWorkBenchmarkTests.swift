import Foundation
import Observation
import XCTest
@testable import GanaBajana

@MainActor
final class ScrollingWorkBenchmarkTests: XCTestCase {
    func testLargeHistoryProfileReadsAndListeningCheckpoint() throws {
        try withLibraryTestDirectory { directory in
            let now = Date()
            let document = benchmarkDocument(now: now)
            let track = try XCTUnwrap(document.playback.queue.first)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(LibraryPersistence.encode(document), to: url, replacing: nil)
            let library = LibraryStore(directory: directory)
            let player = PlayerController(resolver: AppModelStreamResolver())
            let lyrics = AppModelLyricsProvider()
            let model = MusicAppModel(library: library, player: player, catalog: AppModelCatalogProvider(),
                                      charts: AppModelChartsProvider(), lyrics: lyrics,
                                      account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                      recordingLanguageService: ArtistSpotlightLanguageService(provider: lyrics),
                                      generatesMixes: false)
            var preferenceInvalidated = false
            withObservationTracking { _ = library.preferences } onChange: {
                MainActor.assumeIsolated { preferenceInvalidated = true }
            }
            let profileStart = ContinuousClock.now
            for _ in 0..<30 { XCTAssertFalse(model.listeningLanguageProfile.requestKey.isEmpty) }
            let profileMs = Double(profileStart.duration(to: .now) / .microseconds(1)) / 1_000
            let session = UUID()
            let started = now.addingTimeInterval(-120)
            let checkpointStart = ContinuousClock.now
            var callbackTimes: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                XCTAssertTrue(player.onListeningProgress?(track, session, started, 5) == true)
                callbackTimes.append(Double(start.duration(to: .now) / .microseconds(1)) / 1_000)
            }
            let checkpointMs = Double(checkpointStart.duration(to: .now) / .microseconds(1)) / 3_000
            XCTAssertEqual(library.events.first { $0.id == session }?.listenedSeconds, 15)
            XCTAssertNil(library.errorMessage)
            print("SCROLL_BENCH events=10000 profile_reads=30 profile_ms=\(profileMs) progress_callback_ms=\(checkpointMs) callbacks_ms=\(callbackTimes) preference_invalidated=\(preferenceInvalidated)")
            withExtendedLifetime(model) {}
        }
    }

    func testLargeHistoryAsyncCheckpointMainActorOccupancy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajana-ScrollBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let document = benchmarkDocument(now: now)
        let track = try XCTUnwrap(document.playback.queue.first)
        let url = directory.appendingPathComponent(LibraryPersistence.fileName)
        try LibraryPersistence.write(LibraryPersistence.encode(document), to: url, replacing: nil)
        let library = LibraryStore(directory: directory)
        let player = PlayerController(resolver: AppModelStreamResolver())
        let lyrics = AppModelLyricsProvider()
        let model = MusicAppModel(library: library, player: player, catalog: AppModelCatalogProvider(),
                                  charts: AppModelChartsProvider(), lyrics: lyrics,
                                  account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                  recordingLanguageService: ArtistSpotlightLanguageService(provider: lyrics),
                                  generatesMixes: false, asynchronousListeningCheckpoints: true)
        await player.waitForListeningCheckpointDelivery()
        var submission: [Double] = []
        var persistenceMain: [Double] = []
        var wall: [Double] = []
        let event = ListeningEvent(id: UUID(), track: track, startedAt: now.addingTimeInterval(-120), listenedSeconds: 5)
        for _ in 0..<3 {
            let before = library.listeningCheckpointMainActorMilliseconds
            let start = ContinuousClock.now
            XCTAssertTrue(player.enqueueListeningCheckpoint(event))
            player.flushListeningProgress()
            submission.append(Double(start.duration(to: .now) / .microseconds(1)) / 1_000)
            await player.waitForListeningCheckpointDelivery()
            wall.append(Double(start.duration(to: .now) / .microseconds(1)) / 1_000)
            persistenceMain.append(library.listeningCheckpointMainActorMilliseconds - before)
        }
        XCTAssertTrue(player.pendingListeningCheckpoints.isEmpty)
        XCTAssertEqual(library.events.first { $0.id == event.id }?.listenedSeconds, 15)
        XCTAssertEqual(LibraryStore(directory: directory).events.first { $0.id == event.id }?.listenedSeconds, 15)
        print("SCROLL_ASYNC_BENCH events=10000 submit_ms=\(submission) persistence_main_ms=\(persistenceMain) wall_ms=\(wall)")
        withExtendedLifetime(model) {}
    }

    private func benchmarkDocument(now: Date) -> LibraryDocument {
        let tracks = (0..<100).map { index in
            Track(id: "scroll-benchmark-\(index)", title: "Song \(index)", artists: ["Artist \(index % 20)"],
                  duration: 240, language: index.isMultiple(of: 2) ? .english : .hindi)
        }
        var document = LibraryDocument()
        document.preferences.useEncryptedDNS = false
        document.favorites = Array(tracks.prefix(50))
        document.playback = PlaybackSnapshot(queue: [tracks[0]], originalQueue: [tracks[0]])
        document.events = (0..<10_000).map { index in
            ListeningEvent(id: UUID(), track: tracks[index % tracks.count],
                           startedAt: now.addingTimeInterval(-Double(index + 1) * 240), listenedSeconds: 180)
        }
        return document
    }
}
