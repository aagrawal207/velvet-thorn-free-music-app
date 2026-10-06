import Foundation
import SwiftUI
import TipKit

/// Teaches the heart's hold gesture once, after the listener has liked a song with the player open.
struct SuperLikeTip: Tip {
    static let songLiked = Tips.Event(id: "superLike.songLiked")

    var title: Text { Text("Hold to Super Like") }
    var message: Text? { Text("Super likes count more in your mixes and can download on their own.") }
    var image: Image? { Image(systemName: "bolt.heart.fill") }
    var rules: [Rule] {
        #Rule(Self.songLiked) { $0.donations.count >= 1 }
    }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

/// TipKit lifecycle. Real launches use the device datastore; UI-test launches use a fresh temporary one and hide
/// every tip unless `--show-tips` lets the real rules run, so unrelated workflows never meet a popover. Unit hosts
/// never configure.
@MainActor
enum TipSupport {
    private(set) static var isConfigured = false

    static func configure(isTesting: Bool, arguments: [String]) {
        guard !isConfigured else { return }
        let uiTesting = arguments.contains("--uitesting")
        guard !isTesting || uiTesting else { return }
        do {
            if uiTesting {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GanaBajanaTips-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Tips.configure([.datastoreLocation(.url(directory)), .displayFrequency(.immediate)])
                if !arguments.contains("--show-tips") { Tips.hideAllTipsForTesting() }
            } else {
                try Tips.configure([.displayFrequency(.immediate)])
            }
            isConfigured = true
        } catch {
            // A tip is help, not a feature; a datastore failure must not stop the app.
        }
    }

    /// Donations before configuration would be lost or logged as errors by TipKit; unit hosts skip them.
    static func donateSongLiked() {
        guard isConfigured else { return }
        SuperLikeTip.songLiked.sendDonation()
    }
}
