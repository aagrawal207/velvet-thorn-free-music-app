import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLanguageTests: XCTestCase {
    func testNativeRecognitionCoversHindiTamilTeluguEnglishAndBengaliOriginalScript() {
        let samples: [(ArtistSongLanguage, String)] = [
            (.hindi, ArtistSpotlightFixtures.hindiText), (.tamil, ArtistSpotlightFixtures.tamilText),
            (.telugu, ArtistSpotlightFixtures.teluguText), (.english, ArtistSpotlightFixtures.englishText),
            (.bengali, ArtistSpotlightFixtures.bengaliText),
        ]
        let track = ArtistSpotlightTestSupport.track("native-language", title: "A language-neutral title")
        for (language, text) in samples {
            let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text), for: track)
            XCTAssertEqual(result, .identified(language, source: .matchedLyrics), language.title)
            XCTAssertTrue(result.isInferred)
        }
    }

    func testOnlyMatchedLyricsCanSupplyLanguageEvidence() {
        let track = ArtistSpotlightTestSupport.track("identity", title: "Hindi Tamil Telugu English")
        let original = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.tamilText)
        let changes: [(inout LyricsDocument) -> Void] = [
            { $0.trackID = "stale-song" }, { $0.sourceID = nil }, { $0.matchedTitle = "A different title" },
            { $0.matchedArtist = "A different artist" }, { $0.source = "Unverified lyrics" },
            { $0.kind = .unavailable }, { $0.kind = .instrumental },
        ]
        for change in changes {
            var document = original
            change(&document)
            let result = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["ta": 1] })
            XCTAssertEqual(result, .unclassified(.noMatchedLyrics))
        }
        XCTAssertNil(ArtistSongLanguageResult.recordingMetadata(track), "Rahman's name and a language in the title are not proof")
    }

    func testLowConfidenceCompetingLanguagesAndUnsupportedLanguageStayUnknown() {
        let track = ArtistSpotlightTestSupport.track("confidence")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.hindiText)
        for scores in [["hi": 0.80], ["hi": 0.93, "mr": 0.89], ["mr": 0.99], ["hi": Double.nan], [:]] {
            let result = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in scores })
            XCTAssertEqual(result, .unclassified(.uncertainLanguage))
        }
    }

    func testShortRepeatedAndRomanizedIndianLyricsCannotBeLabeledEnglish() {
        let track = ArtistSpotlightTestSupport.track("romanized")
        let short = ArtistSpotlightTestSupport.document(track, text: "nayi subah mere dil ki baat")
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(short, for: track, hypotheses: { _ in ["en": 1] }),
                       .unclassified(.insufficientText))
        let repeated = ArtistSpotlightTestSupport.document(track, text: Array(repeating: "nayi subah mere dil ki baat", count: 40).joined(separator: "\n"))
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(repeated, for: track, hypotheses: { _ in ["en": 1] }),
                       .unclassified(.insufficientText))
        let romanized = """
        subah ki halki hawa hamare chhote ghar ki khidki se andar aati hai aasman par badal dheere chalte hain
        bachche khule maidan mein khelte hain hum apne doston ke saath nadi ke kinare baithkar aaj ki yatra par baat karte hain shaam hone par sab log ghar lautkar garam khana banate hain
        """
        let document = ArtistSpotlightTestSupport.document(track, text: romanized)
        for code in ["en", "hi", "ta", "te"] {
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in [code: 1] }),
                           .unclassified(.uncertainLanguage))
        }
    }

    func testMixedScriptsAndDisagreeingVersesRemainUnclassifiedDespiteDominantLanguage() {
        let track = ArtistSpotlightTestSupport.track("mixed")
        let mixed = ArtistSpotlightTestSupport.document(track,
            text: ArtistSpotlightFixtures.tamilText + "\n" + ArtistSpotlightFixtures.hindiText)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(mixed, for: track, hypotheses: { _ in ["ta": 1] }),
                       .unclassified(.uncertainLanguage))
        let english = ArtistSpotlightTestSupport.document(track)
        let result = ArtistSpotlightLanguageClassifier.classify(english, for: track, hypotheses: { text in
            text.split(separator: " ").count > 70 ? ["en": 0.99] : ["hi": 0.99]
        })
        XCTAssertEqual(result, .unclassified(.uncertainLanguage))
    }

    func testAnEnglishVerseDoesNotTurnRomanizedHindiVersesIntoEnglish() {
        let track = ArtistSpotlightTestSupport.track("mixed-latin")
        let text = ArtistSpotlightFixtures.englishText + "\n"
            + "subah ki halki hawa hamare chhote ghar ki khidki se andar aati hai aur dost nadi ke paas baithkar kahani sunate hain"
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["en": 0.99] }),
                       .unclassified(.uncertainLanguage))
    }

    func testSyncedOriginalTextWinsOverAPlainTextTranslation() {
        let track = ArtistSpotlightTestSupport.track("synced")
        var document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightFixtures.englishText)
        document.kind = .synced
        document.lines = [LyricLine(id: 0, time: 1, text: ArtistSpotlightFixtures.tamilText)]
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["ta": 0.99] })
        XCTAssertEqual(result, .identified(.tamil, source: .matchedLyrics))
    }

    func testLRCLIBMatcherRejectsWrongRecordingsBeforeClassificationAndAcceptsMixedCredits() async throws {
        var track = ArtistSpotlightTestSupport.track("matched-recording")
        track.credits.insert(ArtistCredit(name: "Fixture Singer"), at: 0)
        for matchesRecording in [false, true] {
            let record = LyricsTestFixtures.record(title: track.title, artist: ArtistSpotlightFixtures.artist.name,
                album: track.albumTitle, duration: matchesRecording ? 240 : 400, plain: ArtistSpotlightFixtures.tamilText, synced: nil)
            let transport = LyricsStubTransport { request, _ in
                if request.url?.path == "/api/get" { return try LyricsTestFixtures.response(record) }
                return try LyricsTestFixtures.response([record])
            }
            let service = LRCLyricsService(transport: transport, clientConfiguration: LyricsTestFixtures.clientConfiguration())
            let document = try await service.lyrics(for: track)
            let result = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["ta": 0.99] })
            XCTAssertEqual(result, matchesRecording ? .identified(.tamil, source: .matchedLyrics) : .unclassified(.noMatchedLyrics))
        }
    }
}
