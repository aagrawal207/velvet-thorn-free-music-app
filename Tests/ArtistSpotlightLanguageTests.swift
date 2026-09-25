import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLanguageTests: XCTestCase {
    private let sparseEnglishLines = [
        "I keep dreaming I keep walking I breathe",
        "My battered speakers crackle beneath flickering basement lights",
    ]

    func testConfidentEnglishResetsSparseRepeatedPronounAndSingleAnchorLines() throws {
        let track = ArtistSpotlightTestSupport.track("sparse-english")
        for line in sparseEnglishLines {
            let document = ArtistSpotlightTestSupport.document(track, text: line + "\n" + ArtistSpotlightFixtures.englishText)
            let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { text in
                text == line ? ["en": 0.97, "nl": 0.03] : ["en": 0.99]
            }
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses),
                           .identified(.english, source: .matchedLyrics))
            let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
            let sparse = try XCTUnwrap(inspection.lines.first)
            XCTAssertEqual(sparse.wordCount, 8)
            XCTAssertTrue(sparse.lexicalPassOne)
            XCTAssertFalse(sparse.lexicalPassTwo)
            XCTAssertTrue(sparse.recognizerAssistedReset)
            XCTAssertTrue(sparse.resetsUnsupportedRun)
            XCTAssertNil(inspection.firstRejectedLine)
        }
    }

    func testNativeRecognitionAcceptsSparseSingleAnchorEnglishInMatchedContext() {
        let track = ArtistSpotlightTestSupport.track("native-sparse-english")
        let document = ArtistSpotlightTestSupport.document(track, text: sparseEnglishLines[1] + "\n" + ArtistSpotlightFixtures.englishText)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track), .identified(.english, source: .matchedLyrics))
    }

    func testNativeUncertaintyIsNotOverriddenByAnEnglishLookingPronounPattern() {
        let track = ArtistSpotlightTestSupport.track("native-repetitive-pronoun")
        let text = sparseEnglishLines[0] + "\n" + ArtistSpotlightFixtures.englishText
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        XCTAssertLessThan(ArtistSpotlightLanguageClassifier.recognize(text)["en"] ?? 0, 0.92)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track), .unclassified(.uncertainLanguage))
    }

    func testWindowRecognitionKeepsOriginalPunctuationContractionsAndLineBreaks() {
        let track = ArtistSpotlightTestSupport.track("original-window-text")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRapText)
        let normalizedInputs = CatalogTestRecorder<Bool>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
            let isNormalized = sample == LyricsMatcher.normalized(sample)
            normalizedInputs.record(isNormalized)
            return isNormalized ? ["en": 0.47, "hr": 0.22, "nb": 0.14] : ["en": 0.99]
        }
        XCTAssertEqual(result, .identified(.english, source: .matchedLyrics))
        XCTAssertFalse(normalizedInputs.values.contains(true), "Recognition must receive the original text, including window samples")
    }

    func testAmbiguousWordBoundaryWindowsUseBoundedLineContextWithoutLoweringConfidence() {
        let track = ArtistSpotlightTestSupport.track("window-context")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRapText)
        let wordCounts = CatalogTestRecorder<Int>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
            let count = sample.split(whereSeparator: \.isWhitespace).count
            wordCounts.record(count)
            return count == 40 ? ["en": 0.4747, "hr": 0.2248, "nb": 0.1457, "nl": 0.0553] : ["en": 0.99]
        }
        XCTAssertEqual(result, .identified(.english, source: .matchedLyrics))
        let afterWholeText = wordCounts.values.dropFirst()
        XCTAssertTrue(afterWholeText.contains(40))
        XCTAssertTrue(afterWholeText.contains { $0 > 40 }, "An ambiguous core needs additional original-line context")
        XCTAssertTrue(afterWholeText.allSatisfy { $0 <= 80 }, "Context expansion is bounded independently of document size")
    }

    func testUnresolvedWindowAmbiguityStopsAfterOneContextExpansion() {
        let track = ArtistSpotlightTestSupport.track("unresolved-window")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRapText)
        let wordCounts = CatalogTestRecorder<Int>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
            let count = sample.split(whereSeparator: \.isWhitespace).count
            wordCounts.record(count)
            return (20...80).contains(count) ? ["en": 0.47, "hr": 0.22, "nb": 0.14] : ["en": 0.99]
        }
        XCTAssertEqual(result, .unclassified(.uncertainLanguage))
        let windowCalls = wordCounts.values.dropFirst().filter { $0 >= 20 }
        XCTAssertEqual(windowCalls.count, 2, "An ambiguous core gets one bounded retry, not progressively more of the song")
        XCTAssertEqual(windowCalls.first, 40)
        XCTAssertTrue(windowCalls.allSatisfy { $0 <= 80 })
    }

    func testConfidentUnsupportedWindowCannotBeWashedOutByEnglishContext() {
        let track = ArtistSpotlightTestSupport.track("foreign-window")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRapText)
        let cases: [(Double, ArtistSongLanguageResult)] = [
            (0.99, .unclassified(.conflictingEvidence)), (0.93, .unclassified(.uncertainLanguage)),
        ]
        for (confidence, expected) in cases {
            let wordCounts = CatalogTestRecorder<Int>()
            let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
                let count = sample.split(whereSeparator: \.isWhitespace).count
                wordCounts.record(count)
                return count == 40 ? ["es": confidence] : ["en": 0.99]
            }
            XCTAssertEqual(result, expected)
            XCTAssertEqual(wordCounts.values.dropFirst().filter { $0 >= 20 }, [40], "Confident foreign evidence forbids a context retry")
        }
    }

    func testAdditionalContextCannotSupplyMissingCoreLexicalEvidence() {
        let track = ArtistSpotlightTestSupport.track("window-lexical-evidence")
        let sparseCore = """
        I hear you singing over dusty broken speakers
        You hear me singing beneath quiet midnight windows
        I hear you humming beside silent empty hallways
        You hear me whispering beneath distant summer thunder
        I hear you laughing beside sleepy little lanterns
        """
        let document = ArtistSpotlightTestSupport.document(track, text: sparseCore + "\n" + ArtistSpotlightTestSupport.englishRapText)
        let wordCounts = CatalogTestRecorder<Int>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
            let count = sample.split(whereSeparator: \.isWhitespace).count
            wordCounts.record(count)
            return count == 40 ? ["en": 0.47, "hr": 0.22] : ["en": 0.99]
        }
        XCTAssertEqual(result, .unclassified(.uncertainLanguage))
        XCTAssertEqual(wordCounts.values.dropFirst().filter { $0 >= 20 }, [40], "A core without four distinct lexical words cannot borrow them from context")
    }

    func testContextRevealingAForeignLanguageStillVetoesEnglish() {
        let track = ArtistSpotlightTestSupport.track("foreign-context")
        let document = ArtistSpotlightTestSupport.document(track, text: ArtistSpotlightTestSupport.englishRapText)
        let wordCounts = CatalogTestRecorder<Int>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { sample in
            let count = sample.split(whereSeparator: \.isWhitespace).count
            wordCounts.record(count)
            if count == 40 { return ["en": 0.47, "hr": 0.22] }
            if (41...80).contains(count) { return ["es": 0.99] }
            return ["en": 0.99]
        }
        XCTAssertEqual(result, .unclassified(.conflictingEvidence))
        XCTAssertEqual(wordCounts.values.dropFirst().filter { $0 >= 20 }.count, 2)
    }

    func testSparseEnglishNeedsHighConfidenceAndAClearMargin() throws {
        let track = ArtistSpotlightTestSupport.track("sparse-confidence")
        let line = sparseEnglishLines[0]
        let document = ArtistSpotlightTestSupport.document(track, text: line + "\n" + ArtistSpotlightFixtures.englishText)
        for scores in [["en": 0.969], ["en": 0.70], ["en": 0.99, "nl": 0.85], ["en": Double.nan], ["en": Double.infinity], [:]] {
            let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { $0 == line ? scores : ["en": 0.99] }
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses),
                           .unclassified(.uncertainLanguage))
            let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
            XCTAssertFalse(try XCTUnwrap(inspection.lines.first).recognizerAssistedReset)
            XCTAssertEqual(inspection.firstRejectedLine, 1)
            XCTAssertEqual(inspection.rejectedRunWordCount, 8)
        }
    }

    func testEnglishRecognitionAloneCannotResetUnanchoredOrAmbiguousWords() throws {
        let track = ArtistSpotlightTestSupport.track("no-english-anchor")
        let lines = ["Silent silver clouds drift overhead beyond shuttered windows",
                     "mere dil ki baat suno nayi subah aayi", "is me to do us in a an"]
        for line in lines {
            let document = ArtistSpotlightTestSupport.document(track, text: line + "\n" + ArtistSpotlightFixtures.englishText)
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["en": 1] }),
                           .unclassified(.uncertainLanguage))
            let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: { _ in ["en": 1] }))
            let unsupported = try XCTUnwrap(inspection.lines.first)
            XCTAssertFalse(unsupported.lexicalPassOne)
            XCTAssertFalse(unsupported.recognizerAssistedReset)
            XCTAssertFalse(unsupported.resetsUnsupportedRun)
            XCTAssertEqual(inspection.firstRejectedLine, 1)
        }
    }

    func testForeignSegmentsWithNoOrHeCannotUseTheSingleAnchorFallback() {
        let track = ArtistSpotlightTestSupport.track("foreign-single-anchor")
        for guest in ["No puedo olvidar aquellos días junto al río", "He buscado respuestas durante noches llenas de silencio"] {
            let text = ArtistSpotlightTestSupport.shortEnglishRockText + "\n" + sparseEnglishLines[0] + "\n" + guest
            let document = ArtistSpotlightTestSupport.document(track, text: text)
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track,
                hypotheses: { $0 == guest ? ["es": 0.99] : ["en": 0.99] }), .unclassified(.conflictingEvidence))
        }
    }

    func testShortForeignSingleAnchorLinesStillAccumulateAnUnsupportedRun() throws {
        let track = ArtistSpotlightTestSupport.track("short-foreign-anchors")
        let text = ArtistSpotlightTestSupport.shortEnglishRockText + "\nNo recuerdo aquellos días\nHe buscado otras respuestas"
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { text in
            text.hasPrefix("No recuerdo") || text.hasPrefix("He buscado") ? ["es": 0.99] : ["en": 0.99]
        }
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses),
                       .unclassified(.uncertainLanguage))
        let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        XCTAssertTrue(inspection.lines.suffix(2).allSatisfy(\.lexicalPassOne))
        XCTAssertTrue(inspection.lines.suffix(2).allSatisfy { !$0.recognizerAssistedReset && !$0.resetsUnsupportedRun })
        XCTAssertEqual(inspection.rejectedRunWordCount, 8)
    }

    func testUnanchoredShortLineWaitsForLexicalEvidenceEvenWithStrongEnglishRecognition() throws {
        let track = ArtistSpotlightTestSupport.track("unanchored-short-line")
        let reset = "We are walking with our friends along the river"
        let text = "Silent silver clouds drift beyond shuttered windows\n" + reset + "\n" + ArtistSpotlightFixtures.englishText
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { $0 == reset ? ["en": 0.50] : ["en": 0.99] }
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses),
                       .identified(.english, source: .matchedLyrics))
        let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        let unsupported = try XCTUnwrap(inspection.lines.first)
        XCTAssertEqual(unsupported.wordCount, 7)
        XCTAssertFalse(unsupported.resetsUnsupportedRun)
        XCTAssertFalse(unsupported.recognizerAssistedReset)
        XCTAssertTrue(inspection.lines[1].lexicalPassTwo)
        XCTAssertTrue(inspection.lines[1].resetsUnsupportedRun)
        XCTAssertFalse(inspection.lines[1].recognizerAssistedReset)
        XCTAssertEqual(inspection.lines[1].englishConfidence, 0.50)
        XCTAssertNil(inspection.firstRejectedLine)
    }

    func testLexicalInspectionReportsTheFirstCumulativeRejectAndOneVersusTwoWordGates() throws {
        let track = ArtistSpotlightTestSupport.track("lexical-inspection")
        let text = "My copper lantern\nSilent silver clouds drift overhead\n" + ArtistSpotlightFixtures.englishText
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { $0 == "My copper lantern" ? ["en": 0.96] : ["en": 0.99] }
        let before = ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses)
        let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        XCTAssertTrue(inspection.wholeLexicalPass)
        XCTAssertTrue(inspection.wholeScriptPass)
        XCTAssertEqual(inspection.firstRejectedLine, 2)
        XCTAssertEqual(inspection.rejectedRunWordCount, 8)
        XCTAssertEqual(inspection.lines.prefix(2).map(\.index), [1, 2])
        XCTAssertEqual(inspection.lines.prefix(2).map(\.wordCount), [3, 5])
        XCTAssertEqual(inspection.lines.prefix(2).map(\.lexicalPassOne), [true, false])
        XCTAssertEqual(inspection.lines.prefix(2).map(\.lexicalPassTwo), [false, false])
        XCTAssertEqual(inspection.lines.first?.englishConfidence, 0.96)
        XCTAssertFalse(try XCTUnwrap(inspection.lines.first).recognizerAssistedReset)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: hypotheses), before)
    }

    func testLexicalInspectionUsesRetainedLinesAndExpandedContractionCounts() throws {
        let track = ArtistSpotlightTestSupport.track("lexical-cleanup")
        let document = ArtistSpotlightTestSupport.document(track, text: "[Verse 1] I'm awake\nI'm awake\n[Chorus]\nOh oh oh\nYou're here")
        let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track,
                                                                                                hypotheses: { _ in ["en": 0.99] }))
        XCTAssertEqual(inspection.totalLineCount, 2)
        XCTAssertEqual(inspection.wholeWordCount, 6)
        XCTAssertEqual(inspection.lines.map(\.wordCount), [3, 3])
        XCTAssertTrue(inspection.lines.allSatisfy(\.lexicalPassTwo))
        XCTAssertNil(inspection.firstRejectedLine)
    }

    func testLexicalInspectionBoundsRecognizerCallsAndRejectsUnmatchedOrOversizedDocuments() throws {
        let track = ArtistSpotlightTestSupport.track("lexical-bound")
        let text = (0..<200).map { "I keep my radio at home \($0)" }.joined(separator: "\n")
        let calls = CatalogTestRecorder<Int>()
        let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { _ in
            calls.record(1)
            return ["en": 0.99]
        }
        var document = ArtistSpotlightTestSupport.document(track, text: text)
        let inspection = try XCTUnwrap(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        XCTAssertEqual(inspection.totalLineCount, 200)
        XCTAssertEqual(inspection.lines.count, 128)
        XCTAssertEqual(calls.values.count, 128)
        document.trackID = "another-recording"
        XCTAssertNil(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        document = ArtistSpotlightTestSupport.document(track, text: String(repeating: "x", count: 12_001))
        XCTAssertNil(ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track, hypotheses: hypotheses))
        XCTAssertEqual(calls.values.count, 128)
    }

    func testNativeRecognitionAcceptsEnglishRapAndRockWithoutArtistOrTitleHints() {
        let track = ArtistSpotlightTestSupport.track("lyrical-english", title: "नयी राह")
        for text in [ArtistSpotlightTestSupport.englishRapText, ArtistSpotlightTestSupport.englishRockText,
                     ArtistSpotlightTestSupport.shortEnglishRockText] {
            for sample in [text, text.replacingOccurrences(of: "'", with: "’")] {
                let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: sample), for: track)
                XCTAssertEqual(result, .identified(.english, source: .matchedLyrics))
            }
        }
    }

    func testEnglishContractionsAndInlineSectionLabelsRetainUsableEvidence() {
        let track = LyricsFallbackFixtures.track
        let document = LyricsFallbackFixtures.plain(text: ArtistSpotlightTestSupport.englishRapText)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["en": 0.99] }),
                       .identified(.english, source: .linkedLyrics))
    }

    func testRomanizedHindiFunctionWordCoincidencesAndEnglishAdlibsStayUnknown() {
        let track = ArtistSpotlightTestSupport.track("romanized-function-words")
        let text = ArtistSpotlightTestSupport.romanizedHindiText + "\nOh oh oh yeah yeah hey hey"
        let document = ArtistSpotlightTestSupport.document(track, text: text)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track, hypotheses: { _ in ["en": 1] }),
                       .unclassified(.uncertainLanguage))
        XCTAssertNotEqual(ArtistSpotlightLanguageClassifier.classify(document, for: track).language, .english)
    }

    func testShortRomanizedGuestLinesCannotHideBehindAnEnglishVerse() {
        let track = ArtistSpotlightTestSupport.track("short-guest-lines")
        let text = ArtistSpotlightTestSupport.englishRapText + """

        subah ki halki hawa aati hai
        mere dil ki baat suno saathi
        khidki se nayi roshni ghar aayi
        """
        let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text),
                                                               for: track, hypotheses: { _ in ["en": 0.99] })
        XCTAssertEqual(result, .unclassified(.uncertainLanguage))
    }

    func testConfidentBilingualVersesAreAConflictRatherThanTheMajorityLanguage() {
        let track = ArtistSpotlightTestSupport.track("bilingual")
        let text = ArtistSpotlightTestSupport.englishRapText + "\n" + ArtistSpotlightFixtures.hindiText
        let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text), for: track,
            hypotheses: { sample in
                if sample.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) { return ["hi": 0.99] }
                return ["en": 0.99]
            })
        XCTAssertEqual(result, .unclassified(.conflictingEvidence))
    }

    func testUnsupportedConfidentGuestLanguageCannotBeDiscarded() {
        let track = ArtistSpotlightTestSupport.track("unsupported-guest")
        let spanish = "Mis amigos caminan por el bosque mientras nosotros buscamos otro camino para volver a nuestra casa"
        let text = ArtistSpotlightTestSupport.englishRockText + "\n" + spanish
        let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text), for: track,
            hypotheses: { $0.hasPrefix("Mis amigos") ? ["es": 0.99] : ["en": 0.99] })
        XCTAssertEqual(result, .unclassified(.conflictingEvidence))
    }

    func testSingleSpanishGuestLineConflictsWithShortEnglishLines() {
        let track = LyricsFallbackFixtures.track
        let text = ArtistSpotlightTestSupport.shortEnglishRockText + "\n" + ArtistSpotlightTestSupport.spanishGuestLine
        let documents = [ArtistSpotlightTestSupport.document(track, text: text), LyricsFallbackFixtures.plain(track, text: text)]
        for document in documents {
            let result = ArtistSpotlightLanguageClassifier.classify(document, for: track,
                hypotheses: { $0.hasPrefix("No he dejado") ? ["es": 0.99] : ["en": 0.99] })
            XCTAssertEqual(result, .unclassified(.conflictingEvidence))
        }
    }

    func testNativeRecognitionRejectsSingleSpanishGuestLineAmongShortEnglishLines() {
        let track = ArtistSpotlightTestSupport.track("native-single-guest")
        let text = ArtistSpotlightTestSupport.shortEnglishRockText + "\n" + ArtistSpotlightTestSupport.spanishGuestLine
        let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text), for: track)
        XCTAssertNil(result.language, "A bilingual sample must not receive a single-language classification")
    }

    func testLowerConfidenceEnglishLinesPermitRapAndRockButCannotHideAForeignLine() {
        let track = ArtistSpotlightTestSupport.track("lower-confidence-lines")
        let hypotheses: ArtistSpotlightLanguageClassifier.Hypotheses = { text in
            if text.hasPrefix("No he dejado") { return ["es": 0.99] }
            if text.contains("\n") { return ["en": 0.93] }
            return ["en": text.split(whereSeparator: \.isWhitespace).count < 20 ? 0.90 : 0.99]
        }
        for text in [ArtistSpotlightTestSupport.englishRapText, ArtistSpotlightTestSupport.englishRockText,
                     ArtistSpotlightTestSupport.shortEnglishRockText] {
            let english = ArtistSpotlightTestSupport.document(track, text: text)
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(english, for: track, hypotheses: hypotheses),
                           .identified(.english, source: .matchedLyrics))
            let mixed = ArtistSpotlightTestSupport.document(track, text: text + "\n" + ArtistSpotlightTestSupport.spanishGuestLine)
            XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(mixed, for: track, hypotheses: hypotheses),
                           .unclassified(.conflictingEvidence))
        }
    }

    func testConflictingCredibleSegmentsSurviveAnUncertainWholeTextLanguage() {
        let track = ArtistSpotlightTestSupport.track("uncertain-whole-text")
        let text = ArtistSpotlightTestSupport.englishRockText + "\n" + ArtistSpotlightTestSupport.spanishGuestLine
        let result = ArtistSpotlightLanguageClassifier.classify(ArtistSpotlightTestSupport.document(track, text: text), for: track,
            hypotheses: { sample in
                if sample.hasPrefix("No he dejado") { return ["es": 0.99] }
                return ["en": sample.contains("\n") ? 0.80 : 0.99]
            })
        XCTAssertEqual(result, .unclassified(.conflictingEvidence))
    }

    func testVocalizationsAloneAndLyricsBeyondTheAnalysisLimitCannotCertifyEnglish() {
        let track = ArtistSpotlightTestSupport.track("analysis-bounds")
        let vocalizations = ArtistSpotlightTestSupport.document(track, text: Array(repeating: "Oh oh yeah hey la na", count: 40).joined(separator: "\n"))
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(vocalizations, for: track, hypotheses: { _ in ["en": 1] }),
                       .unclassified(.insufficientText))
        let longText = Array(repeating: ArtistSpotlightTestSupport.englishRapText, count: 25).joined(separator: "\n")
            + "\n" + ArtistSpotlightFixtures.hindiText
        let long = ArtistSpotlightTestSupport.document(track, text: longText)
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(long, for: track, hypotheses: { _ in ["en": 1] }),
                       .unclassified(.uncertainLanguage))
    }

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
