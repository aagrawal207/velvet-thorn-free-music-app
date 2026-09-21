import XCTest
@testable import GanaBajana

@MainActor
final class OpusMaintenanceTests: XCTestCase {
    func testClearAndResizeLetCurrentPlaybackFallBackToAACWithoutPublishingStaleOpus() async throws {
        for operation in Maintenance.allCases {
            let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
            let fixture = try makeFixture(gate: gate)
            let validated = CatalogTestRecorder<URL>()
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
                fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
            let resolution = Task { try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false) }
            defer { resolution.cancel() }
            let request = try await gate.request(at: 0)
            let maintenance = Task { try await operation.perform(on: resolver) }
            defer { maintenance.cancel() }
            try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
            try await gate.complete(request, with: .success(OpusTestSupport.inspection))

            let result = try await resolution.value
            let usage = try await maintenance.value
            XCTAssertEqual(result.url, OpusTestSupport.aacURL)
            XCTAssertEqual(result.quality, OpusTestSupport.aacQuality)
            XCTAssertEqual(validated.values, [OpusTestSupport.aacURL])
            XCTAssertEqual(usage?.pendingDownloads, 0)
            XCTAssertEqual(usage?.songCount, 0)
            XCTAssertEqual(usage?.bytes, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path), [])

            let retry = Task { try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: true) }
            defer { retry.cancel() }
            let next = try await gate.request(at: 1)
            try await gate.complete(next, with: .success(OpusTestSupport.inspection))
            let prepared = try await retry.value
            XCTAssertEqual(prepared.quality?.codec, .opus, "Maintenance must not impose an Opus failure cooldown")
            XCTAssertTrue(prepared.url.isFileURL)
        }
    }

    func testQualityReloadKeepsRetainedAudioWhenMaintenanceCancelsOpusAndAACIsUnavailable() async throws {
        for operation in Maintenance.allCases {
            let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
            let fixture = try makeFixture(gate: gate)
            let track = OpusTestSupport.track
            let original = try fixture.seed(track.id)
            let originalData = try Data(contentsOf: original)
            await fixture.cache.pin(track.id)
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in throw PlaybackStreamError.httpStatus(503) },
                fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
            let resolution = Task { try await resolver.refreshQuality(track: track) }
            defer { resolution.cancel() }
            let request = try await gate.request(at: 0)
            let maintenance = Task { try await operation.perform(on: resolver, retaining: { [track.id] }) }
            defer { maintenance.cancel() }
            try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
            try await gate.complete(request, with: .success(OpusTestSupport.inspection))

            let result = try await resolution.value
            let usage = try await maintenance.value
            XCTAssertEqual(result.url, original)
            XCTAssertEqual(try Data(contentsOf: original), originalData)
            XCTAssertEqual(usage?.bytes, Int64(originalData.count))
            XCTAssertEqual(usage?.songCount, 1)
            XCTAssertEqual(usage?.pendingDownloads, 0)
            XCTAssertEqual(fixture.mock.state.requests.count, 1)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.directory.path)
                .contains { $0.contains(".opus-") || $0.hasSuffix(".part") })
        }
    }

    func testCancellingThePlaybackIntentDuringMaintenanceNeverReturnsAACOrRetainedAudio() async throws {
        for refresh in [false, true] {
            for operation in Maintenance.allCases {
                let gate = AppModelRequestGate<URL, OpusNativeAudio.Inspection>()
                let fixture = try makeFixture(gate: gate)
                let track = OpusTestSupport.track
                if refresh { try fixture.seed(track.id); await fixture.cache.pin(track.id) }
                let validated = CatalogTestRecorder<URL>()
                let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { validated.record($0) },
                    fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
                let resolution = Task {
                    if refresh { return try await resolver.refreshQuality(track: track) }
                    return try await resolver.resolve(track: track, forceRefresh: false)
                }
                defer { resolution.cancel() }
                let request = try await gate.request(at: 0)
                let maintenance = Task { try await operation.perform(on: resolver) }
                defer { maintenance.cancel() }
                try await PlaybackTestSupport.eventually { await gate.cancellations.contains(request.id) }
                resolution.cancel()
                do { _ = try await resolution.value; XCTFail("The listener cancelled playback") }
                catch { XCTAssertTrue(error is CancellationError) }
                try await gate.complete(request, with: .success(OpusTestSupport.inspection))
                _ = try await maintenance.value
                XCTAssertTrue(validated.values.isEmpty)
                let cached = await fixture.cache.entry(for: track.id)
                XCTAssertNotEqual(cached?.quality?.codec, .opus)
            }
        }
    }

    func testPlaybackStartingDuringMaintenanceUsesAACWithoutStartingADiskWriter() async throws {
        for operation in Maintenance.allCases {
            let gate = AppModelRequestGate<Bool, Set<String>>()
            let fixture = try CacheManagementFixture(capacityBytes: AudioCacheLimit.mb500.bytes,
                maximumFiles: AudioCacheLimit.mb500.maximumSongs, opusPreparation: OpusTestSupport.prepare)
            addTeardownBlock { try await fixture.close() }
            addTeardownBlock { await gate.close() }
            let resolver = YouTubeStreamResolver(extract: { _, _ in [] }, validate: { _ in },
                fastExtract: { _ in OpusTestSupport.fast() }, audioCache: fixture.cache, opusEnabled: true)
            let maintenance = Task {
                try await operation.perform(on: resolver, retaining: { (try? await gate.receive(true)) ?? [] })
            }
            defer { maintenance.cancel() }
            let request = try await gate.request(at: 0)
            let result = try await resolver.resolve(track: OpusTestSupport.track, forceRefresh: false)
            XCTAssertEqual(result.url, OpusTestSupport.aacURL)
            XCTAssertTrue(fixture.mock.state.requests.isEmpty)
            try await gate.complete(request, with: .success([]))
            _ = try await maintenance.value
        }
    }

    private func makeFixture(gate: AppModelRequestGate<URL, OpusNativeAudio.Inspection>) throws -> CacheManagementFixture {
        let fixture = try CacheManagementFixture(capacityBytes: AudioCacheLimit.mb500.bytes,
            maximumFiles: AudioCacheLimit.mb500.maximumSongs, handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(OpusTestSupport.webM.count)"],
                        data: OpusTestSupport.webM)
        }, opusPreparation: { input, output in
            _ = try await OpusTestSupport.prepare(input: input, output: output)
            return try await gate.receive(output)
        })
        addTeardownBlock { try await fixture.close() }
        addTeardownBlock { await gate.close() }
        return fixture
    }

    private enum Maintenance: CaseIterable, Sendable {
        case clear, resize

        func perform(on resolver: YouTubeStreamResolver,
                     retaining: @escaping @Sendable () async -> Set<String> = { [] }) async throws -> AudioCache.Usage? {
            switch self {
            case .clear: try await resolver.clearAudioCache(retaining: retaining)
            case .resize: try await resolver.setAudioCacheLimit(.mb250, retaining: retaining)
            }
        }
    }
}
