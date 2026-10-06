import XCTest
@testable import GanaBajanaWatch

@MainActor
final class WatchAccentTests: XCTestCase {
    func testThemeMapsEveryAccentToItsDarkPaletteValue() {
        let expected: [CompanionAccent: UInt32] = [
            .coral: 0xFF5A7A, .mint: 0x4DE0B0, .ocean: 0x64B5FF, .violet: 0xB79AFF,
            .amber: 0xFFC15A, .rose: 0xFF83BB, .teal: 0x53D7E0,
        ]
        XCTAssertEqual(Set(expected.keys), Set(CompanionAccent.allCases))
        for accent in CompanionAccent.allCases {
            XCTAssertEqual(WatchTheme.hex(for: accent), expected[accent], accent.rawValue)
        }
        XCTAssertEqual(Set(CompanionAccent.allCases.map(WatchTheme.hex(for:))).count, CompanionAccent.allCases.count)
    }

    func testFreshWatchUsesTheFallbackAndPersistsTheFirstReceivedAccent() async throws {
        let defaults = try isolatedDefaults()
        let transport = WatchTestTransport()
        transport.automaticResponse = { WatchTestSupport.response(for: $0, snapshot: WatchTestSupport.snapshot(accent: .violet)) }
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport), accentStore: WatchAccentStore(defaults: defaults))
        XCTAssertEqual(model.accent, .coral)
        model.setForeground(true)
        try await WatchTestSupport.waitUntil { model.isCurrent }
        XCTAssertEqual(model.accent, .violet)
        XCTAssertEqual(defaults.string(forKey: WatchAccentStore.key), "violet")
        model.setForeground(false)

        let relaunched = WatchCompanionModel(client: WatchRequestClient(transport: WatchTestTransport()),
                                             accentStore: WatchAccentStore(defaults: defaults))
        XCTAssertEqual(relaunched.accent, .violet, "A relaunch without the phone keeps the last accent")
    }

    func testApplicationContextAppliesAccentAndAnAbsentAccentKeepsTheLastOne() throws {
        let defaults = try isolatedDefaults()
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport), accentStore: WatchAccentStore(defaults: defaults))
        model.setForeground(true)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot(sequence: 1, accent: .amber))))
        XCTAssertEqual(model.accent, .amber)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot(sequence: 2))))
        XCTAssertEqual(model.accent, .amber)
        XCTAssertEqual(model.timeline.snapshot?.sequence, 2)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CompanionWire.encode(WatchTestSupport.snapshot(sequence: 3))) as? [String: Any])
        object["accent"] = "lime"
        transport.onEvent?(.applicationContext(try JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(model.timeline.snapshot?.sequence, 3, "An unknown accent does not drop the snapshot")
        XCTAssertEqual(model.accent, .amber)
        XCTAssertEqual(defaults.string(forKey: WatchAccentStore.key), "amber")
        model.setForeground(false)
    }

    func testRejectedOlderOrForeignSnapshotsCannotChangeTheAccent() throws {
        let defaults = try isolatedDefaults()
        let transport = WatchTestTransport()
        transport.state = .ready(reachable: false, installed: true, needsUnlock: false)
        let model = WatchCompanionModel(client: WatchRequestClient(transport: transport), accentStore: WatchAccentStore(defaults: defaults))
        model.setForeground(true)
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot(sequence: 5, accent: .ocean))))
        transport.onEvent?(.applicationContext(try CompanionWire.encode(WatchTestSupport.snapshot(sequence: 4, accent: .rose))))
        XCTAssertEqual(model.accent, .ocean, "An older sequence is ignored")
        transport.onEvent?(.applicationContext(try CompanionWire.encode(
            WatchTestSupport.snapshot(sessionID: UUID(), sequence: 9, accent: .teal))))
        XCTAssertEqual(model.accent, .ocean, "A cached context from an unconfirmed phone process is ignored")
        model.setForeground(false)
    }

    func testStoreIgnoresAnUnknownPersistedValue() throws {
        let defaults = try isolatedDefaults()
        defaults.set("lime", forKey: WatchAccentStore.key)
        XCTAssertNil(WatchAccentStore(defaults: defaults).load())
        let model = WatchCompanionModel(client: WatchRequestClient(transport: WatchTestTransport()),
                                        accentStore: WatchAccentStore(defaults: defaults))
        XCTAssertEqual(model.accent, .fallback)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "WatchAccentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}
