import Foundation
import XCTest
@testable import GanaBajana

actor PlaybackResolutionGate: StreamResolving {
    struct Request: Sendable {
        let id: UUID
        let trackID: String
        let forceRefresh: Bool
    }
    private(set) var requests: [Request] = []
    private var pending: [UUID: CheckedContinuation<ResolvedStream, Error>] = [:]

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        let request = Request(id: UUID(), trackID: track.id, forceRefresh: forceRefresh)
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[request.id] = $0 }
    }

    func finish(_ request: Request, with result: Result<ResolvedStream, Error>) {
        pending.removeValue(forKey: request.id)?.resume(with: result)
    }

    func cancelRemaining() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}

actor PlaybackFileResolver: StreamResolving {
    let url: URL
    let duration: TimeInterval?
    let loudnessDb: Double?
    private(set) var refreshes: [Bool] = []

    init(url: URL, duration: TimeInterval? = nil, loudnessDb: Double? = nil) {
        self.url = url
        self.duration = duration
        self.loudnessDb = loudnessDb
    }

    func resolve(track: Track, forceRefresh: Bool) -> ResolvedStream {
        refreshes.append(forceRefresh)
        return ResolvedStream(url: url, duration: duration, loudnessDb: loudnessDb)
    }
}

/// Serves a distinct local stream per track ID so multi-track transitions can use different lengths and loudness.
actor PlaybackFixtureResolver: StreamResolving {
    struct Entry: Sendable {
        var url: URL
        var duration: TimeInterval?
        var loudnessDb: Double?
        var expiresAt: Date?
        /// Expiry handed out for forceRefresh requests; defaults to expiresAt.
        var refreshedExpiresAt: Date?

        init(url: URL, duration: TimeInterval? = nil, loudnessDb: Double? = nil,
             expiresAt: Date? = nil, refreshedExpiresAt: Date? = nil) {
            self.url = url
            self.duration = duration
            self.loudnessDb = loudnessDb
            self.expiresAt = expiresAt
            self.refreshedExpiresAt = refreshedExpiresAt
        }
    }

    struct Request: Equatable, Sendable {
        let trackID: String
        let forceRefresh: Bool
    }

    private var entries: [String: Entry]
    private(set) var requests: [Request] = []

    init(_ entries: [String: Entry]) { self.entries = entries }

    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream {
        requests.append(Request(trackID: track.id, forceRefresh: forceRefresh))
        guard let entry = entries[track.id] else { throw MusicServiceError.unavailable("No fixture for \(track.id)") }
        let expiry = forceRefresh ? (entry.refreshedExpiresAt ?? entry.expiresAt) : entry.expiresAt
        return ResolvedStream(url: entry.url, duration: entry.duration, expiresAt: expiry, loudnessDb: entry.loudnessDb)
    }
}

/// A caching resolver over local files: `remote` is what a plain resolution returns until `download` has run,
/// after which `cached` takes over. Downloads can be delayed or made to fail so tests control when the copy lands.
actor PlaybackCachingFixtureResolver: StreamCaching {
    struct Entry: Sendable {
        var remote: URL
        var cached: URL?
        var duration: TimeInterval?
        var downloadDelay: Duration = .zero
        var downloadFails = false
    }

    enum Request: Equatable, Sendable {
        case resolve(String, forceRefresh: Bool)
        case download(String)
        case discard(String)
    }

    private let entries: [String: Entry]
    private var downloaded: Set<String>
    private(set) var requests: [Request] = []
    private(set) var retained: [Set<String>] = []

    init(_ entries: [String: Entry], downloaded: Set<String> = []) {
        self.entries = entries
        self.downloaded = downloaded
    }

    func resolve(track: Track, forceRefresh: Bool) throws -> ResolvedStream {
        requests.append(.resolve(track.id, forceRefresh: forceRefresh))
        guard let entry = entries[track.id] else { throw MusicServiceError.unavailable("No fixture for \(track.id)") }
        if downloaded.contains(track.id), let cached = entry.cached { return ResolvedStream(url: cached, duration: entry.duration) }
        return ResolvedStream(url: entry.remote, duration: entry.duration)
    }

    func download(_ track: Track) async throws -> ResolvedStream {
        requests.append(.download(track.id))
        guard let entry = entries[track.id], let cached = entry.cached, !entry.downloadFails else {
            throw MusicServiceError.unavailable("No cached fixture for \(track.id)")
        }
        try await Task.sleep(for: entry.downloadDelay)
        downloaded.insert(track.id)
        return ResolvedStream(url: cached, duration: entry.duration)
    }

    func discardCached(_ track: Track) {
        requests.append(.discard(track.id))
        downloaded.remove(track.id)
    }

    func retainCached(_ trackIDs: Set<String>) { retained.append(trackIDs) }

    nonisolated func isCachedStream(_ stream: ResolvedStream) -> Bool {
        entries.values.contains { $0.cached == stream.url }
    }

    var downloadedTrackIDs: Set<String> { downloaded }
}

enum PlaybackTestSupport {
    @MainActor
    static func waitUntil(timeout: TimeInterval = 8, _ predicate: @MainActor () -> Bool) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            if start.duration(to: .now) > .seconds(timeout) { throw PlaybackStreamError.timedOut }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    static func eventually(timeout: TimeInterval = 8, _ predicate: @MainActor () async -> Bool) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if start.duration(to: .now) > .seconds(timeout) { throw PlaybackStreamError.timedOut }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    static func waitForRequests(_ count: Int, on gate: PlaybackResolutionGate) async throws -> [PlaybackResolutionGate.Request] {
        let start = ContinuousClock.now
        while await gate.requests.count < count {
            if start.duration(to: .now) > .seconds(4) { throw PlaybackStreamError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        return await gate.requests
    }

    static func audioFile(seconds: Int = 8) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GanaBajanaPlaybackTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tone.wav")
        try audioData(seconds: seconds).write(to: url, options: .atomic)
        return url
    }

    /// A 16-bit mono 22.05 kHz sine tone as a complete RIFF/WAVE payload.
    static func audioData(seconds: Int = 8) -> Data {
        let sampleRate = 22_050
        let frames = seconds * sampleRate
        var data = Data()
        func text(_ string: String) { data.append(contentsOf: string.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        text("RIFF"); integer(UInt32(36 + frames * 2)); text("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
        integer(UInt16(2)); integer(UInt16(16)); text("data"); integer(UInt32(frames * 2))
        for frame in 0..<frames {
            integer(Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 1_000))
        }
        return data
    }
}
