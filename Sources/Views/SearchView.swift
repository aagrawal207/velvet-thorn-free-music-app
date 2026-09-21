import SwiftUI

@MainActor
struct SearchView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @FocusState private var isSearchFocused: Bool
    @State private var searchAttempt = 0
    @State private var completedRequest: SearchRequest?
    @State private var isLoadingMore = false
    @State private var paginationTask: Task<Void, Never>?
    @State private var showsAllRecentSearches = false
    @State private var radioSetupExperience: RadioExperience?
    @State private var needsNavigationScrollReset = false

    var body: some View {
        ScrollViewReader { proxy in
            content(proxy: proxy)
        }
    }

    private func content(proxy: ScrollViewProxy) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                if verticalSizeClass != .compact {
                    Text("Search")
                        .appFont(.largeTitle, weight: .bold)
                        .padding(.horizontal, 20)
                }

                HStack(spacing: 12) {
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

                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id("search.top").accessibilityHidden(true)
                        LazyVStack(alignment: .leading, spacing: 22) {
                            filters
                            if request.query.isEmpty {
                                suggestions
                            } else if completedRequest != request {
                                searchProgress
                            } else {
                                searchResults(width: min(geometry.size.width, 760))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 760)
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
        .sheet(item: AppNavigationIntent.binding($radioSetupExperience, in: model, identity: { $0?.id })) { experience in
            RadioSetupView(experience: experience, model: model)
        }
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
            proxy.scrollTo("search.top", anchor: .top)
            isSearchFocused = true
            await Task.yield()
            guard !Task.isCancelled, focusRequest == model.searchFocusRequest, isSearchFocused else { return }
            proxy.scrollTo("search.top", anchor: .top)
        }
        .task(id: model.navigationPaths[.search, default: []].count) {
            guard model.navigationPaths[.search, default: []].isEmpty else {
                needsNavigationScrollReset = true
                return
            }
            guard needsNavigationScrollReset else { return }
            await Task.yield()
            guard !Task.isCancelled, model.selectedTab == .search,
                  model.navigationPaths[.search, default: []].isEmpty else { return }
            proxy.scrollTo("search.top", anchor: .top)
            needsNavigationScrollReset = false
        }
        .onChange(of: model.searchFocusDismissal) { _, _ in isSearchFocused = false }
        .onChange(of: model.selectedTab) { _, tab in
            if tab != .search { isSearchFocused = false }
        }
        .onChange(of: model.isPlayerPresented) { _, presented in
            if presented { hideKeyboard() }
        }
        .onChange(of: model.isSettingsPresented) { _, presented in
            if presented { hideKeyboard() }
        }
        .task(id: request) {
            let activeRequest = request
            paginationTask?.cancel()
            isLoadingMore = false
            guard !activeRequest.query.isEmpty else {
                await model.loadSearch()
                completedRequest = nil
                return
            }
            guard completedRequest != activeRequest || !model.hasSearched else { return }

            do {
                try await Task.sleep(for: .milliseconds(320))
                try Task.checkCancellation()
                await model.loadSearch()
                try Task.checkCancellation()
                guard request == activeRequest else { return }
                completedRequest = activeRequest
            } catch { }
        }
        .onDisappear {
            if !model.navigationPaths[.search, default: []].isEmpty { needsNavigationScrollReset = true }
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

            TextField("Songs, artists, albums…", text: $model.searchQuery)
                .appFont(.body)
                .frame(minHeight: 52)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .accessibilityLabel("Search music in any language")
                .accessibilityIdentifier("search.field")
                .onSubmit {
                    finishSearchEditing()
                    if completedRequest == request { searchAttempt += 1 }
                }

            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 44, height: 48)
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
                            .frame(minHeight: 44)
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

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !model.library.recentSearches.isEmpty { recentSearches }

            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Start somewhere good")
                    .padding(.bottom, 6)
                ForEach(["Kanye West", "A. R. Rahman", "Char Diwaari", "Shreya Ghoshal", "Radiohead"], id: \.self) { query in
                    Button {
                        useSuggestion(query)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 24)
                            Text(query)
                                .appFont(.body, weight: .medium)
                                .foregroundStyle(AppTheme.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search for \(query)")
                    .accessibilityIdentifier("search.suggestion.\(query)")
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                radioHeader
                radioErrors
                if model.radioExperiences.isEmpty {
                    Text("No stations for your discovery languages yet.")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                    ForEach(model.radioExperiences) { experience in
                        radioTile(experience)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("search.radio")
        }
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recent searches")
                    .appFont(.title3, weight: .bold)
                Spacer(minLength: 8)
                Button("Clear all") {
                    model.library.clearRecentSearches()
                    showsAllRecentSearches = false
                }
                .appFont(.subheadline, weight: .semibold)
                .foregroundStyle(AppTheme.accent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("search.recents.clear")
            }
            ForEach(Array(model.library.recentSearches.prefix(showsAllRecentSearches ? SearchHistory.limit : 5)), id: \.self) { query in
                HStack(spacing: 4) {
                    Button { useSuggestion(query) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock")
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 24)
                            Text(query)
                                .appFont(.body)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Search again for \(query)")
                    .accessibilityIdentifier("search.recent.\(SearchHistory.key(query))")
                    Button { model.library.removeRecentSearch(query) } label: {
                        Image(systemName: "xmark")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 44, height: 48)
                    }
                    .accessibilityLabel("Remove \(query) from recent searches")
                    .accessibilityIdentifier("search.recent.remove.\(SearchHistory.key(query))")
                }
                .buttonStyle(.plain)
            }
            if model.library.recentSearches.count > 5 {
                Button(showsAllRecentSearches ? "Show fewer" : "Show all") { showsAllRecentSearches.toggle() }
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
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
                        hideKeyboard()
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
                        .frame(minHeight: 44)
                }
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
                        .frame(minHeight: 44)
                }
                .disabled(model.isContinuingRadio)
                .accessibilityIdentifier("search.station.retryContinuation")
            }
        }
    }

    private func radioTile(_ experience: RadioExperience) -> some View {
        let isLoading = model.isLoadingRadio && model.selectedRadioExperience?.stationID == experience.stationID
        let isActive = model.isActiveRadio(experience)
        let selection = experience.selection(for: model.library.preferences.languages)
        let color = experience.tone == .warm ? AppTheme.gold : AppTheme.violet
        let contentLabel = selection?.contentLabel ?? ""

        return ZStack(alignment: .topTrailing) {
            Button {
                hideKeyboard()
                if model.isLoadingRadio && model.selectedRadioExperience?.stationID == experience.stationID {
                    model.cancelPendingRadio()
                } else {
                    AppNavigationIntent.perform(in: model) { radioSetupExperience = experience }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: experience.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(color)
                            .frame(width: 24, height: 24)
                        Spacer()
                        Image(systemName: isActive ? "waveform" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                            .frame(width: 24, height: 24)
                            .opacity(isLoading ? 0 : 1)
                    }
                    Text(experience.title)
                        .appFont(.headline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(selection?.description ?? experience.description)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(["Radio", contentLabel]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .appFont(.caption, weight: .medium)
                        .foregroundStyle(color)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(isActive ? color : .clear, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(experience.radioTitle). \(contentLabel). \(selection?.description ?? experience.description)")
            .accessibilityValue(isLoading ? "Loading" : isActive ? "Current station" : "Play radio")
            .accessibilityHint(isLoading ? "Tap again to cancel loading" : "Set radio preferences and optional artist hints")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityIdentifier("search.station.\(experience.id)")

            // The overlay occupies the reserved icon slot without merging its progress semantics into the button.
            if isLoading {
                ProgressView()
                    .tint(color)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Loading \(experience.radioTitle)")
                    .accessibilityIdentifier("search.station.progress.\(experience.id)")
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var searchProgress: some View {
        ProgressView()
            .tint(AppTheme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .accessibilityLabel("Searching")
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
                Button("Try again", systemImage: "arrow.clockwise") {
                    model.cancelPendingArtistLookup()
                    if hasResults && model.searchPage.continuation != nil {
                        loadMore()
                    } else {
                        searchAttempt += 1
                    }
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.accent)
                .frame(minHeight: 44)
                .disabled(isLoadingMore)
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
                    TrackRow(track: track)
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
            model.open(artist)
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
            model.open(collection)
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
        .accessibilityIdentifier("collection.\(collection.id)")
    }

    private func searchCollectionCard(_ collection: MusicCollection, size: CGFloat) -> some View {
        Button { model.open(collection) } label: {
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
        .accessibilityIdentifier("collection.\(collection.id)")
    }

    private func useSuggestion(_ query: String) {
        model.searchFilter = .songs
        model.searchQuery = query
        finishSearchEditing()
    }

    private func finishSearchEditing() {
        model.commitSearch()
        hideKeyboard()
    }

    private func hideKeyboard() {
        isSearchFocused = false
        model.dismissSearchKeyboard()
    }

    private func loadMore() {
        guard !isLoadingMore, model.searchPage.continuation != nil else { return }
        let activeRequest = request
        isLoadingMore = true
        paginationTask?.cancel()
        paginationTask = Task { @MainActor in
            await model.loadMoreSearch()
            guard !Task.isCancelled, request == activeRequest else { return }
            isLoadingMore = false
        }
    }

    private var hasResults: Bool { !model.searchPage.tracks.isEmpty || !model.searchPage.collections.isEmpty }

    private var request: SearchRequest {
        SearchRequest(query: model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                      filter: model.searchFilter, attempt: searchAttempt)
    }

    private struct SearchRequest: Hashable {
        let query: String
        let filter: SearchFilter
        let attempt: Int
    }
}
