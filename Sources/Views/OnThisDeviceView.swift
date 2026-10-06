import SwiftUI

/// Every song that plays without a connection: downloads first, then complete copies in the temporary cache.
@MainActor
struct OnThisDeviceView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isVisible = false

    var body: some View {
        let songs = model.onThisDeviceSongs
        let queue = songs.downloaded.map(\.track) + songs.cached.map(\.track)
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text(countDescription(downloaded: songs.downloaded.count, cached: songs.cached.count))
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onThisDevice.count")
                    LibraryQueueButtons(tracks: queue, title: "songs on this device", identifier: "onThisDevice")
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if queue.isEmpty {
                if !model.hasLoadedCachedSongs || model.isRefreshingCachedSongs, model.cachedSongsError == nil {
                    ProgressView("Checking this device…")
                        .frame(maxWidth: .infinity, minHeight: 88)
                        .accessibilityIdentifier("onThisDevice.loading")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    EmptyStateView(symbol: "internaldrive", title: "Nothing on This Device Yet",
                                   message: "Download songs, or play them while connected so they are cached on this device.")
                        .accessibilityIdentifier("onThisDevice.empty")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            if !songs.downloaded.isEmpty {
                section(title: "Downloaded", id: "downloaded", rows: songs.downloaded, queue: queue)
            }
            if !songs.cached.isEmpty {
                section(title: "Cached", id: "cached", rows: songs.cached, queue: queue)
            }
        }
        .listStyle(.plain)
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("On This Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("onThisDevice.screen")
        .refreshable { await model.refreshCachedSongs() }
        .task { await model.refreshCachedSongs() }
        .onAppear {
            // Paired transitions keep the model's screen count balanced if SwiftUI repeats a callback.
            guard !isVisible else { return }
            isVisible = true
            model.onThisDeviceScreenAppeared()
        }
        .onDisappear {
            guard isVisible else { return }
            isVisible = false
            model.onThisDeviceScreenDisappeared()
        }
    }

    private func section(title: String, id: String, rows: [(song: CachedSong, track: Track)], queue: [Track]) -> some View {
        Section {
            ForEach(rows, id: \.song.id) { row in
                OnThisDeviceRow(song: row.song, track: row.track, queue: queue)
            }
        } header: {
            Text(title)
                .appFont(.caption)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onThisDevice.section.\(id)")
        }
        .listRowBackground(AppTheme.surface)
    }

    private func countDescription(downloaded: Int, cached: Int) -> String {
        let total = downloaded + cached
        let songs = "\(total.formatted()) \(total == 1 ? "song" : "songs") play without a connection"
        guard total > 0 else { return songs }
        return "\(songs) · \(downloaded.formatted()) downloaded · \(cached.formatted()) cached"
    }
}

@MainActor
private struct OnThisDeviceRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let song: CachedSong
    let track: Track
    let queue: [Track]

    var body: some View {
        Button {
            model.play(track, in: queue)
        } label: {
            HStack(alignment: .center, spacing: 13) {
                // Artwork has a separate cache; offline browsing must not start image requests.
                ArtworkView(url: model.isOffline ? nil : track.artworkURL, title: track.title, size: 44, cornerRadius: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(model.player.currentTrack?.id == song.id ? AppTheme.accent : AppTheme.primaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Text(byline)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if song.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.title), \(byline)")
        .accessibilityValue(song.isDownloaded ? "Downloaded" : "Cached")
        .accessibilityIdentifier("onThisDevice.row.\(song.id)")
    }

    private var byline: String {
        track.credits.isEmpty ? "Recording ID: \(song.id)" : track.artistName
    }
}
