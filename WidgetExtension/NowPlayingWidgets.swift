import AppIntents
import SwiftUI
import WidgetKit

struct NowPlayingEntry: TimelineEntry, Sendable {
    let date: Date
    let state: WidgetPlaybackState
}

struct NowPlayingTimelineProvider: TimelineProvider {
    static let preview = WidgetPlaybackState(hasSelection: true, isPlaying: false, title: "Tum Hi Ho", subtitle: "Arijit Singh")

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), state: Self.preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let state = WidgetPlaybackStateStore().read()
        completion(NowPlayingEntry(date: Date(), state: context.isPreview && !state.hasSelection ? Self.preview : state))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // The app reloads this kind whenever the selection or play state changes.
        completion(Timeline(entries: [NowPlayingEntry(date: Date(), state: WidgetPlaybackStateStore().read())], policy: .never))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetPlaybackState.nowPlayingWidgetKind, provider: NowPlayingTimelineProvider()) { entry in
            NowPlayingWidgetView(state: entry.state)
        }
        .configurationDisplayName("Play or Pause")
        .description("Play or pause your last song, or tap to open Velvet Thorn.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

struct BreezyLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetPlaybackState.launcherWidgetKind, provider: NowPlayingTimelineProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "music.note").font(.title2.weight(.semibold)).widgetAccentable()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open Velvet Thorn")
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Open Velvet Thorn")
        .description("Open Velvet Thorn from your Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct PlaybackControlProvider: ControlValueProvider {
    var previewValue: WidgetPlaybackState { NowPlayingTimelineProvider.preview }

    func currentValue() async throws -> WidgetPlaybackState {
        WidgetPlaybackStateStore().read()
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetPlaybackState.playPauseControlKind, provider: PlaybackControlProvider()) { state in
            ControlWidgetToggle(isOn: state.isPlaying, action: SetBreezyPlaybackIntent()) {
                Label(NowPlayingWidgetPresentation(state: state).controlTitle, systemImage: "music.note")
            } valueLabel: { isOn in
                Label(isOn ? "Playing" : "Paused", systemImage: isOn ? "pause.fill" : "play.fill")
            }
            .tint(state.accent.color)
        }
        .displayName("Play or Pause")
        .description("Play or pause your last song in Velvet Thorn.")
    }
}

struct OpenBreezyControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetPlaybackState.openControlKind) {
            ControlWidgetButton(action: OpenBreezyPlayerIntent()) {
                Label("Velvet Thorn", systemImage: "music.note")
            }
        }
        .displayName("Open Velvet Thorn")
        .description("Open Velvet Thorn to the song you were playing.")
    }
}
