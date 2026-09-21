import StoreKit
import XCTest
@testable import GanaBajana

@MainActor
final class TipJarServiceTests: XCTestCase {
    private var small: String { TipJarService.productIDs[0] }
    private var medium: String { TipJarService.productIDs[1] }

    func testOnlyTheFiveIntendedConsumablesAreEligible() {
        XCTAssertEqual(TipJarService.productIDs, ["small", "medium", "large", "grand", "patron"].map {
            "com.agraabhi.ganabajana.tip.\($0)"
        })
        for id in TipJarService.productIDs {
            XCTAssertTrue(TipJarService.isTip(productID: id, type: .consumable))
            for type in [Product.ProductType.nonConsumable, .autoRenewable, .nonRenewable] {
                XCTAssertFalse(TipJarService.isTip(productID: id, type: type))
            }
        }
        XCTAssertFalse(TipJarService.isTip(productID: "com.agraabhi.oshodiscourses.tip.small", type: .consumable))
        XCTAssertFalse(TipJarService.isTip(productID: "unrelated.product", type: .consumable))
    }

    func testMissingFailedAndCancelledLoadsCanBeRetried() async throws {
        try await withService { tips, library, _ in
            var calls = 0
            for _ in 0..<2 {
                await tips.loadProducts {
                    calls += 1
                    XCTAssertNil(tips.loadError)
                    return []
                }
                XCTAssertTrue(tips.products.isEmpty)
                XCTAssertNotNil(tips.loadError)
                XCTAssertFalse(tips.isLoading)
            }
            XCTAssertEqual(calls, 2)
            await tips.loadProducts { throw URLError(.notConnectedToInternet) }
            XCTAssertTrue(tips.products.isEmpty)
            XCTAssertNotNil(tips.loadError)
            XCTAssertFalse(tips.isLoading)
            await tips.loadProducts { throw CancellationError() }
            XCTAssertNotNil(tips.loadError)
            XCTAssertFalse(tips.isLoading)
            await tips.loadProducts { calls += 1; return [] }
            XCTAssertEqual(calls, 3)
            XCTAssertTrue(tips.canPurchase)
            XCTAssertEqual(library.tipCount, 0)
        }
    }

    func testLoadingRejectsOverlappingLoadsAndPurchases() async throws {
        try await withService { tips, _, _ in
            let gate = AppModelRequestGate<Int, [Product]>()
            let loading = Task { await tips.loadProducts { try await gate.receive(1) } }
            addTeardownBlock { await gate.close(); await loading.value }
            let request = try await gate.request(at: 0)
            XCTAssertTrue(tips.isLoading)
            XCTAssertFalse(tips.canPurchase)
            var called = false
            await tips.loadProducts { called = true; return [] }
            await tips.purchase(productID: small, type: .consumable) { called = true; return .pending }
            XCTAssertFalse(called)
            try await gate.complete(request, with: .success([]))
            await loading.value
            XCTAssertFalse(tips.isLoading)
            XCTAssertTrue(tips.canPurchase)
        }
    }

    func testVerifiedPurchaseIsDurableBeforeFinishAndThanksAfterward() async throws {
        try await withService { tips, library, directory in
            let gate = AppModelRequestGate<UInt64, Void>()
            let transaction = FakeTipTransaction()
            transaction.onFinish = { try? await gate.receive(1) }
            let buying = Task { await self.purchase(.verified(transaction), using: tips) }
            addTeardownBlock { await gate.close(); await buying.value }
            let request = try await gate.request(at: 0)
            XCTAssertEqual(library.tipCredit(for: 1), true)
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 1)
            XCTAssertEqual(tips.state, .purchasing(small))
            XCTAssertTrue(tips.isPurchasing)
            tips.dismissMessage()
            XCTAssertFalse(tips.canPurchase)
            try await gate.complete(request, with: .success(()))
            await buying.value
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(tips.state, .thanked)
            XCTAssertFalse(tips.isPurchasing)
            var called = false
            await tips.purchase(productID: small, type: .consumable) { called = true; return .pending }
            XCTAssertFalse(called)
            tips.dismissMessage()
            XCTAssertTrue(tips.canPurchase)
        }
    }

    func testPurchaseUpdateAndRecoveryDoNotCountOrThankDuplicates() async throws {
        try await withService { tips, _, directory in
            let transaction = FakeTipTransaction()
            await purchase(.verified(transaction), using: tips)
            tips.dismissMessage()
            for source in [TipJarService.TransactionSource.update, .recovery] {
                let outcome = await tips.handle(.verified(transaction), source: source)
                XCTAssertEqual(outcome, .duplicate)
                XCTAssertEqual(tips.state, .idle)
                XCTAssertEqual(tips.tipCount, 1)
            }
            let relaunched = TipJarService(library: LibraryStore(directory: directory), observeTransactions: false)
            let outcome = await relaunched.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(outcome, .duplicate)
            XCTAssertEqual(relaunched.state, .idle)
            XCTAssertEqual(relaunched.tipCount, 1)
            XCTAssertEqual(transaction.finishCalls, 4)
        }
    }

    func testSameProductCanBeTippedAgainWithANewTransaction() async throws {
        try await withService { tips, _, _ in
            for id in [UInt64(1), 2] {
                let transaction = FakeTipTransaction(id: id)
                await purchase(.verified(transaction), using: tips)
                XCTAssertEqual(tips.state, .thanked)
                XCTAssertEqual(transaction.finishCalls, 1)
                tips.dismissMessage()
            }
            XCTAssertEqual(tips.tipCount, 2)
        }
    }

    func testPendingPurchaseWaitsForAVerifiedUpdate() async throws {
        try await withService { tips, _, _ in
            await purchase(.pending, using: tips)
            XCTAssertEqual(tips.state, .pending)
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertFalse(tips.isPurchasing)
            XCTAssertFalse(tips.canPurchase)
            let approval = FakeTipTransaction()
            let outcome = await tips.handle(.verified(approval), source: .update)
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(tips.state, .thanked)
            XCTAssertEqual(tips.tipCount, 1)
            XCTAssertEqual(approval.finishCalls, 1)
        }
    }

    func testCancelledAndInterruptedPurchasesNeverCountOrReportSuccess() async throws {
        try await withService { tips, _, _ in
            await purchase(.userCancelled, using: tips)
            XCTAssertEqual(tips.state, .idle)
            let errors: [any Error] = [StoreKitError.userCancelled, CancellationError()]
            for error in errors {
                await tips.purchase(productID: small, type: .consumable) { throw error }
                XCTAssertEqual(tips.state, .idle)
                XCTAssertTrue(tips.canPurchase)
                XCTAssertEqual(tips.tipCount, 0)
            }
        }
    }

    func testPurchaseErrorsReleaseTheGateAndDoNotExposeRawErrorDetails() async throws {
        try await withService { tips, _, _ in
            let errors: [any Error] = [
                Product.PurchaseError.purchaseNotAllowed,
                Product.PurchaseError.productUnavailable,
                NSError(domain: "private-purchase-payload", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "private-purchase-payload"]),
            ]
            for error in errors {
                await tips.purchase(productID: small, type: .consumable) { throw error }
                guard case .failed(let message) = tips.state else { return XCTFail("Expected a purchase failure") }
                XCTAssertFalse(message.contains("private-purchase-payload"))
                XCTAssertEqual(tips.tipCount, 0)
                XCTAssertFalse(tips.isPurchasing)
                tips.dismissMessage()
                XCTAssertTrue(tips.canPurchase)
            }
        }
    }

    func testUnverifiedPurchaseIsUnfinishedAndCanRecover() async throws {
        try await withService { tips, library, _ in
            let transaction = FakeTipTransaction()
            await purchase(.unverified(transaction, .invalidSignature), using: tips)
            guard case .failed = tips.state else { return XCTFail("An unverified purchase must not report success") }
            XCTAssertEqual(transaction.finishCalls, 0)
            XCTAssertNil(library.tipCredit(for: transaction.id))
            XCTAssertEqual(tips.tipCount, 0)
            tips.dismissMessage()
            let outcome = await tips.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(tips.state, .thanked)
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(tips.tipCount, 1)
        }
    }

    func testUnverifiedUpdatesAndRecoveryRemainUnfinished() async throws {
        for source in [TipJarService.TransactionSource.update, .recovery] {
            try await withService { tips, _, _ in
                let transaction = FakeTipTransaction()
                let outcome = await tips.handle(.unverified(transaction, .invalidDeviceVerification), source: source)
                XCTAssertEqual(outcome, .unverified)
                XCTAssertEqual(transaction.finishCalls, 0)
                XCTAssertEqual(tips.tipCount, 0)
                guard case .failed = tips.state else { return XCTFail("Expected a verification failure") }
            }
        }
    }

    func testUnsupportedTransactionsAndProductsAreNotAcknowledged() async throws {
        try await withService { tips, _, _ in
            for transaction in [
                FakeTipTransaction(productID: "unrelated.product"),
                FakeTipTransaction(productType: .nonConsumable),
                FakeTipTransaction(productType: .autoRenewable),
                FakeTipTransaction(productType: .nonRenewable),
            ] {
                let outcome = await tips.handle(.verified(transaction), source: .update)
                XCTAssertEqual(outcome, .unsupported)
                XCTAssertEqual(tips.state, .idle)
                await purchase(.verified(transaction), using: tips)
                guard case .failed = tips.state else { return XCTFail("Expected an unsupported transaction failure") }
                XCTAssertEqual(transaction.finishCalls, 0)
                XCTAssertEqual(tips.tipCount, 0)
                tips.dismissMessage()

                var called = false
                await tips.purchase(productID: transaction.productID, type: transaction.productType) {
                    called = true
                    return .pending
                }
                XCTAssertFalse(called)
                tips.dismissMessage()
            }
            let unrelated = FakeTipTransaction(productID: "unrelated.product")
            await tips.handle(.unverified(unrelated, .invalidSignature), source: .update)
            XCTAssertEqual(tips.state, .idle)
            XCTAssertEqual(unrelated.finishCalls, 0)
        }
    }

    func testAnotherProductsTransactionCannotConfirmTheSelectedTip() async throws {
        try await withService { tips, _, _ in
            let transaction = FakeTipTransaction(productID: medium)
            await purchase(.verified(transaction), using: tips)
            guard case .failed = tips.state else { return XCTFail("A different product must not confirm the purchase") }
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertEqual(transaction.finishCalls, 0)
            tips.dismissMessage()
            let outcome = await tips.handle(.verified(transaction), source: .update)
            XCTAssertEqual(outcome, .completed)
            XCTAssertEqual(tips.tipCount, 1)
        }
    }

    func testRevokedPurchaseIsFinishedWithoutCreditOrThanks() async throws {
        try await withService { tips, library, _ in
            let transaction = FakeTipTransaction(revocationDate: Date())
            await purchase(.verified(transaction), using: tips)
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertEqual(library.tipCredit(for: transaction.id), false)
            XCTAssertEqual(transaction.finishCalls, 1)
            guard case .failed = tips.state else { return XCTFail("A refund must not report purchase success") }
        }
    }

    func testRefundRemovesCreditAndStaleReplayAfterRelaunchCannotRestoreIt() async throws {
        try await withService { tips, _, directory in
            let transaction = FakeTipTransaction()
            await tips.handle(.verified(transaction), source: .update)
            XCTAssertEqual(tips.tipCount, 1)
            let refund = FakeTipTransaction(revocationDate: Date())
            let outcome = await tips.handle(.verified(refund), source: .update)
            XCTAssertEqual(outcome, .revoked)
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertEqual(tips.state, .idle)
            XCTAssertEqual(refund.finishCalls, 1)
            let relaunched = TipJarService(library: LibraryStore(directory: directory), observeTransactions: false)
            let replay = await relaunched.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(replay, .revoked)
            XCTAssertEqual(relaunched.tipCount, 0)
            XCTAssertEqual(relaunched.state, .idle)
        }
    }

    func testPurchaseAndUpdateShareAnInFlightFinishAndOneCredit() async throws {
        try await withService { tips, _, _ in
            let gate = AppModelRequestGate<UInt64, Void>()
            let transaction = FakeTipTransaction()
            transaction.onFinish = { try? await gate.receive(1) }
            let buying = Task { await self.purchase(.verified(transaction), using: tips) }
            addTeardownBlock { await gate.close(); await buying.value }
            let request = try await gate.request(at: 0)
            var entered = false
            let update = Task {
                entered = true
                return await tips.handle(.verified(transaction), source: .update)
            }
            try await AppModelFixtures.eventually { entered }
            XCTAssertEqual(tips.tipCount, 1)
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(tips.state, .purchasing(small))
            try await gate.complete(request, with: .success(()))
            await buying.value
            let outcome = await update.value
            XCTAssertEqual(outcome, .duplicate)
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(tips.state, .thanked)
        }
    }

    func testBackgroundDeliveryCannotReplaceOrUnlockAnotherPurchase() async throws {
        for cancelled in [false, true] {
            try await withService { tips, _, _ in
                let gate = AppModelRequestGate<Int, TipJarService.PurchaseState>()
                let buying = Task {
                    await tips.purchase(productID: self.medium, type: .consumable) { try await gate.receive(1) }
                }
                addTeardownBlock { await gate.close(); await buying.value }
                let request = try await gate.request(at: 0)
                await tips.handle(.verified(FakeTipTransaction()), source: .update)
                await tips.handle(.unverified(FakeTipTransaction(id: 2), .invalidSignature), source: .update)
                XCTAssertEqual(tips.tipCount, 1)
                XCTAssertEqual(tips.state, .purchasing(medium))
                tips.dismissMessage()
                XCTAssertFalse(tips.canPurchase)
                var called = false
                await tips.purchase(productID: small, type: .consumable) { called = true; return .pending }
                await tips.loadProducts { called = true; return [] }
                XCTAssertFalse(called)
                try await gate.complete(request, with: .success(cancelled ? .idle : .pending))
                await buying.value
                XCTAssertEqual(tips.state, cancelled ? .idle : .pending)
                XCTAssertFalse(tips.isPurchasing)
                tips.dismissMessage()
                XCTAssertTrue(tips.canPurchase)
            }
        }
    }

    func testRefundDuringFinishSuppressesPurchaseSuccess() async throws {
        try await withService { tips, _, _ in
            let gate = AppModelRequestGate<UInt64, Void>()
            let transaction = FakeTipTransaction()
            transaction.onFinish = { try? await gate.receive(1) }
            let buying = Task { await self.purchase(.verified(transaction), using: tips) }
            addTeardownBlock { await gate.close(); await buying.value }
            let request = try await gate.request(at: 0)
            let refund = FakeTipTransaction(revocationDate: Date())
            let refunding = Task { await tips.handle(.verified(refund), source: .update) }
            try await AppModelFixtures.eventually { tips.tipCount == 0 }
            try await gate.complete(request, with: .success(()))
            await buying.value
            let outcome = await refunding.value
            XCTAssertEqual(outcome, .revoked)
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(refund.finishCalls, 0)
            guard case .failed = tips.state else { return XCTFail("A refund during finish must suppress thanks") }
        }
    }

    func testFailedPersistencePreventsFinishAndRecoveryCanRetry() async throws {
        try await withService { tips, library, directory in
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let transaction = FakeTipTransaction()
            await purchase(.verified(transaction), using: tips)
            XCTAssertEqual(transaction.finishCalls, 0)
            XCTAssertEqual(library.tipCount, 0)
            XCTAssertNil(library.tipCredit(for: transaction.id))
            XCTAssertNotNil(library.errorMessage)
            guard case .failed(let message) = tips.state else { return XCTFail("A failed write must not report thanks") }
            XCTAssertTrue(message.contains("Apple verified"))
            XCTAssertTrue(message.contains("couldn't save"))
            XCTAssertTrue(message.contains("Don't tip again"))

            let outcome = await tips.handle(.verified(transaction), source: .update)
            XCTAssertEqual(outcome, .persistenceFailed)
            XCTAssertEqual(transaction.finishCalls, 0)
            try FileManager.default.removeItem(at: url)
            let recovered = await tips.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(recovered, .completed)
            XCTAssertEqual(transaction.finishCalls, 1)
            XCTAssertEqual(LibraryStore(directory: directory).tipCount, 1)
            XCTAssertEqual(tips.state, .thanked)
            XCTAssertNil(library.errorMessage)
        }
    }

    func testFailedRefundWriteRemainsUnfinishedAndOutranksAStaleDelivery() async throws {
        try await withService { tips, library, directory in
            let transaction = FakeTipTransaction()
            await tips.handle(.verified(transaction), source: .update)
            tips.dismissMessage()
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let refund = FakeTipTransaction(revocationDate: Date())
            let failed = await tips.handle(.verified(refund), source: .update)
            XCTAssertEqual(failed, .persistenceFailed)
            XCTAssertEqual(refund.finishCalls, 0)
            XCTAssertEqual(library.tipCount, 1)
            guard case .failed = tips.state else { return XCTFail("An unsaved refund must expose its storage failure") }
            let staleFailure = await tips.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(staleFailure, .persistenceFailed)
            XCTAssertEqual(transaction.finishCalls, 1)

            try FileManager.default.removeItem(at: url)
            try saved.write(to: url, options: .atomic)
            let recovered = await tips.handle(.verified(transaction), source: .recovery)
            XCTAssertEqual(recovered, .revoked)
            XCTAssertEqual(tips.tipCount, 0)
            XCTAssertEqual(LibraryStore(directory: directory).tipCredit(for: transaction.id), false)
            XCTAssertEqual(tips.state, .idle)
        }
    }

    func testDuplicateDeliveryIsNotFinishedWhenItsSavedRecordBecomesUnreadable() async throws {
        try await withService { tips, _, directory in
            let transaction = FakeTipTransaction()
            await purchase(.verified(transaction), using: tips)
            tips.dismissMessage()
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let duplicate = FakeTipTransaction()
            let outcome = await tips.handle(.verified(duplicate), source: .update)
            XCTAssertEqual(outcome, .persistenceFailed)
            XCTAssertEqual(duplicate.finishCalls, 0)
            guard case .failed = tips.state else { return XCTFail("Unreadable saved credit must expose a storage failure") }

            try FileManager.default.removeItem(at: url)
            try saved.write(to: url, options: .atomic)
            let recovered = await tips.handle(.verified(duplicate), source: .recovery)
            XCTAssertEqual(recovered, .duplicate)
            XCTAssertEqual(duplicate.finishCalls, 1)
            XCTAssertEqual(tips.tipCount, 1)
            XCTAssertEqual(tips.state, .idle)
        }
    }

    func testFailedRefundDuringFinishCannotReportPurchaseSuccess() async throws {
        try await withService { tips, library, directory in
            let gate = AppModelRequestGate<UInt64, Void>()
            let transaction = FakeTipTransaction()
            transaction.onFinish = { try? await gate.receive(1) }
            let buying = Task { await self.purchase(.verified(transaction), using: tips) }
            addTeardownBlock { await gate.close(); await buying.value }
            let request = try await gate.request(at: 0)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let refund = FakeTipTransaction(revocationDate: Date())
            let outcome = await tips.handle(.verified(refund), source: .update)
            XCTAssertEqual(outcome, .persistenceFailed)
            XCTAssertEqual(refund.finishCalls, 0)
            XCTAssertEqual(library.tipCount, 1)
            try await gate.complete(request, with: .success(()))
            await buying.value
            guard case .failed(let message) = tips.state else { return XCTFail("An unsaved refund must suppress purchase success") }
            XCTAssertTrue(message.contains("couldn't save"))
            try FileManager.default.removeItem(at: url)
            try saved.write(to: url, options: .atomic)
            let recovered = await tips.handle(.verified(refund), source: .recovery)
            XCTAssertEqual(recovered, .revoked)
            XCTAssertEqual(refund.finishCalls, 1)
            XCTAssertEqual(tips.tipCount, 0)
        }
    }

    func testCorruptOrFutureLibraryNeverFinishesARecoveredTip() async throws {
        for data in [Data("broken JSON".utf8), Data("{\"version\":9999,\"future\":true}".utf8)] {
            try await withService { _, _, directory in
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)
                let library = LibraryStore(directory: directory)
                let originalError = try XCTUnwrap(library.errorMessage)
                let tips = TipJarService(library: library, observeTransactions: false)
                let transaction = FakeTipTransaction()
                let outcome = await tips.handle(.verified(transaction), source: .recovery)
                XCTAssertEqual(outcome, .persistenceFailed)
                XCTAssertEqual(transaction.finishCalls, 0)
                XCTAssertEqual(tips.tipCount, 0)
                XCTAssertEqual(library.errorMessage, originalError)
                XCTAssertEqual(try Data(contentsOf: url), data)
                guard case .failed = tips.state else { return XCTFail("Blocked storage must report recovery failure") }
            }
        }
    }

    private func purchase(_ result: Product.PurchaseResult, using tips: TipJarService) async {
        await tips.purchase(productID: small, type: .consumable) {
            await tips.purchaseState(for: result, productID: self.small)
        }
    }

    private func purchase(_ result: VerificationResult<FakeTipTransaction>, using tips: TipJarService) async {
        await tips.purchase(productID: small, type: .consumable) {
            await tips.purchaseState(for: result, productID: self.small)
        }
    }

    private func withService(_ body: @MainActor (TipJarService, LibraryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GanaBajana-TipJarTests-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let library = LibraryStore(directory: directory)
        try await body(TipJarService(library: library, observeTransactions: false), library, directory)
    }
}

@MainActor
private final class FakeTipTransaction: TipJarTransaction {
    let id: UInt64
    let productID: String
    let productType: Product.ProductType
    let revocationDate: Date?
    var finishCalls = 0
    var onFinish: @MainActor () async -> Void = {}

    init(id: UInt64 = 1, productID: String = TipJarService.productIDs[0],
         productType: Product.ProductType = .consumable, revocationDate: Date? = nil) {
        self.id = id
        self.productID = productID
        self.productType = productType
        self.revocationDate = revocationDate
    }

    func finish() async {
        finishCalls += 1
        await onFinish()
    }
}
