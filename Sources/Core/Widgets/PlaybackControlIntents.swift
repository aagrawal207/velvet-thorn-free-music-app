import AppIntents
import Foundation

enum PlaybackIntentCommand: String, Sendable {
    case toggle, play, pause, openPlayer
}

enum PlaybackIntentOutcome: String, Sendable {
    case success, unchanged, noSelection, unavailable
}

/// The app installs its model here. The widget extension compiles these intents but never performs playback:
/// the system runs `AudioPlaybackIntent` and `openAppWhenRun` intents in the app process.
@MainActor
enum PlaybackIntentRuntime {
    static var perform: (@MainActor (PlaybackIntentCommand) -> PlaybackIntentOutcome)?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play or Pause Velvet Thorn" }
    static var description: IntentDescription { IntentDescription("Plays or pauses the last song in Velvet Thorn.") }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = PlaybackIntentRuntime.perform?(.toggle)
        return .result()
    }
}

struct SetBreezyPlaybackIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Set Velvet Thorn Playback" }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Playing")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = PlaybackIntentRuntime.perform?(value ? .play : .pause)
        return .result()
    }
}

struct OpenBreezyPlayerIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Velvet Thorn" }
    static var description: IntentDescription { IntentDescription("Opens Velvet Thorn to the song you were playing.") }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = PlaybackIntentRuntime.perform?(.openPlayer)
        return .result()
    }
}
