import OSLog
import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playlistEditor: LibraryPlaylistEditorRequest?
    @State private var deletingPlaylist: UserPlaylist?
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Library")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain stack: after a programmatic jump the lazy one stopped short and then hung the main thread
                // while scrolling back up (iPhone SE, R14). Playlist rows are light enough to lay out eagerly.
                VStack(alignment: .leading, spacing: 28) {
                    header
                    LibraryStoreNotices()
                    entries
                    playlists
                    if !model.library.followedArtists.isEmpty {
                        following
                            .id(LibraryScrollTarget.following.anchorID)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            }
            .task(id: model.libraryScrollTarget) {
                guard let target = model.libraryScrollTarget else { return }
                // Lets the tab switch and root reset lay out before the jump.
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, model.libraryScrollTarget == target else { return }
                let hasAnchor = !model.library.followedArtists.isEmpty
                if hasAnchor {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target.anchorID, anchor: .top)
                    }
                }
                Self.log.debug("event=library_scroll target=following outcome=\(hasAnchor ? "landed" : "no_anchor", privacy: .public)")
                model.libraryScrollTarget = nil
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("library.screen")
        .navigationDestination(isPresented: cachedSongsDestination) {
            CachedSongsView().id(model.libraryRootGeneration).miniPlayerClearanceProbe()
        }
        .navigationDestination(isPresented: onThisDeviceDestination) {
            OnThisDeviceView().id(model.libraryRootGeneration).miniPlayerClearanceProbe()
        }
        // The row's count and bytes follow listening since the last visit; the read is a local inventory pass.
        .task { await model.refreshCachedSongs() }
        .sheet(item: AppNavigationIntent.binding($playlistEditor, in: model, identity: { $0?.id })) { request in
            LibraryPlaylistNameEditor(request: request).appPresentationEnvironment(model)
        }
        .alert("Delete Playlist?", isPresented: isDeletingPlaylist, presenting: deletingPlaylist) { playlist in
            Button("Delete Playlist", role: .destructive) {
                model.library.deletePlaylist(id: playlist.id)
                if !model.library.playlists.contains(where: { $0.id == playlist.id }) {
                    model.showToast("Playlist deleted.")
                }
            }
            .accessibilityIdentifier("library.playlist.confirmDelete")
            Button("Cancel", role: .cancel) { }
        } message: { playlist in
            Text("“\(playlist.name)” will be removed from your library. The songs remain available to listen to.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Your Library")
                .appFont(.largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

        }
    }

    /// Compact listening entries keep playlists on the first screen; cache management lives in Settings > Storage.
    private var entries: some View {
        VStack(spacing: 0) {
            AppNavigationLink {
                LibrarySavedSongsView(kind: .likes)
            } label: {
                LibraryEntryRow(title: "Liked Songs", systemImage: "heart.fill",
                                value: model.library.favorites.isEmpty ? "" : model.library.favorites.count.formatted())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Liked Songs")
            .accessibilityValue(likedSongsCaption)
            .accessibilityIdentifier("library.likes")

            if model.downloads.isAvailable {
                LibraryEntryDivider()
                let caption = downloadsCaption(count: model.downloadedTrackIDs.count, pending: model.downloads.pendingItems.count)
                AppNavigationLink {
                    DownloadsView()
                } label: {
                    LibraryEntryRow(title: "Downloads", systemImage: "arrow.down.circle.fill", value: downloadsValue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Downloads")
                .accessibilityValue(caption)
                .accessibilityIdentifier("library.downloads")
            }

        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.compact))
        .clipShape(RoundedRectangle(cornerRadius: AppCorner.compact))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.entries")
    }

    private var likedSongsCaption: String {
        model.library.favorites.isEmpty ? "Keep a little of what you love." : librarySongCount(model.library.favorites.count)
    }

    /// Short trailing text; the full sentence stays in the accessibility value.
    private var downloadsValue: String {
        let count = model.downloadedTrackIDs.count
        let pending = model.downloads.pendingItems.count
        if pending > 0 { return count == 0 ? "\(pending.formatted()) in progress" : "\(count.formatted()) · \(pending.formatted()) in progress" }
        return count == 0 ? "" : count.formatted()
    }

    private func downloadsCaption(count: Int, pending: Int) -> String {
        if count == 0, pending == 0 { return "Keep music on this device." }
        var text = count == 0 ? "" : "\(librarySongCount(count)) on this device"
        if pending > 0 { text += text.isEmpty ? "\(pending.formatted()) in progress" : " · \(pending.formatted()) in progress" }
        return text
    }

    /// Hidden only once the provider has answered that it keeps no browsable inventory.
    private var showsCachedSongsCard: Bool {
        !model.hasLoadedCachedSongs || model.cachedSongsUsage != nil || !model.cachedSongs.isEmpty || model.cachedSongsError != nil
    }

    private var cachedSongsValue: String {
        if model.cachedSongsError != nil { return "Try again" }
        guard model.hasLoadedCachedSongs || model.cachedSongsUsage != nil || !model.cachedSongs.isEmpty else { return "" }
        let songs = model.temporaryCachedSongs
        guard !songs.isEmpty else { return "" }
        return ByteCountFormatter.string(fromByteCount: max(0, songs.reduce(Int64(0)) { $0 + max(0, $1.bytes) }), countStyle: .binary)
    }

    private var cachedSongsCaption: String {
        if model.cachedSongsError != nil { return "Couldn’t check this device. Open to try again." }
        guard model.hasLoadedCachedSongs || model.cachedSongsUsage != nil || !model.cachedSongs.isEmpty else { return "Checking this device…" }
        let songs = model.temporaryCachedSongs
        guard !songs.isEmpty else { return "Songs you play are cached on this device." }
        let bytes = ByteCountFormatter.string(fromByteCount: max(0, songs.reduce(Int64(0)) { $0 + max(0, $1.bytes) }),
                                              countStyle: .binary)
        return "\(librarySongCount(songs.count)) · \(bytes) on this device"
    }

    private var cachedSongsDestination: Binding<Bool> {
        AppNavigationIntent.binding(Binding(get: { model.showsLibraryCachedSongs }, set: { model.showsLibraryCachedSongs = $0 }),
                                    in: model, isCurrent: { model.selectedTab == .library })
    }

    private var onThisDeviceDestination: Binding<Bool> {
        AppNavigationIntent.binding(Binding(get: { model.showsLibraryOnThisDevice }, set: { model.showsLibraryOnThisDevice = $0 }),
                                    in: model, isCurrent: { model.selectedTab == .library })
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SectionHeader(title: "Playlists")
                Button {
                    AppNavigationIntent.perform(in: model) { playlistEditor = LibraryPlaylistEditorRequest() }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(AppTheme.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create Playlist")
                .accessibilityIdentifier("library.createPlaylist")
            }
            if model.library.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "music.note.list")
                            .appFont(.title3)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 44, height: 44)
                            .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A Place for Your Next Mix").appFont(.headline, weight: .semibold)
                            Text("Start a playlist, then add songs from your library or search.")
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        AppNavigationIntent.perform(in: model) { playlistEditor = LibraryPlaylistEditorRequest() }
                    } label: {
                        Label("Create a Playlist", systemImage: "plus")
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppTheme.onAccent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("library.playlists.createFirst")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.playlists.empty")
            } else {
                ForEach(model.library.playlists) { playlist in
                    HStack(spacing: 0) {
                        AppNavigationLink {
                            LibraryUserPlaylistView(playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 14) {
                                ArtworkView(url: playlist.tracks.first?.artworkURL, title: playlist.name, size: 64, cornerRadius: 6)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.name)
                                        .appFont(.headline, weight: .semibold)
                                        .foregroundStyle(AppTheme.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(librarySongCount(playlist.tracks.count))
                                        .appFont(.subheadline)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library.playlist.\(playlist.id.uuidString)")

                        Menu {
                            Button("Play", systemImage: "play.fill") { model.play(playlist.tracks) }
                                .disabled(playlist.tracks.isEmpty)
                                .accessibilityIdentifier("library.playlist.play.\(playlist.id.uuidString)")
                            Button("Shuffle", systemImage: "shuffle") { model.play(playlist.tracks, shuffle: true) }
                                .disabled(playlist.tracks.isEmpty)
                                .accessibilityIdentifier("library.playlist.shuffle.\(playlist.id.uuidString)")
                            Button("Rename", systemImage: "pencil") {
                                AppNavigationIntent.perform(in: model) { playlistEditor = LibraryPlaylistEditorRequest(playlist: playlist) }
                            }
                            .accessibilityIdentifier("library.playlist.rename.\(playlist.id.uuidString)")
                            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                AppNavigationIntent.perform(in: model) { deletingPlaylist = playlist }
                            }
                            .accessibilityIdentifier("library.playlist.delete.\(playlist.id.uuidString)")
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.headline)
                                .frame(width: 52, height: 52)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Actions for \(playlist.name)")
                        .accessibilityIdentifier("library.playlist.menu.\(playlist.id.uuidString)")
                    }
                }
            }
        }
    }

    private var following: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Following")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.library.followedArtists) { artist in
                        AppNavigationLink {
                            CollectionDetailView(collection: MusicCollection(id: artist.id, title: artist.name,
                                                                             artworkURL: artist.artworkURL, kind: .artist))
                        } label: {
                            VStack(spacing: 8) {
                                ArtworkView(url: artist.artworkURL, title: artist.name, size: 72, cornerRadius: 36)
                                Text(artist.name)
                                    .appFont(.caption)
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: 88, alignment: .top)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(artist.name)
                        .accessibilityIdentifier("library.following.\(artist.id)")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LibraryScrollTarget.following.anchorID)
    }

    private var isDeletingPlaylist: Binding<Bool> {
        AppNavigationIntent.binding(Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }), in: model)
    }
}

enum LibraryScrollTarget: Hashable, Sendable {
    case following

    var anchorID: String {
        switch self {
        case .following: "library.following"
        }
    }
}

/// Compact Library entry: a 28-point tile, the title, a short trailing value and a chevron, at least 44 points tall.
@MainActor
private struct LibraryEntryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: SettingsRowMetrics.iconSpacing) {
            SettingsRowIcon(systemImage: systemImage)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            layout {
                Text(title)
                    .appFont(.body)
                    .foregroundStyle(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
                if !value.isEmpty {
                    Text(value)
                        .appFont(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .appFont(.footnote, weight: .semibold)
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: SettingsRowMetrics.minHeight)
        .contentShape(Rectangle())
    }
}

private struct LibraryEntryDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.primaryText.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 16 + SettingsRowMetrics.textInset)
            .accessibilityHidden(true)
    }
}

@MainActor
struct LibraryStoreNotices: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        if let error = model.library.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your library needs attention", systemImage: "exclamationmark.triangle")
                    .appFont(.headline, weight: .semibold)
                Text(error)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(AppTheme.gold.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.error")
        }
        if !model.library.preferences.saveListeningHistory {
            VStack(alignment: .leading, spacing: 10) {
                Label("Listening history is paused", systemImage: "pause.circle")
                    .appFont(.headline, weight: .semibold)
                Text("New listening won’t be saved. Your earlier history is still here.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                Button {
                    model.updatePreferences { $0.saveListeningHistory = true }
                } label: {
                    Text("Turn On Listening History")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("library.history.enable")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

@MainActor
struct LibraryQueueButtons: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tracks: [Track]
    let title: String
    let identifier: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button {
                model.play(tracks)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AppTheme.onAccent)
                    .background(AppTheme.accent, in: Capsule())
            }
            .accessibilityLabel("Play \(title)")
            .accessibilityIdentifier("\(identifier).play")
            Button {
                model.play(tracks, shuffle: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AppTheme.primaryText)
                    .background(AppTheme.raised, in: Capsule())
            }
            .accessibilityLabel("Shuffle \(title)")
            .accessibilityIdentifier("\(identifier).shuffle")
        }
        .appFont(.subheadline, weight: .semibold)
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.45 : 1)
    }
}

@MainActor
struct LibraryRecentSongRow: View {
    @Environment(MusicAppModel.self) private var model
    let recent: RecentListen
    let tracks: [Track]
    /// "library" for the Recently played page, "recap" for Recap's Recently played section.
    var identifierPrefix = "library"

    var body: some View {
        let lastPlayed = recent.playedAt.formatted(.relative(presentation: .named))
        VStack(alignment: .leading, spacing: 0) {
            TrackRow(track: recent.track, tracks: tracks,
                     subtitle: "\(recent.track.artistName) · \(lastPlayed)",
                     accessibilityMetadata: "Last played \(lastPlayed)")
            if recent.position >= 1 {
                Button {
                    let position = recent.position
                    if model.play(recent.track, in: tracks) { model.player.seek(to: position) }
                } label: {
                    Label("Resume at \(TimeText.duration(recent.position))", systemImage: "play.circle")
                        .appFont(.caption, weight: .semibold)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .padding(.leading, 8)
                .accessibilityLabel("Resume \(recent.track.title) at \(TimeText.duration(recent.position))")
                .accessibilityIdentifier("\(identifierPrefix).resume.\(recent.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifierPrefix).recent.\(recent.id)")
    }
}

@MainActor
private struct LibraryTrackSearchButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "magnifyingglass")
                .appFont(.body, weight: .semibold)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search \(title)")
        .accessibilityIdentifier("\(identifier).search")
        .keyboardShortcut("f", modifiers: .command)
    }
}

@MainActor
private struct LibraryTrackSearchField: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var query: String
    let title: String
    let identifier: String
    let cancel: () -> Void
    @FocusState private var isFocused: Bool
    @State private var didRequestFocus = false

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
                TextField("Title, artist, or album", text: $query)
                    .appFont(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isFocused)
                    .onSubmit { isFocused = false }
                    .frame(minWidth: 44, minHeight: 48)
                    // Native editors keep text-line bounds; the surrounding padding must also focus the field.
                    .contentShape([.interaction, .accessibility], Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { isFocused = true })
                    .accessibilityLabel("Search \(title)")
                    .accessibilityIdentifier("\(identifier).search.field")
                if !query.isEmpty {
                    Button {
                        query = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(minWidth: 44, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                    .accessibilityIdentifier("\(identifier).search.clear")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, query.isEmpty ? 12 : 0)
            .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: AppCorner.compact))

            Button {
                isFocused = false
                cancel()
            } label: {
                Text("Cancel")
                    .appFont(.body)
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Search")
            .accessibilityIdentifier("\(identifier).search.cancel")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .task {
            guard !didRequestFocus else { return }
            didRequestFocus = true
            let dismissal = model.searchFocusDismissal
            let presentingTab = model.selectedTab
            await Task.yield()
            guard !Task.isCancelled, dismissal == model.searchFocusDismissal,
                  model.selectedTab == presentingTab, !model.isPlayerPresented, !model.isSettingsPresented else { return }
            isFocused = true
        }
        .onChange(of: model.searchFocusDismissal) { _, _ in isFocused = false }
        .onChange(of: model.selectedTab) { _, _ in isFocused = false }
        .onChange(of: model.isPlayerPresented) { _, presented in if presented { isFocused = false } }
        .onDisappear { isFocused = false }
    }
}

private struct LibraryTrackSearchEmptyResults: View {
    let identifier: String

    var body: some View {
        EmptyStateView(symbol: "magnifyingglass", title: "No Matching Songs",
                       message: "Try another title, artist, or album.")
            .accessibilityIdentifier("\(identifier).search.empty")
    }
}

protocol LibraryFilterOption: Hashable {
    var title: String { get }
    /// Identifier suffix, such as "all" in `library.likes.filter.all`.
    var key: String { get }
}

enum LikedSongsFilter: String, CaseIterable, LibraryFilterOption {
    case all, superLiked, downloaded, onDevice

    var key: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .superLiked: "Super Liked"
        case .downloaded: "Downloaded"
        case .onDevice: "On This Device"
        }
    }

    var queueTitle: String {
        switch self {
        case .all: "liked songs"
        case .superLiked: "super liked songs"
        case .downloaded: "downloaded liked songs"
        case .onDevice: "liked songs on this device"
        }
    }

    var symbol: String {
        switch self {
        case .all, .onDevice: "internaldrive"
        case .superLiked: "bolt.heart.fill"
        case .downloaded: "arrow.down.circle"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all, .onDevice: "No Likes on This Device"
        case .superLiked: "No Super Likes Yet"
        case .downloaded: "No Downloaded Likes"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all, .onDevice: "Download liked songs, or play them while connected so they are cached on this device."
        case .superLiked: "Hold the heart on a song you love, or choose Super Like from its menu."
        case .downloaded: "Download liked songs to keep them on this device."
        }
    }

    /// On this device counts a download or a complete cached copy, the two copies that play without a connection.
    @MainActor func includes(_ track: Track, in model: MusicAppModel) -> Bool {
        switch self {
        case .all: true
        case .superLiked: model.library.isSuperLiked(track)
        case .downloaded: model.isDownloaded(track)
        case .onDevice: model.hasLocalCopy(track)
        }
    }
}

/// Single-select capsule chips; each chip keeps a 44-point target while drawing a 34-point capsule.
@MainActor
struct LibraryFilterChips<Option: LibraryFilterOption>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let options: [Option]
    @Binding var selection: Option
    let identifier: String

    var body: some View {
        // Chips that no longer fit one row wrap to the next instead of truncating or stacking one per row.
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { chips }
            } else {
                ChipFlowLayout(horizontalSpacing: 8) { chips }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The capsule fill follows the selection in under a fifth of a second; layout never animates.
        .animation(reduceMotion ? nil : .snappy(duration: 0.18, extraBounce: 0), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var chips: some View {
        ForEach(options, id: \.self) { option in
            let isSelected = option == selection
            Button {
                selection = option
            } label: {
                Text(option.title)
                    .appFont(.subheadline, weight: .semibold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .foregroundStyle(isSelected ? AppTheme.onAccent : AppTheme.primaryText)
                    .background(isSelected ? AppTheme.accent : AppTheme.raised, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).\(option.key)")
        }
    }
}

@MainActor
struct LibrarySavedSongsView: View {
    enum Kind: Hashable { case likes, recents }
    @Environment(MusicAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let kind: Kind
    @State private var query = ""
    @State private var isSearching = false
    @State private var filter: LikedSongsFilter

    /// `initialFilter` preselects a Likes chip for callers such as Home's Super Liked shelf; Recently Played ignores it.
    init(kind: Kind, initialFilter: LikedSongsFilter? = nil) {
        self.kind = kind
        _filter = State(initialValue: kind == .likes ? (initialFilter ?? .all) : .all)
    }

    private var title: String { kind == .likes ? "Liked Songs" : "Recently Played" }
    private var tracks: [Track] { kind == .likes ? model.library.favorites : model.library.recentlyPlayed.map(\.track) }
    private var identifier: String { kind == .likes ? "library.likes" : "library.recents" }
    private var showsFilters: Bool { kind == .likes && !model.library.favorites.isEmpty }
    /// All Liked downloads every like, so Downloaded and On This Device would repeat All; Super Liked stays a real subset.
    private var filters: [LikedSongsFilter] {
        if model.library.preferences.autoDownloadScope == .liked { return [.all, .superLiked] }
        return model.downloads.isAvailable ? LikedSongsFilter.allCases : [.all, .superLiked, .onDevice]
    }

    var body: some View {
        let sourceTracks = tracks
        let search = LibraryTrackSearch(tracks: sourceTracks, query: query)
        let activeFilter = showsFilters && filters.contains(filter) ? filter : .all
        let selection = (tracks: search.tracks.filter { activeFilter.includes($0, in: model) },
                         isFiltering: search.isFiltering || activeFilter != .all)
        ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        if !isSearching {
                            Image(systemName: kind == .likes ? "heart.fill" : "clock.arrow.circlepath")
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 100, height: 100)
                                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityHidden(true)
                            Text(title)
                                .appFont(.largeTitle, weight: .bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        Text(selection.isFiltering && !sourceTracks.isEmpty
                             ? "\(selection.tracks.count.formatted()) of \(librarySongCount(sourceTracks.count))"
                             : librarySongCount(sourceTracks.count))
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("\(identifier).count")
                        if kind == .likes, model.downloads.isAvailable {
                            VStack(alignment: .leading, spacing: 8) {
                                DownloadLikedSongsToggle(identifier: "library.likes.autoDownload")
                                Text(likedDownloadsStatus)
                                    .appFont(.footnote)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("library.likes.downloadStatus")
                            }
                        }
                        if showsFilters {
                            LibraryFilterChips(options: filters, selection: $filter, identifier: "library.likes.filter")
                        }
                        LibraryQueueButtons(tracks: selection.tracks,
                                            title: search.isFiltering ? "search results" : activeFilter == .all ? title : activeFilter.queueTitle,
                                            identifier: identifier)
                        LibraryStoreNotices()
                    }
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .id("\(identifier).top")
                }
                Section {
                    if sourceTracks.isEmpty {
                        EmptyStateView(
                            symbol: kind == .likes ? "heart" : "headphones",
                            title: kind == .likes ? "Save a Song You Love" : "Nothing Played Yet",
                            message: kind == .likes
                                ? "Tap the heart in a song’s menu to keep it here."
                                : "With listening history on, your recent songs and resume positions appear here."
                        )
                        .accessibilityIdentifier("\(identifier).empty")
                        Button("Find Music", systemImage: "magnifyingglass") { model.openSearch("") }
                            .appFont(.body)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("\(identifier).findMusic")
                    } else if selection.tracks.isEmpty, activeFilter != .all, !search.isFiltering {
                        EmptyStateView(symbol: activeFilter.symbol, title: activeFilter.emptyTitle, message: activeFilter.emptyMessage)
                            .accessibilityIdentifier("library.likes.filter.empty")
                    } else if selection.tracks.isEmpty {
                        LibraryTrackSearchEmptyResults(identifier: identifier)
                    } else if kind == .likes {
                        ForEach(selection.tracks) { track in
                            let isSuperLiked = model.library.isSuperLiked(track)
                            let tierAction = isSuperLiked ? "Change to Like" : "Super Like"
                            TrackRow(track: track, tracks: selection.tracks, showsDuration: kind == .likes)
                                .swipeActions(edge: .leading) {
                                    Button(tierAction, systemImage: isSuperLiked ? "heart.fill" : "bolt.heart.fill") {
                                        model.toggleSuperLike(track, surface: .library)
                                    }
                                    .tint(AppTheme.accent)
                                    .accessibilityIdentifier("library.superLike.\(track.id)")
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Unlike", systemImage: "heart.slash", role: .destructive) {
                                        model.toggleLike(track, surface: .library)
                                    }
                                    .accessibilityIdentifier("library.unlike.\(track.id)")
                                }
                                .accessibilityAction(named: tierAction) {
                                    model.toggleSuperLike(track, surface: .library)
                                }
                                .accessibilityAction(named: "Remove from Liked Songs") {
                                    model.toggleLike(track, surface: .library)
                                }
                        }
                    } else {
                        ForEach(model.library.recentlyPlayed) { recent in
                            LibraryRecentSongRow(recent: recent, tracks: sourceTracks)
                        }
                    }
                }
                .listRowBackground(AppTheme.surface)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: query) { _, _ in proxy.scrollTo("\(identifier).top", anchor: .top) }
            .onChange(of: isSearching) { _, _ in proxy.scrollTo("\(identifier).top", anchor: .top) }
        }
        .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // All Liked hides the Downloaded and On This Device chips; a hidden choice must not stay or come back selected,
        // while a preselected Super Liked chip survives because All Liked keeps it.
        .onChange(of: model.library.preferences.autoDownloadScope, initial: true) { _, scope in
            if scope == .liked, !filters.contains(filter) { filter = .all }
        }
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if kind == .likes, !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryTrackSearchButton(title: title, identifier: identifier) {
                        AppNavigationIntent.perform(in: model) { isSearching = true }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearching {
                LibraryTrackSearchField(query: $query, title: title, identifier: identifier) {
                    query = ""
                    isSearching = false
                }
            }
        }
    }

    private var likedDownloadsStatus: String {
        let likes = model.library.favorites
        let downloaded = likes.filter { model.isDownloaded($0) }.count
        let pending = likes.filter { !model.isDownloaded($0) && model.downloads.isQueued($0.id) }
        let failed = likes.filter {
            if case .failed = model.downloadState(for: $0) { return true }
            return false
        }.count
        var parts = ["\(downloaded.formatted()) of \(likes.count.formatted()) downloaded"]
        if !pending.isEmpty {
            parts.append("\(pending.count.formatted()) pending")
            if model.isOffline {
                parts.append("Waiting for a connection")
            } else if pending.contains(where: { model.downloads.state(for: $0.id) == .waitingForWiFi }) {
                parts.append("Waiting for Wi-Fi")
            } else {
                parts.append("Downloads run while Velvet Thorn is open")
            }
        }
        if failed > 0 { parts.append("\(failed.formatted()) failed; retry in Downloads") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
struct LibraryUserPlaylistView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let playlistID: UUID
    @State private var editor: LibraryPlaylistEditorRequest?
    @State private var isAddingSongs = false
    @State private var isDeleting = false
    @State private var query = ""
    @State private var isSearching = false
    @State private var editMode: EditMode = .inactive

    private var playlist: UserPlaylist? { model.library.playlists.first { $0.id == playlistID } }

    var body: some View {
        Group {
            if let playlist {
                let selection = LibraryTrackSearch(tracks: playlist.tracks, query: query)
                ScrollViewReader { proxy in
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 18) {
                                if !isSearching {
                                    ArtworkView(url: playlist.tracks.first?.artworkURL, title: playlist.name, size: 176, cornerRadius: 8)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .accessibilityHidden(true)
                                    Text(playlist.name)
                                        .appFont(.largeTitle, weight: .bold)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                Text(selection.isFiltering && !playlist.tracks.isEmpty
                                     ? "\(selection.tracks.count.formatted()) of \(librarySongCount(playlist.tracks.count))"
                                     : "\(librarySongCount(playlist.tracks.count)) · Made by you")
                                    .appFont(.subheadline)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .accessibilityIdentifier("library.playlist.count")
                                LibraryQueueButtons(tracks: selection.tracks,
                                                    title: selection.isFiltering ? "search results" : playlist.name,
                                                    identifier: "library.playlist")
                                if !isSearching {
                                    Button("Add Songs", systemImage: "plus") {
                                        AppNavigationIntent.perform(in: model) { isAddingSongs = true }
                                    }
                                    .appFont(.headline, weight: .semibold)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(AppTheme.surface, in: Capsule())
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("library.playlist.addSongs")
                                }
                                LibraryStoreNotices()
                            }
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .id("library.playlist.top")
                        }
                        if playlist.tracks.isEmpty {
                            EmptyStateView(symbol: "music.note", title: "The First Song Sets the Mood",
                                           message: "Add a few songs, then put them in an order that feels right.")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .accessibilityIdentifier("library.playlist.empty")
                        } else if selection.tracks.isEmpty {
                            LibraryTrackSearchEmptyResults(identifier: "library.playlist")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        } else {
                            Section {
                                ForEach(selection.tracks) { track in
                                    TrackRow(track: track, tracks: selection.tracks, showsDuration: true)
                                        .moveDisabled(isSearching)
                                        .accessibilityElement(children: .contain)
                                        .accessibilityIdentifier("library.playlist.track.\(track.id)")
                                         .accessibilityAction(named: "Remove from Playlist") {
                                            model.library.remove(trackID: track.id, from: playlistID)
                                        }
                                }
                                .onDelete { offsets in
                                    for id in selection.removalIDs(at: offsets) {
                                        model.library.remove(trackID: id, from: playlistID)
                                    }
                                }
                                .onMove { offsets, destination in
                                    guard !isSearching, let current = self.playlist,
                                          selection.canReorder(currentTracks: current.tracks) else { return }
                                    model.library.moveTracks(in: playlistID, from: offsets, to: destination)
                                }
                            } footer: {
                                Text(isSearching
                                     ? "Cancel search to reorder songs. Swipe to remove a song."
                                     : "Use Edit to reorder or remove songs.")
                                    .appFont(.footnote)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .listRowBackground(AppTheme.surface)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .environment(\.editMode, $editMode)
                    .onChange(of: query) { _, _ in proxy.scrollTo("library.playlist.top", anchor: .top) }
                    .onChange(of: isSearching) { _, _ in proxy.scrollTo("library.playlist.top", anchor: .top) }
                }
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            } else {
                EmptyStateView(symbol: "music.note.list", title: "Playlist Removed",
                               message: "This playlist is no longer in your library.")
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !isSearching {
                ToolbarItem(placement: .topBarTrailing) {
                    LibraryTrackSearchButton(title: playlist?.name ?? "playlist", identifier: "library.playlist") {
                        AppNavigationIntent.perform(in: model) {
                            editMode = .inactive
                            isSearching = true
                        }
                    }
                    .disabled(playlist == nil)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .appFont(.body)
                    .disabled(isSearching || playlist?.tracks.isEmpty != false)
                    .environment(\.editMode, $editMode)
                    .accessibilityIdentifier("library.playlist.edit")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        if let playlist {
                            AppNavigationIntent.perform(in: model) { editor = LibraryPlaylistEditorRequest(playlist: playlist) }
                        }
                    }
                    .accessibilityIdentifier("library.playlist.rename")
                    Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                        AppNavigationIntent.perform(in: model) { isDeleting = true }
                    }
                    .accessibilityIdentifier("library.playlist.delete")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Playlist Actions")
                .accessibilityIdentifier("library.playlist.menu")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isSearching {
                LibraryTrackSearchField(query: $query, title: playlist?.name ?? "playlist", identifier: "library.playlist") {
                    query = ""
                    isSearching = false
                }
            }
        }
        .sheet(item: AppNavigationIntent.binding($editor, in: model, identity: { $0?.id })) { request in
            LibraryPlaylistNameEditor(request: request).appPresentationEnvironment(model)
        }
        .sheet(isPresented: AppNavigationIntent.binding($isAddingSongs, in: model)) { LibraryAddSongsSheet(playlistID: playlistID).appPresentationEnvironment(model) }
        .alert("Delete Playlist?", isPresented: AppNavigationIntent.binding($isDeleting, in: model)) {
            Button("Delete Playlist", role: .destructive) {
                model.library.deletePlaylist(id: playlistID)
                if playlist == nil { AppNavigationIntent.perform(in: model) { dismiss() } }
            }
            .accessibilityIdentifier("library.playlist.confirmDelete")
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the playlist. Your liked songs and listening history are kept.")
        }
    }
}

private struct LibraryPlaylistEditorRequest: Identifiable {
    let id = UUID()
    var playlist: UserPlaylist?
}

@MainActor
private struct LibraryPlaylistNameEditor: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    let request: LibraryPlaylistEditorRequest
    @State private var name: String
    @State private var saveError: String?

    init(request: LibraryPlaylistEditorRequest) {
        self.request = request
        _name = State(initialValue: request.playlist?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist name", text: $name)
                        .appFont(.body)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit { save() }
                        .accessibilityIdentifier("library.playlist.name")
                } header: {
                    Text("Give It a Name")
                        .appFont(.footnote)
                }
                .listRowBackground(AppTheme.surface)
                if let error = saveError ?? model.library.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(AppTheme.primaryText)
                            .appFont(.subheadline)
                            .accessibilityIdentifier("library.playlist.saveError")
                    }
                    .listRowBackground(AppTheme.gold.opacity(0.12))
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .foregroundStyle(AppTheme.primaryText)
            .navigationTitle(request.playlist == nil ? "New Playlist" : "Rename Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { AppNavigationIntent.perform(in: model) { dismiss() } }
                        .appFont(.body)
                        .accessibilityIdentifier("library.playlist.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .appFont(.body, weight: .semibold)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("library.playlist.save")
                }
            }
            .task { isNameFocused = true }
        }
        .presentationDetents([.medium, .large])
        .appSheetChrome()
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        let id: UUID
        if let playlist = request.playlist {
            id = playlist.id
            model.library.renamePlaylist(id: id, name: trimmedName)
        } else {
            id = model.library.createPlaylist(name: trimmedName)
        }
        guard model.library.errorMessage == nil,
              model.library.playlists.contains(where: { $0.id == id && $0.name == trimmedName }) else {
            saveError = model.library.errorMessage ?? "The playlist couldn’t be saved. Please try again."
            return
        }
        model.showToast(request.playlist == nil ? "Playlist created." : "Playlist renamed.")
        AppNavigationIntent.perform(in: model) { dismiss() }
    }
}

@MainActor
private struct LibraryAddSongsSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var query = ""

    private var playlist: UserPlaylist? { model.library.playlists.first { $0.id == playlistID } }

    private var candidates: [Track] {
        var ids = Set<String>()
        let tracks = model.library.favorites + model.library.recentlyPlayed.map(\.track)
            + model.library.playlists.flatMap(\.tracks) + model.player.queue
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tracks.filter {
            ids.insert($0.id).inserted && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.artistName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.openSearch(query)
                        dismiss()
                    } label: {
                        Label("Search All Music", systemImage: "magnifyingglass")
                            .appFont(.headline, weight: .semibold)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("library.playlist.searchMusic")
                } footer: {
                    Text("Use a song’s menu in search to add it to this playlist.")
                        .appFont(.footnote)
                }
                .listRowBackground(AppTheme.surface)

                if candidates.isEmpty {
                    EmptyStateView(symbol: "magnifyingglass", title: "Find Your Next Song",
                                   message: "Liked songs and recent listens appear here. Search all music for something new.")
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(candidates) { track in
                            let added = playlist?.tracks.contains { $0.id == track.id } ?? false
                            Button {
                                model.library.add(track, to: playlistID)
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(url: track.artworkURL, title: track.title, size: 48)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .appFont(.headline, weight: .semibold)
                                            .foregroundStyle(AppTheme.primaryText)
                                        Text(track.artistName)
                                            .appFont(.subheadline)
                                            .foregroundStyle(AppTheme.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                        .font(.title2)
                                        .foregroundStyle(added ? AppTheme.secondaryText : AppTheme.accent)
                                        .frame(width: 44, height: 44)
                                }
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(added || playlist == nil)
                            .accessibilityLabel("\(added ? "Added" : "Add") \(track.title), \(track.artistName)")
                            .accessibilityIdentifier("library.playlist.add.\(track.id)")
                        }
                    } header: {
                        Text("From Your Library").appFont(.footnote)
                    }
                    .listRowBackground(AppTheme.surface)
                }
                if let error = model.library.errorMessage {
                    Text(error)
                        .appFont(.subheadline)
                        .listRowBackground(AppTheme.gold.opacity(0.12))
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .foregroundStyle(AppTheme.primaryText)
            .searchable(text: $query, prompt: "Filter your saved songs")
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "library.playlist.addDone") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
    }
}

private func librarySongCount(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "song" : "songs")"
}

/// Left-aligned wrapping rows for fixed-size chips; a row breaks before the chip that would overflow the width.
struct ChipFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.items.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
