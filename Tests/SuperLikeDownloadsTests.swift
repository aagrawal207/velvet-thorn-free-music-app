import Foundation
import XCTest
@testable import GanaBajana

/// Download Liked Songs as a three-way scope: the derived preference over its two lenient leaves, the sync leaf,
/// the Liked Songs and Downloads filters, and the model's per-scope automatic downloads.
@MainActor
final class SuperLikeDownloadsTests: XCTestCase {
    private let a = "fsiPzT50ZiM"
    private let b = "NJAv_7lHUIU"
    private let c = "J7p4bzqLvCw"
    private let d = "FOA9iyxsW_A"

    // MARK: - Preference

    func testAutoDownloadScopeWritesBothLeavesAndReadsALegacyAllLikedFile() {
        XCTAssertEqual(AutoDownloadScope.allCases, [.off, .superLiked, .liked])
        XCTAssertEqual(AutoDownloadScope.allCases.map(\.rawValue), ["off", "superLiked", "liked"])
        XCTAssertEqual(AutoDownloadScope.allCases.map(\.id), ["off", "superLiked", "liked"])
        XCTAssertEqual(AutoDownloadScope.allCases.map(\.title), ["Off", "Super Liked Only", "All Liked"])
        XCTAssertEqual(AutoDownloadScope.allCases.map(\.settingsTitle), ["Off", "Super Liked Only", "All Liked"])

        var preferences = UserPreferences()
        XCTAssertEqual(preferences.autoDownloadScope, .off)
        XCTAssertFalse(preferences.autoDownloadLikedSongs)
        XCTAssertFalse(preferences.autoDownloadSuperLikedSongs)

        preferences.autoDownloadScope = .superLiked
        XCTAssertFalse(preferences.autoDownloadLikedSongs)
        XCTAssertTrue(preferences.autoDownloadSuperLikedSongs)
        XCTAssertEqual(preferences.autoDownloadScope, .superLiked)

        preferences.autoDownloadScope = .liked
        XCTAssertTrue(preferences.autoDownloadLikedSongs)
        XCTAssertTrue(preferences.autoDownloadSuperLikedSongs, "All Liked implies Super Liked Only")
        XCTAssertEqual(preferences.autoDownloadScope, .liked)

        preferences.autoDownloadScope = .off
        XCTAssertFalse(preferences.autoDownloadLikedSongs)
        XCTAssertFalse(preferences.autoDownloadSuperLikedSongs)
        XCTAssertEqual(preferences.autoDownloadScope, .off)

        // A file saved before the tier existed carries only the All Liked leaf.
        var legacy = UserPreferences()
        legacy.autoDownloadLikedSongs = true
        XCTAssertEqual(legacy.autoDownloadScope, .liked)
        // The two leaves merge independently; when they disagree, All Liked wins in effect.
        legacy.autoDownloadSuperLikedSongs = false
        XCTAssertEqual(legacy.autoDownloadScope, .liked)
        XCTAssertNotEqual(legacy, UserPreferences(), "The Bool leaves stay the stored fields; the scope is derived")
    }

    func testAutoDownloadSuperLikedSongsDecodesLenientlyAndTravelsAsItsOwnSyncLeaf() throws {
        let decode = { (json: String) in try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8)) }
        XCTAssertEqual(try decode("{}"), UserPreferences())
        XCTAssertFalse(try decode("{}").autoDownloadSuperLikedSongs, "Absent reads as the default")
        for json in [#"{"autoDownloadSuperLikedSongs":null}"#, #"{"autoDownloadSuperLikedSongs":1}"#,
                     #"{"autoDownloadSuperLikedSongs":"yes"}"#, #"{"autoDownloadSuperLikedSongs":[true]}"#,
                     #"{"autoDownloadSuperLikedSongs":{"on":true}}"#] {
            let decoded = try decode(json)
            XCTAssertFalse(decoded.autoDownloadSuperLikedSongs, json)
            XCTAssertEqual(decoded, UserPreferences(), "An unreadable value falls back without blocking the file: \(json)")
        }
        XCTAssertTrue(try decode(#"{"autoDownloadSuperLikedSongs":true}"#).autoDownloadSuperLikedSongs)
        XCTAssertEqual(try decode(#"{"autoDownloadSuperLikedSongs":true}"#).autoDownloadScope, .superLiked)
        XCTAssertEqual(try decode(#"{"autoDownloadLikedSongs":true}"#).autoDownloadScope, .liked,
                       "A file written before the tier existed reads as All Liked")
        XCTAssertEqual(try decode(#"{"autoDownloadLikedSongs":true,"autoDownloadSuperLikedSongs":false}"#).autoDownloadScope, .liked)
        XCTAssertEqual(try decode(#"{"autoDownloadLikedSongs":true,"autoDownloadSuperLikedSongs":"broken"}"#).autoDownloadScope, .liked)
        XCTAssertEqual(try decode(#"{"autoDownloadLikedSongs":false,"autoDownloadSuperLikedSongs":true}"#).autoDownloadScope, .superLiked)

        // One leaf beside autoDownloadLikedSongs, so each merges on its own.
        let defaults = try LibrarySyncPreferences.fields(UserPreferences())
        XCTAssertEqual(defaults["autoDownloadSuperLikedSongs"], Data("false".utf8))
        XCTAssertEqual(defaults["autoDownloadLikedSongs"], Data("false".utf8))
        var superLikedOnly = UserPreferences()
        superLikedOnly.autoDownloadScope = .superLiked
        let superLikedFields = try LibrarySyncPreferences.fields(superLikedOnly)
        XCTAssertEqual(superLikedFields["autoDownloadSuperLikedSongs"], Data("true".utf8))
        XCTAssertEqual(superLikedFields["autoDownloadLikedSongs"], Data("false".utf8))
        XCTAssertEqual(superLikedFields.filter { defaults[$0.key] != $0.value }.keys.sorted(), ["autoDownloadSuperLikedSongs"])
        XCTAssertEqual(try LibrarySyncPreferences.applying(superLikedFields, to: UserPreferences()), superLikedOnly)
        var allLiked = UserPreferences()
        allLiked.autoDownloadScope = .liked
        let allLikedFields = try LibrarySyncPreferences.fields(allLiked)
        XCTAssertEqual(allLikedFields.filter { defaults[$0.key] != $0.value }.keys.sorted(),
                       ["autoDownloadLikedSongs", "autoDownloadSuperLikedSongs"])
        XCTAssertEqual(try LibrarySyncPreferences.applying(["autoDownloadSuperLikedSongs": Data("true".utf8)], to: UserPreferences()),
                       superLikedOnly)
        // A remote All Liked leaf alone still reads as All Liked on a device that never saw the new leaf's value.
        XCTAssertEqual(try LibrarySyncPreferences.applying(["autoDownloadLikedSongs": Data("true".utf8)], to: UserPreferences()).autoDownloadScope,
                       .liked)
        XCTAssertThrowsError(try LibrarySyncPreferences.applying(["autoDownloadSuperLikedSongs": Data("1".utf8)], to: UserPreferences()),
                             "A remote value the lenient decoder would rewrite is refused, like every other clamped leaf")

        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let first = harness.device()
        let second = harness.device(LibrarySyncTestData.b)
        first.library.preferences = superLikedOnly
        XCTAssertNil(first.library.errorMessage)
        XCTAssertEqual(try first.state().registers.keys.filter { $0.collection == .preference }.map(\.id), ["autoDownloadSuperLikedSongs"])
        try second.library.mergeCloudState(first.state())
        XCTAssertEqual(second.library.preferences.autoDownloadScope, .superLiked)
        XCTAssertEqual(try second.saved().preferences, superLikedOnly)
    }

    // MARK: - Filters

    func testLikedSongsAndDownloadsFiltersListSuperLikedSecondWithStableKeysAndCopy() {
        XCTAssertEqual(LikedSongsFilter.allCases, [.all, .superLiked, .downloaded, .onDevice])
        XCTAssertEqual(LikedSongsFilter.allCases.map(\.key), ["all", "superLiked", "downloaded", "onDevice"])
        XCTAssertEqual(LikedSongsFilter.allCases.map(\.title), ["All", "Super Liked", "Downloaded", "On This Device"])
        XCTAssertEqual(LikedSongsFilter.superLiked.queueTitle, "super liked songs")
        XCTAssertEqual(LikedSongsFilter.superLiked.symbol, "bolt.heart.fill")
        XCTAssertEqual(LikedSongsFilter.superLiked.emptyTitle, "No Super Likes Yet")
        XCTAssertEqual(LikedSongsFilter.superLiked.emptyMessage, "Hold the heart on a song you love, or choose Super Like from its menu.")
        XCTAssertEqual(LikedSongsFilter.downloaded.symbol, "arrow.down.circle")
        XCTAssertEqual(LikedSongsFilter.downloaded.emptyTitle, "No Downloaded Likes")
        XCTAssertEqual(LikedSongsFilter.onDevice.emptyTitle, "No Likes on This Device")

        XCTAssertEqual(DownloadsFilter.allCases, [.all, .superLiked, .liked, .notLiked])
        XCTAssertEqual(DownloadsFilter.allCases.map(\.key), ["all", "superLiked", "liked", "notLiked"])
        XCTAssertEqual(DownloadsFilter.allCases.map(\.title), ["All", "Super Liked", "Liked", "Not Liked"])
        XCTAssertEqual(DownloadsFilter.superLiked.emptySymbol, "bolt.heart.fill")
        XCTAssertEqual(DownloadsFilter.superLiked.emptyTitle, "No Super Liked Downloads")
        XCTAssertEqual(DownloadsFilter.superLiked.emptyMessage, "No super liked songs are downloaded. Super like a downloaded song to see it here.")
        XCTAssertEqual(DownloadsFilter.liked.emptyTitle, "No Liked Downloads")
        XCTAssertEqual(DownloadsFilter.notLiked.emptyTitle, "All Downloads Are Liked")
        XCTAssertEqual(DownloadsFilter.notLiked.emptySymbol, "heart.slash")
    }

    func testLikedSongsFilterClassifiesTheSuperLikedTierWithinFavorites() throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let model = context.model
        let liked = Self.track(a)
        let superLiked = Self.track(b)
        model.toggleLike(liked, surface: .library)
        model.toggleSuperLike(superLiked, surface: .library)
        XCTAssertEqual(model.library.favorites.map(\.id), [b, a], "A promotion is the newest reaction")
        XCTAssertTrue(LikedSongsFilter.superLiked.includes(superLiked, in: model))
        XCTAssertFalse(LikedSongsFilter.superLiked.includes(liked, in: model))
        XCTAssertTrue(LikedSongsFilter.all.includes(liked, in: model))
        XCTAssertTrue(LikedSongsFilter.all.includes(superLiked, in: model))
        XCTAssertFalse(LikedSongsFilter.downloaded.includes(superLiked, in: model), "The tier says nothing about local copies")
        XCTAssertFalse(LikedSongsFilter.onDevice.includes(superLiked, in: model))
        XCTAssertEqual(model.library.favorites.filter { LikedSongsFilter.superLiked.includes($0, in: model) }.map(\.id), [b])

        model.toggleSuperLike(superLiked, surface: .library)
        XCTAssertFalse(LikedSongsFilter.superLiked.includes(superLiked, in: model), "Change to Like leaves the tier")
        XCTAssertTrue(model.library.isFavorite(superLiked), "and keeps the like")
        model.toggleLike(superLiked, surface: .library)
        XCTAssertFalse(model.library.isFavorite(superLiked), "Unlike removes the song from Liked Songs completely")
        XCTAssertFalse(LikedSongsFilter.superLiked.includes(superLiked, in: model))
    }

    // MARK: - Automatic downloads

    func testFavoritesChangedQueuesPerScopeAndTheBacklogFollowsTheScope() async throws {
        let center = try makeDownloadCenter()
        let model = try makeModel(downloads: center)
        let (songA, songB, songC, songD) = (Self.track(a), Self.track(b), Self.track(c), Self.track(d))

        // Off: neither a like nor a promotion queues anything.
        model.toggleLike(songA, surface: .library)
        model.toggleSuperLike(songB, surface: .library)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(center.items.isEmpty, "Off downloads nothing")
        XCTAssertEqual(model.pendingAutoDownloads(for: .off), [])
        XCTAssertEqual(model.pendingAutoDownloads(for: .superLiked).map(\.id), [b])
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked).map(\.id), [b, a], "Liked Songs order, newest first")
        XCTAssertEqual(model.pendingLikedDownloads.map(\.id), [b, a], "The legacy backlog is the All Liked scope")

        // Super Liked Only: a plain like does nothing; promoting an already liked song queues it.
        model.updatePreferences { $0.autoDownloadScope = .superLiked }
        XCTAssertEqual(model.library.preferences.autoDownloadScope, .superLiked)
        model.toggleLike(songC, surface: .library)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(center.items.isEmpty, "A like is outside Super Liked Only")
        model.toggleSuperLike(songC, surface: .library)
        try await PlaybackTestSupport.waitUntil { center.items.map(\.id) == [self.c] }
        XCTAssertTrue(center.isQueued(c))
        XCTAssertFalse(center.isQueued(b), "Changing the scope is the confirmation's decision, not an implicit backlog")
        XCTAssertEqual(model.pendingAutoDownloads(for: .superLiked).map(\.id), [b], "Queued songs leave the backlog")
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked).map(\.id), [b, a])

        // All Liked: a new like queues on its own.
        model.updatePreferences { $0.autoDownloadScope = .liked }
        model.toggleLike(songD, surface: .library)
        try await PlaybackTestSupport.waitUntil { center.items.map(\.id) == [self.c, self.d] }
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked).map(\.id), [b, a])
        XCTAssertEqual(model.pendingAutoDownloads(for: .superLiked).map(\.id), [b])

        // The confirmation's Download action queues the remaining backlog for the chosen scope in Liked Songs order.
        model.downloadPendingAutoDownloads(for: .liked)
        try await PlaybackTestSupport.waitUntil { center.items.map(\.id) == [self.c, self.d, self.b, self.a] }
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked), [])
        XCTAssertEqual(model.pendingAutoDownloads(for: .superLiked), [])

        // Narrowing the scope, demoting and unliking never remove a queued or downloaded song.
        model.updatePreferences { $0.autoDownloadScope = .off }
        model.toggleSuperLike(songC, surface: .library)
        model.toggleLike(songA, surface: .library)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.items.map(\.id), [c, d, b, a])
        XCTAssertFalse(model.library.isFavorite(songA))
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked), [], "An unliked song is no longer part of any backlog")
    }

    func testSuperLikedOnlyQueuesAPromotionOfANewSongAndSkipsSongsAlreadyDownloaded() async throws {
        let root = try makeRoot()
        let cache = Self.makeCache(root: root)
        // A complete copy already in the download tier, the way an earlier download left it.
        try Self.seedDownload(b, in: cache)
        let center = try makeDownloadCenter(cache: cache)
        let model = try makeModel(downloads: center)
        let (songA, songB) = (Self.track(a), Self.track(b))
        // The test player has no inventory, so the tier is observed through the center's promotion callback.
        center.download([songB])
        try await PlaybackTestSupport.waitUntil { model.isDownloaded(songB) }
        XCTAssertTrue(center.items.isEmpty)

        model.updatePreferences { $0.autoDownloadScope = .superLiked }
        model.toggleSuperLike(songA, surface: .library)
        try await PlaybackTestSupport.waitUntil { center.items.map(\.id) == [self.a] }
        XCTAssertTrue(model.library.isFavorite(songA), "Promoting an unliked song likes it too")
        XCTAssertTrue(model.library.isSuperLiked(songA))

        model.toggleSuperLike(songB, surface: .library)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(center.items.map(\.id), [a], "A downloaded song is never queued again")
        XCTAssertEqual(model.pendingAutoDownloads(for: .superLiked), [], "Downloaded and queued super likes are not part of the backlog")
        XCTAssertEqual(model.pendingAutoDownloads(for: .liked), [])

        model.updatePreferences { $0.autoDownloadScope = .off }
        model.toggleLike(songB, surface: .library)
        try await Task.sleep(for: .milliseconds(200))
        let stillDownloaded = await cache.isDownloaded(b)
        XCTAssertTrue(stillDownloaded, "Unliking never deletes a file")
        XCTAssertEqual(center.items.map(\.id), [a])
    }

    // MARK: - Helpers

    private static func track(_ id: String) -> Track {
        Track(id: id, title: "Song \(id)", artists: ["Fixture artist"], duration: 8, isAudioRecording: true)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajanaSuperLikeDownloadsTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static func makeCache(root: URL) -> AudioCache {
        AudioCache(directory: root.appendingPathComponent("Audio", isDirectory: true),
                   downloadsDirectory: root.appendingPathComponent("Downloads", isDirectory: true))
    }

    /// Known offline, the manager parks every uncached song as queued without a transfer, so the queue itself is the
    /// observable outcome and no network or gate is involved. Complete copies still promote.
    private func makeDownloadCenter(cache: AudioCache? = nil) throws -> DownloadCenter {
        let cache = try cache ?? Self.makeCache(root: makeRoot())
        let manager = DownloadManager(store: cache, transfer: { _ in throw URLError(.notConnectedToInternet) },
                                      connectivity: OfflineConnectivity(), queueFile: nil,
                                      configuration: DownloadManager.Configuration(allowOpus: false))
        let center = DownloadCenter(manager: manager)
        addTeardownBlock { @MainActor in
            center.cancelAll()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return center
    }

    /// Writes a complete WAV pair straight into the download tier, the way an earlier download left it.
    private static func seedDownload(_ id: String, in cache: AudioCache) throws {
        let payload = PlaybackTestSupport.audioData(seconds: 1)
        try FileManager.default.createDirectory(at: cache.downloadsDirectory, withIntermediateDirectories: true)
        try payload.write(to: cache.downloadsDirectory.appendingPathComponent("\(id).wav"))
        let sidecar = AudioCache.Sidecar(duration: 1, bytes: Int64(payload.count), storedAt: Date(), fileExtension: "wav", downloaded: true)
        try JSONEncoder().encode(sidecar).write(to: cache.downloadsDirectory.appendingPathComponent("\(id).json"))
    }

    private func makeModel(downloads: DownloadCenter) throws -> MusicAppModel {
        let context = try AppModelTestContext()
        let model = MusicAppModel(library: context.library, player: context.player, catalog: context.catalog,
                                  charts: context.charts, lyrics: context.lyrics, account: context.model.account,
                                  appIcons: context.model.appIcons, recordingLanguageService: context.model.recordingLanguageService,
                                  languageDiscovery: context.model.languageDiscovery,
                                  connectivity: ConnectivityMonitor(initialStatus: .online, monitorsSystem: false),
                                  downloads: downloads, generatesMixes: false)
        addTeardownBlock { @MainActor in
            model.deactivateDeviceServices()
            try await context.close()
        }
        return model
    }
}

private struct OfflineConnectivity: DownloadConnectivity {
    var isOffline: Bool { true }
    var isExpensivePath: Bool { false }
}
