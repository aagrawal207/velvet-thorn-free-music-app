import Foundation

enum CatalogDiscovery {
    static let hindiPlaylist = "VLRDCLAK5uy_n9Fbdw7e6ap-98_A-8JYBmPv64v-Uaq1g"
    static let englishPlaylist = "VLRDCLAK5uy_nmS3YoxSwVVQk9lEQJ0UX4ZCjXsW_psU8"

    static func starters(for language: MusicLanguage) -> [Track] {
        switch language {
        case .hindi:
            return [
                starter("fsiPzT50ZiM", "Tum Hi Ho", ["Arijit Singh"], "Aashiqui 2", 262, .hindi),
                starter("NJAv_7lHUIU", "Kesariya (From \"Brahmastra\")", ["Arijit Singh"], "Kesariya (From \"Brahmastra\")", 269, .hindi),
                starter("FOA9iyxsW_A", "Agar Tum Saath Ho", ["Arijit Singh", "Alka Yagnik"], "Tamasha", 342, .hindi),
            ]
        case .english:
            return [
                starter("J7p4bzqLvCw", "Blinding Lights", ["The Weeknd"], "Blinding Lights", 202, .english),
                starter("xTvyyoF_LZY", "Shape of You", ["Ed Sheeran"], "Shape of You", 234, .english),
            ]
        }
    }

    static func select(_ tracks: [Track], language: MusicLanguage, excluding seedID: String? = nil) -> [Track] {
        CatalogText.uniqueTracks(tracks).filter {
            $0.id != seedID && accepts($0, language: language)
        }.map { track in
            var track = track
            if let known = knownLanguages[track.id] { track.language = known }
            return track
        }
    }

    static func accepts(_ track: Track, language: MusicLanguage) -> Bool {
        guard track.isAudioRecording != false else { return false }
        if let known = knownLanguages[track.id] ?? track.language { return known == language }
        if let duration = track.duration, !(30...900).contains(duration) { return false }
        if isUnwantedVersion(track.title) { return false }
        let title = track.title.lowercased()
        if foreignLanguageLabels.contains(where: { containsWord($0, in: title) }) { return false }
        let allowedScripts = CharacterSet(charactersIn: "\u{0000}"..."\u{024F}")
            .union(.punctuationCharacters).union(.symbols).union(.whitespacesAndNewlines).union(.decimalDigits)
        let letters = track.title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if language == .english && letters.contains(where: { !allowedScripts.contains($0) }) { return false }
        if language == .hindi && letters.contains(where: { scalar in
            !allowedScripts.contains(scalar) && !(0x0900...0x097F).contains(scalar.value)
        }) { return false }
        let artists = language == .hindi ? hindiArtists : englishArtists
        // Artist affinity narrows a seeded mix; it does not prove a recording's language.
        // Only verified recording metadata sets Track.language.
        return track.artists.contains { artists.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    /// Re-uploads and altered takes (karaoke, slowed, 8D) that no mix or autoplay queue should surface.
    static func isUnwantedVersion(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return unwantedVersionWords.contains(where: lowered.contains)
    }

    private static func starter(_ id: String, _ title: String, _ artists: [String], _ album: String,
                                _ duration: TimeInterval, _ language: MusicLanguage) -> Track {
        Track(id: id, title: title, artists: artists, albumTitle: album, duration: duration,
              artworkURL: CatalogText.artwork(.null, videoID: id), language: language, isAudioRecording: true)
    }

    private static func containsWord(_ word: String, in title: String) -> Bool {
        title.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil
    }

    private static let knownLanguages: [String: MusicLanguage] = [
        "fsiPzT50ZiM": .hindi, "NJAv_7lHUIU": .hindi, "FOA9iyxsW_A": .hindi,
        "J7p4bzqLvCw": .english, "xTvyyoF_LZY": .english,
    ]
    private static let unwantedVersionWords = ["karaoke", "slowed", "sped up", "sped-up", "8d audio", "reverb", "full movie", "podcast"]
    private static let foreignLanguageLabels = ["tamil", "telugu", "kannada", "malayalam", "bengali", "marathi", "bhojpuri", "punjabi", "korean", "spanish", "japanese"]
    private static let hindiArtists: Set<String> = [
        "arijit singh", "alka yagnik", "pritam", "shreya ghoshal", "sonu nigam", "udit narayan", "kumar sanu",
        "kk", "mohit chauhan", "ankit tiwari", "jubin nautiyal", "roop kumar rathod", "sunidhi chauhan",
        "vishal mishra", "sachin-jigar", "shashwat sachdev", "amit trivedi", "armaan malik", "amaal mallik",
        "sachet tandon", "tanishk bagchi", "atif aslam", "rahat fateh ali khan", "sukhwinder singh",
        "madhubanti bagchi", "sadhu tiwari", "faheem abdullah", "mithoon", "vishal-shekhar",
    ]
    private static let englishArtists: Set<String> = [
        "the weeknd", "ed sheeran", "taylor swift", "bruno mars", "justin bieber", "dua lipa", "adele",
        "coldplay", "onerepublic", "post malone", "the kid laroi", "swae lee", "ariana grande", "billie eilish",
        "maroon 5", "imagine dragons", "shawn mendes", "charlie puth", "selena gomez", "rihanna", "sia",
        "sabrina carpenter", "olivia rodrigo", "harry styles", "benson boone", "lady gaga", "miley cyrus",
    ]
}
