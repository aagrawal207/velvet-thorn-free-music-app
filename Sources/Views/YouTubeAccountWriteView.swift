import SwiftUI

/// Present from Settings or an explicit song action; capture the controller context when creating the destination.
@MainActor
struct YouTubeAccountWriteView: View {
    @Environment(\.dismiss) private var dismiss
    let controller: YouTubeAccountWriteController
    let track: Track?
    let artist: ArtistCredit?
    let onDone: (@MainActor () -> Void)?
    /// False inside the player's options sheet, whose own toolbar already carries the sheet's Done.
    let showsDoneButton: Bool
    @State private var context: YouTubeAccountWriteController.Context
    @State private var selectedPlaylistID: String?
    @State private var pendingAction: YouTubeAccountWriteAction?
    @State private var pendingArtist: ArtistCredit?
    @State private var confirmsAction = false

    init(controller: YouTubeAccountWriteController, track: Track? = nil, artist: ArtistCredit? = nil,
         context: YouTubeAccountWriteController.Context, onDone: (@MainActor () -> Void)? = nil,
         showsDoneButton: Bool = true) {
        self.controller = controller
        self.track = track
        self.artist = artist
        self.onDone = onDone
        self.showsDoneButton = showsDoneButton
        _context = State(initialValue: context)
    }

    private var isCurrent: Bool { context == controller.context }
    private var artists: [ArtistCredit] {
        if let artist { return YouTubeAccountWriteTarget.channelID(artist) == nil ? [] : [artist] }
        guard let track, YouTubeAccountWriteTarget.videoID(track) != nil else { return [] }
        var seen = Set<String>()
        return track.allCredits.filter {
            guard let id = YouTubeAccountWriteTarget.channelID($0) else { return false }
            return seen.insert(id).inserted
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow YouTube Changes", isOn: Binding(get: { controller.allowsChanges }, set: {
                    if isCurrent { controller.setAllowsChanges($0) }
                }))
                    .toggleStyle(CompactSwitchToggleStyle())
                    .disabled(!isCurrent || (!controller.canAuthorize && !controller.allowsChanges))
                    .accessibilityIdentifier("youtubeWrite.allow")
                Text("Applies to this YouTube sign-in on this device. Each action below changes YouTube. Local likes, playlists and follows stay separate.")
                Text("Google can see these requests. This unofficial connection may stop working or be refused by YouTube.")
                Text("Uses the default Google account. Multiple-account and brand-account selection are not supported.")
            } header: { Text("YouTube Changes") }

            if !controller.canAuthorize {
                Section { Text("Reconnect YouTube in Settings before allowing changes.") }
            }
            if let error = controller.permissionError {
                Section {
                    Text(error)
                    Button("Retry Turning Off Changes") { controller.setAllowsChanges(false) }
                        .frame(minHeight: 44)
                }
            }
            if controller.allowsChanges && isCurrent {
                if let track, YouTubeAccountWriteTarget.videoID(track) != nil {
                    Section {
                        Text(track.title).font(.headline)
                        actionButton(.like)
                        actionButton(.removeLike)
                    } header: { Text("Song") }
                    Section {
                        Button("Load My YouTube Playlists") { controller.loadOwnedPlaylists(context: context) }
                            .frame(minHeight: 44)
                            .disabled(controller.isBusy)
                            .accessibilityIdentifier("youtubeWrite.loadPlaylists")
                        ForEach(controller.playlists) { playlist in
                            Button {
                                selectedPlaylistID = playlist.id
                            } label: {
                                HStack {
                                    Text(playlist.title)
                                    Spacer()
                                    if selectedPlaylistID == playlist.id { Image(systemName: "checkmark") }
                                }.frame(minHeight: 44)
                            }
                            .disabled(controller.isBusy)
                            .accessibilityAddTraits(selectedPlaylistID == playlist.id ? .isSelected : [])
                        }
                        if controller.playlistsAreLimited { Text("Showing a limited list. Only playlists YouTube identifies as yours are available.") }
                        actionButton(.addToPlaylist)
                            .disabled(!controller.playlists.contains { $0.id == selectedPlaylistID })
                    } header: { Text("Owned Playlists") }
                }
                ForEach(artists, id: \.id) { artist in
                    Section {
                        actionButton(.subscribe, artist: artist)
                        actionButton(.unsubscribe, artist: artist)
                    } header: { Text(artist.name) }
                }
                if track == nil && artist == nil {
                    Section { Text("Open YouTube Changes from a YouTube song's menu to like it, choose a playlist or manage artist subscriptions.") }
                }
            } else if !isCurrent {
                Section { Text("The account or permission changed. Reopen this page to choose an action.") }
            }
            if controller.isBusy {
                Section {
                    ProgressView(controller.isLoadingPlaylists ? "Reading YouTube playlists…" : "Waiting for YouTube…")
                    Button("Cancel Request") { controller.cancel() }.frame(minHeight: 44)
                }
            }
            if let message = controller.message {
                Section { Text(message).accessibilityIdentifier("youtubeWrite.status") }
            }
        }
        .settingsFormChrome()
        .navigationTitle("YouTube Changes")
        .navigationBarTitleDisplayMode(.inline)
        .youTubeWriteDone(showsDoneButton) { if let onDone { onDone() } else { dismiss() } }
        .accessibilityIdentifier("youtubeWrite.content")
        .confirmationDialog(pendingAction?.title ?? "YouTube Changes", isPresented: $confirmsAction, titleVisibility: .visible) {
            if let action = pendingAction {
                Button(action.title, role: [.removeLike, .unsubscribe].contains(action) ? .destructive : nil) { confirm(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("Changes the connected YouTube account. Check that this is the account you intend to change.")
        }
        .onChange(of: controller.presentationGeneration) { _, _ in
            selectedPlaylistID = nil
            pendingAction = nil
            pendingArtist = nil
            confirmsAction = false
            if context.sessionRevision == controller.context.sessionRevision { context = controller.context }
        }
        .onDisappear { if isCurrent { controller.cancel() } }
    }

    private func actionButton(_ action: YouTubeAccountWriteAction, artist: ArtistCredit? = nil) -> some View {
        Button(action.title) {
            pendingAction = action
            pendingArtist = artist
            confirmsAction = true
        }
        .frame(minHeight: 44)
        .disabled(controller.isBusy || !isCurrent)
        .accessibilityIdentifier("youtubeWrite.\(action.rawValue)")
    }

    private func confirm(_ action: YouTubeAccountWriteAction) {
        guard isCurrent, pendingAction == action else { return }
        if let artist = pendingArtist {
            controller.setSubscribed(action == .subscribe, artist: artist, context: context)
        } else if let track {
            controller.perform(action, track: track, playlist: controller.playlists.first { $0.id == selectedPlaylistID }, context: context)
        }
        pendingAction = nil
        pendingArtist = nil
    }
}

private extension View {
    @ViewBuilder
    func youTubeWriteDone(_ shown: Bool, action: @escaping () -> Void) -> some View {
        if shown { appSheetDoneButton(id: "youtubeWrite.done", action: action) } else { self }
    }
}

