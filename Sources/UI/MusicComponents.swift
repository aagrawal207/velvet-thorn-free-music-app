import SwiftUI

@MainActor
struct TrackRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.secondaryTextColor) private var secondaryTextColor
    let track: Track
    var tracks: [Track] = []
    var rank: Int? = nil
    var subtitle: String? = nil
    var accessibilityMetadata: String? = nil
    var showsDuration = false
    var onSelect: (@MainActor () -> Void)? = nil
    var searchOrigin = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if let onSelect { onSelect() }
                else { model.play(track, in: tracks) }
            } label: {
                HStack(spacing: 13) {
                    if let rank {
                        Text(rank.formatted()).monospacedDigit().appFont(.subheadline).foregroundStyle(secondaryTextColor)
                            .frame(minWidth: 22)
                    }
                    ArtworkView(url: track.artworkURL, title: track.title, size: 52, cornerRadius: 5)
                        .overlay(alignment: .bottomTrailing) {
                            if isCurrent {
                                Image(systemName: model.player.isPlaying ? "waveform" : "pause.fill")
                                    .font(.caption2.weight(.bold)).foregroundStyle(AppTheme.onAccent)
                                    .padding(5).background(AppTheme.accent, in: Circle()).padding(3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText).lineLimit(2)
                        HStack(spacing: 5) {
                            if model.cachedPlayableTrackIDs.contains(track.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.accent)
                                    .accessibilityHidden(true)
                            }
                            if track.isExplicit {
                                // A solid badge keeps its contrast over the brightest artwork patches.
                                Text("E").appFont(.caption2, weight: .bold).padding(.horizontal, 3)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 2))
                            }
                            // The byline truncates while the play count keeps a fixed size: a compressible count next to a
                            // truncating text can make the row's layout oscillate between two widths.
                            Text(subtitle ?? track.artistName).appFont(.caption).lineLimit(1).truncationMode(.tail)
                            if subtitle == nil, let plays = PlayCountText.plays(track.playCount) {
                                Text("·").appFont(.caption).fixedSize()
                                Text(plays).appFont(.caption).lineLimit(1).fixedSize()
                            }
                        }
                        .foregroundStyle(secondaryTextColor)
                        if dynamicTypeSize.isAccessibilitySize, let durationText {
                            // Keep the title's full column when accessibility text makes the clock wider.
                            durationLabel(durationText)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize, let durationText {
                        durationLabel(durationText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.title), \(track.artistName)")
            .accessibilityValue(accessibilityValue + (model.cachedPlayableTrackIDs.contains(track.id) ? ". Cached on this device" : ""))
            .accessibilityHint("Play song")
            .accessibilityIdentifier("track.play.\(track.id)")
            TrackActionsMenu(track: track, searchOrigin: searchOrigin)
        }
        .padding(.vertical, 6)
    }

    private var isCurrent: Bool { model.player.currentTrack?.id == track.id }

    var durationText: String? {
        guard showsDuration, let duration = track.duration, duration.isFinite,
              duration >= 1, duration < 360_000 else { return nil }
        return TimeText.duration(duration)
    }

    private func durationLabel(_ text: String) -> some View {
        Text(text)
            .appFont(.caption, design: .monospaced)
            .foregroundStyle(secondaryTextColor)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("track.duration.\(track.id)")
    }

    var accessibilityValue: String {
        var details: [String] = []
        if let rank { details.append("Rank \(rank.formatted())") }
        if track.isExplicit { details.append("Explicit") }
        if let metadata = accessibilityMetadata ?? subtitle, !metadata.isEmpty {
            details.append(metadata)
        }
        if subtitle == nil, let count = track.playCount, count > 0 {
            details.append("YouTube Music: \(count.formatted()) \(count == 1 ? "play" : "plays") worldwide")
        }
        if let durationText { details.append("Duration \(durationText)") }
        return details.joined(separator: ". ")
    }
}

@MainActor
struct TrackCard: View {
    @Environment(MusicAppModel.self) private var model
    let track: Track
    var tracks: [Track] = []
    var size: CGFloat = 160

    var body: some View {
        Button { model.play(track, in: tracks) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: track.artworkURL, title: track.title, size: size, cornerRadius: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: model.player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption.weight(.bold)).foregroundStyle(AppTheme.onAccent)
                                .padding(7).background(AppTheme.accent, in: Circle()).padding(8)
                        }
                    }
                Text(track.title).appFont(.subheadline, weight: .semibold).lineLimit(1)
                    .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText)
                Text(track.artistName).appFont(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
            }
            .frame(width: size, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title), \(track.artistName)")
        .accessibilityIdentifier("track.card.\(track.id)")
        .contextMenu { TrackActionButtons(track: track) }
    }

    private var isCurrent: Bool { model.player.currentTrack?.id == track.id }
}

@MainActor
struct CollectionCard: View {
    @Environment(\.secondaryTextColor) private var secondaryTextColor
    let collection: MusicCollection
    var size: CGFloat = 160
    /// Overrides the provider subtitle; pass "" to show the title alone.
    var caption: String? = nil

    var body: some View {
        AppNavigationLink {
            CollectionDetailView(collection: collection)
        } label: {
            VStack(alignment: collection.kind == .artist ? .center : .leading, spacing: 8) {
                ArtworkView(url: collection.artworkURL, title: collection.title, size: size,
                            cornerRadius: collection.kind == .artist ? size / 2 : 4)
                Text(collection.title).appFont(.subheadline, weight: .semibold).foregroundStyle(AppTheme.primaryText).lineLimit(1)
                if let text = caption ?? (collection.subtitle.isEmpty ? nil : collection.subtitle), !text.isEmpty {
                    Text(text).appFont(.caption).foregroundStyle(secondaryTextColor).lineLimit(1)
                }
            }
            .frame(width: size, alignment: collection.kind == .artist ? .center : .topLeading)
            .multilineTextAlignment(collection.kind == .artist ? .center : .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("collection.\(collection.id)")
    }
}

@MainActor
struct MixTile: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let collection: MusicCollection
    var caption: String
    var size: CGFloat
    var tint: Color = AppTheme.accent

    var body: some View {
        AppNavigationLink {
            CollectionDetailView(collection: collection)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkCollage(urls: collection.tracks.prefix(4).map(\.artworkURL), titles: collection.tracks.prefix(4).map(\.title), size: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            model.play(collection.tracks)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .appGlass(in: Circle(), interactive: true, tint: tint.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .accessibilityLabel("Play \(collection.title)")
                        .accessibilityIdentifier("mix.play.\(collection.id)")
                    }
                Text(collection.title)
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(caption)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            .frame(width: size, alignment: .topLeading)
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mix.\(collection.id)")
        .contextMenu {
            Button("Play", systemImage: "play.fill") { model.play(collection.tracks) }
            Button("Shuffle", systemImage: "shuffle") { model.play(collection.tracks, shuffle: true) }
        }
    }
}

/// Four artworks in a grid; fewer than four fall back to the placeholder so the tile is always full.
struct ArtworkCollage: View {
    var urls: [URL?]
    var titles: [String]
    var size: CGFloat

    var body: some View {
        let cell = size / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) { tile(0, cell); tile(1, cell) }
            HStack(spacing: 0) { tile(2, cell); tile(3, cell) }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ index: Int, _ cell: CGFloat) -> some View {
        ArtworkView(url: urls.indices.contains(index) ? urls[index] : nil,
                    title: titles.indices.contains(index) ? titles[index] : "\(index)", size: cell, cornerRadius: 0)
    }
}

@MainActor
struct TrackActionsMenu: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.secondaryTextColor) private var secondaryTextColor
    let track: Track
    var searchOrigin = false
    @State private var isNamingPlaylist = false
    @State private var playlistName = ""

    var body: some View {
        Menu {
            TrackActionButtons(track: track, searchOrigin: searchOrigin)
            Button("New playlist with this song", systemImage: "plus.rectangle.on.rectangle") {
                AppNavigationIntent.perform(in: model) {
                    playlistName = ""
                    isNamingPlaylist = true
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold))
                .foregroundStyle(secondaryTextColor).frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More options for \(track.title)")
        .accessibilityIdentifier("track.options.\(track.id)")
        .alert("New playlist", isPresented: AppNavigationIntent.binding($isNamingPlaylist, in: model)) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let id = model.library.createPlaylist(name: playlistName, tracks: [track])
                if model.library.playlists.contains(where: { $0.id == id }) {
                    model.showToast(model.library.errorMessage ?? "Added to \(playlistName)")
                }
            }
            .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

@MainActor
private struct TrackActionButtons: View {
    @Environment(MusicAppModel.self) private var model
    let track: Track
    var searchOrigin = false
    var body: some View {
        Button(model.library.isFavorite(track) ? "Remove from liked songs" : "Like song",
               systemImage: model.library.isFavorite(track) ? "heart.slash" : "heart") {
            model.library.toggleFavorite(track)
        }
        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            model.player.enqueue(track, next: true)
            model.showToast("Playing next: \(track.title)")
        }
        Button("Add to queue", systemImage: "text.badge.plus") {
            model.player.enqueue(track)
            model.showToast("Added to queue")
        }
        if !model.library.playlists.isEmpty {
            Menu("Add to playlist", systemImage: "music.note.list") {
                ForEach(model.library.playlists) { playlist in
                    Button(playlist.name) {
                        model.library.add(track, to: playlist.id)
                        model.showToast(model.library.errorMessage ?? "Added to \(playlist.name)")
                    }
                }
            }
        }
        if let album = track.albumCollection {
            Button("Go to album", systemImage: "square.stack") {
                if searchOrigin { model.activateSearchSelection(.collection(album), source: .resultMenu) }
                else { model.open(album) }
            }
        }
        let credits = track.allCredits
        if credits.count > 1 {
            Menu("Go to artist", systemImage: "person.crop.circle") {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                    Button(credit.name) {
                        AppNavigationIntent.perform(in: model) {
                            Task { await model.openArtist(credit, searchSource: searchOrigin ? .resultMenu : nil) }
                        }
                    }
                }
            }
        } else if let credit = credits.first {
            Button("Go to artist", systemImage: "person.crop.circle") {
                AppNavigationIntent.perform(in: model) {
                    Task { await model.openArtist(credit, searchSource: searchOrigin ? .resultMenu : nil) }
                }
            }
        }
        if !model.library.isFavorite(track) || track.shareURL != nil {
            Divider()
        }
        if !model.library.isFavorite(track) {
            Button(model.library.isDisliked(track) ? "Remove dislike" : "Dislike song",
                   systemImage: model.library.isDisliked(track) ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                model.toggleDislike(track)
            }
        }
        if let url = track.shareURL {
            ShareLink(item: url) { Label("Share song", systemImage: "square.and.arrow.up") }
                .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
        }
    }
}
