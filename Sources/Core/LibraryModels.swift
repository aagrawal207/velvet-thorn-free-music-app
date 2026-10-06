import Foundation

enum AppAppearance: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ShuffleStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case random, fewerRepeats
    var id: String { rawValue }
    var title: String {
        switch self {
        case .random: "Random"
        case .fewerRepeats: "Fewer repeats"
        }
    }
}

enum DiscoveryFamiliarity: String, CaseIterable, Codable, Sendable, Identifiable {
    case familiar, balanced, newMusic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .familiar: "More familiar"
        case .balanced: "Balanced"
        case .newMusic: "More new"
        }
    }
}

/// Download Liked Songs choice; derived from two preference leaves, never stored itself.
enum AutoDownloadScope: String, CaseIterable, Sendable, Identifiable {
    case off, superLiked, liked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .superLiked: "Super Liked Only"
        case .liked: "All Liked"
        }
    }
}

enum HomeSectionKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    // New cases go last: a saved six-section order still reads as the default, and the section appends for existing users.
    case recentlyPlayed, madeForYou, newReleases, becauseYouLike, charts, discovery, superLiked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyPlayed: "Recently played"
        case .madeForYou: "Made for you"
        case .newReleases: "New releases"
        case .becauseYouLike: "Because you like"
        case .charts: "Charts"
        case .discovery: "Discovery"
        case .superLiked: "Super Liked"
        }
    }

    var detail: String {
        switch self {
        case .recentlyPlayed: "Songs you’ve played, with a shortcut to resume."
        case .madeForYou: "Your Daily Mix and Discover Weekly."
        case .newReleases: "New music from artists you follow."
        case .becauseYouLike: "Picks based on artists you listen to."
        case .charts: "Weekly song charts for your languages."
        case .discovery: "More music to explore in your languages."
        case .superLiked: "The songs you super liked, newest first."
        }
    }
}

struct HomeLayoutPreferences: Codable, Equatable, Sendable {
    // Raw identifiers let an older app preserve sections it does not yet know how to display.
    private var order: [String]
    private var hidden: Set<String>

    init(order: [HomeSectionKind] = HomeSectionKind.allCases, hidden: Set<HomeSectionKind> = []) {
        self.order = order.map(\.rawValue)
        self.hidden = Set(hidden.map(\.rawValue))
    }

    var orderedSections: [HomeSectionKind] {
        var seen = Set<HomeSectionKind>()
        return (order.compactMap(HomeSectionKind.init(rawValue:)) + HomeSectionKind.allCases)
            .filter { seen.insert($0).inserted }
    }

    var visibleSections: [HomeSectionKind] { orderedSections.filter(isVisible) }
    var isDefault: Bool { orderedSections == HomeSectionKind.allCases && HomeSectionKind.allCases.allSatisfy(isVisible) }

    func isVisible(_ section: HomeSectionKind) -> Bool { !hidden.contains(section.rawValue) }

    mutating func setVisible(_ visible: Bool, for section: HomeSectionKind) {
        if visible { hidden.remove(section.rawValue) }
        else { hidden.insert(section.rawValue) }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let sections = orderedSections
        guard !offsets.isEmpty, offsets.allSatisfy({ sections.indices.contains($0) }),
              (0...sections.count).contains(destination) else { return }
        let moved = offsets.map { sections[$0] }
        var remaining = sections.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        order = remaining.map(\.rawValue) + order.filter { HomeSectionKind(rawValue: $0) == nil }
    }

    mutating func reset() {
        order = HomeSectionKind.allCases.map(\.rawValue) + order.filter { HomeSectionKind(rawValue: $0) == nil }
        hidden.subtract(HomeSectionKind.allCases.map(\.rawValue))
    }

    private enum CodingKeys: String, CodingKey { case order, hidden }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? HomeSectionKind.allCases.map(\.rawValue)
        hidden = try values.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
    }
}

struct UserPreferences: Codable, Equatable, Sendable {
    static let crossfadeRange: ClosedRange<TimeInterval> = 0...12

    // Older sync journals address this field; only cold starts may use it as a language hint.
    var languages: Set<MusicLanguage> = [.hindi, .english]
    var languageNudges = LanguageRecommendationNudges()
    /// One More/Automatic/Less per genre family; encodes every family so each is its own sync register.
    var genreNudges = GenreNudges()
    var discoveryFamiliarity: DiscoveryFamiliarity = .balanced
    var appearance: AppAppearance = .dark
    var accent: AppAccent = .coral
    // An empty preference lets an upgraded installation retain its existing Home Screen icon.
    var appIconID = ""
    var hasCompletedWelcome = false
    var saveListeningHistory = true
    var allowRemoteFallback = false
    var useEncryptedDNS = true
    /// Seconds of overlap between songs; zero leaves the transition to Gapless and Automix.
    var crossfadeSeconds: TimeInterval = 0
    var gaplessPlayback = true
    var automix = false
    var autoplay = true
    var shuffleStyle: ShuffleStyle = .fewerRepeats
    // Retained for journal compatibility; this flag cannot establish why an older value was saved.
    var shuffleDefaultMigrated = false
    var normalizeVolume = true
    var audioCacheLimit: AudioCacheLimit = .defaultLimit
    var newReleaseAlerts = true
    var homeLayout = HomeLayoutPreferences()
    var trailingTimeStyle: TrailingTimeStyle = .songLength
    var playerSwipeUpAction: PlayerSwipeUpAction = .lyrics
    var playerBackgroundMotion: PlayerBackgroundMotion = .off
    var audioQuality: AudioQualityPreference = .best
    var equalizer = EqualizerSettings()
    var downloadsOverCellular = false
    var autoDownloadLikedSongs = false
    /// Super Liked Only downloads; All Liked (`autoDownloadLikedSongs`) implies it. Two lenient leaves, one control.
    var autoDownloadSuperLikedSongs = false
    /// Ordered, not a set, so the synced register has one canonical form.
    var enabledCatalogSources: [MusicSource] = MusicSource.allCases
    var sponsorBlockSkipping = false

    init() { }

    private enum CodingKeys: String, CodingKey {
        case languages, appearance, accent, hasCompletedWelcome, saveListeningHistory, allowRemoteFallback, useEncryptedDNS
        case crossfadeSeconds, gaplessPlayback, automix, autoplay, normalizeVolume, newReleaseAlerts
        case homeLayout, appIconID
        case audioCacheLimit
        case languageNudges, genreNudges
        case shuffleStyle, discoveryFamiliarity, shuffleDefaultMigrated
        case trailingTimeStyle, playerSwipeUpAction, audioQuality, equalizer, downloadsOverCellular, autoDownloadLikedSongs
        case enabledCatalogSources, sponsorBlockSkipping, autoDownloadSuperLikedSongs
        case playerBackgroundMotion
    }

    /// Which likes download on their own; the picker writes both Bool leaves so each merges independently.
    var autoDownloadScope: AutoDownloadScope {
        get { autoDownloadLikedSongs ? .liked : autoDownloadSuperLikedSongs ? .superLiked : .off }
        set {
            autoDownloadLikedSongs = newValue == .liked
            autoDownloadSuperLikedSongs = newValue != .off
        }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        languages = try values.decodeIfPresent(Set<MusicLanguage>.self, forKey: .languages) ?? [.hindi, .english]
        languageNudges = try values.decodeIfPresent(LanguageRecommendationNudges.self, forKey: .languageNudges) ?? .init()
        genreNudges = (try? values.decodeIfPresent(GenreNudges.self, forKey: .genreNudges)) ?? GenreNudges()
        // Only absence is a legacy default; a present null or unknown choice must block file replacement.
        if values.contains(.discoveryFamiliarity) {
            discoveryFamiliarity = try values.decode(DiscoveryFamiliarity.self, forKey: .discoveryFamiliarity)
        }
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .dark
        accent = try values.decodeIfPresent(AppAccent.self, forKey: .accent) ?? .coral
        appIconID = try values.decodeIfPresent(String.self, forKey: .appIconID) ?? ""
        hasCompletedWelcome = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedWelcome) ?? false
        saveListeningHistory = try values.decodeIfPresent(Bool.self, forKey: .saveListeningHistory) ?? true
        allowRemoteFallback = try values.decodeIfPresent(Bool.self, forKey: .allowRemoteFallback) ?? false
        useEncryptedDNS = try values.decodeIfPresent(Bool.self, forKey: .useEncryptedDNS) ?? true
        let crossfade = try values.decodeIfPresent(TimeInterval.self, forKey: .crossfadeSeconds) ?? 0
        crossfadeSeconds = crossfade.isFinite ? min(max(crossfade, Self.crossfadeRange.lowerBound), Self.crossfadeRange.upperBound) : 0
        gaplessPlayback = try values.decodeIfPresent(Bool.self, forKey: .gaplessPlayback) ?? true
        automix = try values.decodeIfPresent(Bool.self, forKey: .automix) ?? false
        autoplay = try values.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        if values.contains(.shuffleStyle) {
            shuffleStyle = try values.decode(ShuffleStyle.self, forKey: .shuffleStyle)
        }
        normalizeVolume = try values.decodeIfPresent(Bool.self, forKey: .normalizeVolume) ?? true
        audioCacheLimit = try values.decodeIfPresent(AudioCacheLimit.self, forKey: .audioCacheLimit) ?? .defaultLimit
        newReleaseAlerts = try values.decodeIfPresent(Bool.self, forKey: .newReleaseAlerts) ?? true
        homeLayout = try values.decodeIfPresent(HomeLayoutPreferences.self, forKey: .homeLayout) ?? HomeLayoutPreferences()
        // Unlike the choices above, these fall back to their defaults on an unreadable value instead of blocking the file.
        trailingTimeStyle = (try? values.decodeIfPresent(TrailingTimeStyle.self, forKey: .trailingTimeStyle)) ?? .songLength
        playerSwipeUpAction = (try? values.decodeIfPresent(PlayerSwipeUpAction.self, forKey: .playerSwipeUpAction)) ?? .lyrics
        playerBackgroundMotion = (try? values.decodeIfPresent(PlayerBackgroundMotion.self, forKey: .playerBackgroundMotion)) ?? .off
        audioQuality = (try? values.decodeIfPresent(AudioQualityPreference.self, forKey: .audioQuality)) ?? .best
        equalizer = (try? values.decodeIfPresent(EqualizerSettings.self, forKey: .equalizer)) ?? EqualizerSettings()
        downloadsOverCellular = (try? values.decodeIfPresent(Bool.self, forKey: .downloadsOverCellular)) ?? false
        autoDownloadLikedSongs = (try? values.decodeIfPresent(Bool.self, forKey: .autoDownloadLikedSongs)) ?? false
        autoDownloadSuperLikedSongs = (try? values.decodeIfPresent(Bool.self, forKey: .autoDownloadSuperLikedSongs)) ?? false
        if let sources = try? values.decodeIfPresent([String].self, forKey: .enabledCatalogSources) {
            // A source this version does not know is dropped; an empty list is a deliberate choice and stays empty.
            enabledCatalogSources = sources.compactMap(MusicSource.init(rawValue:))
        }
        sponsorBlockSkipping = (try? values.decodeIfPresent(Bool.self, forKey: .sponsorBlockSkipping)) ?? false
        shuffleDefaultMigrated = (try? values.decodeIfPresent(Bool.self, forKey: .shuffleDefaultMigrated)) ?? false
    }

    // Older saves encode defaults and explicit choices identically. Only a missing field takes the new default.
    @discardableResult
    mutating func migrateShuffleDefault() -> Bool {
        false
    }

    // Explicit choices retain the compatibility marker without inferring intent for older saved values.
    mutating func chooseShuffleStyle(_ style: ShuffleStyle) {
        shuffleStyle = style
        shuffleDefaultMigrated = true
    }
}

/// Full-screen player backdrop motion. Off keeps the static artwork backdrop; collections never animate.
enum PlayerBackgroundMotion: String, Codable, CaseIterable, Sendable {
    case off, drift, pulse, reactive

    var title: String {
        switch self {
        case .off: "Off"
        case .drift: "Drift"
        case .pulse: "Pulse"
        case .reactive: "React to Music"
        }
    }
}

/// Song-to-song transition behavior the player applies; derived from UserPreferences by the app model.
struct PlaybackTransitionSettings: Equatable, Sendable {
    var crossfadeSeconds: TimeInterval = 0
    var gapless = true
    var automix = false
    var autoplay = true
    var normalizeVolume = true

    init() { }

    init(_ preferences: UserPreferences) {
        crossfadeSeconds = preferences.crossfadeSeconds
        gapless = preferences.gaplessPlayback
        automix = preferences.automix
        autoplay = preferences.autoplay
        normalizeVolume = preferences.normalizeVolume
    }
}

/// A song the listener never wants recommended or autoplayed again. Kept with its name so it can be listed and undone.
struct DislikedSong: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var artists: [String]
    var dislikedAt: Date = Date()
}

struct FollowedArtist: Codable, Hashable, Identifiable, Sendable {
    /// YouTube Music channel identifier (UC…).
    var id: String
    var name: String
    var artworkURL: URL?
    var followedAt: Date = Date()
    /// Release identifiers already seen for this artist; only identifiers outside this set count as new.
    var knownReleaseIDs: [String] = []
    var lastCheckedAt: Date?
    /// A successful catalog read establishes a baseline even when no releases are visible.
    var hasEstablishedReleaseBaseline = false

    private enum CodingKeys: String, CodingKey {
        case id, name, artworkURL, followedAt, knownReleaseIDs, lastCheckedAt, hasEstablishedReleaseBaseline
    }
}

extension FollowedArtist {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
        followedAt = try values.decode(Date.self, forKey: .followedAt)
        knownReleaseIDs = try values.decode([String].self, forKey: .knownReleaseIDs)
        lastCheckedAt = try values.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        // Legacy check timestamps include failures; only remembered IDs prove a successful baseline.
        hasEstablishedReleaseBaseline = try values.decodeIfPresent(Bool.self, forKey: .hasEstablishedReleaseBaseline)
            ?? !knownReleaseIDs.isEmpty
    }
}

struct ArtistRelease: Codable, Hashable, Identifiable, Sendable {
    /// Album or single browse identifier (MPRE…).
    var id: String
    var title: String
    var subtitle: String
    var artistID: String
    var artistName: String
    var artworkURL: URL?
    var discoveredAt: Date
    var seen = false
    var notificationIdentifier: String { "release.\(id)" }
}

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    var next: RepeatMode { switch self { case .off: .all; case .all: .one; case .one: .off } }
}

struct PlaybackSnapshot: Codable, Sendable {
    var queue: [Track] = []
    var currentIndex: Int = 0
    var position: TimeInterval = 0
    var shuffleEnabled = false
    var repeatMode: RepeatMode = .off
    var originalQueue: [Track]? = nil
    /// Index in originalQueue for each queue occurrence; equal Track values cannot distinguish duplicate occurrences.
    var originalQueueIndices: [Int]? = nil
}

struct UserPlaylist: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct ListeningEvent: Codable, Identifiable, Sendable {
    var id: UUID
    var track: Track
    var startedAt: Date
    var listenedSeconds: TimeInterval
}

struct LifetimeListeningSummary: Equatable, Sendable {
    var seconds: TimeInterval = 0
    var plays: Int = 0
    var coverageStartedAt: Date?
}

struct RecentListen: Codable, Identifiable, Sendable {
    var track: Track
    var playedAt: Date
    var position: TimeInterval
    var id: String { track.id }
}

enum ListeningWindow: String, CaseIterable, Identifiable, Sendable {
    case week, month, year
    var id: String { rawValue }
    var title: String { switch self { case .week: "Week"; case .month: "Month"; case .year: "Year" } }
    var days: Int { switch self { case .week: 7; case .month: 30; case .year: 365 } }
    var subtitle: String { "Your last \(days) days" }
}

struct RankedTrack: Identifiable, Sendable {
    var track: Track
    var seconds: TimeInterval
    var plays: Int
    var id: String { track.id }
}

struct RankedArtist: Identifiable, Sendable {
    var name: String
    var seconds: TimeInterval
    var plays: Int
    var id: String { name }
}

struct ListeningDay: Identifiable, Sendable {
    var date: Date
    var seconds: TimeInterval
    var id: Date { date }
}

struct ListeningSummary: Sendable {
    var seconds: TimeInterval = 0
    var plays: Int = 0
    var uniqueTracks: Int = 0
    var uniqueArtists: Int = 0
    var topTracks: [RankedTrack] = []
    var topArtists: [RankedArtist] = []
    var days: [ListeningDay] = []
    var streak: Int = 0
    var minutes: Int { Int(seconds / 60) }
}
