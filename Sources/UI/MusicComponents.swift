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
                                    .nowPlayingMotion(isPlaying: model.player.isPlaying)
                                    .font(.caption2.weight(.bold)).foregroundStyle(AppTheme.onAccent)
                                    .padding(5).background(AppTheme.accent, in: Circle()).padding(3)
                            }
                        }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText).lineLimit(2)
                        HStack(spacing: 5) {
                            if model.cachedPlayableTrackIDs.contains(track.id), !isDownloaded {
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
                            if showsSourceBadge {
                                // Rows with a custom byline (Recap, Recently played) are already dense; the badge waits for room.
                                Text(track.source.title).appFont(.caption2, weight: .semibold).lineLimit(1).fixedSize()
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 3))
                                    .accessibilityHidden(true)
                                    .accessibilityIdentifier("track.source.\(track.id)")
                            }
                        }
                        .foregroundStyle(secondaryTextColor)
                        if dynamicTypeSize.isAccessibilitySize, showsTrailingDetails {
                            // Keep the title's full column when accessibility text makes the clock wider.
                            trailingDetails
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize, showsTrailingDetails {
                        trailingDetails
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(track.title), \(track.artistName)")
            .accessibilityValue(accessibilityValue + stateDescription)
            .accessibilityHint("Play song")
            .accessibilityIdentifier("track.play.\(track.id)")
            TrackActionsMenu(track: track, searchOrigin: searchOrigin)
        }
        .padding(.vertical, 6)
    }

    private var isCurrent: Bool { model.player.currentTrack?.id == track.id }
    private var isDownloaded: Bool { model.isDownloaded(track) }
    private var isSuperLiked: Bool { model.library.isSuperLiked(track) }
    private var showsTrailingDetails: Bool { durationText != nil || isDownloaded || isSuperLiked }

    /// "JioSaavn" or "Gaana" after the byline; YouTube Music rows stay unmarked, and accessibility sizes keep the room.
    private var showsSourceBadge: Bool {
        track.source != .youTubeMusic && subtitle == nil && !dynamicTypeSize.isAccessibilitySize
    }

    private var stateDescription: String {
        Self.stateDescription(isSuperLiked: isSuperLiked, isDownloaded: isDownloaded,
                              isCached: model.cachedPlayableTrackIDs.contains(track.id))
    }

    /// VoiceOver's trailing state after the value: the tier, then the local copy, as separate sentences.
    static func stateDescription(isSuperLiked: Bool, isDownloaded: Bool, isCached: Bool) -> String {
        var text = isSuperLiked ? ". Super liked" : ""
        if isDownloaded { text += ". Downloaded" }
        else if isCached { text += ". Cached on this device" }
        return text
    }

    var durationText: String? {
        guard showsDuration, let duration = track.duration, duration.isFinite,
              duration >= 1, duration < 360_000 else { return nil }
        return TimeText.duration(duration)
    }

    /// Duration first, then the small tier and downloaded glyphs, so the clock column keeps its alignment across rows.
    private var trailingDetails: some View {
        HStack(spacing: 5) {
            if let durationText { durationLabel(durationText) }
            if isSuperLiked {
                Image(systemName: "bolt.heart.fill")
                    .appFont(.caption2, weight: .semibold)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("track.superLiked.\(track.id)")
            }
            if isDownloaded {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("track.downloaded.\(track.id)")
            }
        }
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
            details.append("\(track.source.title): \(count.formatted()) \(count == 1 ? "play" : "plays") worldwide")
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

    @State private var exportingTrack: Track?

    var body: some View {
        Button { model.play(track, in: tracks) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkView(url: track.artworkURL, title: track.title, size: size, cornerRadius: 4)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: model.player.isPlaying ? "waveform" : "pause.fill")
                                .nowPlayingMotion(isPlaying: model.player.isPlaying)
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
        .contextMenu { TrackActionButtons(track: track, onExport: { exportingTrack = track }) }
        .sheet(item: AppNavigationIntent.binding($exportingTrack, in: model, identity: { $0?.id })) { track in
            AudioExportSheet(track: track).appPresentationEnvironment(model)
        }
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
    /// Lines for the title and caption; carousels keep one so every tile lines up.
    var textLines = 1
    /// In a grid row, stretch to the tallest neighbour so cards share one height.
    var fillsRowHeight = false

    var body: some View {
        AppNavigationLink {
            CollectionDetailView(collection: collection)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkCollage(urls: collection.tracks.prefix(4).map(\.artworkURL), titles: collection.tracks.prefix(4).map(\.title), size: size)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(collection.title)
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? textLines + 1 : textLines)
                Text(caption)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? textLines + 1 : textLines)
            }
            .frame(width: size, alignment: .topLeading)
            .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
            .multilineTextAlignment(.leading)
            // The stretched frame is the link's hit area too, so a short card is as tall to the touch as its neighbour.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .accessibilityIdentifier("mix.\(collection.id)")
        .overlay(alignment: .topTrailing) {
            Button { model.play(collection.tracks) } label: {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .appGlass(in: Circle(), interactive: true, tint: tint.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Play \(collection.title)")
            .accessibilityIdentifier("mix.play.\(collection.id)")
            .padding(10)
        }
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
    @State private var exportingTrack: Track?
    @State private var shareCardTrack: Track?

    var body: some View {
        Menu {
            TrackActionButtons(track: track, searchOrigin: searchOrigin, onExport: { exportingTrack = track },
                               onShareCard: { AppNavigationIntent.perform(in: model) { shareCardTrack = track } })
            Button("New Playlist with This Song", systemImage: "plus.rectangle.on.rectangle") {
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
        .alert("New Playlist", isPresented: AppNavigationIntent.binding($isNamingPlaylist, in: model)) {
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
        .sheet(item: AppNavigationIntent.binding($exportingTrack, in: model, identity: { $0?.id })) { track in
            AudioExportSheet(track: track).appPresentationEnvironment(model)
        }
        .sheet(item: AppNavigationIntent.binding($shareCardTrack, in: model, identity: { $0?.id })) { track in
            SongShareCardSheet(track: track).appPresentationEnvironment(model)
        }
    }
}

@MainActor
private struct TrackActionButtons: View {
    @Environment(MusicAppModel.self) private var model
    let track: Track
    var searchOrigin = false
    var onExport: (() -> Void)? = nil
    var onShareCard: (() -> Void)? = nil
    var body: some View {
        Button(model.library.isFavorite(track) ? "Remove from Liked Songs" : "Like Song",
               systemImage: model.library.isFavorite(track) ? "heart.slash" : "heart") {
            model.toggleLike(track, surface: .menu)
        }
        if model.library.isSuperLiked(track) {
            Button("Change to Like", systemImage: "heart.fill") {
                model.toggleSuperLike(track, surface: .menu)
            }
        } else {
            Button("Super Like", systemImage: "bolt.heart.fill") {
                model.toggleSuperLike(track, surface: .menu)
            }
        }
        Button(model.isOffline ? "Start Radio (Requires Internet)" : "Start Radio",
               systemImage: "dot.radiowaves.left.and.right") {
            guard !model.isOffline else { return }
            AppNavigationIntent.perform(in: model) { model.startRadio(seed: .song(track)) }
        }
        .disabled(model.isOffline)
        .accessibilityIdentifier("track.radio.\(track.id)")
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
            model.player.enqueue(track, next: true)
            model.showToast("Playing next: \(track.title)")
        }
        Button("Add to Queue", systemImage: "text.badge.plus") {
            model.player.enqueue(track)
            model.showToast("Added to queue")
        }
        if !model.library.playlists.isEmpty {
            Menu("Add to Playlist", systemImage: "music.note.list") {
                ForEach(model.library.playlists) { playlist in
                    Button(playlist.name) {
                        model.library.add(track, to: playlist.id)
                        model.showToast(model.library.errorMessage ?? "Added to \(playlist.name)")
                    }
                }
            }
        }
        if model.downloads.isAvailable {
            downloadButtons
        }
        if let album = track.albumCollection {
            Button("Go to Album", systemImage: "square.stack") {
                if searchOrigin { model.activateSearchSelection(.collection(album), source: .resultMenu) }
                else { model.open(album) }
            }
        }
        let credits = track.allCredits
        if credits.count > 1 {
            Menu("Go to Artist", systemImage: "person.crop.circle") {
                ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                    Button(credit.name) {
                        AppNavigationIntent.perform(in: model) {
                            Task { await model.openArtist(credit, searchSource: searchOrigin ? .resultMenu : nil) }
                        }
                    }
                }
            }
        } else if let credit = credits.first {
            Button("Go to Artist", systemImage: "person.crop.circle") {
                AppNavigationIntent.perform(in: model) {
                    Task { await model.openArtist(credit, searchSource: searchOrigin ? .resultMenu : nil) }
                }
            }
        }
        if !model.library.isFavorite(track) || track.shareURL != nil {
            Divider()
        }
        if !model.library.isFavorite(track) {
            Button(model.library.isDisliked(track) ? "Allow Recommendations" : "Don't Recommend This Song",
                   systemImage: model.library.isDisliked(track) ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                model.toggleDislike(track)
            }
            .accessibilityHint(model.library.isDisliked(track)
                               ? "Lets this song back into mixes and radio." : "Keeps this song out of mixes and radio.")
        }
        if let onShareCard {
            Button("Share Song", systemImage: "square.and.arrow.up", action: onShareCard)
                .accessibilityIdentifier("track.share.\(track.id)")
        } else if let url = track.shareURL {
            ShareLink(item: url, preview: SharePreview(track.title)) { Label("Share Song Link", systemImage: "square.and.arrow.up") }
                .buttonStyle(AppNavigationIntentButtonStyle(.automatic))
                .accessibilityIdentifier("track.share.\(track.id)")
        }
    }

    @ViewBuilder
    private var downloadButtons: some View {
        if model.isDownloaded(track) {
            Button("Remove Download", systemImage: "arrow.down.circle.dashed") {
                Task { await model.removeDownload(track) }
            }
            .accessibilityIdentifier("track.removeDownload.\(track.id)")
        } else if model.downloads.isQueued(track.id) {
            Button("Cancel Download", systemImage: "xmark.circle") {
                model.downloads.cancel(track.id)
            }
            .accessibilityIdentifier("track.cancelDownload.\(track.id)")
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                model.download(track)
            }
            .accessibilityIdentifier("track.download.\(track.id)")
        }
        if let onExport {
            // Export needs the complete file; the disabled row says how to get one instead of hiding the feature.
            Button(model.hasLocalCopy(track) ? "Export Audio" : "Download to Export", systemImage: "square.and.arrow.up.on.square") {
                AppNavigationIntent.perform(in: model) { onExport() }
            }
            .disabled(!model.hasLocalCopy(track))
            .accessibilityIdentifier("track.export.\(track.id)")
        }
    }
}

/// Export presented from a song menu: a content-sized sheet around the shared export view.
@MainActor
struct AudioExportSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track

    var body: some View {
        NavigationStack {
            AudioExportView(track: track)
                .background(AppTheme.background)
                .navigationTitle("Export Audio")
                .navigationBarTitleDisplayMode(.inline)
                .appSheetDoneButton(id: "export.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .appSheetChrome()
        .accessibilityIdentifier("export.sheet")
    }
}
