import AVFoundation
import Foundation
import OSLog

struct AudioExport: Equatable, Sendable {
    let url: URL
    let bytes: Int64
    let tagged: Bool
    let codec: SourceAudioQuality.Codec?
    let transcoded: Bool
    let hasArtwork: Bool
    let artworkJPEG: Data?
    private let lifetime: AudioExportLifetime?

    init(url: URL, bytes: Int64, tagged: Bool, codec: SourceAudioQuality.Codec?,
         transcoded: Bool = false, hasArtwork: Bool = false, lifetime: AudioExportLifetime? = nil,
         artworkJPEG: Data? = nil) {
        self.url = url
        self.bytes = bytes
        self.tagged = tagged
        self.codec = codec
        self.transcoded = transcoded
        self.hasArtwork = hasArtwork
        self.artworkJPEG = artworkJPEG
        self.lifetime = lifetime
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.bytes == rhs.bytes && lhs.tagged == rhs.tagged && lhs.codec == rhs.codec
            && lhs.transcoded == rhs.transcoded && lhs.hasArtwork == rhs.hasArtwork && lhs.artworkJPEG == rhs.artworkJPEG
    }
}

enum AudioExportError: LocalizedError, Equatable {
    case noLocalCopy, exportFailed, timedOut, unsupportedAudio, invalidArtwork, verificationFailed, busy
    case artworkUnavailable
    case failed(stage: AudioExportStage, reason: AudioExportFailureReason)

    var diagnostic: String {
        switch self {
        case .failed(let stage, let reason): "\(stage.rawValue)/\(reason.rawValue)"
        case .noLocalCopy: "source/missing"
        case .exportFailed: "export/native"
        case .timedOut: "export/timeout"
        case .unsupportedAudio: "source/unsupported"
        case .invalidArtwork: "artwork/invalid"
        case .artworkUnavailable: "artwork/unavailable"
        case .verificationFailed: "verify/unknown"
        case .busy: "export/busy"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noLocalCopy: "Download this song first. Export uses the complete copy on this device."
        case .exportFailed: "The audio file could not be prepared for sharing."
        case .timedOut: "Preparing the file took too long. Try again."
        case .unsupportedAudio: "This device could not convert the local audio to AAC."
        case .invalidArtwork: "The cover image could not be prepared for the audio file."
        case .verificationFailed: "The exported audio or its tags could not be verified."
        case .busy: "Two audio exports are already being prepared. Try again when one finishes."
        case .artworkUnavailable: "The song's cover could not be loaded. Check your connection and try again. No file was shared."
        case .failed(let stage, let reason):
            "\(reason.message) Try again with Velvet Thorn open. If it keeps failing, download the song again. (\(stage.rawValue)/\(reason.rawValue))"
        }
    }
}

enum AudioExportStage: String, Sendable { case inspect, passthrough, encode, verify, publish }

enum AudioExportFailureReason: String, Sendable, CaseIterable {
    case native, emptyFile = "empty_file", outputFormat = "output_format", duration
    case title, artist, album, coverMissing = "cover_missing", coverType = "cover_type", coverMismatch = "cover_mismatch"
    case decoderStart = "decoder_start", decoderRead = "decoder_read", pcmPayload = "pcm_payload", pcmTiming = "pcm_timing"
    case pcmDuration = "pcm_duration"

    var message: String {
        switch self {
        case .title, .artist, .album: "The exported song details did not match."
        case .coverMissing, .coverType, .coverMismatch: "The cover could not be verified inside the M4A file."
        case .duration, .pcmDuration: "The exported audio length did not match the complete song."
        case .decoderStart, .decoderRead, .pcmPayload, .pcmTiming: "The exported audio could not be decoded completely."
        case .outputFormat: "The exported file was not compatible AAC audio."
        case .emptyFile: "The exported file was empty."
        case .native: "Audio preparation stopped before it finished."
        }
    }
}

actor AudioExporter {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
    static let maximumFileNameLength = 120
    static let staleAge: TimeInterval = 3_600
    static let deadline: TimeInterval = 120
    static let maximumConcurrentExports = 2

    enum Stage: Equatable, Sendable { case inspect, passthrough, encode, verify }

    private let outputDirectory: URL
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let stageObserver: @Sendable (Stage) async throws -> Void
    private var active = 0
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")

    init(now: @escaping @Sendable () -> Date = { Date() }, directory: URL = AudioExporter.directory,
         timeout: TimeInterval = AudioExporter.deadline,
         stageObserver: @escaping @Sendable (Stage) async throws -> Void = { _ in }) {
        self.now = now
        outputDirectory = directory
        self.timeout = timeout.isFinite ? min(max(0, timeout), Self.deadline) : Self.deadline
        self.stageObserver = stageObserver
    }

    // The caller's cache reader lease must span this entire call, including cancellation drainage.
    func export(track: Track, source: CachedAudio, artwork: Data?) async throws -> AudioExport {
        try Task.checkCancellation()
        guard active < Self.maximumConcurrentExports else {
            log.notice("event=export outcome=busy bytes=0")
            throw AudioExportError.busy
        }
        active += 1
        defer { active -= 1 }
        let folder = outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lifetime = AudioExportLifetime(directory: folder)
        let output = folder.appendingPathComponent(Self.fileName(artist: track.artistName, title: track.title) + ".m4a")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let observer = stageObserver
        do {
            guard source.url.isFileURL, Self.size(of: source.url) > 0 else { throw AudioExportError.noLocalCopy }
            guard track.artworkURL == nil || artwork != nil else { throw AudioExportError.artworkUnavailable }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let (transcoded, embeddedCover) = try await Self.bounded(seconds: timeout) {
                let cover = try artwork.map { try AudioExportArtwork.prepare($0) }
                try await observer(.inspect)
                let inspection = try await Self.atStage(.inspect) { try await NativeAudioExport.inspect(source.url) }
                Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")
                    .info("event=export_input codec=\(inspection.isAAC ? "aac" : "other", privacy: .public)")
                var preserved = false
                var embeddedCover: Data?
                if inspection.isAAC {
                    do {
                        embeddedCover = try await Self.bounded(seconds: 20) {
                            try await observer(.passthrough)
                            try await Self.atStage(.passthrough) {
                                try await NativeAudioExport.passthrough(source.url, to: output, track: track, artwork: cover)
                            }
                            try await observer(.verify)
                            return try await Self.atStage(.verify) {
                                try await NativeAudioExport.verify(output, expected: inspection, track: track, artwork: cover)
                            }
                        }
                        preserved = true
                    } catch {
                        try Task.checkCancellation()
                        // The bounded scope drains its native session before a fallback can reuse this private path.
                        try? FileManager.default.removeItem(at: output)
                        Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")
                            .notice("event=export_passthrough_failed reason=\(((error as? AudioExportError) ?? .exportFailed).diagnostic, privacy: .public)")
                    }
                }
                if !preserved {
                    try await observer(.encode)
                    try await Self.atStage(.encode) {
                        try await NativeAudioExport.encode(source.url, to: output, track: track, artwork: cover)
                    }
                    try await observer(.verify)
                    embeddedCover = try await Self.atStage(.verify) {
                        try await NativeAudioExport.verify(output, expected: inspection, track: track, artwork: cover)
                    }
                }
                return (!preserved, embeddedCover)
            }
            try Task.checkCancellation()
            let bytes = Self.size(of: output)
            guard bytes > 0 else { throw AudioExportError.failed(stage: .publish, reason: .emptyFile) }
            try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: folder.path)
            try Task.checkCancellation()
            let result = AudioExport(url: output, bytes: bytes, tagged: true, codec: .aac,
                                     transcoded: transcoded, hasArtwork: embeddedCover != nil, lifetime: lifetime,
                                     artworkJPEG: embeddedCover)
            succeeded = true
            log.info("event=export outcome=ok codec=aac tagged=1 mode=\(transcoded ? "encode" : "passthrough", privacy: .public) artwork=\(artwork == nil ? 0 : 1) bytes=\(bytes)")
            return result
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            let outcome = cancelled ? "cancelled" : error as? AudioExportError == .timedOut ? "timeout" : "failed"
            let diagnostic = ((error as? AudioExportError) ?? .exportFailed).diagnostic
            log.error("event=export outcome=\(outcome, privacy: .public) reason=\(diagnostic, privacy: .public) bytes=0")
            if cancelled { throw CancellationError() }
            throw (error as? AudioExportError) ?? AudioExportError.exportFailed
        }
    }

    private static func atStage<Value: Sendable>(_ stage: AudioExportStage,
                                                 operation: () async throws -> Value) async throws -> Value {
        do { return try await operation() }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let exportError = error as? AudioExportError, case .failed(_, let reason) = exportError {
                throw AudioExportError.failed(stage: stage, reason: reason)
            }
            if error as? AudioExportError == .exportFailed { throw AudioExportError.failed(stage: stage, reason: .native) }
            throw (error as? AudioExportError) ?? .failed(stage: stage, reason: .native)
        }
    }

    // A structured scope waits for native cancellation before releasing source leases or deleting partial files.
    static func bounded<Value: Sendable>(seconds: TimeInterval,
                                        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds > 0 else { throw AudioExportError.timedOut }
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AudioExportError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw AudioExportError.exportFailed }
            try Task.checkCancellation()
            guard ContinuousClock.now < end else { throw AudioExportError.timedOut }
            return value
        }
    }

    static func pruneStaleExports(now: Date = Date(), directory: URL = AudioExporter.directory) {
        let removed = AudioExportLifetime.prune(directory: directory, before: now.addingTimeInterval(-staleAge))
        if removed > 0 {
            Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads").info("event=export_pruned count=\(removed)")
        }
    }

    static func fileName(artist: String, title: String) -> String {
        func clean(_ text: String) -> String {
            let scalars = text.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == ":" || scalar == "\\" || scalar.properties.generalCategory == .control { return " " }
                return Character(scalar)
            }
            return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var name = [clean(artist), clean(title)].filter { !$0.isEmpty }.joined(separator: " - ")
        if name.isEmpty { name = "Song" }
        if name.hasPrefix(".") { name = "_" + name.dropFirst() }
        name = String(name.prefix(maximumFileNameLength))
        // APFS limits a component by UTF-8 bytes; long multi-scalar titles must leave room for the extension.
        while name.utf8.count > 240 { name.removeLast() }
        if name.isEmpty { name = "Song" }
        return name.trimmingCharacters(in: .whitespaces)
    }

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

// Copies of AudioExport retain one lifetime; pruning cannot remove an in-flight export or a retained share result.
final class AudioExportLifetime: Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var directories: Set<String> = []
    }
    private static let registry = Registry()
    private let directory: String

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.path
        Self.registry.lock.withLock { _ = Self.registry.directories.insert(self.directory) }
    }

    deinit { Self.registry.lock.withLock { _ = Self.registry.directories.remove(directory) } }

    static func prune(directory: URL, before: Date) -> Int {
        registry.lock.withLock {
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
            guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
            var removed = 0
            for item in items {
                guard !registry.directories.contains(item.standardizedFileURL.path),
                      let values = try? item.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                      let date = values.contentModificationDate, date <= before else { continue }
                let owned = values.isDirectory == true ? UUID(uuidString: item.lastPathComponent) != nil
                    : ["m4a", "wav"].contains(item.pathExtension)
                if owned, (try? FileManager.default.removeItem(at: item)) != nil { removed += 1 }
            }
            return removed
        }
    }
}
