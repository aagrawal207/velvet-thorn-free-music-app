// CarPlay templates exist only on iPhone; Mac Catalyst links the framework but cannot host its scenes.
#if !targetEnvironment(macCatalyst)
import CarPlay
import UIKit
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
        XCTAssertEqual(interface.buttonsAtRootInstallation, [4])
        XCTAssertEqual(interface.upNextAtRootInstallation, [true])
        XCTAssertFalse(CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled)
        XCTAssertTrue(CPNowPlayingTemplate.shared.nowPlayingButtons.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(CPNowPlayingTemplate.shared.nowPlayingButtons.map(\.accessibilityLabel),
                       ["Shuffle", "Repeat off", "Favorite", "Super like"])
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
    func testNowPlayingHeartButtonsShowTheTierAndRequestTheOppositeTier() throws {
        let sent = CarPlaySentRequests()
        let controls = CarPlayNowPlayingControls(request: { request, _ in sent.requests.append(request) }, upNext: { })
        addTeardownBlock { @MainActor in controls.disconnect() }
        XCTAssertEqual(controls.buttonStates.map(\.control), [.shuffle, .repeatMode, .favorite, .superLike])
        XCTAssertTrue(controls.buttons.allSatisfy { !$0.isEnabled })

        let plain = WatchTestSupport.snapshot(sequence: 1)
        let liked = WatchTestSupport.snapshot(sequence: 2, favorite: true)
        let superLiked = WatchTestSupport.snapshot(sequence: 3, favorite: true, superLiked: true)
        let expectations: [(CompanionSnapshot, [String], [String?], [Bool])] = [
            (plain, ["heart", "bolt.heart"], ["Favorite", "Super like"], [false, false]),
            (liked, ["heart.fill", "bolt.heart"], ["Remove favorite", "Super like"], [true, false]),
            (superLiked, ["bolt.heart.fill", "bolt.heart.fill"], ["Remove favorite", "Change to favorite"], [true, true]),
        ]
        for (snapshot, symbols, labels, selected) in expectations {
            controls.update(snapshot)
            let hearts = controls.buttonStates.suffix(2)
            XCTAssertEqual(hearts.map(\.control), [.favorite, .superLike])
            XCTAssertEqual(hearts.map(\.symbol), symbols)
            XCTAssertEqual(hearts.map(\.label), labels.compactMap { $0 })
            XCTAssertEqual(hearts.map(\.isSelected), selected)
            XCTAssertEqual(controls.buttons.count, 4)
            XCTAssertEqual(controls.buttons.suffix(2).map(\.accessibilityLabel), labels)
            XCTAssertEqual(controls.buttons.suffix(2).map(\.isSelected), selected)
            XCTAssertTrue(controls.buttons.allSatisfy(\.isEnabled))
            XCTAssertEqual(CPNowPlayingTemplate.shared.nowPlayingButtons.map(\.accessibilityLabel), controls.buttons.map(\.accessibilityLabel))
        }
        for state in controls.buttonStates { XCTAssertNotNil(UIImage(systemName: state.symbol), state.symbol) }

        controls.update(liked)
        let before = controls.buttons
        controls.update(WatchTestSupport.snapshot(sequence: 4, position: 50, favorite: true))
        XCTAssertTrue(zip(before, controls.buttons).allSatisfy { $0 === $1 }, "A position-only update keeps the buttons")
        controls.update(WatchTestSupport.snapshot(sequence: 5, position: 50, favorite: true, superLiked: true))
        XCTAssertFalse(zip(before, controls.buttons).contains { $0 === $1 }, "A tier-only change rebuilds the buttons")

        controls.activate(.superLike)
        controls.activate(.favorite)
        controls.update(plain)
        controls.activate(.superLike)
        controls.activate(.favorite)
        XCTAssertEqual(sent.requests.map(\.action), [.setSuperLiked(false), .setFavorite(false), .setSuperLiked(true), .setFavorite(true)])
        XCTAssertTrue(sent.requests.allSatisfy { $0.expectedTrackID == plain.nowPlaying?.trackID && $0.version == CompanionWire.version })
        controls.disconnect()
        controls.activate(.superLike)
        XCTAssertEqual(sent.requests.count, 4)
        XCTAssertTrue(controls.buttons.allSatisfy { !$0.isEnabled })
    }
}

@MainActor
private final class CarPlaySelectedItems {
    var items: [CompanionItem] = []
}

@MainActor
private final class CarPlaySentRequests {
    var requests: [CompanionRequest] = []
}
#endif
