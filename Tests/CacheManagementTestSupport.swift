import Foundation
@testable import GanaBajana

@MainActor
final class CacheManagementFixture {
    let root: URL
    let cache: AudioCache
    let mock: CatalogMockSession

    init(capacityBytes: Int64 = 200 << 20, maximumFiles: Int = 40,
         handler: CatalogMockState.Handler? = nil,
         opusPreparation: @escaping AudioCache.OpusPreparation = { try await OpusNativeAudio.prepare(input: $0, output: $1) }) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-CacheManagement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        mock = CatalogMockSession(handler: handler ?? { _ in
            CatalogStub(headers: ["Content-Type": "audio/wav", "Content-Length": "\(payload.count)"], data: payload)
        })
        cache = AudioCache(directory: root.appendingPathComponent("Audio", isDirectory: true),
                           capacityBytes: capacityBytes, maximumFiles: maximumFiles, session: mock.session,
                           opusPreparation: opusPreparation)
    }

    @discardableResult
    func seed(_ id: String, seconds: Int = 1) throws -> URL {
        let payload = PlaybackTestSupport.audioData(seconds: seconds)
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let media = cache.directory.appendingPathComponent("\(id).wav")
        try payload.write(to: media)
        try sidecar(id, bytes: Int64(payload.count), duration: Double(seconds))
        return media
    }

    func sidecar(_ id: String, bytes: Int64, duration: TimeInterval = 1, fileExtension: String = "wav") throws {
        let sidecar = AudioCache.Sidecar(duration: duration, loudnessDb: nil, viewCount: nil,
                                         bytes: bytes, storedAt: Date(), fileExtension: fileExtension)
        try JSONEncoder().encode(sidecar).write(to: cache.directory.appendingPathComponent("\(id).json"))
    }

    func resolver(fastExtract: YouTubeStreamResolver.FastExtraction? = nil) -> YouTubeStreamResolver {
        YouTubeStreamResolver(extract: { id, _ in [AudioCacheTests.remote(id)] }, validate: { _ in },
                              fastExtract: fastExtract ?? { FastPathResult(urls: [AudioCacheTests.remote($0)]) }, audioCache: cache)
    }

    func close() async throws {
        _ = try? await cache.clearUnused()
        mock.close()
        try FileManager.default.removeItem(at: root)
    }
}
