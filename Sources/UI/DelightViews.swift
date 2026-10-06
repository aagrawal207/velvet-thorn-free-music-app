import SwiftUI

/// The full player's eyebrow: "NOW PLAYING", or between 2:00 and 3:59 local time the night's cheeky line. The minute
/// timeline swaps it in or out when the clock crosses the window while the player is open.
@MainActor
struct PlayerEyebrow: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        TimelineView(.everyMinute) { context in
            let line = LateNightEyebrow.line(at: context.date)
            Text(line?.text ?? "NOW PLAYING")
                .appFont(.caption2, weight: .bold)
                .tracking(1.6)
                .lineLimit(1)
                // Spoken in sentence case; VoiceOver would otherwise read some all-caps words letter by letter.
                .accessibilityLabel(line?.spokenText ?? "NOW PLAYING")
                .onChange(of: line?.option, initial: true) { _, option in
                    if option != nil { model.delights.lateNightShown(at: context.date) }
                }
        }
    }
}

extension View {
    /// Places the equalizer's cheeky line beneath this curve; see `EqualizerDelightLine`.
    func equalizerDelightLine(gains: [Double], isAdjusting: Bool) -> some View {
        modifier(EqualizerDelightLine(extreme: EqualizerExtreme(gains: gains), isAdjusting: isAdjusting))
    }
}

/// The cheeky line under the equalizer curve. It holds its state while a finger is on a control: its height would move
/// the slider under the finger and could pull a band off the minimum, so it settles on lift.
@MainActor
struct EqualizerDelightLine: ViewModifier {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let extreme: EqualizerExtreme?
    let isAdjusting: Bool
    @State private var shown: EqualizerExtreme?

    init(extreme: EqualizerExtreme?, isAdjusting: Bool) {
        self.extreme = extreme
        self.isAdjusting = isAdjusting
        _shown = State(initialValue: isAdjusting ? nil : extreme)
    }

    func body(content: Content) -> some View {
        VStack(spacing: 4) {
            content
            if let shown {
                Text(shown.message)
                    .appFont(.footnote, weight: .medium)
                    .foregroundStyle(AppTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .transition(.opacity)
                    .accessibilityIdentifier("equalizer.delight")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: shown)
        .onChange(of: extreme) { _, extreme in
            if !isAdjusting { shown = extreme }
        }
        .onChange(of: isAdjusting) { _, adjusting in
            if !adjusting { shown = extreme }
        }
        .onChange(of: shown) { _, current in
            guard let current else { return }
            model.delights.equalizerLineShown(current)
            AppAccessibilityAnnouncements.post(current.message)
        }
        .onAppear {
            // The opening state is recorded but not announced; VoiceOver reads it with the page.
            if let shown { model.delights.equalizerLineShown(shown) }
        }
    }
}

/// Home's anniversary card, for seven days from each anniversary of the first recorded listen. Hidden while listening
/// history is off; Dismiss keeps it away until the next anniversary.
@MainActor
struct HomeAnniversaryCard: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let card = model.delights.anniversaryCard() {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "birthday.cake.fill")
                    .appFont(.title3)
                    .foregroundStyle(AppTheme.gold)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .appFont(.headline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(card.message)
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home.anniversary.text")
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { model.delights.dismissAnniversary(card) }
                } label: {
                    Image(systemName: "xmark")
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("home.anniversary.dismiss")
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.compact))
            .padding(.horizontal, 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.anniversary")
            .transition(.opacity)
            .onAppear { model.delights.anniversaryShown(card) }
        }
    }
}
