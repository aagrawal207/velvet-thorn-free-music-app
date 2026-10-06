// The Catalyst SDK's StoreKitTest names these session APIs differently; native StoreKit is covered on iOS.
#if !targetEnvironment(macCatalyst)
import StoreKit
import StoreKitTest
import XCTest
@testable import GanaBajana

@MainActor
final class TipJarStoreKitTests: XCTestCase {
    func testLocalProductsHaveTheFiveUSPricesAndLocalizedMetadata() async throws {
        try await withStoreKit { _, library, _ in
            let tips = TipJarService(library: library, observeTransactions: false)
            await tips.loadProducts()
            XCTAssertNil(tips.loadError)
            XCTAssertEqual(tips.products.map(\.id), TipJarService.productIDs)
            let expected: [(String, Decimal, String)] = [
                ("Small tip", 3, "$3.00"), ("Generous tip", 5, "$5.00"), ("Big tip", 10, "$10.00"),
                ("Grand tip", 25, "$25.00"), ("Patron tip", 50, "$50.00"),
            ]
            XCTAssertEqual(tips.products.count, expected.count)
            for (product, (name, price, displayPrice)) in zip(tips.products, expected) {
                XCTAssertEqual(product.type, .consumable)
                XCTAssertEqual(product.displayName, name)
                XCTAssertEqual(product.price, price)
                XCTAssertEqual(product.displayPrice, displayPrice)
                XCTAssertFalse(product.description.isEmpty)
            }
        }
    }

    func testPartialCatalogKeepsRealProductsAvailableAndRetryLoadsAllFive() async throws {
        try await withStoreKit { _, library, _ in
            let all = try await Product.products(for: TipJarService.productIDs)
            let small = try XCTUnwrap(all.first { $0.id == TipJarService.productIDs[0] })
            let patron = try XCTUnwrap(all.first { $0.id == TipJarService.productIDs[4] })
            let tips = TipJarService(library: library, observeTransactions: false)
            await tips.loadProducts { [patron, small, small] }
            XCTAssertEqual(tips.products.map(\.id), [small.id, patron.id])
            XCTAssertTrue(try XCTUnwrap(tips.loadError).contains("Some tips"))
            XCTAssertTrue(tips.canPurchase)
            await tips.loadProducts()
            XCTAssertNil(tips.loadError)
            XCTAssertEqual(tips.products.count, 5)
        }
    }

    func testNativeConsumablePurchasesAreRepeatableAndFinishAfterRecording() async throws {
        try await withStoreKit { session, library, directory in
            let tips = TipJarService(library: library, observeTransactions: false)
            await tips.loadProducts()
            let product = try XCTUnwrap(tips.products.first)
            for expectedCount in 1...2 {
                try await purchaseWithinDeadline(tips, product)
                XCTAssertEqual(tips.state, .thanked)
                XCTAssertEqual(library.tipCount, expectedCount)
                XCTAssertEqual(LibraryStore(directory: directory).tipCount, expectedCount)
                tips.dismissMessage()
            }
            let transactions = session.allTransactions()
            XCTAssertEqual(transactions.count, 2)
            XCTAssertEqual(Set(transactions.map(\.identifier)).count, 2)
            let unfinished = await unfinishedIDs()
            XCTAssertTrue(unfinished.isEmpty)
            let relaunched = TipJarService(library: LibraryStore(directory: directory), observeTransactions: false)
            XCTAssertEqual(relaunched.tipCount, 2)
            XCTAssertEqual(relaunched.state, .idle)
        }
    }

    func testLifetimeRecoveryFindsAndFinishesAnExistingUnfinishedTip() async throws {
        try await withStoreKit { session, library, directory in
            let transaction = try await session.buyProduct(identifier: TipJarService.productIDs[0])
            let before = await unfinishedIDs()
            XCTAssertTrue(before.contains(transaction.id))
            let tips = TipJarService(library: library)
            try await waitForStoreKit {
                guard tips.tipCount == 1 else { return false }
                return await self.unfinishedIDs().isEmpty
            }
            XCTAssertEqual(tips.state, .thanked)
            XCTAssertEqual(LibraryStore(directory: directory).tipCredit(for: transaction.id), true)
        }
    }

    func testNativePendingApprovalAndRefundArriveThroughTheLifetimeListener() async throws {
        try await withStoreKit { session, library, directory in
            session.askToBuyEnabled = true
            let tips = TipJarService(library: library)
            await tips.loadProducts()
            let product = try XCTUnwrap(tips.products.first)
            try await purchaseWithinDeadline(tips, product)
            XCTAssertEqual(tips.state, .pending)
            XCTAssertEqual(tips.tipCount, 0)
            let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
            try session.approveAskToBuyTransaction(identifier: pending.identifier)
            try await waitForStoreKit { tips.tipCount == 1 && tips.state == .thanked }
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 1)

            try session.refundTransaction(identifier: pending.identifier)
            try await waitForStoreKit { library.tipCredit(for: UInt64(pending.identifier)) == false }
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertEqual(tips.state, .idle)
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 0)
        }
    }

    func testNativeLoadFailureRetriesAndCancelledPurchaseDoesNotCredit() async throws {
        try await withStoreKit { session, library, _ in
            let tips = TipJarService(library: library, observeTransactions: false)
            try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
            await tips.loadProducts()
            XCTAssertNotNil(tips.loadError)
            XCTAssertTrue(tips.products.isEmpty)
            XCTAssertFalse(tips.isLoading)
            try await session.setSimulatedError(nil, forAPI: .loadProducts)
            await tips.loadProducts()
            XCTAssertNil(tips.loadError)
            let product = try XCTUnwrap(tips.products.first)
            try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
            try await purchaseWithinDeadline(tips, product)
            XCTAssertEqual(tips.state, .idle)
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertTrue(tips.canPurchase)
        }
    }

    func testNativeUnverifiedPurchaseRemainsUnfinishedUntilVerifiedRecovery() async throws {
        try await withStoreKit { session, library, _ in
            let tips = TipJarService(library: library, observeTransactions: false)
            await tips.loadProducts()
            let product = try XCTUnwrap(tips.products.first)
            try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
            try await purchaseWithinDeadline(tips, product)
            guard case .failed = tips.state else { return XCTFail("An unverified StoreKit purchase must not be thanked") }
            XCTAssertEqual(tips.tipCount, 0)
            let unfinished = await unfinishedIDs()
            XCTAssertEqual(unfinished.count, 1)
            try await session.setSimulatedError(nil, forAPI: .verification)
            let recovery = TipJarService(library: library)
            try await waitForStoreKit {
                guard recovery.tipCount == 1 else { return false }
                return await self.unfinishedIDs().isEmpty
            }
        }
    }

    func testNativeTransactionStaysUnfinishedAfterAWriteFailureAndRecovers() async throws {
        try await withStoreKit { _, library, directory in
            let tips = TipJarService(library: library, observeTransactions: false)
            await tips.loadProducts()
            let product = try XCTUnwrap(tips.products.first)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try await purchaseWithinDeadline(tips, product)
            guard case .failed = tips.state else { return XCTFail("A failed write must not finish or thank the purchase") }
            XCTAssertEqual(tips.tipCount, 0)
            let unfinished = await unfinishedIDs()
            XCTAssertEqual(unfinished.count, 1)
            try FileManager.default.removeItem(at: url)
            let recovery = TipJarService(library: library)
            try await waitForStoreKit {
                guard recovery.tipCount == 1 else { return false }
                return await self.unfinishedIDs().isEmpty
            }
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 1)
        }
    }

    private func withStoreKit(
        _ body: @MainActor (SKTestSession, LibraryStore, URL) async throws -> Void
    ) async throws {
        let session = try SKTestSession(configurationFileNamed: "TipJar")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "USA"
        session.locale = Locale(identifier: "en_US")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-TipJarStoreKitTests-\(UUID())", isDirectory: true)
        addTeardownBlock {
            session.clearTransactions()
            session.resetToDefaultState()
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(session, LibraryStore(directory: directory), directory)
    }

    /// A StoreKit test session that failed to take over shows the real sign-in sheet, and `purchase` would wait
    /// for a person forever; the deadline turns that into a failure the run can report.
    private func purchaseWithinDeadline(_ tips: TipJarService, _ product: Product) async throws {
        var finished = false
        let purchase = Task { @MainActor in
            await tips.purchase(product)
            finished = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !finished {
            guard ContinuousClock.now < deadline else {
                purchase.cancel()
                throw AppModelTestFailure.timedOut("StoreKit purchase; the test session did not suppress dialogs")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func unfinishedIDs() async -> Set<UInt64> {
        var ids: Set<UInt64> = []
        // Unverified records must also remain visible to tests that intentionally fail verification.
        for await result in StoreKit.Transaction.unfinished { ids.insert(result.unsafePayloadValue.id) }
        return ids
    }

    private func waitForStoreKit(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw AppModelTestFailure.timedOut("StoreKit transaction delivery") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
#endif
