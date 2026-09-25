import XCTest
@testable import GanaBajana

@MainActor
final class AppIconControllerTests: XCTestCase {
    private let drift = AppIcons.option(named: "AppIcon-Notes")
    private let sonnet = AppIcons.option(named: "AppIcon-Sonnet")

    func testKnownInstalledChoicesAndPrimaryAliasArePreservedWithoutNativeCalls() async throws {
        for name in [nil, "AppIcon-Beat", "AppIcon-Sonnet"] as [String?] {
            let system = ControlledAppIconSystem(installed: name)
            let controller = AppIconController(system: system)
            XCTAssertEqual(controller.current, AppIcons.option(named: name))
            controller.request(controller.current)
            try await controller.select(controller.current)
            XCTAssertTrue(system.calls.isEmpty)
            XCTAssertEqual(system.orphanClaims, 0)
            XCTAssertFalse(controller.isApplying)
            XCTAssertNil(controller.errorMessage)
            XCTAssertEqual(system.installed, name)
        }
    }

    func testRequestsBeforeTheTaskStartsCoalesceToTheNewestChoice() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        controller.request(drift)
        controller.request(sonnet)
        XCTAssertTrue(controller.isApplying)
        XCTAssertTrue(system.calls.isEmpty, "Request must return before the native async apply starts")
        XCTAssertEqual(controller.current, AppIcons.primary)

        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        XCTAssertEqual(system.calls, ["AppIcon-Sonnet"])
        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
    }

    func testRapidRequestsSerializeAndSkipSupersededQueuedChoices() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        controller.request(drift)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        controller.request(AppIcons.option(named: "AppIcon-Waves"))
        controller.request(sonnet)
        XCTAssertEqual(system.calls, ["AppIcon-Notes"])
        XCTAssertEqual(controller.current, AppIcons.primary)

        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertEqual(system.calls, ["AppIcon-Notes", "AppIcon-Sonnet"])
        XCTAssertEqual(controller.current, drift)
        XCTAssertTrue(controller.isApplying)
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertEqual(system.installed, "AppIcon-Sonnet")
        XCTAssertEqual(system.maximumInFlight, 1)
        XCTAssertNil(controller.errorMessage)
    }

    func testSelectingTheCurrentIconDuringAnApplyRestoresItAfterThatApply() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        controller.request(drift)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        controller.request(AppIcons.primary)
        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertEqual(system.calls, ["AppIcon-Notes", nil])
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertNil(system.installed)
        XCTAssertEqual(system.maximumInFlight, 1)
    }

    func testFailureIsVisibleAndTheSameChoiceCanBeRetried() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        controller.request(sonnet)
        XCTAssertTrue(controller.isApplying)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        try system.complete(0, error: AppIconTestError.refused)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.errorMessage, AppIconTestError.refused.localizedDescription)
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertNil(system.installed)
        XCTAssertFalse(controller.isApplying)
        XCTAssertEqual(system.calls.count, 1)

        controller.request(sonnet)
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isApplying)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertEqual(system.calls, ["AppIcon-Sonnet", "AppIcon-Sonnet"])
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertEqual(system.installed, "AppIcon-Sonnet")
        XCTAssertEqual(system.maximumInFlight, 1)
        XCTAssertNil(controller.errorMessage)
    }

    func testAsyncSelectPropagatesTheNativeError() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        let selection = Task { try await controller.select(sonnet) }
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        try system.complete(0, error: AppIconTestError.refused)
        do {
            try await selection.value
            XCTFail("The async entry point must propagate the native error")
        } catch {
            XCTAssertEqual(error as? AppIconTestError, .refused)
        }
        XCTAssertEqual(controller.errorMessage, AppIconTestError.refused.localizedDescription)
        XCTAssertFalse(controller.isApplying)
    }

    func testSupersededFailureDoesNotBlockOrSurfaceOverTheNewestChoice() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        controller.request(drift)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        controller.request(sonnet)
        try system.complete(0, error: AppIconTestError.refused)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.isApplying)
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(system.maximumInFlight, 1)
    }

    func testAsyncSelectSharesTheWriterAndReportsSupersession() async throws {
        let system = ControlledAppIconSystem()
        let controller = AppIconController(system: system)
        let selection = Task { try await controller.select(drift) }
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        controller.request(sonnet)
        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        try system.complete(1)
        do {
            try await selection.value
            XCTFail("A superseded async selection must not claim it is still selected")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertEqual(system.calls, ["AppIcon-Notes", "AppIcon-Sonnet"])
        XCTAssertEqual(system.maximumInFlight, 1)
        XCTAssertFalse(controller.isApplying)
    }

    func testUnsupportedRequestsLeaveTheInstalledChoiceAlone() async throws {
        let system = ControlledAppIconSystem(installed: "AppIcon-Sonnet", supported: false)
        let controller = AppIconController(system: system)
        controller.request(drift)
        XCTAssertFalse(controller.supportsAlternateIcons)
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertEqual(controller.errorMessage, AppIconError.unsupported.localizedDescription)
        XCTAssertFalse(controller.isApplying)
        XCTAssertTrue(system.calls.isEmpty)
        do {
            try await controller.select(drift)
            XCTFail("The throwing compatibility API must still report unsupported devices")
        } catch {
            XCTAssertEqual(error.localizedDescription, AppIconError.unsupported.localizedDescription)
        }
        controller.request(sonnet)
        try await controller.select(sonnet)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isApplying)
        XCTAssertEqual(system.installed, "AppIcon-Sonnet")
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testDisabledFixtureNeverReadsOrMutatesTheSystem() {
        let system = ControlledAppIconSystem(installed: "AppIcon-Dhol")
        let controller = AppIconController(system: system, enabled: false)
        controller.request(sonnet)
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertFalse(controller.supportsAlternateIcons)
        XCTAssertFalse(controller.isApplying)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(system.nameReads, 0)
        XCTAssertEqual(system.supportReads, 0)
        XCTAssertEqual(system.orphanClaims, 0)
        XCTAssertTrue(system.calls.isEmpty)
    }

    func testOrphanResetIsClaimedOnceAndSerializesWithANewerSelection() async throws {
        let system = ControlledAppIconSystem(installed: "AppIcon-Dhol")
        let controller = AppIconController(system: system)
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertTrue(controller.isApplying)
        let secondController = AppIconController(system: system)
        XCTAssertFalse(secondController.isApplying)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        XCTAssertEqual(system.calls, [nil])
        controller.request(sonnet)
        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertEqual(system.calls, [nil, "AppIcon-Sonnet"])
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
        XCTAssertEqual(system.installed, "AppIcon-Sonnet")
        XCTAssertEqual(system.maximumInFlight, 1)
    }

    func testUnstartedOrphanResetYieldsToExplicitSelection() async throws {
        let system = ControlledAppIconSystem(installed: "AppIcon-Dhol")
        let controller = AppIconController(system: system)
        controller.request(sonnet)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        XCTAssertEqual(system.calls, ["AppIcon-Sonnet"])
        try system.complete(0)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, sonnet)
    }

    func testFailedOrphanResetCanRetryPrimaryDespiteFallbackCurrent() async throws {
        let system = ControlledAppIconSystem(installed: "AppIcon-Dhol")
        let controller = AppIconController(system: system)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 1 }
        try system.complete(0, error: AppIconTestError.refused)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertNotNil(controller.errorMessage)
        let secondController = AppIconController(system: system)
        XCTAssertFalse(secondController.isApplying)

        controller.request(AppIcons.primary)
        try await PlaybackTestSupport.waitUntil { system.calls.count == 2 }
        XCTAssertEqual(system.calls, [nil, nil])
        try system.complete(1)
        try await PlaybackTestSupport.waitUntil { !controller.isApplying }
        XCTAssertNil(system.installed)
        XCTAssertNil(controller.errorMessage)
    }

    func testUnsupportedOrphanDoesNotConsumeItsResetClaim() {
        let system = ControlledAppIconSystem(installed: "AppIcon-Dhol", supported: false)
        let controller = AppIconController(system: system)
        XCTAssertEqual(controller.current, AppIcons.primary)
        XCTAssertFalse(controller.isApplying)
        XCTAssertEqual(system.orphanClaims, 0)
        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertEqual(system.installed, "AppIcon-Dhol")
    }
}

private enum AppIconTestError: LocalizedError {
    case refused
    var errorDescription: String? { "The app icon could not be changed. Try again." }
}

@MainActor
private final class ControlledAppIconSystem: AppIconSystem {
    private(set) var installed: String?
    private let supported: Bool
    private(set) var calls: [String?] = []
    private(set) var maximumInFlight = 0
    private(set) var nameReads = 0
    private(set) var supportReads = 0
    private(set) var orphanClaims = 0
    private var claimedOrphanReset = false
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    init(installed: String? = nil, supported: Bool = true) {
        self.installed = installed
        self.supported = supported
    }

    var alternateIconName: String? {
        nameReads += 1
        return installed
    }

    var supportsAlternateIcons: Bool {
        supportReads += 1
        return supported
    }

    func claimOrphanReset() -> Bool {
        orphanClaims += 1
        guard !claimedOrphanReset else { return false }
        claimedOrphanReset = true
        return true
    }

    func setAlternateIconName(_ name: String?) async throws {
        let index = calls.count
        calls.append(name)
        try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            maximumInFlight = max(maximumInFlight, pending.count)
        }
    }

    func complete(_ index: Int, error: (any Error)? = nil) throws {
        let continuation = try XCTUnwrap(pending.removeValue(forKey: index))
        if let error {
            continuation.resume(throwing: error)
        } else {
            installed = calls[index]
            continuation.resume()
        }
    }
}
