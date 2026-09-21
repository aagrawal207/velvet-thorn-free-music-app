import SwiftUI
import UIKit

@MainActor
struct HomeView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isVisible = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width.isFinite ? min(max(0, geometry.size.width), 760) : 0
            let cardSize = dynamicTypeSize.isAccessibilitySize ? 200 : min(150, max(124, width * 0.36))
            let tileSize = dynamicTypeSize.isAccessibilitySize ? max(0, width - 40) : min(230, max(140, (width - 54) / 2))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    masthead
                        .padding(.horizontal, 20)

                    ForEach(visibleHomeSections) { section in
                        if hasContent(for: section) {
                            VStack(alignment: .leading, spacing: 30) {
                                homeSection(section, cardSize: cardSize, tileSize: tileSize)
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("home.group.\(section.rawValue)")
                        }
                    }

                    if visibleHomeSections.isEmpty {
                        VStack(spacing: 16) {
                            EmptyStateView(symbol: "square.grid.2x2", title: "Make Home your own",
                                           message: "Choose the sections you want to see here.")
                            AppNavigationLink {
                                HomeCustomizationView()
                            } label: {
                                Text("Customize Home").appFont(.body, weight: .semibold).frame(minHeight: 44)
                                    .foregroundStyle(AppTheme.onAccent)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("home.customize.empty")
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.empty.customized")
                    } else if isLoadingVisibleHome && !hasContent {
                        ProgressView()
                            .tint(AppTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if !isLoadingVisibleHome && !hasContent {
                        VStack(spacing: 18) {
                            EmptyStateView(symbol: "sparkle.magnifyingglass", title: "Nothing here yet",
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
                .frame(maxWidth: 760)
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
                    Text("Breezy")
                        .appFont(.title, weight: .bold, design: .rounded)
                }
                .accessibilityElement(children: .combine)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: 4)
                    customizationLink
                    settingsButton
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    customizationLink
                    Spacer()
                    settingsButton
                }
            }
        }
    }

    private var customizationLink: some View {
        AppNavigationLink {
            HomeCustomizationView()
        } label: {
            Image(systemName: "square.grid.2x2")
                .appFont(.title3, weight: .medium)
                .frame(width: 46, height: 46)
                .appGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Customize Home")
        .accessibilityIdentifier("home.customize")
    }

    private var settingsButton: some View {
        Button {
            model.isSettingsPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .appFont(.title3, weight: .medium)
                .frame(width: 46, height: 46)
                .appGlass(in: Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("home.settings")
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSectionKind, cardSize: CGFloat, tileSize: CGFloat) -> some View {
        switch section {
        case .recentlyPlayed:
            recentListening(cardSize: cardSize)
        case .madeForYou:
            mixes(tileSize: tileSize)
        case .newReleases:
            newReleases(cardSize: cardSize)
        case .becauseYouLike:
            ForEach(personalSections) { carousel($0, cardSize: cardSize) }
        case .charts:
            charts(tileSize: tileSize)
        case .discovery:
            if let error = model.homeError { homeError(error).padding(.horizontal, 20) }
            ForEach(editorialSections) { carousel($0, cardSize: cardSize) }
        }
    }

    @ViewBuilder
    private func mixes(tileSize: CGFloat) -> some View {
        let weekly = model.discoverWeekly
        let daily = model.dailyMix
        if weekly != nil || daily != nil {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(title: "Made for you")
                    .padding(.horizontal, 20)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        if let weekly {
                            MixTile(collection: collection(for: weekly), caption: "New every Monday", size: tileSize, tint: AppTheme.violet)
                        }
                        if let daily {
                            MixTile(collection: collection(for: daily), caption: "Fresh every day", size: tileSize, tint: AppTheme.accent)
                        }
                    }
                    .padding(.horizontal, 20)
                }
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

    private func newReleases(cardSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "New releases")
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.library.releases.prefix(20)) { release in
                        CollectionCard(collection: MusicCollection(id: release.id, title: release.title, subtitle: release.subtitle,
                                                                   artworkURL: release.artworkURL, kind: .album),
                                       size: cardSize, caption: release.artistName)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .accessibilityIdentifier("home.releases")
    }

    private func recentListening(cardSize: CGFloat) -> some View {
        let recents = model.library.recentlyPlayed.map(\.track)
        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Recently played", collection: MusicCollection(id: "home.recent", title: "Recently played",
                                                                                 kind: .mix, tracks: recents))
                .padding(.horizontal, 20)

            if let recent = resumableListen {
                HomeResumeRow(recent: recent, tracks: recents)
                    .padding(.horizontal, 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(model.library.recentlyPlayed.prefix(12)) { recent in
                        TrackCard(track: recent.track, tracks: recents, size: cardSize)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func charts(tileSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: "Charts")
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(visibleCharts) { chart in
                        MixTile(collection: collection(for: chart), caption: chartCaption(chart), size: tileSize,
                                tint: chart.language == .hindi ? AppTheme.gold : AppTheme.violet)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func carousel(_ section: DiscoverySection, cardSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(title: section.title, collection: collection(for: section))
                .padding(.horizontal, 20)
            if !section.tracks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(section.tracks.prefix(16)) { track in
                            TrackCard(track: track, tracks: section.tracks, size: cardSize)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            if !section.collections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(section.collections) { collection in
                            CollectionCard(collection: collection, size: cardSize)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .accessibilityIdentifier("home.section.\(section.id)")
    }

    /// Title opens the full list; the play button starts it. Subtitles live on the detail page.
    @ViewBuilder
    private func sectionHeader(title: String, collection: MusicCollection? = nil) -> some View {
        if let collection {
            HStack(alignment: .center, spacing: 12) {
                AppNavigationLink {
                    CollectionDetailView(collection: collection)
                } label: {
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
                Spacer(minLength: 0)
                if !collection.tracks.isEmpty {
                    Button {
                        model.play(collection.tracks)
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
        } else {
            Text(title)
                .appFont(.title3, weight: .bold)
                .foregroundStyle(AppTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
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
                Label("Try again", systemImage: "arrow.clockwise").appFont(.body).frame(minHeight: 44)
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
        HomeLoadRequest(languages: model.library.preferences.languages,
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
            (section.language.map { model.library.preferences.languages.contains($0) } ?? true)
                && (!section.tracks.isEmpty || !section.collections.isEmpty)
        }
    }

    private var personalSections: [DiscoverySection] { visibleSections.filter { $0.id.hasPrefix("personal.") } }
    private var editorialSections: [DiscoverySection] { visibleSections.filter { !$0.id.hasPrefix("personal.") } }

    private var visibleCharts: [ChartSnapshot] {
        model.charts.filter { model.library.preferences.languages.contains($0.language) && !$0.entries.isEmpty }
    }

    private var hasContent: Bool {
        visibleHomeSections.contains { hasContent(for: $0) }
    }

    private func hasContent(for section: HomeSectionKind) -> Bool {
        switch section {
        case .recentlyPlayed:
            model.library.preferences.saveListeningHistory && !model.library.recentlyPlayed.isEmpty
        case .madeForYou:
            model.discoverWeekly != nil || model.dailyMix != nil || model.isGeneratingMixes
                || (model.library.preferences.saveListeningHistory && !model.hasListeningProfile)
        case .newReleases:
            !model.library.releases.isEmpty
        case .becauseYouLike:
            !personalSections.isEmpty
        case .charts:
            !visibleCharts.isEmpty
        case .discovery:
            !editorialSections.isEmpty || model.homeError != nil
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

    private func collection(for mix: GeneratedPlaylist) -> MusicCollection {
        let basis = mix.seedArtists.isEmpty ? "" : "Based on \(mix.seedArtists.joined(separator: ", ")) · "
        let cadence = mix.kind == .discoverWeekly ? "New every Monday" : "Fresh every day"
        return MusicCollection(id: "mix.\(mix.kind.rawValue)", title: mix.kind.title,
                               subtitle: basis + cadence + " · Made on this iPhone from your listening",
                               artworkURL: mix.tracks.first?.artworkURL, kind: .mix, tracks: mix.tracks)
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
        let languages: Set<MusicLanguage>
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
                model.play(recent.track, in: tracks)
                model.player.seek(to: recent.position)
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
