import Foundation
import OSLog
import WidgetKit

struct MusicWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: WidgetLibrarySnapshot
    var mixKind: GeneratedPlaylistKind = .dailyMix
}

enum MusicWidgetTimeline {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Widgets")

    static func read(kind: MusicWidgetKind, mixKind: GeneratedPlaylistKind = .dailyMix) -> MusicWidgetEntry {
        let snapshot = WidgetSnapshotStore(directory: WidgetSnapshotStore.sharedDirectory()).read()
        let state = MusicWidgetPresentation(snapshot: snapshot, kind: kind, mixKind: mixKind).timelineState
        log.info("event=widget_timeline kind=\(kind.rawValue, privacy: .public) weekly=\(mixKind == .discoverWeekly ? 1 : 0) ready=\(state == .ready ? 1 : 0) empty=\(state == .empty ? 1 : 0) unavailable=\(state == .unavailable ? 1 : 0)")
        return MusicWidgetEntry(date: Date(), snapshot: snapshot, mixKind: mixKind)
    }

    static func timeline(_ entry: MusicWidgetEntry) -> Timeline<MusicWidgetEntry> {
        // Publication requests reloads; WidgetKit decides when a requested refresh actually runs.
        Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(30 * 60)))
    }
}

struct MusicWidgetTimelineProvider: TimelineProvider {
    let kind: MusicWidgetKind

    func placeholder(in context: Context) -> MusicWidgetEntry {
        MusicWidgetEntry(date: Date(), snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (MusicWidgetEntry) -> Void) {
        completion(MusicWidgetTimeline.read(kind: kind))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<MusicWidgetEntry>) -> Void) {
        completion(MusicWidgetTimeline.timeline(MusicWidgetTimeline.read(kind: kind)))
    }
}

struct MixWidgetTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MusicWidgetEntry {
        MusicWidgetEntry(date: Date(), snapshot: .empty)
    }

    func snapshot(for configuration: MixWidgetConfigurationIntent, in context: Context) async -> MusicWidgetEntry {
        MusicWidgetTimeline.read(kind: .mixes, mixKind: configuration.mixKind)
    }

    func timeline(for configuration: MixWidgetConfigurationIntent, in context: Context) async -> Timeline<MusicWidgetEntry> {
        MusicWidgetTimeline.timeline(MusicWidgetTimeline.read(kind: .mixes, mixKind: configuration.mixKind))
    }
}
