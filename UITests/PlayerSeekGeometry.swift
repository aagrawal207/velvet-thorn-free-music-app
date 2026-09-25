import CoreGraphics
import XCTest

/// Maps between the player's seek element and playback progress with the app's trail geometry, so tests place
/// touches where a position actually lies instead of assuming the bar alone spans the whole song.
extension XCUIApplication {
    var playerProgressTrail: PlayerProgressTrail {
        let bar = sliders["player.seek"].frame
        let like = buttons["player.like"].frame
        return PlayerProgressTrail(rowWidth: like.maxX - bar.minX)
    }

    /// Progress for a touch at the normalized horizontal offset within the seek element.
    func playerSeekProgress(atNormalizedX dx: CGFloat) -> CGFloat {
        playerProgressTrail.progress(atX: dx * sliders["player.seek"].frame.width)
    }

    /// Normalized horizontal offset within the seek element that lands the given progress. Exceeds 1 when the
    /// position lies on the heart's stretch of the trail.
    func playerSeekNormalizedX(forProgress progress: CGFloat) -> CGFloat {
        playerProgressTrail.x(forProgress: progress) / sliders["player.seek"].frame.width
    }
}
