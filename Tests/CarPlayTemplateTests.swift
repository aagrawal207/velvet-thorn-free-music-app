import CarPlay
import XCTest
@testable import GanaBajana

@MainActor
final class CarPlayTemplateTests: CarPlayTestCase {
    func testRootAndNowPlayingAreConfiguredBeforeTheRootCompletion() async throws {
        let context = try makeContext()
        let interface = CarPlayTestInterface()
        interface.automaticallyCompletes = false
        let session = makeSession(context: context, interface: interface,
                                  limits: CarPlayTemplateLimits(tabs: 9, items: 20, sections: 1))
        let root = try XCTUnwrap(session.rootTemplate as? CPTabBarTemplate)
        XCTAssertEqual(root.templates.count, 4)
        XCTAssertEqual(root.templates.map(\.tabTitle), ["Favorites", "Recently played", "Playlists", "Queue"])
        XCTAssertTrue(root.templates.allSatisfy { $0.tabImage != nil })
        XCTAssertEqual(interface.buttonsAtRootInstallation, [3])
        XCTAssertEqual(interface.upNextAtRootInstallation, [true])
        XCTAssertFalse(CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled)
        XCTAssertTrue(CPNowPlayingTemplate.shared.nowPlayingButtons.allSatisfy { !$0.isEnabled })
        let favorites = try rootList(session, at: 0)
        XCTAssertEqual(favorites.itemCount, 0)
        XCTAssertEqual(favorites.emptyViewTitleVariants.first, "Loading your library…")
        if #available(iOS 18.4, *) { XCTAssertTrue(favorites.showsSpinnerWhileEmpty) }
        try interface.completeNext()
        try await AppModelFixtures.eventually { favorites.emptyViewTitleVariants.first == "No favorites yet" }
        if #available(iOS 18.4, *) { XCTAssertFalse(favorites.showsSpinnerWhileEmpty) }
        XCTAssertEqual(favorites.trailingNavigationBarButtons.first?.title, "Reload")
    }

    func testFewerSupportedTabsUseTheBridgeLibraryRootWithoutDroppingQueue() async throws {
        let context = try makeContext()
        let interface = CarPlayTestInterface()
        let session = makeSession(context: context, interface: interface,
                                  limits: CarPlayTemplateLimits(tabs: 2, items: 20, sections: 1))
        let root = try XCTUnwrap(session.rootTemplate as? CPListTemplate)
        try await waitForRows(4, in: root)
        XCTAssertEqual(rows(root).map(\.text), ["Favorites", "Recently played", "Playlists", "Queue"])
        XCTAssertTrue(rows(root).allSatisfy { $0.accessoryType == .disclosureIndicator })
        try select(try XCTUnwrap(rows(root).last))
        let queue = try XCTUnwrap(interface.topTemplate as? CPListTemplate)
        XCTAssertEqual(queue.title, "Queue")
        XCTAssertEqual(queue.emptyViewTitleVariants.first, "Your queue is empty")
    }

    func testPageLimitPreservesOpaqueRowIdentityAndRetiresOldHandlers() throws {
        let factory = CarPlayListTemplates(limits: CarPlayTemplateLimits(tabs: 4, items: 2, sections: 1))
        let list = factory.make(location: "queue", title: "Queue", connection: UUID()) { _ in }
        let selected = CarPlaySelectedItems()
        let page = CompanionPage(location: "queue", title: "Queue", revision: "revision-a", items: [
            CompanionItem(id: "occurrence:0", title: "Same song", subtitle: "First occurrence"),
            CompanionItem(id: "occurrence:1", title: "Same song", subtitle: "Second occurrence"),
            CompanionItem(id: "occurrence:2", title: "Hidden song", subtitle: "Outside CarPlay limit")
        ], isTruncated: false)
        factory.display(page, sessionID: UUID(), on: list) { selected.items.append($0) }
        XCTAssertEqual(list.sectionCount, 1)
        XCTAssertEqual(list.itemCount, 2)
        XCTAssertTrue(list.sections[0].header?.contains("More on iPhone") == true)
        let oldRow = try XCTUnwrap(rows(list).last)
        let completion = try select(oldRow)
        XCTAssertEqual(selected.items.map(\.id), ["occurrence:1"])
        factory.display(CompanionPage(location: "queue", title: "Queue", revision: "revision-b", items: [], isTruncated: false),
                        sessionID: UUID(), on: list) { selected.items.append($0) }
        try select(oldRow)
        XCTAssertEqual(selected.items.count, 1)
        XCTAssertEqual(completion.value, 1)
        XCTAssertEqual(list.itemCount, 0)
    }

    func testBridgeTruncationIsShownEvenWhenAllReceivedRowsFit() throws {
        let factory = CarPlayListTemplates(limits: CarPlayTemplateLimits(tabs: 4, items: 20, sections: 1))
        let list = factory.make(location: "favorites", title: "Favorites", connection: UUID()) { _ in }
        factory.display(CompanionPage(location: "favorites", title: "Favorites", revision: "r", items: [
            CompanionItem(id: "item:0", title: "A song", subtitle: "An artist")
        ], isTruncated: true), sessionID: UUID(), on: list) { _ in }
        XCTAssertEqual(list.itemCount, 1)
        XCTAssertEqual(list.sections.first?.header, "First 1 item · More on iPhone")
    }

    func testErrorRowsReserveRetryWithinAOneItemLimit() throws {
        let factory = CarPlayListTemplates(limits: CarPlayTemplateLimits(tabs: 4, items: 1, sections: 1))
        let list = factory.make(location: "queue", title: "Queue", connection: UUID()) { _ in }
        let retries = CarPlayCompletionCount()
        factory.error(on: list, title: "Couldn’t load", message: "Vehicle disconnected") { retries.value += 1 }
        XCTAssertEqual(list.itemCount, 1)
        let retry = try retryRow(list)
        XCTAssertEqual(retry.detailText, "Vehicle disconnected")
        try select(retry)
        XCTAssertEqual(retries.value, 1)
        factory.loading(list)
        try select(retry)
        XCTAssertEqual(retries.value, 1, "A retired Retry callback must not restart an obsolete request")
    }

    func testZeroItemOrSectionCapacityUsesAnEmptyMessageAndToolbarRetry() {
        for limit in [CarPlayTemplateLimits(tabs: 0, items: 0, sections: 1), CarPlayTemplateLimits(tabs: 0, items: 10, sections: 0)] {
            let factory = CarPlayListTemplates(limits: limit)
            let list = factory.make(location: "queue", title: "Queue", connection: UUID()) { _ in }
            factory.error(on: list, title: "Not ready", message: "Try again") { }
            XCTAssertEqual(list.itemCount, 0)
            XCTAssertEqual(list.sectionCount, 0)
            XCTAssertEqual(list.emptyViewTitleVariants, ["Not ready"])
            XCTAssertEqual(list.trailingNavigationBarButtons.first?.title, "Retry")
        }
    }
}

@MainActor
private final class CarPlaySelectedItems {
    var items: [CompanionItem] = []
}
