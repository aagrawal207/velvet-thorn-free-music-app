import XCTest
@testable import GanaBajana

@MainActor
final class LiveRadioNativeValidationTests: XCTestCase {
    func testNativeRequirementsAcceptPositiveChecks() async throws {
        for stage in [LiveRadioDiagnostics.Stage.nativePlayable, .nativeAudio, .nativeVideo] {
            try await LiveRadioNativeValidation.require(stage) { true }
        }
    }

    func testEachRejectedNativeGuardRetainsUnsupportedStationFailure() async {
        for stage in [LiveRadioDiagnostics.Stage.nativePlayable, .nativeAudio, .nativeVideo] {
            do {
                try await LiveRadioNativeValidation.require(stage) { false }
                XCTFail("Expected rejection at \(stage.rawValue)")
            } catch LiveRadioError.invalidStation { }
            catch { XCTFail("Unexpected failure at \(stage.rawValue): \(error)") }
        }
    }

    func testNativeTransportErrorIsNotReclassifiedAsUnsupportedCodec() async {
        do {
            try await LiveRadioNativeValidation.require(.nativePlayable) { throw URLError(.networkConnectionLost) }
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancelledNativeCheckDoesNotRunItsLoader() async {
        let task = Task { @MainActor in
            try await LiveRadioNativeValidation.require(.nativeAudio) { throw URLError(.badURL) }
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation before loader invocation") }
        catch is CancellationError { }
        catch { XCTFail("Loader ran after cancellation: \(error)") }
    }

    func testProvenElementaryMP3AndADTSAllowEmptyStaticAudioTracks() async throws {
        for (data, mime) in [(LiveRadioFrameFixtures.mp3, "audio/mpeg"), (LiveRadioFrameFixtures.adts, "audio/aac")] {
            let url = LiveRadioFrameFixtures.url
            let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(data, contentType: mime, url: url))
            let connection = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url, sourceProof: .elementary(proof))
            try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                playable: { true }, audioCount: { 0 }, videoCount: { 0 })
        }
    }

    func testNativeAudioTracksStillValidateWithoutElementaryEvidence() async throws {
        let url = LiveRadioFrameFixtures.url
        for proof in [LiveRadioSourceProof.unverified, .hls] {
            let connection = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url, sourceProof: proof)
            try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                playable: { true }, audioCount: { 1 }, videoCount: { 0 })
        }
    }

    func testValidatedHLSPlaylistAllowsEmptyStaticAudioTracksButNotVideo() async throws {
        let url = LiveRadioFrameFixtures.url
        let connection = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url, sourceProof: .hls)
        XCTAssertTrue(connection.hasPlaylistProof(for: url))
        try await LiveRadioNativeValidation.validate(url: url, connection: connection,
            playable: { true }, audioCount: { 0 }, videoCount: { 0 })
        do {
            try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                playable: { true }, audioCount: { 0 }, videoCount: { 1 })
            XCTFail("A video rendition must stay rejected")
        } catch LiveRadioError.invalidStation { }
    }

    func testEmptyStaticTracksWithoutProofWithHLSOrWithDifferentURLAreRejected() async throws {
        let url = LiveRadioFrameFixtures.url
        let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        let otherURL = URL(string: "https://other.example.org/live")!
        let hlsStation = LiveRadioStation(id: LiveRadioTestSupport.station.id, name: "HLS", streamingURL: url,
            homepageURL: nil, artworkURL: nil, countryCode: "US", languages: [], tags: [], codec: "AAC", isHLS: true)
        let candidates: [LiveRadioConnection?] = [nil,
            LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url),
            LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: otherURL, sourceProof: .hls),
            LiveRadioConnection(station: hlsStation, streamingURL: url, sourceProof: .elementary(proof)),
            LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: otherURL, sourceProof: .elementary(proof))]
        for connection in candidates {
            do {
                try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                    playable: { true }, audioCount: { 0 }, videoCount: { 0 })
                XCTFail("Missing or mismatched proof must not authorize empty static tracks")
            } catch LiveRadioError.invalidStation { }
        }
        let wrongProof = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: otherURL, sourceProof: .elementary(proof))
        XCTAssertFalse(wrongProof.hasElementaryProof(for: otherURL))
        do {
            try await LiveRadioNativeValidation.validate(url: otherURL, connection: wrongProof,
                playable: { true }, audioCount: { 0 }, videoCount: { 0 })
            XCTFail("An elementary proof must remain bound to its probed URL")
        } catch LiveRadioError.invalidStation { }
    }

    func testActualVideoAndNotPlayableAlwaysRejectEvenWithElementaryProof() async throws {
        let url = LiveRadioFrameFixtures.url
        let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        let connection = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url, sourceProof: .elementary(proof))
        for playable in [true, false] {
            do {
                try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                    playable: { playable }, audioCount: { throw URLError(.badURL) }, videoCount: { playable ? 1 : 0 })
                XCTFail("Video or non-playable assets must fail before any audio-proof fallback")
            } catch LiveRadioError.invalidStation { }
        }
    }

    func testNativeVideoReadFailureCannotBeBypassedByElementaryProof() async throws {
        let url = LiveRadioFrameFixtures.url
        let proof = try XCTUnwrap(LiveRadioElementaryProof.inspect(LiveRadioFrameFixtures.mp3, contentType: "audio/mpeg", url: url))
        let connection = LiveRadioConnection(station: LiveRadioTestSupport.station, streamingURL: url, sourceProof: .elementary(proof))
        do {
            try await LiveRadioNativeValidation.validate(url: url, connection: connection,
                playable: { true }, audioCount: { 0 }, videoCount: { throw URLError(.networkConnectionLost) })
            XCTFail("Video inspection failures must propagate")
        } catch let error as URLError { XCTAssertEqual(error.code, .networkConnectionLost) }
    }
}
