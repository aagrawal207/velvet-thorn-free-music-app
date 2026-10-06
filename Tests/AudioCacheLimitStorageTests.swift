import XCTest
@testable import GanaBajana

@MainActor
final class AudioCacheLimitStorageTests: XCTestCase {
    func testDefaultsUseOneGiBAndTwoHundredSongs() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let directory = fixture.root.appendingPathComponent("default-policy", isDirectory: true)
        let cache = AudioCache(directory: directory, session: fixture.mock.session)

        let usage = try await cache.storageUsage()

        XCTAssertEqual(UserPreferences().audioCacheLimit, .gb1)
        XCTAssertEqual(usage.capacityBytes, 1_073_741_824)
        XCTAssertEqual(usage.maximumSongs, 200)
        XCTAssertEqual(usage.bytes, 0)
    }

    func testEveryChoicePersistsWithoutChangingAccentHomeLayoutOrPlaybackPreferences() throws {
        XCTAssertEqual(AudioCacheLimit.allCases.map(\.bytes),
                       [262_144_000, 524_288_000, 1_073_741_824, 2_147_483_648, 5_368_709_120])
        XCTAssertEqual(AudioCacheLimit.allCases.map(\.maximumSongs), [50, 100, 200, 400, 1_000])
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            var preferences = library.preferences
            preferences.accent = .ocean
            preferences.appearance = .light
            preferences.crossfadeSeconds = 7
            preferences.languages = [.english]
            preferences.homeLayout = HomeLayoutPreferences(order: [.charts, .recentlyPlayed], hidden: [.discovery])
            for limit in AudioCacheLimit.allCases {
                preferences.audioCacheLimit = limit
                library.preferences = preferences
                XCTAssertNil(library.errorMessage)
                let restored = LibraryStore(directory: directory)
                XCTAssertEqual(restored.preferences, preferences)
                XCTAssertEqual(restored.preferences.audioCacheLimit, limit)
            }
        }
    }

    func testAnOldLibraryWithoutTheLimitGetsOneGiBAndPreservesOtherPreferences() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            var preferences = library.preferences
            preferences.accent = .teal
            preferences.appearance = .light
            preferences.crossfadeSeconds = 6
            preferences.audioCacheLimit = .gb5
            preferences.homeLayout.setVisible(false, for: .charts)
            library.preferences = preferences
            library.toggleFavorite(libraryTestTrack())
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var saved = try XCTUnwrap(document["preferences"] as? [String: Any])
            saved.removeValue(forKey: "audioCacheLimit")
            document["preferences"] = saved
            document["version"] = 1
            document.removeValue(forKey: "lifetimeListening")
            document.removeValue(forKey: "superLikedIDs")
            document.removeValue(forKey: "syncState")
            let legacy = try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
            try legacy.write(to: url, options: .atomic)

            let restored = LibraryStore(directory: directory)

            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.preferences.audioCacheLimit, .gb1)
            XCTAssertEqual(restored.preferences.accent, .teal)
            XCTAssertEqual(restored.preferences.appearance, .light)
            XCTAssertEqual(restored.preferences.crossfadeSeconds, 6)
            XCTAssertFalse(restored.preferences.homeLayout.isVisible(.charts))
            XCTAssertEqual(restored.favorites, [libraryTestTrack()])
            XCTAssertEqual(try Data(contentsOf: url), legacy, "Reading a missing optional preference needs no rewrite")
        }
    }

    func testAnUnknownStoredLimitDoesNotOverwriteTheLibrary() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack())
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var saved = try XCTUnwrap(document["preferences"] as? [String: Any])
            saved["audioCacheLimit"] = "unknown-limit"
            document["preferences"] = saved
            let unreadable = try JSONSerialization.data(withJSONObject: document)
            try unreadable.write(to: url, options: .atomic)

            let restored = LibraryStore(directory: directory)
            XCTAssertNotNil(restored.errorMessage)
            var preferences = restored.preferences
            preferences.audioCacheLimit = .mb500
            restored.preferences = preferences

            XCTAssertEqual(try Data(contentsOf: url), unreadable)
        }
    }

    func testModelPreferenceSelectionPersistsAndAppliesToItsExistingPlayer() async throws {
        let fixture = try CacheManagementFixture()
        addTeardownBlock { try await fixture.close() }
        let context = try AppModelTestContext(resolver: fixture.resolver())
        addTeardownBlock { try await context.close() }

        context.model.updatePreferences {
            $0.audioCacheLimit = .gb5
            $0.accent = .mint
            $0.homeLayout.setVisible(false, for: .newReleases)
        }
        try await PlaybackTestSupport.eventually {
            let usage = try? await context.player.audioCacheUsage()
            return usage?.capacityBytes == AudioCacheLimit.gb5.bytes && !context.player.isUpdatingAudioCacheLimit
        }

        let restored = LibraryStore(directory: context.directory)
        XCTAssertEqual(restored.preferences.audioCacheLimit, .gb5)
        XCTAssertEqual(restored.preferences.accent, .mint)
        XCTAssertFalse(restored.preferences.homeLayout.isVisible(.newReleases))
        XCTAssertNil(context.player.audioCacheLimitError)
        let usage = try await fixture.cache.storageUsage()
        XCTAssertEqual(usage.maximumSongs, 1_000)
        XCTAssertEqual(usage.capacityBytes, 5_368_709_120)
    }

    func testAnApplyFailureKeepsTheSavedChoiceAndReportsTheActualPolicy() async throws {
        let fixture = try CacheManagementFixture(capacityBytes: AudioCacheLimit.gb1.bytes, maximumFiles: 200)
        addTeardownBlock { try await fixture.close() }
        let blocker = Data("cannot open this as a cache directory".utf8)
        try blocker.write(to: fixture.cache.directory)
        let context = try AppModelTestContext(resolver: fixture.resolver())
        addTeardownBlock { try await context.close() }

        context.model.updatePreferences { $0.audioCacheLimit = .mb500 }
        try await PlaybackTestSupport.waitUntil {
            !context.player.isUpdatingAudioCacheLimit && context.player.audioCacheLimitError != nil
        }

        XCTAssertEqual(context.library.preferences.audioCacheLimit, .mb500)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.audioCacheLimit, .mb500)
        XCTAssertNil(context.player.audioCacheLimitUsage)
        XCTAssertEqual(try Data(contentsOf: fixture.cache.directory), blocker)
        try FileManager.default.removeItem(at: fixture.cache.directory)
        let unchanged = try await fixture.cache.storageUsage()
        XCTAssertEqual(unchanged.capacityBytes, 1_073_741_824)
        XCTAssertEqual(unchanged.maximumSongs, 200)

        let retried = try await context.player.setAudioCacheLimit(context.library.preferences.audioCacheLimit).value
        XCTAssertEqual(retried?.capacityBytes, 524_288_000)
        XCTAssertEqual(retried?.maximumSongs, 100)
        XCTAssertNil(context.player.audioCacheLimitError)
    }
}
