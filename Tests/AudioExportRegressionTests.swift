import AudioToolbox
import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import GanaBajana

@MainActor
final class AudioExportRegressionTests: XCTestCase {
    private static let track = Track(id: "export-r18", title: "रात • ਰਾਤ • 夜 🌙 e\u{301}",
                                     artists: ["Björk", "ਅਮਨ"], albumTitle: "Álbum / संगीत")

    func testNativePCM441And48kMonoStereoWithPartialFinalPacketPNGAndUnicode() async throws {
        let root = try directory()
        let png = Self.cover().pngData()!
        let expectedCover = try AudioExportArtwork.prepare(png)
        for rate in [44_100, 48_000] {
            for channels in [1, 2] {
                let source = try await Self.writePCM(root, rate: rate, channels: channels)
                let original = try Data(contentsOf: source)
                let result = try await AudioExporter(directory: root.appendingPathComponent(UUID().uuidString))
                    .export(track: Self.track, source: Self.cached(source), artwork: png)
                XCTAssertTrue(result.transcoded)
                XCTAssertEqual(result.artworkJPEG, expectedCover)
                try await Self.assertNativeReadback(result, duration: 3 + 137.0 / Double(rate),
                                                    rate: rate, channels: channels, cover: expectedCover)
                XCTAssertEqual(try Data(contentsOf: source), original)
            }
        }
    }

    func testNativeNonzeroPCMTimestampsKeepLeadingEmptyEditAndCompleteAudio() async throws {
        let root = try directory()
        let source = try await Self.writePCM(root, rate: 48_000, channels: 2, offset: 2.25)
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let segments = try await audio.load(.segments)
        let first = try XCTUnwrap(segments.first { !$0.isEmpty })
        XCTAssertEqual(first.timeMapping.target.start.seconds, 2.25, accuracy: 1.0 / 48_000)
        let inspection = try await NativeAudioExport.inspect(source)
        XCTAssertEqual(inspection.duration, 5.25 + 137.0 / 48_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(inspection.mediaDuration), 3 + 137.0 / 48_000, accuracy: 0.001)
        let result = try await AudioExporter(directory: root.appendingPathComponent("exports"))
            .export(track: Self.track, source: Self.cached(source), artwork: nil)
        XCTAssertTrue(result.transcoded)
        try await Self.assertNativeReadback(result, duration: inspection.duration, rate: 48_000, channels: 2,
                                            minimumMediaSeconds: 3)
    }

    func testNativeAACWriterTimelinePassesBothExportPaths() async throws {
        let root = try directory()
        let source = try await Self.writeAudio(root, rate: 44_100, channels: 1,
                                               offset: 2.25, sessionStart: 2.25, encodesAAC: true)
        let original = try Data(contentsOf: source)
        let expectedDuration = 3 + 137.0 / 44_100
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let segments = try await audio.load(.segments)
        let nonempty = segments.filter { !$0.isEmpty }
        let edit = try XCTUnwrap(nonempty.first)
        XCTAssertEqual(nonempty.count, 1, "Native AAC writer supplies one contiguous media edit")
        XCTAssertEqual(edit.timeMapping.target.start.seconds, 0, accuracy: 1.0 / 44_100)
        XCTAssertEqual(edit.timeMapping.target.duration.seconds, expectedDuration, accuracy: 0.001)
        let inspection = try await NativeAudioExport.inspect(source)
        XCTAssertTrue(inspection.isAAC)
        XCTAssertEqual(inspection.duration, expectedDuration, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(inspection.mediaDuration), expectedDuration, accuracy: 0.001)
        let jpeg = try AudioExportArtwork.jpeg(from: Self.cover())
        for forceEncode in [false, true] {
            let exporter = AudioExporter(directory: root.appendingPathComponent(UUID().uuidString), stageObserver: { stage in
                if forceEncode, stage == .passthrough { throw AudioExportError.exportFailed }
            })
            let result = try await exporter.export(track: Self.track, source: Self.cached(source), artwork: jpeg)
            XCTAssertEqual(result.transcoded, forceEncode, "The first pass must exercise actual AAC passthrough")
            try await Self.assertNativeReadback(result, duration: expectedDuration, rate: 44_100, channels: 1, cover: jpeg)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testInteriorEmptyEditsUseMappedPresentationTimesAndRequireEveryMediaInterval() throws {
        let rate: Int32 = 44_100
        let firstRange = CMTimeRange(start: CMTime(value: 33_075, timescale: rate), duration: CMTime(value: 44_100, timescale: rate))
        let secondRange = CMTimeRange(start: CMTime(value: 110_250, timescale: rate), duration: CMTime(value: 33_075, timescale: rate))
        let first = try Self.sample(frames: 44_100, rate: Int(rate), channels: 1, startFrame: 11_951)
        let second = try Self.sample(frames: 33_075, rate: Int(rate), channels: 1, startFrame: 66_150)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(first, newValue: firstRange.start), noErr)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(second, newValue: secondRange.start), noErr)
        var coverage = AudioExportPCM.Coverage(ranges: [firstRange, secondRange])
        try coverage.append(Self.marker(at: .zero, permanent: false))
        try coverage.append(first)
        try coverage.append(Self.marker(at: firstRange.end, permanent: false))
        try coverage.append(second)
        try coverage.append(Self.marker(at: secondRange.end, permanent: true))
        XCTAssertEqual(secondRange.end.seconds, 3.25, accuracy: 1e-12)
        XCTAssertEqual(coverage.seconds, 1.75, accuracy: 1e-12)
        try coverage.requireComplete(tolerance: 1.0 / Double(rate))
        var missing = AudioExportPCM.Coverage(ranges: [firstRange, secondRange])
        try missing.append(first)
        try missing.append(Self.marker(at: secondRange.end, permanent: true))
        XCTAssertThrowsError(try missing.requireComplete(tolerance: 0.15)) { error in
            XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .pcmDuration))
        }
    }

    func testPCMTrimMathDoesNotDoubleSubtractPrimingOrEndPadding() throws {
        let rate = 48_000
        let first = try Self.sample(frames: 1_024, rate: rate, channels: 2, startFrame: -211)
        Self.trim(first, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, frames: 211, rate: rate)
        let last = try Self.sample(frames: 1_024, rate: rate, channels: 2, startFrame: 813)
        Self.trim(last, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, frames: 137, rate: rate)
        let priming = try Self.sample(frames: 1_024, rate: rate, channels: 2, startFrame: -1_235)
        Self.trim(priming, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, frames: 1_024, rate: rate)
        let duration = CMTime(value: 1_700, timescale: 48_000)
        var coverage = AudioExportPCM.Coverage(ranges: [CMTimeRange(start: .zero, duration: duration)])
        try coverage.append(priming)
        try coverage.append(first)
        try coverage.append(last)
        try coverage.append(Self.marker(at: duration, permanent: true))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(first).seconds, 813.0 / 48_000, accuracy: 1e-12)
        XCTAssertEqual(coverage.seconds, 1_700.0 / 48_000, accuracy: 1e-12)
        try coverage.requireComplete(tolerance: 1.0 / 48_000)
    }

    func testPCMCoverageUsesPresentationIntervalsAndRejectsMissingOrDuplicateFrames() throws {
        let rate = 48_000
        let window = CMTimeRange(start: CMTime(value: 96_000, timescale: 48_000),
                                 duration: CMTime(value: 48_000, timescale: 48_000))
        var coverage = AudioExportPCM.Coverage(ranges: [window])
        try coverage.append(Self.marker(at: .zero, permanent: false))
        let sample = try Self.sample(frames: rate, rate: rate, channels: 1, startFrame: 96_000)
        try coverage.append(sample)
        XCTAssertEqual(coverage.seconds, 1, accuracy: 1e-12)
        try coverage.requireComplete(tolerance: 1.0 / 48_000)
        XCTAssertThrowsError(try coverage.append(sample)) { error in
            XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .pcmTiming))
        }
        var missing = AudioExportPCM.Coverage(ranges: [window])
        try missing.append(Self.sample(frames: 24_000, rate: rate, channels: 1, startFrame: 96_000))
        XCTAssertThrowsError(try missing.requireComplete(tolerance: 0.15)) { error in
            XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .pcmDuration))
        }
        var onlyMarkers = AudioExportPCM.Coverage(ranges: [window])
        try onlyMarkers.append(Self.marker(at: window.end, permanent: true))
        XCTAssertThrowsError(try onlyMarkers.requireComplete(tolerance: 0.15))
    }

    func testPCMPayloadAndInvalidTrimAreNotAcceptedAsEmptyMarkers() throws {
        let sample = try Self.sample(frames: 1_024, rate: 44_100, channels: 1, startFrame: 0)
        Self.trim(sample, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd, frames: 2_048, rate: 44_100)
        XCTAssertThrowsError(try AudioExportPCM.playableRange(sample)) { error in
            XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .pcmTiming))
        }
        let invalid = try Self.sample(frames: 128, rate: 48_000, channels: 1, startFrame: 0, includeData: false)
        XCTAssertThrowsError(try AudioExportPCM.playableRange(invalid)) { error in
            XCTAssertEqual(error as? AudioExportError, .failed(stage: .verify, reason: .pcmPayload))
        }
    }

    func testNativeOpusReadbackRetainsJPEGAndUnicode() async throws {
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Requires the supported native Opus runtime") }
        let root = try directory()
        let jpeg = try AudioExportArtwork.jpeg(from: Self.cover())
        for name in ["opus-160", "opus-256"] {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")
                ?? Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
            let source = root.appendingPathComponent(name + ".m4a")
            let original = try Data(contentsOf: fixture)
            try original.write(to: source)
            let result = try await AudioExporter(directory: root.appendingPathComponent(UUID().uuidString))
                .export(track: Self.track, source: Self.cached(source), artwork: jpeg)
            XCTAssertTrue(result.transcoded)
            try await Self.assertNativeReadback(result, duration: 8, rate: 48_000, channels: 2, cover: jpeg)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testShareSourceUsesVerifiedEmbeddedJPEGAndKeepsM4AAsTheOnlySharedItem() async throws {
        let root = try directory()
        let source = try await Self.writePCM(root, rate: 48_000, channels: 2)
        let result = try await AudioExporter(directory: root.appendingPathComponent("exports"))
            .export(track: Self.track, source: Self.cached(source), artwork: Self.cover().pngData())
        let items = try await AVURLAsset(url: result.url).load(.metadata)
        let cover = try XCTUnwrap(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first)
        let embeddedData = try await cover.load(.dataValue)
        let embedded = try XCTUnwrap(embeddedData)
        let sourceItem = AudioExportShareSource(export: result, title: Self.track.title)
        let controller = UIActivityViewController(activityItems: [sourceItem], applicationActivities: nil)
        XCTAssertEqual(sourceItem.activityViewControllerPlaceholderItem(controller) as? URL, result.url)
        XCTAssertEqual(sourceItem.activityViewController(controller, itemForActivityType: .mail) as? URL, result.url)
        XCTAssertEqual(sourceItem.activityViewController(controller, dataTypeIdentifierForActivityType: .mail), UTType.mpeg4Audio.identifier)
        XCTAssertEqual(sourceItem.export.artworkJPEG, embedded)
        XCTAssertEqual(sourceItem.previewImage?.pngData(), UIImage(data: embedded)?.pngData())
        let metadata = try XCTUnwrap(sourceItem.activityViewControllerLinkMetadata(controller))
        let provider = try XCTUnwrap(metadata.imageProvider)
        let previewData: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? AudioExportError.invalidArtwork) }
            }
        }
        XCTAssertEqual(previewData, embedded)
        XCTAssertEqual(metadata.title, Self.track.title)
        let background = try await Self.backgroundShareCallbacks(sourceItem, controller: controller)
        XCTAssertFalse(background.wasMainThread)
        XCTAssertEqual(background.placeholderURL, result.url)
        XCTAssertEqual(background.itemURL, result.url)
        XCTAssertEqual(background.dataType, UTType.mpeg4Audio.identifier)
        XCTAssertEqual(background.title, Self.track.title)
        XCTAssertEqual(background.metadataURL, result.url)
        XCTAssertEqual(background.thumbnailPNG, UIImage(data: embedded)?.pngData())
        XCTAssertEqual(background.previewJPEG, embedded)
        XCTAssertTrue(background.hasIcon)
        AudioExporter.pruneStaleExports(now: Date().addingTimeInterval(7_200), directory: root.appendingPathComponent("exports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceItem.export.url.path))
    }

    func testKnownCoverFailureIsVisibleRetryableAndUnknownCoverMakesNoRequests() async throws {
        let png = Self.cover().pngData()!
        let counter = CatalogTestCounter()
        let mock = CatalogMockSession { _ in
            counter.increment() == 1 ? CatalogStub(status: 404, data: Data())
                : CatalogStub(headers: ["Content-Type": "image/png"], data: png)
        }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock { _ = await loader.clearCache(); mock.close() }
        var track = Self.track
        let absent = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
        XCTAssertNil(absent)
        XCTAssertEqual(mock.state.requests.count, 0)
        track.artworkURL = URL(string: "https://export-artwork.invalid/cover.png")!
        do {
            _ = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
            XCTFail("A known cover URL failing must not become a coverless success")
        } catch { XCTAssertEqual(error as? AudioExportError, .artworkUnavailable) }
        let recovered = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
        XCTAssertTrue(recovered.map(AudioExportArtwork.isValid) ?? false)
        XCTAssertEqual(mock.state.requests.count, 2)
        let cached = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
        XCTAssertEqual(cached, recovered)
        XCTAssertEqual(mock.state.requests.count, 2)
    }

    func testExporterRejectsSilentlyDroppedKnownCoverBeforePublishing() async throws {
        let root = try directory()
        let source = try await Self.writePCM(root, rate: 48_000, channels: 1)
        var track = Self.track
        track.artworkURL = URL(string: "https://export-artwork.invalid/known.png")!
        let exports = root.appendingPathComponent("exports")
        do {
            _ = try await AudioExporter(directory: exports).export(track: track, source: Self.cached(source), artwork: nil)
            XCTFail("A caller must not turn a failed known-cover lookup into a coverless export")
        } catch { XCTAssertEqual(error as? AudioExportError, .artworkUnavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testSizedYouTubeCoverFallsBackThroughExistingLoaderCandidates() async throws {
        let png = Self.cover().pngData()!
        let mock = CatalogMockSession { request in
            request.url?.lastPathComponent == "hqdefault.jpg"
                ? CatalogStub(headers: ["Content-Type": "image/png"], data: png)
                : CatalogStub(status: 404, data: Data())
        }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock { _ = await loader.clearCache(); mock.close() }
        var track = Self.track
        track.artworkURL = URL(string: "https://i.ytimg.com/vi/fixture1234/maxresdefault.jpg")!
        let cover = try await AudioExportArtworkResolver.resolve(for: track, loader: loader)
        XCTAssertTrue(cover.map(AudioExportArtwork.isValid) ?? false)
        XCTAssertEqual(mock.state.requests.compactMap { $0.url?.lastPathComponent },
                       ["maxresdefault.jpg", "sddefault.jpg", "hqdefault.jpg"])
    }

    func testSizedGoogleCoverRetriesSmallerImageAndCancellationMakesNoRequest() async throws {
        let png = Self.cover().pngData()!
        let mock = CatalogMockSession { request in
            request.url?.absoluteString.contains("=w544-h544") == true
                ? CatalogStub(headers: ["Content-Type": "image/png"], data: png)
                : CatalogStub(status: 404, data: Data())
        }
        let loader = ArtworkLoader(session: mock.session)
        addTeardownBlock { _ = await loader.clearCache(); mock.close() }
        var track = Self.track
        track.artworkURL = URL(string: "https://lh3.googleusercontent.com/fixture=w60-h60-l90-rj")!
        let suppliedTrack = track
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AudioExportArtworkResolver.resolve(for: suppliedTrack, loader: loader)
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation must remain cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(mock.state.requests.isEmpty)
        let data = try await AudioExportArtworkResolver.resolve(for: suppliedTrack, loader: loader)
        XCTAssertTrue(data.map(AudioExportArtwork.isValid) ?? false)
        XCTAssertEqual(mock.state.requests.count, 2)
        XCTAssertTrue(mock.state.requests[0].url?.absoluteString.contains("=w1080-h1080") == true)
        XCTAssertTrue(mock.state.requests[1].url?.absoluteString.contains("=w544-h544") == true)
    }

    func testWrongCoverAndMissingCoverFailWithBoundedReasons() async throws {
        let root = try directory()
        let source = try await Self.writePCM(root, rate: 48_000, channels: 1)
        let first = try AudioExportArtwork.jpeg(from: Self.cover())
        let other = try AudioExportArtwork.jpeg(from: Self.cover(alternate: true))
        let inspection = try await NativeAudioExport.inspect(source)
        for supplied in [nil, first] as [Data?] {
            let result = try await AudioExporter(directory: root.appendingPathComponent(UUID().uuidString))
                .export(track: Self.track, source: Self.cached(source), artwork: supplied)
            do {
                try await NativeAudioExport.verify(result.url, expected: inspection, track: Self.track, artwork: other)
                XCTFail("Missing or wrong image must not pass just because it decodes")
            } catch {
                XCTAssertEqual(error as? AudioExportError,
                               .failed(stage: .verify, reason: supplied == nil ? .coverMissing : .coverMismatch))
            }
            if supplied == nil {
                XCTAssertFalse(result.hasArtwork)
                let share = AudioExportShareSource(export: result, title: Self.track.title)
                XCTAssertNil(share.previewImage)
                let controller = UIActivityViewController(activityItems: [share], applicationActivities: nil)
                XCTAssertNil(share.activityViewControllerLinkMetadata(controller)?.imageProvider)
                let background = try await Self.backgroundShareCallbacks(share, controller: controller)
                XCTAssertFalse(background.wasMainThread)
                XCTAssertEqual(background.placeholderURL, result.url)
                XCTAssertEqual(background.itemURL, result.url)
                XCTAssertEqual(background.dataType, UTType.mpeg4Audio.identifier)
                XCTAssertNil(background.thumbnailPNG)
                XCTAssertNil(background.previewJPEG)
                XCTAssertFalse(background.hasIcon)
            }
        }
        for reason in AudioExportFailureReason.allCases {
            let error = AudioExportError.failed(stage: .verify, reason: reason)
            XCTAssertLessThan(error.diagnostic.count, 40)
            XCTAssertFalse(error.localizedDescription.contains(Self.track.title))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }
    }

    private struct ShareCallbackSnapshot: Sendable {
        let wasMainThread: Bool
        let placeholderURL: URL?
        let itemURL: URL?
        let dataType: String?
        let title: String?
        let metadataURL: URL?
        let thumbnailPNG: Data?
        let hasIcon: Bool
        var previewJPEG: Data?
    }

    private static func backgroundShareCallbacks(_ source: AudioExportShareSource,
                                                  controller: UIActivityViewController) async throws -> ShareCallbackSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "AudioExportRegressionTests.shareCallbacks").async {
                // The protocol existential exercises Objective-C witnesses, where the isolation trap occurred.
                let itemSource: any UIActivityItemSource = source
                let placeholder = itemSource.activityViewControllerPlaceholderItem(controller) as? URL
                let item = itemSource.activityViewController(controller, itemForActivityType: .mail) as? URL
                let type = itemSource.activityViewController?(controller, dataTypeIdentifierForActivityType: .mail)
                let thumbnail = itemSource.activityViewController?(controller, thumbnailImageForActivityType: .mail,
                                                                   suggestedSize: CGSize(width: 96, height: 96))
                let metadata = itemSource.activityViewControllerLinkMetadata?(controller)
                let snapshot = ShareCallbackSnapshot(wasMainThread: Thread.isMainThread, placeholderURL: placeholder,
                    itemURL: item, dataType: type, title: metadata?.title, metadataURL: metadata?.url,
                    thumbnailPNG: thumbnail?.pngData(), hasIcon: metadata?.iconProvider != nil, previewJPEG: nil)
                guard let provider = metadata?.imageProvider else {
                    continuation.resume(returning: snapshot)
                    return
                }
                provider.loadDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { data, error in
                    guard let data else {
                        continuation.resume(throwing: error ?? AudioExportError.invalidArtwork)
                        return
                    }
                    var completed = snapshot
                    completed.previewJPEG = data
                    continuation.resume(returning: completed)
                }
            }
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioExportR18-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static func cached(_ url: URL) -> CachedAudio {
        CachedAudio(trackID: track.id, url: url, duration: 999, loudnessDb: nil, viewCount: nil,
                    bytes: AudioExporter.size(of: url), storedAt: Date(), quality: nil, isDownloaded: true)
    }

    private static func cover(alternate: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 960, height: 640), format: format).image { context in
            (alternate ? UIColor.orange : UIColor.systemTeal).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 137, y: 63, width: 411, height: 279))
        }
    }

    private static func trim(_ sample: CMSampleBuffer, key: CFString, frames: Int64, rate: Int) {
        CMSetAttachment(sample, key: key,
                        value: CMTimeCopyAsDictionary(CMTime(value: frames, timescale: Int32(rate)), allocator: kCFAllocatorDefault)!,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }

    private static func marker(at time: CMTime, permanent: Bool) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .zero, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &result)
        XCTAssertEqual(status, noErr)
        let sample = try XCTUnwrap(result)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia, value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        if permanent {
            CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_PermanentEmptyMedia,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return sample
    }

    private static func sample(frames: Int, rate: Int, channels: Int, startFrame: Int64,
                               includeData: Bool = true) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        if includeData {
            let values = (0..<(frames * channels)).map { index -> Int16 in
                let frame = Double(startFrame) + Double(index / channels)
                let frequency = index % channels == 0 ? 440.0 : 659.25
                return Int16(sin(frame * frequency * 2 * .pi / Double(rate)) * 12_000)
            }
            let bytes = values.count * MemoryLayout<Int16>.size
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
            let buffer = try XCTUnwrap(block)
            XCTAssertEqual(values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                blockBuffer: buffer, offsetIntoDestination: 0, dataLength: bytes) }, kCMBlockBufferNoErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(value: startFrame, timescale: Int32(rate)), decodeTimeStamp: .invalid)
        var frameBytes = channels * 2
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &frameBytes, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private static func writePCM(_ root: URL, rate: Int, channels: Int, offset: Double = 0) async throws -> URL {
        try await writeAudio(root, rate: rate, channels: channels, offset: offset)
    }

    private static func writeAudio(_ root: URL, rate: Int, channels: Int, offset: Double = 0,
                                    sessionStart: Double = 0, encodesAAC: Bool = false) async throws -> URL {
        let url = root.appendingPathComponent("\(UUID()).\(encodesAAC ? "m4a" : "mov")")
        let writer = try AVAssetWriter(outputURL: url, fileType: encodesAAC ? .m4a : .mov)
        let settings: [String: Any] = encodesAAC ? [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AudioExportError.exportFailed }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        // Session origin maps input PTS to movie time; a zero origin deliberately retains the leading empty edit.
        writer.startSession(atSourceTime: CMTime(seconds: sessionStart, preferredTimescale: Int32(rate)))
        let frames = rate * 3 + 137
        let origin = Int64(offset * Double(rate))
        var written = 0
        while written < frames {
            let sample = try sample(frames: min(4_093, frames - written), rate: rate, channels: channels,
                                    startFrame: origin + Int64(written))
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? AudioExportError.timedOut
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.append(sample) else { throw writer.error ?? AudioExportError.exportFailed }
            written += CMSampleBufferGetNumSamples(sample)
        }
        writer.endSession(atSourceTime: CMTime(value: origin + Int64(frames), timescale: Int32(rate)))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private static func assertNativeReadback(_ result: AudioExport, duration: Double, rate: Int, channels: Int,
                                             cover: Data? = nil, minimumMediaSeconds: Double? = nil) async throws {
        XCTAssertTrue(result.tagged)
        XCTAssertEqual(result.codec, .aac)
        let asset = AVURLAsset(url: result.url)
        let actualDuration = try await asset.load(.duration).seconds
        XCTAssertEqual(actualDuration, duration, accuracy: 0.02)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        for description in try await audio.load(.formatDescriptions) {
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
            XCTAssertEqual(format.mFormatID, kAudioFormatMPEG4AAC)
            XCTAssertEqual(format.mSampleRate, Double(rate))
            XCTAssertEqual(format.mChannelsPerFrame, UInt32(channels))
        }
        let items = try await asset.load(.metadata)
        for (identifier, value) in [(AVMetadataIdentifier.iTunesMetadataSongName, track.title),
                                    (.iTunesMetadataArtist, track.artistName), (.iTunesMetadataAlbum, track.albumTitle!)] {
            let item = try XCTUnwrap(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first)
            let actual = try await item.load(.stringValue)
            XCTAssertEqual(actual, value)
        }
        if let cover {
            let item = try XCTUnwrap(AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataCoverArt).first)
            let coverData = try await item.load(.dataValue)
            let data = try XCTUnwrap(coverData)
            XCTAssertEqual(item.dataType, kCMMetadataBaseDataType_JPEG as String)
            XCTAssertEqual(data, cover)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(image) as String?, UTType.jpeg.identifier)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual(result.artworkJPEG, data)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioExportError.exportFailed }
        defer { reader.cancelReading() }
        var frames = 0
        var tailPeak = 0
        while let sample = output.copyNextSampleBuffer() {
            let count = CMSampleBufferGetNumSamples(sample)
            if count == 0 { XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sample), 0); continue }
            frames += count
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let size = CMBlockBufferGetDataLength(block)
            XCTAssertEqual(size, count * channels * 2)
            if CMSampleBufferGetPresentationTimeStamp(sample).seconds > duration - 0.25 {
                var values = [Int16](repeating: 0, count: size / 2)
                XCTAssertEqual(values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,
                    atOffset: 0, dataLength: size, destination: $0.baseAddress!) }, noErr)
                tailPeak = max(tailPeak, values.map { abs(Int($0)) }.max() ?? 0)
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(Double(frames) / Double(rate), (minimumMediaSeconds ?? duration) - 0.02)
        XCTAssertGreaterThan(tailPeak, 1_000, "The tail must contain the generated tone, not merely container padding")
    }
}
