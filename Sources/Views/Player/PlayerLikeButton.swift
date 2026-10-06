import SwiftUI
import TipKit

/// The heart in the track heading, a 52-point target with three states: `bolt.heart.fill` in the accent when super
/// liked, `heart.fill` in the accent when liked, a `heart` outline in the artwork text colour otherwise. A tap runs
/// `action` (like, or remove the like and any super like with it); a 0.4-second hold runs `superLikeAction` instead.
/// A like bounces the glyph with a light tap; a super like adds a spark burst with the success haptic. Reduce Motion
/// keeps the colour and glyph changes and drops every scale, offset and burst.
@MainActor
struct PlayerLikeButton: View {
    let liked: Bool
    let superLiked: Bool
    let action: () -> Void
    let superLikeAction: () -> Void

    static let size: CGFloat = 52
    static let holdDuration: TimeInterval = 0.4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A hold owns the rest of its press: the release that follows must not also run the tap action.
    @State private var holdFired = false
    /// Likes and promotions made from this heart drive the motion and haptics, so skipping to a song that is
    /// already liked or super liked stays silent.
    @State private var likes = 0
    @State private var promotions = 0

    var body: some View {
        Button(action: tap) {
            ZStack {
                if !reduceMotion {
                    SuperLikeBurst(trigger: promotions)
                }
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(liked || superLiked ? AppTheme.accent : AppTheme.artworkSecondaryText)
                    // The state glyph flips at once; only the like bounce, promotion bounce and press scale animate.
                    .transaction { $0.animation = nil }
                    .symbolEffect(.bounce.up.byLayer, options: .speed(1.6), value: likes)
                    .phaseAnimator([false, true], trigger: promotions) { glyph, bouncing in
                        glyph.scaleEffect(bouncing && !reduceMotion ? 1.18 : 1)
                    } animation: { _ in
                        .easeInOut(duration: 0.12)
                    }
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Rectangle())
        }
        // Any press transition clears the hold flag: a new press starts clean, and a release clears it only after
        // the Button has delivered (or skipped) its action for that release.
        .buttonStyle(PlayerHeartButtonStyle(onPressingChanged: { _ in holdFired = false }))
        .simultaneousGesture(LongPressGesture(minimumDuration: Self.holdDuration).onEnded { _ in hold() })
        .sensoryFeedback(.impact(weight: .light), trigger: likes)
        .sensoryFeedback(.success, trigger: promotions)
        .accessibilityLabel(liked || superLiked ? "Unlike this song" : "Like this song")
        .accessibilityValue(superLiked ? "Super Liked" : "Liked", isEnabled: liked || superLiked)
        .accessibilityHint("Hold to super like", isEnabled: !superLiked)
        .accessibilityAddTraits(liked || superLiked ? .isSelected : [])
        .accessibilityAction(named: superLiked ? "Change to Like" : "Super Like") { toggleTier() }
        .accessibilityIdentifier("player.like")
        .popoverTip(SuperLikeTip(), arrowEdge: .top)
    }

    private var symbol: String {
        superLiked ? "bolt.heart.fill" : liked ? "heart.fill" : "heart"
    }

    private func tap() {
        guard !holdFired else {
            holdFired = false
            return
        }
        let liking = !liked && !superLiked
        action()
        if liking { likes += 1 }
    }

    private func hold() {
        holdFired = true
        toggleTier()
    }

    private func toggleTier() {
        let promoting = !superLiked
        superLikeAction()
        if promoting { promotions += 1 }
    }
}

/// Six accent sparks that fly out from the heart once per promotion and fade before they stop, then hold invisible.
/// One-shot keyframes on a trigger keep it state-driven; nothing runs on appearance or on a revisit.
private struct SuperLikeBurst: View {
    let trigger: Int

    private struct Phase {
        var radius: CGFloat = 0
        var scale: CGFloat = 0.4
        var opacity: Double = 0
    }

    var body: some View {
        KeyframeAnimator(initialValue: Phase(), trigger: trigger) { phase in
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 5, height: 5)
                        .scaleEffect(phase.scale)
                        .offset(y: -phase.radius)
                        .rotationEffect(.degrees(Double(index) * 60 + 30))
                }
            }
            .opacity(phase.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.radius) {
                CubicKeyframe(8, duration: 0.05)
                CubicKeyframe(26, duration: 0.3)
                CubicKeyframe(30, duration: 0.15)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(1, duration: 0.2)
                LinearKeyframe(0.2, duration: 0.3)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.05)
                LinearKeyframe(1, duration: 0.2)
                LinearKeyframe(0, duration: 0.25)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Presses shrink the heart glyph in place instead of dimming, since the unliked glyph is only an outline.
struct PlayerHeartButtonStyle: ButtonStyle {
    /// Reports each press beginning and ending so the heart can tell a release after a hold from a plain tap.
    var onPressingChanged: ((Bool) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressing in onPressingChanged?(pressing) }
    }
}
