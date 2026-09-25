#if DEBUG
import Observation
import SwiftUI
import UIKit
import WidgetKit

@MainActor
enum DebugWidgetSupport {
    @Observable fileprivate final class State {
        var snapshot = WidgetLibrarySnapshot.empty
    }

    private static let state = State()
    private static var publisher: WidgetSnapshotPublisher?
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isEnabled: Bool {
        arguments.contains("--uitesting") && arguments.contains("--seed-ui") && arguments.contains("--widget-fixture")
    }

    static var sharesWithExtension: Bool { isEnabled && arguments.contains("--widget-sharing-fixture") }
    static var previewsWidget: Bool { isEnabled && arguments.contains("--widget-preview") }
    static var sharedSnapshot: WidgetLibrarySnapshot { state.snapshot }

    static var kind: MusicWidgetKind { value("--widget-kind").flatMap(MusicWidgetKind.init(rawValue:)) ?? .recentlyPlayed }
    static var mixKind: GeneratedPlaylistKind { arguments.contains("--widget-weekly") ? .discoverWeekly : .dailyMix }
    static var family: WidgetFamily {
        switch value("--widget-family") {
        case "medium": .systemMedium
        case "large": .systemLarge
        default: .systemSmall
        }
    }

    static func seed(_ library: LibraryStore) {
        guard isEnabled else { return }
        library.preferences.hasCompletedWelcome = true
        library.preferences.autoplay = false
        var tracks = DebugMusicFixtures.tracks
        if arguments.contains("--widget-long-titles") {
            for index in tracks.indices {
                tracks[index].title = "A long evening song title with संगीत and a quiet piano recording \(index + 1)"
                tracks[index].credits = [ArtistCredit(name: "The extraordinarily long artist name and accompanying orchestra")]
            }
        }
        for favorite in library.favorites { library.toggleFavorite(favorite) }
        for (index, track) in tracks.enumerated().reversed() {
            library.toggleFavorite(track)
            library.recordRecent(track: track, position: Double(index + 1) * 12)
        }
        for kind in GeneratedPlaylistKind.allCases {
            let period = kind == .dailyMix ? RecommendationEngine.dayKey(for: Date(), calendar: .current)
                : RecommendationEngine.weekKey(for: Date(), calendar: .current)
            library.saveMix(GeneratedPlaylist(kind: kind, tracks: tracks, generatedAt: Date(), periodKey: period, seedArtists: []))
        }
        if arguments.contains("--widget-empty") {
            library.clearHistory()
            for track in library.favorites { library.toggleFavorite(track) }
        }
        if arguments.contains("--widget-history-off") { library.preferences.saveListeningHistory = false }
    }

    static func startSharing(_ model: MusicAppModel) {
        guard sharesWithExtension else { return }
        let store = WidgetSnapshotStore(directory: WidgetSnapshotStore.sharedDirectory())
        state.snapshot = store.read()
        publisher = WidgetSnapshotPublisher(library: model.library, store: store, thumbnail: { thumbnail($0.id) }) {
            state.snapshot = store.read()
            for kind in MusicWidgetKind.allCases { WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind) }
        }
    }

    static func previewSnapshot(_ library: LibraryStore) -> WidgetLibrarySnapshot {
        if arguments.contains("--widget-unavailable") { return .unavailable }
        let snapshot = WidgetLibrarySnapshot.projection(recentlyPlayed: library.recentlyPlayed.map(\.track),
            likedSongs: library.favorites, mixes: library.mixes, historyEnabled: library.preferences.saveListeningHistory,
            accent: library.preferences.accent)
        return snapshot.withArtwork(snapshot.displayedTracks.reduce(into: [:]) { images, track in images[track.id] = thumbnail(track.id) })
    }

    private static func thumbnail(_ id: String) -> Data? {
        let names = ["IconPreview-Thorn", "IconPreview-Sonnet", "IconPreview-Notes", "IconPreview-Waves", "IconPreview-Boombox"]
        let index = DebugMusicFixtures.tracks.firstIndex { $0.id == id } ?? 0
        return UIImage(named: names[index % names.count])?.jpegData(compressionQuality: 0.5)
    }

    private static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

@MainActor
struct DebugWidgetPreviewView: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        GeometryReader { geometry in
            let family = DebugWidgetSupport.family
            let width = family == .systemSmall ? CGFloat(160) : min(360, geometry.size.width - 32)
            let height: CGFloat = family == .systemLarge ? 360 : 160
            let snapshot = DebugWidgetSupport.previewSnapshot(model.library)
            let kind = DebugWidgetSupport.kind
            let mix = DebugWidgetSupport.mixKind
            let presentation = MusicWidgetPresentation(snapshot: snapshot, kind: kind, mixKind: mix)
            VStack(spacing: 24) {
                HStack {
                    Text("Widget preview").font(.headline)
                    Spacer()
                    Button("Done") { model.isWidgetPreviewPresented = false }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("widgetPreview.done")
                }
                Spacer(minLength: 0)
                Group {
                    if family == .systemSmall {
                        Link(destination: presentation.widgetRoute(for: family).url) {
                            MusicWidgetView(snapshot: snapshot, kind: kind, mixKind: mix)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(presentation.smallAccessibilityLabel)
                        .accessibilityIdentifier("widgetPreview.smallLink")
                    } else {
                        MusicWidgetView(snapshot: snapshot, kind: kind, mixKind: mix)
                    }
                }
                .environment(\.musicWidgetPreviewFamily, family)
                .frame(width: width, height: height)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("widgetPreview.canvas")
                Spacer(minLength: 0)
                Text("Breezy").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.background)
            .environment(\.openURL, OpenURLAction { url in
                model.isWidgetPreviewPresented = false
                model.handleOpenURL(url)
                return .handled
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("widgetPreview.screen")
    }
}
#endif
