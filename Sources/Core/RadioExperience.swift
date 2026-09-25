import Foundation

/// Station intent, not a catalog playlist. Songs and their identifiers are resolved when the listener taps.
struct RadioExperience: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let symbol: String
    let group: Group
    // Hand-picked cues, tagged by the languages that activate them. Every station also searches by wording.
    let variants: [Variant]
    // Search wording per language. Stations are genre or mood intent, so any non-empty language set can start one.
    let queryTemplates: [MusicLanguage: [String]]
    let tone: Tone
    // Presentation order inside its group only; this is not a catalog popularity ranking.
    let discoveryRank: Int
    let defaultEra: RadioEra
    let sourceStationID: String?
    let artistHints: [ArtistCredit]

    var radioTitle: String { "\(title) Radio" }
    var stationID: String { sourceStationID ?? id }
    var seeds: [Seed] { Self.interleaved(variants.map(\.seeds)) }
    var styleQueries: [String] { selection(for: Set(MusicLanguage.allCases))?.styleQueries ?? [] }
    /// Languages with hand-picked cues. Discovery lists every station regardless.
    var cueLanguages: Set<MusicLanguage> { variants.reduce(into: []) { $0.formUnion($1.discoveryLanguages) } }

    enum Tone: Hashable, Sendable { case warm, cool }

    enum Group: String, CaseIterable, Hashable, Identifiable, Sendable {
        case moods, genres

        var id: String { rawValue }
        var title: String {
            switch self {
            case .moods: "Moods"
            case .genres: "Genres"
            }
        }
        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

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
         styleQueries: [String] = [], artistHints: [ArtistCredit] = [], group: Group = .moods,
         queryTemplates: [MusicLanguage: [String]] = [:]) {
        self.init(id: id, title: title, description: description, symbol: symbol, group: group,
                  variants: [Variant(id: "default", discoveryLanguages: discoveryLanguages, contentLabel: contentLabel,
                                     seeds: seeds, styleQueries: styleQueries)],
                  queryTemplates: queryTemplates, tone: tone, discoveryRank: discoveryRank, defaultEra: defaultEra,
                  sourceStationID: sourceStationID, artistHints: artistHints)
    }

    init(id: String, title: String, description: String, symbol: String, group: Group, variants: [Variant],
         queryTemplates: [MusicLanguage: [String]] = [:], tone: Tone = .cool, discoveryRank: Int = 100,
         defaultEra: RadioEra = .anytime, sourceStationID: String? = nil, artistHints: [ArtistCredit] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.symbol = symbol
        self.group = group
        self.variants = variants
        self.queryTemplates = queryTemplates
        self.tone = tone
        self.discoveryRank = discoveryRank
        self.defaultEra = defaultEra
        self.sourceStationID = sourceStationID
        self.artistHints = artistHints
    }

    /// Nil only for an empty language set. Cues follow their tags; wording is interleaved across the chosen languages.
    func selection(for languages: Set<MusicLanguage>) -> Selection? {
        let chosen = MusicLanguage.allCases.filter(languages.contains)
        guard !chosen.isEmpty else { return nil }
        let groups = variants.filter { !$0.discoveryLanguages.isDisjoint(with: languages) }
        var labels: [String] = []
        for language in chosen {
            let tagged = groups.filter { $0.discoveryLanguages.contains(language) }.map(\.contentLabel)
            for label in (tagged.isEmpty ? [language.title] : tagged) where !labels.contains(label) { labels.append(label) }
        }
        var label = labels.joined(separator: " + ")
        if sourceStationID != nil {
            label += " · \(defaultEra.title)"
            if !artistHints.isEmpty { label += " · \(artistHints.count) artist \(artistHints.count == 1 ? "hint" : "hints")" }
        }
        return Selection(seeds: Self.interleaved(groups.map(\.seeds)),
                         description: groups.count == 1 ? groups[0].description ?? description : description,
                         contentLabel: label, styleQueries: Self.interleaved(chosen.map { styleQueries(for: $0) }))
    }

    func selection(for profile: ListeningLanguageProfile) -> Selection {
        let cueLanguage: MusicLanguage? = switch profile.orderedLanguages.first {
        case .hindi: .hindi
        case .english: .english
        default: nil
        }
        // Cues target the dominant language only; missing coverage must reach style discovery before radio can succeed.
        // These tags select search intents, never evidence about the returned recordings.
        let groups = cueLanguage.map { language in variants.filter { $0.discoveryLanguages.contains(language) } } ?? []
        var queries: [String] = []
        for language in profile.scheduledLanguages(count: 3) {
            if let query = automaticStyleQueries(for: language).first(where: { !queries.contains($0) }) {
                queries.append(query)
            }
        }
        var label = profile.isLearned ? "Follows your listening" : "Automatic discovery"
        if sourceStationID != nil {
            label += " · \(defaultEra.title)"
            if !artistHints.isEmpty { label += " · \(artistHints.count) artist \(artistHints.count == 1 ? "hint" : "hints")" }
        }
        return Selection(seeds: Self.interleaved(groups.map(\.seeds)), description: description,
                         contentLabel: label, styleQueries: queries)
    }

    private func automaticStyleQueries(for language: ArtistSongLanguage) -> [String] {
        let curated: [String] = switch language {
        case .hindi: styleQueries(for: MusicLanguage.hindi)
        case .english: styleQueries(for: MusicLanguage.english)
        case .bengali, .tamil, .telugu: []
        }
        return curated + Self.synthesizedQueries(title: title, languageTitle: language.title)
            + ["\(title.lowercased()) songs in \(language.title)"]
    }

    /// Curated wording first, then templates. A station with wording in any language gets synthesized wording for the
    /// rest, so a newly added language can start every station; a cue-only station stays cue-only.
    func styleQueries(for language: MusicLanguage) -> [String] {
        let curated = variants.filter { $0.discoveryLanguages.contains(language) }.flatMap(\.styleQueries)
        var seen = Set<String>()
        let queries = (curated + (queryTemplates[language] ?? [])).filter { seen.insert($0).inserted }
        if !queries.isEmpty { return queries }
        let hasWording = !queryTemplates.values.allSatisfy(\.isEmpty) || variants.contains { !$0.styleQueries.isEmpty }
        return hasWording ? Self.synthesizedQueries(title: title, language: language) : []
    }

    static func synthesizedQueries(title: String, language: MusicLanguage) -> [String] {
        synthesizedQueries(title: title, languageTitle: language.title)
    }

    private static func synthesizedQueries(title: String, languageTitle: String) -> [String] {
        let mood = title.lowercased()
        return ["\(languageTitle) \(mood) songs", "\(mood) \(languageTitle) music"]
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

    // MARK: Catalog

    private static func station(_ id: String, _ title: String, group: Group, description: String, symbol: String,
                                tone: Tone = .cool, rank: Int = 100, era: RadioEra = .anytime,
                                hindi: [String], english: [String], variants: [Variant] = []) -> RadioExperience {
        RadioExperience(id: id, title: title, description: description, symbol: symbol, group: group, variants: variants,
                        queryTemplates: [.hindi: hindi, .english: english], tone: tone, discoveryRank: rank, defaultEra: era)
    }

    private static func cues(_ id: String, _ languages: Set<MusicLanguage>, label: String, description: String? = nil,
                             _ seeds: [Seed]) -> Variant {
        Variant(id: id, discoveryLanguages: languages, contentLabel: label, description: description, seeds: seeds)
    }

    // Ids are stable keys for saved sessions and debug fixtures; retitle freely, never rename an id.
    static let stations: [RadioExperience] = [
        station("melancholy", "Melancholy", group: .moods,
                description: "Hazy guitars and a little ache. Slow songs for grey hours.", symbol: "cloud.moon", rank: 0,
                hindi: ["Hindi sad songs", "Bollywood melancholy songs", "sad Hindi acoustic songs"],
                english: ["melancholy indie sad songs", "sad slow english songs", "melancholy dream pop shoegaze songs"],
                variants: [cues("english", [.english], label: "English", [
                    Seed("Apocalypse", by: "Cigarettes After Sex", year: 2017,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Apocalypse_(Cigarettes_After_Sex_song)")),
                    Seed("Where Is My Mind?", by: "Pixies", year: 1988,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Where_Is_My_Mind%3F")),
                    Seed("No Surprises", by: "Radiohead", year: 1997,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/OK_Computer")),
                    Seed("Fade Into You", by: "Mazzy Star", year: 1993,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Fade_into_You")),
                ])]),
        station("hindi-gym", "Workout", group: .moods,
                description: "Big drums and a faster pulse. Songs that push a set.",
                symbol: "figure.strengthtraining.traditional", tone: .warm, rank: 1,
                hindi: ["Hindi workout motivation songs", "Punjabi gym hip hop songs", "Bollywood gym songs"],
                english: ["workout motivation songs", "gym hip hop english songs", "high energy running songs"],
                variants: [cues("hindi", [.hindi], label: "Hindi + Punjabi", [
                    Seed("Zinda", by: "Siddharth Mahadevan", album: "Bhaag Milkha Bhaag"),
                    Seed("G.O.A.T.", by: "Diljit Dosanjh"),
                    Seed("Sultan", by: "Sukhwinder Singh", album: "Sultan"),
                    Seed("Brown Munde", by: "AP Dhillon"),
                ])]),
        station("late-night-hindi", "Late night", group: .moods,
                description: "Quiet songs for the ride home.", symbol: "moon.stars",
                hindi: ["quiet Hindi late night songs", "Hindi acoustic romantic songs", "soft Bollywood night songs"],
                english: ["late night chill songs", "quiet english songs for night drives", "mellow midnight indie songs"],
                variants: [cues("hindi", [.hindi], label: "Hindi", [
                    Seed("Iktara", by: "Kavita Seth"),
                    Seed("Saibo", by: "Shreya Ghoshal"),
                    Seed("Phir Le Aya Dil (Reprise)", by: "Arijit Singh"),
                    Seed("Agar Tum Saath Ho", by: "Alka Yagnik"),
                ])]),
        station("easy-morning", "Easy morning", group: .moods,
                description: "Warm, unhurried songs for a slow start.", symbol: "sun.horizon", tone: .warm,
                hindi: ["Hindi morning songs", "soft Bollywood songs for morning", "Hindi acoustic feel good songs"],
                english: ["warm soul easy morning songs", "mellow soft rock morning songs", "feel good acoustic morning songs"],
                variants: [cues("english", [.english], label: "English", [
                    Seed("Lovely Day", by: "Bill Withers"),
                    Seed("Sir Duke", by: "Stevie Wonder"),
                    Seed("Put Your Records On", by: "Corinne Bailey Rae"),
                    Seed("Dreams", by: "Fleetwood Mac"),
                ])]),
        station("feel-good", "Feel good", group: .moods,
                description: "Bright, easy songs that lift the room.", symbol: "face.smiling", tone: .warm,
                hindi: ["Hindi feel good songs", "happy Bollywood songs", "upbeat Hindi songs"],
                english: ["feel good english songs", "happy upbeat pop songs", "good mood indie pop songs"]),
        station("focus", "Focus", group: .moods,
                description: "Steady, low-key music for work or study.", symbol: "brain",
                hindi: ["Hindi instrumental focus music", "calm Hindi songs for studying", "Bollywood lofi study songs"],
                english: ["focus music instrumental", "deep focus ambient songs", "lofi study beats"]),
        station("party", "Party", group: .moods,
                description: "Loud, fast and made for a crowd.", symbol: "party.popper", tone: .warm,
                hindi: ["Bollywood party songs", "Hindi dance party hits", "Punjabi party songs"],
                english: ["party hits english songs", "dance party anthems", "club party pop songs"]),
        station("romance", "Romance", group: .moods,
                description: "Love songs, from first glance to slow dance.", symbol: "heart", tone: .warm,
                hindi: ["Hindi romantic songs", "Bollywood love songs", "romantic Hindi duets"],
                english: ["romantic english songs", "love songs pop", "slow dance love songs"]),
        station("heartbreak", "Heartbreak", group: .moods,
                description: "For the nights it still stings.", symbol: "heart.slash",
                hindi: ["Hindi heartbreak songs", "Bollywood breakup songs", "sad Hindi love songs"],
                english: ["heartbreak songs english", "breakup songs pop", "sad love songs acoustic"]),
        station("punjabi-drive", "Road trip", group: .moods,
                description: "Windows down, bass up, miles to go.", symbol: "car.side", tone: .warm,
                hindi: ["Punjabi driving hip hop songs", "Bollywood road trip songs", "Hindi long drive songs"],
                english: ["road trip songs english", "driving playlist rock pop", "highway songs indie"],
                variants: [cues("hindi", [.hindi], label: "Punjabi", [
                    Seed("Lover", by: "Diljit Dosanjh"),
                    Seed("Softly", by: "Karan Aujla"),
                    Seed("We Rollin", by: "Shubh"),
                    Seed("Excuses", by: "AP Dhillon"),
                ])]),
        station("rainy-day", "Rainy day", group: .moods,
                description: "Soft songs for a window seat and a warm cup.", symbol: "cloud.rain",
                hindi: ["Hindi rainy day songs", "Bollywood monsoon songs", "Hindi baarish songs"],
                english: ["rainy day songs english", "cozy rainy day acoustic songs", "mellow rainy day indie"]),
        station("devotional", "Devotional", group: .moods,
                description: "Bhajans, hymns and songs of quiet faith.", symbol: "hands.sparkles", tone: .warm,
                hindi: ["Hindi devotional songs", "bhajan songs", "Hindi bhakti songs"],
                english: ["devotional songs english", "gospel worship songs", "spiritual hymns songs"]),
        station("left-field-rap", "Rap and hip hop", group: .genres,
                description: "Sharp bars and heavy beats, from the underground to the charts.", symbol: "waveform",
                hindi: ["Hindi rap songs", "desi hip hop songs", "Hindi alternative hip hop songs"],
                english: ["hip hop songs", "rap hits english", "alternative hip hop experimental rap songs"],
                variants: [
                    cues("english", [.english], label: "English",
                         description: "Big beats and sharper bars. Kanye West and Tyler, The Creator.", [
                            Seed("Flashing Lights", by: "Kanye West"),
                            Seed("EARFQUAKE", by: "Tyler, The Creator"),
                         ]),
                    cues("hindi", [.hindi], label: "Hindi",
                         description: "Desi hip hop with bite. Char Diwaari and Seedhe Maut.", [
                            Seed("Jhaag", by: "Char Diwaari"),
                            Seed("Nanchaku", by: "Seedhe Maut"),
                         ]),
                ]),
        station("rock", "Rock", group: .genres,
                description: "Riffs, drums and choruses built for volume.", symbol: "guitars.fill", tone: .warm,
                hindi: ["Hindi rock songs", "Bollywood rock songs", "Indian rock band Hindi songs"],
                english: ["rock songs", "classic rock hits", "modern rock anthems"]),
        station("alt-rock", "Alt rock", group: .genres,
                description: "Restless guitars and loud choruses.", symbol: "bolt",
                hindi: ["Hindi alternative rock songs", "Indian indie rock Hindi songs", "Hindi grunge rock songs"],
                english: ["alternative rock guitar songs", "indie rock anthems songs", "90s alternative rock songs"],
                variants: [cues("english", [.english], label: "English", [
                    Seed("Paranoid Android", by: "Radiohead"),
                    Seed("Debaser", by: "Pixies"),
                    Seed("Reptilia", by: "The Strokes"),
                    Seed("Everlong", by: "Foo Fighters"),
                ])]),
        station("indian-indie", "Indie", group: .genres,
                description: "Guitars and close-to-home stories.", symbol: "guitars",
                hindi: ["Hindi independent acoustic songs", "Indian indie guitar songs", "Hindi indie pop songs"],
                english: ["indie songs", "indie folk pop songs", "bedroom pop indie songs"],
                variants: [cues("hindi", [.hindi], label: "Hindi indie", [
                    Seed("Aaoge Tum Kabhi", by: "The Local Train"),
                    Seed("Baarishein", by: "Anuv Jain"),
                    Seed("Kasoor", by: "Prateek Kuhad"),
                    Seed("Khoj (Passing By)", by: "When Chai Met Toast"),
                ])]),
        station("pop", "Pop", group: .genres,
                description: "Hooks first. The songs everyone hums.", symbol: "sparkles", tone: .warm,
                hindi: ["Hindi pop songs", "Bollywood pop hits", "Indian pop songs"],
                english: ["pop hits english", "top pop songs", "pop anthems"]),
        station("rnb-soul", "R&B and soul", group: .genres,
                description: "Smooth vocals and slow grooves.", symbol: "music.mic", tone: .warm,
                hindi: ["Hindi R&B songs", "Indian soul R&B songs", "Hindi smooth groove songs"],
                english: ["r&b songs", "soul music classics", "neo soul songs"]),
        station("dance-edm", "Dance and EDM", group: .genres,
                description: "Drops, builds and four on the floor.", symbol: "speaker.wave.3", tone: .warm,
                hindi: ["Bollywood EDM songs", "Hindi dance songs", "Indian EDM songs"],
                english: ["edm songs", "dance hits", "house music songs"]),
        station("lofi", "Lo-fi", group: .genres,
                description: "Dusty beats and low lights.", symbol: "moon.zzz",
                hindi: ["Hindi lofi songs", "Bollywood lofi", "Hindi lofi chill"],
                english: ["lofi hip hop beats", "lofi chill songs", "chillhop lofi"]),
        station("acoustic", "Acoustic", group: .genres,
                description: "Wood, strings and a voice up close.", symbol: "music.quarternote.3",
                hindi: ["Hindi acoustic songs", "Bollywood unplugged songs", "Hindi acoustic cover songs"],
                english: ["acoustic songs", "acoustic guitar singer songwriter", "unplugged acoustic sessions"]),
        station("jazz", "Jazz", group: .genres,
                description: "Swing, blue notes and late sets.", symbol: "music.note.list", tone: .warm,
                hindi: ["Hindi jazz songs", "Bollywood jazz", "Indian jazz fusion songs"],
                english: ["jazz standards", "smooth jazz songs", "jazz vocal classics"]),
        station("classical", "Classical and instrumental", group: .genres,
                description: "Orchestras, ragas and instruments without words.", symbol: "pianokeys",
                hindi: ["Hindustani classical music", "Indian classical instrumental", "Hindi classical vocal ragas"],
                english: ["classical music", "orchestral instrumental music", "piano classical pieces"]),
        station("folk", "Folk", group: .genres,
                description: "Old roads, new voices, songs handed down.", symbol: "leaf", tone: .warm,
                hindi: ["Hindi folk songs", "Indian folk songs", "Rajasthani folk songs"],
                english: ["folk songs", "indie folk acoustic", "folk revival songs"]),
        station("sufi", "Sufi", group: .genres,
                description: "Devotion with a heartbeat. Sufi verses set to music.", symbol: "flame", tone: .warm,
                hindi: ["Sufi songs Hindi", "Bollywood Sufi songs", "Sufi music"],
                english: ["sufi music", "sufi fusion songs", "sufi rock songs"]),
        station("ghazal", "Ghazal", group: .genres,
                description: "Poetry sung slowly, every word weighed.", symbol: "text.book.closed",
                hindi: ["ghazal songs", "Hindi Urdu ghazals", "classic ghazal"],
                english: ["ghazal music", "modern ghazal fusion", "ghazal classics"]),
        station("qawwali", "Qawwali", group: .genres,
                description: "Handclaps, harmonium and voices that climb.", symbol: "hands.clap", tone: .warm,
                hindi: ["qawwali songs", "Bollywood qawwali", "Hindi qawwali"],
                english: ["qawwali music", "qawwali live performance songs", "sufi qawwali"]),
        station("punjabi-hits", "Punjabi hits", group: .genres,
                description: "Bhangra bounce and the newest Punjabi bangers.", symbol: "crown", tone: .warm,
                hindi: ["Punjabi hits", "latest Punjabi songs", "Punjabi bhangra songs"],
                english: ["Punjabi pop hits", "desi hip hop Punjabi songs", "Punjabi english mix songs"]),
        station("hindi-classics", "Bollywood classics", group: .genres,
                description: "Golden-era film songs. Lata, Kishore, Mukesh and Rafi.", symbol: "radio", tone: .warm, era: .older,
                hindi: ["Hindi golden era film songs", "classic Hindi romantic songs", "old Bollywood songs"],
                english: ["old Bollywood classic songs", "evergreen Bollywood songs", "vintage Hindi film songs"],
                variants: [cues("hindi", [.hindi], label: "Hindi", [
                    Seed("Lag Ja Gale Se Phir", by: "Lata Mangeshkar", year: 1964,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Woh_Kaun_Thi%3F")),
                    Seed("Yeh Sham Mastani", by: "Kishore Kumar", year: 1970,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Kati_Patang")),
                    Seed("Kabhi Kabhie Mere Dil Mein", by: "Mukesh", year: 1976,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Kabhi_Kabhie")),
                    Seed("Chaudhvin Ka Chand Ho", by: "Mohammed Rafi", year: 1960,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Chaudhvin_Ka_Chand")),
                ])]),
        station("english-golden-oldies", "Golden oldies", group: .genres,
                description: "Familiar favorites from the 50s, 60s and 70s.", symbol: "record.circle", tone: .warm, era: .older,
                hindi: ["old Hindi golden songs", "purane Hindi gaane", "Hindi retro hits"],
                english: ["English golden oldies pop soul songs", "classic crooners soft rock songs", "60s and 70s hits"],
                variants: [cues("english", [.english], label: "English", [
                    Seed("Here Comes The Sun", by: "The Beatles", year: 1969,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Here_Comes_the_Sun")),
                    Seed("Can't Help Falling in Love", by: "Elvis Presley", year: 1961,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Can%27t_Help_Falling_in_Love")),
                    Seed("Fly Me To The Moon (In Other Words)", by: "Frank Sinatra", year: 1964,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Fly_Me_to_the_Moon")),
                    Seed("Stand By Me", by: "Ben E. King", year: 1961,
                         yearSource: URL(string: "https://en.wikipedia.org/wiki/Stand_by_Me_(Ben_E._King_song)")),
                ])]),
        station("metal", "Metal", group: .genres,
                description: "Heavy, fast and unapologetic.", symbol: "bolt.fill",
                hindi: ["Hindi metal songs", "Indian metal bands", "Bollywood rock metal songs"],
                english: ["metal songs", "heavy metal classics", "metalcore songs"]),
        station("country", "Country", group: .genres,
                description: "Steel guitars, open roads and plain talk.", symbol: "sun.dust", tone: .warm,
                hindi: ["Hindi country style songs", "Indian folk country songs", "Hindi acoustic country songs"],
                english: ["country songs", "country music hits", "modern country songs"]),
        station("reggae", "Reggae", group: .genres,
                description: "Offbeat, warm and easy.", symbol: "sun.max", tone: .warm,
                hindi: ["Hindi reggae songs", "Bollywood reggae", "Indian reggae fusion songs"],
                english: ["reggae songs", "reggae classics", "reggae dancehall songs"]),
        station("nineties", "90s", group: .genres,
                description: "The decade of Walkmans and cassette mixes.", symbol: "clock.arrow.circlepath",
                hindi: ["90s Hindi songs", "90s Bollywood hits", "90s Hindi romantic songs"],
                english: ["90s hits", "90s pop rock songs", "90s alternative songs"]),
    ]

    static var discoveryStations: [RadioExperience] {
        stations.enumerated().sorted { left, right in
            if left.element.group != right.element.group { return left.element.group.order < right.element.group.order }
            if left.element.discoveryRank != right.element.discoveryRank {
                return left.element.discoveryRank < right.element.discoveryRank
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}
