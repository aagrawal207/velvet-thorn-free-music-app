import SwiftUI

@MainActor
struct StorageSettingsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    private let artwork: ArtworkLoader

    @State private var audioUsage: AudioCache.Usage?
    @State private var artworkUsage: ArtworkLoader.Usage?
    @State private var hasLoadedUsage = false
    @State private var isRefreshing = false
    @State private var usageGeneration = UUID()
    @State private var audioReadError: String?
    @State private var messages: [ClearAction: String] = [:]
    @State private var errors: [ClearAction: String] = [:]
    @State private var confirmation: ClearAction = .audio
    @State private var isConfirming = false
    @State private var clearing: ClearAction?

    init(artwork: ArtworkLoader = .shared) {
        self.artwork = artwork
    }

    var body: some View {
        Form {
            audioSection
            artworkSection
            librarySection
            searchesSection
            Section {
                metric("Lyrics and lookups", value: "Memory only",
                       detail: "Lyrics text, catalog results and stream links use temporary memory. They are fetched again when needed. Lyrics timing adjustments are saved in your library.")
                    .accessibilityIdentifier("storage.memoryOnly")
                metric("YouTube sign-in", value: accountStatus,
                       detail: "Optional sign-in details use the iPhone Keychain. Manage sign-in in Settings.")
                    .accessibilityIdentifier("storage.account")
            } header: {
                Text("Other data").appFont(.caption)
            }
            .listRowBackground(AppTheme.surface)
        }
        .appFont(.body)
        .environment(\.defaultMinListRowHeight, 44)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("storage.screen")
        .refreshable { await refreshUsage() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refreshUsage()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: model.library.preferences.audioCacheLimit) { _, _ in
            usageGeneration = UUID()
        }
        .onChange(of: model.player.isUpdatingAudioCacheLimit) { _, updating in
            usageGeneration = UUID()
            if !updating {
                if let usage = model.player.audioCacheLimitUsage {
                    audioUsage = usage
                    audioReadError = nil
                    hasLoadedUsage = true
                }
                Task { await refreshUsage() }
            }
        }
        .alert(confirmation.title, isPresented: AppNavigationIntent.binding($isConfirming, in: model)) {
            Button("Clear", role: .destructive) {
                let action = confirmation
                Task { await clear(action) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmation.explanation)
        }
    }

    private var audioSection: some View {
        Section {
            if let usage = audioUsage {
                metric("Stored audio", value: Self.bytes(usage.bytes),
                       detail: "\(Self.songs(usage.songCount)) cached in full. Temporary copies of current, upcoming and suggested songs. iOS can remove them. Uncached songs need a connection.")
                    .accessibilityIdentifier("storage.audio.usage")
                if usage.pendingDownloads > 0 {
                    LabeledContent("Pending downloads", value: usage.pendingDownloads.formatted())
                        .accessibilityIdentifier("storage.audio.pending")
                }
            } else {
                metric("Stored audio", value: hasLoadedUsage ? "Unavailable" : "Calculating…",
                       detail: audioReadError ?? "Temporary audio caching is available only with a caching playback provider.")
                    .accessibilityIdentifier("storage.audio.usage")
            }
            audioCacheLimitRow
            if let usage = audioUsage {
                metric("Current cache policy", value: "\(Self.bytes(usage.capacityBytes)) or \(usage.maximumSongs.formatted()) songs",
                       detail: "Audio in use can temporarily exceed these limits. Bytes include each cached version and files being prepared; songs count once.")
                    .accessibilityIdentifier("storage.audio.limit")
            }
            clearRow(.audio, enabled: hasLoadedUsage && audioUsage != nil,
                     detail: "Songs in use are kept so playback can continue. The cache can grow again as you listen.")
        } header: {
            Text("Temporary audio cache").appFont(.caption)
        }
        .listRowBackground(AppTheme.surface)
    }

    private var audioCacheLimitRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Audio cache limit", selection: Binding {
                model.library.preferences.audioCacheLimit
            } set: { limit in
                model.updatePreferences { $0.audioCacheLimit = limit }
            }) {
                ForEach(AudioCacheLimit.allCases) { limit in
                    Text(limit.title).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .disabled(clearing != nil || !hasLoadedUsage || audioUsage == nil)
            .accessibilityIdentifier("storage.audio.limitPicker")
            description("Older unused songs are removed when this fills up.")
            if model.player.isUpdatingAudioCacheLimit {
                ProgressView("Updating cache limit…")
                    .appFont(.caption)
                    .accessibilityIdentifier("storage.audio.updatingLimit")
            } else if let error = audioCacheLimitProblem {
                Text(error)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityIdentifier("storage.audio.limitError")
                Button {
                    model.player.setAudioCacheLimit(model.library.preferences.audioCacheLimit)
                } label: {
                    Text("Try again")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(clearing != nil)
                .accessibilityIdentifier("storage.audio.retryLimit")
            }
        }
    }

    private var audioCacheLimitProblem: String? {
        if let error = model.player.audioCacheLimitError { return "Couldn’t apply the saved limit. \(error)" }
        let selected = model.library.preferences.audioCacheLimit
        if let usage = audioUsage, usage.capacityBytes != selected.bytes || usage.maximumSongs != selected.maximumSongs {
            return "The saved limit hasn’t been applied. The current policy is shown below."
        }
        return nil
    }

    private var artworkSection: some View {
        Section {
            metric("On disk", value: artworkUsage.map { Self.bytes($0.diskBytes) } ?? "Calculating…",
                   detail: artworkUsage.map { "Cover images kept temporarily, up to \(Self.bytes($0.diskCapacity)). iOS manages this cache." })
                .accessibilityIdentifier("storage.artwork.disk")
            if let usage = artworkUsage {
                metric("Image memory", value: Self.bytes(usage.decodedBytes),
                       detail: "\(usage.decodedImages.formatted()) \(usage.decodedImages == 1 ? "image" : "images") ready to display, up to \(Self.bytes(usage.decodedCapacity)).")
                    .accessibilityIdentifier("storage.artwork.images")
                metric("Image data memory", value: Self.bytes(usage.responseMemoryBytes),
                       detail: "Downloaded artwork held in memory, up to \(Self.bytes(usage.responseMemoryCapacity)).")
                    .accessibilityIdentifier("storage.artwork.responses")
            }
            clearRow(.artwork, enabled: artworkUsage != nil,
                     detail: "Clears saved artwork and image memory. Artwork loads again as you browse.")
        } header: {
            Text("Artwork cache").appFont(.caption)
        }
        .listRowBackground(AppTheme.surface)
    }

    private var librarySection: some View {
        Section {
            metric("Library data", value: Self.bytes(model.library.storageBytes),
                    detail: "Saved on this iPhone. Includes preferences and lyrics timing adjustments. Clearing caches keeps this data.")
                .accessibilityIdentifier("storage.library.bytes")
            LabeledContent("Liked songs", value: model.library.favorites.count.formatted())
                .accessibilityIdentifier("storage.library.likes")
            LabeledContent("Playlists", value: model.library.playlists.count.formatted())
                .accessibilityIdentifier("storage.library.playlists")
            metric("Listening sessions", value: model.library.events.count.formatted(),
                   detail: "\(Self.songs(model.library.recentlyPlayed.count)) in recently played. History helps build your personal mixes and recap.")
            metric("Saved queue", value: Self.songs(model.library.playback.queue.count),
                   detail: "Song details, playback position, shuffle and repeat. Saving a song in your library does not save its audio.")
            metric("Followed artists", value: model.library.followedArtists.count.formatted(),
                   detail: "Saved release updates: \(model.library.releases.count.formatted()).")
            LabeledContent("Personal mixes", value: model.library.mixes.count.formatted())
            LabeledContent("Disliked songs", value: model.library.disliked.count.formatted())
            metric("Tips recorded", value: model.library.tipCount.formatted(),
                   detail: "Verified tip transaction identifiers are saved in your library to avoid counting the same purchase twice. Apple handles payment details.")
            if let error = model.library.errorMessage {
                Text(error)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityIdentifier("storage.library.error")
            }
            if model.library.requiresReload {
                LibraryReloadButton(identifier: "storage.library.reload")
            }
        } header: {
            Text("Saved library").appFont(.caption)
        }
        .listRowBackground(AppTheme.surface)
    }

    private var searchesSection: some View {
        Section {
            metric("Saved searches", value: model.library.recentSearches.count.formatted(),
                   detail: "Recent search terms are stored in your library on this iPhone.")
                .accessibilityIdentifier("storage.searches.count")
            clearRow(.searches, enabled: !model.library.recentSearches.isEmpty,
                     detail: "Removes saved search terms. Your listening history stays.")
        } header: {
            Text("Recent searches").appFont(.caption)
        }
        .listRowBackground(AppTheme.surface)
    }

    private func metric(_ title: String, value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: value)
            if let detail { description(detail) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func clearRow(_ action: ClearAction, enabled: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(role: .destructive) {
                AppNavigationIntent.perform(in: model) {
                    confirmation = action
                    isConfirming = true
                }
            } label: {
                HStack {
                    Text(clearing == action ? "Clearing…" : action.label)
                    Spacer()
                    if clearing == action { ProgressView() }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(!enabled || clearing != nil || model.player.isUpdatingAudioCacheLimit)
            .accessibilityIdentifier("storage.clear.\(action.rawValue)")
            description(detail)
            if let error = errors[action] {
                Text(error).appFont(.caption).foregroundStyle(AppTheme.accent)
                    .accessibilityIdentifier("storage.error.\(action.rawValue)")
            } else if let message = messages[action] {
                description(message)
                    .accessibilityIdentifier("storage.result.\(action.rawValue)")
            }
        }
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .appFont(.caption)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accountStatus: String {
        if model.account.errorMessage != nil { return "Check account settings" }
        if model.account.isExpired { return "Expired, in Keychain" }
        return model.account.isSignedIn ? "Saved in Keychain" : "Not signed in"
    }

    private func refreshUsage() async {
        guard clearing == nil, !isRefreshing, !model.player.isUpdatingAudioCacheLimit else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let generation = usageGeneration
        let audio: AudioCache.Usage?
        let readError: String?
        do {
            audio = try await model.player.audioCacheUsage()
            readError = nil
        } catch {
            audio = nil
            readError = error.localizedDescription
        }
        let artworkSnapshot = await artwork.storageUsage()
        guard !Task.isCancelled, generation == usageGeneration, clearing == nil, !model.player.isUpdatingAudioCacheLimit else { return }
        audioUsage = audio
        audioReadError = readError
        artworkUsage = artworkSnapshot
        hasLoadedUsage = true
    }

    private func clear(_ action: ClearAction) async {
        guard clearing == nil else { return }
        clearing = action
        usageGeneration = UUID()
        errors[action] = nil
        messages[action] = nil
        defer { clearing = nil }
        switch action {
        case .audio:
            do {
                audioUsage = try await model.player.clearTemporaryAudioCache()
                audioReadError = nil
                if let usage = audioUsage {
                    messages[action] = usage.retainedSongCount == 0 ? "Unused audio removed."
                        : "Unused audio removed. \(Self.songs(usage.retainedSongCount)) (\(Self.bytes(usage.retainedBytes))) kept for playback."
                } else { errors[action] = "This playback provider has no audio cache to clear." }
            } catch {
                errors[action] = "Audio could not be fully cleared. \(error.localizedDescription)"
                do {
                    audioUsage = try await model.player.audioCacheUsage()
                    audioReadError = nil
                } catch {
                    audioUsage = nil
                    audioReadError = error.localizedDescription
                }
            }
        case .artwork:
            let usage = await artwork.clearCache()
            artworkUsage = usage
            let remaining = usage.diskBytes + usage.responseMemoryBytes + usage.decodedBytes
            messages[action] = remaining == 0 ? "Artwork cache cleared."
                : "Clear requested. iOS still reports \(Self.bytes(remaining)) in the artwork cache."
        case .searches:
            model.library.clearRecentSearches()
            if let error = model.library.errorMessage { errors[action] = error }
            else { messages[action] = "Recent searches cleared." }
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .binary)
    }

    private static func songs(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count.formatted()) songs"
    }

    private enum ClearAction: String {
        case audio, artwork, searches

        var label: String {
            switch self {
            case .audio: "Clear audio cache"
            case .artwork: "Clear artwork cache"
            case .searches: "Clear recent searches"
            }
        }

        var title: String {
            switch self {
            case .audio: "Clear temporary audio?"
            case .artwork: "Clear artwork cache?"
            case .searches: "Clear recent searches?"
            }
        }

        var explanation: String {
            switch self {
            case .audio: "Unused cached songs will be removed. Songs in use are kept. Uncached songs need a connection."
            case .artwork: "Artwork will load again as you browse. Your saved library and sign-in stay."
            case .searches: "This removes saved search terms from this iPhone. Your listening history stays."
            }
        }
    }
}
