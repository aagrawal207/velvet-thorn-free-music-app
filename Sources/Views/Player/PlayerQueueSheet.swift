import SwiftUI

@MainActor
struct PlayerQueueSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editMode: EditMode = .inactive
    @State private var playlistDraft: UserPlaylist?
    @State private var tuneSelection: RadioTuneSelection?

    var body: some View {
        NavigationStack {
            Group {
                if model.player.queue.isEmpty && model.activeRadioSeed == nil
                    && !model.isStartingSeedRadio && model.seedRadioError == nil {
                    EmptyStateView(symbol: "music.note.list", title: "An Open Queue",
                                   message: "Use a song's menu to play it next or add it to the end of your queue.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                } else {
                    List {
                        SeedRadioSessionSection(identifier: "queue.radio", tuneSelection: $tuneSelection)
                        if !model.player.queue.isEmpty {
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
                                    if let station = model.radioSessionLabel, model.activeRadioSeed == nil {
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
                                    if model.player.isRadioSession && model.activeRadioSeed == nil {
                                        continuationRetry(error: model.radioContinuationError, isContinuing: model.isContinuingRadio,
                                                          id: "queue.radio.retry") { model.retryRadioContinuation() }
                                    } else if !model.player.isRadioSession {
                                        continuationRetry(error: model.autoplayContinuationError, isContinuing: model.isContinuingAutoplay,
                                                          id: "queue.autoplay.retry") { model.retryAutoplayContinuation() }
                                    }
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
                    .accessibilityLabel("Save Remaining Songs")
                    .accessibilityIdentifier("queue.saveRemaining")
                    .help("Save remaining songs")
                }
            }
            .appSheetDoneButton(id: "queue.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .safeAreaInset(edge: .bottom, spacing: 0) { RootMessageBanner() }
        .sheet(item: AppNavigationIntent.binding($playlistDraft, in: model, identity: { $0?.id })) { draft in
            PlayerQueuePlaylistSheet(draft: draft).appPresentationEnvironment(model)
        }
        .sheet(item: AppNavigationIntent.binding($tuneSelection, in: model, identity: { $0?.id })) { selection in
            RadioTuneSheet(selection: selection).appPresentationEnvironment(model)
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
                       title: model.player.repeatMode == .one ? "Repeat One" : "Repeat",
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
                Label("Try More Songs", systemImage: "arrow.clockwise")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isContinuing || model.isOffline)
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
                                .nowPlayingMotion(isPlaying: model.player.isPlaying)
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
                        Text("Save Playlist")
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
                                Label("Reload Saved Library", systemImage: "arrow.clockwise")
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
            .navigationTitle("Save Remaining Songs")
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
