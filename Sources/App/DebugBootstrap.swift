#if DEBUG
import Foundation
import OSLog
import UIKit

@MainActor
enum DebugBootstrap {
    private static var isMonitoringLayout = false
    private(set) static var fixtureAudioDirectory: URL?

    static var requestsReducedMotion: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui") && arguments.contains("--reduce-motion")
    }

    static var usesPairedWatchFixture: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--ui-watch-connectivity")
    }

    static func installUITestGeometryRequests() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"), arguments.contains("--ui-scene-geometry") else { return }
        for direction in ["portrait", "landscape"] {
            let name = "com.agraabhi.ganabajana.uitests.geometry.\(direction)" as CFString
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
                let landscape = (name?.rawValue as String?)?.hasSuffix(".landscape") == true
                Task { @MainActor in DebugBootstrap.requestUITestGeometry(landscape: landscape) }
            }, name, nil, .deliverImmediately)
        }
    }

    private static func requestUITestGeometry(landscape: Bool) {
        let orientations: UIInterfaceOrientationMask = landscape ? .landscapeLeft : .portrait
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where scene.windows.contains(where: \.isKeyWindow) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "UILayoutDiagnostics")
                logger.error("scene_geometry_request_failed code=\((error as NSError).code)")
            }
        }
    }

    static func beginLayoutDiagnostics() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-layout-diagnostics"), !isMonitoringLayout else { return }
        isMonitoringLayout = true
        // UIDevice.orientation stays unknown until notifications are enabled, even when the scene is oriented.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        logLayout("monitoring-started")
    }

    static func endLayoutDiagnostics() {
        guard isMonitoringLayout else { return }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        logLayout("monitoring-stopped")
        isMonitoringLayout = false
    }

    static func logLayout(_ event: String) {
        guard isMonitoringLayout else { return }
        let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "UILayoutDiagnostics")
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            logger.notice("\(event, privacy: .public) device=\(UIDevice.current.orientation.rawValue) generating=\(UIDevice.current.isGeneratingDeviceOrientationNotifications) scene=\(scene.interfaceOrientation.rawValue)")
            for window in scene.windows where window.isKeyWindow {
                logger.notice("window=\(String(describing: window.bounds), privacy: .public) appMask=\(UIApplication.shared.supportedInterfaceOrientations(for: window).rawValue)")
                func describe(_ controller: UIViewController, depth: Int = 0) {
                    guard depth < 10 else { return }
                    logger.notice("depth=\(depth) controller=\(String(describing: type(of: controller)), privacy: .public) mask=\(controller.supportedInterfaceOrientations.rawValue)")
                    controller.children.forEach { describe($0, depth: depth + 1) }
                    if let presented = controller.presentedViewController { describe(presented, depth: depth + 1) }
                }
                if let root = window.rootViewController { describe(root) }
            }
        }
    }

    static func makeModel() -> MusicAppModel {
        DebugArtworkURLProtocol.install()
        let arguments = ProcessInfo.processInfo.arguments
        let unitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            && !arguments.contains("--uitesting")
        let testing = arguments.contains("--uitesting") || unitTestHost
        let seededUITest = arguments.contains("--uitesting") && arguments.contains("--seed-ui")
        let welcomeFixture = arguments.contains("--uitesting") && !arguments.contains("--seed-ui")
            && !arguments.contains("--skip-welcome") && !arguments.contains("--play-live") && !arguments.contains("--search-results")
        let fixtures = unitTestHost || seededUITest || welcomeFixture
        var directory: URL?
        if testing {
            let name = ProcessInfo.processInfo.environment["GANABAJANA_TEST_STORE"] ?? (unitTestHost ? "unit-test-host" : "default")
            let safeName = String(name.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(80))
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GanaBajanaUITests", isDirectory: true)
                .appendingPathComponent(safeName.isEmpty ? "default" : safeName, isDirectory: true)
            if arguments.contains("--reset-ui"), let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let existingTestStore = directory.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("library.json").path)
        } ?? false
        fixtureAudioDirectory = fixtures ? directory?.appendingPathComponent("FixtureAudio", isDirectory: true) : nil
        let library = LibraryStore(directory: directory)
        if arguments.contains("--skip-welcome") || unitTestHost { library.preferences.hasCompletedWelcome = true }
        if arguments.contains("--light") { library.preferences.appearance = .light }
        if fixtures {
            if !existingTestStore, unitTestHost || seededUITest { DebugMusicFixtures.seed(library) }
            if !existingTestStore { DebugWidgetSupport.seed(library) }
            if seededUITest, !existingTestStore, arguments.contains("--listening-languages-unknown") {
                library.setRecordingLanguageOverride("und", for: "xTvyyoF_LZY")
            }
            let connectivity = ConnectivityMonitor(initialStatus: seededUITest && arguments.contains("--offline-fixture") ? .offline : .online,
                                                   monitorsSystem: false)
            let cachedResolver = directory.flatMap {
                DebugCachedAudioFixture.makeResolver(directory: $0, initializingStore: !existingTestStore,
                                                     connectivity: connectivity, arguments: arguments)
            }
            if cachedResolver != nil, !existingTestStore {
                var preferences = library.preferences
                preferences.autoplay = false
                preferences.allowRemoteFallback = false
                preferences.useEncryptedDNS = false
                library.preferences = preferences
                if arguments.contains("--cache-fixture-in-use") {
                    library.updatePlayback(PlaybackSnapshot(queue: Array(DebugMusicFixtures.tracks.prefix(2)), position: 32))
                }
            }
            let resolver: any StreamResolving
            if let cachedResolver {
                resolver = cachedResolver
            } else if arguments.contains("--fail-audio-once") {
                resolver = DebugFailOnceAudioResolver(delay: arguments.contains("--slow-audio") ? .seconds(4) : .milliseconds(300))
            } else {
                resolver = arguments.contains("--slow-audio") ? DebugDelayedAudioResolver() : DebugMusicFixtures()
            }
            let radioControl = DebugExperienceRadioControl(
                delay: arguments.contains("--slow-experience-radio") ? .seconds(3) : .milliseconds(120),
                failuresRemaining: arguments.contains("--fail-experience-radio-once") ? 4 : 0)
            let artistNavigationFixture = arguments.contains("--uitesting") && arguments.contains("--artist-navigation-fixture")
            if artistNavigationFixture, var track = DebugMusicFixtures.radioSetupSongs(DebugMusicFixtures.radioSetupNorah).first {
                track.credits = [ArtistCredit(name: DebugMusicFixtures.radioSetupNorah.name)]
                library.updatePlayback(PlaybackSnapshot(queue: [track], position: 32))
            }
            let libraryRecoveryFixture = arguments.contains("--uitesting") && arguments.contains("--library-recovery-fixture")
            if libraryRecoveryFixture, !existingTestStore {
                library.updatePlayback(PlaybackSnapshot(queue: Array(DebugMusicFixtures.tracks.prefix(3)), currentIndex: 1,
                                                        position: 32, repeatMode: .all))
            }
            var catalog: any MusicCatalogProviding
            let lyrics: any LyricsProviding
            if arguments.contains("--artist-spotlight-fixture") {
                let provider = ArtistSpotlightFixtureProvider()
                catalog = provider
                lyrics = provider
            } else {
                let provider = DebugMusicFixtures(experienceRadioControl: radioControl,
                                                  artistLookupDelay: artistNavigationFixture ? .seconds(3) : .milliseconds(100))
                catalog = provider
                lyrics = provider
            }
            if seededUITest, arguments.contains("--slow-search") || arguments.contains("--fail-search-once") {
                catalog = DebugSearchFixtureCatalog(base: catalog,
                    control: DebugSearchControl(delay: arguments.contains("--slow-search") ? .seconds(1) : .zero,
                                                failOnce: arguments.contains("--fail-search-once")))
            }
            // Fixtures never touch the device keychain, so UI runs start signed out and leave nothing behind.
            let model = MusicAppModel(library: library, player: PlayerController(resolver: resolver),
                                      catalog: catalog, charts: DebugMusicFixtures(), lyrics: lyrics,
                                      account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                                      recordingLanguageService: ArtistSpotlightLanguageService(provider: lyrics), connectivity: connectivity,
                                      generatesMixes: !libraryRecoveryFixture && !DebugWidgetSupport.isEnabled)
            DebugCachedAudioFixture.attach(to: model)
            if libraryRecoveryFixture, !existingTestStore, let directory {
                // The second writer changes storage after the live player has restored its own selection.
                let external = LibraryStore(directory: directory)
                external.toggleFavorite(DebugMusicFixtures.tracks[4])
                external.preferences.crossfadeSeconds = 7
                external.updatePlayback(PlaybackSnapshot(queue: [DebugMusicFixtures.tracks[3]], position: 80, repeatMode: .one))
                if let error = external.errorMessage {
                    model.showToast(error)
                    return model
                }
                do {
                    if arguments.contains("--library-recovery-future") {
                        try Data(#"{"version":9999}"#.utf8).write(to: directory.appendingPathComponent(LibraryPersistence.fileName), options: .atomic)
                    }
                    library.recordSearch("Rejected recovery fixture edit")
                } catch { model.showToast(error.localizedDescription) }
            }
            return model
        }
        return MusicAppModel(library: library)
    }

    static func performLaunchAction(_ model: MusicAppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        if DebugWidgetSupport.previewsWidget { model.isWidgetPreviewPresented = true }
        if DebugCachedAudioFixture.isActive {
            await DebugCachedAudioFixture.prepare()
            if let error = DebugCachedAudioFixture.setupError { model.showToast(error); return }
        }
        if arguments.contains("--uitesting"), arguments.contains("--seed-ui"), let index = arguments.firstIndex(of: "--search-results"),
           arguments.indices.contains(index + 1) {
            model.openSearch(arguments[index + 1])
        } else if let index = arguments.firstIndex(of: "--play-live"), arguments.indices.contains(index + 1) {
            do {
                let page = try await model.catalog.search(query: arguments[index + 1], filter: .songs, continuation: nil)
                if let track = page.tracks.first {
                    model.play(track, in: page.tracks)
                    model.isPlayerPresented = true
                }
            } catch { model.showToast(error.localizedDescription) }
        } else if arguments.contains("--uitesting"), arguments.contains("--seed-ui"), arguments.contains("--player") {
            model.player.restore(PlaybackSnapshot(queue: DebugMusicFixtures.tracks, currentIndex: 0, position: 32))
            model.isPlayerPresented = true
        }
    }
}

struct DebugMusicFixtures: MusicCatalogProviding, MusicChartsProviding, LyricsProviding, StreamResolving {
    var experienceRadioControl: DebugExperienceRadioControl? = nil
    var artistLookupDelay: Duration = .milliseconds(100)

    private static var hasPendingArtistArtwork: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--seed-ui")
            && arguments.contains("--artist-artwork-pending")
    }

    // Ids follow the provider shape (24 characters, "UC" prefix) so artist id validation accepts them.
    static let arijitSingh = ArtistCredit(name: "Arijit Singh", id: "UCfixtureArijitSingh0001")
    static let alkaYagnik = ArtistCredit(name: "Alka Yagnik", id: "UCfixtureAlkaYagnik00001")
    static let theWeeknd = ArtistCredit(name: "The Weeknd", id: "UCfixtureTheWeeknd000001")
    static let edSheeran = ArtistCredit(name: "Ed Sheeran", id: "UCfixtureEdSheeran000001")
    static let albumID = "fixture.album"

    static var credits: [ArtistCredit] { [arijitSingh, alkaYagnik, theWeeknd, edSheeran] }

    static var tracks: [Track] {
        var tracks = [Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", credits: [arijitSingh], albumTitle: "Aashiqui 2", duration: 262, language: .hindi, isAudioRecording: true),
         Track(id: "NJAv_7lHUIU", title: "Kesariya", credits: [arijitSingh], albumTitle: "Brahmastra", duration: 269, language: .hindi, isAudioRecording: true),
         Track(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", credits: [alkaYagnik, arijitSingh], albumTitle: "Tamasha", duration: 342, language: .hindi, isAudioRecording: true),
         Track(id: "J7p4bzqLvCw", title: "Blinding Lights", credits: [theWeeknd], albumTitle: "After Hours", duration: 202, language: .english, isAudioRecording: true),
          Track(id: "xTvyyoF_LZY", title: "Shape of You", credits: [edSheeran], albumTitle: "Divide", duration: 234, language: .english, isAudioRecording: true)]
        if hasPendingArtistArtwork { tracks[2].title = "Pending artist photo fixture" }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitesting"), arguments.contains("--seed-ui"),
           arguments.contains("--player-browse-fixture") {
            tracks[2].title = "Album and artists fixture"
            tracks[2].albumID = albumID
            tracks[2].albumTitle = "Evening favorites"
            tracks[2].credits = [alkaYagnik, arijitSingh, theWeeknd, edSheeran,
                                 ArtistCredit(name: "A. R. Rahman"), radioSetupNorah]
        }
        if let artwork = DebugArtworkURLProtocol.url("album") {
            for index in tracks.indices { tracks[index].artworkURL = artwork }
        }
        return tracks
    }

    static func credit(id: String) -> ArtistCredit? { credits.first { $0.id == id } }

    static func songs(crediting credit: ArtistCredit) -> [Track] {
        tracks.filter { track in track.credits.contains { $0.id == credit.id } }
    }

    static var experienceSeeds: [RadioExperience.Seed] { RadioExperience.stations.flatMap(\.seeds) }

    /// Fixture ids come from the seed's own query, so reordering or adding stations never renames a fixture.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        var pendingSeparator = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(Character(scalar))
            } else {
                pendingSeparator = true
            }
        }
        return slug
    }

    static func experienceTrack(for seed: RadioExperience.Seed) -> Track {
        Track(id: "fixture.experience.seed.\(slug(seed.query))", title: seed.title, credits: [seed.artist],
              albumTitle: seed.album, duration: 240, isAudioRecording: true)
    }

    static var experienceTracks: [Track] { experienceSeeds.map(experienceTrack) }

    static func experienceSeed(slug key: String) -> RadioExperience.Seed? {
        experienceSeeds.first { slug($0.query) == key }
    }

    /// Every station's wording in every language, keyed for lookup; era suffixes are stripped before matching.
    static let styleQueriesByKey: [String: String] = {
        var queries: [String: String] = [:]
        for station in RadioExperience.stations {
            for language in MusicLanguage.allCases {
                for query in station.styleQueries(for: language) { queries[SearchHistory.key(query)] = query }
            }
        }
        return queries
    }()

    static func styleQuery(matching query: String) -> String? {
        for era in RadioEra.allCases {
            let suffix = era.styleQuerySuffix
            guard !suffix.isEmpty, query.hasSuffix(suffix) else { continue }
            if let base = styleQueriesByKey[SearchHistory.key(String(query.dropLast(suffix.count)))] { return base }
        }
        return styleQueriesByKey[SearchHistory.key(query)]
    }

    /// Deterministic audio songs for a style query, each by a different artist so anchor selection keeps them all.
    static func styleSongs(for query: String) -> [Track] {
        let key = slug(query)
        return (0..<6).map { index in
            Track(id: "fixture.style.\(key).\(index)", title: "\(query) fixture \(index + 1)",
                  credits: [ArtistCredit(name: "Style artist \(index + 1) \(key)")], duration: 240, isAudioRecording: true)
        }
    }

    static func styleRadio(seed: String, key: String, from firstNeighbor: Int) -> [Track] {
        (firstNeighbor..<(firstNeighbor + 6)).map { index in
            Track(id: "fixture.style.\(key).radio.\(seed).\(index)", title: "Style radio fixture \(key) \(seed) \(index + 1)",
                  credits: [ArtistCredit(name: "Style neighbor \(seed) \(index + 1) \(key)")], duration: 240, isAudioRecording: true)
        }
    }

    static let radioSetupNorah = ArtistCredit(name: "Norah Jones", id: "UCfixtureRadioNorah00001")

    static var radioSetupArtists: [ArtistCredit] {
        var names = Set<String>()
        let credits = experienceSeeds.map(\.artist).filter { names.insert(SearchRelevance.normalize($0.name)).inserted }
        return credits.enumerated().map { index, credit in
            ArtistCredit(name: credit.name, id: String(format: "UCfixtureRadioArtist%04d", index))
        } + [radioSetupNorah]
    }

    static func radioSetupSongs(_ artist: ArtistCredit) -> [Track] {
        if artist.id == radioSetupNorah.id {
            return [Track(id: "fixture.setup.norah.2002", title: "Come Away With Me", credits: [artist],
                          albumTitle: "Come Away With Me", albumID: "fixture.setup.album.norah.2002", duration: 240,
                          language: .english, isAudioRecording: true),
                    Track(id: "fixture.setup.norah.2016", title: "Carry On", credits: [artist],
                          albumTitle: "Day Breaks", albumID: "fixture.setup.album.norah.2016", duration: 240,
                          language: .english, isAudioRecording: true)]
        }
        return zip(experienceSeeds, experienceTracks).compactMap { intent, recording in
            guard SearchRelevance.normalize(intent.artist.name) == SearchRelevance.normalize(artist.name) else { return nil }
            var song = recording
            song.credits = [artist]
            if let year = intent.year, let id = artist.id {
                song.albumID = "fixture.setup.album.\(id).\(year)"
                song.albumTitle = "Dated fixture release \(year)"
            }
            return song
        }
    }

    static func radioSetupReleases(_ artist: ArtistCredit) -> [MusicCollection] {
        var ids = Set<String>()
        let releases = radioSetupSongs(artist).compactMap { song -> MusicCollection? in
            guard let albumID = song.albumID, ids.insert(albumID).inserted,
                  let year = albumID.split(separator: ".").last.flatMap({ Int($0) }) else { return nil }
            return MusicCollection(id: albumID, title: song.albumTitle ?? "Fixture album", subtitle: "Album · \(year)", kind: .album)
        }
        return Array(releases.reversed())
    }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await Task.sleep(for: filter == .artists ? artistLookupDelay : .milliseconds(100))
        if filter == .songs, let seed = Self.experienceSeeds.first(where: { SearchHistory.key($0.query) == SearchHistory.key(query) }) {
            return CatalogPage(tracks: [Self.experienceTrack(for: seed)])
        }
        // Station wording resolves to synthetic songs so wording-only stations start; other queries keep the empty state.
        if filter == .songs, let style = Self.styleQuery(matching: query) {
            return CatalogPage(tracks: Self.styleSongs(for: style))
        }
        if filter == .artists {
            let key = SearchRelevance.normalize(query)
            let artists = Self.radioSetupArtists.filter {
                !key.isEmpty && (SearchRelevance.normalize($0.name) == key
                    || ($0.id == Self.radioSetupNorah.id && SearchRelevance.normalize($0.name).contains(key)))
            }
            if !artists.isEmpty { return CatalogPage(collections: artists.compactMap(\.collection)) }
        }
        let tracks = Self.tracks.filter { ($0.title + " " + $0.artistName).localizedCaseInsensitiveContains(query) }
        if filter == .songs { return CatalogPage(tracks: tracks) }
        let kind: CollectionKind = switch filter { case .artists: .artist; case .playlists: .playlist; default: .album }
        // Like the provider, search collections carry no songs; the page fetches them and the album's credits.
        return CatalogPage(collections: [MusicCollection(id: Self.albumID, title: "Evening favorites",
            subtitle: "Breezy test collection", artworkURL: DebugArtworkURLProtocol.url(kind == .artist ? "artist" : "album"), kind: kind)])
    }

    func browse(id: String) async throws -> CatalogPage {
        if id.hasPrefix("fixture.setup.album.") {
            let songs = Self.radioSetupArtists.flatMap(Self.radioSetupSongs).filter { $0.albumID == id }
            return CatalogPage(tracks: songs, title: songs.first?.albumTitle)
        }
        if let credit = Self.credit(id: id) { return CatalogPage(tracks: Self.songs(crediting: credit), title: credit.name) }
        return CatalogPage(tracks: Self.tracks, title: "Evening favorites", credits: [Self.arijitSingh])
    }

    func artist(id: String) async throws -> ArtistPage {
        if Self.hasPendingArtistArtwork { try await Task.sleep(for: .seconds(30)) }
        if let credit = Self.radioSetupArtists.first(where: { $0.id == id }) {
            try await Task.sleep(for: .milliseconds(100))
            let songs = Self.radioSetupSongs(credit)
            return ArtistPage(id: id, name: credit.name, topSongs: credit.id == Self.radioSetupNorah.id ? Array(songs.prefix(1)) : songs,
                              releases: Self.radioSetupReleases(credit))
        }
        guard let credit = Self.credit(id: id) else {
            let page = try await browse(id: id)
            return ArtistPage(id: id, name: page.title ?? "", topSongs: page.tracks)
        }
        return ArtistPage(id: id, name: credit.name, artworkURL: DebugArtworkURLProtocol.url("artist"), topSongs: Self.songs(crediting: credit))
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] { Self.tracks.filter { $0.language == language } }
    func radio(seed: Track) async throws -> [Track] {
        if seed.id.hasPrefix("fixture.setup.norah.") || seed.id.hasPrefix("fixture.setup.radio.norah.") {
            try await experienceRadioControl?.beforeRequest()
            let offset = seed.id.hasPrefix("fixture.setup.radio.norah.") ? (seed.id.split(separator: ".").last.flatMap { Int($0) } ?? 0) + 1 : 0
            return (offset..<(offset + 6)).map { index in
                Track(id: "fixture.setup.radio.norah.\(index)", title: "Norah Jones radio fixture \(index)", credits: [Self.radioSetupNorah],
                      duration: 240, language: .english, isAudioRecording: true)
            }
        }
        if seed.id.hasPrefix("fixture.style.") {
            // fixture.style.<query>.<n> or fixture.style.<query>.radio.<n>.<k>; the query slug never contains a dot.
            let parts = seed.id.split(separator: ".").map(String.init)
            guard parts.count == 4 || (parts.count == 6 && parts[3] == "radio") else { return [] }
            try await experienceRadioControl?.beforeRequest()
            let firstNeighbor = parts.count == 6 ? (Int(parts[5]) ?? 0) + 1 : 0
            return Self.styleRadio(seed: parts.count == 6 ? parts[4] : parts[3], key: parts[2], from: firstNeighbor)
        }
        let key: String
        let firstNeighbor: Int
        if seed.id.hasPrefix("fixture.experience.seed.") {
            key = String(seed.id.dropFirst("fixture.experience.seed.".count))
            firstNeighbor = 0
        } else if seed.id.hasPrefix("fixture.experience.radio.") {
            let parts = seed.id.split(separator: ".")
            guard parts.count == 5 else { return [] }
            key = String(parts[3])
            firstNeighbor = (Int(parts[4]) ?? 0) + 1
        } else {
            return Self.tracks.filter { $0.id != seed.id }
        }
        guard let intent = Self.experienceSeed(slug: key) else { return [] }
        try await experienceRadioControl?.beforeRequest()
        let original = Self.experienceTrack(for: intent)
        return (firstNeighbor..<(firstNeighbor + 6)).map { number in
            Track(id: "fixture.experience.radio.\(key).\(number)",
                  title: "\(original.artistName) radio fixture \(number + 1)", credits: original.credits,
                  duration: 240, isAudioRecording: true)
        }
    }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        MusicLanguage.allCases.filter(languages.contains).map { language in
            DiscoverySection(id: "fixture.\(language.rawValue)", title: language == .hindi ? "Your daily mix" : "Fresh favorites",
                subtitle: "Your next good listen", language: language, tracks: Self.tracks.filter { $0.language == language })
        }
    }

    func weeklyChart(language: MusicLanguage) async throws -> ChartSnapshot {
        let end = Date()
        let start = end.addingTimeInterval(-6 * 86_400)
        let region = language == .hindi ? "India" : "United States"
        var format = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        format.timeZone = TimeZone(secondsFromGMT: 0)!
        return ChartSnapshot(id: "fixture.chart.\(language.rawValue)", title: "Weekly picks",
                      subtitle: "\(region) · \(start.formatted(format)) – \(end.formatted(format))", source: "Test fixture", language: language,
                      periodStart: start, periodEnd: end, fetchedAt: end,
                      entries: Self.tracks.filter { $0.language == language }.enumerated().map {
                          ChartEntry(rank: $0.offset + 1, track: $0.element, views: nil)
                      })
    }

    func lyrics(for track: Track) async throws -> LyricsDocument {
        LyricsDocument(trackID: track.id, kind: .synced, lines: [
            LyricLine(id: 0, time: 0, text: "A line for testing the player"),
            LyricLine(id: 1, time: 20, text: "The next line follows the music"),
            LyricLine(id: 2, time: 40, text: "Tap a line to move through the song"),
            LyricLine(id: 3, time: 60, text: "Your place stays with you")], source: "Synthetic UI fixture")
    }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        let directory = await DebugBootstrap.fixtureAudioDirectory ?? FileManager.default.temporaryDirectory
        let url = try await Self.fileURL(in: directory)
        return ResolvedStream(url: url, duration: track.duration, expiresAt: nil)
    }

    static func fileURL(in directory: URL) async throws -> URL {
        try await DebugFixtureAudio.waveform(in: directory)
    }

    @MainActor static func seed(_ library: LibraryStore) {
        guard library.events.isEmpty else { return }
        for (index, track) in tracks.enumerated() {
            library.toggleFavorite(track)
            library.recordRecent(track: track, position: Double(index * 12))
            for day in 0..<(6 - index) {
                library.recordListening(track: track, sessionID: UUID(), startedAt: Date().addingTimeInterval(-Double(day) * 86_400 - 900), seconds: track.duration ?? 200)
            }
        }
        let id = library.createPlaylist(name: "Late night favorites")
        tracks.forEach { library.add($0, to: id) }
    }
}

private actor DebugSearchControl {
    let delay: Duration
    private var failuresRemaining: Int

    init(delay: Duration, failOnce: Bool) {
        self.delay = delay
        failuresRemaining = failOnce ? 1 : 0
    }

    func beforeRequest() async throws {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MusicServiceError.network("Synthetic catalog search failure. Try again.")
        }
    }
}

private struct DebugSearchFixtureCatalog: MusicCatalogProviding, AlbumDescriptionProviding {
    let base: any MusicCatalogProviding
    let control: DebugSearchControl

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        try await control.beforeRequest()
        return try await base.search(query: query, filter: filter, continuation: continuation)
    }

    func browse(id: String) async throws -> CatalogPage { try await base.browse(id: id) }
    func artist(id: String) async throws -> ArtistPage { try await base.artist(id: id) }
    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        try await base.recommendations(seed: seed, language: language)
    }
    func radio(seed: Track) async throws -> [Track] { try await base.radio(seed: seed) }
    func radio(seed: Track, forceRefresh: Bool) async throws -> [Track] { try await base.radio(seed: seed, forceRefresh: forceRefresh) }
    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] { try await base.discovery(languages: languages) }
    func albumDescription(id: String) async throws -> AlbumDescription? {
        try await (base as? any AlbumDescriptionProviding)?.albumDescription(id: id)
    }
}

actor DebugExperienceRadioControl {
    let delay: Duration
    private var failuresRemaining: Int

    init(delay: Duration, failuresRemaining: Int) {
        self.delay = delay
        self.failuresRemaining = failuresRemaining
    }

    func beforeRequest() async throws {
        try await Task.sleep(for: delay)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MusicServiceError.unavailable("Synthetic radio connection failure")
        }
    }
}

struct DebugDelayedAudioResolver: StreamResolving {
    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await Task.sleep(for: .seconds(4))
        return try await DebugMusicFixtures().resolve(track: track, forceRefresh: forceRefresh)
    }
}

actor DebugFailOnceAudioResolver: StreamResolving {
    private var hasFailed = false
    let delay: Duration

    init(delay: Duration) { self.delay = delay }

    func resolve(track: Track, forceRefresh: Bool) async throws -> ResolvedStream {
        try await Task.sleep(for: delay)
        if !hasFailed {
            hasFailed = true
            throw MusicServiceError.unavailable("Synthetic audio connection failure")
        }
        return try await DebugMusicFixtures().resolve(track: track, forceRefresh: forceRefresh)
    }
}
#endif
