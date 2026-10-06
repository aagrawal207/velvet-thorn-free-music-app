import CoreGraphics
import XCTest

/// Maps between the player's seek element and playback progress. The bar spans the whole seek element and touches
/// map linearly across it, so both directions are the identity; the helpers stay so drivers read as intent.
extension XCUIApplication {
    /// Progress for a touch at the normalized horizontal offset within the seek element.
    func playerSeekProgress(atNormalizedX dx: CGFloat) -> CGFloat {
        min(max(dx, 0), 1)
    }

    /// Normalized horizontal offset within the seek element that lands the given progress.
    func playerSeekNormalizedX(forProgress progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }
}
