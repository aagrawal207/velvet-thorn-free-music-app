import AudioToolbox
import AVFoundation
import CryptoKit
import XCTest
@testable import GanaBajana

@MainActor
final class FFmpegMetadataLimitTests: XCTestCase {
    func test300000TagsCompleteWithinBudgetAndPreserveCompressedPackets() async throws {
        try requireNativeTests()
        let seed = try Data(contentsOf: fixture("opus-160", fileExtension: "webm"))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for placement in [MetadataWebMFixture.Placement.beforeMedia, .seekHeadToTrailingMetadata] {
            let data = try await Task.detached {
                try MetadataWebMFixture.make(seed: seed, kind: .tags, count: 300_000,
                    placement: placement, unknownContainers: placement == .seekHeadToTrailingMetadata)
            }.value
            XCTAssertLessThan(Int64(data.count), AudioCache.maximumFileBytes)
            let input = directory.appendingPathComponent("tags-\(placement).webm")
            let output = directory.appendingPathComponent("tags-\(placement).m4a")
            try data.write(to: input)

            try await remuxWithinBudget(input: input, output: output)
            try await assertOriginalPackets(output)
            let inspection = try await OpusNativeAudio.inspect(output)
            XCTAssertEqual(inspection.sampleRate, 48_000)
            XCTAssertEqual(inspection.channels, 2)
            XCTAssertEqual(inspection.duration, 8, accuracy: 0.1)
            XCTAssertGreaterThan(inspection.decodedFrames, 0)
            XCTAssertLessThan(try Data(contentsOf: output).count, data.count / 2)
        }
    }

    func testLargeChaptersAndAttachmentsCompleteWithinBudget() async throws {
        try requireNativeTests()
        let seed = try Data(contentsOf: fixture("opus-160", fileExtension: "webm"))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in [MetadataWebMFixture.Kind.chapters, .attachments] {
            let data = try await Task.detached {
                try MetadataWebMFixture.make(seed: seed, kind: kind, count: 100_000)
            }.value
            XCTAssertLessThan(Int64(data.count), AudioCache.maximumFileBytes)
            let input = directory.appendingPathComponent("\(kind).webm")
            let output = directory.appendingPathComponent("\(kind).m4a")
            try data.write(to: input)

            try await remuxWithinBudget(input: input, output: output)
            try await assertOriginalPackets(output)
            let inspection = try await OpusNativeAudio.inspect(output)
            XCTAssertGreaterThan(inspection.decodedFrames, 0)
        }
    }

    func testMalformedSkippedMetadataFailsPromptlyAndNextRemuxDrains() async throws {
        try requireNativeTests()
        let seedURL = try fixture("opus-160", fileExtension: "webm")
        let seed = try Data(contentsOf: seedURL)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for length in [MetadataWebMFixture.Length.pastFileEnd, .unknown] {
            let input = directory.appendingPathComponent("invalid-\(length).webm")
            let output = directory.appendingPathComponent("invalid-\(length).m4a")
            let data = try MetadataWebMFixture.make(seed: seed, kind: .tags, count: 32,
                unknownContainers: true, metadataLength: length)
            XCTAssertLessThan(Int64(data.count), AudioCache.maximumFileBytes)
            try data.write(to: input)

            do {
                try await remuxWithinBudget(input: input, output: output)
                XCTFail("An unskippable metadata extent must fail, not publish a partial file")
            } catch {
                // The outer watchdog timing out is a liveness failure, not acceptable rejection.
                guard case OpusPreparationError.remux = error else {
                    return XCTFail("Expected a native remux error, got \(type(of: error))")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let next = directory.appendingPathComponent("after-\(length).m4a")
            try await remuxWithinBudget(input: seedURL, output: next)
            try await assertOriginalPackets(next)
        }
    }

    func testCancelledHighTagRemuxReleasesWorkerBeforeNextFile() async throws {
        try requireNativeTests()
        let seedURL = try fixture("opus-160", fileExtension: "webm")
        let seed = try Data(contentsOf: seedURL)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try await Task.detached {
            try MetadataWebMFixture.make(seed: seed, kind: .tags, count: 300_000)
        }.value
        let input = directory.appendingPathComponent("cancel.webm")
        let output = directory.appendingPathComponent("cancel.m4a")
        try data.write(to: input)
        let work = Task {
            try await OpusRemuxer.remux(input: input, output: output)
        }
        defer { work.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        work.cancel()
        do {
            try await PlaybackDeadline.run(seconds: 4) { try await work.value }
            // Completion can race cancellation; neither outcome may strand the serialized worker.
            try await assertOriginalPackets(output)
        } catch {
            XCTAssertTrue(error is CancellationError, "A watchdog timeout means the native worker did not unwind")
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let next = directory.appendingPathComponent("after-cancel.m4a")
        try await remuxWithinBudget(input: seedURL, output: next)
        try await assertOriginalPackets(next)
    }

    func testExpiredHighTagPreparationCancelsDrainsAndNeverPublishes() async throws {
        try requireNativeTests()
        let seedURL = try fixture("opus-160", fileExtension: "webm")
        let seed = try Data(contentsOf: seedURL)
        let data = try await Task.detached {
            try MetadataWebMFixture.make(seed: seed, kind: .tags, count: 300_000,
                placement: .seekHeadToTrailingMetadata, unknownContainers: true)
        }.value
        let validation = AppModelRequestGate<URL, Void>()
        let fixture = try CacheManagementFixture(handler: { _ in
            CatalogStub(headers: ["Content-Type": "audio/webm", "Content-Length": "\(data.count)"], data: data)
        }, opusPreparation: { input, output in
            let inspected = try await OpusNativeAudio.prepare(input: input, output: output)
            // Real FFmpeg and PCM work must finish before this controlled, late validation response.
            try await validation.receive(output)
            return inspected
        })
        addTeardownBlock {
            await validation.close()
            try await PlaybackDeadline.run(seconds: 5) { try await fixture.close() }
        }
        let cache = fixture.cache
        let id = OpusTestSupport.track.id
        let original = try fixture.seed(id, seconds: 8)
        let originalBytes = try Data(contentsOf: original)
        await cache.pin(id)
        let permit = try await cache.writePermit()
        let work = Task {
            try await cache.storeOpus(trackID: id, stream: OpusTestSupport.source(), permit: permit, foreground: true)
        }
        defer { work.cancel() }

        try await PlaybackTestSupport.eventually(timeout: 15) { await validation.requests.count == 1 }
        let response = try await validation.request(at: 0)
        try await assertOriginalPackets(response.input)
        let before = try await cache.storageUsage()
        XCTAssertEqual(before.pendingDownloads, 1)
        XCTAssertEqual(before.songCount, 1)

        do {
            _ = try await PlaybackDeadline.run(seconds: 0.05) { try await work.value }
            XCTFail("The deliberately withheld validation must cross the caller deadline")
        } catch {
            guard case PlaybackStreamError.timedOut = error else {
                return XCTFail("Expected the caller deadline")
            }
        }
        work.cancel()
        try await PlaybackTestSupport.eventually { await validation.cancellations.contains(response.id) }
        let finished = CatalogTestRecorder<Bool>()
        let clear = Task {
            let usage = try await cache.clearUnused()
            finished.record(true)
            return usage
        }
        defer { clear.cancel() }
        try await PlaybackTestSupport.eventually { (try? await cache.writePermit()) == nil }
        XCTAssertTrue(finished.values.isEmpty, "Maintenance must drain the actual writer before returning")
        try await validation.complete(response, with: .success(()))

        let cleared = try await PlaybackDeadline.run(seconds: 4) { try await clear.value }
        do {
            _ = try await PlaybackDeadline.run(seconds: 2) { try await work.value }
            XCTFail("A result arriving after cancellation must not publish")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cleared.pendingDownloads, 0)
        XCTAssertEqual(cleared.songCount, 1)
        XCTAssertEqual(cleared.bytes, Int64(originalBytes.count))
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let entry = await cache.entry(for: id)
        XCTAssertEqual(entry?.url, original)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        XCTAssertFalse(files.contains { $0.contains(".opus-") || $0.hasSuffix(".part") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: response.input.path))

        let next = fixture.root.appendingPathComponent("after-deadline.m4a")
        try await remuxWithinBudget(input: seedURL, output: next)
        try await assertOriginalPackets(next)
    }

    private func remuxWithinBudget(input: URL, output: URL) async throws {
        // A Swift race alone can return while C is stuck; success and the following queued work are required.
        try await PlaybackDeadline.run(seconds: 4) {
            try await OpusRemuxer.remux(input: input, output: output, timeout: 2)
        }
    }

    private func assertOriginalPackets(_ output: URL) async throws {
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture("OpusFixtures", fileExtension: "json"))) as? [String: Any])
        let entries = try XCTUnwrap(manifest["fixtures"] as? [[String: Any]])
        let expected = try XCTUnwrap(entries.first { $0["name"] as? String == "opus-160" })
        let expectedHash = try XCTUnwrap(expected["packetSHA256"] as? String)
        let packetBytes = try XCTUnwrap(expected["packetBytes"] as? Int)
        let packetCount = try XCTUnwrap(expected["packetCount"] as? Int)
        let actual = try await Self.compressedFingerprint(output)
        let reference = try await Self.compressedFingerprint(fixture("opus-160", fileExtension: "mp4"))
        XCTAssertEqual(actual.hash, expectedHash, "Independent golden hash from the original encoded WebM packets")
        XCTAssertEqual(actual.bytes, packetBytes * packetCount)
        XCTAssertEqual(actual.hash, reference.hash)
        XCTAssertEqual(actual.samples, reference.samples)
    }

    nonisolated private static func compressedFingerprint(_ url: URL) async throws -> (hash: String, bytes: Int, samples: Int) {
        let asset = AVURLAsset(url: url)
        defer { asset.cancelLoading() }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw OpusPreparationError.invalidOutput }
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        guard reader.canAdd(output) else { throw OpusPreparationError.invalidOutput }
        reader.add(output)
        guard reader.startReading() else { throw OpusPreparationError.invalidOutput }
        var hash = SHA256()
        var byteCount = 0, samples = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if CMSampleBufferGetNumSamples(sample) == 0 && CMSampleBufferGetTotalSampleSize(sample) == 0 { continue }
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
            XCTAssertEqual(format.pointee.mFormatID, kAudioFormatOpus)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= 1 << 20 else { throw OpusPreparationError.invalidOutput }
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw OpusPreparationError.invalidOutput }
            hash.update(data: bytes)
            byteCount += size
            samples += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed else { throw OpusPreparationError.invalidOutput }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount, samples)
    }

    private func fixture(_ name: String, fileExtension ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Breezy-SEC1-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func requireNativeTests() throws {
        guard OpusNativeAudio.isSupported else { throw XCTSkip("Native Opus metadata regression requires iOS 26.5+") }
    }
}

private enum MetadataWebMFixture {
    enum Kind: Sendable, Equatable { case tags, chapters, attachments }
    enum Placement: Sendable, Equatable { case beforeMedia, seekHeadToTrailingMetadata }
    enum Length: Sendable, Equatable { case exact, pastFileEnd, unknown }
    enum Failure: Error { case invalidSeed }
    private static let unknownSize = Data([0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])

    static func make(seed: Data, kind: Kind, count: Int, placement: Placement = .beforeMedia,
                     unknownContainers: Bool = false, metadataLength: Length = .exact) throws -> Data {
        var cursor = 0
        let header = try readElement(seed, cursor: &cursor, end: seed.count)
        let segment = try readElement(seed, cursor: &cursor, end: seed.count)
        guard header.id == 0x1a45dfa3, segment.id == 0x18538067, cursor == seed.count else { throw Failure.invalidSeed }
        var prefix = Data(), media = Data()
        var foundInfo = false, foundTrack = false
        cursor = segment.payload.lowerBound
        while cursor < segment.payload.upperBound {
            let child = try readElement(seed, cursor: &cursor, end: segment.payload.upperBound)
            switch child.id {
            case 0x1549a966, 0x1654ae6b:
                prefix.append(seed.subdata(in: child.full))
                foundInfo = foundInfo || child.id == 0x1549a966
                foundTrack = foundTrack || child.id == 0x1654ae6b
            case 0x1f43b675:
                media.append(unknownContainers ? element(child.id, seed.subdata(in: child.payload), unknown: true)
                                              : seed.subdata(in: child.full))
            default:
                // Seed SeekHead/Cues offsets cannot be retained when metadata is inserted.
                break
            }
        }
        guard foundInfo, foundTrack, !media.isEmpty else { throw Failure.invalidSeed }
        let metadata = makeMetadata(kind: kind, count: count, length: metadataLength)
        var body: Data
        switch placement {
        case .beforeMedia:
            body = prefix + metadata.bytes + media
        case .seekHeadToTrailingMetadata:
            let placeholder = seekHead(id: metadata.id, offset: 0)
            body = seekHead(id: metadata.id, offset: UInt64(placeholder.count + prefix.count + media.count))
                + prefix + media + metadata.bytes
        }
        body = seed.subdata(in: header.full) + element(0x18538067, body, unknown: unknownContainers)
        guard body.count < 64 << 20 else { throw Failure.invalidSeed }
        return body
    }

    private static func makeMetadata(kind: Kind, count: Int, length: Length) -> (id: UInt32, bytes: Data) {
        var children = Data()
        children.reserveCapacity(count * 64)
        for index in 0..<count {
            switch kind {
            case .tags:
                let pair = element(0x45a3, Data("SEC1_\(index)".utf8)) + element(0x4487, Data("value".utf8))
                children.append(element(0x67c8, pair))
            case .chapters:
                let fields = element(0x73c4, integer(UInt64(index + 1)))
                    + element(0x91, integer(UInt64(index + 1) * 1_000))
                    + element(0x92, integer(UInt64(index + 2) * 1_000))
                children.append(element(0xb6, fields))
            case .attachments:
                let fields = element(0x46ae, integer(UInt64(index + 1)))
                    + element(0x466e, Data("unused".utf8))
                    + element(0x4660, Data("application/octet-stream".utf8))
                    + element(0x465c, Data([0x01]))
                children.append(element(0x61a7, fields))
            }
        }
        let id: UInt32, payload: Data
        switch kind {
        case .tags: id = 0x1254c367; payload = element(0x7373, children)
        case .chapters: id = 0x1043a770; payload = element(0x45b9, children)
        case .attachments: id = 0x1941a469; payload = children
        }
        return (id, element(id, payload, unknown: length == .unknown,
                            declaredLength: length == .pastFileEnd ? 64 << 20 : nil))
    }

    private static func seekHead(id: UInt32, offset: UInt64) -> Data {
        element(0x114d9b74, element(0x4dbb, element(0x53ab, idBytes(id)) + element(0x53ac, integer(offset))))
    }

    private static func element(_ id: UInt32, _ payload: Data, unknown: Bool = false,
                                declaredLength: Int? = nil) -> Data {
        idBytes(id) + (unknown ? unknownSize : size(UInt64(declaredLength ?? payload.count))) + payload
    }

    private static func idBytes(_ id: UInt32) -> Data {
        Data(integer(UInt64(id), width: 4).drop(while: { $0 == 0 }))
    }

    private static func integer(_ value: UInt64, width: Int = 8) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func size(_ value: UInt64) -> Data {
        let width = (1...8).first { value < (UInt64(1) << ($0 * 7)) - 1 }!
        return integer(value | (UInt64(1) << (width * 7)), width: width)
    }

    // Only the trusted fixture's outer headers are read; encoded blocks are copied verbatim.
    private static func readElement(_ data: Data, cursor: inout Int, end: Int)
        throws -> (id: UInt32, full: Range<Int>, payload: Range<Int>) {
        let start = cursor
        func vint(isID: Bool) throws -> (value: UInt64, unknown: Bool) {
            guard cursor < end, data[cursor] != 0 else { throw Failure.invalidSeed }
            let width = data[cursor].leadingZeroBitCount + 1
            guard width <= (isID ? 4 : 8), width <= end - cursor else { throw Failure.invalidSeed }
            var value = UInt64(data[cursor])
            if !isID { value &= UInt64(0xff >> width) }
            cursor += 1
            for _ in 1..<width { value = value << 8 | UInt64(data[cursor]); cursor += 1 }
            return (value, !isID && value == (UInt64(1) << (7 * width)) - 1)
        }
        let id = try vint(isID: true).value
        let length = try vint(isID: false)
        let count = length.unknown ? UInt64(end - cursor) : length.value
        guard count <= UInt64(end - cursor) else { throw Failure.invalidSeed }
        let payload = cursor..<(cursor + Int(count))
        cursor = payload.upperBound
        return (UInt32(id), start..<cursor, payload)
    }
}
