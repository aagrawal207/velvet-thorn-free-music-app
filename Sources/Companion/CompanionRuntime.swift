import Foundation

@MainActor
enum CompanionRuntime {
    // The app installs its existing model's controller before activating companion transports.
    static var playback: CompanionPlaybackController?
}
