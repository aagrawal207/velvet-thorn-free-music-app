import AVKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
struct NowPlayingView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var artistLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16
    @State private var activeSheet: PlayerSheet?
    @State private var deferredAction: PlayerDeferredAction?
    @State private var isAirPlayPresented = false
    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0
    @State private var scrubTrackID: String?
    @State private var scrubQueueIndex: Int?
    @State private var dismissalOffset: CGFloat = 0
    @State private var isDismissing = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            ZStack {
                ZStack {
                    ArtworkBackdrop(url: model.player.currentTrack?.artworkURL, fallbackTint: artworkTint)
                    playerLayout.padding(geometry.safeAreaInsets)
                        .environment(\.secondaryTextColor, AppTheme.artworkSecondaryText)
                }
                .offset(y: dismissalOffset)
            }
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.presentation")
            .contentShape(Rectangle())
            .gesture(PlayerDismissPanGesture(
                isEnabled: activeSheet == nil && !isAirPlayPresented && !isScrubbing && !isDismissing,
                onChanged: updateDismissal,
                onEnded: { distance, velocity in finishDismissal(distance: distance, velocity: velocity, height: height) },
                onCancel: cancelDismissal
            ))
            .allowsHitTesting(!isDismissing)
        }
        .presentationBackground(.clear)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .accessibilityAction(.escape) { model.isPlayerPresented = false }
        .onAppear {
            dismissalOffset = 0
            isDismissing = false
        }
        .onChange(of: model.player.currentTrack?.id) { _, _ in
            resetScrub()
        }
        .onChange(of: model.player.currentIndex) { _, _ in resetScrub() }
        .onChange(of: effectiveDuration) { _, duration in
            if isScrubbing { scrubPosition = min(scrubPosition, duration) }
        }
        .onChange(of: activeSheet?.id) { _, id in
            if id != nil { cancelDismissal() }
        }
        .sheet(item: AppNavigationIntent.binding($activeSheet, in: model, identity: { $0?.id }), onDismiss: sheetDidDismiss) { sheet in
            // Lyrics and Queue fill the height; Options starts medium; browsing fits the available album and credits.
            switch sheet {
            case .lyrics:
                PlayerLyricsSheet()
                    .presentationDetents([.large])
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            case .queue:
                PlayerQueueSheet()
                    .presentationDetents([.large])
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            case .artists(let track):
                PlayerArtistPickerSheet(track: track, onArtist: { performAfterSheet(.artist($0)) })
                    .presentationCompactAdaptation(.sheet)
            case .browse(let track):
                PlayerArtistPickerSheet(track: track, onArtist: { performAfterSheet(.artist($0)) },
                                        onAlbum: { performAfterSheet(.album($0)) })
                    .presentationCompactAdaptation(.sheet)
            case .actions(let track, let route):
                PlayerOptionsSheet(track: track, initialRoute: route,
                                   onAlbum: { performAfterSheet(.album($0)) },
                                   onArtist: { performAfterSheet(.artist($0)) })
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }

    private var playerLayout: some View {
        GeometryReader { geometry in
            // Artwork sits beside the controls only in landscape; a tall regular-width window keeps the stacked
            // layout, centered, so a portrait iPad does not bottom-align a half-empty page.
            let regular = horizontalSizeClass == .regular
            let landscape = geometry.size.width > geometry.size.height

            VStack(spacing: 0) {
                topBar
                if let track = model.player.currentTrack {
                    if landscape {
                        let contentWidth = max(0, min(geometry.size.width - 48, regular ? 1040 : 900))
                        if regular { Spacer(minLength: 0) }
                        HStack(alignment: regular ? .center : .bottom, spacing: regular ? 48 : 24) {
                            VStack(spacing: 8) {
                                artworkArea(track)
                                if dynamicTypeSize.isAccessibilitySize { trackHeading(track) }
                            }
                            playerDetails(track, compact: true, showsHeading: !dynamicTypeSize.isAccessibilitySize)
                                .frame(width: min(regular ? 480 : 430, max(0, contentWidth - 24) * 0.55))
                        }
                        .padding(.top, 8)
                        if regular { Spacer(minLength: 0) }
                    } else {
                        if regular { Spacer(minLength: 0) }
                        artworkArea(track)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                        playerDetails(track, compact: false)
                        if regular { Spacer(minLength: 0) }
                    }
                } else {
                    EmptyStateView(symbol: "music.note", title: "Make room for music",
                                   message: "Choose a song from Home, Search, or your library to start listening.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: landscape ? (regular ? 1040 : 900) : (regular ? 620 : 500))
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.screen")
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                model.isPlayerPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("player.close")

            VStack(spacing: 2) {
                let context = model.radioSessionLabel ?? model.player.currentTrack?.albumTitle ?? "Breezy"
                Text("NOW PLAYING")
                    .appFont(.caption2, weight: .bold)
                    .tracking(1.6)
                    .lineLimit(1)
                Text((model.isOffline ? "Offline · " : "") + context)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.artworkSecondaryText)
                    .lineLimit(1)
                    .accessibilityIdentifier(model.isOffline ? "player.offline" : "player.context")
            }
            .frame(maxWidth: .infinity)

            if let track = model.player.currentTrack {
                Button {
                    presentSheet(.actions(track, .options))
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options for \(track.title)")
                .accessibilityIdentifier("player.menu")
            } else {
                Color.clear.frame(width: 52, height: 52)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
    }

    private func artworkArea(_ track: Track) -> some View {
        GeometryReader { geometry in
            let size = artworkSize(geometry.size)
            ArtworkView(url: track.artworkURL, title: track.title, size: size, cornerRadius: AppCorner.compact)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                .frame(width: size, height: size)
                .overlay(alignment: .bottom) {
                    if let message = model.player.errorMessage {
                        playbackError(message).padding(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { RootMessageBanner() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func playerDetails(_ track: Track, compact: Bool, showsHeading: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsHeading { trackHeading(track) }
            seekControls(track)
                .padding(.top, compact ? 4 : 8)
            transportControls
                .padding(.top, compact ? 4 : 12)
            secondaryControls(track)
                .padding(.top, compact ? 4 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func trackHeading(_ track: Track) -> some View {
        let plays = PlayCountText.plays(model.player.currentPlayCount)
        return VStack(alignment: .leading, spacing: 0) {
            Text(track.title)
                .appFont(.title2, weight: .bold)
                .lineLimit(1)
                .frame(height: titleLineHeight)
                .accessibilityIdentifier("player.track.\(track.id)")
            Button {
                goToArtist(track)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if track.isExplicit {
                        Image(systemName: "e.square.fill")
                            .font(.caption)
                            .accessibilityLabel("Explicit")
                    }
                    Text(track.artistName)
                        .appFont(.subheadline)
                        .lineLimit(1)
                }
                .foregroundStyle(AppTheme.artworkSecondaryText)
                .frame(maxWidth: .infinity, minHeight: max(44, artistLineHeight), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(track.allCredits.isEmpty)
            .accessibilityLabel("Go to artist, \(track.artistName)")
            .accessibilityIdentifier("player.artistName")
            ZStack(alignment: .leading) {
                if let plays {
                    Text(plays)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.artworkSecondaryText)
                        .lineLimit(1)
                        .accessibilityIdentifier("player.playCount")
                }
            }
            .frame(maxWidth: .infinity, minHeight: captionLineHeight, maxHeight: captionLineHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func seekControls(_ track: Track) -> some View {
        // The row is as tall as the heart's 52-point target; the time labels keep their old distance from the bar
        // by overlapping the row's empty bottom edge.
        VStack(spacing: -6) {
            PlayerProgressRow(
                position: displayedPosition, duration: effectiveDuration, isScrubbing: isScrubbing,
                liked: model.library.isFavorite(track),
                onToggleLike: { model.library.toggleFavorite(track) },
                onEditingChanged: scrubEditingChanged,
                onValueChanged: { value in
                    guard isScrubbing, value.isFinite else { return }
                    scrubPosition = min(max(value, 0), effectiveDuration)
                },
                onCancel: resetScrub,
                onAccessibilitySeek: { value in
                    guard effectiveDuration > 0, value.isFinite else { return }
                    resetScrub()
                    model.player.seek(to: min(max(value, 0), effectiveDuration))
                }
            )
            .id(model.player.currentTrack?.id)
            .id(model.player.currentIndex)
            .frame(height: PlayerProgressTrail.Layout.standard.rowHeight)

            HStack {
                Text(TimeText.duration(displayedPosition))
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(TimeText.duration(displayedPosition))
                    .accessibilityIdentifier("player.elapsed")
                Spacer()
                Text(effectiveDuration > 0 ? "−\(TimeText.duration(max(0, effectiveDuration - displayedPosition)))" : "--:--")
                    .accessibilityLabel("Remaining time")
                    .accessibilityValue(effectiveDuration > 0 ? TimeText.duration(max(0, effectiveDuration - displayedPosition)) : "Unknown")
                    .accessibilityIdentifier("player.remaining")
            }
            .appFont(.caption2, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(AppTheme.artworkSecondaryText)
            .frame(height: captionLineHeight)
        }
    }

    private var transportControls: some View {
        GeometryReader { geometry in
            // Shuffle and repeat live in the Queue sheet, so the three transport targets can grow and stay centered.
            // The buttons sit straight on the artwork backdrop; a container here would cut the page into panels.
            let target = min(64, max(52, (geometry.size.width - 96) / 4))
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                transportButton(symbol: "backward.end.fill", label: "Previous song", id: "player.previous", target: target) {
                    model.player.previous()
                }
                Spacer(minLength: 0)
                playButton
                Spacer(minLength: 0)
                transportButton(symbol: "forward.end.fill", label: "Next song", id: "player.next", target: target) {
                    model.player.next()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 88)
    }

    private var playButton: some View {
        Button {
            model.player.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(AppTheme.primaryText)
                Image(systemName: playbackActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .offset(x: playbackActive ? 0 : 2)
                    .opacity(model.player.isLoading ? 0 : 1)
                ProgressView()
                    .tint(AppTheme.background)
                    .scaleEffect(1.2)
                    .opacity(model.player.isLoading ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AppTheme.background)
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackActive ? "Pause" : "Play")
        .accessibilityValue(model.player.isLoading ? "Loading" : "")
        .accessibilityIdentifier("player.playPause")
    }

    private func transportButton(symbol: String, label: String, id: String,
                                 target: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
                .frame(width: target, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func secondaryControls(_ track: Track) -> some View {
        HStack(spacing: 0) {
            PlayerAirPlayPicker(accentColor: model.library.preferences.accent.color) { presented in
                if presented { AppNavigationIntent.perform(in: model) { cancelDismissal() } }
                isAirPlayPresented = presented
            }
            // AVKit owns its route-state artwork; size the visible picker instead of adding a second button image.
            .frame(width: 44, height: 44)
            .frame(width: 56, height: 56)
            .frame(maxWidth: .infinity)
            .onDisappear { isAirPlayPresented = false }

            playerAction("Lyrics", symbol: "quote.bubble", id: "player.lyrics") {
                presentSheet(.lyrics)
            }

            playerAction("Album and artists", symbol: "square.stack", id: "player.browse",
                         enabled: track.albumCollection != nil || !track.allCredits.isEmpty) {
                presentSheet(.browse(track))
            }

            playerAction("Queue", symbol: "text.line.first.and.arrowtriangle.forward", id: "player.queue") {
                presentSheet(.queue)
            }
        }
    }

    /// The artist-name link can open one credit directly; the combined control always offers its choices.
    private func goToArtist(_ track: Track) {
        let credits = track.allCredits
        guard let credit = credits.first else { return }
        if credits.count == 1 {
            performAfterSheet(.artist(credit))
        } else {
            presentSheet(.artists(track))
        }
    }

    private func presentSheet(_ sheet: PlayerSheet) {
        AppNavigationIntent.perform(in: model) { activeSheet = sheet }
    }

    private func playerAction(_ title: String, symbol: String, id: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTheme.artworkSecondaryText)
                .opacity(enabled ? 1 : 0.4)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    private func performAfterSheet(_ action: PlayerDeferredAction) {
        // UIKit must finish dismissing the sheet before collection navigation closes the player cover.
        AppNavigationIntent.perform(in: model) {
            if activeSheet != nil {
                deferredAction = action
                activeSheet = nil
            } else {
                perform(action)
            }
        }
    }

    private func sheetDidDismiss() {
        guard let action = deferredAction else { return }
        deferredAction = nil
        perform(action)
    }

    private func perform(_ action: PlayerDeferredAction) {
        switch action {
        case .album(let album): model.open(album)
        case .artist(let credit):
            model.isPlayerPresented = false
            Task { await model.openArtist(credit) }
        }
    }

    private func updateDismissal(_ distance: CGFloat) {
        guard activeSheet == nil, !isAirPlayPresented, !isScrubbing, !isDismissing else { return }
        dismissalOffset = max(0, distance)
    }

    private func finishDismissal(distance: CGFloat, velocity: CGPoint, height: CGFloat) {
        guard activeSheet == nil, !isAirPlayPresented, !isScrubbing, !isDismissing else {
            cancelDismissal()
            return
        }
        let flick = distance >= PlayerDismissPanRecognizer.minimumFlickDistance
            && velocity.y >= PlayerDismissPanRecognizer.minimumFlickVelocity && velocity.y > abs(velocity.x)
        guard velocity.y > -PlayerDismissPanRecognizer.minimumFlickVelocity, distance >= 70 || flick else {
            cancelDismissal()
            return
        }
        isDismissing = true
        if reduceMotion {
            completeDismissal()
        } else {
            withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
                dismissalOffset = max(height, dismissalOffset)
            } completion: {
                completeDismissal()
            }
        }
    }

    private func cancelDismissal() {
        guard !isDismissing, dismissalOffset != 0 else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)) {
            dismissalOffset = 0
        }
    }

    private func completeDismissal() {
        // The drag owns the exit animation; a second cover transition would delay the return to the library.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.isPlayerPresented = false }
    }

    private func playbackError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Playback needs another try", systemImage: "exclamationmark.circle")
                .appFont(.subheadline, weight: .semibold)
            Text(message)
                .appFont(.caption)
                .foregroundStyle(AppTheme.artworkSecondaryText)
                .lineLimit(2)
            Button("Retry playback", systemImage: "arrow.clockwise") {
                model.player.retry()
            }
            .appFont(.subheadline, weight: .semibold)
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .appGlass(in: Capsule(), interactive: true)
            .accessibilityIdentifier("player.retry")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appGlass(in: RoundedRectangle(cornerRadius: AppCorner.card))
    }

    private func scrubEditingChanged(_ editing: Bool, value: TimeInterval) {
        if editing {
            guard !isScrubbing else { return }
            scrubPosition = playbackPosition
            scrubTrackID = model.player.currentTrack?.id
            scrubQueueIndex = model.player.currentIndex
            isScrubbing = true
        } else {
            let target = min(max(value, 0), effectiveDuration)
            let shouldSeek = isScrubbing && scrubTrackID == model.player.currentTrack?.id
                && scrubQueueIndex == model.player.currentIndex && value.isFinite && effectiveDuration > 0
            resetScrub()
            if shouldSeek { model.player.seek(to: target) }
        }
    }

    private func resetScrub() {
        isScrubbing = false
        scrubPosition = 0
        scrubTrackID = nil
        scrubQueueIndex = nil
    }

    private var playbackActive: Bool { model.player.isPlaying || model.player.isLoading }

    private var artworkTint: Color {
        switch model.player.currentTrack?.language {
        case .hindi: AppTheme.gold
        case .english: AppTheme.violet
        case nil: AppTheme.accent
        }
    }

    private var effectiveDuration: TimeInterval {
        let duration = model.player.duration
        if duration.isFinite && duration > 0 { return duration }
        if let fallback = model.player.currentTrack?.duration, fallback.isFinite && fallback > 0 { return fallback }
        return 0
    }

    private var playbackPosition: TimeInterval {
        let position = model.player.position
        guard position.isFinite else { return 0 }
        return effectiveDuration > 0 ? min(max(position, 0), effectiveDuration) : max(position, 0)
    }

    private var displayedPosition: TimeInterval {
        isScrubbing ? min(max(scrubPosition, 0), effectiveDuration) : playbackPosition
    }

    private func artworkSize(_ size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite else { return 0 }
        // Large iPads have the room for bigger art; phones stay capped so the controls keep their space.
        return max(0, min(size.width, size.height, horizontalSizeClass == .regular ? 560 : 420))
    }

    private enum PlayerSheet: Identifiable {
        case lyrics, queue
        case artists(Track)
        case browse(Track)
        case actions(Track, PlayerOptionsRoute)

        var id: String {
            switch self {
            case .lyrics: "lyrics"
            case .queue: "queue"
            case .artists(let track): "artists.\(track.id)"
            case .browse(let track): "browse.\(track.id)"
            case .actions(let track, let route): "actions.\(track.id).\(route.rawValue)"
            }
        }
    }

    private enum PlayerDeferredAction {
        case album(MusicCollection), artist(ArtistCredit)
    }
}

private enum PlayerOptionsRoute: String, Hashable {
    case options, artists, playlists, newPlaylist, sleep

    var title: String {
        switch self {
        case .options: "Song options"
        case .artists: "Go to artist"
        case .playlists: "Add to playlist"
        case .newPlaylist: "New playlist"
        case .sleep: "Sleep timer"
        }
    }
}

@MainActor
private struct PlayerOptionsSheet: View {
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
            if routes.last == .newPlaylist {
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
            case .playlists: playlists
            case .newPlaylist: newPlaylist
            case .sleep: PlayerSleepTimerContent(onDone: { AppNavigationIntent.perform(in: model) { dismiss() } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.background)
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!path.isEmpty)
        .toolbar {
            if !path.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        guard !path.isEmpty else { return }
                        AppNavigationIntent.perform(in: model) {
                            isPlaylistNameFocused = false
                            path.removeLast()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .appFont(.body)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("player.options.back")
                }
            }
        }
        .appSheetDoneButton(id: "player.options.toolbarDone") { AppNavigationIntent.perform(in: model) { dismiss() } }
    }

    private var options: some View {
        ScrollView {
            VStack(spacing: 12) {
                trackSummary
                VStack(spacing: 0) {
                    option("Go to album", symbol: "square.stack", id: "player.options.album",
                           enabled: track.albumCollection != nil, showsChevron: true) {
                        if let album = track.albumCollection { onAlbum(album) }
                    }
                    option("Go to artist", symbol: "person.crop.circle", id: "player.options.artist",
                           enabled: !track.allCredits.isEmpty, showsChevron: true) {
                        if track.allCredits.count == 1, let credit = track.allCredits.first {
                            onArtist(credit)
                        } else {
                            AppNavigationIntent.perform(in: model) { path.append(.artists) }
                        }
                    }
                    option("Add to playlist", symbol: "music.note.list", id: "player.options.playlist", showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.playlists) }
                    }
                    Divider().padding(.leading, 60)

                    let deadline = model.player.sleepUntil?.formatted(date: .omitted, time: .shortened)
                    option("Sleep timer", symbol: deadline == nil ? "moon.zzz" : "moon.zzz.fill", id: "player.sleepTimer",
                           subtitle: deadline.map { "Stops at \($0)" },
                           accessibilityLabel: deadline.map { "Sleep timer · stops at \($0)" }, showsChevron: true) {
                        AppNavigationIntent.perform(in: model) { path.append(.sleep) }
                    }
                    if deadline != nil {
                        option("Cancel sleep timer", symbol: "xmark.circle", id: "player.sleepTimer.cancel") {
                            model.player.setSleepTimer(minutes: nil)
                            AppNavigationIntent.perform(in: model) { dismiss() }
                        }
                    }
                    Divider().padding(.leading, 60)

                    if model.player.currentTrack?.id == track.id {
                        PlayerOptionLabel(title: "Audio quality", symbol: "waveform",
                            subtitle: model.player.sourceAudioQuality?.summary ?? "Quality information unavailable")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("player.options.audioQuality")
                        PlayerCacheAvailability(identifier: "player.options.cache")
                            .padding(.leading, 60)
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                        option("Reload best available audio", symbol: "arrow.clockwise", id: "player.options.reloadAudioQuality",
                               subtitle: model.isOffline
                                   ? "Connect to check audio quality. Cached audio can still play."
                                   : "Checks the source for this play. Keeps cached audio for fallback.",
                               enabled: !model.isOffline && model.player.canReloadAudioQuality) {
                            guard model.player.currentTrack?.id == track.id, !model.isOffline,
                                  model.player.canReloadAudioQuality else { return }
                            model.player.retry(preferBestAudio: true)
                            AppNavigationIntent.perform(in: model) { dismiss() }
                        }
                        Divider().padding(.leading, 60)
                    }

                    if !model.library.isFavorite(track) {
                        let disliked = model.library.isDisliked(track)
                        option(disliked ? "Remove dislike" : "Dislike song",
                               symbol: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", id: "player.options.dislike") {
                            guard !model.library.isFavorite(track) else { return }
                            model.toggleDislike(track)
                            AppNavigationIntent.perform(in: model) { dismiss() }
                        }
                    }
                    if let url = track.shareURL {
                        ShareLink(item: url) {
                            PlayerOptionLabel(title: "Share song", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(AppNavigationIntentButtonStyle(.plain))
                        .accessibilityLabel("Share song")
                        .accessibilityIdentifier("player.options.share")
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("player.options.list")
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
                    option("New playlist", symbol: "plus", id: "player.playlists.new", showsChevron: true) {
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
                    Text("Create and add song")
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
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlayerOptionLabel(title: title, symbol: symbol, subtitle: subtitle, showsChevron: showsChevron)
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
private struct PlayerOptionLabel: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var showsChevron = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(AppTheme.primaryText)
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

/// Progress bar and like button on one line: the bar runs into the heart's outline, which the last stretch of the
/// song traces, so a finished song shows a complete heart the listener can tap.
@MainActor
private struct PlayerProgressRow: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let position: TimeInterval
    let duration: TimeInterval
    let isScrubbing: Bool
    let liked: Bool
    let onToggleLike: () -> Void
    let onEditingChanged: (Bool, TimeInterval) -> Void
    let onValueChanged: (TimeInterval) -> Void
    let onCancel: () -> Void
    let onAccessibilitySeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let trail = PlayerProgressTrail(rowWidth: geometry.size.width)
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            HStack(spacing: 0) {
                seekArea(trail, progress: progress)
                heartButton(trail, progress: progress)
            }
            .overlay(alignment: .topLeading) {
                if isScrubbing {
                    let point = trail.point(atProgress: progress)
                    Circle()
                        .fill(AppTheme.primaryText)
                        .overlay(Circle().strokeBorder(AppTheme.accent, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(point)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Enough tint to read as liked over any backdrop while the full-accent outline trace stays distinct.
    private static let likedFillOpacity = 0.45

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: PlayerProgressTrail.Layout.standard.lineWidth, lineCap: .round, lineJoin: .round)
    }

    private var trackColor: Color {
        AppTheme.artworkSecondaryText.opacity(contrast == .increased ? 0.6 : 0.35)
    }

    private func seekArea(_ trail: PlayerProgressTrail, progress: CGFloat) -> some View {
        ZStack {
            Path(trail.barProgressPath(1)).stroke(trackColor, style: stroke)
            Path(trail.barProgressPath(progress)).stroke(AppTheme.accent, style: stroke)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // The recognizer keeps following a drag past the bar, so the heart's stretch of the song stays reachable.
        .gesture(PlayerSeekPanGesture(
            onChanged: { x in
                guard duration > 0, x.isFinite else { return }
                onEditingChanged(true, position)
                onValueChanged(duration * trail.progress(atX: x))
            },
            onEnded: { x in
                guard duration > 0, x.isFinite else {
                    onCancel()
                    return
                }
                onEditingChanged(false, duration * trail.progress(atX: x))
            },
            onCancel: onCancel
        ))
        .onTapGesture { location in
            guard duration > 0 else { return }
            onEditingChanged(true, position)
            onEditingChanged(false, duration * trail.progress(atX: location.x))
        }
        .opacity(duration > 0 ? 1 : 0.45)
        .accessibilityRepresentation {
            // Accessibility adjustments seek explicitly; layout must not write back to the player.
            Slider(value: .constant(position), in: 0...max(duration, 1)) {
                Text("Playback position").appFont(.body)
            }
            .frame(minHeight: 44)
            .accessibilityValue("\(TimeText.duration(position)) of \(duration > 0 ? TimeText.duration(duration) : "unknown duration")")
            .accessibilityIdentifier("player.seek")
            .accessibilityAdjustableAction { direction in
                guard duration > 0 else { return }
                switch direction {
                case .increment: onAccessibilitySeek(min(position + 10, duration))
                case .decrement: onAccessibilitySeek(max(position - 10, 0))
                @unknown default: break
                }
            }
            .disabled(duration <= 0)
        }
        .disabled(duration <= 0)
    }

    private func heartButton(_ trail: PlayerProgressTrail, progress: CGFloat) -> some View {
        let layout = trail.layout
        return Button(action: onToggleLike) {
            ZStack {
                // Paths are in row coordinates; the label starts at the slot's leading edge. A liked song tints
                // the inside; the outline and its trace stay readable on top of that tint.
                let heart = Path(trail.heartPath).offsetBy(dx: -trail.heartSlotOrigin, dy: 0)
                heart.fill(AppTheme.accent).opacity(liked ? Self.likedFillOpacity : 0)
                heart.stroke(trackColor, style: stroke)
                if let traced = trail.heartProgressPath(progress) {
                    Path(traced).offsetBy(dx: -trail.heartSlotOrigin, dy: 0).stroke(AppTheme.accent, style: stroke)
                }
            }
            // The like state flips at once; only the press scale in the button style animates.
            .transaction { $0.animation = nil }
            .frame(width: layout.heartSlotWidth, height: layout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerHeartButtonStyle(anchor: UnitPoint(
            x: (trail.heartFrame.midX - trail.heartSlotOrigin) / layout.heartSlotWidth,
            y: trail.heartFrame.midY / layout.rowHeight)))
        .accessibilityLabel(liked ? "Unlike this song" : "Like this song")
        .accessibilityAddTraits(liked ? .isSelected : [])
        .accessibilityIdentifier("player.like")
    }
}

/// Presses shrink the heart glyph in place instead of dimming, since the unliked glyph is only an outline.
private struct PlayerHeartButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let anchor: UnitPoint

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1, anchor: anchor)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
private struct PlayerSeekPanGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancel: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(context.converter.localLocation.x)
        case .ended: onEnded(context.converter.localLocation.x)
        case .cancelled, .failed: onCancel()
        case .possible: break
        @unknown default: onCancel()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view?.window)
            // Only deliberate horizontal pans should change the playback position.
            return abs(translation.x) > abs(translation.y)
        }
    }
}

@MainActor
private struct PlayerDismissPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGPoint) -> Void
    let onCancel: () -> Void

    func makeUIGestureRecognizer(context: Context) -> PlayerDismissPanRecognizer {
        let recognizer = PlayerDismissPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PlayerDismissPanRecognizer, context: Context) {
        if recognizer.isEnabled != isEnabled { recognizer.isEnabled = isEnabled }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: PlayerDismissPanRecognizer, context: Context) {
        // Window coordinates stay fixed while the player follows the finger.
        let translation = recognizer.translation(in: recognizer.view?.window)
        switch recognizer.state {
        case .began, .changed:
            recognizer.captureFlickVelocity()
            onChanged(translation.y)
        case .ended: onEnded(translation.y, recognizer.releaseVelocity)
        case .cancelled, .failed: onCancel()
        case .possible: break
        @unknown default: onCancel()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view?.window)
            // Lock direction by travel, so slow drags work and horizontal seeks stay horizontal.
            return abs(translation.y) > abs(translation.x) * 1.15
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

@MainActor
private final class PlayerDismissPanRecognizer: UIPanGestureRecognizer {
    static let minimumFlickDistance: CGFloat = 24
    static let minimumFlickVelocity: CGFloat = 550
    private var origin: CGPoint?
    private var velocitySample: (point: CGPoint, time: TimeInterval)?
    private var recentFlick: (velocity: CGPoint, time: TimeInterval)?
    private var maximumTravel: CGFloat = 0
    private var currentTravel: CGFloat = 0
    private var latestTouchTime: TimeInterval = 0
    private var lastForwardTime: TimeInterval = 0

    var releaseVelocity: CGPoint {
        let current = velocity(in: view?.window)
        guard current.y > -Self.minimumFlickVelocity else { return current }
        // Release may report zero speed; retain actual recent motion, but expire a held or reversed flick.
        guard let recentFlick, latestTouchTime - recentFlick.time <= 0.2 else {
            return CGPoint(x: current.x, y: min(current.y, 0))
        }
        return recentFlick.velocity
    }

    func captureFlickVelocity() {
        guard lastForwardTime == latestTouchTime else { return }
        qualifyFlick(velocity(in: view?.window), at: latestTouchTime)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first {
            let point = touch.location(in: view?.window)
            origin = point
            velocitySample = (point, touch.timestamp)
            maximumTravel = 0
            currentTravel = 0
            latestTouchTime = touch.timestamp
            lastForwardTime = 0
            recentFlick = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first {
            for sample in event.coalescedTouches(for: touch) ?? [touch] { record(sample) }
            record(touch)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first { record(touch) }
        super.touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        origin = nil
        velocitySample = nil
        recentFlick = nil
        maximumTravel = 0
        currentTravel = 0
        latestTouchTime = 0
        lastForwardTime = 0
    }

    private func record(_ touch: UITouch) {
        guard let origin, touch.timestamp >= latestTouchTime else { return }
        let point = touch.location(in: view?.window)
        latestTouchTime = touch.timestamp
        if point.y - origin.y > currentTravel { lastForwardTime = touch.timestamp }
        currentTravel = point.y - origin.y
        if currentTravel <= maximumTravel - 8 {
            recentFlick = nil
            maximumTravel = currentTravel
        } else {
            maximumTravel = max(maximumTravel, currentTravel)
        }
        guard let previous = velocitySample, touch.timestamp > previous.time else { return }
        let delta = CGPoint(x: point.x - previous.point.x, y: point.y - previous.point.y)
        if delta == .zero {
            velocitySample = (point, touch.timestamp)
        } else if max(abs(delta.x), abs(delta.y)) >= 4 {
            let duration = CGFloat(touch.timestamp - previous.time)
            // Touch timestamps survive main-thread delays; callback arrival times do not measure finger speed.
            qualifyFlick(CGPoint(x: delta.x / duration, y: delta.y / duration), at: touch.timestamp)
            velocitySample = (point, touch.timestamp)
        }
    }

    private func qualifyFlick(_ velocity: CGPoint, at time: TimeInterval) {
        if velocity.y <= -Self.minimumFlickVelocity { recentFlick = nil }
        guard currentTravel >= Self.minimumFlickDistance,
              velocity.y >= Self.minimumFlickVelocity, velocity.y > abs(velocity.x) else { return }
        recentFlick = (velocity, time)
    }
}

/// The visible AVKit button owns route presentation and the iPad popover anchor.
@MainActor
private final class PlayerAirPlayTrigger: NSObject, @MainActor AVRoutePickerViewDelegate {
    var onPresentationChanged: (Bool) -> Void = { _ in }

    func attach(to picker: AVRoutePickerView) {
        picker.delegate = self
        picker.layoutIfNeeded()
        guard let button = Self.button(in: picker) else { return }
        button.accessibilityLabel = "AirPlay and audio output"
        button.accessibilityIdentifier = "player.airplay"
    }

    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        onPresentationChanged(true)
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        onPresentationChanged(false)
    }

    private static func button(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let nested = button(in: subview) { return nested }
        }
        return nil
    }
}

@MainActor
private struct PlayerAirPlayPicker: UIViewRepresentable {
    let accentColor: Color
    let onPresentationChanged: (Bool) -> Void

    func makeCoordinator() -> PlayerAirPlayTrigger { PlayerAirPlayTrigger() }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.airplay.anchor"
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(AppTheme.artworkSecondaryText)
        uiView.activeTintColor = UIColor(accentColor)
        context.coordinator.onPresentationChanged = onPresentationChanged
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: AVRoutePickerView, coordinator: PlayerAirPlayTrigger) {
        uiView.delegate = nil
    }
}

@MainActor
private struct PlayerLyricsSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let track = model.player.currentTrack {
                    LyricsView(track: track)
                        .id(track.id)
                } else {
                    EmptyStateView(symbol: "quote.bubble", title: "Choose a song first",
                                   message: "Lyrics follow the song in your player.")
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "lyrics.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
    }
}

/// Short album/credit lists fit their content; from six credits on the sheet scrolls and offers the full height.
@MainActor
private struct PlayerArtistPickerSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let onArtist: (ArtistCredit) -> Void
    var onAlbum: ((MusicCollection) -> Void)? = nil
    @State private var fittedHeight: CGFloat?

    private var credits: [ArtistCredit] { track.allCredits }
    private var album: MusicCollection? { onAlbum == nil ? nil : track.albumCollection }
    private var identifier: String { onAlbum == nil ? "player.artists" : "player.browse" }

    var body: some View {
        NavigationStack {
            PlayerArtistRows(credits: credits, onArtist: onArtist, album: album, onAlbum: onAlbum,
                             onFittedHeight: { fittedHeight = $0 })
                .navigationTitle(onAlbum == nil ? "Go to artist" : "Album and artists")
                .navigationBarTitleDisplayMode(.inline)
                .appSheetDoneButton(id: "\(identifier).done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .presentationDetents(detents)
        // Regular widths present a form sheet; fitting it vertically keeps the same content-sized feel as the phone.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).sheet")
    }

    private var detents: Set<PresentationDetent> {
        let height = fittedHeight ?? PlayerArtistRows.estimatedHeight(rows: credits.count, hasAlbum: album != nil)
        return credits.count > PlayerArtistRows.fittedRowLimit ? [.height(height), .large] : [.height(height)]
    }
}

/// Artist choices as a surface card of TrackRow-like rows, shared by the picker sheet and the options page.
@MainActor
private struct PlayerArtistRows: View {
    @Environment(MusicAppModel.self) private var model
    static let fittedRowLimit = 5
    private static let rowHeight: CGFloat = 56
    private static let cardPadding = EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20)
    private static let estimatedBarHeight: CGFloat = 56
    private static let sectionSpacing: CGFloat = 12

    let credits: [ArtistCredit]
    let onArtist: (ArtistCredit) -> Void
    var album: MusicCollection? = nil
    var onAlbum: ((MusicCollection) -> Void)? = nil
    /// Includes the optional album, navigation bar and the first `fittedRowLimit` artist rows.
    var onFittedHeight: ((CGFloat) -> Void)? = nil
    @State private var rowHeights: [Int: CGFloat] = [:]
    @State private var albumHeight: CGFloat = Self.rowHeight
    @State private var barHeight: CGFloat = Self.estimatedBarHeight

    static func estimatedHeight(rows: Int, hasAlbum: Bool = false) -> CGFloat {
        estimatedBarHeight + cardPadding.top + cardPadding.bottom + CGFloat(min(rows, fittedRowLimit)) * rowHeight
            + (hasAlbum ? rowHeight + (rows > 0 ? sectionSpacing : 0) : 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Self.sectionSpacing) {
                if let album, let onAlbum {
                    Button { onAlbum(album) } label: {
                        PlayerOptionLabel(title: "Go to album", symbol: "square.stack", subtitle: album.title, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to album")
                    .accessibilityValue(album.title)
                    .accessibilityIdentifier("player.browse.album")
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height.isFinite, height > 0 else { return }
                        albumHeight = height
                        reportFittedHeight()
                    }
                }

                if !credits.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                            Button {
                                onArtist(credit)
                            } label: {
                                HStack(spacing: 12) {
                                    PlayerArtistArtwork(credit: credit, resolver: model.artistArtwork)
                                    Text(credit.name)
                                        .appFont(.body, weight: .medium)
                                        .foregroundStyle(AppTheme.primaryText)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(credit.name)
                            .accessibilityIdentifier("player.artist.\(index)")
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                guard height.isFinite, height > 0 else { return }
                                rowHeights[index] = height
                                reportFittedHeight()
                            }
                        }
                    }
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
                }
            }
            .padding(Self.cardPadding)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
            // Inside the sheet the top inset is the navigation bar, which the fitted detent has to include.
            barHeight = inset > 0 ? inset : Self.estimatedBarHeight
            reportFittedHeight()
        }
        .accessibilityIdentifier(onAlbum == nil ? "player.artists.list" : "player.browse.list")
    }

    private func reportFittedHeight() {
        guard let onFittedHeight else { return }
        let rows = (0..<min(credits.count, Self.fittedRowLimit)).reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? Self.rowHeight) }
        let albumSection = album != nil && onAlbum != nil ? albumHeight + (credits.isEmpty ? 0 : Self.sectionSpacing) : 0
        onFittedHeight(barHeight + Self.cardPadding.top + Self.cardPadding.bottom + rows + albumSection)
    }
}

@MainActor
private struct PlayerArtistArtwork: View {
    let credit: ArtistCredit
    let resolver: ArtistArtworkResolver
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var imageCredit: ArtistCredit?
    @State private var generation = UUID()

    var body: some View {
        ZStack {
            Color.clear
            if imageCredit == credit, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: credit, priority: .utility) {
            guard !Task.isCancelled else { return }
            let request = UUID()
            generation = request
            image = nil
            imageCredit = nil
            let loaded = await resolver.image(for: credit, maxPixels: Int((44 * displayScale).rounded(.up)))
            guard !Task.isCancelled, generation == request else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                image = loaded
                imageCredit = credit
            }
        }
        .onDisappear {
            generation = UUID()
            image = nil
            imageCredit = nil
        }
    }
}

@MainActor
private struct PlayerQueueSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editMode: EditMode = .inactive
    @State private var playlistDraft: UserPlaylist?

    var body: some View {
        NavigationStack {
            Group {
                if model.player.queue.isEmpty {
                    EmptyStateView(symbol: "music.note.list", title: "An open queue",
                                   message: "Use a song's menu to play it next or add it to the end of your queue.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                } else {
                    List {
                        Section {
                            playbackModeControls
                                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("queue.controls")
                            PlayerCacheAvailability(identifier: "queue.cache")
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        Section {
                            let autoplayIDs = model.player.autoplayTrackIDs
                            let firstAutoplayIndex = model.player.queue.firstIndex { autoplayIDs.contains($0.id) }
                            ForEach(Array(model.player.queue.enumerated()), id: \.offset) { index, track in
                                queueRow(track, at: index, isAutoplay: autoplayIDs.contains(track.id),
                                         startsAutoplay: index == firstAutoplayIndex)
                                    .listRowBackground(index == model.player.currentIndex ? AppTheme.accent.opacity(0.09) : AppTheme.background)
                            }
                            .onDelete { offsets in
                                for index in offsets.sorted(by: >) { model.player.removeFromQueue(at: index) }
                            }
                            .onMove { offsets, destination in
                                model.player.moveQueue(from: offsets, to: destination)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let station = model.radioSessionLabel {
                                    Text(station)
                                        .appFont(.subheadline, weight: .semibold)
                                        .foregroundStyle(AppTheme.accent)
                                        .accessibilityIdentifier("queue.radio")
                                }
                                Text("\(model.player.queue.count) songs · \(model.player.currentIndex + 1) of \(model.player.queue.count)")
                                    .appFont(.caption)
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Tap to play. Swipe to remove, Edit to reorder.")
                                    .appFont(.footnote)
                                if model.player.isRadioSession {
                                    continuationRetry(error: model.radioContinuationError, isContinuing: model.isContinuingRadio,
                                                      id: "queue.radio.retry") { model.retryRadioContinuation() }
                                } else {
                                    continuationRetry(error: model.autoplayContinuationError, isContinuing: model.isContinuingAutoplay,
                                                      id: "queue.autoplay.retry") { model.retryAutoplayContinuation() }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .listSectionSpacing(.compact)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, $editMode)
                    .accessibilityIdentifier("queue.list")
                }
            }
            .background(AppTheme.background)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                        .appFont(.body)
                        .disabled(model.player.queue.isEmpty)
                        .environment(\.editMode, $editMode)
                        .accessibilityIdentifier("queue.edit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: captureRemainingSongs) {
                        Image(systemName: "text.badge.plus")
                            .appFont(.body, weight: .semibold)
                            .frame(width: 48, height: 48)
                            .contentShape(.interaction, Rectangle())
                            .contentShape(.accessibility, Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.player.queue.indices.contains(model.player.currentIndex))
                    .accessibilityLabel("Save remaining songs")
                    .accessibilityIdentifier("queue.saveRemaining")
                    .help("Save remaining songs")
                }
            }
            .appSheetDoneButton(id: "queue.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .sheet(item: AppNavigationIntent.binding($playlistDraft, in: model, identity: { $0?.id })) { draft in
            PlayerQueuePlaylistSheet(draft: draft)
        }
    }

    private func captureRemainingSongs() {
        let snapshot = QueuePlaylistSnapshot(queue: model.player.queue, currentIndex: model.player.currentIndex)
        guard !snapshot.tracks.isEmpty else { return }
        let station = model.radioSessionLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A draft owns its selection while playback, radio continuation, or queue edits move on.
        AppNavigationIntent.perform(in: model) {
            playlistDraft = UserPlaylist(name: station.isEmpty ? "Remaining songs" : station, tracks: snapshot.tracks)
        }
    }

    /// Shuffle and repeat belong with the queue they reorder, not with the fixed transport row.
    private var playbackModeControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            modeToggle(symbol: "shuffle", title: "Shuffle",
                       label: model.player.shuffleEnabled ? "Turn shuffle off" : "Turn shuffle on",
                       id: "player.shuffle", active: model.player.shuffleEnabled) {
                model.player.toggleShuffle()
            }
            modeToggle(symbol: model.player.repeatMode == .one ? "repeat.1" : "repeat",
                       title: model.player.repeatMode == .one ? "Repeat one" : "Repeat",
                       label: repeatLabel, id: "player.repeat", active: model.player.repeatMode != .off) {
                model.player.cycleRepeatMode()
            }
        }
    }

    private func modeToggle(symbol: String, title: String, label: String, id: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .appFont(.subheadline, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(active ? AppTheme.accent : AppTheme.primaryText)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appGlass(in: Capsule(), interactive: true, tint: active ? AppTheme.accent.opacity(0.22) : nil)
        .overlay {
            if active { Capsule().strokeBorder(AppTheme.accent.opacity(0.5)) }
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var repeatLabel: String {
        switch model.player.repeatMode {
        case .off: "Repeat off. Repeat queue next."
        case .all: "Repeating queue. Repeat song next."
        case .one: "Repeating song. Turn repeat off next."
        }
    }

    /// Radio and autoplay report a stalled continuation the same way: the reason and one retry.
    @ViewBuilder
    private func continuationRetry(error: String?, isContinuing: Bool, id: String, retry: @escaping () -> Void) -> some View {
        if let error {
            Text(error).appFont(.footnote)
            Button(action: retry) {
                Label("Try more songs", systemImage: "arrow.clockwise")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isContinuing)
            .accessibilityIdentifier(id)
        }
    }

    private func queueRow(_ track: Track, at index: Int, isAutoplay: Bool, startsAutoplay: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if startsAutoplay {
                Text(model.player.isRadioSession ? "Radio continues" : "Autoplay")
                    .appFont(.footnote, weight: .semibold)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                Button {
                    guard model.player.queue.indices.contains(index) else { return }
                    if index == model.player.currentIndex {
                        model.cancelPendingRadio()
                        if !model.player.isPlaying && !model.player.isLoading { model.player.togglePlayback() }
                    } else {
                        model.playQueueTrack(at: index)
                    }
                    AppNavigationIntent.perform(in: model) { dismiss() }
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.artworkURL, title: track.title, size: 48, cornerRadius: 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .appFont(.subheadline, weight: .semibold)
                                .foregroundStyle(index == model.player.currentIndex ? AppTheme.accent : AppTheme.primaryText)
                                .lineLimit(2)
                            Text(track.artistName)
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(2)
                            if isAutoplay {
                                Text(model.player.isRadioSession ? "Radio" : "Autoplay")
                                    .appFont(.caption2)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if index == model.player.currentIndex {
                            Image(systemName: model.player.isPlaying ? "waveform" : "pause.fill")
                                .foregroundStyle(AppTheme.accent)
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(index == model.player.currentIndex ? "Current song, " : "Play ")\(track.title), \(track.artistName)\(isAutoplay ? ", Autoplay" : "")")
                .accessibilityIdentifier("queue.play.\(index).\(track.id)")

                if editMode != .active {
                    TrackActionsMenu(track: track)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.row.\(index).\(track.id)")
    }
}

@MainActor
private struct PlayerQueuePlaylistSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    let draft: UserPlaylist
    @State private var name: String
    @State private var saveError: String?
    @State private var didSave = false

    init(draft: UserPlaylist) {
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(draft.tracks.count.formatted()) \(draft.tracks.count == 1 ? "song" : "songs") selected")
                            .appFont(.headline, weight: .semibold)
                            .accessibilityIdentifier("queue.saveRemaining.count")
                        if let first = draft.tracks.first {
                            Text("Starts with \(first.title)")
                                .appFont(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("queue.saveRemaining.firstSong")
                        }
                        Text("Current and upcoming songs when you opened this sheet. Repeats are saved once.")
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Playlist name", text: $name)
                        .appFont(.body)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .onSubmit { isNameFocused = false }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
                        .accessibilityLabel("Playlist name")
                        .accessibilityIdentifier("queue.saveRemaining.name")
                    Button(action: save) {
                        Text("Save playlist")
                            .appFont(.body, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .appGlass(in: Capsule(), interactive: true)
                    .disabled(trimmedName.isEmpty || draft.tracks.isEmpty || didSave)
                    .accessibilityIdentifier("queue.saveRemaining.save")
                    if let saveError {
                        Text(saveError)
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("queue.saveRemaining.error")
                        if model.library.requiresReload {
                            Button {
                                model.reloadSavedLibrary()
                                self.saveError = model.library.errorMessage
                            } label: {
                                Label("Reload saved library", systemImage: "arrow.clockwise")
                                    .appFont(.footnote, weight: .semibold)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("queue.saveRemaining.reloadLibrary")
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppTheme.background)
            .navigationTitle("Save remaining songs")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "queue.saveRemaining.done") {
                AppNavigationIntent.perform(in: model) { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCompactAdaptation(.sheet)
        .appSheetChrome()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("queue.saveRemaining.sheet")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !didSave, !trimmedName.isEmpty, !draft.tracks.isEmpty else { return }
        let id = model.library.createPlaylist(name: trimmedName, tracks: draft.tracks)
        guard model.library.errorMessage == nil,
              let playlist = model.library.playlists.first(where: { $0.id == id }) else {
            saveError = model.library.errorMessage ?? "The playlist couldn’t be saved. Please try again."
            return
        }
        saveError = nil
        didSave = true
        isNameFocused = false
        model.showToast("Saved to \(playlist.name)")
        AppNavigationIntent.perform(in: model) { dismiss() }
    }
}

@MainActor
private struct PlayerCacheAvailability: View {
    @Environment(MusicAppModel.self) private var model
    let identifier: String

    var body: some View {
        if let current = model.player.currentTrack {
            VStack(alignment: .leading, spacing: 4) {
                status("Current", track: current, ready: model.player.isCurrentTrackCached, suffix: "current")
                if let next = nextTrack {
                    status("Next", track: next, ready: model.player.isNextTrackCached, suffix: "next")
                }
                Text(model.isOffline ? "Offline. iOS can remove cached audio." : "Temporary audio. iOS can remove it.")
                    .appFont(.caption2)
                    .accessibilityIdentifier("\(identifier).notice")
            }
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var nextTrack: Track? {
        model.player.nextAutomaticTrack
    }

    private var inventoryIsKnown: Bool {
        model.hasLoadedCachedSongs && model.cachedSongsUsage != nil && model.cachedSongsError == nil
    }

    private func status(_ title: String, track: Track, ready: Bool, suffix: String) -> some View {
        let cached = ready || (inventoryIsKnown && model.cachedPlayableTrackIDs.contains(track.id))
        let detail = if cached {
            "Cached on this device"
        } else if inventoryIsKnown {
            model.isOffline ? "Needs a connection" : "Not cached"
        } else {
            "Cache status unavailable"
        }
        return Text("\(title): \(detail)")
            .appFont(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(identifier).\(suffix)")
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
                        Text("Cancel sleep timer")
                            .appFont(.body, weight: .medium)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("player.sleepTimer.cancel")
                } header: {
                    Text("Timer active").appFont(.caption)
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
                Text("Stop playing in").appFont(.caption)
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
