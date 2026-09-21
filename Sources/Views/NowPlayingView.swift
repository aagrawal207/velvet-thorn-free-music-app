import AVKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
struct NowPlayingView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleLineHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var artistLineHeight: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var captionLineHeight: CGFloat = 16
    @State private var activeSheet: PlayerSheet?
    @State private var deferredAction: PlayerDeferredAction?
    @State private var airPlayTrigger = PlayerAirPlayTrigger()
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
                    PlayerBackdrop(track: model.player.currentTrack)
                    playerLayout.padding(geometry.safeAreaInsets)
                }
                .offset(y: dismissalOffset)
            }
            .ignoresSafeArea()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.presentation")
            .contentShape(Rectangle())
            .gesture(PlayerDismissPanGesture(
                isEnabled: activeSheet == nil && !isScrubbing && !isDismissing,
                onChanged: updateDismissal,
                onEnded: { distance, velocity in finishDismissal(distance: distance, velocity: velocity, height: height) },
                onCancel: cancelDismissal
            ))
            .allowsHitTesting(!isDismissing)
        }
        .presentationBackground(.clear)
        .background {
            // AVKit presents routes through its own button, which must stay mounted between sheets.
            PlayerAirPlayPicker(trigger: airPlayTrigger, accentColor: model.library.preferences.accent.color)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
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
            switch sheet {
            case .lyrics:
                PlayerLyricsSheet()
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            case .queue:
                PlayerQueueSheet()
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            case .actions(let track, let route):
                PlayerOptionsSheet(track: track, initialRoute: route,
                                   onAlbum: { performAfterSheet(.album($0)) },
                                   onArtist: { performAfterSheet(.artist($0)) },
                                   onAirPlay: { performAfterSheet(.airPlay) })
                    .presentationDragIndicator(.visible)
                    .presentationContentInteraction(.resizes)
                    .presentationCompactAdaptation(.sheet)
            }
        }
    }

    private var playerLayout: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height

            VStack(spacing: 0) {
                topBar
                if let track = model.player.currentTrack {
                    if landscape {
                        let contentWidth = max(0, min(geometry.size.width - 48, 900))
                        HStack(alignment: .bottom, spacing: 24) {
                            VStack(spacing: 8) {
                                artworkArea(track)
                                if dynamicTypeSize.isAccessibilitySize { trackHeading(track) }
                            }
                            playerDetails(track, compact: true, showsHeading: !dynamicTypeSize.isAccessibilitySize)
                                .frame(width: min(430, max(0, contentWidth - 24) * 0.55))
                        }
                        .padding(.top, 8)
                    } else {
                        artworkArea(track)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                        playerDetails(track, compact: false)
                    }
                } else {
                    EmptyStateView(symbol: "music.note", title: "Make room for music",
                                   message: "Choose a song from Home, Search, or your library to start listening.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .frame(maxWidth: landscape ? 900 : 500)
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
                Text("NOW PLAYING")
                    .appFont(.caption2, weight: .bold)
                    .tracking(1.6)
                    .lineLimit(1)
                Text(model.radioSessionLabel ?? model.player.currentTrack?.albumTitle ?? "Breezy")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
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
            ArtworkView(url: track.artworkURL, title: track.title, size: size, cornerRadius: 10)
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
            seekControls
                .padding(.top, compact ? 4 : 8)
            transportControls
                .padding(.top, compact ? 4 : 12)
            secondaryControls(track)
                .padding(.top, compact ? 4 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func trackHeading(_ track: Track) -> some View {
        let liked = model.library.isFavorite(track)
        let plays = PlayCountText.plays(track.playCount ?? model.player.resolvedViewCount)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
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
                    .foregroundStyle(AppTheme.secondaryText)
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
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                            .accessibilityIdentifier("player.playCount")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: captionLineHeight, maxHeight: captionLineHeight, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.library.toggleFavorite(track)
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(liked ? AppTheme.accent : AppTheme.secondaryText)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "Unlike this song" : "Like this song")
            .accessibilityAddTraits(liked ? .isSelected : [])
            .accessibilityIdentifier("player.like")
        }
    }

    private var seekControls: some View {
        VStack(spacing: 2) {
            PlayerSeekSlider(
                position: displayedPosition, duration: effectiveDuration,
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
            .frame(height: 44)

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
            .foregroundStyle(AppTheme.secondaryText)
            .frame(height: captionLineHeight)
        }
    }

    private var transportControls: some View {
        GeometryReader { geometry in
            let target = min(56, max(44, (geometry.size.width - 96) / 4))
            HStack(spacing: 0) {
                transportButton(symbol: "shuffle", label: model.player.shuffleEnabled ? "Turn shuffle off" : "Turn shuffle on",
                                id: "player.shuffle", target: target, active: model.player.shuffleEnabled) {
                    model.player.toggleShuffle()
                }
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
                transportButton(symbol: model.player.repeatMode == .one ? "repeat.1" : "repeat", label: repeatLabel,
                                id: "player.repeat", target: target, active: model.player.repeatMode != .off) {
                    model.player.cycleRepeatMode()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 88)
        .appGlass(in: Capsule())
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
                                 target: CGFloat, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? AppTheme.accent : AppTheme.primaryText)
                .frame(width: target, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private func secondaryControls(_ track: Track) -> some View {
        HStack(spacing: 0) {
            playerAction("Lyrics", symbol: "quote.bubble", id: "player.lyrics") {
                presentSheet(.lyrics)
            }

            playerAction("Album", symbol: "square.stack", id: "player.album",
                         enabled: track.albumCollection != nil) {
                if let album = track.albumCollection { performAfterSheet(.album(album)) }
            }

            playerAction("Artist", symbol: "person.crop.circle", id: "player.artist",
                         enabled: !track.allCredits.isEmpty) {
                goToArtist(track)
            }

            playerAction("Queue", symbol: "text.line.first.and.arrowtriangle.forward", id: "player.queue") {
                presentSheet(.queue)
            }
        }
    }

    /// One credit opens straight away; several ask which artist to open.
    private func goToArtist(_ track: Track) {
        let credits = track.allCredits
        guard let credit = credits.first else { return }
        if credits.count == 1 {
            performAfterSheet(.artist(credit))
        } else {
            presentSheet(.actions(track, .artists))
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
                .foregroundStyle(AppTheme.secondaryText)
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
        // UIKit must finish dismissing the sheet before navigation or the route picker can present.
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
        case .airPlay: airPlayTrigger.present()
        }
    }

    private func updateDismissal(_ distance: CGFloat) {
        guard activeSheet == nil, !isScrubbing, !isDismissing else { return }
        dismissalOffset = max(0, distance)
    }

    private func finishDismissal(distance: CGFloat, velocity: CGPoint, height: CGFloat) {
        guard activeSheet == nil, !isScrubbing, !isDismissing else {
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
                .foregroundStyle(AppTheme.secondaryText)
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
        .appGlass(in: RoundedRectangle(cornerRadius: 16))
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

    private var repeatLabel: String {
        switch model.player.repeatMode {
        case .off: "Repeat off. Repeat queue next."
        case .all: "Repeating queue. Repeat song next."
        case .one: "Repeating song. Turn repeat off next."
        }
    }

    private func artworkSize(_ size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite else { return 0 }
        return max(0, min(size.width, size.height, 420))
    }

    private enum PlayerSheet: Identifiable {
        case lyrics, queue
        case actions(Track, PlayerOptionsRoute)

        var id: String {
            switch self {
            case .lyrics: "lyrics"
            case .queue: "queue"
            case .actions(let track, let route): "actions.\(track.id).\(route.rawValue)"
            }
        }
    }

    private enum PlayerDeferredAction {
        case album(MusicCollection), artist(ArtistCredit), airPlay
    }
}

/// Album art blurred behind the controls, with a gradient that keeps them legible.
@MainActor
private struct PlayerBackdrop: View {
    let track: Track?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var imageURL: URL?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.background
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 60, opaque: true)
                        // Blur feathers the edges; overscan keeps the fade outside the visible area.
                        .scaleEffect(1.25)
                        .opacity(colorScheme == .dark ? 0.55 : 0.35)
                        .id(imageURL)
                        .transition(.opacity)
                } else {
                    LinearGradient(colors: [artworkTint.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
                        .transition(.opacity)
                }
                LinearGradient(colors: [AppTheme.background.opacity(0.35), AppTheme.background.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.4), value: track?.id)
        .task(id: track?.artworkURL) {
            guard let url = track?.artworkURL else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    image = nil
                    imageURL = nil
                }
                return
            }
            // A blurred backdrop needs few pixels; decoding small keeps the cache cheap.
            let loaded = await ArtworkLoader.shared.image(for: url, tier: .standard, maxPixels: 300)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                image = loaded
                imageURL = loaded == nil ? nil : url
            }
        }
    }

    private var artworkTint: Color {
        switch track?.language {
        case .hindi: AppTheme.gold
        case .english: AppTheme.violet
        case nil: AppTheme.accent
        }
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
    let onAirPlay: () -> Void
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
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { AppNavigationIntent.perform(in: model) { dismiss() } }
                    .appFont(.body, weight: .semibold)
                    .accessibilityIdentifier("player.options.toolbarDone")
            }
        }
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
                        option("Reload best available audio", symbol: "arrow.clockwise", id: "player.options.reloadAudioQuality",
                               subtitle: "Checks the source for this play. Keeps cached audio for fallback.",
                               enabled: model.player.canReloadAudioQuality) {
                            guard model.player.currentTrack?.id == track.id else { return }
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
                    option("AirPlay", symbol: "airplayaudio", id: "player.options.airplay", action: onAirPlay)
                    if let url = track.shareURL {
                        ShareLink(item: url) {
                            PlayerOptionLabel(title: "Share song", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(AppNavigationIntentButtonStyle(.plain))
                        .accessibilityLabel("Share song")
                        .accessibilityIdentifier("player.options.share")
                    }
                }
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
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
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(track.allCredits.enumerated()), id: \.offset) { index, credit in
                    option(credit.name, symbol: "person.crop.circle", id: "player.artist.\(index)", showsChevron: true) {
                        onArtist(credit)
                    }
                }
            }
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier("player.artists.list")
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
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
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
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
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
        let id = model.library.createPlaylist(name: trimmedPlaylistName)
        guard model.library.playlists.contains(where: { $0.id == id }) else { return }
        addTrack(to: id)
    }

    private func addTrack(to id: UUID) {
        model.library.add(track, to: id)
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

@MainActor
private struct PlayerSeekSlider: View {
    let position: TimeInterval
    let duration: TimeInterval
    let onEditingChanged: (Bool, TimeInterval) -> Void
    let onValueChanged: (TimeInterval) -> Void
    let onCancel: () -> Void
    let onAccessibilitySeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width.isFinite ? max(0, geometry.size.width) : 0
            let progress = duration > 0 ? min(max(position / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.secondaryText.opacity(0.22)).frame(height: 4)
                Capsule().fill(AppTheme.accent).frame(width: width * progress, height: 4)
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 12, height: 12)
                    .offset(x: min(max(width * progress - 6, 0), max(width - 12, 0)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(PlayerSeekPanGesture(
                onChanged: { x in
                    guard duration > 0, width > 0, x.isFinite else { return }
                    onEditingChanged(true, position)
                    onValueChanged(duration * min(max(x / width, 0), 1))
                },
                onEnded: { x in
                    guard duration > 0, width > 0, x.isFinite else {
                        onCancel()
                        return
                    }
                    onEditingChanged(false, duration * min(max(x / width, 0), 1))
                },
                onCancel: onCancel
            ))
            .onTapGesture { location in
                guard duration > 0, width > 0 else { return }
                onEditingChanged(true, position)
                onEditingChanged(false, duration * min(max(location.x / width, 0), 1))
            }
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

/// Opens the system route picker from a menu item. AVKit exposes no API for this, so the picker's own
/// button is pressed programmatically.
@MainActor
private final class PlayerAirPlayTrigger {
    weak var picker: AVRoutePickerView?

    func present() {
        guard let picker, let button = Self.button(in: picker) else { return }
        button.sendActions(for: .touchUpInside)
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
    let trigger: PlayerAirPlayTrigger
    let accentColor: Color

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        view.accessibilityLabel = "AirPlay and audio output"
        view.accessibilityIdentifier = "player.airplay"
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = UIColor(AppTheme.secondaryText)
        uiView.activeTintColor = UIColor(accentColor)
        trigger.picker = uiView
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { AppNavigationIntent.perform(in: model) { dismiss() } }
                        .appFont(.body, weight: .semibold)
                        .accessibilityIdentifier("lyrics.done")
                }
            }
        }
        .tint(AppTheme.accent)
    }
}

@MainActor
private struct PlayerQueueSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive

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
                                if model.player.isRadioSession, let error = model.radioContinuationError {
                                    Text(error).appFont(.footnote)
                                    Button("Try more songs", systemImage: "arrow.clockwise") {
                                        model.retryRadioContinuation()
                                    }
                                    .appFont(.subheadline, weight: .semibold)
                                    .frame(minHeight: 44)
                                    .disabled(model.isContinuingRadio)
                                    .accessibilityIdentifier("queue.radio.retry")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
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
                    Button("Done") { AppNavigationIntent.perform(in: model) { dismiss() } }
                        .appFont(.body, weight: .semibold)
                        .accessibilityIdentifier("queue.done")
                }
            }
        }
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
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
