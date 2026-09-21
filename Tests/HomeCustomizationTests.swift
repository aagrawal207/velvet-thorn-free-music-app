import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class HomeCustomizationTests: XCTestCase {
    func testDefaultHomeStartsWithRecentlyPlayed() {
        let layout = UserPreferences().homeLayout
        XCTAssertEqual(layout.orderedSections.map(\.rawValue), ["recentlyPlayed", "madeForYou", "newReleases", "becauseYouLike", "charts", "discovery"])
        XCTAssertEqual(layout.visibleSections, layout.orderedSections)
        XCTAssertTrue(layout.isDefault)
    }

    func testOldPreferencesWithoutHomeLayoutOrWithNullKeepTheirOtherChoices() throws {
        for explicitNull in [false, true] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.preferences.languages = [.english]
                document.preferences.saveListeningHistory = false
                document.preferences.autoplay = false
                document.favorites = [libraryTestTrack()]
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
                if explicitNull { preferences["homeLayout"] = NSNull() }
                else { preferences.removeValue(forKey: "homeLayout") }
                json["preferences"] = preferences
                let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)
                let store = LibraryStore(directory: directory)
                XCTAssertNil(store.errorMessage)
                XCTAssertEqual(store.preferences.languages, [.english])
                XCTAssertFalse(store.preferences.saveListeningHistory)
                XCTAssertFalse(store.preferences.autoplay)
                XCTAssertTrue(store.preferences.homeLayout.isDefault)
                XCTAssertEqual(store.preferences.homeLayout.visibleSections.first, .recentlyPlayed)
                XCTAssertEqual(store.favorites, document.favorites)
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testOrderAndVisibilityPersistTogetherWithoutChangingLibraryHistory() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let song = libraryTestTrack()
            store.toggleFavorite(song)
            store.recordRecent(track: song, position: 30)
            store.recordListening(track: song, sessionID: UUID(), startedAt: Date().addingTimeInterval(-90), seconds: 45)
            store.preferences.homeLayout.move(from: IndexSet(integer: 4), to: 0)
            store.preferences.homeLayout.setVisible(false, for: .recentlyPlayed)
            store.preferences.homeLayout.setVisible(false, for: .newReleases)
            let restored = LibraryStore(directory: directory)
            XCTAssertNil(restored.errorMessage)
            XCTAssertEqual(restored.preferences.homeLayout.orderedSections, [.charts, .recentlyPlayed, .madeForYou, .newReleases, .becauseYouLike, .discovery])
            XCTAssertEqual(restored.preferences.homeLayout.visibleSections, [.charts, .madeForYou, .becauseYouLike, .discovery])
            XCTAssertTrue(restored.preferences.saveListeningHistory)
            XCTAssertEqual(restored.favorites, [song])
            XCTAssertEqual(restored.recentlyPlayed.first?.position, 30)
            XCTAssertEqual(restored.events.first?.listenedSeconds, 45)
            restored.preferences.homeLayout.setVisible(true, for: .recentlyPlayed)
            XCTAssertEqual(restored.preferences.homeLayout.visibleSections.first, .charts)
            XCTAssertEqual(restored.preferences.homeLayout.visibleSections[1], .recentlyPlayed)
        }
    }

    func testAllHiddenIsAValidSavedChoiceAndResetRestoresTheDefaultOrder() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            for section in HomeSectionKind.allCases { store.preferences.homeLayout.setVisible(false, for: section) }
            store.preferences.homeLayout.move(from: IndexSet(integer: 5), to: 0)
            let restored = LibraryStore(directory: directory)
            XCTAssertTrue(restored.preferences.homeLayout.visibleSections.isEmpty)
            XCTAssertEqual(restored.preferences.homeLayout.orderedSections.first, .discovery)
            XCTAssertFalse(restored.preferences.homeLayout.isDefault)
            restored.preferences.homeLayout.reset()
            let reset = LibraryStore(directory: directory)
            XCTAssertEqual(reset.preferences.homeLayout.visibleSections, HomeSectionKind.allCases)
            XCTAssertTrue(reset.preferences.homeLayout.isDefault)
        }
    }

    func testFutureSectionIdentifiersArePreservedButNeverBlockKnownSections() throws {
        try withLibraryTestDirectory { directory in
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(LibraryDocument())) as? [String: Any])
            var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
            preferences["homeLayout"] = ["order": ["future-section", "charts", "recentlyPlayed", "charts"],
                                           "hidden": ["future-section", "recentlyPlayed"]]
            json["preferences"] = preferences
            let data = try JSONSerialization.data(withJSONObject: json)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try LibraryPersistence.write(data, to: url, replacing: nil)
            let store = LibraryStore(directory: directory)
            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.preferences.homeLayout.orderedSections, [.charts, .recentlyPlayed, .madeForYou, .newReleases, .becauseYouLike, .discovery])
            XCTAssertFalse(store.preferences.homeLayout.isVisible(.recentlyPlayed))
            store.preferences.homeLayout.move(from: IndexSet(integer: 0), to: 6)
            store.preferences.homeLayout.reset()
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let savedPreferences = try XCTUnwrap(saved["preferences"] as? [String: Any])
            let layout = try XCTUnwrap(savedPreferences["homeLayout"] as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(layout["order"] as? [String]).contains("future-section"))
            XCTAssertEqual(try XCTUnwrap(layout["hidden"] as? [String]), ["future-section"])
            XCTAssertTrue(LibraryStore(directory: directory).preferences.homeLayout.isDefault)
        }
    }

    func testPartialOrDuplicateOrdersAppendMissingKnownSectionsOnlyOnce() throws {
        let data = Data(#"{"order":["discovery","unknown","discovery"],"hidden":["charts"]}"#.utf8)
        let layout = try JSONDecoder().decode(HomeLayoutPreferences.self, from: data)
        XCTAssertEqual(layout.orderedSections, [.discovery, .recentlyPlayed, .madeForYou, .newReleases, .becauseYouLike, .charts])
        XCTAssertEqual(layout.visibleSections, [.discovery, .recentlyPlayed, .madeForYou, .newReleases, .becauseYouLike])
        let missing = try JSONDecoder().decode(HomeLayoutPreferences.self, from: Data("{}".utf8))
        XCTAssertTrue(missing.isDefault)
    }

    func testMovingSeveralSectionsUsesNativeListDestinationSemanticsAndRejectsInvalidMoves() {
        var layout = HomeLayoutPreferences()
        layout.move(from: IndexSet([0, 1]), to: 6)
        XCTAssertEqual(layout.orderedSections, [.newReleases, .becauseYouLike, .charts, .discovery, .recentlyPlayed, .madeForYou])
        let saved = layout
        layout.move(from: IndexSet(integer: 20), to: 0)
        layout.move(from: IndexSet(integer: 0), to: -1)
        layout.move(from: IndexSet(integer: 0), to: 20)
        XCTAssertEqual(layout, saved)
    }

    func testHomePreferenceEditsDoNotFetchCatalogDataOrDisableListeningCallbacks() async throws {
        let song = libraryTestTrack()
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: [song], position: 12))
        addTeardownBlock { @MainActor in try await context.close() }
        let playbackSettings = context.player.settings
        context.model.updatePreferences {
            $0.homeLayout.setVisible(false, for: .recentlyPlayed)
            $0.homeLayout.move(from: IndexSet(integer: 4), to: 0)
        }
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        XCTAssertTrue(progress(song, UUID(), Date().addingTimeInterval(-60), 30))
        XCTAssertEqual(context.player.currentTrack, song)
        XCTAssertEqual(context.player.position, 12)
        XCTAssertEqual(context.player.settings, playbackSettings)
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        XCTAssertEqual(context.library.recentlyPlayed.first?.track, song)
        XCTAssertEqual(context.library.events.first?.listenedSeconds, 30)
        let searches = await context.catalog.searches.requests
        let discovery = await context.catalog.discoveries.requests
        let radios = await context.catalog.autoplayRadios.requests
        let charts = await context.charts.charts.requests
        XCTAssertTrue(searches.isEmpty && discovery.isEmpty && radios.isEmpty && charts.isEmpty)
    }

    func testReleaseOnlyLoadingStaysVisibleUntilTheOriginalCheckFinishes() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        context.library.follow(FollowedArtist(id: "followed-fixture", name: "Followed artist", knownReleaseIDs: ["existing-release"]))
        let check = Task { await context.model.checkForNewReleases(force: true) }
        defer { check.cancel() }
        let request = try await context.catalog.artists.request(at: 0)
        XCTAssertTrue(context.model.isCheckingNewReleases)
        let overlapping = await context.model.checkForNewReleases(force: true)
        XCTAssertEqual(overlapping, 0)
        XCTAssertTrue(context.model.isCheckingNewReleases)
        try await context.catalog.artists.complete(request, with: .success(ArtistPage(id: "followed-fixture", name: "Followed artist")))
        _ = await check.value
        XCTAssertFalse(context.model.isCheckingNewReleases)
        let discoveries = await context.catalog.discoveries.requests
        let charts = await context.charts.charts.requests
        XCTAssertTrue(discoveries.isEmpty && charts.isEmpty)
    }
}
