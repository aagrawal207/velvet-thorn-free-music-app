import StoreKit
import StoreKitTest
import XCTest

@MainActor
final class GanaBajanaTipJarUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsShowsActualUSStoreKitProductsWithComfortableRowsAndBackNavigation() throws {
        _ = try makeSession()
        let ui = makeDriver()
        try ui.launch()
        try openTipJar(ui)
        XCTAssertEqual(ui.element("tipJar.explanation").label,
                       "An optional tip helps me keep improving Velvet Thorn. Tips are one-time purchases through Apple and unlock no features or music.")
        let expected = [
            ("small", "Small tip", "$3.00"), ("medium", "Generous tip", "$5.00"), ("large", "Big tip", "$10.00"),
            ("grand", "Grand tip", "$25.00"), ("patron", "Patron tip", "$50.00"),
        ]
        for (suffix, name, price) in expected {
            let row = ui.app.buttons["com.agraabhi.ganabajana.tip.\(suffix)"]
            try ui.reveal(row)
            let text = ui.accessibleText(row)
            XCTAssertTrue(text.contains(name))
            XCTAssertTrue(text.contains(price))
            XCTAssertTrue(row.isEnabled)
            XCTAssertGreaterThanOrEqual(row.frame.height + 1e-6, 52)
        }
        XCTAssertFalse(ui.element("tipJar.count").exists)
        XCTAssertFalse(ui.app.buttons["tipJar.retry"].exists)
        ui.capture("tip-jar-local-storekit-iphone17pro")
        try ui.tap(ui.app.navigationBars["Support Development"].buttons.firstMatch)
        try ui.wait("Back must return to the existing Settings navigation stack") {
            ui.app.navigationBars[SettingsPageID.about.title].exists && !ui.app.navigationBars["Support Development"].exists
        }
    }

    func testTwoNativeTipsShowThanksAndKeepTheirCountAfterRelaunch() throws {
        let session = try makeSession()
        let ui = makeDriver()
        try ui.launch(additionalArguments: ["--light"])
        try openTipJar(ui)
        for count in 1...2 {
            let row = ui.app.buttons["com.agraabhi.ganabajana.tip.small"]
            try ui.reveal(row)
            try ui.tap(row)
            try ui.wait("A completed native tip must show thanks") { ui.app.alerts["Thank you"].exists }
            try ui.tap(ui.app.alerts["Thank you"].buttons["OK"])
            try ui.reveal(ui.element("tipJar.count"))
            XCTAssertEqual(ui.element("tipJar.count").value as? String, String(count))
        }
        XCTAssertEqual(session.allTransactions().count, 2)
        XCTAssertEqual(Set(session.allTransactions().map(\.identifier)).count, 2)
        try ui.relaunch()
        try openTipJar(ui)
        try ui.reveal(ui.element("tipJar.count"))
        XCTAssertEqual(ui.element("tipJar.count").value as? String, "2")
        XCTAssertFalse(ui.app.alerts["Thank you"].exists)
    }

    func testStoreKitLoadFailureShowsRetryAndThenRealProducts() async throws {
        let session = try makeSession()
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let ui = makeDriver()
        try ui.launch()
        try openTipJar(ui, expectingProducts: false)
        let retry = ui.app.buttons["tipJar.retry"]
        try ui.reveal(retry)
        XCTAssertTrue(ui.element("tipJar.loadError").exists)
        XCTAssertGreaterThanOrEqual(retry.frame.height + 1e-6, 52)
        XCTAssertFalse(ui.app.buttons["com.agraabhi.ganabajana.tip.small"].exists)
        XCTAssertFalse(ui.app.alerts["Thank you"].exists)

        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try ui.tap(retry)
        try ui.wait("Retry must replace the error with StoreKit products") {
            ui.app.buttons["com.agraabhi.ganabajana.tip.small"].exists && !retry.exists
        }
        try ui.reveal(ui.app.buttons["com.agraabhi.ganabajana.tip.patron"])
        XCTAssertTrue(ui.app.buttons["com.agraabhi.ganabajana.tip.patron"].isEnabled)
    }

    func testPendingPurchaseExplainsApprovalWithoutThankingOrCrediting() throws {
        let session = try makeSession()
        session.askToBuyEnabled = true
        let ui = makeDriver()
        try ui.launch()
        try openTipJar(ui)
        let small = ui.app.buttons["com.agraabhi.ganabajana.tip.small"]
        try ui.tap(small)
        try ui.wait("An Ask to Buy purchase must show the inline pending message") { ui.element("tipJar.pending").exists }
        XCTAssertTrue(ui.app.staticTexts["Your purchase is pending with Apple. It may need approval. You don't need to try again."].exists)
        XCTAssertFalse(ui.element("tipJar.count").exists)
        XCTAssertFalse(ui.app.alerts["Thank you"].exists)
        XCTAssertFalse(small.isEnabled)
        XCTAssertEqual(session.allTransactions().filter(\.pendingAskToBuyConfirmation).count, 1)
        try ui.tap(ui.app.buttons["tipJar.dismissPending"])
        try ui.wait("Acknowledging pending must close the message without inventing a completed tip") {
            !ui.element("tipJar.pending").exists && small.isEnabled
        }
        XCTAssertFalse(ui.element("tipJar.count").exists)
    }

    private func makeSession() throws -> SKTestSession {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TipJar", withExtension: "storekit"),
                                          "Copy Resources/TipJar.storekit into GanaBajanaUITests resources.")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        addTeardownBlock {
            session.clearTransactions()
            session.resetToDefaultState()
        }
        return session
    }

    private func makeDriver() -> AppUITestDriver {
        let ui = AppUITestDriver(testCase: self, prefix: "tip-jar")
        addTeardownBlock { await ui.finish() }
        return ui
    }

    private func openTipJar(_ ui: AppUITestDriver, expectingProducts: Bool = true) throws {
        try ui.openSettings()
        try ui.openSettingsPage(.about)
        let link = ui.app.buttons["settings.tipJar"]
        try ui.reveal(link, maxSwipes: 24)
        try ui.tap(link)
        try ui.wait("Settings must push the Support development page") { ui.app.navigationBars["Support Development"].exists }
        try ui.wait("StoreKit must finish loading or show an explicit retry") {
            ui.app.buttons["com.agraabhi.ganabajana.tip.small"].exists || ui.app.buttons["tipJar.retry"].exists
        }
        if expectingProducts {
            XCTAssertFalse(ui.element("tipJar.loadError").exists, "The local StoreKit configuration must load real products.")
            try ui.reveal(ui.app.buttons["com.agraabhi.ganabajana.tip.small"])
        }
    }
}
