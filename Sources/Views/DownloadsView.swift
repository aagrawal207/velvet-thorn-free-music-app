import SwiftUI
import UIKit

@MainActor
struct DownloadsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isVisible = false
    @State private var deletingID: String?
    @State private var isConfirmingCancelAll = false
    @State private var filter: DownloadsFilter = .all

    var body: some View {
        let allDownloaded = downloadedSongs
        let downloaded = allDownloaded.filter { song in
            let track = model.cachedTrack(for: song)
            let isLiked = track.map { model.library.isFavorite($0) } ?? false
            switch filter {
            case .all: return true
            case .superLiked: return track.map { model.library.isSuperLiked($0) } ?? false
            case .liked: return isLiked
            case .notLiked: return !isLiked
            }
        }
        let tracks = downloaded.compactMap { model.cachedTrack(for: $0) }
        List {
            if model.isOffline {
                Label("You're offline", systemImage: "wifi.slash")
                    .appFont(.subheadline, weight: .semibold)
                    .accessibilityIdentifier("downloads.offline")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !model.downloads.isAvailable {
                EmptyStateView(symbol: "internaldrive", title: "Downloads Unavailable",
                               message: "This playback provider keeps no audio on this device.")
                    .accessibilityIdentifier("downloads.unsupported")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                summary(allDownloaded, tracks: tracks)
                if let error = model.downloads.queueError {
                    Section {
                        Text(error).appFont(.footnote)
                        Button("Try Again") { model.restoreDownloadQueue() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("downloads.queue.retry")
                    }
                }
                if !model.downloads.items.isEmpty { inProgress }
                downloadedSection(downloaded, tracks: tracks, hasHiddenSongs: downloaded.count < allDownloaded.count)
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
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("downloads.screen")
        .refreshable { await model.refreshCachedSongs() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: shouldPoll) {
            guard shouldPoll else { return }
            while !Task.isCancelled {
                if deletingID == nil, model.cachedSongsError == nil { await model.refreshCachedSongs() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .alert("Cancel All Downloads?", isPresented: AppNavigationIntent.binding($isConfirmingCancelAll, in: model)) {
            Button("Cancel Downloads", role: .destructive) { model.downloads.cancelAll() }
            Button("Keep Downloading", role: .cancel) { }
        } message: {
            Text("Songs already on this device stay.")
        }
    }

    private var shouldPoll: Bool { isVisible && scenePhase == .active && !model.isPlayerPresented }

    private var downloadedSongs: [CachedSong] {
        model.cachedSongs.filter(\.isDownloaded).sorted { left, right in
            let leftTitle = model.cachedTrack(for: left)?.title ?? left.id
            let rightTitle = model.cachedTrack(for: right)?.title ?? right.id
            return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
        }
    }

    private func summary(_ downloaded: [CachedSong], tracks: [Track]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Text(summaryText(downloaded))
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("downloads.summary")
                if !downloaded.isEmpty {
                    LibraryFilterChips(options: DownloadsFilter.allCases, selection: $filter, identifier: "downloads.filter")
                }
                LibraryQueueButtons(tracks: tracks.filter { model.cachedPlayableTrackIDs.contains($0.id) },
                                    title: filter == .all ? "downloads" : "\(filter.title.lowercased()) downloads", identifier: "downloads")
                    .disabled(deletingID != nil)
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func summaryText(_ downloaded: [CachedSong]) -> String {
        let bytes = model.cachedSongsUsage?.downloadedBytes ?? downloaded.reduce(0) { $0 + $1.bytes }
        let count = downloaded.count
        let pending = model.downloads.pendingItems.count
        var text = "\(count.formatted()) \(count == 1 ? "song" : "songs") on this device · \(Self.bytes(bytes))"
        if pending > 0 { text += " · \(pending.formatted()) in progress" }
        return text
    }

    private var inProgress: some View {
        Section {
            ForEach(model.downloads.items) { item in
                DownloadProgressRow(item: item)
            }
            Button(role: .destructive) {
                AppNavigationIntent.perform(in: model) { isConfirmingCancelAll = true }
            } label: {
                Label("Cancel All", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("downloads.cancelAll")
        } header: {
            Text("In Progress").appFont(.caption)
        }
        .listRowBackground(AppTheme.surface)
    }

    private func downloadedSection(_ downloaded: [CachedSong], tracks: [Track], hasHiddenSongs: Bool) -> some View {
        Section {
            if downloaded.isEmpty, hasHiddenSongs {
                EmptyStateView(symbol: filter.emptySymbol, title: filter.emptyTitle, message: filter.emptyMessage)
                    .accessibilityIdentifier("downloads.filter.empty")
            } else if downloaded.isEmpty {
                if model.downloads.items.isEmpty {
                    emptyState
                } else {
                    Text("Songs appear here when their download finishes.")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("downloads.pendingOnly")
                }
            } else {
                ForEach(downloaded) { song in
                    DownloadedSongRow(song: song, track: model.cachedTrack(for: song), tracks: tracks,
                                      isDeleting: deletingID == song.id, deletionDisabled: deletingID != nil) {
                        delete(song.id)
                    }
                }
            }
        } header: {
            Text("Downloaded").appFont(.caption)
        } footer: {
            Text("Downloads stay on this device until you delete them. They are not counted in the cache limit and are not kept in the temporary cache too.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("downloads.footer")
        }
        .listRowBackground(AppTheme.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            EmptyStateView(symbol: "arrow.down.circle", title: "No Downloads Yet",
                           message: "Download songs, albums or playlists to keep them on this device.")
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
            .accessibilityIdentifier("downloads.library")
        }
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.empty")
    }

    private func delete(_ id: String) {
        guard deletingID == nil else { return }
        deletingID = id
        Task {
            defer { deletingID = nil }
            await model.deleteDownload(id: id)
        }
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .binary)
    }
}

@MainActor
private struct DownloadProgressRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(item.track.title), \(item.track.artistName)")
                    .appFont(.subheadline, weight: .semibold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .accessibilityIdentifier("downloads.title.\(item.id)")
                Text(detail)
                    .appFont(.caption)
                    .foregroundStyle(isFailed ? AppTheme.accent : AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("downloads.state.\(item.id)")
                if case .downloading(let fraction) = item.state {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("downloads.progress.\(item.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFailed {
                Button {
                    model.downloads.retry(item.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Retry download, \(item.track.title)")
                .accessibilityIdentifier("downloads.retry.\(item.id)")
            }
            Button(role: .destructive) {
                model.downloads.cancel(item.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.secondaryText)
            .accessibilityLabel(isFailed ? "Remove failed download, \(item.track.title)" : "Cancel download, \(item.track.title)")
            .accessibilityIdentifier("downloads.cancel.\(item.id)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.item.\(item.id)")
    }

    private var isFailed: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var detail: String {
        switch item.state {
        case .failed(let reason): "Failed. \(reason)"
        case .queued: model.isOffline ? "Waiting for a connection" : item.statusTitle
        default: item.statusTitle
        }
    }
}

@MainActor
private struct DownloadedSongRow: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let song: CachedSong
    let track: Track?
    let tracks: [Track]
    let isDeleting: Bool
    let deletionDisabled: Bool
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: play) {
                HStack(alignment: .center, spacing: 13) {
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
                        Text(storageDetail)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canPlay || isDeleting)
            .accessibilityLabel("\(title), \(byline)")
            .accessibilityValue("Downloaded. \(storageDetail)")
            .accessibilityHint(canPlay ? "Play downloaded audio" : "This song cannot be played locally.")
            .accessibilityIdentifier("downloads.play.\(song.id)")

            Button(role: .destructive, action: delete) {
                Group {
                    if isDeleting { ProgressView() } else { Image(systemName: "trash") }
                }
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppTheme.secondaryText)
            .disabled(deletionDisabled)
            .accessibilityLabel("Delete download, \(title)")
            .accessibilityHint("Deletes the audio from this device. Listening again may need a connection.")
            .accessibilityIdentifier("downloads.delete.\(song.id)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloads.row.\(song.id)")
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                .disabled(deletionDisabled)
                .accessibilityIdentifier("downloads.swipeDelete.\(song.id)")
        }
        .contextMenu {
            Button("Play", systemImage: "play.fill", action: play)
                .disabled(!canPlay || isDeleting)
            if let quality = song.preferredAudio?.quality { Text(quality.summary) }
            if let track {
                Button("Remove Download, Keep Cached", systemImage: "arrow.down.circle.dashed") {
                    Task { await model.removeDownload(track) }
                }
                .disabled(deletionDisabled)
                .accessibilityIdentifier("downloads.contextRemove.\(song.id)")
            }
            Button("Delete Download", systemImage: "trash", role: .destructive, action: delete)
                .disabled(deletionDisabled)
                .accessibilityIdentifier("downloads.contextDelete.\(song.id)")
        }
    }

    private var title: String {
        guard let title = track?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Downloaded song" }
        return title
    }

    private var byline: String {
        guard let track, !track.credits.isEmpty else { return "Recording ID: \(song.id)" }
        return track.artistName
    }

    private var canPlay: Bool { song.isPlayable && track != nil }

    private var storageDetail: String {
        var parts = [DownloadsView.bytes(song.bytes)]
        if let codec = song.preferredAudio?.quality?.codec { parts.append(codec.title) }
        if song.variantCount > 1 { parts.append("\(song.variantCount.formatted()) versions") }
        return parts.joined(separator: " · ")
    }

    private func play() {
        guard !isDeleting, song.isPlayable, let track else { return }
        let availableIDs = model.cachedPlayableTrackIDs
        model.play(track, in: tracks.filter { availableIDs.contains($0.id) })
    }
}

/// Prepares a shareable file from the complete local copy and hands it to the system share sheet.
@MainActor
struct AudioExportView: View {
    @Environment(MusicAppModel.self) private var model
    let track: Track
    @State private var export: AudioExport?
    @State private var errorMessage: String?
    @State private var isPreparing = false
    @State private var generation = UUID()
    @State private var shareSource: AudioExportShareSource?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    if let data = export?.artworkJPEG, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
                            .accessibilityIdentifier("export.cover")
                    } else {
                        Image(systemName: "music.note").frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).appFont(.subheadline, weight: .semibold).lineLimit(2)
                        Text(track.artistName).appFont(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)

                if let export {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(export.url.lastPathComponent)
                            .appFont(.footnote, design: .monospaced)
                            .lineLimit(3)
                            .accessibilityIdentifier("export.fileName")
                        Text(detail(export))
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("export.detail")
                    }
                    Button {
                        shareSource = AudioExportShareSource(export: export, title: track.title)
                    } label: {
                        Label("Share File", systemImage: "square.and.arrow.up")
                            .appFont(.body, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(AppNavigationIntentButtonStyle(.plain))
                    .appGlass(in: Capsule(), interactive: true)
                    .accessibilityIdentifier("export.share")
                } else if isPreparing {
                    ProgressView("Preparing file…")
                        .appFont(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .accessibilityIdentifier("export.preparing")
                } else if let errorMessage {
                    Text(errorMessage)
                        .appFont(.footnote)
                        .foregroundStyle(AppTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("export.error")
                    if model.hasLocalCopy(track) {
                        Button {
                            generation = UUID()
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .appFont(.body, weight: .semibold)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .appGlass(in: Capsule(), interactive: true)
                        .accessibilityIdentifier("export.retry")
                    } else if model.downloads.isAvailable {
                        Button {
                            model.download(track)
                        } label: {
                            Label(model.downloads.isQueued(track.id) ? "Downloading…" : "Download to export", systemImage: "arrow.down.circle")
                                .appFont(.body, weight: .semibold)
                                .frame(maxWidth: .infinity, minHeight: 56)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .appGlass(in: Capsule(), interactive: true)
                        .disabled(model.downloads.isQueued(track.id))
                        .accessibilityIdentifier("export.download")
                    }
                }
                Text("Exports use AAC in an M4A file, with song details and available cover art. Other formats are converted for compatibility; this does not improve the original audio quality.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if export?.hasArtwork == true {
                    Text("Cover art was verified inside this M4A. Some receiving apps do not display embedded covers.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("export.coverEvidence")
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("export.screen")
        .sheet(item: $shareSource) { AudioExportShareSheet(source: $0) }
        .task(id: generation) {
            guard export == nil else { return }
            isPreparing = true
            errorMessage = nil
            defer { isPreparing = false }
            do {
                let result = try await model.exportAudio(for: track)
                guard !Task.isCancelled else { return }
                export = result
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func detail(_ export: AudioExport) -> String {
        var parts = [DownloadsView.bytes(export.bytes)]
        if let codec = export.codec { parts.append(codec.title) }
        if export.tagged { parts.append("Song details included") }
        parts.append(export.hasArtwork ? "Cover art included" : "No cover art available")
        parts.append(export.transcoded ? "Converted to AAC" : "Original AAC preserved")
        return parts.joined(separator: " · ")
    }
}

enum DownloadsFilter: String, CaseIterable, LibraryFilterOption {
    case all, superLiked, liked, notLiked

    var key: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .superLiked: "Super Liked"
        case .liked: "Liked"
        case .notLiked: "Not Liked"
        }
    }

    /// Shown when the filter hides every download; All hides nothing, so its copy is never displayed.
    var emptySymbol: String {
        switch self {
        case .all, .liked: "heart"
        case .superLiked: "bolt.heart.fill"
        case .notLiked: "heart.slash"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all, .liked: "No Liked Downloads"
        case .superLiked: "No Super Liked Downloads"
        case .notLiked: "All Downloads Are Liked"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all, .liked: "Like a downloaded song to see it here."
        case .superLiked: "No super liked songs are downloaded. Super like a downloaded song to see it here."
        case .notLiked: "Downloaded songs outside Liked Songs appear here."
        }
    }
}
