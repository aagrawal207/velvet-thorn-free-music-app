import SwiftUI
import WatchKit

@MainActor
struct WatchNowPlayingView: View {
    @Environment(WatchCompanionModel.self) private var model
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.watchAccent) private var accent
    /// A hold owns the rest of its press: the release that follows must not also run the favorite tap action.
    @State private var favoriteHoldFired = false

    private static let favoriteHoldDuration: TimeInterval = 0.4

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let displayed = model.timeline.snapshot, let track = displayed.nowPlaying {
                    HStack(spacing: 8) {
                        WatchRecordMark(size: 32)
                        trackDetails(track)
                    }
                    TimelineView(.animation(minimumInterval: 1, paused: !model.isPlaying || isLuminanceReduced)) { _ in
                        VStack(spacing: 10) {
                            controls(track, displayed: displayed)
                            progress(track)
                            if !model.isCurrent { lastSeen }
                        }
                    }
                    secondaryControls(track, displayed: displayed)
                    if let error = track.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.petal)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("watch.playback.error")
                    }
                } else if model.isCurrent, model.libraryError == nil {
                    emptyPlayer
                } else {
                    WatchRecordMark()
                }

                if !model.connection.canMessage || (model.nowPlaying == nil && !model.isCurrent) {
                    WatchConnectionView()
                }
                if let notice = model.notice { WatchNoticeView(message: notice) }
                if let error = model.libraryError { WatchLibraryFailureView(message: error) }
                libraryLink
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .accessibilityIdentifier("watch.nowPlaying")
    }

    private func trackDetails(_ track: CompanionNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.headline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("watch.track.title")
            Text(track.artist)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("watch.track.artist")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
    }

    private func progress(_ track: CompanionNowPlaying) -> some View {
        let position = model.position
        return VStack(spacing: 4) {
            ProgressView(value: track.duration > 0 ? min(position / track.duration, 1) : 0)
                .tint(accent)
                .accessibilityHidden(true)
            HStack {
                Text(WatchSnapshotState.timestamp(position))
                Spacer(minLength: 4)
                Text(track.duration > 0 ? WatchSnapshotState.timestamp(track.duration) : "–:––")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.isCurrent ? "Playback progress" : "Last known progress")
        .accessibilityValue("\(WatchSnapshotState.timestamp(position)) of \(track.duration > 0 ? WatchSnapshotState.timestamp(track.duration) : "unknown duration")")
        .accessibilityIdentifier("watch.progress")
    }

    private func controls(_ track: CompanionNowPlaying, displayed: CompanionSnapshot) -> some View {
        HStack(spacing: 0) {
            transportButton("Previous song", symbol: "backward.end.fill", action: .previous, displayed: displayed, identifier: "watch.previous")
            Button {
                let action: CompanionAction = track.isPlaying || track.isLoading ? .pause : .play
                Task { await model.command(action, displayed: displayed) }
            } label: {
                ZStack {
                    Circle().fill(accent)
                    if (model.isCurrent && track.isLoading) || isPlayPausePending {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: model.isCurrent && track.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 52, height: 52)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canControl)
            .opacity(model.canControl ? 1 : 0.5)
            .accessibilityLabel(!model.isCurrent ? "Playback unavailable" : track.isPlaying || track.isLoading ? "Pause on iPhone" : "Play on iPhone")
            .accessibilityValue(model.isCurrent && track.isLoading ? "Loading" : model.pendingCommand != nil ? "Pending" : "")
            .accessibilityIdentifier("watch.playPause")
            transportButton("Next song", symbol: "forward.end.fill", action: .next, displayed: displayed, identifier: "watch.next")
        }
    }

    private var isPlayPausePending: Bool {
        guard let action = model.pendingCommand?.action else { return false }
        return action == .play || action == .pause
    }

    private func transportButton(_ title: String, symbol: String, action: CompanionAction,
                                 displayed: CompanionSnapshot, identifier: String) -> some View {
        Button {
            Task { await model.command(action, displayed: displayed) }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canControl)
        .accessibilityLabel(title)
        .accessibilityHint("Plays on iPhone")
        .accessibilityIdentifier(identifier)
    }

    private func secondaryControls(_ track: CompanionNowPlaying, displayed: CompanionSnapshot) -> some View {
        VStack(spacing: 2) {
            if model.pendingCommand != nil {
                Text("Sending to iPhone…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.pending")
            } else if model.isCurrent {
                Text(track.isLoading ? "Loading on iPhone" : track.isPlaying ? "Playing on iPhone" : "Paused on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                favoriteButton(track, displayed: displayed)

                NavigationLink {
                    WatchPlaybackOptionsView()
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Playback options")
                .accessibilityIdentifier("watch.options")
            }
        }
    }

    /// One three-state heart: a tap likes or removes the song (a super liked song is removed fully), a hold toggles the
    /// super like tier. The displayed track and snapshot are captured here, before any Task, like every other control.
    private func favoriteButton(_ track: CompanionNowPlaying, displayed: CompanionSnapshot) -> some View {
        Button {
            guard !favoriteHoldFired else {
                favoriteHoldFired = false
                return
            }
            let action = CompanionAction.setFavorite(!track.isFavorite)
            Task { await model.command(action, displayed: displayed) }
        } label: {
            Image(systemName: track.isSuperLiked ? "bolt.heart.fill" : track.isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(track.isFavorite ? WatchTheme.petal : .white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        // Simultaneous so the Button keeps its tap. Every press start clears the hold flag; reaching the hold sets it.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Self.favoriteHoldDuration)
                .onChanged { _ in favoriteHoldFired = false }
                .onEnded { _ in
                    favoriteHoldFired = true
                    toggleSuperLike(track, displayed: displayed)
                }
        )
        .disabled(!canEditFavorite)
        .accessibilityLabel(track.isFavorite ? "Remove from favorites" : "Add to favorites")
        .accessibilityValue(track.isSuperLiked ? "Super liked" : track.isFavorite ? "Favorite" : "Not a favorite")
        .accessibilityAction(named: track.isSuperLiked ? "Change to favorite" : "Super like") {
            toggleSuperLike(track, displayed: displayed)
        }
        .accessibilityIdentifier("watch.favorite")
    }

    private var canEditFavorite: Bool { model.canControl && model.libraryError == nil }

    private func toggleSuperLike(_ track: CompanionNowPlaying, displayed: CompanionSnapshot) {
        // `.disabled` is relied on for the Button, not for the simultaneous gesture; a rejected hold must stay silent.
        guard canEditFavorite else { return }
        let promoting = !track.isSuperLiked
        let action = CompanionAction.setSuperLiked(promoting)
        if promoting { WKInterfaceDevice.current().play(.success) }
        Task { await model.command(action, displayed: displayed) }
    }

    private var lastSeen: some View {
        VStack(spacing: 2) {
            Text("Last seen on iPhone").font(.caption2.weight(.semibold))
            if model.connection.canMessage {
                WatchRefreshButton()
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("watch.lastSeen")
    }

    private var emptyPlayer: some View {
        VStack(spacing: 8) {
            WatchRecordMark()
            Text("Find your next song").font(.headline)
            Text("Choose from your library or open Velvet Thorn on iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("watch.empty")
    }

    private var libraryLink: some View {
        NavigationLink(value: "root") {
            Label("Library", systemImage: "music.note.list")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("watch.library")
    }
}
