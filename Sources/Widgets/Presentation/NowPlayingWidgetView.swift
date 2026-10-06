import AppIntents
import SwiftUI
import WidgetKit

struct NowPlayingWidgetPresentation: Equatable {
    static let openURL = URL(string: "ganabajana://player")!

    let state: WidgetPlaybackState

    var symbol: String { state.isPlaying ? "pause.fill" : "play.fill" }
    var actionLabel: String { state.isPlaying ? "Pause" : "Play" }

    var title: String {
        if let title = state.title { return title }
        guard state.hasSelection else { return "Velvet Thorn" }
        return state.isLiveRadio ? "Live radio" : "Your last song"
    }

    var subtitle: String {
        guard state.hasSelection else { return "Choose music to play" }
        return state.subtitle ?? (state.isPlaying ? "Playing" : "Paused")
    }

    var inlineText: String {
        guard state.hasSelection else { return "Velvet Thorn" }
        return state.title ?? (state.isPlaying ? "Playing in Velvet Thorn" : "Paused in Velvet Thorn")
    }

    var controlTitle: String { state.title ?? "Velvet Thorn" }

    var accessibilityLabel: String {
        guard state.hasSelection else { return "Open Velvet Thorn" }
        let detail = state.title.map { title in state.subtitle.map { "\(title), \($0)" } ?? title } ?? (state.isLiveRadio ? "Live radio" : "Last song")
        return "\(detail). \(state.isPlaying ? "Playing" : "Paused")"
    }
}

@MainActor
struct NowPlayingWidgetView: View {
    let state: WidgetPlaybackState

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var presentation: NowPlayingWidgetPresentation { NowPlayingWidgetPresentation(state: state) }
    private var fullColor: Bool { renderingMode == .fullColor }
    private var accent: Color { fullColor ? state.accent.color : .primary }

    var body: some View {
        content
            .widgetURL(NowPlayingWidgetPresentation.openURL)
            .containerBackground(for: .widget) {
                if fullColor, family == .systemSmall {
                    AppTheme.surface.overlay {
                        LinearGradient(colors: [state.accent.color.opacity(0.14), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                } else {
                    Color.clear
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: Label(presentation.inlineText, systemImage: state.isPlaying ? "waveform" : "music.note")
        default: small
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if state.hasSelection {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: presentation.symbol)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
            } else {
                Image(systemName: "music.note").font(.title2.weight(.semibold)).widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.hasSelection ? "\(presentation.actionLabel) Velvet Thorn" : "Open Velvet Thorn")
        .accessibilityValue(state.hasSelection ? presentation.accessibilityLabel : "")
        .accessibilityAddTraits(.isButton)
    }

    private var rectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Label("Velvet Thorn", systemImage: state.isPlaying ? "waveform" : "music.note")
                    .font(.caption2.weight(.semibold))
                    .widgetAccentable()
                Text(presentation.title).font(.headline).lineLimit(1)
                Text(presentation.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            if state.hasSelection {
                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: presentation.symbol)
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(AccessoryWidgetBackground().clipShape(Circle()))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .widgetAccentable()
                .accessibilityLabel(presentation.actionLabel)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Velvet Thorn", systemImage: state.isPlaying ? "waveform" : "music.note")
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text(presentation.title)
                .font(.headline)
                .foregroundStyle(fullColor ? AppTheme.primaryText : .primary)
                .lineLimit(2)
            Text(presentation.subtitle)
                .font(.caption)
                .foregroundStyle(fullColor ? AppTheme.secondaryText : .secondary)
                .lineLimit(1)
            HStack {
                Spacer(minLength: 0)
                if state.hasSelection {
                    Button(intent: TogglePlaybackIntent()) {
                        Image(systemName: presentation.symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(fullColor ? AppTheme.onAccent : Color.primary)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(fullColor ? AnyShapeStyle(state.accent.color) : AnyShapeStyle(.fill.secondary)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .widgetAccentable()
                    .accessibilityLabel(presentation.actionLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tint(state.accent.color)
    }
}
