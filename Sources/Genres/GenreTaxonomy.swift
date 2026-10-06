import Foundation

/// Bounded genre families. They are the only genre dimension metrics may carry; MusicBrainz tags never leave the device.
enum GenreFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case bollywood, indiePop, pop, hipHop, rnb, rock, metal, electronic, dance, lofi, jazz, blues, classical
    case hindustani, carnatic, sufi, ghazal, devotional, punjabi, folk, country, kpop, latin, reggae, soundtrack
    case instrumental, acoustic, ambient, world

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bollywood: "Bollywood"
        case .indiePop: "Indie"
        case .pop: "Pop"
        case .hipHop: "Hip hop"
        case .rnb: "R&B and soul"
        case .rock: "Rock"
        case .metal: "Metal"
        case .electronic: "Electronic"
        case .dance: "Dance"
        case .lofi: "Lo-fi"
        case .jazz: "Jazz"
        case .blues: "Blues"
        case .classical: "Classical"
        case .hindustani: "Hindustani classical"
        case .carnatic: "Carnatic"
        case .sufi: "Sufi"
        case .ghazal: "Ghazal"
        case .devotional: "Devotional"
        case .punjabi: "Punjabi"
        case .folk: "Folk"
        case .country: "Country"
        case .kpop: "K-pop"
        case .latin: "Latin"
        case .reggae: "Reggae"
        case .soundtrack: "Soundtrack"
        case .instrumental: "Instrumental"
        case .acoustic: "Acoustic"
        case .ambient: "Ambient"
        case .world: "World"
        }
    }

    /// Stable presentation order for ties; `allCases` order is the taxonomy order, not a popularity ranking.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One MusicBrainz genre or tag vote as returned by the API: the tag name and its net vote count.
struct GenreVote: Equatable, Hashable, Sendable {
    var name: String
    var count: Int

    init(_ name: String, count: Int = 1) {
        self.name = name
        self.count = count
    }
}

enum GenreTaxonomy {
    /// Bump when the table changes meaning so cached distributions are rebuilt lazily within the usual budgets.
    static let version = 1

    /// Lowercases, folds diacritics and turns every punctuation run into one space: "Hip-Hop", "hip hop" and "HIP HOP" agree.
    static func normalize(_ tag: String) -> String {
        let folded = tag.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var result = ""
        var pendingSeparator = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append(" ") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return result
    }

    /// Nil for tags outside the table, including moods and eras such as "romantic", "sad", "party" and "90s".
    static func family(forTag tag: String) -> GenreFamily? {
        table[normalize(tag)]
    }

    /// Family weights from one source's votes: mapped counts (at least one each) summed per family and normalised.
    /// Nil when no vote maps to a family, so the caller can fall through to the next evidence source.
    static func distribution(votes: [GenreVote], source: GenreEvidenceSource) -> GenreDistribution? {
        var weights: [GenreFamily: Double] = [:]
        for vote in votes {
            guard let family = family(forTag: vote.name) else { continue }
            weights[family, default: 0] += Double(max(1, vote.count))
        }
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return nil }
        let ranked = weights.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.order < $1.key.order
        }.prefix(GenreDistribution.maximumFamilies)
        let kept = ranked.reduce(0) { $0 + $1.value }
        // The kept families are renormalised so one play always spreads one unit of weight across its families.
        return GenreDistribution(shares: ranked.map { GenreShare(family: $0.key, share: $0.value / kept) }, source: source)
    }

    // Keys are normalised tag names. Punctuation variants ("r&b", "lo-fi") are reached through `normalize`, so only
    // spellings that differ after normalisation ("hiphop", "rnb") need their own row.
    static let table: [String: GenreFamily] = {
        var table: [String: GenreFamily] = [:]
        func add(_ family: GenreFamily, _ names: [String]) {
            for name in names { table[normalize(name)] = family }
        }
        add(.bollywood, ["bollywood", "filmi", "filmi songs", "filmi music", "hindi film music", "hindi film", "hindi film song",
                         "hindi film soundtrack", "indian film music", "indian film song", "indian film soundtrack", "bollywood music",
                         "bollywood pop", "bollywood dance", "bollywood romantic", "bollywood item song", "item number", "tollywood",
                         "kollywood", "mollywood", "sandalwood", "bollywood instrumental", "old bollywood", "retro bollywood",
                         "hindi film classics", "bollywood classics"])
        add(.indiePop, ["indie", "indie pop", "indie rock", "indie folk", "indietronica", "indie electronic", "dream pop", "shoegaze",
                        "bedroom pop", "chamber pop", "twee pop", "jangle pop", "noise pop", "slowcore", "sadcore", "indian indie",
                        "hindi indie", "indie hindi", "indie soul", "lo fi indie", "indie surf", "indie punk"])
        add(.pop, ["pop", "pop rock", "synth pop", "synthpop", "electropop", "teen pop", "power pop", "europop", "britpop", "art pop",
                   "pop soul", "adult contemporary", "hindi pop", "indipop", "indi pop", "indian pop", "j pop", "jpop", "c pop", "cpop",
                   "mandopop", "cantopop", "bubblegum pop", "baroque pop", "sophisti pop", "sunshine pop", "pop ballad", "ballad",
                   "hyperpop", "easy listening", "vocal pop", "tamil pop", "telugu pop", "bengali pop", "urdu pop", "pakistani pop",
                   "contemporary pop", "mainstream pop"])
        add(.hipHop, ["hip hop", "hiphop", "hip hop rap", "rap", "trap", "drill", "uk drill", "desi hip hop", "indian hip hop",
                      "hindi rap", "hindi hip hop", "gangsta rap", "conscious hip hop", "alternative hip hop", "boom bap",
                      "east coast hip hop", "west coast hip hop", "southern hip hop", "cloud rap", "emo rap", "mumble rap", "grime",
                      "crunk", "hardcore hip hop", "underground hip hop", "experimental hip hop", "jazz rap", "pop rap", "melodic rap",
                      "phonk", "horrorcore", "abstract hip hop", "instrumental hip hop", "g funk", "dirty south", "chopped and screwed",
                      "afro trap", "rap rock", "old school hip hop", "urban", "urdu rap", "gully rap"])
        add(.rnb, ["r b", "rnb", "r and b", "rhythm and blues", "contemporary r b", "soul", "neo soul", "northern soul", "southern soul",
                   "quiet storm", "new jack swing", "funk", "motown", "alternative r b", "pbr b", "philly soul", "doo wop",
                   "urban contemporary", "blue eyed soul", "psychedelic soul", "trap soul", "soul pop", "modern soul", "deep soul"])
        add(.rock, ["rock", "alternative rock", "alternative", "alt rock", "hard rock", "grunge", "classic rock", "punk", "punk rock",
                    "post punk", "pop punk", "garage rock", "psychedelic rock", "progressive rock", "prog rock", "art rock", "glam rock",
                    "soft rock", "blues rock", "southern rock", "folk rock", "arena rock", "post grunge", "new wave", "emo", "post hardcore",
                    "hardcore punk", "noise rock", "math rock", "post rock", "stoner rock", "surf rock", "rockabilly", "roots rock",
                    "heartland rock", "indian rock", "hindi rock", "raga rock", "gothic rock", "industrial rock", "rock and roll",
                    "rock n roll", "krautrock", "space rock", "dance rock", "celtic rock", "alternative metal rock", "psychedelic",
                    "garage punk", "proto punk", "experimental rock"])
        add(.metal, ["metal", "heavy metal", "thrash metal", "death metal", "black metal", "doom metal", "power metal", "progressive metal",
                     "metalcore", "deathcore", "nu metal", "symphonic metal", "folk metal", "gothic metal", "industrial metal",
                     "speed metal", "groove metal", "sludge metal", "djent", "grindcore", "alternative metal", "glam metal",
                     "melodic death metal", "post metal", "stoner metal", "hair metal", "viking metal", "technical death metal",
                     "indian metal", "melodic metalcore"])
        add(.electronic, ["electronic", "electronica", "edm", "house", "deep house", "tech house", "progressive house", "electro house",
                          "future house", "tropical house", "techno", "minimal techno", "trance", "progressive trance", "psytrance",
                          "uplifting trance", "dubstep", "brostep", "drum and bass", "drum n bass", "dnb", "jungle", "breakbeat",
                          "big beat", "electro", "idm", "glitch", "downtempo", "trip hop", "future bass", "garage", "uk garage", "2 step",
                          "bass music", "hardstyle", "hardcore techno", "gabber", "synthwave", "vaporwave", "chillwave", "future garage",
                          "electro swing", "industrial", "ebm", "acid house", "chicago house", "detroit techno", "electronic dance music",
                          "moombahton", "nightcore", "slap house", "melodic dubstep", "funky house", "lo fi house", "progressive electronic",
                          "electronic rock", "bollywood edm", "indian electronic"])
        add(.dance, ["dance", "dance pop", "disco", "nu disco", "eurodance", "italo disco", "hi nrg", "post disco", "boogie", "club",
                     "club dance", "freestyle", "eurobeat", "disco house", "dance hits", "electro pop dance"])
        add(.lofi, ["lo fi", "lofi", "lo fi hip hop", "lofi hip hop", "chillhop", "chill hop", "lo fi beats", "lofi beats", "lo fi chill",
                    "lofi chill", "study beats", "jazzhop", "lo fi jazz", "bollywood lofi", "hindi lofi", "lofi remix"])
        add(.jazz, ["jazz", "smooth jazz", "bebop", "hard bop", "cool jazz", "swing", "big band", "free jazz", "jazz fusion", "fusion",
                    "vocal jazz", "latin jazz", "acid jazz", "nu jazz", "modal jazz", "post bop", "dixieland", "gypsy jazz", "jazz funk",
                    "avant garde jazz", "contemporary jazz", "soul jazz", "ragtime", "jazz blues", "indo jazz", "indian jazz",
                    "jazz standards", "jazz vocal"])
        add(.blues, ["blues", "delta blues", "chicago blues", "electric blues", "country blues", "acoustic blues", "texas blues",
                     "soul blues", "piedmont blues", "jump blues", "gospel blues", "swamp blues", "british blues", "modern blues"])
        add(.classical, ["classical", "western classical", "orchestral", "orchestra", "symphony", "symphonic", "baroque", "opera",
                         "chamber music", "choral", "piano", "classical piano", "contemporary classical", "modern classical",
                         "neoclassical", "neo classical", "minimalism", "early music", "renaissance", "medieval", "concerto", "sonata",
                         "string quartet", "classical crossover", "post minimalism", "classical music", "art song", "lied"])
        add(.hindustani, ["hindustani classical", "hindustani", "hindustani classical music", "khayal", "khyal", "thumri", "dhrupad",
                          "tappa", "tarana", "indian classical", "indian classical music", "north indian classical", "raga", "raag",
                          "sitar", "sarod", "bansuri", "tabla", "santoor", "dadra", "hori", "kajri", "chaiti", "semi classical",
                          "indian semi classical", "hindustani vocal", "sitar instrumental"])
        add(.carnatic, ["carnatic", "carnatic classical", "carnatic music", "south indian classical", "kriti", "varnam", "thillana",
                        "tillana", "padam", "javali", "ragam tanam pallavi", "veena", "nadaswaram", "mridangam", "carnatic fusion",
                        "carnatic vocal"])
        add(.sufi, ["sufi", "sufi music", "qawwali", "qawali", "kafi", "sufiana", "sufi rock", "sufi pop", "sufi fusion", "sufi kalam",
                    "sufi songs", "sufi folk", "bollywood sufi", "punjabi sufi"])
        add(.ghazal, ["ghazal", "gazal", "urdu ghazal", "ghazals", "nazm", "urdu poetry", "ghazal pop", "modern ghazal", "classic ghazal",
                      "hindi ghazal"])
        add(.devotional, ["devotional", "bhajan", "bhajans", "kirtan", "kirtans", "gurbani", "shabad", "shabad kirtan", "aarti", "arti",
                          "chalisa", "mantra", "stotra", "stotram", "bhakti", "bhakti sangeet", "bhakti geet", "hindu devotional",
                          "sikh devotional", "christian", "christian rock", "gospel", "worship", "praise and worship",
                          "contemporary christian", "ccm", "hymn", "hymns", "spiritual", "spirituals", "naat", "hamd", "nasheed",
                          "islamic", "haveli sangeet", "sikh", "religious", "religious music", "sacred", "sacred music", "buddhist chant",
                          "chant", "gregorian chant", "devotional songs", "hindi devotional", "islamic devotional"])
        add(.punjabi, ["punjabi", "bhangra", "punjabi pop", "punjabi folk", "punjabi music", "boliyan", "giddha", "punjabi hip hop",
                       "punjabi rap", "punjabi bhangra", "punjabi hits", "desi pop", "punjabi songs", "modern bhangra"])
        add(.folk, ["folk", "indian folk", "hindi folk", "rajasthani folk", "rajasthani", "bhojpuri folk", "bhojpuri", "haryanvi",
                    "haryanvi folk", "garhwali", "kumaoni", "himachali", "marathi folk", "lavani", "bengali folk", "baul", "bhatiali",
                    "assamese folk", "bihu", "gujarati folk", "garba", "dandiya", "dandiya raas", "kashmiri folk", "manganiyar", "langa",
                    "folk revival", "contemporary folk", "traditional folk", "americana", "bluegrass", "celtic", "celtic folk", "irish folk",
                    "scottish folk", "folk pop", "neofolk", "chamber folk", "freak folk", "anti folk", "sea shanty", "shanty", "nepali folk",
                    "lok geet", "lokgeet", "lok sangeet", "traditional", "folk music", "world folk", "maithili folk", "odia folk"])
        add(.country, ["country", "country pop", "country rock", "outlaw country", "alt country", "alternative country", "bro country",
                       "contemporary country", "classic country", "honky tonk", "nashville sound", "bakersfield sound", "western",
                       "western swing", "cowboy", "red dirt", "texas country", "country soul", "country folk", "country music",
                       "modern country", "traditional country"])
        add(.kpop, ["k pop", "kpop", "korean pop", "korean ballad", "k ballad", "k indie", "k r b", "k hip hop", "korean hip hop",
                    "k rock", "korean"])
        add(.latin, ["latin", "latin pop", "reggaeton", "salsa", "bachata", "cumbia", "merengue", "bossa nova", "samba", "tango",
                     "flamenco", "latin rock", "latin trap", "urbano", "urbano latino", "dembow", "mariachi", "ranchera", "banda",
                     "norteno", "tejano", "bolero", "son cubano", "mambo", "cha cha cha", "rumba", "latin alternative", "brazilian", "mpb",
                     "forro", "sertanejo", "axe", "pagode", "corridos", "corridos tumbados", "regional mexican", "latin urban", "champeta",
                     "latin music", "spanish pop", "latin ballad"])
        add(.reggae, ["reggae", "dancehall", "dub", "roots reggae", "ska", "rocksteady", "reggae fusion", "lovers rock", "ragga",
                      "reggae pop", "ska punk", "reggae rock", "reggae classics", "indian reggae"])
        add(.soundtrack, ["soundtrack", "film score", "score", "original score", "video game music", "game music", "video game soundtrack",
                          "anime", "anime soundtrack", "musical", "musicals", "show tunes", "broadway", "stage and screen", "tv soundtrack",
                          "television music", "trailer music", "epic music", "cinematic", "orchestral soundtrack", "film music",
                          "original soundtrack", "ost", "background score"])
        add(.instrumental, ["instrumental", "instrumental music", "instrumental rock", "instrumental guitar", "instrumental pop",
                            "guitar instrumental", "piano instrumental", "instrumental cover", "instrumental version", "guitar",
                            "instrumental jazz", "flute instrumental", "violin instrumental", "instrumental fusion", "instrumentals"])
        add(.acoustic, ["acoustic", "singer songwriter", "acoustic pop", "acoustic folk", "acoustic rock", "unplugged", "acoustic guitar",
                        "acoustic cover", "acoustic soul", "coffeehouse", "folk singer songwriter", "acoustic indie", "acoustic ballad",
                        "acoustic version", "acoustic sessions", "hindi acoustic", "bollywood unplugged"])
        add(.ambient, ["ambient", "new age", "newage", "dark ambient", "drone", "meditation", "meditation music", "relaxation",
                       "relaxing music", "sleep music", "nature sounds", "space ambient", "ambient electronic", "ambient pop",
                       "healing music", "spa music", "yoga music", "binaural beats", "soundscape", "chillout", "chill out", "lounge",
                       "ambient music", "new age music"])
        add(.world, ["world", "world music", "afrobeat", "afrobeats", "afropop", "highlife", "amapiano", "afro house", "soukous", "mbalax",
                     "arabic", "arabic pop", "khaleeji", "turkish pop", "persian", "persian pop", "middle eastern", "balkan", "klezmer",
                     "fado", "chanson", "enka", "african", "ethnic", "tribal", "polynesian", "hawaiian", "caribbean", "calypso", "soca",
                     "zouk", "kizomba", "gnawa", "rai", "nepali", "nepali pop", "sri lankan", "indian fusion", "ethnic fusion",
                     "world fusion", "asian", "oriental", "african music", "world beat", "global"])
        return table
    }()
}

extension RadioExperience {
    /// Families a station's wording promises; only genre-led stations carry one. Era and mood stations stay untagged
    /// so affinity ordering never moves them ahead of the listener's actual genres.
    var genreFamilies: [GenreFamily] {
        switch stationID {
        case "left-field-rap": [.hipHop]
        case "rock": [.rock]
        case "alt-rock": [.rock, .indiePop]
        case "indian-indie": [.indiePop]
        case "pop": [.pop]
        case "rnb-soul": [.rnb]
        case "dance-edm": [.dance, .electronic]
        case "lofi": [.lofi]
        case "acoustic": [.acoustic]
        case "jazz": [.jazz, .blues]
        case "classical": [.classical, .hindustani, .carnatic, .instrumental]
        case "folk": [.folk]
        case "sufi": [.sufi]
        case "ghazal": [.ghazal]
        case "qawwali": [.sufi]
        case "punjabi-hits": [.punjabi]
        case "hindi-classics": [.bollywood]
        case "metal": [.metal]
        case "country": [.country]
        case "reggae": [.reggae]
        case "devotional": [.devotional]
        default: []
        }
    }
}
