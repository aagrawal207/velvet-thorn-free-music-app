import SwiftUI
import WidgetKit

@main
struct BreezyWidgets: WidgetBundle {
    var body: some Widget {
        RecentlyPlayedWidget()
        LikedSongsWidget()
        MixWidget()
        NowPlayingWidget()
        BreezyLauncherWidget()
        PlayPauseControl()
        OpenBreezyControl()
    }
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MusicWidgetKind.recentlyPlayed.widgetKind,
                            provider: MusicWidgetTimelineProvider(kind: .recentlyPlayed)) { entry in
            MusicWidgetView(snapshot: entry.snapshot, kind: .recentlyPlayed)
        }
        .configurationDisplayName("Recently played")
        .description("Return to songs you've played in Velvet Thorn.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct LikedSongsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MusicWidgetKind.likedSongs.widgetKind,
                            provider: MusicWidgetTimelineProvider(kind: .likedSongs)) { entry in
            MusicWidgetView(snapshot: entry.snapshot, kind: .likedSongs)
        }
        .configurationDisplayName("Liked songs")
        .description("Keep your favorite songs close.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct MixWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: MusicWidgetKind.mixes.widgetKind, intent: MixWidgetConfigurationIntent.self,
                               provider: MixWidgetTimelineProvider()) { entry in
            MusicWidgetView(snapshot: entry.snapshot, kind: .mixes, mixKind: entry.mixKind)
        }
        .configurationDisplayName("Mix")
        .description("Choose your Daily Mix or Discover Weekly.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
