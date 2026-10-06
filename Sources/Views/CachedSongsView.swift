import SwiftUI

@MainActor
struct CachedSongsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Inside a tab the offline banner already reports the status; Settings covers that banner, so it asks for the line.
    var showsOfflineStatus = false
    @State private var query = ""
    @State private var isVisible = false
    @State private var removingID: String?

    var body: some View {
        let songs = matchingSongs
        let playableTracks = songs.filter(\.isPlayable).compactMap { model.cachedTrack(for: $0) }
        List {
            if showsOfflineStatus, model.isOffline {
                Label("You're offline", systemImage: "wifi.slash")
                    .appFont(.subheadline, weight: .semibold)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("You're offline")
                    .accessibilityIdentifier("cachedSongs.offline")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let error = model.cachedSongsError {
                errorSection(error)
            }

            if model.cachedSongsUsage != nil || !model.cachedSongs.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(countDescription(songs))
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("cachedSongs.count")
                        CachedSongsQueueButtons(tracks: playableTracks,
                                                title: isFiltering ? "cached search results" : "cached songs")
                            .disabled(removingID != nil)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if model.temporaryCachedSongs.isEmpty {
                        if model.cachedSongsError == nil { emptyCache }
                    } else if songs.isEmpty {
                        EmptyStateView(symbol: "magnifyingglass", title: "No Matching Cached Songs",
                                       message: "Try another title, artist, or album.")
                            .accessibilityIdentifier("cachedSongs.search.empty")
                    } else {
                        ForEach(songs) { song in
                            CachedSongRow(song: song, track: model.cachedTrack(for: song), tracks: playableTracks,
                                          isRemoving: removingID == song.id,
                                          removalDisabled: removingID != nil || model.player.isUpdatingAudioCacheLimit) {
                                remove(song.id)
                            }
                        }
                    }
                } footer: {
                    Text("iOS can remove cached audio. Artwork and lyrics may still need a connection.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("cachedSongs.footer")
                }
                .listRowBackground(AppTheme.surface)
            } else if !model.hasLoadedCachedSongs || model.isRefreshingCachedSongs, model.cachedSongsError == nil {
                ProgressView("Checking cached songs…")
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .accessibilityIdentifier("cachedSongs.loading")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if model.cachedSongsError == nil {
                EmptyStateView(symbol: "internaldrive", title: "Cache Browsing Unavailable",
                               message: "This playback provider doesn't offer a cache inventory. Local audio availability couldn't be checked.")
                    .accessibilityIdentifier("cachedSongs.unsupported")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("Cached Songs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Title, artist, or album")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("cachedSongs.screen")
        .refreshable { await model.refreshCachedSongs() }
        .onAppear {
            // Paired transitions keep the model's screen count balanced if SwiftUI repeats a callback.
            guard !isVisible else { return }
            isVisible = true
            model.cachedSongsScreenAppeared()
        }
        .onDisappear {
            guard isVisible else { return }
            isVisible = false
            model.cachedSongsScreenDisappeared()
        }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            while !Task.isCancelled {
                // Keep an operation error visible until the listener explicitly retries.
                if removingID == nil, model.cachedSongsError == nil,
                   !model.hasLoadedCachedSongs || model.cachedSongsUsage != nil {
                    await model.refreshCachedSongs()
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var shouldPoll: Bool { isVisible && scenePhase == .active && !model.isPlayerPresented }
    private var isFiltering: Bool { !SearchRelevance.normalize(query).isEmpty }

    /// Cache-tier songs only: a downloaded song has its home under Downloads and never shows here.
    private var matchingSongs: [CachedSong] {
        let songs = model.temporaryCachedSongs
        let tokens = SearchRelevance.normalize(query).split(separator: " ")
        guard !tokens.isEmpty else { return songs }
        let tracks = songs.compactMap { model.cachedTrack(for: $0) }
        let matchingIDs = Set(LibraryTrackSearch(tracks: tracks, query: query).tracks.map(\.id))
        return songs.filter { song in
            if matchingIDs.contains(song.id) { return true }
            guard model.cachedTrack(for: song) == nil else { return false }
            let text = SearchRelevance.normalize("Cached song \(song.id)")
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    private func countDescription(_ songs: [CachedSong]) -> String {
        let total = model.temporaryCachedSongs.count
        let count = isFiltering ? "\(songs.count.formatted()) of \(total.formatted()) songs"
            : "\(total.formatted()) \(total == 1 ? "song" : "songs")"
        let available = songs.filter(\.isPlayable).count
        let prefix = model.cachedSongsError == nil ? "" : "Last checked: "
        return "\(prefix)\(count) · \(available.formatted()) available locally"
    }

    private func errorSection(_ error: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't update cached songs", systemImage: "exclamationmark.triangle")
                    .appFont(.headline, weight: .semibold)
                Text(error)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cachedSongs.error")
                Button {
                    Task { await model.refreshCachedSongs() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshingCachedSongs || removingID != nil || model.player.isUpdatingAudioCacheLimit)
                .accessibilityIdentifier("cachedSongs.retry")
            }
        }
        .listRowBackground(AppTheme.surface)
    }

    private var emptyCache: some View {
        VStack(spacing: 0) {
            EmptyStateView(symbol: "music.note", title: "No Cached Songs Yet",
                           message: model.isOffline
                               ? "When you're connected, play music from your library. Songs appear here after their audio finishes caching."
                               : "Songs appear here after their audio finishes caching while you listen. Play something from your library to get started.")
            Button {
                AppNavigationIntent.perform(in: model) {
                    dismiss()
                    model.isSettingsPresented = false
                    model.selectedTab = .library
                }
            } label: {
                Label("Browse Library", systemImage: "music.note.list")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("cachedSongs.library")
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cachedSongs.empty")
    }

    private func remove(_ id: String) {
        guard removingID == nil, !model.player.isUpdatingAudioCacheLimit,
              let song = model.temporaryCachedSongs.first(where: { $0.id == id }), !song.isInUse else { return }
        removingID = id
        Task {
            defer { removingID = nil }
            await model.removeCachedSong(id: id)
        }
    }
}

@MainActor
private struct CachedSongsQueueButtons: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismissSearch) private var dismissSearch
    let tracks: [Track]
    let title: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button { play(shuffle: false) } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AppTheme.onAccent)
                    .background(AppTheme.accent, in: Capsule())
            }
            .accessibilityLabel("Play \(title)")
            .accessibilityIdentifier("cachedSongs.play")
            Button { play(shuffle: true) } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AppTheme.primaryText)
                    .background(AppTheme.raised, in: Capsule())
            }
            .accessibilityLabel("Shuffle \(title)")
            .accessibilityIdentifier("cachedSongs.shuffle")
        }
        .appFont(.subheadline, weight: .semibold)
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
        .opacity(tracks.isEmpty ? 0.45 : 1)
    }

    private func play(shuffle: Bool) {
        let availableIDs = Set(model.temporaryCachedSongs.filter(\.isPlayable).map(\.id))
        // Native search dismissal clears the filter, so playback needs its own captured queue.
        let queue = tracks.filter { availableIDs.contains($0.id) }
        guard !queue.isEmpty else { return }
        dismissSearch()
        model.play(queue, shuffle: shuffle)
    }
}

@MainActor
private struct CachedSongRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismissSearch) private var dismissSearch
    let song: CachedSong
    let track: Track?
    let tracks: [Track]
    let isRemoving: Bool
    let removalDisabled: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: play) {
                HStack(alignment: .center, spacing: 13) {
                    // Artwork has a separate cache; offline browsing must not start image requests.
                    ArtworkView(url: model.isOffline ? nil : track?.artworkURL, title: title, size: 52, cornerRadius: 5)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(model.player.currentTrack?.id == song.id ? AppTheme.accent : AppTheme.primaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text(byline)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text("\(availability) · \(storageDetail)")
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if song.isInUse {
                            Label("In use", systemImage: "lock.fill")
                                .appFont(.caption, weight: .semibold)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay || isRemoving)
            .accessibilityLabel("\(title), \(byline)")
            .accessibilityValue("\(availability). \(storageDetail)\(song.isInUse ? ". In use" : "")")
            .accessibilityHint(canPlay ? "Play cached audio" : "This song cannot be played locally.")
            .accessibilityIdentifier("cachedSongs.play.\(song.id)")

            Button(role: .destructive, action: remove) {
                Group {
                    if isRemoving { ProgressView() }
                    else { Image(systemName: song.isInUse ? "lock.fill" : "trash") }
                }
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.secondaryText)
            .disabled(!canRemove)
            .accessibilityLabel(song.isInUse ? "\(title), In use" : "Remove cached song, \(title)")
            .accessibilityHint(song.isInUse
                               ? "Playing and upcoming songs are kept, including while paused."
                               : "Removes all cached versions of this song. Listening again may need a connection.")
            .accessibilityIdentifier("cachedSongs.remove.\(song.id)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cachedSongs.row.\(song.id)")
        .swipeActions(edge: .trailing) {
            Button(song.isInUse ? "In use" : "Remove", systemImage: "trash", role: .destructive, action: remove)
                .disabled(!canRemove)
                .accessibilityIdentifier("cachedSongs.swipeRemove.\(song.id)")
        }
        .contextMenu {
            Button("Play Cached Song", systemImage: "play.fill", action: play)
                .disabled(!canPlay || isRemoving)
                .accessibilityIdentifier("cachedSongs.contextPlay.\(song.id)")
            if let quality = song.preferredAudio?.quality { Text(quality.summary) }
            Button(song.isInUse ? "In use" : "Remove cached song", systemImage: "trash", role: .destructive, action: remove)
                .disabled(!canRemove)
                .accessibilityIdentifier("cachedSongs.contextRemove.\(song.id)")
        }
    }

    private var title: String {
        guard let title = track?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Cached song" }
        return title
    }

    private var byline: String {
        guard let track, !track.credits.isEmpty else { return "Recording ID: \(song.id)" }
        return track.artistName
    }

    private var canPlay: Bool { song.isPlayable && track != nil }
    private var canRemove: Bool { !song.isInUse && !removalDisabled }

    private var availability: String {
        guard song.isPlayable else { return "Needs a connection" }
        return track == nil ? "Audio saved; playback unavailable" : "Available locally"
    }

    private var storageDetail: String {
        var parts = [ByteCountFormatter.string(fromByteCount: max(0, song.bytes), countStyle: .binary)]
        if let codec = song.preferredAudio?.quality?.codec { parts.append(codec.title) }
        if song.variantCount > 1 { parts.append("\(song.variantCount.formatted()) versions") }
        return parts.joined(separator: " · ")
    }

    private func play() {
        guard !isRemoving, let current = model.temporaryCachedSongs.first(where: { $0.id == song.id }), current.isPlayable,
              let track = model.cachedTrack(for: current) else { return }
        let availableIDs = Set(model.temporaryCachedSongs.filter(\.isPlayable).map(\.id))
        // Keep both the selected recording and the filtered queue across native search dismissal.
        let queue = tracks.filter { availableIDs.contains($0.id) }
        dismissSearch()
        model.play(track, in: queue)
    }
}
