#if DEBUG
import SwiftUI
import UIKit

/// Writes in-process window captures for layout checks when the window server cannot be screenshotted (locked Mac).
@MainActor
enum DebugWindowSnapshot {
    static func run(_ model: MusicAppModel) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-window-snapshot"), arguments.indices.contains(index + 2) else { return }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let steps = arguments[index + 2].split(separator: ",").map(String.init)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(5))
        for (position, step) in steps.enumerated() {
            switch step {
            case "player": model.isPlayerPresented = true
            case "devices": model.isNearbyDevicesPresented = true
            case "settings": model.isSettingsPresented = true
            case "search": model.selectTab(.search)
            case "library": model.selectTab(.library)
            case "stats": model.selectTab(.recap)
            case "home": model.selectTab(.home)
            case "play": if let track = model.library.favorites.first ?? model.library.recentlyPlayed.first?.track {
                _ = model.play(track, in: model.library.favorites)
            }
            case "close":
                model.isPlayerPresented = false
                model.isNearbyDevicesPresented = false
                model.isSettingsPresented = false
            default: break
            }
            try? await Task.sleep(for: .seconds(3))
            capture(to: directory.appendingPathComponent("\(position)-\(step).png"))
        }
    }

    /// `--debug-player-sheet options|devices|queue|lyrics` opens that player sheet when the player appears.
    static func requestedPlayerSheet(for track: Track) -> NowPlayingView.PlayerSheet? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--debug-player-sheet"), arguments.indices.contains(index + 1) else { return nil }
        switch arguments[index + 1] {
        case "options": return .actions(track, .options)
        case "devices": return .actions(track, .devices)
        case "queue": return .queue
        case "lyrics": return .lyrics
        default: return nil
        }
    }

    /// Mac sheets live in their own windows, so every visible window is written beside the first.
    private static func capture(to url: URL) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 1 }
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        var views: [UIView] = [window]
        var presented = window.rootViewController?.presentedViewController
        while let controller = presented {
            views.append(controller.view)
            presented = controller.presentedViewController
        }
        for (index, view) in views.enumerated() where view.bounds.width > 1 {
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let name = index == 0 ? url : url.deletingPathExtension().appendingPathExtension("sheet\(index).png")
            try? image.pngData()?.write(to: name)
        }
    }
}
#endif
