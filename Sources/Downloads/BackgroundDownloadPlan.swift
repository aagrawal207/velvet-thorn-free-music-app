import Foundation
import Synchronization

/// An in-memory request only. The durable queue stores `metadata`, never this value or URLSession resume data.
struct BackgroundDownloadPlan: Sendable {
    let stream: ResolvedStream
    let metadata: AudioCache.Sidecar
    let expiresAt: Date

    init(stream: ResolvedStream, now: Date = Date()) throws {
        guard stream.url.scheme == "https", stream.url.host != nil,
              CompositeStreamResolver.isCacheable(stream) else { throw PlaybackStreamError.invalidMedia }
        let ext = stream.quality?.codec == .opus ? "webm" : stream.url.pathExtension.lowercased() == "wav" ? "wav" : "m4a"
        let length = AudioDownloader.declaredLength(in: stream.url) ?? 0
        guard length <= AudioCache.maximumFileBytes else { throw PlaybackStreamError.invalidMedia }
        self.stream = stream
        expiresAt = min(min(stream.expiresAt ?? .distantFuture, PlaybackTiming.expiry(in: stream.url) ?? .distantFuture),
                        now.addingTimeInterval(6 * 3_600))
        metadata = AudioCache.Sidecar(duration: PlaybackTiming.validDuration(stream.duration), loudnessDb: stream.loudnessDb,
                                     viewCount: stream.viewCount, bytes: length, storedAt: now, fileExtension: ext,
                                     quality: stream.quality, playbackSource: stream.playbackSource)
    }

    func request(allowCellular: Bool, now: Date) throws -> URLRequest {
        guard expiresAt.timeIntervalSince(now) > 90 else { throw PlaybackStreamError.expired }
        var request = URLRequest(url: stream.url)
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = allowCellular
        request.allowsExpensiveNetworkAccess = allowCellular
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // A full explicit range avoids the CDN's partial default response; publication still requires every byte.
        if metadata.bytes > 0 { request.setValue("bytes=0-\(metadata.bytes - 1)", forHTTPHeaderField: "Range") }
        return request
    }
}

/// Cancellation and final publication share this lock, so cancellation cannot slip between a check and a rename.
final class DownloadPublicationFence: Sendable {
    private let valid = Mutex(true)
    func cancel() { valid.withLock { $0 = false } }
    func withValid<T: Sendable>(_ operation: () throws -> T) throws -> T {
        try valid.withLock { valid in
            guard valid else { throw CancellationError() }
            return try operation()
        }
    }
}

enum BackgroundDownloadFailure: String, Error, Codable, Sendable {
    case expired, transport, invalidMedia, staging, publication, interrupted

    var message: String {
        switch self {
        case .expired: "The download link expired. Open Velvet Thorn and retry."
        case .transport, .interrupted: "The download was interrupted. Please retry."
        case .invalidMedia: "The downloaded file could not be verified."
        case .staging, .publication: "The downloaded audio could not be saved. Please retry."
        }
    }
}
