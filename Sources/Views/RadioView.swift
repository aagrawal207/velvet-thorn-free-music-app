import SwiftUI

@MainActor
struct RadioView: View {
    @Environment(MusicAppModel.self) private var model
    @State private var search = RadioSearchModel()
    @State private var tuneSelection: RadioTuneSelection?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var search = search
        let request = search.request(isOffline: model.isOffline)
        List {
            Section {
                SettingsMenuRow(title: "Search For", selection: $search.filter,
                                value: search.filter == .artists ? "Artists" : "Songs", id: "radio.search.type") {
                    Text("Songs").tag(SearchFilter.songs)
                        .accessibilityIdentifier("radio.search.type.songs")
                    Text("Artists").tag(SearchFilter.artists)
                        .accessibilityIdentifier("radio.search.type.artists")
                }
                if model.isOffline {
                    Label("Connect to the internet to search or start radio.", systemImage: "wifi.slash")
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("radio.search.offline")
                } else if !request.query.isEmpty {
                    searchResults
                } else {
                    Text("Search for a song or artist, then tap to start radio.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("radio.search.guidance")
                }
            }

            SeedRadioSessionSection(tuneSelection: $tuneSelection)

            if !model.seedRadioHistory.entries.isEmpty {
                Section("Listen Again") {
                    ForEach(Array(model.seedRadioHistory.entries.prefix(20))) { entry in
                        seedButton(entry.seed, subtitle: entry.tuning.summary,
                                   id: "radio.listenAgain.\(entry.id)", tuning: entry.tuning)
                            .contextMenu {
                                Button("Remove from Listen Again", systemImage: "trash", role: .destructive) {
                                    model.seedRadioHistory.remove(id: entry.id)
                                }
                                .accessibilityIdentifier("radio.listenAgain.remove.\(entry.id)")
                            }
                    }
                }
            }
            if let error = model.seedRadioHistory.errorMessage {
                Section {
                    Text(error).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("radio.listenAgain.error")
                    Button("Reload Radio History") {
                        model.seedRadioHistory.reload(historyEpoch: model.library.listeningHistoryEpoch,
                                                      enabled: model.library.preferences.saveListeningHistory)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("radio.listenAgain.reload")
                }
            }
            if !model.radioSuggestions.isEmpty {
                Section("Start with a Song") {
                    ForEach(Array(model.radioSuggestions.prefix(8))) { track in
                        seedButton(.song(track), subtitle: track.artistName, id: "radio.suggestion.\(track.id)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs or artists")
        .searchFocused($isSearchFocused)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("search.radio.content")
        .sheet(item: AppNavigationIntent.binding($tuneSelection, in: model, identity: { $0?.id })) { selection in
            RadioTuneSheet(selection: selection).appPresentationEnvironment(model)
        }
        .task(id: request) {
            await search.load(request, catalog: model.catalog, isOffline: { model.isOffline })
        }
        .onChange(of: model.searchFocusDismissal) { _, _ in isSearchFocused = false }
        .onDisappear {
            isSearchFocused = false
            search.cancel()
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if search.isLoading || !search.hasSearched {
            ProgressView("Searching…")
                .accessibilityIdentifier("radio.search.loading")
        } else if let error = search.errorMessage {
            Text(error).foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("radio.search.error")
            Button { search.retry() } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("radio.search.retry")
        } else if search.filter == .songs {
            if search.songs.isEmpty { noResults }
            ForEach(search.songs) { track in
                seedButton(.song(track), subtitle: track.artistName, id: "radio.search.song.\(track.id)")
            }
        } else {
            if search.artists.isEmpty { noResults }
            ForEach(search.artists) { artist in
                seedButton(.artist(ArtistCredit(name: artist.title, id: artist.id)),
                           subtitle: "Artist", id: "radio.search.artist.\(artist.id)", artworkURL: artist.artworkURL)
            }
        }
    }

    private var noResults: some View {
        ContentUnavailableView.search(text: search.query)
            .accessibilityIdentifier("radio.search.empty")
    }

    private func seedButton(_ seed: RadioSeed, subtitle: String, id: String,
                            tuning: RadioTuning = RadioTuning(), artworkURL: URL? = nil) -> some View {
        Button {
            guard !model.isOffline else { return }
            isSearchFocused = false
            AppNavigationIntent.perform(in: model) { model.startRadio(seed: seed, tuning: tuning) }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: artworkURL ?? seed.artworkURL, title: seed.title, size: 48,
                            cornerRadius: seed.kind == "artist" ? 24 : 6)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(seed.title).appFont(.body, weight: .medium)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(subtitle).appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isOffline)
        .accessibilityLabel("Start \(seed.radioTitle), \(subtitle)")
        .accessibilityHint(model.isOffline ? "An internet connection is required" : "Starts radio from this \(seed.kind)")
        .accessibilityIdentifier(id)
    }
}

@MainActor
struct SeedRadioSessionSection: View {
    @Environment(MusicAppModel.self) private var model
    var identifier = "radio.session"
    @Binding var tuneSelection: RadioTuneSelection?

    var body: some View {
        if model.activeRadioSeed != nil || model.isStartingSeedRadio || model.seedRadioError != nil {
            Section {
                if model.isStartingSeedRadio {
                    ProgressView("Starting \(model.pendingRadioSeed?.radioTitle ?? "radio")…")
                        .accessibilityIdentifier("\(identifier).loading")
                    Button { model.cancelSeedRadioStart() } label: {
                        Text("Cancel").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("\(identifier).cancel")
                } else if let error = model.seedRadioError {
                    Text(error).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("\(identifier).error")
                    Button { model.retrySeedRadioStart() } label: {
                        Label("Try Again", systemImage: "arrow.clockwise").frame(minHeight: 44)
                    }
                    .disabled(model.isOffline)
                    .accessibilityIdentifier("\(identifier).retry")
                }

                if let seed = model.activeRadioSeed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(seed.radioTitle).appFont(.headline)
                            .accessibilityIdentifier(identifier)
                        Text(model.radioTuning.summary).appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("\(identifier).tuning")
                    }
                    Button {
                        guard let sessionID = model.seedRadioSessionID, !model.isStartingSeedRadio else { return }
                        AppNavigationIntent.perform(in: model) {
                            tuneSelection = RadioTuneSelection(id: sessionID, seed: seed, tuning: model.radioTuning)
                        }
                    } label: {
                        Label("Tune Radio", systemImage: "slider.horizontal.3").frame(minHeight: 44)
                    }
                    .disabled(model.isStartingSeedRadio || model.seedRadioSessionID == nil)
                    .accessibilityIdentifier("\(identifier).tune")
                    if model.isContinuingRadio && !model.isStartingSeedRadio {
                        ProgressView("Finding more songs…")
                            .accessibilityIdentifier("\(identifier).continuing")
                    } else if !model.isContinuingRadio, let error = model.radioContinuationError {
                        Text(error).foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("\(identifier).continuationError")
                        Button { model.retryRadioContinuation() } label: {
                            Label("Try More Songs", systemImage: "arrow.clockwise").frame(minHeight: 44)
                        }
                        .disabled(model.isOffline || model.isStartingSeedRadio)
                        .accessibilityIdentifier("\(identifier).retryContinuation")
                    }
                }
            } header: {
                Text(model.activeRadioSeed != nil ? "Current Radio" : "Radio")
            } footer: {
                if model.isOffline { Text("Radio needs an internet connection. Songs on this device can still play.") }
            }
        }
    }
}
