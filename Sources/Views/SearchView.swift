import SwiftUI

@MainActor
struct SearchView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var searchAttempt = 0
    @State private var completedRequest: SearchRequest?
    @State private var isLoadingMore = false
    @State private var paginationTask: Task<Void, Never>?
    @State private var showsAllRecentSelections = false

    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || DebugBootstrap.requestsReducedMotion
        #else
        systemReduceMotion
        #endif
    }

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy: proxy)
        }
    }

    private func content(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            // Title, field, and results share one column so regular widths do not stretch the header alone.
            let columnWidth = AppLayout.contentMaxWidth(for: horizontalSizeClass)
            VStack(alignment: .leading, spacing: 16) {
                if verticalSizeClass != .compact {
                    Text("Search")
                        .appFont(.largeTitle, weight: .bold)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: columnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }

                let fieldLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4)) : AnyLayout(HStackLayout(spacing: 12))
                fieldLayout {
                    searchField
                    if isSearchFocused {
                        Button(action: finishSearchEditing) {
                            Text("Done")
                                .appFont(.subheadline, weight: .semibold)
                                .foregroundStyle(AppTheme.accent)
                                .frame(minWidth: 44, minHeight: 52)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.dismissKeyboard")
                    }
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id("search.top").accessibilityHidden(true)
                        LazyVStack(alignment: .leading, spacing: 22) {
                            if model.library.errorMessage != nil { LibraryStoreNotices() }
                            if model.isOffline { offlineNotice }
                            if !request.query.isEmpty, !model.isOffline, model.hasExecutedCurrentSearch {
                                filters
                            }
                            if request.query.isEmpty {
                                discovery
                            } else if model.isOffline {
                                offlineResults
                            } else if completedRequest != request {
                                searchProgress
                            } else {
                                searchResults(width: min(geometry.size.width, columnWidth))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: columnWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("search.content")
                .id(request)
            }
            .padding(.top, 12)
            .background(AppTheme.background)
        }
        .foregroundStyle(AppTheme.primaryText)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearchFocused {
                HStack {
                    Spacer()
                    Button(action: finishSearchEditing) {
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                            .appFont(.subheadline, weight: .semibold)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("search.dismissKeyboard.toolbar")
                }
                .padding(.horizontal, 8)
                .background(.regularMaterial)
            }
        }
        .task(id: model.searchFocusRequest) {
            let focusRequest = model.searchFocusRequest
            await Task.yield()
            guard !Task.isCancelled, model.consumeSearchFocusRequest(focusRequest) else { return }
            isSearchFocused = true
            await Task.yield()
            guard !Task.isCancelled, focusRequest == model.searchFocusRequest, isSearchFocused else { return }
            var transaction = Transaction(animation: reduceMotion ? nil : .easeInOut(duration: 0.35))
            transaction.disablesAnimations = reduceMotion
            withTransaction(transaction) {
                proxy.scrollTo("search.top", anchor: .top)
            }
        }
        .onChange(of: model.searchFocusDismissal) { _, _ in isSearchFocused = false }
        .onChange(of: model.selectedTab) { _, tab in
            if tab != .search { isSearchFocused = false }
        }
        .task(id: request) {
            let activeRequest = request
            paginationTask?.cancel()
            isLoadingMore = false
            guard !activeRequest.isOffline else {
                completedRequest = nil
                return
            }
            guard !activeRequest.query.isEmpty else {
                await model.loadSearch()
                completedRequest = nil
                return
            }
            guard completedRequest != activeRequest || !model.hasSearched else { return }

            do {
                try await Task.sleep(for: .milliseconds(320))
                try Task.checkCancellation()
                guard request == activeRequest, !model.isOffline else { return }
                await model.loadSearch()
                try Task.checkCancellation()
                guard request == activeRequest else { return }
                completedRequest = activeRequest
            } catch { }
        }
        .onDisappear {
            isSearchFocused = false
            paginationTask?.cancel()
            isLoadingMore = false
        }
    }

    private var searchField: some View {
        @Bindable var model = model

        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .appFont(.body, weight: .medium)
                .foregroundStyle(AppTheme.secondaryText)

            TextField(model.isOffline ? "Search your saved music" : "Songs, artists, albums…", text: $model.searchQuery)
                .appFont(.body)
                .frame(minHeight: 52)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .accessibilityLabel(model.isOffline ? "Search your saved music" : "Search music in any language")
                .accessibilityIdentifier("search.field")
                .onSubmit {
                    finishSearchEditing()
                    if !model.isOffline, completedRequest == request { searchAttempt += 1 }
                }

            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("search.clear")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, model.searchQuery.isEmpty ? 16 : 2)
        .frame(minHeight: 52)
        .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 15))
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(SearchFilter.allCases) { filter in
                    let selected = model.searchFilter == filter
                    Button {
                        model.searchFilter = filter
                    } label: {
                        Text(filter.title)
                            .appFont(.subheadline, weight: .semibold)
                            .padding(.horizontal, 18)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(selected ? AppTheme.background : AppTheme.secondaryText)
                            .background(selected ? AppTheme.primaryText : AppTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("search.filter.\(filter.rawValue)")
                }
            }
        }
    }

    private var discovery: some View {
        VStack(alignment: .leading, spacing: 24) {
            libraryShortcuts
            AppNavigationLink {
                SearchRadioBrowseView()
            } label: {
                navigationRow(title: "Radio", subtitle: "Stations for a mood or genre",
                              symbol: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.radio.open")
            recentSelections
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.discovery")
    }

    private var libraryShortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            let columns = Array(repeating: GridItem(.flexible(), alignment: .top),
                                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                AppNavigationLink {
                    LibrarySavedSongsView(kind: .likes)
                } label: {
                    libraryCard(title: "Liked songs",
                                subtitle: model.library.hasLoadedDocument ? songCount(model.library.favorites.count) : "Library unavailable",
                                symbol: "heart.fill", tint: AppTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.library.likes")

                AppNavigationLink {
                    CachedSongsView()
                } label: {
                    libraryCard(title: "Cached songs", subtitle: "On this device",
                                symbol: "arrow.down.circle.fill", tint: AppTheme.gold)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.library.cached")
            }

            if !model.library.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Your playlists")
                    ForEach(model.library.playlists.sorted { $0.updatedAt > $1.updatedAt }.prefix(3)) { playlist in
                        AppNavigationLink {
                            LibraryUserPlaylistView(playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 14) {
                                ArtworkView(url: playlist.tracks.first?.artworkURL, title: playlist.name,
                                            size: 52, cornerRadius: 6)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name)
                                        .appFont(.subheadline, weight: .semibold)
                                        .foregroundStyle(AppTheme.primaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("Playlist · \(songCount(playlist.tracks.count))")
                                        .appFont(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .appFont(.caption, weight: .semibold)
                                    .foregroundStyle(AppTheme.secondaryText)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(playlist.name), Playlist, \(songCount(playlist.tracks.count))")
                        .accessibilityIdentifier("search.library.playlist.\(playlist.id.uuidString)")
                    }
                }
            }
            openLibraryButton
        }
    }

    private func libraryCard(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .appFont(.title2, weight: .semibold)
                .foregroundStyle(tint)
                .frame(height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .appFont(.headline, weight: .semibold)
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(16)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .contentShape(RoundedRectangle(cornerRadius: AppCorner.card))
    }

    private var openLibraryButton: some View {
        Button { model.openLibrary() } label: {
            navigationRow(title: "Your library", symbol: "square.stack")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search.library.open")
    }

    private func navigationRow(title: String, subtitle: String? = nil, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .appFont(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.compact))
        .contentShape(RoundedRectangle(cornerRadius: AppCorner.compact))
    }

    private var recentSelections: some View {
        let selections = model.library.recentSearchSelections
        let headerLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
        return VStack(alignment: .leading, spacing: 8) {
            headerLayout {
                Text("Recently opened")
                    .appFont(.title3, weight: .bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if !selections.isEmpty {
                    Button {
                        model.clearRecentSearchSelections()
                        if model.library.recentSearchSelections.isEmpty { showsAllRecentSelections = false }
                    } label: {
                        Text("Clear all")
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppTheme.accent)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear recently opened items")
                    .accessibilityIdentifier("search.recents.clear")
                }
            }
            if !model.library.hasLoadedDocument {
                Text("Your saved library couldn’t be read. Recently opened items aren’t available.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("search.recents.unavailable")
            } else if selections.isEmpty {
                Text(model.library.requiresReload
                     ? "Your library needs attention before recently opened items can be saved."
                     : "Songs, artists, albums, and playlists you open from search will appear here.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("search.recents.empty")
            }
            ForEach(Array(selections.prefix(showsAllRecentSelections ? selections.count : 5)), id: \.id) { selection in
                HStack(spacing: 4) {
                    Button { model.activateSearchSelection(selection, source: .recent) } label: {
                        HStack(spacing: 14) {
                            ArtworkView(url: selection.artworkURL, title: selection.title, size: 52,
                                        cornerRadius: recentArtworkCornerRadius(selection))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selection.title)
                                    .appFont(.subheadline, weight: .semibold)
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                Text([selection.typeTitle, selection.subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .appFont(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel([selection.title, selection.typeTitle, selection.subtitle]
                        .filter { !$0.isEmpty }.joined(separator: ", "))
                    .accessibilityHint("Reopen \(selection.typeTitle.lowercased())")
                    .accessibilityIdentifier("search.recent.\(selection.id)")
                    Button { model.removeRecentSearchSelection(id: selection.id) } label: {
                        Image(systemName: "xmark")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 44, height: 48)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove \(selection.typeTitle.lowercased()) \(selection.title) from recently opened")
                    .accessibilityIdentifier("search.recent.remove.\(selection.id)")
                }
                .buttonStyle(.plain)
            }
            if selections.count > 5 {
                Button { showsAllRecentSelections.toggle() } label: {
                    Text(showsAllRecentSelections ? "Show fewer" : "Show all")
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.accent)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.recents.showAll")
            }
        }
    }

    private func recentArtworkCornerRadius(_ selection: SearchSelection) -> CGFloat {
        if case .collection(let collection) = selection, collection.kind == .artist { return 26 }
        return 6
    }

    private var offlineNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("You’re offline", systemImage: "wifi.slash")
                .appFont(.headline, weight: .semibold)
            Text("Search your saved music. Cached songs can play without a connection.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.offline")
    }

    private var offlineResults: some View {
        let tracks = model.offlineSearchTracks(query: request.query)
        return VStack(alignment: .leading, spacing: 20) {
            AppNavigationLink {
                CachedSongsView()
            } label: {
                navigationRow(title: "Cached songs", subtitle: "On this device", symbol: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.library.cached")
            openLibraryButton

            if tracks.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No saved songs found",
                               message: "Try a title, artist, or album from your library.")
                    .accessibilityIdentifier("search.offline.empty")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Your songs")
                        .padding(.bottom, 8)
                    ForEach(tracks) { track in
                        TrackRow(track: track, accessibilityMetadata: "Song", onSelect: {
                            model.activateSearchSelection(.track(track), source: .result)
                        }, searchOrigin: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("search.offline.results")
            }
        }
    }

    private func songCount(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "song" : "songs")"
    }

    private var searchProgress: some View {
        ProgressView()
            .tint(AppTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .accessibilityLabel("Searching")
            .accessibilityIdentifier("search.progress")
    }

    @ViewBuilder
    private func searchResults(width: CGFloat) -> some View {
        if let error = model.searchError {
            VStack(alignment: .leading, spacing: 12) {
                Label("Search couldn't finish", systemImage: "wifi.exclamationmark")
                    .appFont(.headline, weight: .semibold)
                Text(error)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                Button {
                    model.cancelPendingArtistLookup()
                    if hasResults && model.searchPage.continuation != nil {
                        loadMore()
                    } else {
                        searchAttempt += 1
                    }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
                .disabled(isLoadingMore)
                .accessibilityIdentifier("search.retry")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }

        if !hasResults && model.searchError == nil && model.hasSearched {
            EmptyStateView(symbol: "magnifyingglass", title: "No \(model.searchFilter.title.lowercased()) found",
                           message: "Try another spelling or a different filter.")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }

        if let corrected = model.searchPage.correctedQuery, hasResults {
            (Text("Showing results for ") + Text(corrected).fontWeight(.semibold).foregroundStyle(AppTheme.primaryText))
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("search.corrected")
        }

        if let artist = model.searchPage.featuredArtist {
            featuredArtistCard(artist)
        }

        if !model.searchPage.tracks.isEmpty {
            LazyVStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Songs")
                    .padding(.bottom, 12)
                ForEach(model.searchPage.tracks) { track in
                    // A tapped result plays alone; Autoplay's radio for that song fills the queue, so a search
                    // for one title is not followed by every other version of it.
                    TrackRow(track: track, accessibilityMetadata: "Song", onSelect: {
                        model.activateSearchSelection(.track(track), source: .result)
                    }, searchOrigin: true)
                }
            }
        }

        if !model.searchPage.collections.isEmpty {
            let size = min(204, max(120, (width - 54) / 2))
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: model.searchFilter.title)
                if dynamicTypeSize.isAccessibilitySize {
                    ForEach(model.searchPage.collections) { collection in
                        accessibleCollectionRow(collection)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size), alignment: .top)], alignment: .leading, spacing: 22) {
                        ForEach(model.searchPage.collections) { collection in
                            searchCollectionCard(collection, size: size)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }

        if model.searchPage.continuation != nil && hasResults {
            Button {
                loadMore()
            } label: {
                HStack(spacing: 10) {
                    if isLoadingMore { ProgressView().tint(AppTheme.accent) }
                    Text(isLoadingMore ? "Loading more…" : "More \(model.searchFilter.title.lowercased())")
                        .appFont(.subheadline, weight: .semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(AppTheme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .disabled(isLoadingMore)
            .accessibilityIdentifier("search.loadMore")
        }
    }

    private func featuredArtistCard(_ artist: MusicCollection) -> some View {
        Button {
            model.activateSearchSelection(.collection(artist), source: .result)
        } label: {
            HStack(spacing: 14) {
                ArtworkView(url: artist.artworkURL, title: artist.title, size: 64, cornerRadius: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.title)
                        .appFont(.headline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)
                    Text("Artist")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(artist.title), artist")
        .accessibilityIdentifier("search.featuredArtist")
    }

    private func accessibleCollectionRow(_ collection: MusicCollection) -> some View {
        Button {
            model.activateSearchSelection(.collection(collection), source: .result)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(url: collection.artworkURL, title: collection.title, size: 64,
                            cornerRadius: collection.kind == .artist ? 32 : 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(collection.title)
                        .appFont(.headline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                    if !collection.subtitle.isEmpty {
                        Text(collection.subtitle)
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collectionAccessibilityLabel(collection))
        .accessibilityIdentifier("collection.\(collection.id)")
    }

    private func searchCollectionCard(_ collection: MusicCollection, size: CGFloat) -> some View {
        Button { model.activateSearchSelection(.collection(collection), source: .result) } label: {
            VStack(alignment: collection.kind == .artist ? .center : .leading, spacing: 8) {
                ArtworkView(url: collection.artworkURL, title: collection.title, size: size,
                            cornerRadius: collection.kind == .artist ? size / 2 : 6)
                Text(collection.title)
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)
                if !collection.subtitle.isEmpty {
                    Text(collection.subtitle).appFont(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                }
            }
            .frame(width: size, alignment: collection.kind == .artist ? .center : .leading)
            .multilineTextAlignment(collection.kind == .artist ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collectionAccessibilityLabel(collection))
        .accessibilityIdentifier("collection.\(collection.id)")
    }

    private func collectionAccessibilityLabel(_ collection: MusicCollection) -> String {
        let selection = SearchSelection.collection(collection)
        return [selection.title, selection.typeTitle, selection.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func finishSearchEditing() {
        model.cancelPendingArtistLookup()
        hideKeyboard()
    }

    private func hideKeyboard() {
        isSearchFocused = false
        model.dismissSearchKeyboard()
    }

    private func loadMore() {
        guard !model.isOffline, !isLoadingMore, model.searchPage.continuation != nil else { return }
        let activeRequest = request
        isLoadingMore = true
        paginationTask?.cancel()
        paginationTask = Task { @MainActor in
            guard !Task.isCancelled, !model.isOffline, request == activeRequest else { return }
            await model.loadMoreSearch()
            guard !Task.isCancelled, request == activeRequest else { return }
            isLoadingMore = false
        }
    }

    private var hasResults: Bool { !model.searchPage.tracks.isEmpty || !model.searchPage.collections.isEmpty }

    private var request: SearchRequest {
        SearchRequest(query: model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                      filter: model.searchFilter, attempt: searchAttempt, isOffline: model.isOffline)
    }

    private struct SearchRequest: Hashable {
        let query: String
        let filter: SearchFilter
        let attempt: Int
        let isOffline: Bool
    }
}

@MainActor
private struct SearchRadioBrowseView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var radioSetupExperience: RadioExperience?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                radioHeader
                if model.isOffline {
                    Text("Radio needs a connection. You can still browse your library and cached songs from Search.")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                radioErrors
                ForEach(RadioExperience.Group.allCases) { group in
                    let stations = model.radioExperiences.filter { $0.group == group }
                    if !stations.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .appFont(.subheadline, weight: .semibold)
                                .foregroundStyle(AppTheme.secondaryText)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("search.radio.group.\(group.rawValue)")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: radioColumnCount),
                                      spacing: 10) {
                                ForEach(stations) { experience in
                                    radioTile(experience)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.radio")
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("search.radio.content")
        .sheet(item: AppNavigationIntent.binding($radioSetupExperience, in: model, identity: { $0?.id })) { experience in
            RadioSetupView(experience: experience, model: model)
        }
    }

    private var radioColumnCount: Int {
        if dynamicTypeSize.isAccessibilitySize { return 1 }
        return AppLayout.isRegularWidth(horizontalSizeClass) ? 3 : 2
    }

    private var radioHeader: some View {
        let active = model.activeRadioExperience
        let isContinuing = active != nil && model.isContinuingRadio && !model.isLoadingRadio

        return SectionHeader(title: "Find your radio")
            .padding(.trailing, 56)
            .frame(minHeight: 44)
            .overlay(alignment: .trailing) {
                if let active {
                    Button {
                        guard model.activeRadioExperience != nil else { return }
                        model.isPlayerPresented = true
                    } label: {
                        ZStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .appFont(.title3)
                                .opacity(isContinuing ? 0 : 1)
                            if isContinuing {
                                ProgressView()
                                    .tint(AppTheme.accent)
                                    .accessibilityIdentifier("search.station.progress.continuation")
                            }
                        }
                        .frame(width: 24, height: 24)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("Open \(active.radioTitle), \(model.activeRadioContentLabel ?? "radio")")
                    .accessibilityValue(isContinuing ? "Loading more songs" : "")
                    .accessibilityIdentifier("search.station.active")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.radio.header")
    }

    @ViewBuilder
    private var radioErrors: some View {
        if let error = model.radioError, let selected = model.selectedRadioExperience {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t start \(selected.radioTitle)")
                    .appFont(.headline, weight: .semibold)
                    .accessibilityIdentifier("search.station.error")
                Text(error).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
                Button { model.retryRadio() } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(model.isOffline)
                .accessibilityIdentifier("search.station.retry")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }

        if model.activeRadioExperience != nil, let error = model.radioContinuationError {
            VStack(alignment: .leading, spacing: 6) {
                Text(error).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
                Button { model.retryRadioContinuation() } label: {
                    Label("Try more songs", systemImage: "arrow.clockwise")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(model.isOffline || model.isContinuingRadio)
                .accessibilityIdentifier("search.station.retryContinuation")
            }
        }
    }

    private func radioTile(_ experience: RadioExperience) -> some View {
        let isLoading = model.isLoadingRadio && model.selectedRadioExperience?.stationID == experience.stationID
        let isActive = model.isActiveRadio(experience)
        let selection = experience.selection(for: model.listeningLanguageProfile)
        let color = experience.tone == .warm ? AppTheme.gold : AppTheme.violet
        let contentLabel = selection.contentLabel
        let copy = selection.description

        return ZStack(alignment: .trailing) {
            Button {
                if model.isLoadingRadio && model.selectedRadioExperience?.stationID == experience.stationID {
                    model.cancelPendingRadio()
                } else {
                    AppNavigationIntent.perform(in: model) { radioSetupExperience = experience }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: experience.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(color)
                        .frame(width: 22, height: 22)
                    Text(experience.title)
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isActive ? "waveform" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 20, height: 20)
                        .opacity(isLoading ? 0 : 1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(isActive ? color : .clear, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(model.isOffline && !isLoading)
            .accessibilityLabel("\(experience.radioTitle). \(contentLabel). \(copy)")
            .accessibilityValue(isLoading ? "Loading" : isActive ? "Current station" : "Play radio")
            .accessibilityHint(isLoading ? "Tap again to cancel loading" : "Set radio preferences and optional artist hints")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("search.station.\(experience.id)")

            // The overlay occupies the reserved icon slot without merging its progress semantics into the button.
            if isLoading {
                ProgressView()
                    .tint(color)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Loading \(experience.radioTitle)")
                    .accessibilityIdentifier("search.station.progress.\(experience.id)")
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
