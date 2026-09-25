import XCTest
@testable import GanaBajana

@MainActor
final class WidgetPublisherLibraryCallbackTests: XCTestCase {
    func testCallbackObservesDurableDocumentsAndSkipsRejectedCandidatesAndNoOpSaves() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory, now: { RecommendationFixtures.now })
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            var callbacks = 0
            var syncChanges = 0
            library.onSyncChange = { syncChanges += 1 }
            library.onWidgetLibraryChange = { [weak library] in
                guard let library else { return }
                callbacks += 1
                let saved = try? LibraryPersistence.decode(Data(contentsOf: url), now: RecommendationFixtures.now)
                XCTAssertEqual(saved?.favorites, library.favorites)
                XCTAssertEqual(saved?.preferences, library.preferences)
                XCTAssertEqual(saved?.playback.position, library.playback.position)
                XCTAssertTrue(library.widgetLibrarySourceIsAvailable)
            }
            library.toggleFavorite(libraryTestTrack())
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(syncChanges, 1)
            let bytes = try Data(contentsOf: url)
            library.toggleFavorite(Track(id: "bad", title: "Rejected", duration: -1))
            XCTAssertNotNil(library.errorMessage)
            XCTAssertEqual(callbacks, 1)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            library.updatePlayback(PlaybackSnapshot(queue: [libraryTestTrack()], position: 9))
            XCTAssertEqual(callbacks, 2)
            library.updatePlayback(library.playback)
            XCTAssertEqual(callbacks, 2)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            XCTAssertEqual(callbacks, 3)
            XCTAssertTrue(library.recordTip(transactionID: 1, credited: true))
            XCTAssertEqual(callbacks, 3)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(callbacks, 4, "A validated reload is observable even when its projected content is equal")
        }
    }

    func testExternalChangesNotifyUnavailableOnceAndRecoveryObservesValidatedReplacement() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("original"))
            var availability: [Bool] = []
            library.onWidgetLibraryChange = { [weak library] in availability.append(library?.widgetLibrarySourceIsAvailable == true) }
            let external = LibraryStore(directory: directory)
            external.toggleFavorite(libraryTestTrack("external"))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let durable = try Data(contentsOf: url)

            library.toggleFavorite(libraryTestTrack("rejected-candidate"))

            XCTAssertEqual(availability, [false])
            XCTAssertTrue(library.requiresReload)
            XCTAssertEqual(library.favorites.map(\.id), ["original"])
            library.toggleFavorite(libraryTestTrack("another-rejected-candidate"))
            XCTAssertEqual(availability, [false])
            XCTAssertEqual(try Data(contentsOf: url), durable)
            XCTAssertEqual(library.reloadFromDisk(), .reloaded)
            XCTAssertEqual(availability, [false, true])
            XCTAssertEqual(library.favorites.map(\.id), ["external", "original"])
        }
    }

    func testUnreadableFileFailureNotifiesUnavailableWithoutChangingExistingRecoverySemantics() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.toggleFavorite(libraryTestTrack("saved"))
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let backup = directory.appendingPathComponent("saved-backup.json")
            try FileManager.default.moveItem(at: url, to: backup)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            var availability: [Bool] = []
            library.onWidgetLibraryChange = { [weak library] in availability.append(library?.widgetLibrarySourceIsAvailable == true) }

            library.toggleFavorite(libraryTestTrack("unsaved"))

            XCTAssertEqual(availability, [false])
            XCTAssertEqual(library.favorites.map(\.id), ["saved"])
            XCTAssertNotNil(library.errorMessage)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: backup, to: url)
            library.toggleFavorite(libraryTestTrack("retry"))
            XCTAssertEqual(availability, [false, true])
            XCTAssertEqual(library.favorites.map(\.id), ["retry", "saved"])
        }
    }

    func testDirectValidationNotifiesEachAvailabilityTransitionOnceIncludingReentrantValidation() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory, now: { RecommendationFixtures.now })
            library.recordRecent(track: libraryTestTrack("private-recent"), position: 9)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let original = try Data(contentsOf: url)
            var availability: [Bool] = []
            library.onWidgetLibraryChange = { [weak library] in
                guard let library else { return }
                let available = library.widgetLibrarySourceIsAvailable
                availability.append(available)
                if availability.count <= 2 {
                    XCTAssertEqual(library.validateWidgetLibrarySource(), available)
                }
            }
            let external = LibraryStore(directory: directory, now: { RecommendationFixtures.now })
            external.clearHistory()
            XCTAssertNil(external.errorMessage)

            XCTAssertFalse(library.validateWidgetLibrarySource())
            XCTAssertEqual(availability, [false])
            XCTAssertFalse(library.validateWidgetLibrarySource())
            XCTAssertEqual(availability, [false])

            try original.write(to: url, options: .atomic)
            XCTAssertTrue(library.validateWidgetLibrarySource())
            XCTAssertEqual(availability, [false, true])
            XCTAssertTrue(library.validateWidgetLibrarySource())
            XCTAssertEqual(availability, [false, true])
        }
    }
}
