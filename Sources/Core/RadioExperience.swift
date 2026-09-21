import Foundation

/// Station intent, not a catalog playlist. Songs and their identifiers are resolved when the listener taps.
struct RadioExperience: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let symbol: String
    // Audience tags control discovery, never a recording's language classification.
    let discoveryLanguages: Set<MusicLanguage>
    let variants: [Variant]
    let tone: Tone
    // Presentation order only; this is not a catalog popularity ranking.
    let discoveryRank: Int
    let defaultEra: RadioEra
    let sourceStationID: String?
    let artistHints: [ArtistCredit]

    var radioTitle: String { "\(title) Radio" }
    var stationID: String { sourceStationID ?? id }
    var seeds: [Seed] { Self.interleaved(variants.map(\.seeds)) }
    var styleQueries: [String] { Self.interleaved(variants.map(\.styleQueries)) }

    enum Tone: Hashable, Sendable { case warm, cool }

    // Add a tagged variant or station when the catalog supports another language; the pipeline stays shared.
    struct Variant: Hashable, Sendable {
        let id: String
        let discoveryLanguages: Set<MusicLanguage>
        let contentLabel: String
        let description: String?
        let seeds: [Seed]
        let styleQueries: [String]

        init(id: String, discoveryLanguages: Set<MusicLanguage>, contentLabel: String,
             description: String? = nil, seeds: [Seed], styleQueries: [String] = []) {
            self.id = id
            self.discoveryLanguages = discoveryLanguages
            self.contentLabel = contentLabel
            self.description = description
            self.seeds = seeds
            self.styleQueries = styleQueries
        }
    }

    struct Selection: Hashable, Sendable {
        let seeds: [Seed]
        let description: String
        let contentLabel: String
        let styleQueries: [String]
    }

    init(id: String, title: String, description: String, symbol: String,
         discoveryLanguages: Set<MusicLanguage>, contentLabel: String, seeds: [Seed], tone: Tone = .cool, discoveryRank: Int = 100,
          defaultEra: RadioEra = .anytime, sourceStationID: String? = nil,
          styleQueries: [String] = [], artistHints: [ArtistCredit] = []) {
        self.init(id: id, title: title, description: description, symbol: symbol, discoveryLanguages: discoveryLanguages,
                  variants: [Variant(id: "default", discoveryLanguages: discoveryLanguages, contentLabel: contentLabel,
                                     seeds: seeds, styleQueries: styleQueries)],
                  tone: tone, discoveryRank: discoveryRank, defaultEra: defaultEra,
                  sourceStationID: sourceStationID, artistHints: artistHints)
    }

    init(id: String, title: String, description: String, symbol: String,
         discoveryLanguages: Set<MusicLanguage>, variants: [Variant], tone: Tone = .cool, discoveryRank: Int = 100,
          defaultEra: RadioEra = .anytime, sourceStationID: String? = nil, artistHints: [ArtistCredit] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.symbol = symbol
        self.discoveryLanguages = discoveryLanguages
        self.variants = variants
        self.tone = tone
        self.discoveryRank = discoveryRank
        self.defaultEra = defaultEra
        self.sourceStationID = sourceStationID
        self.artistHints = artistHints
    }

    func selection(for languages: Set<MusicLanguage>) -> Selection? {
        let audience = discoveryLanguages.intersection(languages)
        let groups = variants.filter { !$0.discoveryLanguages.isDisjoint(with: audience) }
        guard !groups.isEmpty else { return nil }
        let seeds = Self.interleaved(groups.map(\.seeds))
        var labels = Set<String>()
        var label = groups.map(\.contentLabel).filter { labels.insert($0).inserted }.joined(separator: " + ")
        if sourceStationID != nil {
            label += " · \(defaultEra.title)"
            if !artistHints.isEmpty { label += " · \(artistHints.count) artist \(artistHints.count == 1 ? "hint" : "hints")" }
        }
        return Selection(seeds: seeds, description: groups.count == 1 ? groups[0].description ?? description : description,
                         contentLabel: label, styleQueries: Self.interleaved(groups.map(\.styleQueries)))
    }

    private static func interleaved<Value: Hashable>(_ groups: [[Value]]) -> [Value] {
        var values: [Value] = []
        var seen = Set<Value>()
        for rank in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(rank) {
                let value = group[rank]
                if seen.insert(value).inserted { values.append(value) }
            }
        }
        return values
    }

    struct Seed: Hashable, Sendable {
        let title: String
        let artist: ArtistCredit
        var album: String? = nil
        let year: Int?
        let yearSource: URL?
        let recording: Track?

        var query: String { ([title, artist.name] + [album].compactMap { $0 }).joined(separator: " ") }

        init(_ title: String, by artist: String, album: String? = nil, year: Int? = nil, yearSource: URL? = nil) {
            self.title = title
            self.artist = ArtistCredit(name: artist)
            self.album = album
            self.year = year
            self.yearSource = yearSource
            self.recording = nil
        }

        init(recording: Track, artist: ArtistCredit, year: Int? = nil, yearSource: URL? = nil) {
            self.title = recording.title
            self.artist = artist
            self.album = recording.albumTitle
            self.year = year
            self.yearSource = yearSource
            self.recording = recording
        }
    }

    // Registry order also identifies debug seed fixtures; display ordering must not change those indices.
    static let stations: [RadioExperience] = [
        RadioExperience(id: "melancholy", title: "Melancholy",
            description: "Hazy guitars, a little ache. Cigarettes After Sex and Pixies.",
            symbol: "cloud.moon", discoveryLanguages: [.english], contentLabel: "English", seeds: [
                Seed("Apocalypse", by: "Cigarettes After Sex", year: 2017,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Apocalypse_(Cigarettes_After_Sex_song)")),
                Seed("Where Is My Mind?", by: "Pixies", year: 1988,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Where_Is_My_Mind%3F")),
                Seed("No Surprises", by: "Radiohead", year: 1997,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/OK_Computer")),
                Seed("Fade Into You", by: "Mazzy Star", year: 1993,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Fade_into_You")),
            ], discoveryRank: 0, styleQueries: ["melancholy dream pop songs", "sad indie rock shoegaze songs"]),
        RadioExperience(id: "hindi-gym", title: "Hindi gym",
            description: "Zinda from Bhaag Milkha Bhaag, plus G.O.A.T. and Punjabi bounce.",
            symbol: "figure.strengthtraining.traditional", discoveryLanguages: [.hindi], contentLabel: "Hindi + Punjabi", seeds: [
                Seed("Zinda", by: "Siddharth Mahadevan", album: "Bhaag Milkha Bhaag"),
                Seed("G.O.A.T.", by: "Diljit Dosanjh"),
                Seed("Sultan", by: "Sukhwinder Singh", album: "Sultan"),
                Seed("Brown Munde", by: "AP Dhillon"),
            ], tone: .warm, discoveryRank: 1, styleQueries: ["Hindi workout motivation songs", "Punjabi gym hip hop songs"]),
        RadioExperience(id: "late-night-hindi", title: "Late-night Hindi",
            description: "Quiet songs for the ride home. Iktara, Saibo, Phir Le Aya Dil.",
            symbol: "moon.stars", discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [
                Seed("Iktara", by: "Kavita Seth"),
                Seed("Saibo", by: "Shreya Ghoshal"),
                Seed("Phir Le Aya Dil (Reprise)", by: "Arijit Singh"),
                Seed("Agar Tum Saath Ho", by: "Alka Yagnik"),
            ], styleQueries: ["quiet Hindi late night songs", "Hindi acoustic romantic songs"]),
        RadioExperience(id: "punjabi-drive", title: "Punjabi drive",
            description: "Bass up, windows down. Diljit Dosanjh, Karan Aujla, Shubh.",
            symbol: "car.side", discoveryLanguages: [.hindi], contentLabel: "Punjabi", seeds: [
                Seed("Lover", by: "Diljit Dosanjh"),
                Seed("Softly", by: "Karan Aujla"),
                Seed("We Rollin", by: "Shubh"),
                Seed("Excuses", by: "AP Dhillon"),
            ], tone: .warm, styleQueries: ["Punjabi driving hip hop songs", "Punjabi bass road trip songs"]),
        RadioExperience(id: "indian-indie", title: "Indian indie",
            description: "Guitars and close-to-home stories. The Local Train, Anuv Jain, Prateek Kuhad.",
            symbol: "guitars", discoveryLanguages: [.hindi], contentLabel: "Hindi indie", seeds: [
                Seed("Aaoge Tum Kabhi", by: "The Local Train"),
                Seed("Baarishein", by: "Anuv Jain"),
                Seed("Kasoor", by: "Prateek Kuhad"),
                Seed("Khoj (Passing By)", by: "When Chai Met Toast"),
            ], styleQueries: ["Hindi independent acoustic songs", "Indian indie guitar songs"]),
        RadioExperience(id: "alt-rock", title: "Alt rock",
            description: "Restless guitars, loud choruses. Radiohead, Pixies, The Strokes.",
            symbol: "bolt", discoveryLanguages: [.english], contentLabel: "English", seeds: [
                Seed("Paranoid Android", by: "Radiohead"),
                Seed("Debaser", by: "Pixies"),
                Seed("Reptilia", by: "The Strokes"),
                Seed("Everlong", by: "Foo Fighters"),
            ], styleQueries: ["alternative rock guitar songs", "indie rock anthems songs"]),
        RadioExperience(id: "easy-morning", title: "Easy morning",
            description: "Warm soul for a slow start. Lovely Day, Sir Duke, Put Your Records On.",
            symbol: "sun.horizon", discoveryLanguages: [.english], contentLabel: "English", seeds: [
                Seed("Lovely Day", by: "Bill Withers"),
                Seed("Sir Duke", by: "Stevie Wonder"),
                Seed("Put Your Records On", by: "Corinne Bailey Rae"),
                Seed("Dreams", by: "Fleetwood Mac"),
            ], tone: .warm, styleQueries: ["warm soul easy morning songs", "mellow soft rock morning songs"]),
        RadioExperience(id: "left-field-rap", title: "Left-field rap",
            description: "Off-kilter beats and big swings. Kanye West, Char Diwaari, Seedhe Maut.",
            symbol: "waveform", discoveryLanguages: [.english, .hindi], variants: [
                Variant(id: "english", discoveryLanguages: [.english], contentLabel: "English",
                        description: "Off-kilter beats and big swings. Kanye West and Tyler, The Creator.", seeds: [
                            Seed("Flashing Lights", by: "Kanye West"),
                             Seed("EARFQUAKE", by: "Tyler, The Creator"),
                         ], styleQueries: ["alternative hip hop experimental rap songs", "left field rap songs"]),
                Variant(id: "hindi", discoveryLanguages: [.hindi], contentLabel: "Hindi",
                        description: "Restless Indian rap. Char Diwaari and Seedhe Maut.", seeds: [
                            Seed("Jhaag", by: "Char Diwaari"),
                             Seed("Nanchaku", by: "Seedhe Maut"),
                         ], styleQueries: ["Hindi alternative hip hop songs", "Indian experimental rap songs"]),
            ]),
        RadioExperience(id: "hindi-classics", title: "Hindi classics",
            description: "Golden-era Hindi favorites. Lata, Kishore, Mukesh and Rafi.",
            symbol: "radio", discoveryLanguages: [.hindi], contentLabel: "Hindi", seeds: [
                Seed("Lag Ja Gale Se Phir", by: "Lata Mangeshkar", year: 1964,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Woh_Kaun_Thi%3F")),
                Seed("Yeh Sham Mastani", by: "Kishore Kumar", year: 1970,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Kati_Patang")),
                Seed("Kabhi Kabhie Mere Dil Mein", by: "Mukesh", year: 1976,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Kabhi_Kabhie")),
                Seed("Chaudhvin Ka Chand Ho", by: "Mohammed Rafi", year: 1960,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Chaudhvin_Ka_Chand")),
            ], tone: .warm, discoveryRank: 2, defaultEra: .older,
            styleQueries: ["Hindi golden era film songs", "classic Hindi romantic songs"]),
        RadioExperience(id: "english-golden-oldies", title: "English golden oldies",
            description: "Familiar ’60s favorites. The Beatles, Elvis Presley, Frank Sinatra.",
            symbol: "record.circle", discoveryLanguages: [.english], contentLabel: "English", seeds: [
                Seed("Here Comes The Sun", by: "The Beatles", year: 1969,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Here_Comes_the_Sun")),
                Seed("Can't Help Falling in Love", by: "Elvis Presley", year: 1961,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Can%27t_Help_Falling_in_Love")),
                Seed("Fly Me To The Moon (In Other Words)", by: "Frank Sinatra", year: 1964,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Fly_Me_to_the_Moon")),
                Seed("Stand By Me", by: "Ben E. King", year: 1961,
                     yearSource: URL(string: "https://en.wikipedia.org/wiki/Stand_by_Me_(Ben_E._King_song)")),
            ], tone: .warm, discoveryRank: 3, defaultEra: .older,
            styleQueries: ["English golden oldies pop soul songs", "classic crooners soft rock songs"]),
    ]

    static var discoveryStations: [RadioExperience] {
        stations.enumerated().sorted { left, right in
            if left.element.discoveryRank != right.element.discoveryRank {
                return left.element.discoveryRank < right.element.discoveryRank
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
