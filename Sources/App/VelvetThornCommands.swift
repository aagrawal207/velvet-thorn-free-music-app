import SwiftUI

/// Menu bar on the Mac and the hardware-keyboard shortcut overlay on iPad, both driving the same model actions.
@MainActor
struct VelvetThornCommands: Commands {
    let model: MusicAppModel

    var body: some Commands {
        // Every window shares one navigation state, so a second window would mirror the first.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { present { model.isSettingsPresented = true } }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Playback") {
            // Text fields keep the space bar: UIKit gives system text input priority over this key command.
            Button(isPlaying ? "Pause" : "Play") { togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.player.hasPlaybackSelection)
            Button("Next") { model.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(model.player.currentTrack == nil)
            Button("Previous") { model.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(model.player.currentTrack == nil)

            Divider()

            Button(isLiked ? "Remove Like" : "Like Song") {
                if let track = model.player.currentTrack { model.toggleLike(track, surface: .menu) }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.player.currentTrack == nil || !model.library.hasLoadedDocument)
            Button(model.player.shuffleEnabled ? "Turn Off Shuffle" : "Shuffle") { model.player.toggleShuffle() }
                .disabled(model.player.currentTrack == nil)
            Button(repeatTitle) { model.player.cycleRepeatMode() }
                .disabled(model.player.currentTrack == nil)

            Divider()

            Button("Now Playing") { present { model.isPlayerPresented = true } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.player.hasPlaybackSelection)
            Button("Devices…") { present { model.isNearbyDevicesPresented = true } }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandGroup(before: .sidebar) {
            tabButton("Home", tab: .home, key: "1")
            tabButton("Search", tab: .search, key: "2")
            tabButton("Library", tab: .library, key: "3")
            tabButton("Stats", tab: .recap, key: "4")
            Button("Find") { show(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
        }
    }

    private var isPlaying: Bool {
        model.player.isPlaying || model.player.isLoading
    }

    private var isLiked: Bool {
        model.player.currentTrack.map { model.library.isFavorite($0) } ?? false
    }

    private var repeatTitle: String {
        switch model.player.repeatMode {
        case .off: "Repeat All"
        case .all: "Repeat One"
        case .one: "Turn Off Repeat"
        }
    }

    private func togglePlayback() {
        if model.player.errorMessage != nil { model.player.retry() } else { model.player.togglePlayback() }
    }

    private func tabButton(_ title: String, tab: AppTab, key: KeyEquivalent) -> some View {
        Button(title) { show(tab) }
            .keyboardShortcut(key, modifiers: .command)
    }

    /// Selecting Search while it is showing focuses its field, matching a second tab tap.
    private func show(_ tab: AppTab) {
        model.isPlayerPresented = false
        model.isSettingsPresented = false
        model.isNearbyDevicesPresented = false
        model.selectTab(tab)
    }

    /// Root sheets cannot present over the full-screen player or each other.
    private func present(_ action: () -> Void) {
        model.isPlayerPresented = false
        model.isSettingsPresented = false
        model.isNearbyDevicesPresented = false
        action()
    }
}
