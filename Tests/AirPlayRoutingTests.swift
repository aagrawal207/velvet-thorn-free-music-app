import AVFoundation
import XCTest
@testable import GanaBajana

/// AirPlay must carry rendered audio: a player that allowed external playback would hand a TV an unfetchable URL.
@MainActor
final class AirPlayRoutingTests: XCTestCase {
    private let first = Track(id: "airplay-first", title: "First")
    private let second = Track(id: "airplay-second", title: "Second")

    func testFactoryPlayerForbidsExternalPlayback() {
        XCTAssertFalse(PlaybackAudioRoute.makePlayer().allowsExternalPlayback)
    }

    func testMainAndStandbyPlayersForbidExternalPlaybackIncludingAfterMediaServicesReset() {
        let player = PlayerController(resolver: PlaybackResolutionGate())
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback)
        XCTAssertEqual(player.standbyPlayerAllowsExternalPlayback, false)
        XCTAssertFalse(player.isExternalPlaybackActive)
        player.handleMediaServicesReset()
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback)
        XCTAssertEqual(player.standbyPlayerAllowsExternalPlayback, false)
    }

    func testStandbyDeckPlayerForbidsExternalPlaybackIncludingAfterReset() {
        let deck = StandbyDeck(resolver: PlaybackResolutionGate())
        XCTAssertEqual(deck.player?.allowsExternalPlayback, false)
        deck.reset()
        XCTAssertEqual(deck.player?.allowsExternalPlayback, false)
    }

    func testPlayersSwappedByGaplessAndCrossfadeStillForbidExternalPlayback() async throws {
        let url = try PlaybackTestSupport.audioFile(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let player = PlayerController(resolver: PlaybackFileResolver(url: url, duration: 3))
        defer { player.pause() }
        var settings = PlaybackTransitionSettings()
        settings.crossfadeSeconds = 1
        settings.gapless = true
        settings.automix = false
        player.apply(settings)
        player.play([first, second])
        try await PlaybackTestSupport.waitUntil(timeout: 6) { player.crossfadeState != nil }
        XCTAssertFalse(player.activePlayerAllowsExternalPlayback, "The incoming deck player is now the active one")
        try await PlaybackTestSupport.waitUntil { player.crossfadeState == nil && player.hasStandbyPlayer }
        XCTAssertEqual(player.standbyPlayerAllowsExternalPlayback, false, "The outgoing player returns to the deck")
        XCTAssertFalse(player.isExternalPlaybackActive)
        XCTAssertNil(player.errorMessage)
    }

    func testSessionConfigurationIsLongFormPlaybackWithoutMixingOptions() {
        let configuration = PlaybackAudioRoute.session
        XCTAssertEqual(configuration.category, .playback)
        XCTAssertEqual(configuration.mode, .default)
        XCTAssertEqual(configuration.policy, .longFormAudio)
        XCTAssertEqual(configuration.options, [])
    }

    func testControllerAppliesTheSessionConfigurationToTheSharedSession() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("macOS ignores the long-form route-sharing policy; the Mac picks its own output")
        #endif
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default, policy: .default, options: [])
        let player = PlayerController(resolver: PlaybackResolutionGate())
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio)
        XCTAssertEqual(session.categoryOptions, [])
        withExtendedLifetime(player) {}
    }

    func testRouteClassificationMapsEachPortType() {
        let expected: [(AVAudioSession.Port, PlaybackAudioRoute.Kind)] = [
            (.airPlay, .airplay), (.bluetoothA2DP, .bluetooth), (.bluetoothLE, .bluetooth), (.bluetoothHFP, .bluetooth),
            (.carAudio, .car), (.builtInSpeaker, .builtin), (.builtInReceiver, .builtin),
            (.headphones, .other), (.HDMI, .other), (.usbAudio, .other), (.lineOut, .other)
        ]
        for (port, kind) in expected {
            XCTAssertEqual(PlaybackAudioRoute.kind(for: port), kind, port.rawValue)
        }
    }

    func testRouteClassificationPrefersTheMostSpecificOutput() {
        XCTAssertEqual(PlaybackAudioRoute.kind(for: [.builtInSpeaker, .airPlay]), .airplay)
        XCTAssertEqual(PlaybackAudioRoute.kind(for: [.bluetoothA2DP, .carAudio]), .car)
        XCTAssertEqual(PlaybackAudioRoute.kind(for: [.builtInSpeaker, .bluetoothA2DP]), .bluetooth)
        XCTAssertEqual(PlaybackAudioRoute.kind(for: [.headphones, .builtInSpeaker]), .builtin)
        XCTAssertEqual(PlaybackAudioRoute.kind(for: [.headphones]), .other)
        XCTAssertEqual(PlaybackAudioRoute.kind(for: []), .other)
    }

    func testRouteKindsAreTheBoundedLogValues() {
        XCTAssertEqual(PlaybackAudioRoute.Kind.allCases.map(\.rawValue), ["airplay", "bluetooth", "car", "builtin", "other"])
    }
}
