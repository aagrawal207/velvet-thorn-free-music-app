import SwiftUI

/// The century's hearts, live only for `HeartBurst.duration`. Decorative: no touches, no VoiceOver focus, and under
/// Reduce Motion nothing is drawn because the toast already carries the news.
@MainActor
struct HeartBurstOverlay: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Root passes false while the full player covers it, so only the visible surface animates.
    var isActive = true

    var body: some View {
        if isActive, !reduceMotion, let burst = model.delights.heartBurst {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(burst.startedAt)
                Canvas { context, size in
                    HeartBurstParticles.draw(in: &context, size: size, elapsed: elapsed)
                } symbols: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .tag(0)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppTheme.gold)
                        .tag(1)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .id(burst.id)
        }
    }
}

/// Fixed pseudo-random particles, so every burst has the same choreography and nothing is allocated per frame.
enum HeartBurstParticles {
    struct Particle: Sendable {
        let horizontal: Double
        let vertical: Double
        let size: Double
        let delay: Double
        let spin: Double
        let symbol: Int
    }

    static let particles: [Particle] = (0..<18).map { index in
        Particle(horizontal: unit(index, 1) - 0.5, vertical: 0.95 + unit(index, 2) * 0.6, size: 0.6 + unit(index, 3) * 0.7,
                 delay: unit(index, 4) * 0.18, spin: unit(index, 5) - 0.5, symbol: index % 4 == 0 ? 1 : 0)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let width = Double(size.width)
        let height = Double(size.height)
        let originY = height * 0.62
        // Speeds scale with the height, so the highest arc peaks well below the top edge on phones and iPads alike.
        let lift = height * 0.46
        let gravity = lift * 1.5
        for particle in particles {
            let t = elapsed - particle.delay
            let progress = t / (HeartBurst.duration - particle.delay)
            guard t > 0, progress < 1, let heart = context.resolveSymbol(id: particle.symbol) else { continue }
            let x = width / 2 + particle.horizontal * width * 0.6 * t
            let y = originY - particle.vertical * lift * t + 0.5 * gravity * t * t
            let grow = min(1, 0.4 + t / 0.3)
            var copy = context
            copy.opacity = min(1, t / 0.12) * (1 - progress * progress * progress)
            copy.translateBy(x: x, y: y)
            copy.rotate(by: .radians(particle.spin * t * 2))
            copy.scaleBy(x: particle.size * grow, y: particle.size * grow)
            copy.draw(heart, at: .zero)
        }
    }

    private static func unit(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index * 97 + salt * 13) * 12.9898) * 43_758.5453
        return value - value.rounded(.down)
    }
}
