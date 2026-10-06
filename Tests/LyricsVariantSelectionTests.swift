import XCTest
@testable import GanaBajana

enum LyricsVariantFixtures {
    static let track = LyricsTestFixtures.track
    static let nativeText = "ਕਾਗਜ਼ ਦੇ ਤਾਰੇ ਅੰਬਰ ਵਿੱਚ\nਨਵੀਂ ਸਵੇਰ ਦੀ ਰੌਸ਼ਨੀ"
    static let latinText = "Kaagaz de taare ambar vich\nNaveen saver di roshni"

    static func native(_ track: Track = LyricsVariantFixtures.track) -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .plain, plainText: nativeText, sourceID: 101,
                       matchedTitle: track.title, matchedArtist: track.artistName)
    }

    static func latin(_ track: Track = LyricsVariantFixtures.track) -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .synced,
                       lines: [LyricLine(id: 0, time: 1, text: "Kaagaz de taare ambar vich"),
                               LyricLine(id: 1, time: 12, text: "Naveen saver di roshni")],
                       sourceID: 102, matchedTitle: track.title, matchedArtist: track.artistName)
    }
}

struct LyricsVariantFixtureProvider: LyricsVariantsProviding {
    var baseline: @Sendable (Track) async throws -> LyricsDocument = { LyricsVariantFixtures.latin($0) }
    var discover: @Sendable (Track) async throws -> [LyricsDocument] = {
        [LyricsVariantFixtures.latin($0), LyricsVariantFixtures.native($0)]
    }

    func lyrics(for track: Track) async throws -> LyricsDocument { try await baseline(track) }
    func lyricVariants(for track: Track) async throws -> [LyricsDocument] { try await discover(track) }
}

@MainActor
final class LyricsVariantSelectionTests: XCTestCase {
    func testPunjabiUnicodeAndLatinHaveHonestDistinctLabels() {
        let native = LyricsVariant(LyricsVariantFixtures.native())
        let latin = LyricsVariant(LyricsVariantFixtures.latin())
        XCTAssertEqual(native.script, .gurmukhi)
        XCTAssertEqual(latin.script, .latin)
        XCTAssertTrue(native.title(recordingLanguage: "pa-Guru").hasPrefix("Original Script · Gurmukhi"))
        XCTAssertTrue(latin.title(recordingLanguage: "pa").hasPrefix("Romanised / Latin"))
        XCTAssertFalse(latin.title(recordingLanguage: "pa").contains("Original"))
        XCTAssertFalse(native.title(recordingLanguage: nil).contains("Original"))
        XCTAssertFalse(native.title(recordingLanguage: "hi").contains("Original"))
        XCTAssertFalse(LyricsScript.gurmukhi.isOriginalScript(for: "pa-Arab"))
        XCTAssertTrue(LyricsScript.arabic.isOriginalScript(for: "pa-Arab"))
        XCTAssertEqual(LyricsScript.detect("ਕਾਗਜ਼ ਦੇ ਤਾਰੇ\nA completely different English verse"), .mixed)
        XCTAssertEqual(LyricsScript.detect("[00:01] 123 …"), .other)
        XCTAssertEqual(LyricsScript.detect("ਕਿ ਕੀ ਕੁ ਕੂ ਕੇ ਕੈ ਕੋ ਕੌ"), .gurmukhi)
        XCTAssertEqual(LyricsScript.detect("ka\u{0304}gaz de ta\u{0304}re"), .latin)
    }

    func testOriginalScriptIsPreferredAndAnExplicitLatinChoiceSurvivesReload() async throws {
        let loader = LyricsLoader()
        let track = LyricsVariantFixtures.track
        let provider = LyricsVariantFixtureProvider()
        await loader.load(for: track, using: provider, recordingLanguage: "pa")
        XCTAssertEqual(loader.selectedDocument?.plainText, LyricsVariantFixtures.nativeText)
        let latin = try XCTUnwrap(loader.variants.first { $0.script == .latin })
        loader.selectVariant(id: latin.id, for: track)
        XCTAssertEqual(loader.selectedDocument?.kind, .synced)
        await loader.load(for: track, using: provider, recordingLanguage: "pa")
        XCTAssertEqual(loader.selectedDocument?.selectionID, latin.id)
        XCTAssertEqual(loader.variants.count, 2)
    }

    func testRecordingLanguageComesFromInputOrTrackNeverArtist() async {
        var track = LyricsVariantFixtures.track
        track.artists = ["A Punjabi Artist Name Is Not Language Metadata"]
        let loader = LyricsLoader()
        await loader.load(for: track, using: LyricsVariantFixtureProvider())
        XCTAssertNil(loader.recordingLanguage)
        XCTAssertEqual(loader.selectedDocument?.kind, .synced)
        track.language = .english
        await loader.load(for: track, using: LyricsVariantFixtureProvider())
        XCTAssertEqual(loader.recordingLanguage, "en")
        await loader.load(for: track, using: LyricsVariantFixtureProvider(), recordingLanguage: "pa")
        XCTAssertEqual(loader.recordingLanguage, "pa")
        XCTAssertEqual(loader.selectedDocument?.plainText, LyricsVariantFixtures.nativeText)
    }

    func testSwitchingUsesSelectedTimestampsAndClearsPlainTimingAndAttribution() async throws {
        let track = LyricsVariantFixtures.track
        var alternate = LyricsVariantFixtures.latin()
        alternate.lines = [LyricLine(id: 0, time: 8, text: LyricsVariantFixtures.nativeText),
                           LyricLine(id: 1, time: 20, text: "ਕਾਗਜ਼ ਦੇ ਤਾਰੇ")]
        alternate.source = "JioSaavn"
        alternate.attributionText = "Synthetic publisher credit"
        let timedNative = alternate
        let provider = LyricsVariantFixtureProvider(discover: {
            [LyricsVariantFixtures.latin($0), timedNative, LyricsVariantFixtures.native($0)]
        })
        let loader = LyricsLoader()
        var projections: [LyricsDocument?] = []
        loader.onSelectionChanged = { _, document in projections.append(document) }
        await loader.load(for: track, using: provider)
        let latin = try XCTUnwrap(loader.selectedDocument)
        XCTAssertEqual(LRCParser.activeLineIndex(in: latin.lines, at: 15), 1)
        loader.selectVariant(id: timedNative.selectionID, for: track)
        let selected = try XCTUnwrap(loader.selectedDocument)
        XCTAssertEqual(LRCParser.activeLineIndex(in: selected.lines, at: 15), 0)
        XCTAssertEqual(LyricsTiming.seekPosition(for: selected.lines[1], offset: 0.5, duration: 200), 20.5)
        XCTAssertNotEqual(latin.selectionID, selected.selectionID)
        XCTAssertEqual(projections.last.flatMap { $0 }?.source, "JioSaavn")
        XCTAssertEqual(projections.last.flatMap { $0 }?.attributionText, "Synthetic publisher credit")
        loader.selectVariant(id: LyricsVariantFixtures.native().selectionID, for: track)
        XCTAssertEqual(loader.selectedDocument?.kind, .plain)
        XCTAssertTrue(loader.selectedDocument?.lines.isEmpty == true)
        XCTAssertNil(LRCParser.activeLineIndex(in: loader.selectedDocument?.lines ?? [], at: 15))
        XCTAssertEqual(projections.last.flatMap { $0 }?.source, "LRCLIB")
        XCTAssertNil(projections.last.flatMap { $0 }?.attributionText)
    }

    func testLateVariantsAndFailuresCannotReplaceANewerTrackOrClearedTVProjection() async throws {
        for fail in [false, true] {
            let gate = AppModelRequestGate<Track, [LyricsDocument]>()
            addTeardownBlock { await gate.close() }
            let provider = LyricsVariantFixtureProvider(discover: { try await gate.receive($0) })
            let loader = LyricsLoader()
            let track = LyricsVariantFixtures.track
            var next = track
            next.id = "next-recording"
            let old = Task { await loader.load(for: track, using: provider, recordingLanguage: "pa") }
            let request = try await gate.request(at: 0)
            await loader.load(for: next, using: LyricsVariantFixtureProvider(), recordingLanguage: "pa")
            try await gate.complete(request, with: fail ? .failure(MusicServiceError.rateLimited)
                                   : .success([LyricsVariantFixtures.native(track)]))
            await old.value
            XCTAssertEqual(loader.selectedDocument?.trackID, next.id)
            XCTAssertEqual(loader.variants.count, 2)
            XCTAssertNil(loader.variantMessage)
            loader.selectVariant(id: LyricsVariantFixtures.latin(next).selectionID, for: track)
            XCTAssertEqual(loader.selectedDocument?.kind, .plain)
            loader.clear()
            XCTAssertNil(loader.selectedDocument)
            XCTAssertNil(loader.track)
        }
    }

    func testCancellationDuringDiscoveryKeepsBaselineAndDoesNotPublishLateChoice() async throws {
        let gate = AppModelRequestGate<Track, [LyricsDocument]>()
        addTeardownBlock { await gate.close() }
        let loader = LyricsLoader()
        let provider = LyricsVariantFixtureProvider(discover: { try await gate.receive($0) })
        let task = Task { await loader.load(for: LyricsVariantFixtures.track, using: provider, recordingLanguage: "pa") }
        let request = try await gate.request(at: 0)
        XCTAssertEqual(loader.selectedDocument?.kind, .synced)
        task.cancel()
        try await gate.complete(request, with: .success([LyricsVariantFixtures.native()]))
        await task.value
        XCTAssertEqual(loader.selectedDocument?.kind, .synced)
        XCTAssertFalse(loader.isDiscoveringVariants)
        XCTAssertEqual(loader.variants.count, 1)
    }

    func testClearRetiresAnOutstandingLookupAndPublishesNilForTV() async throws {
        let gate = AppModelRequestGate<Track, [LyricsDocument]>()
        addTeardownBlock { await gate.close() }
        let loader = LyricsLoader()
        var published: [LyricsDocument?] = []
        loader.onSelectionChanged = { _, document in published.append(document) }
        let provider = LyricsVariantFixtureProvider(discover: { try await gate.receive($0) })
        let pending = Task { await loader.load(for: LyricsVariantFixtures.track, using: provider) }
        let request = try await gate.request(at: 0)
        loader.clear()
        let countAtClear = published.count
        XCTAssertNil(published.last.flatMap { $0 })
        try await gate.complete(request, with: .success([LyricsVariantFixtures.native()]))
        await pending.value
        XCTAssertEqual(published.count, countAtClear)
        XCTAssertNil(loader.selectedDocument)
        XCTAssertTrue(loader.variants.isEmpty)
    }

    func testUnavailableInstrumentalFailureAndMalformedVariantsStayDistinct() async {
        for kind in [LyricsKind.unavailable, .instrumental] {
            let loader = LyricsLoader()
            let provider = LyricsVariantFixtureProvider(baseline: { LyricsDocument(trackID: $0.id, kind: kind) }, discover: { _ in [] })
            await loader.load(for: LyricsVariantFixtures.track, using: provider)
            XCTAssertEqual(loader.selectedDocument?.kind, kind)
            XCTAssertTrue(loader.variants.isEmpty)
        }
        let failed = LyricsLoader()
        await failed.load(for: LyricsVariantFixtures.track, using: LyricsVariantFixtureProvider(
            baseline: { _ in throw MusicServiceError.rateLimited }, discover: { _ in throw MusicServiceError.rateLimited }))
        guard case .failed = failed.state else { return XCTFail("Outage became successful absence") }
        let partial = LyricsLoader()
        await partial.load(for: LyricsVariantFixtures.track, using: LyricsVariantFixtureProvider(discover: { _ in
            [LyricsDocument(trackID: "wrong-recording", kind: .plain, plainText: "Unrelated text")]
        }))
        XCTAssertEqual(partial.selectedDocument?.kind, .synced)
        XCTAssertNotNil(partial.variantMessage)
        XCTAssertEqual(partial.variants.count, 1)
    }

    func testChoicesAreBoundedAndDoNotCrossRecordingMetadataChanges() async throws {
        let loader = LyricsLoader()
        let provider = LyricsVariantFixtureProvider()
        for index in 0..<33 {
            var track = LyricsVariantFixtures.track
            track.id = "recording-\(index)"
            await loader.load(for: track, using: provider, recordingLanguage: "pa")
            loader.selectVariant(id: LyricsVariantFixtures.latin(track).selectionID, for: track)
        }
        var oldest = LyricsVariantFixtures.track
        oldest.id = "recording-0"
        await loader.load(for: oldest, using: provider, recordingLanguage: "pa")
        XCTAssertEqual(loader.selectedDocument?.kind, .plain)
        oldest.id = "recording-32"
        await loader.load(for: oldest, using: provider, recordingLanguage: "pa")
        XCTAssertEqual(loader.selectedDocument?.kind, .synced)
        oldest.duration = 205
        await loader.load(for: oldest, using: provider, recordingLanguage: "pa")
        XCTAssertEqual(loader.selectedDocument?.kind, .plain)
    }

    func testLegacyDocumentDecodesAndAttributionRoundTripsWithoutChangingIdentityOnRefresh() throws {
        let data = Data(#"{"trackID":"old","kind":"plain","lines":[],"plainText":"Old text","source":"LRCLIB","fetchedAt":0}"#.utf8)
        let legacy = try JSONDecoder().decode(LyricsDocument.self, from: data)
        XCTAssertNil(legacy.attributionText)
        XCTAssertNil(legacy.attributionURL)
        XCTAssertNil(legacy.providerTrackID)
        var document = LyricsVariantFixtures.native()
        document.attributionText = "Published credit"
        document.attributionURL = URL(string: "https://example.org/lyrics")
        document.providerTrackID = "saavn:matched"
        let decoded = try JSONDecoder().decode(LyricsDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.attributionText, document.attributionText)
        XCTAssertEqual(decoded.sourceURL, document.attributionURL)
        XCTAssertEqual(decoded.providerTrackID, document.providerTrackID)
        let identity = document.selectionID
        document.fetchedAt.addTimeInterval(100)
        XCTAssertEqual(document.selectionID, identity)
        document.attributionURL = URL(string: "javascript:alert(1)")
        XCTAssertNotEqual(document.sourceURL?.scheme, "javascript")
    }
}
