import AudioToolbox
import AVFoundation
import Foundation

enum NativeAudioExport {
    struct Inspection: Sendable {
        let duration: TimeInterval
        let isAAC: Bool
        var mediaDuration: TimeInterval? = nil
    }

    static func inspect(_ url: URL) async throws -> Inspection {
        let asset = try makeAsset(url)
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard audio.count == 1, video.isEmpty,
                  let duration = PlaybackTiming.validDuration(try await asset.load(.duration).seconds) else {
                throw AudioExportError.unsupportedAudio
            }
            let descriptions = try await audio[0].load(.formatDescriptions)
            guard !descriptions.isEmpty else { throw AudioExportError.unsupportedAudio }
            var isAAC = true
            for description in descriptions {
                guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      format.mSampleRate.isFinite, (8_000...192_000).contains(format.mSampleRate),
                      (1...2).contains(format.mChannelsPerFrame) else { throw AudioExportError.unsupportedAudio }
                isAAC = isAAC && format.mFormatID == kAudioFormatMPEG4AAC
            }
            try Task.checkCancellation()
            let assetDuration = try await asset.load(.duration)
            let ranges = try await AudioExportPCM.mediaRanges(for: audio[0], duration: assetDuration)
            return Inspection(duration: duration, isAAC: isAAC, mediaDuration: ranges.reduce(0) { $0 + $1.duration.seconds })
        } onCancel: { asset.cancelLoading() }
    }

    static func passthrough(_ input: URL, to output: URL, track: Track, artwork: Data?) async throws {
        let asset = try makeAsset(input)
        defer { asset.cancelLoading() }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioExportError.exportFailed
        }
        let cancellation = SessionCancellation(session)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            session.metadata = metadata(for: track, artwork: artwork)
            try await session.export(to: output, as: .m4a)
            try Task.checkCancellation()
        } onCancel: {
            cancellation.cancel()
            asset.cancelLoading()
        }
    }

    static func encode(_ input: URL, to output: URL, track: Track, artwork: Data?) async throws {
        let asset = try makeAsset(input)
        defer { asset.cancelLoading() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  let description = try await audio.load(.formatDescriptions).first,
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw AudioExportError.unsupportedAudio
            }
            let rate: Double = format.mSampleRate == 44_100 ? 44_100 : 48_000
            let duration = try await asset.load(.duration)
            let channels = Int(format.mChannelsPerFrame)
            guard (1...2).contains(channels) else { throw AudioExportError.unsupportedAudio }
            let reader = try AVAssetReader(asset: asset)
            let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
            let cancellation = ReaderWriterCancellation(reader: reader, writer: writer)
            defer { cancellation.cancel() }
            try await withTaskCancellationHandler {
                let decoded = AVAssetReaderTrackOutput(track: audio, outputSettings: pcmSettings)
                decoded.alwaysCopiesSampleData = false
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000]
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw AudioExportError.unsupportedAudio }
                let encoded = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                encoded.expectsMediaDataInRealTime = false
                try cancellation.whileActive {
                    guard reader.canAdd(decoded), writer.canAdd(encoded) else { throw AudioExportError.unsupportedAudio }
                    reader.add(decoded)
                    writer.add(encoded)
                    writer.metadata = metadata(for: track, artwork: artwork)
                    try Task.checkCancellation()
                    guard reader.startReading(), writer.startWriting() else { throw AudioExportError.unsupportedAudio }
                }
                var started = false
                var frames: Int64 = 0
                var buffers = 0
                while true {
                    try Task.checkCancellation()
                    guard let sample = try cancellation.whileActive({
                        autoreleasepool { decoded.copyNextSampleBuffer() }
                    }) else { break }
                    let count = CMSampleBufferGetNumSamples(sample)
                    if try AudioExportPCM.isMarker(sample) { continue }
                    _ = try AudioExportPCM.playableRange(sample)
                    if !started {
                        // Preserve the asset timeline, including leading empty edits, rather than shifting to the first PCM PTS.
                        try cancellation.whileActive { writer.startSession(atSourceTime: .zero) }
                        started = true
                    }
                    while !encoded.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writer.status == .writing else { throw AudioExportError.exportFailed }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    try Task.checkCancellation()
                    guard try cancellation.whileActive({ encoded.append(sample) }) else { throw AudioExportError.exportFailed }
                    frames += Int64(count)
                    buffers += 1
                    if buffers.isMultiple(of: 32) { await Task.yield() }
                }
                guard reader.status == .completed, started, frames > 0 else { throw AudioExportError.unsupportedAudio }
                try cancellation.whileActive {
                    writer.endSession(atSourceTime: duration)
                    encoded.markAsFinished()
                }
                try await cancellation.finishWriting()
                try Task.checkCancellation()
                guard writer.status == .completed else { throw AudioExportError.exportFailed }
            } onCancel: { cancellation.cancel() }
        } onCancel: { asset.cancelLoading() }
    }

    @discardableResult
    static func verify(_ url: URL, expected: Inspection, track: Track, artwork: Data?) async throws -> Data? {
        guard AudioExporter.size(of: url) > 0 else { throw AudioExportError.failed(stage: .verify, reason: .emptyFile) }
        let inspected: Inspection
        do { inspected = try await inspect(url) }
        catch {
            try Task.checkCancellation()
            throw AudioExportError.failed(stage: .verify, reason: .outputFormat)
        }
        let tolerance = max(0.15, min(1, expected.duration * 0.01))
        guard inspected.isAAC else { throw AudioExportError.failed(stage: .verify, reason: .outputFormat) }
        guard inspected.duration >= expected.duration * 0.8,
              abs(inspected.duration - expected.duration) <= tolerance else {
            throw AudioExportError.failed(stage: .verify, reason: .duration)
        }
        if let expectedMedia = expected.mediaDuration, let actualMedia = inspected.mediaDuration,
           actualMedia + tolerance < expectedMedia || actualMedia < expectedMedia * 0.8 {
            throw AudioExportError.failed(stage: .verify, reason: .pcmDuration)
        }
        let asset = try makeAsset(url)
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let items = try await asset.load(.metadata)
            try await requireString(track.title, identifier: .iTunesMetadataSongName, items: items, reason: .title)
            try await requireString(track.artistName, identifier: .iTunesMetadataArtist, items: items, reason: .artist)
            if let album = track.albumTitle, !album.isEmpty {
                try await requireString(album, identifier: .iTunesMetadataAlbum, items: items, reason: .album)
            }
            var embeddedCover: Data?
            if let artwork {
                guard let cover = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first,
                      let data = try await cover.load(.dataValue) else {
                    throw AudioExportError.failed(stage: .verify, reason: .coverMissing)
                }
                guard cover.dataType == kCMMetadataBaseDataType_JPEG as String, AudioExportArtwork.isValid(data) else {
                    throw AudioExportError.failed(stage: .verify, reason: .coverType)
                }
                guard data == artwork else { throw AudioExportError.failed(stage: .verify, reason: .coverMismatch) }
                embeddedCover = data
            }
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioExportError.failed(stage: .verify, reason: .outputFormat)
            }
            let assetDuration = try await asset.load(.duration)
            let ranges = try await AudioExportPCM.mediaRanges(for: audio, duration: assetDuration)
            let reader = try AVAssetReader(asset: asset)
            let cancellation = ReaderWriterCancellation(reader: reader)
            defer { cancellation.cancel() }
            try await withTaskCancellationHandler {
                let output = AVAssetReaderTrackOutput(track: audio, outputSettings: pcmSettings)
                output.alwaysCopiesSampleData = false
                try cancellation.whileActive {
                    guard reader.canAdd(output) else { throw AudioExportError.failed(stage: .verify, reason: .decoderStart) }
                    reader.add(output)
                    try Task.checkCancellation()
                    guard reader.startReading() else { throw AudioExportError.failed(stage: .verify, reason: .decoderStart) }
                }
                var coverage = AudioExportPCM.Coverage(ranges: ranges)
                var buffers = 0
                while true {
                    try Task.checkCancellation()
                    let read = try autoreleasepool {
                        guard let sample = try cancellation.whileActive({ output.copyNextSampleBuffer() }) else { return false }
                        try coverage.append(sample)
                        return true
                    }
                    guard read else { break }
                    buffers += 1
                    if buffers.isMultiple(of: 32) { await Task.yield() }
                }
                guard reader.status == .completed else { throw AudioExportError.failed(stage: .verify, reason: .decoderRead) }
                try coverage.requireComplete(tolerance: tolerance)
                try Task.checkCancellation()
            } onCancel: { cancellation.cancel() }
            return embeddedCover
        } onCancel: { asset.cancelLoading() }
    }

    private static func makeAsset(_ url: URL) throws -> AVURLAsset {
        try Task.checkCancellation()
        guard url.isFileURL else { throw AudioExportError.noLocalCopy }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        try Task.checkCancellation()
        var options: [String: Any] = [:]
        // AVFoundation can select its parser by extension before loading tracks; container bytes must override that hint.
        if AudioDownloader.looksLikeMedia(prefix, fileExtension: "wav") {
            options[AVURLAssetOverrideMIMETypeKey] = "audio/vnd.wave"
        } else if AudioDownloader.looksLikeMedia(prefix, fileExtension: "m4a") {
            options[AVURLAssetOverrideMIMETypeKey] = "audio/mp4"
        }
        return AVURLAsset(url: url, options: options)
    }

    private static var pcmSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }

    private static func requireString(_ expected: String, identifier: AVMetadataIdentifier, items: [AVMetadataItem],
                                      reason: AudioExportFailureReason) async throws {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              try await item.load(.stringValue) == expected else { throw AudioExportError.failed(stage: .verify, reason: reason) }
    }

    private static func metadata(for track: Track, artwork: Data?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, dataType: String? = nil) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.dataType = dataType
            items.append(item)
        }
        add(.iTunesMetadataSongName, track.title as NSString, dataType: kCMMetadataBaseDataType_UTF8 as String)
        add(.iTunesMetadataArtist, track.artistName as NSString, dataType: kCMMetadataBaseDataType_UTF8 as String)
        if let album = track.albumTitle, !album.isEmpty {
            add(.iTunesMetadataAlbum, album as NSString, dataType: kCMMetadataBaseDataType_UTF8 as String)
        }
        if let artwork { add(.iTunesMetadataCoverArt, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String) }
        return items
    }
}

// AVFoundation forbids cancellation concurrent with sample reads/appends; the lock also fences setup after cancellation.
private final class ReaderWriterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let reader: AVAssetReader
    let writer: AVAssetWriter?
    init(reader: AVAssetReader, writer: AVAssetWriter? = nil) { self.reader = reader; self.writer = writer }

    func whileActive<Value>(_ body: () throws -> Value) throws -> Value {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            return try body()
        }
    }

    func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try whileActive {
                    guard let writer else { throw AudioExportError.exportFailed }
                    writer.finishWriting { continuation.resume() }
                }
            } catch { continuation.resume(throwing: error) }
        }
    }

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            reader.cancelReading()
            if let writer, writer.status == .writing { writer.cancelWriting() }
        }
    }
}

private final class SessionCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}
