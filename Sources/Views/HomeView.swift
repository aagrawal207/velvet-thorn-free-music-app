import SwiftUI
import UIKit

@MainActor
struct HomeView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.momentMixController) private var momentMixController
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = HomeShelfMetrics(containerWidth: geometry.size.width, sizeClass: horizontalSizeClass,
                                           isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    masthead
                        .padding(.horizontal, 20)

                    HomeAnniversaryCard()

                    ForEach(visibleHomeSections) { section in
                        if hasContent(for: section) {
                            VStack(alignment: .leading, spacing: 30) {
                                homeSection(section, metrics: metrics)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("home.group.\(section.rawValue)")
                        }
                    }

                    if visibleHomeSections.isEmpty {
                        EmptyStateView(symbol: "square.grid.2x2", title: "Home Sections Are Hidden",
                                       message: "Open Settings, then Customize Home, to show your sections.")
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("home.empty.customized")
                    } else if isLoadingVisibleHome && !hasContent {
                        ProgressView()
                            .tint(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if !isLoadingVisibleHome && !hasContent {
                        VStack(spacing: 18) {
                            EmptyStateView(symbol: "sparkle.magnifyingglass", title: "Nothing Here Yet",
                                           message: "Search for an artist you love to start listening.")
                            Button {
                                model.selectTab(.search)
                            } label: {
                                Label("Search", systemImage: "magnifyingglass").appFont(.body).frame(minHeight: 44)
                                    .foregroundStyle(AppTheme.onAccent)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                            .controlSize(.large)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(AppTheme.background)
            .refreshable { await loadContent(force: true) }
        }
        .foregroundStyle(AppTheme.primaryText)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: loadRequest) {
            await loadContent()
        }
        .onAppear {
            isVisible = true
            if visibleHomeSections.contains(.newReleases) { model.library.markReleasesSeen() }
        }
        .onDisappear { isVisible = false }
    }

    // MARK: Sections

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(AppIcons.option(named: UIApplication.shared.alternateIconName).previewImageName)
                            .resizable().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Velvet Thorn")
                        .appFont(.title, weight: .bold, design: .rounded)
                }
                .accessibilityElement(children: .combine)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 4)
                    settingsButton
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    Spacer()
                    settingsButton
                }
            }
        }
    }

    private var settingsButton: some View {
        Button {
            model.isSettingsPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .appFont(.title3, weight: .medium)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .appGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("home.settings")
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSectionKind, metrics: HomeShelfMetrics) -> some View {
        switch section {
        case .recentlyPlayed:
            recentListening(metrics: metrics)
        case .madeForYou:
            mixes(metrics: metrics)
            momentMixes(metrics: metrics)
        case .newReleases:
            newReleases(metrics: metrics)
        case .becauseYouLike:
            ForEach(personalSections) { carousel($0, metrics: metrics) }
        case .charts:
            charts(metrics: metrics)
        case .discovery:
            if let error = model.homeError { homeError(error).padding(.horizontal, 20) }
            if !editorialSections.isEmpty {
                Text(discoveryLanguageSubtitle)
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("home.discovery.languages")
            }
            ForEach(editorialSections) { carousel($0, metrics: metrics) }
        case .superLiked:
            superLiked(metrics: metrics)
        }
    }

    private var discoveryLanguageSubtitle: String {
        let profile = model.listeningLanguageProfile
        if profile.isLearned { return "Languages based on your last 30 days of saved listening." }
        let fallback = model.library.preferences.languages
        let usesDefaults = (fallback.isEmpty || fallback == Set(MusicLanguage.allCases)) && profile.nudges.isAutomatic
        return usesDefaults ? "Starting with Hindi and English. Listening shapes these shelves."
            : "Languages start from your saved settings."
    }

    /// The first card keeps the column's 20-point inset; in wide windows the shelf scrolls out to the window edge.
    private func shelf<Content: View>(_ metrics: HomeShelfMetrics, @ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content()
                .padding(.horizontal, 20 + metrics.carouselBleed)
        }
        .padding(.horizontal, -metrics.carouselBleed)
    }

    @ViewBuilder
    private func mixes(metrics: HomeShelfMetrics) -> some View {
        let generated = (model.discoverWeekly.map { [$0] } ?? []) + model.dailyMixes
        if !generated.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(title: "Made for You")
                    .padding(.horizontal, 20)
                mixGrid(generated, metrics: metrics)
                    .padding(.horizontal, 20)
            }
        } else if model.isGeneratingMixes {
            HStack(spacing: 14) {
                ProgressView().tint(AppTheme.accent)
                Text("Making your mixes")
                    .appFont(.subheadline, weight: .medium)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.horizontal, 20)
            .accessibilityIdentifier("home.mixes.generating")
        } else if model.library.preferences.saveListeningHistory, !model.hasListeningProfile {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .appFont(.title3)
                    .foregroundStyle(AppTheme.gold)
                Text("Play a few songs to unlock your Discover Weekly and Daily Mix.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)
            .accessibilityIdentifier("home.mixes.hint")
        }
    }

    /// Every mix on screen at once, in reading order; unlike the carousels it stays inside the column on wide iPads.
    private func mixGrid(_ mixes: [GeneratedPlaylist], metrics: HomeShelfMetrics) -> some View {
        let rows = HomeShelfMetrics.gridRows(mixes, columns: metrics.mixGridColumns)
        return VStack(alignment: .leading, spacing: HomeShelfMetrics.mixGridRowSpacing) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: HomeShelfMetrics.mixGridSpacing) {
                    ForEach(rows[index]) { mix in
                        // Text sits below the art at the card's full width, so titles and focus lines stay readable.
                        mixCard(mix, size: metrics.mixCardWidth, tint: mix.kind == .discoverWeekly ? AppTheme.violet : dailyMixTint(mix.kind))
                    }
                }
                // The row takes its tallest card's ideal height, and the shorter cards stretch to match it.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.mixes")
    }

    /// Distinct cover tints distinguish neighbouring mixes without repeating the title below each tile.
    private func mixCard(_ mix: GeneratedPlaylist, size: CGFloat, tint: Color) -> some View {
        MixTile(collection: mix.collection, caption: mix.caption, size: size, tint: tint, textLines: 2, fillsRowHeight: true)
            .overlay(alignment: .top) {
                LinearGradient(colors: [tint.opacity(0), tint.opacity(0.35), tint.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private func momentMixes(metrics: HomeShelfMetrics) -> some View {
        if !momentCollections.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(title: "Your Moments")
                    .padding(.horizontal, 20)
                shelf(metrics) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(momentCollections.prefix(6)) { collection in
                            MixTile(collection: collection, caption: "From Your Listening",
                                    size: metrics.tileSize, tint: AppTheme.gold)
                                .accessibilityIdentifier("home.\(collection.id)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("home.moments")
        }
    }

    private var momentCollections: [MusicCollection] {
        guard model.library.preferences.saveListeningHistory else { return [] }
        return momentMixController?.collections ?? []
    }

    /// Fixed tints that stay distinct from Discover Weekly's violet and the accent used by Daily Mix 1.
    private func dailyMixTint(_ kind: GeneratedPlaylistKind) -> Color {
        switch kind {
        case .dailyMix2: AppTheme.gold
        case .dailyMix3:
            ([AppAccent.teal, .ocean, .mint].first { $0 != model.library.preferences.accent } ?? .teal).color
        default: AppTheme.accent
        }
    }

    private func newReleases(metrics: HomeShelfMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "New Releases")
                .padding(.horizontal, 20)
            shelf(metrics) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.library.releases.prefix(20)) { release in
                        CollectionCard(collection: MusicCollection(id: release.id, title: release.title, subtitle: release.subtitle,
                                                                   artworkURL: release.artworkURL, kind: .album),
                                       size: metrics.cardSize, caption: release.artistName)
                    }
                }
            }
        }
        .accessibilityIdentifier("home.releases")
    }

    private func recentListening(metrics: HomeShelfMetrics) -> some View {
        let recents = model.library.recentlyPlayed.map(\.track)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Recently Played", collection: MusicCollection(id: "home.recent", title: "Recently Played",
                                                                                 kind: .mix, tracks: recents))
                .padding(.horizontal, 20)

            if let recent = resumableListen {
                HomeResumeRow(recent: recent, tracks: recents)
                    .padding(.horizontal, 20)
            }

            shelf(metrics) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.library.recentlyPlayed.prefix(12)) { recent in
                        TrackCard(track: recent.track, tracks: recents, size: metrics.cardSize)
                    }
                }
            }
        }
    }

    /// The newest 20 super likes in Liked Songs order; the cap keeps the shelf a few swipes wide like New Releases.
    static let superLikedShelfLimit = 20

    /// Reads the library directly, so a promotion or demotion redraws the shelf through `favoritesRevision`.
    static func superLikedShelf(_ superLikes: [Track]) -> [Track] {
        Array(superLikes.prefix(superLikedShelfLimit))
    }

    /// The header opens Liked Songs on its Super Liked chip, on this tab, the way Stats' See All opens Recently Played.
    private func superLiked(metrics: HomeShelfMetrics) -> some View {
        let superLikes = model.library.superLikes
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Super Liked", tracks: superLikes, identifier: "home.superLiked.seeAll") {
                LibrarySavedSongsView(kind: .likes, initialFilter: .superLiked)
            }
            .padding(.horizontal, 20)

            shelf(metrics) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Self.superLikedShelf(superLikes)) { track in
                        TrackCard(track: track, tracks: superLikes, size: metrics.cardSize)
                    }
                }
            }
        }
    }

    private func charts(metrics: HomeShelfMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Charts")
                .padding(.horizontal, 20)
            shelf(metrics) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(visibleCharts) { chart in
                        MixTile(collection: collection(for: chart), caption: chartCaption(chart), size: metrics.tileSize,
                                tint: chart.language == .hindi ? AppTheme.gold : AppTheme.violet)
                    }
                }
            }
        }
    }

    private func carousel(_ section: DiscoverySection, metrics: HomeShelfMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: section.title, collection: collection(for: section))
                .padding(.horizontal, 20)
            if !section.tracks.isEmpty {
                shelf(metrics) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(section.tracks.prefix(16)) { track in
                            TrackCard(track: track, tracks: section.tracks, size: metrics.cardSize)
                        }
                    }
                }
            }
            if !section.collections.isEmpty {
                shelf(metrics) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(section.collections) { collection in
                            CollectionCard(collection: collection, size: metrics.cardSize)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("home.section.\(section.id)")
    }

    /// Title opens the full list; the play button starts it. Subtitles live on the detail page.
    @ViewBuilder
    private func sectionHeader(title: String, collection: MusicCollection? = nil) -> some View {
        if let collection {
            sectionHeader(title: title, tracks: collection.tracks) { CollectionDetailView(collection: collection) }
        } else {
            Text(title)
                .appFont(.title3, weight: .bold)
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// A shelf whose full list is its own page: title and chevron push it on this tab, play starts every song in order.
    private func sectionHeader<Destination: View>(title: String, tracks: [Track], identifier: String? = nil,
                                                  @ViewBuilder destination: () -> Destination) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppNavigationLink(destination: destination) {
                HStack(spacing: 6) {
                    Text(title)
                        .appFont(.title3, weight: .bold)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(title), see all")
            .accessibilityIdentifier(identifier ?? "")
            Spacer(minLength: 0)
            if !tracks.isEmpty {
                Button {
                    model.play(tracks)
                } label: {
                    Image(systemName: "play.fill")
                        .appFont(.footnote, weight: .bold)
                        .frame(width: 44, height: 44)
                        .appGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(title)")
            }
        }
    }

    private func homeError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Discovery needs another try", systemImage: "wifi.exclamationmark")
                .appFont(.headline, weight: .semibold)
            Text(message)
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            Button {
                Task { await model.loadHome(force: true) }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise").appFont(.body).frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.accent)
            .disabled(model.isLoadingHome)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Data

    private var visibleHomeSections: [HomeSectionKind] { model.library.preferences.homeLayout.visibleSections }

    private var loadRequest: HomeLoadRequest {
        HomeLoadRequest(languageProfileKey: model.listeningLanguageProfile.requestKey,
                        discoveryFamiliarity: model.library.preferences.discoveryFamiliarity,
                        isOffline: model.isOffline,
                        enabled: isVisible && model.selectedTab == .home && !model.isSettingsPresented,
                        needsCatalog: !catalogSections.isDisjoint(with: visibleHomeSections),
                        needsReleases: visibleHomeSections.contains(.newReleases))
    }

    private var catalogSections: Set<HomeSectionKind> { [.madeForYou, .becauseYouLike, .charts, .discovery] }

    private func loadContent(force: Bool = false) async {
        let request = loadRequest
        guard request.enabled, !Task.isCancelled else { return }
        if request.needsCatalog { await model.loadHome(force: force) }
        else if request.needsReleases { _ = await model.checkForNewReleases(force: force) }
    }

    private var visibleSections: [DiscoverySection] {
        model.homeSections.filter { section in
            !section.tracks.isEmpty || !section.collections.isEmpty
        }
    }

    private var personalSections: [DiscoverySection] { visibleSections.filter { $0.id.hasPrefix("personal.") } }
    private var editorialSections: [DiscoverySection] { visibleSections.filter { !$0.id.hasPrefix("personal.") } }

    private var visibleCharts: [ChartSnapshot] {
        model.charts.filter { !$0.entries.isEmpty }
    }

    private var hasContent: Bool {
        visibleHomeSections.contains { hasContent(for: $0) }
    }

    private func hasContent(for section: HomeSectionKind) -> Bool {
        switch section {
        case .recentlyPlayed:
            model.library.preferences.saveListeningHistory && !model.library.recentlyPlayed.isEmpty
        case .madeForYou:
            model.discoverWeekly != nil || !model.dailyMixes.isEmpty || model.isGeneratingMixes
                || !momentCollections.isEmpty
                || (model.library.preferences.saveListeningHistory && !model.hasListeningProfile)
        case .newReleases:
            !model.library.releases.isEmpty
        case .becauseYouLike:
            !personalSections.isEmpty
        case .charts:
            !visibleCharts.isEmpty
        case .discovery:
            !editorialSections.isEmpty || model.homeError != nil
        case .superLiked:
            !Self.superLikedShelf(model.library.superLikes).isEmpty
        }
    }

    private var isLoadingVisibleHome: Bool {
        (model.isLoadingHome && !catalogSections.isDisjoint(with: visibleHomeSections))
            || (model.isGeneratingMixes && visibleHomeSections.contains(.madeForYou))
            || (model.isCheckingNewReleases && visibleHomeSections.contains(.newReleases))
    }

    private var resumableListen: RecentListen? {
        model.library.recentlyPlayed.first { recent in
            guard recent.position.isFinite, recent.position > 5 else { return false }
            guard let duration = recent.track.duration, duration.isFinite, duration > 0 else { return true }
            return recent.position < duration - 10
        }
    }

    private func collection(for section: DiscoverySection) -> MusicCollection {
        MusicCollection(id: "section.\(section.id)", title: section.title, subtitle: section.subtitle,
                        artworkURL: section.tracks.first?.artworkURL, kind: .mix, language: section.language,
                        tracks: section.tracks)
    }

    private func collection(for chart: ChartSnapshot) -> MusicCollection {
        let entries = chart.entries.sorted { $0.rank < $1.rank }
        return MusicCollection(id: "chart:\(chart.id)", title: chartTitle(chart),
                               subtitle: [chart.subtitle, chart.source].filter { !$0.isEmpty }.joined(separator: " · "),
                               artworkURL: entries.first?.track.artworkURL, kind: .playlist,
                               language: chart.language, tracks: entries.map(\.track))
    }

    private func chartTitle(_ chart: ChartSnapshot) -> String { chart.title }

    /// Region and reporting period on one line; the year is dropped here and kept on the detail page.
    private func chartCaption(_ chart: ChartSnapshot) -> String {
        chart.subtitle.replacingOccurrences(of: ",? ?\\b(19|20)\\d{2}\\b", with: "", options: .regularExpression)
    }

    private struct HomeLoadRequest: Hashable {
        let languageProfileKey: String
        let discoveryFamiliarity: DiscoveryFamiliarity
        let isOffline: Bool
        let enabled: Bool
        let needsCatalog: Bool
        let needsReleases: Bool
    }
}

@MainActor
private struct HomeResumeRow: View {
    @Environment(MusicAppModel.self) private var model
    let recent: RecentListen
    let tracks: [Track]

    var body: some View {
        Button {
            if model.player.currentTrack?.id == recent.track.id {
                if model.player.isPlaying || model.player.isLoading {
                    model.isPlayerPresented = true
                } else {
                    model.player.togglePlayback()
                }
            } else {
                if model.play(recent.track, in: tracks) { model.player.seek(to: recent.position) }
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: recent.track.artworkURL, title: recent.track.title, size: 54, cornerRadius: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(recent.track.title)
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(1)
                    Text(isCurrentAndPlaying ? "Now playing" : "Resume at \(TimeText.duration(resumePosition))")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isCurrentAndPlaying ? "waveform" : "play.fill")
                    .appFont(.title3)
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 36, height: 44)
            }
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCurrentAndPlaying ? "Open player for \(recent.track.title)" : "Resume \(recent.track.title) at \(TimeText.duration(resumePosition))")
    }

    private var isCurrentAndPlaying: Bool {
        model.player.currentTrack?.id == recent.track.id && (model.player.isPlaying || model.player.isLoading)
    }

    private var resumePosition: TimeInterval {
        model.player.currentTrack?.id == recent.track.id ? model.player.position : recent.position
    }
}
