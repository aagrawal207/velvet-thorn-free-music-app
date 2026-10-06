import OSLog
import SwiftUI

@MainActor
struct NowPlayingView: View {
    var liveRadioFavorites: LiveRadioFavorites? = nil
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Player")
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
                    PlayerArtworkBackdrop(url: model.player.currentTrack?.artworkURL, fallbackTint: artworkTint,
                                          style: model.library.preferences.playerBackgroundMotion,
                                          identity: model.player.isLiveRadio, isPlaying: model.player.isPlaying,
                                          isCovered: activeSheet != nil, meter: model.player.levelMeter,
                                          meterAvailable: { [player = model.player] in player.levelMeterAvailability == .available },
                                          setMetering: { [player = model.player] in player.setLevelMetering($0) })
                    playerLayout.padding(geometry.safeAreaInsets)
                        .environment(\.secondaryTextColor, AppTheme.artworkSecondaryText)
                }
                .offset(y: dismissalOffset)
            }
            .ignoresSafeArea()
            .overlay { HeartBurstOverlay() }
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
        // Presented at launch, the cover can miss the root's accent and fall back to system blue; own it here.
        .accentColor(model.library.preferences.accent.color)
        .tint(model.library.preferences.accent.color)
        .accessibilityAction(.escape) { model.isPlayerPresented = false }
        .onAppear {
            dismissalOffset = 0
            isDismissing = false
            #if DEBUG
            if let track = model.player.currentTrack, let sheet = DebugWindowSnapshot.requestedPlayerSheet(for: track) {
                activeSheet = sheet
            }
            #endif
        }
        .onChange(of: model.player.currentTrack?.id) { _, _ in
            resetScrub()
        }
        .onChange(of: model.player.isLiveRadio) { _, live in
            if live {
                deferredAction = nil
                activeSheet = nil
                resetScrub()
            }
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
            Group { switch sheet {
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
            } }
            .appPresentationEnvironment(model)
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
                if let station = model.player.liveStation {
                    liveRadioDetails(station)
                } else if let track = model.player.currentTrack {
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
                        // Text and controls keep the 24-point column margin; only the art runs 12 points closer to the
                        // phone's edges. Regular width has room, so the art keeps the column and deeper padding seats the heading.
                        artworkArea(track)
                            .padding(.horizontal, regular ? 0 : -12)
                            .padding(.top, 12)
                            .padding(.bottom, regular ? 40 : 20)
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
            .frame(maxWidth: landscape ? (regular ? 1040 : 900) : (regular ? 660 : 500))
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
                let context = model.player.isLiveRadio ? "Live Radio" : (model.radioSessionLabel ?? model.player.currentTrack?.albumTitle ?? "Velvet Thorn")
                PlayerEyebrow()
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
                // The art stays decorative for VoiceOver; the container only gives layout checks its frame.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("player.artwork")
                .overlay(alignment: .bottom) {
                    if let message = model.player.errorMessage {
                        playbackError(message).padding(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { RootMessageBanner() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(swipeUpRegion)
    }

    private func liveRadioDetails(_ station: LiveRadioStation) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "radio")
                    .font(.system(size: 100, weight: .light))
                    .frame(maxWidth: .infinity, minHeight: 160)
                    .accessibilityHidden(true)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(station.name).appFont(.title2, weight: .bold)
                            .accessibilityIdentifier("player.live.title")
                        Text(station.subtitle).appFont(.subheadline)
                            .foregroundStyle(AppTheme.artworkSecondaryText)
                        Label(model.player.isLoading ? "Connecting…" : model.player.isPlaying ? "Live" : "Paused",
                              systemImage: "dot.radiowaves.left.and.right")
                            .appFont(.caption, weight: .semibold)
                            .accessibilityIdentifier("player.live.status")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let favorites = liveRadioFavorites {
                        Button { favorites.toggle(station) } label: {
                            Image(systemName: favorites.contains(station) ? "heart.fill" : "heart")
                                .font(.title2)
                                .foregroundStyle(favorites.contains(station) ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                                .frame(width: 52, height: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(favorites.requiresReload)
                        .accessibilityLabel(favorites.contains(station) ? "Remove Station Favorite" : "Save Station Favorite")
                        .accessibilityIdentifier("player.live.favorite")
                    }
                }
                if let message = liveRadioFavorites?.errorMessage { Text(message).appFont(.caption) }
                if let message = model.player.errorMessage { playbackError(message) }
                playButton
                HStack(spacing: 8) {
                    PlayerAirPlayPicker(accentColor: model.library.preferences.accent.color) { presented in
                        if presented { AppNavigationIntent.perform(in: model) { cancelDismissal() } }
                        isAirPlayPresented = presented
                    }
                    .frame(width: 44, height: 44)
                    .onDisappear { isAirPlayPresented = false }
                    Spacer()
                    Menu {
                        ForEach([15, 30, 60], id: \.self) { minutes in
                            Button("\(minutes) Minutes") { model.player.setSleepTimer(minutes: minutes) }
                        }
                        if model.player.sleepUntil != nil {
                            Button("Cancel Sleep Timer") { model.player.setSleepTimer(minutes: nil) }
                        }
                    } label: {
                        Image(systemName: model.player.sleepUntil == nil ? "moon.zzz" : "moon.zzz.fill")
                            .foregroundStyle(model.player.sleepUntil == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(AppTheme.accent))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Sleep Timer")
                    .accessibilityIdentifier("player.live.sleep")
                }
                Button { model.player.stopLiveRadio() } label: {
                    Label("Return to Music", systemImage: "music.note")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("player.live.stop")
                Text("Live broadcasts can’t be rewound, downloaded, or shown as song lyrics.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.artworkSecondaryText)
            }
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("player.live")
    }

    private var swipeUpRegion: PlayerSwipeUpRegion {
        PlayerSwipeUpRegion(isEnabled: activeSheet == nil && !isAirPlayPresented && !isScrubbing && !isDismissing,
                            onSwipeUp: performSwipeUp)
    }

    private func performSwipeUp() {
        guard let track = model.player.currentTrack, activeSheet == nil, !isAirPlayPresented, !isScrubbing, !isDismissing else { return }
        let action = model.library.preferences.playerSwipeUpAction
        Self.log.info("event=swipe_up action=\(action.rawValue, privacy: .public)")
        switch action {
        case .lyrics: presentSheet(.lyrics)
        case .queue: presentSheet(.queue)
        case .moreOptions: presentSheet(.actions(track, .options))
        case .off: break
        }
    }

    private func playerDetails(_ track: Track, compact: Bool, showsHeading: Bool = true) -> some View {
        VStack(spacing: 0) {
            if showsHeading { trackHeading(track) }
            seekControls(track)
                .padding(.top, compact ? 4 : 8)
            transportControls
                .padding(.top, compact ? 4 : 12)
            secondaryControls
                .padding(.top, compact ? 4 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func trackHeading(_ track: Track) -> some View {
        let plays = PlayCountText.plays(model.player.currentPlayCount)
        return VStack(alignment: .leading, spacing: 0) {
            // The heart centres on the title and artist lines, not on the play-count caption below them.
            HStack(alignment: .center, spacing: 4) {
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
                        .foregroundStyle(AppTheme.artworkSecondaryText)
                        .frame(maxWidth: .infinity, minHeight: max(44, artistLineHeight), alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(track.allCredits.isEmpty && track.albumCollection == nil)
                    .accessibilityLabel("\(opensArtistDirectly(track) ? "Go to artist" : "Album and artists"), \(track.artistName)")
                    .accessibilityIdentifier("player.artistName")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PlayerLikeButton(liked: model.library.isFavorite(track), superLiked: model.library.isSuperLiked(track),
                                 action: { model.toggleLike(track, surface: .player) },
                                 superLikeAction: { model.toggleSuperLike(track, surface: .player) })
            }
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
        .background(swipeUpRegion)
    }

    private func seekControls(_ track: Track) -> some View {
        // The bar's 44-point target overhangs its 32-point row by 6 points on each side; the labels start where it ends.
        VStack(spacing: (PlayerProgressBar.hitHeight - PlayerProgressBar.rowHeight) / 2) {
            PlayerProgressRow(
                position: displayedPosition, duration: effectiveDuration, isScrubbing: isScrubbing,
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
            .frame(height: PlayerProgressBar.rowHeight)

            HStack {
                Text(TimeText.duration(displayedPosition))
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(TimeText.duration(displayedPosition))
                    .accessibilityIdentifier("player.elapsed")
                Spacer()
                trailingTimeLabel
            }
            .appFont(.caption2, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(AppTheme.artworkSecondaryText)
            .frame(height: captionLineHeight)
        }
    }

    private var trailingTimeStyle: TrailingTimeStyle { model.library.preferences.trailingTimeStyle }

    private var trailingTimeValue: String? {
        guard effectiveDuration > 0 else { return nil }
        switch trailingTimeStyle {
        case .songLength: return TimeText.duration(effectiveDuration)
        case .remaining: return TimeText.duration(max(0, effectiveDuration - displayedPosition))
        }
    }

    private var trailingTimeLabel: some View {
        let value = trailingTimeValue
        let text = value.map { trailingTimeStyle == .remaining ? "−\($0)" : $0 } ?? "--:--"
        let targetHeight = max(44, captionLineHeight)
        return Button {
            toggleTrailingTimeStyle()
        } label: {
            Text(text)
                .frame(height: captionLineHeight)
                .frame(minWidth: 44, minHeight: targetHeight, maxHeight: targetHeight, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The 44-point target grows leftward into the row's empty middle and downward into the transport row's
        // empty band, so the seek row above keeps every touch and the text stays where the caption sits.
        .padding(.bottom, captionLineHeight - targetHeight)
        .accessibilityLabel(trailingTimeStyle == .remaining ? "Remaining time" : "Song length")
        .accessibilityValue(value ?? "Unknown")
        .accessibilityHint("Switches between song length and remaining time")
        .accessibilityIdentifier("player.trailingTime")
    }

    private func toggleTrailingTimeStyle() {
        let style: TrailingTimeStyle = trailingTimeStyle == .remaining ? .songLength : .remaining
        model.updatePreferences { $0.trailingTimeStyle = style }
        Self.log.info("event=trailing_time_toggled style=\(style.rawValue, privacy: .public)")
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
        }
        .frame(height: 80)
    }

    private var playButton: some View {
        Button {
            model.player.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(AppTheme.primaryText)
                PlaybackControlGlyph(symbol: playbackActive ? "pause.fill" : "play.fill", isLoading: model.player.isLoading,
                                     font: .system(size: 28, weight: .bold), arcDiameter: 70, arcLineWidth: 3,
                                     arcColor: AppTheme.background, playOffset: 2)
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

    private var secondaryControls: some View {
        // AirPlay and Download hold the leading corner and the two sheets the trailing one; the artist line owns album browsing.
        HStack(spacing: 8) {
            PlayerAirPlayPicker(accentColor: model.library.preferences.accent.color) { presented in
                if presented { AppNavigationIntent.perform(in: model) { cancelDismissal() } }
                isAirPlayPresented = presented
            }
            // AVKit owns its route-state artwork; size the visible picker instead of adding a second button image.
            .frame(width: 44, height: 44)
            .onDisappear { isAirPlayPresented = false }

            PlayerDownloadButton(track: model.player.currentTrack)

            Spacer(minLength: 0)

            playerAction("Lyrics", symbol: "quote.bubble", id: "player.lyrics") {
                presentSheet(.lyrics)
            }

            playerAction("Queue", symbol: "text.line.first.and.arrowtriangle.forward", id: "player.queue") {
                presentSheet(.queue)
            }
        }
        .frame(height: 44)
    }

    /// One credit without an album is a single destination; anything else deserves the album and artists chooser.
    private func opensArtistDirectly(_ track: Track) -> Bool {
        track.allCredits.count == 1 && track.albumCollection == nil
    }

    private func goToArtist(_ track: Track) {
        if opensArtistDirectly(track), let credit = track.allCredits.first {
            performAfterSheet(.artist(credit))
        } else if !track.allCredits.isEmpty || track.albumCollection != nil {
            presentSheet(.browse(track))
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
                .frame(width: 44, height: 44)
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
        return max(0, min(size.width, size.height, horizontalSizeClass == .regular ? 600 : 420))
    }
}
