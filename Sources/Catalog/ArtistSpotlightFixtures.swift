#if DEBUG
import Foundation

// Synthetic recordings and prose exercise the live matching/classification path without public services.
// DebugBootstrap can select this provider for both catalog and lyrics with --artist-spotlight-fixture.
enum ArtistSpotlightFixtures {
    static let artist = ArtistCredit(name: "A. R. Rahman", id: "UCfixtureARRahman0000001")
    static let hindiID = "fixture.spotlight.hindi"
    static let secondHindiID = "fixture.spotlight.hindi.second"
    static let tamilID = "fixture.spotlight.tamil"
    static let teluguID = "fixture.spotlight.telugu"
    static let englishID = "fixture.spotlight.english"
    static let unknownID = "fixture.spotlight.unknown"

    static let hindiText = """
    सुबह की हल्की हवा हमारे छोटे घर की खिड़की से भीतर आती है। आकाश में बादल धीरे धीरे चलते हैं और बच्चे खुले मैदान में खेलते हैं।
    हम अपने दोस्तों के साथ नदी के किनारे बैठकर आज की यात्रा के बारे में बातें करते हैं। शाम होने पर सभी लोग घर लौटते हैं और मिलकर गरम खाना बनाते हैं।
    """
    static let tamilText = """
    காலை நேரத்தில் எங்கள் வீட்டின் அருகே இருக்கும் சிறிய தோட்டத்தில் பல வண்ண மலர்கள் மலர்கின்றன. குழந்தைகள் நண்பர்களுடன் மகிழ்ச்சியாக விளையாடுகின்றனர்.
    நாங்கள் அனைவரும் மரத்தின் நிழலில் அமர்ந்து புதிய கதைகளைப் பேசுகிறோம். மென்மையான காற்று ஜன்னல் வழியாக உள்ளே வந்து அறையை குளிர்விக்கிறது. மாலை நேரத்தில் குடும்பத்தினர் ஒன்றாக உணவு சமைத்து நாளைய பயணத்தைப் பற்றி பேசுகின்றனர்.
    """
    static let teluguText = """
    ఉదయం మా ఇంటి పక్కన ఉన్న చిన్న తోటలో రంగురంగుల పూలు వికసిస్తాయి. పిల్లలు తమ స్నేహితులతో ఆనందంగా ఆడుకుంటారు.
    మేము అందరం చెట్టు నీడలో కూర్చుని కొత్త కథలు చెప్పుకుంటాము. చల్లని గాలి కిటికీ గుండా లోపలికి వచ్చి గదిని చల్లబరుస్తుంది. సాయంత్రం కుటుంబ సభ్యులు కలిసి వంట చేసి రేపటి ప్రయాణం గురించి మాట్లాడుకుంటారు.
    """
    static let englishText = """
    When we leave the house, the morning air carries the sound of birds through the open windows. Our friends are waiting by the garden, and they have brought their books with them.
    We will walk together along the river, where the trees give shade and the water moves slowly. There are many stories that we could share before the sun goes down. After our walk we will return to the house, where we can cook dinner with our friends and talk about what we have seen through the day.
    """
    static let bengaliText = """
    সকালে আমাদের ছোট বাড়ির জানালা দিয়ে মৃদু বাতাস ঘরে আসে। আকাশে সাদা মেঘ ধীরে ধীরে ভেসে যায় এবং শিশুরা মাঠে খেলতে থাকে।
    আমরা বন্ধুদের সঙ্গে নদীর ধারে বসে নতুন গল্প বলি। বাগানের গাছে পাখিরা গান গায়। সন্ধ্যা হলে সবাই বাড়ি ফিরে একসঙ্গে খাবার তৈরি করে এবং পরের দিনের ভ্রমণ নিয়ে কথা বলে।
    """

    static var tracks: [Track] {
        [track(englishID, "Open Sky", count: 200), track(unknownID, "Unwritten", count: nil),
         track(secondHindiID, "River Lights", count: 400), track(teluguID, "Evening Courtyard", count: 600),
         track(hindiID, "Morning Windows", count: 800), track(tamilID, "Garden Paths", count: 1_200)]
            + (0..<14).map { track("fixture.spotlight.extra.\($0)", "Unclassified recording \($0 + 1)", count: Int64(100 - $0)) }
    }

    static var page: ArtistPage {
        ArtistPage(id: artist.id!, name: artist.name, topSongs: tracks,
                   monthlyAudience: .init(value: 12_300_000, label: "12.3M monthly audience", kind: .audience, source: .headerCount))
    }

    static func text(for id: String) -> String? {
        switch id {
        case hindiID, secondHindiID: hindiText
        case tamilID: tamilText
        case teluguID: teluguText
        case englishID: englishText
        case unknownID: "nayi subah mere dil ki baat"
        default: nil
        }
    }

    private static func track(_ id: String, _ title: String, count: Int64?) -> Track {
        Track(id: id, title: title, credits: [ArtistCredit(name: "Spotlight Fixture Singer"), artist],
              albumTitle: "Synthetic spotlight recordings", duration: 240, isAudioRecording: true, playCount: count)
    }
}

struct ArtistSpotlightFixtureProvider: MusicCatalogProviding, LyricsProviding {
    private let base = DebugMusicFixtures()
    private let matchedLyrics = LRCLyricsService(transport: ArtistSpotlightFixtureLyricsTransport())

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        let key = SearchRelevance.normalize(query)
        if key == SearchRelevance.normalize(ArtistSpotlightFixtures.artist.name) {
            if filter == .songs {
                return CatalogPage(tracks: ArtistSpotlightFixtures.tracks, featuredArtist: ArtistSpotlightFixtures.artist.collection)
            }
            if filter == .artists { return CatalogPage(collections: [ArtistSpotlightFixtures.artist.collection!]) }
        }
        if filter == .songs, let track = ArtistSpotlightFixtures.tracks.first(where: {
            key == SearchRelevance.normalize("\($0.title) \(ArtistSpotlightFixtures.artist.name)")
        }) { return CatalogPage(tracks: [track]) }
        return try await base.search(query: query, filter: filter, continuation: continuation)
    }

    func artist(id: String) async throws -> ArtistPage {
        if id == ArtistSpotlightFixtures.artist.id { return ArtistSpotlightFixtures.page }
        return try await base.artist(id: id)
    }

    func browse(id: String) async throws -> CatalogPage {
        if id == ArtistSpotlightFixtures.artist.id {
            return CatalogPage(tracks: ArtistSpotlightFixtures.tracks, title: ArtistSpotlightFixtures.artist.name)
        }
        return try await base.browse(id: id)
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await base.recommendations(seed: seed, language: language)
    }

    func radio(seed: Track) async throws -> [Track] { try await base.radio(seed: seed) }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        try await base.discovery(languages: languages)
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        guard ArtistSpotlightFixtures.text(for: track.id) != nil else {
            return LyricsDocument(trackID: track.id, kind: .unavailable, source: "Synthetic spotlight fixture")
        }
        return try await matchedLyrics.lyrics(for: track)
    }
}

private actor ArtistSpotlightFixtureLyricsTransport: LRCHTTPTransport {
    func send(_ request: URLRequest) async throws -> LRCHTTPResponse {
        try Task.checkCancellation()
        let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "track_name" }?.value
        guard let index = ArtistSpotlightFixtures.tracks.firstIndex(where: { $0.title == title }),
              let text = ArtistSpotlightFixtures.text(for: ArtistSpotlightFixtures.tracks[index].id) else {
            return LRCHTTPResponse(statusCode: 404)
        }
        let track = ArtistSpotlightFixtures.tracks[index]
        let record: [String: Any] = ["id": 90_000 + index, "trackName": track.title, "artistName": track.artistName,
                                      "albumName": track.albumTitle!, "duration": track.duration!,
                                      "instrumental": false, "plainLyrics": text]
        let object: Any = request.url?.path == "/api/search" ? [record] : record
        return LRCHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
}
#endif
