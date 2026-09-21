import SwiftUI

@MainActor
struct LibraryView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playlistEditor: LibraryPlaylistEditorRequest?
    @State private var deletingPlaylist: UserPlaylist?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                header
                LibraryStoreNotices()
                likedSongs
                playlists
                if !model.library.followedArtists.isEmpty {
                    following
                }
                recentListens
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("library.screen")
        .sheet(item: AppNavigationIntent.binding($playlistEditor, in: model, identity: { $0?.id })) { request in
            LibraryPlaylistNameEditor(request: request)
        }
        .alert("Delete playlist?", isPresented: isDeletingPlaylist, presenting: deletingPlaylist) { playlist in
            Button("Delete playlist", role: .destructive) {
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
            Text("Your library")
                .appFont(.largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                AppNavigationIntent.perform(in: model) { playlistEditor = LibraryPlaylistEditorRequest() }
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .background(AppTheme.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Create playlist")
            .accessibilityIdentifier("library.createPlaylist")
        }
    }

    private var likedSongs: some View {
        AppNavigationLink {
            LibrarySavedSongsView(kind: .likes)
        } label: {
            HStack(spacing: 18) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 74, height: 86)
                        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Liked songs")
                        .appFont(.title2, weight: .bold)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(model.library.favorites.isEmpty ? "Keep a little of what you love." : librarySongCount(model.library.favorites.count))
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(20)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.likes")
    }

    private var recentListens: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionHeader(title: "Recent listens")
                Spacer(minLength: 0)
                if !model.library.recentlyPlayed.isEmpty {
                    AppNavigationLink {
                        LibrarySavedSongsView(kind: .recents)
                    } label: {
                        Text("See all")
                            .appFont(.subheadline, weight: .semibold)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("See all recent listens")
                    .accessibilityIdentifier("library.recents.all")
                }
            }

            if model.library.recentlyPlayed.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(
                        symbol: "headphones", title: "Pick up a new favorite",
                        message: model.library.preferences.saveListeningHistory
                            ? "Songs you play will appear here, along with where you left off."
                            : "Your recent songs will appear here when listening history is on."
                    )
                    Button("Find music", systemImage: "magnifyingglass") { model.openSearch("") }
                        .appFont(.body)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("library.findMusic")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.library.recentlyPlayed.prefix(3)) { recent in
                        LibraryRecentSongRow(recent: recent, tracks: model.library.recentlyPlayed.map(\.track))
                    }
                }
            }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Playlists")
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
                            Text("A place for your next mix").appFont(.headline, weight: .semibold)
                            Text("Start a playlist, then add songs from your library or search.")
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button {
                        AppNavigationIntent.perform(in: model) { playlistEditor = LibraryPlaylistEditorRequest() }
                    } label: {
                        Label("Create a playlist", systemImage: "plus")
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
                            Button("Delete playlist", systemImage: "trash", role: .destructive) {
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
    }

    private var isDeletingPlaylist: Binding<Bool> {
        AppNavigationIntent.binding(Binding(get: { deletingPlaylist != nil }, set: { if !$0 { deletingPlaylist = nil } }), in: model)
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
                Button("Turn on listening history") {
                    model.player.flushListeningProgress()
                    model.library.preferences.saveListeningHistory = true
                }
                .appFont(.subheadline, weight: .semibold)
                .frame(minHeight: 44)
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
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(AppTheme.onAccent)
                    .background(AppTheme.accent, in: Capsule())
            }
            .accessibilityLabel("Play \(title)")
            .accessibilityIdentifier("\(identifier).play")
            Button {
                model.play(tracks, shuffle: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(AppTheme.primaryText)
                    .background(AppTheme.raised, in: Capsule())
            }
            .accessibilityLabel("Shuffle \(title)")
            .accessibilityIdentifier("\(identifier).shuffle")
        }
        .appFont(.headline, weight: .semibold)
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.45 : 1)
    }
}

@MainActor
private struct LibraryRecentSongRow: View {
    @Environment(MusicAppModel.self) private var model
    let recent: RecentListen
    let tracks: [Track]

    var body: some View {
        let lastPlayed = recent.playedAt.formatted(.relative(presentation: .named))
        VStack(alignment: .leading, spacing: 0) {
            TrackRow(track: recent.track, tracks: tracks,
                     subtitle: "\(recent.track.artistName) · \(lastPlayed)",
                     accessibilityMetadata: "Last played \(lastPlayed)")
            if recent.position >= 1 {
                Button {
                    let position = recent.position
                    model.play(recent.track, in: tracks)
                    model.player.seek(to: position)
                } label: {
                    Label("Resume at \(TimeText.duration(recent.position))", systemImage: "play.circle")
                        .appFont(.caption, weight: .semibold)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .padding(.leading, 8)
                .accessibilityLabel("Resume \(recent.track.title) at \(TimeText.duration(recent.position))")
                .accessibilityIdentifier("library.resume.\(recent.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.recent.\(recent.id)")
    }
}

@MainActor
private struct LibrarySavedSongsView: View {
    enum Kind { case likes, recents }
    @Environment(MusicAppModel.self) private var model
    let kind: Kind

    private var title: String { kind == .likes ? "Liked songs" : "Recent listens" }
    private var tracks: [Track] { kind == .likes ? model.library.favorites : model.library.recentlyPlayed.map(\.track) }
    private var identifier: String { kind == .likes ? "library.likes" : "library.recents" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: kind == .likes ? "heart.fill" : "clock.arrow.circlepath")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 100, height: 100)
                        .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    Text(title)
                        .appFont(.largeTitle, weight: .bold)
                        .accessibilityAddTraits(.isHeader)
                    Text(librarySongCount(tracks.count))
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                    LibraryQueueButtons(tracks: tracks, title: title, identifier: identifier)
                    LibraryStoreNotices()
                }
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                if tracks.isEmpty {
                    EmptyStateView(
                        symbol: kind == .likes ? "heart" : "headphones",
                        title: kind == .likes ? "Save a song you love" : "Nothing played yet",
                        message: kind == .likes
                            ? "Tap the heart in a song’s menu to keep it here."
                            : "With listening history on, your recent songs and resume positions appear here."
                    )
                    Button("Find music", systemImage: "magnifyingglass") { model.openSearch("") }
                        .appFont(.body)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("\(identifier).findMusic")
                } else if kind == .likes {
                    ForEach(tracks) { track in
                        TrackRow(track: track, tracks: tracks)
                            .swipeActions(edge: .trailing) {
                                Button("Unlike", systemImage: "heart.slash", role: .destructive) {
                                    model.library.toggleFavorite(track)
                                }
                                .accessibilityIdentifier("library.unlike.\(track.id)")
                            }
                            .accessibilityAction(named: "Remove from liked songs") {
                                model.library.toggleFavorite(track)
                            }
                    }
                } else {
                    ForEach(model.library.recentlyPlayed) { recent in
                        LibraryRecentSongRow(recent: recent, tracks: tracks)
                    }
                }
            }
            .listRowBackground(AppTheme.surface)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

@MainActor
private struct LibraryUserPlaylistView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var editor: LibraryPlaylistEditorRequest?
    @State private var isAddingSongs = false
    @State private var isDeleting = false

    private var playlist: UserPlaylist? { model.library.playlists.first { $0.id == playlistID } }

    var body: some View {
        Group {
            if let playlist {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 18) {
                            ArtworkView(url: playlist.tracks.first?.artworkURL, title: playlist.name, size: 176, cornerRadius: 8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .accessibilityHidden(true)
                            Text(playlist.name)
                                .appFont(.largeTitle, weight: .bold)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text("\(librarySongCount(playlist.tracks.count)) · Made by you")
                                .appFont(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                            LibraryQueueButtons(tracks: playlist.tracks, title: playlist.name, identifier: "library.playlist")
                            Button("Add songs", systemImage: "plus") {
                                AppNavigationIntent.perform(in: model) { isAddingSongs = true }
                            }
                            .appFont(.headline, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(AppTheme.surface, in: Capsule())
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.playlist.addSongs")
                            LibraryStoreNotices()
                        }
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    if playlist.tracks.isEmpty {
                        EmptyStateView(symbol: "music.note", title: "The first song sets the mood",
                                       message: "Add a few songs, then put them in an order that feels right.")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        Section {
                            ForEach(playlist.tracks) { track in
                                TrackRow(track: track, tracks: playlist.tracks)
                                    .accessibilityElement(children: .contain)
                                    .accessibilityIdentifier("library.playlist.track.\(track.id)")
                                    .accessibilityAction(named: "Remove from playlist") {
                                        model.library.remove(trackID: track.id, from: playlistID)
                                    }
                            }
                            .onDelete { offsets in
                                let ids = offsets.compactMap { playlist.tracks.indices.contains($0) ? playlist.tracks[$0].id : nil }
                                for id in ids { model.library.remove(trackID: id, from: playlistID) }
                            }
                            .onMove { offsets, destination in
                                model.library.moveTracks(in: playlistID, from: offsets, to: destination)
                            }
                        } footer: {
                            Text("Use Edit to reorder or remove songs.")
                                .appFont(.footnote)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .listRowBackground(AppTheme.surface)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                EmptyStateView(symbol: "music.note.list", title: "Playlist removed",
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
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .appFont(.body)
                    .disabled(playlist?.tracks.isEmpty != false)
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
                    Button("Delete playlist", systemImage: "trash", role: .destructive) {
                        AppNavigationIntent.perform(in: model) { isDeleting = true }
                    }
                    .accessibilityIdentifier("library.playlist.delete")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Playlist actions")
                .accessibilityIdentifier("library.playlist.menu")
            }
        }
        .sheet(item: AppNavigationIntent.binding($editor, in: model, identity: { $0?.id })) { request in
            LibraryPlaylistNameEditor(request: request)
        }
        .sheet(isPresented: AppNavigationIntent.binding($isAddingSongs, in: model)) { LibraryAddSongsSheet(playlistID: playlistID) }
        .alert("Delete playlist?", isPresented: AppNavigationIntent.binding($isDeleting, in: model)) {
            Button("Delete playlist", role: .destructive) {
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
                    Text("Give it a name")
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
            .navigationTitle(request.playlist == nil ? "New playlist" : "Rename playlist")
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
        .tint(AppTheme.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
                        Label("Search all music", systemImage: "magnifyingglass")
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
                    EmptyStateView(symbol: "magnifyingglass", title: "Find your next song",
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
                        Text("From your library").appFont(.footnote)
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
            .navigationTitle("Add songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { AppNavigationIntent.perform(in: model) { dismiss() } }
                        .appFont(.body, weight: .semibold)
                        .accessibilityIdentifier("library.playlist.addDone")
                }
            }
        }
        .tint(AppTheme.accent)
        .presentationDragIndicator(.visible)
    }
}

private func librarySongCount(_ count: Int) -> String {
    "\(count.formatted()) \(count == 1 ? "song" : "songs")"
}
