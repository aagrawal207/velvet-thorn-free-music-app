import SwiftUI

@MainActor
struct CollectionDetailView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var creditLineHeight: CGFloat = 20
    let collection: MusicCollection
    let spotlight: ArtistSpotlightLoader?

    @State private var catalogTracks: [Track]
    @State private var relatedCollections: [MusicCollection] = []
    @State private var releases: [MusicCollection] = []
    @State private var relatedArtists: [MusicCollection] = []
    @State private var credits: [ArtistCredit] = []
    @State private var artistArtworkURL: URL?
    @State private var artistPage: ArtistPage?
    @State private var artistSpotlight: ArtistSpotlightLoader?
    @State private var catalogTitle: String?
    @State private var loadedCollection: MusicCollection?
    @State private var albumDescription = AlbumDescriptionLoader()
    @State private var isVisible = false
    @State private var hasLoaded = false
    @State private var loadingRequest: UUID?
    @State private var errorMessage: String?
    @State private var providerHasMore = false
    @State private var visibleTrackCount = 30
    @State private var visibleFeaturedCount = 15
    @State private var visibleCollectionCount = 12
    @State private var isPlaylistSheetPresented = false

    init(collection: MusicCollection, spotlight: ArtistSpotlightLoader? = nil) {
        self.collection = collection
        self.spotlight = spotlight
        _catalogTracks = State(initialValue: collection.tracks)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width.isFinite ? min(max(0, geometry.size.width), 760) : 0

            ScrollView {
                // Plain stacks throughout: lazy measurement of these few large children oscillated during playback
                // once the collaborations section joined the page, pinning the main thread. Row counts are capped.
                VStack(alignment: .leading, spacing: 24) {
                    header(width: width, viewportHeight: geometry.size.height)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("collection.header")

                    albumDescriptionSection

                    if isLoading {
                        ProgressView()
                            .tint(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .accessibilityLabel("Loading")
                    }

                    if let errorMessage {
                        loadError(errorMessage)
                    }

                    if let artistSpotlight {
                        ArtistSpotlightCard(loader: artistSpotlight)
                    }

                    if let spotlight {
                        ArtistSpotlightControls(loader: spotlight)
                    }

                    if !tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if isArtist {
                                SectionHeader(title: "Top songs")
                                    .padding(.bottom, 8)
                            }
                            ForEach(tracks.prefix(visibleTrackCount)) { track in
                                if let spotlight {
                                    ArtistSpotlightSongRow(track: track, tracks: tracks, loader: spotlight)
                                } else {
                                    TrackRow(track: track, tracks: tracks, showsDuration: !isArtist)
                                }
                            }
                        }

                        if visibleTrackCount < tracks.count {
                            Button {
                                visibleTrackCount = min(visibleTrackCount + 30, tracks.count)
                            } label: {
                                Label("Show more songs", systemImage: "chevron.down")
                                    .appFont(.subheadline, weight: .semibold)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .background(AppTheme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.accent)
                            .accessibilityIdentifier("collection.loadMore")
                        }
                    } else if let spotlight, !spotlight.tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("No songs in \(spotlight.filter.title)")
                                .appFont(.headline)
                                .accessibilityIdentifier("artist.spotlight.emptyFilter")
                            Button { spotlight.filter = .all } label: {
                                Text("Show all songs").appFont(.subheadline, weight: .semibold)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("artist.spotlight.showAll")
                        }
                    }

                    // Appears only once a collaboration is known, so the layout never reserves space or spins.
                    if let artistSpotlight, !artistSpotlight.featuredTracks.isEmpty {
                        featuringSection(artistSpotlight.featuredTracks)
                    }

                    if isArtist {
                        if !releases.isEmpty {
                            collectionShelf(title: "Releases", items: releases, width: width)
                        }
                        if !relatedArtists.isEmpty {
                            collectionShelf(title: "Fans also like", items: relatedArtists, width: width)
                        }
                    } else if !relatedCollections.isEmpty {
                        relatedReleases(width: width)
                    }

                    if spotlight == nil && hasLoaded && !isLoading && tracks.isEmpty && !hasCollections && errorMessage == nil {
                        EmptyStateView(symbol: "music.note.list", title: "No music in this collection",
                                       message: "The catalog hasn't provided any playable songs or releases here.")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }

                    if providerHasMore && visibleTrackCount >= tracks.count {
                        Text("Showing the songs and releases currently provided by the catalog.")
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.artworkSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !isArtist && !tracks.isEmpty {
                        Text(Self.trackSummary(for: tracks, hasMore: providerHasMore))
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.artworkSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("collection.summary")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .environment(\.secondaryTextColor, AppTheme.artworkSecondaryText)
        }
        .background {
            ArtworkBackdrop(url: headerArtworkURL, fallbackTint: collectionColor)
        }
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                collectionMenu
            }
        }
        .task(id: collection) {
            isVisible = true
            guard spotlight == nil else { return }
            if loadedCollection != collection {
                loadedCollection = collection
                loadingRequest = nil
                albumDescription.reset(for: collection)
                catalogTracks = uniqueTracks(collection.tracks)
                relatedCollections = []
                releases = []
                relatedArtists = []
                credits = []
                artistArtworkURL = nil
                artistPage = nil
                artistSpotlight = nil
                catalogTitle = nil
                visibleTrackCount = 30
                visibleFeaturedCount = 15
                visibleCollectionCount = 12
                // Artist pages always fetch: releases and related artists never travel with the collection.
                hasLoaded = !tracks.isEmpty && !isArtist
                providerHasMore = false
                errorMessage = nil
            }
            if !hasLoaded { await loadCatalog() }
            // A no-op while the shared load runs or has finished; it only resumes after a failed attempt.
            artistSpotlight?.startLoadingSongs(catalog: model.catalog, library: model.library)
            await loadAlbumDescription()
        }
        .onDisappear {
            isVisible = false
            loadingRequest = nil
            albumDescription.cancel()
        }
        .onChange(of: spotlight?.filter) { _, _ in visibleTrackCount = 30 }
        .sheet(isPresented: AppNavigationIntent.binding($isPlaylistSheetPresented, in: model)) {
            NavigationStack {
                CollectionPlaylistSheet(tracks: tracks, suggestedName: title)
            }
            .appSheetChrome()
        }
    }

    @ViewBuilder
    private var albumDescriptionSection: some View {
        if collection.kind == .album, albumDescription.collection == collection {
            switch albumDescription.state {
            case .loaded(let description):
                AlbumDescriptionView(description: description)
                    .id(collection)
            case .loading:
                ProgressView("Loading album details")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.artworkSecondaryText)
                    .accessibilityIdentifier("album.description.loading")
            case .failed:
                HStack(spacing: 12) {
                    Text("Album details couldn't load.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.artworkSecondaryText)
                    Spacer(minLength: 0)
                    Button {
                        Task { await loadAlbumDescription(retry: true) }
                    } label: {
                        Text("Retry")
                            .appFont(.subheadline, weight: .semibold)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry album description")
                    .accessibilityIdentifier("album.description.retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("album.description.error")
            case .idle, .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func header(width: CGFloat, viewportHeight: CGFloat) -> some View {
        let layout = CollectionHeaderLayout(width: width, viewportHeight: viewportHeight,
                                            dynamicTypeSize: dynamicTypeSize, isArtist: isArtist)
        if layout.isHorizontal {
            HStack(alignment: .center, spacing: 28) {
                artwork(size: layout.artworkSide)
                headerDetails
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                artwork(size: layout.artworkSide)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                headerDetails
            }
        }
    }

    private func artwork(size: CGFloat) -> some View {
        let side = size.isFinite ? max(0, size) : 0
        return ArtworkView(url: headerArtworkURL, title: title,
                           size: side, cornerRadius: isArtist ? side / 2 : AppCorner.compact)
            .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
            .accessibilityHidden(true)
    }

    private var headerArtworkURL: URL? {
        if let artistArtworkURL { return ArtworkURL.preferred(artistArtworkURL, tier: .large) }
        return collection.artworkURL ?? tracks.first?.artworkURL
    }

    private var headerDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(spotlight != nil ? "ARTIST COLLECTION" : (collection.kind == .mix ? "MIX" : collection.kind.rawValue.uppercased()))
                    .appFont(.caption2, weight: .bold)
                    .tracking(1.8)
                    .foregroundStyle(collectionColor)
                if isArtist {
                    Spacer(minLength: 8)
                    followButton
                }
            }
            Text(title)
                .appFont(.largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("collection.title")
            if isArtist, let artistPage {
                Text(artistPage.monthlyAudience?.label ?? "Monthly audience unavailable")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.artworkSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("collection.monthlyAudience")
            }
            if collection.kind == .album, !credits.isEmpty {
                creditsRow
            } else if let headerSubtitle {
                Text(headerSubtitle)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.artworkSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tracks.isEmpty {
                playbackActions
                    .padding(.top, 6)
            }
        }
    }

    /// Provider subtitles often just restate the title or the kind; those add nothing under a large title.
    private var headerSubtitle: String? {
        guard !isArtist else { return nil }
        let subtitle = collection.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subtitle.isEmpty,
              subtitle.localizedCaseInsensitiveCompare(title) != .orderedSame,
              subtitle.localizedCaseInsensitiveCompare(collection.kind.rawValue) != .orderedSame else { return nil }
        return subtitle
    }

    /// The album's credited artists as links on one line; albums rarely credit more than two names.
    private var creditsRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                if index > 0 {
                    Text(",")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.artworkSecondaryText)
                        .padding(.trailing, 5)
                }
                Button {
                    AppNavigationIntent.perform(in: model) { Task { await model.openArtist(credit) } }
                } label: {
                    Text(credit.name)
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                        // The row keeps a text line's height below; the taller frame only widens the tap target.
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: creditLineHeight)
                .accessibilityLabel("Go to artist, \(credit.name)")
                .accessibilityIdentifier("collection.artist.\(credit.id ?? credit.name)")
            }
        }
    }

    @ViewBuilder
    private var playbackActions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                playButton
                HStack(spacing: 12) {
                    shuffleButton
                    saveButton
                }
            }
        } else {
            HStack(spacing: 12) {
                playButton
                shuffleButton
                saveButton
            }
        }
    }

    private var playButton: some View {
        Button {
            model.play(tracks)
        } label: {
            Label("Play", systemImage: "play.fill")
                .appFont(.headline, weight: .semibold)
                .padding(.horizontal, 24)
                .frame(minHeight: 50)
                .foregroundStyle(AppTheme.onAccent)
                .background(AppTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(title)")
        .accessibilityIdentifier("collection.play")
    }

    private var shuffleButton: some View {
        Button {
            model.play(tracks, shuffle: true)
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 50, height: 50)
                .background(AppTheme.raised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle \(title)")
        .accessibilityIdentifier("collection.shuffle")
    }

    private var saveButton: some View {
        Button {
            AppNavigationIntent.perform(in: model) { isPlaylistSheetPresented = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 50, height: 50)
                .background(AppTheme.raised, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add songs to a playlist")
        .accessibilityIdentifier("collection.save")
    }

    private var followButton: some View {
        let following = model.isFollowing(collection)
        return Button {
            Task { await model.toggleFollow(collection) }
        } label: {
            Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "person.badge.plus")
                .appFont(.subheadline, weight: .semibold)
                .foregroundStyle(following ? AppTheme.accent : AppTheme.primaryText)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .appGlass(in: Capsule(), interactive: true, tint: following ? AppTheme.accent.opacity(0.18) : nil)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.isFollowPending(collection))
        .accessibilityLabel(following ? "Following \(title)" : "Follow \(title)")
        .accessibilityHint(following ? "Unfollow" : "Get new release alerts")
        .accessibilityIdentifier("collection.follow")
    }

    private var collectionMenu: some View {
        Menu {
            Button("Add to a playlist", systemImage: "text.badge.plus") {
                AppNavigationIntent.perform(in: model) { isPlaylistSheetPresented = true }
            }
            Button("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") {
                for track in tracks { model.player.enqueue(track) }
                model.showToast("Added \(tracks.count) songs to the queue.")
            }
            Button("Like all songs", systemImage: "heart") {
                for track in tracks where !model.library.isFavorite(track) {
                    model.library.toggleFavorite(track)
                    if model.library.errorMessage != nil { return }
                }
                if model.library.errorMessage == nil {
                    model.showToast("Songs added to your likes.")
                }
            }
            .disabled(tracks.allSatisfy { model.library.isFavorite($0) })
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .disabled(tracks.isEmpty)
        .accessibilityLabel("Collection actions")
        .accessibilityIdentifier("collection.actions")
    }

    private func cardSize(for width: CGFloat) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 208 : min(180, max(130, (width - 56) / 2))
    }

    private func collectionShelf(title: String, items: [MusicCollection], width: CGFloat) -> some View {
        let size = cardSize(for: width)
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        CollectionCard(collection: item, size: size)
                    }
                }
            }
        }
    }

    /// Collaborations the provider's listing leaves out; rows play within this list so the queue stays on topic.
    private func featuringSection(_ featured: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Featuring \(title)", subtitle: ArtistSpotlight.countProvenance)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("artist.featuring.header")
            ForEach(featured.prefix(visibleFeaturedCount)) { track in
                TrackRow(track: track, tracks: featured)
            }
            if visibleFeaturedCount < featured.count {
                Button {
                    visibleFeaturedCount = min(visibleFeaturedCount + 15, featured.count)
                } label: {
                    Label("Show more", systemImage: "chevron.down")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(AppTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .padding(.top, 8)
                .accessibilityIdentifier("artist.featuring.more")
            }
        }
    }

    private func relatedReleases(width: CGFloat) -> some View {
        let size = cardSize(for: width)
        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Keep exploring")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(relatedCollections.prefix(visibleCollectionCount)) { related in
                        CollectionCard(collection: related, size: size)
                    }
                }
            }
            if visibleCollectionCount < relatedCollections.count {
                Button("Show more", systemImage: "plus") {
                    visibleCollectionCount = min(visibleCollectionCount + 12, relatedCollections.count)
                }
                .appFont(.body)
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
            }
        }
    }

    private func loadError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't load this collection", systemImage: "wifi.exclamationmark")
                .appFont(.headline, weight: .semibold)
            Text(message)
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            Button("Try again", systemImage: "arrow.clockwise") {
                Task {
                    await loadCatalog()
                    await loadAlbumDescription(retry: true)
                }
            }
            .appFont(.body)
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func loadCatalog() async {
        guard isVisible, loadedCollection == collection, !Task.isCancelled else { return }
        let requestID = UUID()
        let collectionID = collection.id
        loadingRequest = requestID
        errorMessage = nil
        defer {
            if loadingRequest == requestID { loadingRequest = nil }
        }

        do {
            if isArtist {
                let page = try await model.catalog.artist(id: collectionID)
                try Task.checkCancellation()
                guard isVisible, loadingRequest == requestID, loadedCollection == collection else { return }
                releases = uniqueCollections(page.releases, excluding: collectionID)
                relatedArtists = uniqueCollections(page.relatedArtists, excluding: collectionID)
                artistArtworkURL = page.artworkURL
                catalogTitle = page.name
                var spotlightPage = page
                spotlightPage.name = CatalogText.clean(page.name) ?? collection.title
                artistPage = spotlightPage
                let loader = ArtistSpotlightLoader(artist: spotlightPage, languageService: model.recordingLanguageService,
                                                   library: model.library)
                catalogTracks = loader.listedTracks
                artistSpotlight = loader
                loader.startLoadingSongs(catalog: model.catalog, library: model.library)
                providerHasMore = false
            } else {
                let page = try await model.catalog.browse(id: collectionID)
                try Task.checkCancellation()
                guard isVisible, loadingRequest == requestID, loadedCollection == collection else { return }
                catalogTracks = uniqueTracks(page.tracks)
                relatedCollections = uniqueCollections(page.collections, excluding: collectionID)
                credits = page.credits
                catalogTitle = page.title
                providerHasMore = page.continuation != nil
                if collection.kind == .album, let description = page.albumDescription {
                    albumDescription.accept(description, for: collection)
                }
            }
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            guard isVisible, !Task.isCancelled, loadingRequest == requestID, loadedCollection == collection else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadAlbumDescription(retry: Bool = false) async {
        guard isVisible, collection.kind == .album, loadedCollection == collection, !Task.isCancelled, !tracks.isEmpty else { return }
        if case .loaded = albumDescription.state, albumDescription.collection == collection { return }
        await albumDescription.load(for: collection, using: model.catalog as? any AlbumDescriptionProviding, retry: retry)
    }

    private func uniqueTracks(_ values: [Track]) -> [Track] {
        var ids = Set<String>()
        return values.filter { ids.insert($0.id).inserted }
    }

    private func uniqueCollections(_ values: [MusicCollection], excluding id: String) -> [MusicCollection] {
        var ids = Set<String>()
        return values.filter { $0.id != id && ids.insert($0.id).inserted }
    }

    private var title: String {
        guard let catalogTitle, !catalogTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return collection.title
        }
        return catalogTitle
    }

    private var isArtist: Bool { collection.kind == .artist }

    private var tracks: [Track] {
        if let spotlight { return spotlight.visibleTracks }
        if isArtist, let artistSpotlight { return artistSpotlight.listedTracks }
        return catalogTracks
    }

    private var isLoading: Bool { loadingRequest != nil }

    private var hasCollections: Bool { !relatedCollections.isEmpty || !releases.isEmpty || !relatedArtists.isEmpty }

    private var collectionColor: Color {
        switch collection.language {
        case .hindi: AppTheme.gold
        case .english: AppTheme.violet
        case nil: AppTheme.accent
        }
    }

    static func trackSummary(for tracks: [Track], hasMore: Bool = false) -> String {
        let count = "\(tracks.count) \(tracks.count == 1 ? "song" : "songs")"
        guard !hasMore else { return "\(count) loaded" }
        let durations = tracks.compactMap(\.duration)
        guard !tracks.isEmpty, durations.count == tracks.count,
              durations.allSatisfy({ $0.isFinite && $0 >= 1 }) else { return count }
        let total = durations.reduce(0, +)
        // TimeText caps at 99:59:59; an incomplete or unrepresentable total must not look exact.
        guard total.isFinite, total < 360_000 else { return count }
        return "\(count) · \(TimeText.duration(total))"
    }
}

struct CollectionHeaderLayout {
    let isHorizontal: Bool
    let artworkSide: CGFloat

    init(width: CGFloat, viewportHeight: CGFloat, dynamicTypeSize: DynamicTypeSize, isArtist: Bool = false) {
        let width = width.isFinite ? max(0, width) : 0
        isHorizontal = width >= 540 && !dynamicTypeSize.isAccessibilitySize
        // Leave the controls a usable column; accessibility text needs the full width below the cover.
        let available = isHorizontal ? width - 40 - 28 - 260 : width - 48
        var side = min(360, max(0, available))
        if viewportHeight.isFinite, viewportHeight > 0, viewportHeight < width {
            side = min(side, max(0, viewportHeight - 24))
        }
        artworkSide = side * (isArtist ? 0.9 : 1)
    }
}

@MainActor
private struct CollectionPlaylistSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    let suggestedName: String
    @State private var playlistName = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Playlist name", text: $playlistName)
                    .appFont(.body)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    .onSubmit { isNameFocused = false }
                    .accessibilityIdentifier("collection.playlistName")
                Button("Create and add \(tracks.count) \(tracks.count == 1 ? "song" : "songs")", systemImage: "plus") {
                    let id = model.library.createPlaylist(name: trimmedName)
                    guard model.library.playlists.contains(where: { $0.id == id }) else { return }
                    addTracks(to: id)
                }
                .appFont(.body)
                .disabled(trimmedName.isEmpty || tracks.isEmpty)
            } header: {
                Text("Create a playlist").appFont(.footnote)
            }
            .listRowBackground(AppTheme.surface)

            if !model.library.playlists.isEmpty {
                Section {
                    ForEach(model.library.playlists) { playlist in
                        Button {
                            addTracks(to: playlist.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .appFont(.body)
                                        .foregroundStyle(AppTheme.primaryText)
                                    Text("\(playlist.tracks.count) songs")
                                        .appFont(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "plus")
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Add to an existing playlist").appFont(.footnote)
                }
                .listRowBackground(AppTheme.surface)
            }

            if let error = model.library.errorMessage {
                Section {
                    Text(error)
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .listRowBackground(AppTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .tint(AppTheme.accent)
        .navigationTitle("Add to a playlist")
        .navigationBarTitleDisplayMode(.inline)
        .appSheetDoneButton(id: "collection.playlistSheet.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        .onAppear {
            if playlistName.isEmpty { playlistName = suggestedName }
        }
    }

    private var trimmedName: String { playlistName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addTracks(to id: UUID) {
        for track in tracks {
            model.library.add(track, to: id)
            if model.library.errorMessage != nil { return }
        }
        guard model.library.errorMessage == nil else { return }
        model.showToast("Songs added to your playlist.")
        AppNavigationIntent.perform(in: model) { dismiss() }
    }
}
