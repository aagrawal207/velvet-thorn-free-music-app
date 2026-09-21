import SwiftUI
import XCTest
@testable import GanaBajana

@MainActor
final class AppNavigationIntentTests: XCTestCase {
    private let artist = MusicCollection(id: "UC-pending-artist", title: "Pending Artist", kind: .artist)

    func testLocalPresentationActionRetiresLookupBeforeShowingTheSheet() async throws {
        for result in lookupOutcomes {
            let context = try makeContext()
            let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
            let request = try await context.catalog.searches.request(at: 0)
            var presentations = 0
            AppNavigationIntent.perform(in: context.model) {
                XCTAssertFalse(context.model.isArtistLookupPending, "The old result must already be retired when presentation starts")
                presentations += 1
            }
            try await context.catalog.searches.complete(request, with: result)
            await task.value

            XCTAssertEqual(presentations, 1)
            assertOriginalNavigation(in: context)
        }
    }

    func testNativeSelectionActivationAndBackRetireLateSuccessMissAndFailure() async throws {
        for initiallyActive in [false, true] {
            for result in lookupOutcomes {
                let context = try makeContext()
                var isActive = initiallyActive
                let source = Binding(get: { isActive }, set: { value in
                    XCTAssertFalse(context.model.isArtistLookupPending)
                    isActive = value
                })
                let selection = AppNavigationIntent.binding(source, in: context.model)
                let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
                let request = try await context.catalog.searches.request(at: 0)
                selection.wrappedValue = !initiallyActive
                try await context.catalog.searches.complete(request, with: result)
                await task.value

                XCTAssertEqual(isActive, !initiallyActive)
                assertOriginalNavigation(in: context)
            }
        }
    }

    func testIdentifiedSheetReplacementAndDismissalRetireLookup() async throws {
        for dismisses in [false, true] {
            for result in lookupOutcomes {
                let context = try makeContext()
                var sheet: Sheet? = Sheet(id: "first", title: "First sheet")
                let presentation = AppNavigationIntent.binding(Binding(get: { sheet }, set: { sheet = $0 }),
                    in: context.model, identity: { $0?.id })
                let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
                let request = try await context.catalog.searches.request(at: 0)
                presentation.wrappedValue = dismisses ? nil : Sheet(id: "second", title: "Second sheet")
                try await context.catalog.searches.complete(request, with: result)
                await task.value

                XCTAssertEqual(sheet?.id, dismisses ? nil : "second")
                assertOriginalNavigation(in: context)
            }
        }
    }

    func testNestedPlayerOptionsPathChangesRetireLookup() async throws {
        for pushes in [false, true] {
            let context = try makeContext()
            var routes = ["playlists"]
            let path = AppNavigationIntent.binding(Binding(get: { routes }, set: { routes = $0 }), in: context.model)
            let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
            let request = try await context.catalog.searches.request(at: 0)
            path.wrappedValue = pushes ? ["playlists", "newPlaylist"] : []
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
            await task.value

            XCTAssertEqual(routes, pushes ? ["playlists", "newPlaylist"] : [])
            assertOriginalNavigation(in: context)
        }
    }

    func testBindingReconstructionReadsAndUnchangedWritesKeepTheCurrentLookup() async throws {
        for initiallyActive in [false, true] {
            let context = try makeContext()
            var isActive = initiallyActive
            let source = Binding(get: { isActive }, set: { isActive = $0 })
            let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
            let request = try await context.catalog.searches.request(at: 0)
            for _ in 0..<3 {
                let selection = AppNavigationIntent.binding(source, in: context.model)
                XCTAssertEqual(selection.wrappedValue, initiallyActive)
                selection.wrappedValue = initiallyActive
            }
            XCTAssertTrue(context.model.isArtistLookupPending)
            try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
            await task.value
            XCTAssertEqual(context.model.navigationPaths[.library], [artist])
        }
    }

    func testInactiveTabLinkUpdatesCannotRetireTheNewTabsArtistLookup() async throws {
        let context = try makeContext()
        var isActive = true
        let selection = AppNavigationIntent.binding(Binding(get: { isActive }, set: { isActive = $0 }),
            in: context.model, isCurrent: { context.model.selectedTab == .home })
        let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
        let request = try await context.catalog.searches.request(at: 0)
        selection.wrappedValue = false
        XCTAssertFalse(isActive)
        XCTAssertTrue(context.model.isArtistLookupPending)
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
        await task.value
        XCTAssertEqual(context.model.navigationPaths[.library], [artist])
    }

    func testSheetMetadataUpdatesWithTheSameIdentityDoNotCancelAnArtistOpen() async throws {
        let context = try makeContext()
        var sheet: Sheet? = Sheet(id: "options", title: "Old song title")
        let presentation = AppNavigationIntent.binding(Binding(get: { sheet }, set: { sheet = $0 }),
            in: context.model, identity: { $0?.id })
        let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
        let request = try await context.catalog.searches.request(at: 0)
        presentation.wrappedValue = Sheet(id: "options", title: "Updated song title")
        XCTAssertEqual(sheet?.title, "Updated song title")
        XCTAssertTrue(context.model.isArtistLookupPending)
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
        await task.value
        XCTAssertEqual(context.model.navigationPaths[.library], [artist])
    }

    func testDuplicateDismissalDoesNotCancelTheArtistOpenStartedAfterClosingTheSheet() async throws {
        let context = try makeContext()
        var sheet: Sheet? = Sheet(id: "artists", title: "Go to artist")
        let presentation = AppNavigationIntent.binding(Binding(get: { sheet }, set: { sheet = $0 }),
            in: context.model, identity: { $0?.id })
        AppNavigationIntent.perform(in: context.model) { sheet = nil }
        let task = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
        let request = try await context.catalog.searches.request(at: 0)
        presentation.wrappedValue = nil
        XCTAssertTrue(context.model.isArtistLookupPending, "UIKit can acknowledge a dismissal after its deferred artist action starts")
        try await context.catalog.searches.complete(request, with: .success(CatalogPage(collections: [artist])))
        await task.value
        XCTAssertEqual(context.model.navigationPaths[.library], [artist])
    }

    func testPresentationConsumesPendingSearchFocusWithoutChangingTheDraft() throws {
        let context = try makeContext()
        context.model.selectTab(.search)
        context.model.selectTab(.search)
        let focus = context.model.searchFocusRequest
        var presented = false
        AppNavigationIntent.perform(in: context.model) { presented = true }

        XCTAssertTrue(presented)
        XCTAssertFalse(context.model.consumeSearchFocusRequest(focus))
        XCTAssertEqual(context.model.searchFocusRequest, focus)
        XCTAssertEqual(context.model.searchQuery, "Unfinished draft")
        XCTAssertEqual(context.model.searchFilter, .albums)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
    }

    func testDelayedPopOrSheetDismissalPreservesANewerSearchReselectionFocusRequest() throws {
        let context = try makeContext()
        var isPresented = true
        let presentation = AppNavigationIntent.binding(Binding(get: { isPresented }, set: { isPresented = $0 }), in: context.model)
        context.model.selectTab(.search)
        context.model.selectTab(.search)
        let focus = context.model.searchFocusRequest
        presentation.wrappedValue = false
        presentation.wrappedValue = false

        XCTAssertTrue(context.model.consumeSearchFocusRequest(focus))
        XCTAssertFalse(context.model.consumeSearchFocusRequest(focus))
    }

    func testNavigationActionCanStartTheNewArtistIntentWithoutRetiringItAfterwards() async throws {
        let context = try makeContext()
        let oldTask = context.start { await $0.openArtist(ArtistCredit(name: self.artist.title)) }
        let oldRequest = try await context.catalog.searches.request(at: 0)
        let nextArtist = MusicCollection(id: "UC-next-artist", title: "Next Artist", kind: .artist)
        var nextTask: Task<Void, Never>?
        AppNavigationIntent.perform(in: context.model) {
            nextTask = context.start { await $0.openArtist(ArtistCredit(name: nextArtist.title)) }
        }
        let nextRequest = try await context.catalog.searches.request(at: 1)
        try await context.catalog.searches.complete(oldRequest, with: .failure(MusicServiceError.unavailable("Old lookup failed")))
        await oldTask.value
        XCTAssertTrue(context.model.isArtistLookupPending)
        try await context.catalog.searches.complete(nextRequest, with: .success(CatalogPage(collections: [nextArtist])))
        await nextTask?.value
        XCTAssertEqual(context.model.navigationPaths[.library], [nextArtist])
    }

    func testBindingForwardsTheNavigationTransactionIncludingUnchangedWrites() throws {
        let context = try makeContext()
        var selected = false
        var transactions: [Transaction] = []
        let source = Binding(get: { selected }, set: { value, transaction in
            selected = value
            transactions.append(transaction)
        })
        let selection = AppNavigationIntent.binding(source, in: context.model)
        var transaction = Transaction(animation: .linear(duration: 0.25))
        transaction.disablesAnimations = true
        selection.transaction(transaction).wrappedValue = true
        selection.transaction(transaction).wrappedValue = true

        XCTAssertTrue(selected)
        XCTAssertEqual(transactions.count, 2)
        XCTAssertTrue(transactions.allSatisfy(\.disablesAnimations))
        XCTAssertTrue(transactions.allSatisfy { $0.animation == transaction.animation })
    }

    private struct Sheet: Identifiable {
        let id: String
        let title: String
    }

    private var lookupOutcomes: [Result<CatalogPage, any Error>] {
        [.success(CatalogPage(collections: [artist])), .success(CatalogPage()),
         .failure(MusicServiceError.unavailable("Late artist lookup failed"))]
    }

    private func assertOriginalNavigation(in context: AppModelTestContext, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(context.model.isArtistLookupPending, file: file, line: line)
        XCTAssertEqual(context.model.selectedTab, .library, file: file, line: line)
        XCTAssertTrue(context.model.navigationPaths.isEmpty, file: file, line: line)
        XCTAssertEqual(context.model.searchQuery, "Unfinished draft", file: file, line: line)
        XCTAssertEqual(context.model.searchFilter, .albums, file: file, line: line)
    }

    private func makeContext() throws -> AppModelTestContext {
        let context = try AppModelTestContext()
        context.model.selectedTab = .library
        context.model.searchQuery = "Unfinished draft"
        context.model.searchFilter = .albums
        addTeardownBlock { @MainActor in try await context.close() }
        return context
    }
}
