import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightLanguageLiveTests: XCTestCase {
    func testLiveEnglishRapUsesMatchedOrLinkedLyrics() async throws {
        try await checkLyrics(title: "All Falls Down (feat. Syleena Johnson)", artist: "Kanye West", expected: .english)
    }

    func testLiveEnglishRockUsesMatchedOrLinkedLyrics() async throws {
        try await checkLyrics(title: "No Surprises", artist: "Radiohead", expected: .english)
    }

    func testLiveHindiOrRomanizedHindiIsNeverCertifiedAsEnglish() async throws {
        try await checkLyrics(title: "Tum Hi Ho", artist: "Arijit Singh", expected: .hindi)
    }

    func testLiveExactRecordingAndWorkLanguageContract() async throws {
        try requireLiveTests()
        let recordingID = "60bd9d53-01ff-4562-8058-eb44b3940317"
        let workID = "9dfa4a7e-5993-3c95-b41e-e6a66b777044"
        let session = CatalogTransport.anonymousSession()
        defer { session.invalidateAndCancel() }
        let recording = try await musicBrainz("recording/\(recordingID)", include: "artist-credits+work-rels", session: session)
        let work = try await musicBrainz("work/\(workID)", session: session)
        XCTAssertEqual(recording["id"].string, recordingID)
        XCTAssertEqual(work["id"].string, workID)
        XCTAssertEqual(work["languages"].array.compactMap(\.string), ["eng"])
        // This identity is MusicBrainz's recording, not a fabricated link to a YouTube recording ID.
        let track = Track(id: recordingID, title: "Everything in Its Right Place", artists: ["Radiohead"], duration: 251.426)
        let expected = ArtistSongLanguageResult.identified(.english, source: .musicBrainzWork(recordingID: recordingID, workID: workID))
        XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: recording, recordingID: recordingID, for: track), expected)
        XCTAssertEqual(ArtistSpotlightMusicBrainz.workLanguage(in: recording, recordingID: recordingID, for: track, fetchedWork: work), expected)
        print("LANGUAGE LIVE MusicBrainz recording=\(recordingID) work=\(workID) language=eng")
    }

    private func checkLyrics(title: String, artist: String, expected: ArtistSongLanguage) async throws {
        try requireLiveTests()
        let catalog = YouTubeMusicService()
        let page = try await catalog.search(query: "\(title) \(artist)", filter: .songs, continuation: nil)
        let track = try XCTUnwrap(page.tracks.first { track in
            track.isAudioRecording == true && LyricsMatcher.validDuration(track.duration) != nil
                && LyricsRecordingIdentity.sameTitle(track.title, title, artists: track.artists)
                && LyricsMatcher.artistParts(track.artists).contains { SearchRelevance.normalize($0) == SearchRelevance.normalize(artist) }
        }, "The reference recording must be present with its own title, credits, and duration. Candidates: \(page.tracks.prefix(8).map { "\($0.title) | \($0.artistName) | \($0.duration ?? 0)s | audio=\(String(describing: $0.isAudioRecording))" })")
        let provider = CompositeLyricsProvider(primary: LRCLyricsService(), fallback: catalog)
        let document = try await provider.lyrics(for: track)
        guard document.kind != .unavailable else { throw XCTSkip("The providers currently omit lyrics for this reference recording.") }
        XCTAssertTrue(document.kind == .plain || document.kind == .synced)
        XCTAssertEqual(document.trackID, track.id)
        let diagnostics = CatalogTestRecorder<String>()
        let result = ArtistSpotlightLanguageClassifier.classify(document, for: track) { text in
            let scores = ArtistSpotlightLanguageClassifier.recognize(text)
            diagnostics.record("words=\(text.split(whereSeparator: \.isWhitespace).count), hypotheses=\(scores.sorted { $0.key < $1.key })")
            return scores
        }
        if expected == .english, result.language != .english {
            let attachment = XCTAttachment(string: diagnostics.values.joined(separator: "\n"))
            attachment.name = "language-recognizer-metadata"
            attachment.lifetime = .keepAlways
            add(attachment)
            if let inspection = ArtistSpotlightLanguageClassifier.englishLexicalInspection(document, for: track) {
                let summary = "wholeWords=\(inspection.wholeWordCount) wholeLexical=\(inspection.wholeLexicalPass ? 1 : 0) wholeScript=\(inspection.wholeScriptPass ? 1 : 0)"
                    + " retainedLines=\(inspection.totalLineCount) omittedLines=\(inspection.totalLineCount - inspection.lines.count)"
                    + " firstLexicalRejectLine=\(inspection.firstRejectedLine.map(String.init) ?? "none")"
                    + " rejectingRunWords=\(inspection.rejectedRunWordCount.map(String.init) ?? "none")"
                let rows = inspection.lines.map { line in
                    "line=\(line.index) normalizedWords=\(line.wordCount) lexical1=\(line.lexicalPassOne ? 1 : 0)"
                        + " lexical2=\(line.lexicalPassTwo ? 1 : 0) en=\(line.englishConfidence.map { String(format: "%.6f", $0) } ?? "none")"
                        + " assistedReset=\(line.recognizerAssistedReset ? 1 : 0) reset=\(line.resetsUnsupportedRun ? 1 : 0)"
                }
                let lexicalAttachment = XCTAttachment(string: ([summary, "lineIndexBasis=one-based-retained-lines"] + rows).joined(separator: "\n"))
                lexicalAttachment.name = "language-english-lexical-gate"
                lexicalAttachment.lifetime = .keepAlways
                add(lexicalAttachment)
            }
        }
        if expected == .english {
            XCTAssertEqual(result.language, .english, "Usable English lyrics must not silently fall back to an unknown result: \(result), source=\(document.source), matchedTitle=\(document.matchedTitle ?? "unknown"), matchedArtist=\(document.matchedArtist ?? "unknown")")
            XCTAssertTrue(result.source == .matchedLyrics || result.source == .linkedLyrics)
        } else {
            XCTAssertNotEqual(result.language, .english, "Latin transliteration is not English evidence")
            if let language = result.language { XCTAssertEqual(language, expected) }
        }
        var wrongRecording = track
        wrongRecording.id = "different-recording"
        XCTAssertEqual(ArtistSpotlightLanguageClassifier.classify(document, for: wrongRecording), .unclassified(.noMatchedLyrics))
        print("LANGUAGE LIVE recording=\(track.id) source=\(document.providerSource?.rawValue ?? "unknown") kind=\(document.kind.rawValue) language=\(result.language?.rawValue ?? "unclassified")")
    }

    private func musicBrainz(_ path: String, include: String? = nil, session: URLSession) async throws -> CatalogJSON {
        let contact = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "MusicBrainzContactURL") as? String)
        var components = try XCTUnwrap(URLComponents(string: "https://musicbrainz.org/ws/2/\(path)"))
        components.queryItems = [URLQueryItem(name: "fmt", value: "json")]
        if let include { components.queryItems?.append(URLQueryItem(name: "inc", value: include)) }
        try await MusicBrainzRateLimiter.shared.acquire(before: Date().addingTimeInterval(6))
        var request = URLRequest(url: try XCTUnwrap(components.url), timeoutInterval: 3)
        request.httpShouldHandleCookies = false
        request.setValue("Breezy/1.0 (\(contact))", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let sent = request
        let (data, response) = try await PlaybackDeadline.run(seconds: 3) {
            try await session.boundedData(for: sent, maximumBytes: 2 * 1024 * 1024)
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 429 || status == 503 {
            await MusicBrainzRateLimiter.shared.deferRequests(until: Date().addingTimeInterval(30))
            throw MusicServiceError.rateLimited
        }
        XCTAssertEqual(status, 200)
        return try CatalogJSON.decode(data)
    }

    private func requireLiveTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Set GANABAJANA_LIVE_TESTS=1 to check public recording metadata and lyrics without printing lyric text.")
    }
}
