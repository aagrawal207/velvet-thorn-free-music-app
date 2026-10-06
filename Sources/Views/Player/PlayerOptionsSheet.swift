import SwiftUI

enum PlayerOptionsRoute: String, Hashable {
    case options, artists, details, playlists, newPlaylist, sleep, export, equalizer, equalizerAdvanced, shareCard, youtubeChanges
    case devices

    var title: String {
        switch self {
        case .options: "Song Options"
        case .artists: "Go to Artist"
        case .details: "Song Details"
        case .playlists: "Add to Playlist"
        case .newPlaylist: "New Playlist"
        case .sleep: "Sleep Timer"
        case .export: "Export Audio"
        case .equalizer, .equalizerAdvanced: "Equalizer"
        case .shareCard: "Share Song"
        case .youtubeChanges: "YouTube Changes"
        case .devices: "Devices"
        }
    }
}

@MainActor
struct PlayerOptionsSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let track: Track
    let initialRoute: PlayerOptionsRoute
    let onAlbum: (MusicCollection) -> Void
    let onArtist: (ArtistCredit) -> Void
    @State private var path: [PlayerOptionsRoute] = []
    @State private var playlistName = ""
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var isConfirmingRemoval = false
    @State private var writeSelection: (track: Track, context: YouTubeAccountWriteController.Context)?
    @FocusState private var isPlaylistNameFocused: Bool

    var body: some View {
        NavigationStack(path: AppNavigationIntent.binding($path, in: model)) {
            page(initialRoute)
                .navigationDestination(for: PlayerOptionsRoute.self) { page($0) }
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .appSheetChrome()
        .background(AppTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.options.sheet")
        .onChange(of: path) { _, routes in
            if [.newPlaylist, .details, .equalizer, .equalizerAdvanced, .shareCard, .youtubeChanges, .devices].contains(routes.last) {
                selectedDetent = .large
            } else {
                isPlaylistNameFocused = false
            }
        }
        .onChange(of: dynamicTypeSize, initial: true) { _, size in
            if size.isAccessibilitySize { selectedDetent = .large }
        }
        .onChange(of: verticalSizeClass, initial: true) { _, size in
            if size == .compact { selectedDetent = .large }
        }
    }

    private func page(_ route: PlayerOptionsRoute) -> some View {
        Group {
            switch route {
            case .options: options
            case .artists: artists
            case .details: PlayerSongDetailsView(track: track, onAlbum: onAlbum, onArtist: onArtist)
            case .playlists: playlists
            case .newPlaylist: newPlaylist
            case .sleep: PlayerSleepTimerContent(onDone: { AppNavigationIntent.perform(in: model) { dismiss() } })
            case .export: AudioExportView(track: track)
            case .equalizer:
                PlayerEqualizerSheet(track: track) { AppNavigationIntent.perform(in: model) { path.append(.equalizerAdvanced) } }
            case .equalizerAdvanced: EqualizerView(target: model.equalizerTarget(for: track))
            case .shareCard: SongShareCardPage(track: track)
            case .youtubeChanges:
                if let selection = writeSelection {
                    YouTubeAccountWriteView(controller: model.youTubeWrite, track: selection.track, context: selection.context,
                                            showsDoneButton: false)
                }
            case .devices: if let nearby = model.nearbyDevices { NearbyDevicesList(controller: nearby) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.background)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!path.isEmpty)
        .toolbar {
            if !path.isEmpty {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { backButton }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { backButton }
                }
            }
        }
        .appSheetDoneButton(id: "player.options.toolbarDone") { AppNavigationIntent.perform(in: model) { dismiss() } }
    }

    private var backButton: some View {
        Button {
            guard !path.isEmpty else { return }
            AppNavigationIntent.perform(in: model) {
                isPlaylistNameFocused = false
                path.removeLast()
            }
        } label: {
            Image(systemName: "chevron.left")
                .appFont(.body)
                .frame(width: 36, height: 36)
                .appGlass(in: Circle(), interactive: true)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("player.options.back")
    }

    private var options: some View {
        ScrollView {
            VStack(spacing: 12) {
                trackSummary
                VStack(spacing: 0) {
                    reactionAndShareRows
                    Divider().padding(.leading, 60)

                    option("Start Radio", symbol: "dot.radiowaves.left.and.right", id: "player.options.radio",
                           subtitle: model.isOffline ? "Connect to the internet to start radio." : nil,
                           enabled: !model.isOffline) {
                        guard !model.isOffline else { return }
                        AppNavigationIntent.perform(in: model) {
                            model.startRadio(seed: .song(track))
                            dismiss()
                        }
                    }
                    option("Song Details", symbol: "info.circle", id: "player.options.details", showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.details) }
                    }
                    option("Go to Album", symbol: "square.stack", id: "player.options.album",
                           enabled: track.albumCollection != nil, showsChevron: true) {
                        if let album = track.albumCollection { onAlbum(album) }
                    }
                    option("Go to Artist", symbol: "person.crop.circle", id: "player.options.artist",
                           enabled: !track.allCredits.isEmpty, showsChevron: true) {
                        if track.allCredits.count == 1, let credit = track.allCredits.first {
                            onArtist(credit)
                        } else {
                            AppNavigationIntent.perform(in: model) { path.append(.artists) }
                        }
                    }
                    option("Add to Playlist", symbol: "music.note.list", id: "player.options.playlist", showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.playlists) }
                    }
                    if YouTubeAccountWriteTarget.videoID(track) != nil {
                        option("YouTube Changes", symbol: "arrow.up.arrow.down", id: "player.options.youtubeChanges", showsChevron: true) {
                            writeSelection = (track, model.youTubeWrite.context)
                            AppNavigationIntent.perform(in: model) { path.append(.youtubeChanges) }
                        }
                    }
                    if model.downloads.isAvailable {
                        downloadOption
                        option(model.hasLocalCopy(track) ? "Export Audio" : "Download to Export", symbol: "square.and.arrow.up.on.square",
                               id: "player.options.export",
                               subtitle: model.hasLocalCopy(track) ? nil : "Export uses the complete copy on this device.",
                               enabled: model.hasLocalCopy(track), showsChevron: true) {
                            AppNavigationIntent.perform(in: model) { path.append(.export) }
                        }
                    }
                    let settings = model.library.preferences.equalizer
                    let equalizerValue = model.equalizerProfiles.hasOverride(for: track.id) ? "This Song"
                        : settings.isEnabled ? model.equalizerPresetChoice(for: settings).settingsTitle : "Off"
                    option("Equalizer", symbol: "slider.vertical.3", id: "player.options.equalizer", subtitle: equalizerValue,
                           showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.equalizer) }
                    }

                    let deadline = model.player.sleepUntil?.formatted(date: .omitted, time: .shortened)
                    option("Sleep Timer", symbol: deadline == nil ? "moon.zzz" : "moon.zzz.fill", id: "player.sleepTimer",
                           subtitle: deadline.map { "Stops at \($0)" },
                            accessibilityLabel: deadline.map { "Sleep Timer · stops at \($0)" }, showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.sleep) }
                    }
                    if deadline != nil {
                        option("Cancel Sleep Timer", symbol: "xmark.circle", id: "player.sleepTimer.cancel") {
                            model.player.setSleepTimer(minutes: nil)
                            AppNavigationIntent.perform(in: model) { dismiss() }
                        }
                    }
                    if let nearby = model.nearbyDevices {
                        option("Devices", symbol: "laptopcomputer.and.iphone", id: "player.options.devices",
                               subtitle: nearby.peers.isEmpty ? nil : (nearby.peers.count == 1 ? "1 nearby" : "\(nearby.peers.count) nearby"),
                               showsChevron: true) {
                            AppNavigationIntent.perform(in: model) { path.append(.devices) }
                        }
                    }

                    if model.player.currentTrack?.id == track.id {
                        Divider().padding(.leading, 60)
                        let qualityPreference = model.library.preferences.audioQuality
                        let sourceSummary = SourceAudioQuality.playbackSummary(quality: model.player.sourceAudioQuality,
                            catalogSource: track.source, playbackSource: model.player.playbackSource)
                        PlayerOptionLabel(title: "Audio Quality", symbol: "waveform",
                            subtitle: "\(qualityPreference.settingsTitle) · \(sourceSummary)")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("player.options.audioQuality")
                        option("Reload Best Available Audio", symbol: "arrow.clockwise", id: "player.options.reloadAudioQuality",
                               subtitle: model.isOffline
                                   ? "Connect to check audio quality. Cached audio can still play."
                                   : qualityPreference.maximumBitRate == nil
                                       ? "Checks the source for this play. Keeps cached audio for fallback."
                                       : "Checks the source for this play, \(qualityPreference.detail.lowercased()). Keeps cached audio for fallback.",
                               enabled: !model.isOffline && model.player.canReloadAudioQuality) {
                            guard model.player.currentTrack?.id == track.id, !model.isOffline,
                                  model.player.canReloadAudioQuality else { return }
                            model.player.retry(preferBestAudio: true)
                            AppNavigationIntent.perform(in: model) { dismiss() }
                        }
                        PlayerCacheAvailability(identifier: "player.options.cache")
                            .padding(.leading, 60)
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                        if model.player.sponsorBlockSkipCount > 0 {
                            let skips = model.player.sponsorBlockSkipCount
                            PlayerOptionLabel(title: skips == 1 ? "Skipped 1 non-music section" : "Skipped \(skips) non-music sections",
                                              symbol: "forward.frame", subtitle: "SponsorBlock community markers for this play.")
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("player.options.sponsorBlock")
                        }
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("player.options.list")
    }

    @ViewBuilder
    private var reactionAndShareRows: some View {
        let superLiked = model.library.isSuperLiked(track)
        option(superLiked ? "Change to Like" : "Super Like", symbol: superLiked ? "heart.fill" : "bolt.heart.fill",
               id: "player.options.superLike",
               subtitle: superLiked ? "Keeps the like, drops the extra weight."
                   : "Counts more in your mixes and can download on its own.") {
            model.toggleSuperLike(track, surface: .more)
            AppNavigationIntent.perform(in: model) { dismiss() }
        }
        if !model.library.isFavorite(track) {
            let disliked = model.library.isDisliked(track)
            option(disliked ? "Allow Recommendations" : "Don't Recommend This Song",
                   symbol: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", id: "player.options.dislike",
                   subtitle: disliked ? "Lets this song back into mixes and radio." : "Keeps this song out of mixes and radio.") {
                guard !model.library.isFavorite(track) else { return }
                model.toggleDislike(track)
                AppNavigationIntent.perform(in: model) { dismiss() }
            }
        }
        option("Share Song", symbol: "square.and.arrow.up", id: "player.options.share",
               subtitle: "Preview the cover, song details and link", showsChevron: true) {
            AppNavigationIntent.perform(in: model) { path.append(.shareCard) }
        }
    }

    /// One row cycles Download, progress, Downloaded with Remove download, and a failed retry.
    @ViewBuilder
    private var downloadOption: some View {
        switch model.downloadState(for: track) {
        case .downloaded:
            option("Downloaded", symbol: "arrow.down.circle.fill", id: "player.options.download",
                   subtitle: "Remove Download", symbolColor: AppTheme.accent) {
                isConfirmingRemoval = true
            }
            .confirmationDialog("Remove Download?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) {
                    let track = track
                    Task { await model.removeDownload(track) }
                }
                .accessibilityIdentifier("player.options.download.remove")
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The song stays cached for now.")
            }
        case .downloading(let fraction):
            option("Downloading \(DownloadState.percent(fraction))", symbol: "arrow.down.circle", id: "player.options.download",
                   subtitle: "Tap to cancel", progress: fraction) {
                model.downloads.cancel(track.id)
            }
        case .queued, .waitingForWiFi:
            option(model.downloads.state(for: track.id)?.title ?? "Waiting", symbol: "arrow.down.circle.dotted", id: "player.options.download",
                   subtitle: "Tap to cancel") {
                model.downloads.cancel(track.id)
            }
        case .failed(let reason):
            option("Download Failed", symbol: "exclamationmark.arrow.circlepath", id: "player.options.download",
                   subtitle: "\(reason) Tap to retry.") {
                model.downloads.retry(track.id)
            }
        case nil:
            option("Download", symbol: "arrow.down.circle", id: "player.options.download",
                   subtitle: "Keeps this song on this device.") {
                model.download(track)
            }
        }
    }

    private var trackSummary: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.artworkURL, title: track.title, size: 44, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .appFont(.subheadline, weight: .semibold)
                    .lineLimit(2)
                Text(track.artistName)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var artists: some View {
        PlayerArtistRows(credits: track.allCredits, onArtist: onArtist)
    }

    private var playlists: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    option("New Playlist", symbol: "plus", id: "player.playlists.new", showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.newPlaylist) }
                    }
                    if !model.library.playlists.isEmpty { Divider().padding(.leading, 60) }
                    ForEach(model.library.playlists) { playlist in
                        let alreadyAdded = playlist.tracks.contains { $0.id == track.id }
                        option(playlist.name, symbol: "music.note.list", id: "player.playlist.\(playlist.id.uuidString)",
                               subtitle: alreadyAdded ? "Already added" : "\(playlist.tracks.count) songs", enabled: !alreadyAdded) {
                            addTrack(to: playlist.id)
                        }
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
                playlistError
            }
            .padding(20)
        }
        .accessibilityIdentifier("player.playlists.list")
    }

    private var newPlaylist: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add \(track.title) to a new playlist.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                TextField("Playlist name", text: $playlistName)
                    .appFont(.body)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isPlaylistNameFocused)
                    .onSubmit { createPlaylist() }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
                    .accessibilityIdentifier("player.playlist.name")
                Button(action: createPlaylist) {
                    Text("Create and Add Song")
                        .appFont(.body, weight: .semibold)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .appGlass(in: Capsule(), interactive: true)
                .disabled(trimmedPlaylistName.isEmpty)
                .accessibilityIdentifier("player.playlist.create")
                playlistError
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("player.playlist.editor")
        .onAppear { isPlaylistNameFocused = true }
    }

    @ViewBuilder
    private var playlistError: some View {
        if let message = model.library.errorMessage {
            Text(message)
                .appFont(.footnote)
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("player.playlist.error")
        }
    }

    private func option(_ title: String, symbol: String, id: String, subtitle: String? = nil,
                        accessibilityLabel: String? = nil, enabled: Bool = true, showsChevron: Bool = false,
                        symbolColor: Color? = nil, progress: Double? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlayerOptionLabel(title: title, symbol: symbol, subtitle: subtitle, showsChevron: showsChevron,
                              symbolColor: symbolColor, progress: progress)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityIdentifier(id)
    }

    private var trimmedPlaylistName: String { playlistName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func createPlaylist() {
        guard !trimmedPlaylistName.isEmpty else { return }
        let id = model.library.createPlaylist(name: trimmedPlaylistName, tracks: [track])
        finishAddingTrack(to: id)
    }

    private func addTrack(to id: UUID) {
        model.library.add(track, to: id)
        finishAddingTrack(to: id)
    }

    private func finishAddingTrack(to id: UUID) {
        guard model.library.errorMessage == nil,
              let playlist = model.library.playlists.first(where: { $0.id == id }),
              playlist.tracks.contains(where: { $0.id == track.id }) else { return }
        isPlaylistNameFocused = false
        model.showToast("Added to \(playlist.name)")
        AppNavigationIntent.perform(in: model) { dismiss() }
    }
}

@MainActor
struct PlayerOptionLabel: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var showsChevron = false
    var symbolColor: Color? = nil
    /// A thin bar under the title while a transfer runs.
    var progress: Double? = nil

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(symbolColor ?? AppTheme.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(AppTheme.primaryText)
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(AppTheme.accent)
                        .accessibilityHidden(true)
                }
                if let subtitle {
                    Text(subtitle)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }
}

@MainActor
private struct PlayerSleepTimerContent: View {
    @Environment(MusicAppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        List {
            if let until = model.player.sleepUntil {
                Section {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack {
                            Label("Music pauses in", systemImage: "moon.zzz.fill")
                                .appFont(.body)
                            Spacer()
                            Text(TimeText.duration(max(0, until.timeIntervalSince(context.date))))
                                .appFont(.body, weight: .medium)
                                .monospacedDigit()
                        }
                        .frame(minHeight: 56)
                    }
                    Button {
                        model.player.setSleepTimer(minutes: nil)
                        onDone()
                    } label: {
                        Text("Cancel Sleep Timer")
                            .appFont(.body, weight: .medium)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("player.sleepTimer.cancel")
                } header: {
                    Text("Timer Active").appFont(.caption)
                }
                .listRowBackground(AppTheme.surface)
            }

            Section {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                    Button {
                        model.player.setSleepTimer(minutes: minutes)
                        onDone()
                    } label: {
                        HStack {
                            Text(minutes == 60 ? "1 hour" : minutes == 120 ? "2 hours" : "\(minutes) minutes")
                                .appFont(.body, weight: .medium)
                                .foregroundStyle(AppTheme.primaryText)
                            Spacer()
                            Image(systemName: "moon")
                                .font(.system(size: 20))
                                .foregroundStyle(AppTheme.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("player.sleepTimer.\(minutes)")
                }
            } header: {
                Text("Stop Playing In").appFont(.caption)
            } footer: {
                Text("Music pauses when the timer ends.").appFont(.footnote)
            }
            .listRowBackground(AppTheme.surface)
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .accessibilityIdentifier("player.sleepTimer.list")
    }
}
