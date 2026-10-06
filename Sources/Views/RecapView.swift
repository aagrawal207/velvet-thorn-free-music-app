import Charts
import SwiftUI

@MainActor
struct RecapView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var window: ListeningWindow = .week
    @State private var allTime = false
    @State private var showsAllRepeatTracks = false
    @State private var showsRecentlyPlayed = false
    @State private var shareRequest: RecapShareRequest?
    @ScaledMetric(relativeTo: .largeTitle) private var totalFontSize: CGFloat = 44

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            // Listening updates arrive between timeline ticks and must not be treated as future sessions.
            let now = Date()
            let summary = listeningSummary(now: now)
            let genres = genreSummary(summary)
            ScrollView {
                // Stable section heights avoid a lazy-placement loop when a populated recap becomes empty.
                VStack(alignment: .leading, spacing: 26) {
                    header
                    windowSelector
                    LibraryStoreNotices()
                    if allTime {
                        Text(RecapText.lifetimeCoverage(model.library.lifetimeListeningSummary))
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("recap.historyCoverage")
                    }
                    if summary.seconds > 0 || (allTime && model.library.lifetimeListeningSummary.seconds > 0) {
                        hero(summary, now: now)
                        metrics(summary)
                        sharing(summary, genres: genres, now: now)
                        if !summary.topTracks.isEmpty { onRepeat(summary) }
                        dayChart(summary, now: now)
                        if !summary.topArtists.isEmpty { artists(summary) }
                    } else {
                        emptyRecap
                    }
                    topGenres(genres)
                    listeningLanguagesEntry(summary, now: now)
                    countingNotes
                    if !model.library.recentlyPlayed.isEmpty { recentlyPlayed }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            }
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("recap.screen")
        .onChange(of: window) { showsAllRepeatTracks = false }
        .onChange(of: allTime) { showsAllRepeatTracks = false }
        .sheet(item: AppNavigationIntent.binding($shareRequest, in: model, identity: { $0?.id })) { request in
            RecapShareCardPreview(request: request).appPresentationEnvironment(model)
        }
    }

    /// The 20 newest songs, one row per song with its resume position; See all opens the retained history.
    private var recentlyPlayed: some View {
        let recents = model.library.recentlyPlayed
        let tracks = recents.map(\.track)
        return VStack(alignment: .leading, spacing: 14) {
            Button {
                showsRecentlyPlayed.toggle()
            } label: {
                HStack {
                    Text("Recently Played").appFont(.headline, weight: .semibold)
                    Spacer()
                    Image(systemName: showsRecentlyPlayed ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsRecentlyPlayed ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("recap.recent.toggle")
            if showsRecentlyPlayed {
                SectionHeader(title: "Newest First") {
                    AppNavigationLink {
                        LibrarySavedSongsView(kind: .recents)
                    } label: {
                        Text("See All")
                            .appFont(.subheadline, weight: .semibold)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityLabel("See All Recently Played")
                    .accessibilityIdentifier("recap.recent.all")
                }
                VStack(spacing: 6) {
                    ForEach(recents.prefix(20)) { recent in
                        LibraryRecentSongRow(recent: recent, tracks: tracks, identifierPrefix: "recap")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.recent")
    }

    private func listeningSummary(now: Date) -> ListeningSummary {
        allTime ? ListeningAnalytics.allAvailableSummary(events: model.library.events, now: now)
            : model.listeningSummary(for: window, now: now)
    }

    private func genreSummary(_ summary: ListeningSummary) -> ListeningGenreSummary {
        ListeningAnalytics.genreSummary(listening: summary, evidence: model.genreEvidence.distributions)
    }

    private func languageSummary(_ summary: ListeningSummary) -> ListeningLanguageSummary {
        ListeningAnalytics.languageSummary(listening: summary, evidence: model.languageDiscovery.results,
                                             overrides: model.library.recordingLanguageOverrides)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Stats")
                .appFont(.largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Time with your music, made from saved listening.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var windowSelector: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            ForEach(ListeningWindow.allCases) { option in
                Button {
                    window = option
                    allTime = false
                } label: {
                    Text(option.title)
                        .appFont(.subheadline, weight: .semibold)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(!allTime && window == option ? AppTheme.onAccent : AppTheme.primaryText)
                        .background(!allTime && window == option ? AppTheme.accent : AppTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title), last \(option.days) days")
                .accessibilityAddTraits(!allTime && window == option ? .isSelected : [])
                .accessibilityIdentifier("recap.window.\(option.rawValue)")
            }
            Button { allTime = true } label: {
                Text("All Time")
                    .appFont(.subheadline, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .foregroundStyle(allTime ? AppTheme.onAccent : AppTheme.primaryText)
                    .background(allTime ? AppTheme.accent : AppTheme.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("All Time, lifetime totals and retained-history details")
            .accessibilityAddTraits(allTime ? .isSelected : [])
            .accessibilityIdentifier("recap.window.allTime")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.window")
    }

    /// Top five families of the selected window; hidden until at least one play in the window is classified.
    @ViewBuilder
    private func topGenres(_ summary: ListeningGenreSummary) -> some View {
        if !summary.isEmpty {
            let coverage = summary.coverage.formatted(.percent.precision(.fractionLength(0)))
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Top Genres", subtitle: "From \(RecapText.scope(window, allTime: allTime)). \(coverage) of your plays are classified.")
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(summary.top(5)) { row in
                        genreRow(row)
                    }
                }
                AppNavigationLink {
                    ListeningGenresView()
                } label: {
                    HStack(spacing: 8) {
                        Text("Listening Genres")
                            .appFont(.subheadline, weight: .semibold)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("View genre statistics and optional recommendation adjustments")
                .accessibilityIdentifier("recap.genres.open")
            }
            .padding(20)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Top Genres, \(RecapText.period(window, allTime: allTime))")
            .accessibilityIdentifier("recap.genres")
        }
    }

    private func genreRow(_ row: GenreListeningStat) -> some View {
        let percentage = row.share.formatted(.percent.precision(.fractionLength(0)))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.family.title)
                    .appFont(.body, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(percentage)
                    .appFont(.subheadline, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.secondaryText)
            }
            ProgressView(value: row.share, total: 1)
                .tint(AppTheme.violet)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.family.title)
        .accessibilityValue("\(percentage) of classified plays")
        .accessibilityIdentifier("recap.genres.\(row.family.rawValue)")
    }

    private func listeningLanguagesEntry(_ listening: ListeningSummary, now: Date) -> some View {
        let summary = !allTime && window == .month ? languageSummary(listening)
            : model.listeningLanguageSummary(for: .month, now: now)
        let counts = "\(summary.totalPlays.formatted()) \(summary.totalPlays == 1 ? "play" : "plays") · \(summary.totalSongs.formatted()) \(summary.totalSongs == 1 ? "song" : "songs")"
        return AppNavigationLink {
            ListeningLanguagesView()
        } label: {
            HStack(spacing: 14) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "character.bubble")
                        .appFont(.title2)
                        .foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listening Languages").appFont(.headline, weight: .semibold)
                    Text("Last 30 days")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(summary.totalPlays > 0 ? counts : "See your listening take shape.")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .appFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .frame(minHeight: 64)
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
            .contentShape(RoundedRectangle(cornerRadius: AppCorner.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Listening Languages, Last 30 days")
        .accessibilityValue(summary.totalPlays > 0 ? counts : "No counted plays")
        .accessibilityHint("View language statistics and optional recommendation adjustments")
        .accessibilityIdentifier("recap.listeningLanguages")
    }

    private func hero(_ summary: ListeningSummary, now: Date) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 20))
        let comparison = comparisonText(summary, now: now)

        return VStack(alignment: .leading, spacing: 20) {
            Text(allTime ? "LIFETIME LISTENING" : "YOUR LAST \(window.days) DAYS")
                .appFont(.caption, weight: .bold)
                .tracking(1.5)
                .foregroundStyle(AppTheme.secondaryText)

            // The total is a plain stat: artwork would credit one song with every minute of the period.
            layout {
                totalTile(allTime ? ListeningAnalytics.lifetimeHero(model.library.lifetimeListeningSummary) : summary,
                          comparison: comparison)
                VStack(alignment: .leading, spacing: 6) {
                    if allTime { Text("Retained History").appFont(.caption).foregroundStyle(AppTheme.secondaryText) }
                    RecapCompactChart(days: summary.days, window: window, now: now, allTime: allTime)
                }
                .frame(minWidth: 140, maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 220)
            }

            if let comparison {
                Text(comparison)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }

            if let track = summary.topTracks.first?.track {
                Text("\(allTime ? "Most listened in retained history" : "Most listened"): \(track.title)")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(AppTheme.primaryText.opacity(0.10))
                .frame(height: 1)
                .accessibilityHidden(true)

            if let artist = summary.topArtists.first {
                VStack(alignment: .leading, spacing: 5) {
                    Text(allTime ? "Top Artist in Retained History" : "Top Artist")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(artist.name)
                        .appFont(.title2, weight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recap.topArtist")
            } else {
                Text(allTime && summary.topTracks.isEmpty ? "Song and artist details are no longer retained." : "Artist credits aren’t available for these songs.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text(RecapText.dateRange(window: window, now: now, allTime: allTime,
                firstSavedDay: allTime ? model.library.lifetimeListeningSummary.coverageStartedAt : summary.days.first?.date))
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.surface)
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [AppTheme.accent.opacity(0.12), .clear],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }

    private func totalTile(_ summary: ListeningSummary, comparison: String?) -> some View {
        let usesSeconds = summary.seconds < 60
        let value = usesSeconds ? RecapText.secondsValue(summary.seconds) : summary.minutes.formatted()
        let unit = RecapText.totalUnit(summary.seconds)
        return VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: totalFontSize, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.25)
            Text(unit)
                .appFont(.headline, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(unit) \(allTime ? "since lifetime coverage began" : "in the last \(window.days) days")")
        .accessibilityValue(comparison ?? "")
        .accessibilityIdentifier("recap.totalListening")
    }

    /// Week and month compare with the period just before; the year has no retained predecessor to compare with.
    private func comparisonText(_ summary: ListeningSummary, now: Date) -> String? {
        guard !allTime, window != .year, let previous = model.previousWindowListeningSeconds(for: window, now: now) else { return nil }
        return RecapText.comparison(current: summary.seconds, previous: previous, days: window.days)
    }

    private func metrics(_ summary: ListeningSummary) -> some View {
        LazyVGrid(columns: metricColumns, spacing: 12) {
            RecapMetric(value: allTime ? model.library.lifetimeListeningSummary.plays : summary.plays,
                        title: allTime ? "Lifetime Plays" : "Counted Plays", symbol: "play.circle", identifier: "recap.plays")
            RecapMetric(value: summary.uniqueTracks, title: allTime ? "Retained Songs" : "Different Songs", symbol: "music.note", identifier: "recap.songs")
            RecapMetric(value: summary.uniqueArtists, title: allTime ? "Retained Artists" : "Artists", symbol: "person.2", identifier: "recap.artists")
            RecapMetric(value: summary.streak, title: "Current Day Streak", symbol: "flame", identifier: "recap.streak")
        }
    }

    private var metricColumns: [GridItem] {
        if AppLayout.isRegularWidth(horizontalSizeClass) {
            // Adaptive columns in a 1000-point column leave empty cells beside the four metrics; fixed counts fill the row.
            return Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        }
        return [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140), spacing: 12)]
    }

    private func onRepeat(_ summary: ListeningSummary) -> some View {
        let rankings = Array(summary.topTracks.prefix(25))
        let tracks = rankings.map(\.track)
        let visible = showsAllRepeatTracks ? rankings : Array(rankings.prefix(5))

        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "On Repeat", subtitle: "Your most-listened songs from \(RecapText.scope(window, allTime: allTime)), ranked by time.")
            LibraryQueueButtons(tracks: tracks, title: "On Repeat", identifier: "recap.onRepeat")
            VStack(spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, ranking in
                    TrackRow(
                        track: ranking.track, tracks: tracks, rank: index + 1,
                        subtitle: "\(ranking.track.artistName) · \(RecapText.time(ranking.seconds)) listened · \(RecapText.plays(ranking.plays))",
                        accessibilityMetadata: "Your listening, \(RecapText.period(window, allTime: allTime)): \(RecapText.time(ranking.seconds)) listened, \(RecapText.plays(ranking.plays))"
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recap.track.\(ranking.id)")
                }
            }
            if rankings.count > 5 {
                Button {
                    showsAllRepeatTracks.toggle()
                } label: {
                    Label(showsAllRepeatTracks ? "Show Fewer Songs" : "Show All \(rankings.count) Songs",
                          systemImage: showsAllRepeatTracks ? "chevron.up" : "chevron.down")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(AppTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recap.onRepeat.showAll")
            }
            if summary.topTracks.count > 25 {
                Text("On repeat holds your top 25 songs for this window.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.onRepeat")
    }

    private func dayChart(_ summary: ListeningSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: allTime ? "Over Time" : "Day by Day", subtitle: "Time spent with your music.")
            if allTime {
                RecapAvailableHistoryChart(days: summary.days, now: now)
            } else {
                RecapDayChart(days: summary.days, window: window, now: now)
                    .id(window)
            }
            Text(allTime ? "Saved listening grouped into calendar periods. Older periods may be incomplete." : window == .year
                 ? "Minutes per day. Swipe through the year; the view opens on your latest month."
                 : "Minutes per day. The first and last days may be partial.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.timeline")
    }

    private func artists(_ summary: ListeningSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Artists in Rotation")
            ForEach(Array(summary.topArtists.prefix(3).enumerated()), id: \.element.id) { index, artist in
                Button {
                    model.openSearch(artist.name)
                } label: {
                    HStack(alignment: .center, spacing: 14) {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .appFont(.title2, weight: .bold)
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(minWidth: 28)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(artist.name)
                                .appFont(.headline, weight: .semibold)
                                .foregroundStyle(AppTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(RecapText.time(artist.seconds)) · \(RecapText.plays(artist.plays))")
                                .appFont(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 32, height: 44)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Search music by this artist")
                .accessibilityIdentifier("recap.artist.\(artist.id)")
            }
        }
    }

    private func sharing(_ summary: ListeningSummary, genres: ListeningGenreSummary, now: Date) -> some View {
        return VStack(spacing: 10) {
            Button {
                let content = RecapShareCardContent(summary: summary, window: window, now: now,
                    genres: genres, languages: languageSummary(summary), allTime: allTime,
                    lifetime: allTime ? model.library.lifetimeListeningSummary : nil)
                AppNavigationIntent.perform(in: model) {
                    shareRequest = RecapShareRequest(content: content,
                        text: RecapText.share(summary: summary, window: window, now: now, allTime: allTime,
                                             lifetime: allTime ? model.library.lifetimeListeningSummary : nil),
                        tracks: summary.topTracks.prefix(3).map(\.track))
                }
            } label: {
                shareLabel
            }
            .buttonStyle(.plain)
            .accessibilityHint("Preview your listening card before sharing")
            .accessibilityIdentifier("recap.share")
        }
    }

    private var shareLabel: some View {
        Label("Share", systemImage: "square.and.arrow.up")
            .appFont(.headline, weight: .semibold)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(AppTheme.onAccent)
            .background(AppTheme.accent, in: Capsule())
    }

    private var emptyRecap: some View {
        VStack(spacing: 22) {
            EmptyStateView(
                symbol: "waveform", title: model.library.events.isEmpty ? "Your Listening Starts with a Song" : "Nothing Saved in This Window",
                message: model.library.preferences.saveListeningHistory
                    ? "Play something you love. Your listening time, favorite artists, and most-played songs will take shape here."
                    : "Turn on listening history to see the songs you actually play."
            )
            Button { model.openSearch("") } label: {
                Label("Find Music", systemImage: "magnifyingglass")
                    .appFont(.body)
                    .foregroundStyle(AppTheme.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("recap.findMusic")
            Text(allTime ? "No saved listening is available." : "No saved listening in the last \(window.days) days.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.empty")
    }

    private var countingNotes: some View {
        DisclosureGroup("How It’s Counted") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only time actually listened counts. Pausing and seeking don’t add minutes.")
                Text("A play counts once per listening session after 30 seconds, or halfway through a song shorter than a minute.")
                Text(allTime ? "Lifetime time and plays survive the 400-day detail limit. Charts, songs, artists, genres and language shares use retained history only. Older streak samples may be incomplete. Clear Listening History also clears lifetime totals."
                     : "This window rolls back \(window.days) days from now. Listening is grouped by the session’s start date, so the first and last dates can be partial.")
                Text("A streak is consecutive local days with listening, ending today or yesterday. It can be longer than the selected window.")
                Text("Collaborations credit each named artist. The total listening time counts each session only once.")
            }
            .appFont(.footnote)
            .foregroundStyle(AppTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
        }
        .appFont(.subheadline, weight: .semibold)
        .accessibilityIdentifier("recap.howCounted")
    }
}

@MainActor
private struct RecapMetric: View {
    let value: Int
    let title: String
    let symbol: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(value.formatted())
                .monospacedDigit()
                .appFont(.title2, weight: .bold, design: .rounded)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(title)
                .appFont(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private struct RecapDayChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let days: [ListeningDay]
    let window: ListeningWindow
    let now: Date

    private var firstVisibleDay: Date {
        days.dropFirst(max(0, days.count - 31)).first?.date ?? now
    }

    private var visibleDuration: TimeInterval {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: days.last?.date ?? now) ?? now
        return max(1, end.timeIntervalSince(firstVisibleDay))
    }

    var body: some View {
        Chart(days) { day in
            BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.seconds / 60))
                .foregroundStyle(Calendar.current.isDate(day.date, inSameDayAs: now) ? AppTheme.accent : AppTheme.violet)
                .cornerRadius(3)
                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .accessibilityValue("\(RecapText.time(day.seconds)) listened")
        }
        .chartYScale(domain: 0...max(1, (days.map(\.seconds).max() ?? 0) / 60 * 1.1))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                    .foregroundStyle(AppTheme.secondaryText.opacity(0.15))
                AxisValueLabel()
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .chartScrollableAxes(window == .year ? .horizontal : [])
        .chartXVisibleDomain(length: visibleDuration)
        .chartScrollPosition(initialX: firstVisibleDay)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 260 : 190)
        .accessibilityLabel("Daily listening, last \(window.days) days")
        .accessibilityIdentifier("recap.dayChart")
    }
}

/// Axis-free bars beside the total: one per day for the week, per 7-day span for the month, per month for the year.
@MainActor
private struct RecapCompactChart: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let days: [ListeningDay]
    let window: ListeningWindow
    let now: Date
    var allTime = false

    var body: some View {
        let buckets = allTime ? RecapListeningBuckets.allAvailable(days: days, now: now)
            : RecapListeningBuckets.buckets(days: days, window: window, now: now)
        let peak = max(1, buckets.map(\.seconds).max() ?? 0) / 60
        Chart(buckets) { bucket in
            BarMark(x: .value("Period", bucket.id), y: .value("Minutes", bucket.seconds / 60))
                .foregroundStyle(bucket.isCurrent ? AppTheme.accent : AppTheme.violet.opacity(0.7))
                .cornerRadius(2)
        }
        .chartYScale(domain: 0...peak * 1.1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 96 : 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(allTime ? "Listening over time, all available history" : RecapListeningBuckets.title(for: window))
        .accessibilityValue(RecapListeningBuckets.summary(of: buckets, window: window, allTime: allTime))
        .accessibilityIdentifier("recap.totalListening.chart")
    }
}

@MainActor
private struct RecapAvailableHistoryChart: View {
    let days: [ListeningDay]
    let now: Date

    var body: some View {
        let buckets = RecapListeningBuckets.allAvailable(days: days, now: now)
        let labelStride = max(1, (buckets.count + 3) / 4)
        let labels = buckets.enumerated().filter { $0.offset.isMultiple(of: labelStride) }.map(\.element.title)
        Chart(buckets) { bucket in
            BarMark(x: .value("Period", bucket.title), y: .value("Minutes", bucket.seconds / 60), width: .ratio(0.8))
                .foregroundStyle(bucket.isCurrent ? AppTheme.accent : AppTheme.violet)
                .cornerRadius(3)
                .accessibilityLabel(bucket.title)
                .accessibilityValue("\(RecapText.time(bucket.seconds)) listened")
        }
        .chartYScale(domain: 0...max(1, (buckets.map(\.seconds).max() ?? 0) / 60 * 1.1))
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisValueLabel {
                    if let title = value.as(String.self), let bucket = buckets.first(where: { $0.title == title }) {
                        Text(bucket.start, format: .dateTime.month(.abbreviated).year())
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 190)
        .accessibilityLabel("Listening over time, all available history")
        .accessibilityIdentifier("recap.dayChart")
    }
}

struct RecapListeningBucket: Identifiable, Equatable {
    let id: String
    let start: Date
    /// Spoken name of the span, such as "Thursday, Sep 19", "the week of Sep 20" or "September".
    let title: String
    var seconds: TimeInterval
    let isCurrent: Bool
}

enum RecapListeningBuckets {
    /// At most 24 monthly or multi-year spans, including empty gaps, regardless of older retained streak samples.
    static func allAvailable(days: [ListeningDay], now: Date,
                             calendar: Calendar = .current) -> [RecapListeningBucket] {
        let days = days.filter { LibraryValidation.isValidDate($0.date) && $0.date <= now }
        guard LibraryValidation.isValidDate(now), let earliest = days.map(\.date).min(),
              let firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start,
              let lastMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let months = (calendar.dateComponents([.month], from: firstMonth, to: lastMonth).month ?? 0) + 1
        let component: Calendar.Component = months <= 24 ? .month : .year
        guard let first = calendar.dateInterval(of: component, for: earliest)?.start,
              let last = calendar.dateInterval(of: component, for: now)?.start else { return [] }
        let span = (calendar.dateComponents([component], from: first, to: last).value(for: component) ?? 0) + 1
        let stride = max(1, (span + 23) / 24)
        var result: [RecapListeningBucket] = []
        var start = first
        while start <= now && result.count < 24 {
            guard let end = calendar.date(byAdding: component, value: stride, to: start), end > start else { break }
            let title: String
            if component == .month {
                title = format(start, .dateTime.month(.wide).year(), calendar: calendar)
            } else if stride == 1 {
                title = format(start, .dateTime.year(), calendar: calendar)
            } else {
                let finalYear = calendar.date(byAdding: .year, value: stride - 1, to: start) ?? start
                title = "\(format(start, .dateTime.year(), calendar: calendar))–\(format(finalYear, .dateTime.year(), calendar: calendar))"
            }
            let seconds = days.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.seconds }
            result.append(RecapListeningBucket(id: start.formatted(.iso8601), start: start,
                title: title, seconds: seconds, isCurrent: now >= start && now < end))
            start = end
        }
        return result
    }

    static func buckets(days: [ListeningDay], window: ListeningWindow, now: Date,
                        calendar: Calendar = .current) -> [RecapListeningBucket] {
        let today = calendar.startOfDay(for: now)
        var buckets: [Date: RecapListeningBucket] = [:]
        for day in days {
            let start: Date
            let title: String
            switch window {
            case .week:
                start = calendar.startOfDay(for: day.date)
                // The rolling week spans eight local days, so the first and last share a weekday name.
                title = format(start, .dateTime.weekday(.wide).month(.abbreviated).day(), calendar: calendar)
            case .month:
                // Spans count back from today so the newest bar is always a full seven days.
                let distance = calendar.dateComponents([.day], from: calendar.startOfDay(for: day.date), to: today).day ?? 0
                start = calendar.date(byAdding: .day, value: -((max(0, distance) / 7) * 7 + 6), to: today) ?? today
                title = "the week of \(format(start, .dateTime.month(.abbreviated).day(), calendar: calendar))"
            case .year:
                start = calendar.dateInterval(of: .month, for: day.date)?.start ?? calendar.startOfDay(for: day.date)
                title = format(start, .dateTime.month(.wide), calendar: calendar)
            }
            if var bucket = buckets[start] {
                bucket.seconds += day.seconds
                buckets[start] = bucket
            } else {
                let isCurrent = switch window {
                case .week: calendar.isDate(start, inSameDayAs: today)
                case .month: calendar.dateComponents([.day], from: start, to: today).day.map { $0 <= 6 } ?? false
                case .year: calendar.isDate(start, equalTo: today, toGranularity: .month)
                }
                buckets[start] = RecapListeningBucket(id: start.formatted(.iso8601), start: start, title: title,
                                                      seconds: day.seconds, isCurrent: isCurrent)
            }
        }
        return buckets.values.sorted { $0.start < $1.start }
    }

    /// Titles follow the calendar that placed the day, so a bucket never names a neighbouring day in another zone.
    private static func format(_ date: Date, _ style: Date.FormatStyle, calendar: Calendar) -> String {
        var style = style
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func title(for window: ListeningWindow) -> String {
        switch window {
        case .week: "Listening by day, last 7 days"
        case .month: "Listening by week, last 30 days"
        case .year: "Listening by month, last 365 days"
        }
    }

    static func summary(of buckets: [RecapListeningBucket], window: ListeningWindow, allTime: Bool = false) -> String {
        let active = buckets.filter { $0.seconds > 0 }
        guard let peak = active.max(by: { $0.seconds < $1.seconds }) else { return "No listening in this period" }
        let rollingUnit = switch window { case .week: "day"; case .month: "week"; case .year: "month" }
        let unit = allTime ? "period" : rollingUnit
        let spans = "\(active.count) of \(buckets.count) \(unit)\(buckets.count == 1 ? "" : "s") with listening"
        return "\(spans). Most on \(peak.title): \(RecapText.time(peak.seconds))"
    }
}

enum RecapText {
    static let savedHistoryNote = "Based on saved history; older deleted plays cannot be recovered"
    static let lifetimeDetailNote = "Lifetime total; rankings use retained history. Earlier deleted plays cannot be recovered."

    static func lifetimeCoverage(_ summary: LifetimeListeningSummary) -> String {
        let start = summary.coverageStartedAt.map { " since \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
        return "Lifetime totals\(start). Charts and rankings use retained history, normally 400 days. Plays deleted before lifetime tracking cannot be recovered."
    }

    static func period(_ window: ListeningWindow, allTime: Bool) -> String {
        allTime ? "All Time · All available history" : "Last \(window.days) days"
    }

    static func scope(_ window: ListeningWindow, allTime: Bool) -> String {
        allTime ? "retained history" : "the last \(window.days) days"
    }

    static func totalUnit(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return seconds < 2 && seconds > 0 ? "second listened" : "seconds listened" }
        return Int(seconds / 60) == 1 ? "minute listened" : "minutes listened"
    }

    static func secondsValue(_ seconds: TimeInterval) -> String {
        seconds > 0 && seconds < 1 ? "< 1" : Int(seconds).formatted()
    }

    /// Plain-language change against the period just before; ratios of two and above read as multiples.
    static func comparison(current: TimeInterval, previous: TimeInterval, days: Int) -> String {
        guard previous > 0 else { return "No listening in the previous \(days) days" }
        let ratio = current / previous
        if abs(ratio - 1) < 0.005 { return "About the same as the previous \(days) days" }
        if ratio >= 2 {
            return "\(ratio.formatted(.number.precision(.fractionLength(0...1)))) times as much as the previous \(days) days"
        }
        let percent = Int((abs(ratio - 1) * 100).rounded())
        return ratio > 1 ? "Up \(percent)% from the previous \(days) days" : "Down \(percent)% from the previous \(days) days"
    }

    static func time(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return seconds > 0 ? "less than a second" : "0 min" }
        if seconds < 60 { return "\(Int(seconds).formatted()) sec" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes.formatted()) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours.formatted()) hr" : "\(hours.formatted()) hr \(remainder) min"
    }

    static func plays(_ count: Int) -> String {
        "\(count.formatted()) \(count == 1 ? "play" : "plays")"
    }

    static func dateRange(window: ListeningWindow, now: Date, allTime: Bool = false,
                          firstSavedDay: Date? = nil, calendar: Calendar = .current) -> String {
        if allTime && firstSavedDay == nil { return "No saved listening" }
        let start = allTime ? (firstSavedDay ?? now) : (calendar.date(byAdding: .day, value: -window.days, to: now) ?? now)
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return "\(start.formatted(style)) – \(now.formatted(style))"
    }

    static func share(summary: ListeningSummary, window: ListeningWindow, now: Date, allTime: Bool = false,
                      lifetime: LifetimeListeningSummary? = nil) -> String {
        if allTime, let lifetime {
            return ["Velvet Thorn · My lifetime listening", "\(time(lifetime.seconds)) listened · \(plays(lifetime.plays))",
                    lifetimeCoverage(lifetime), "", "Retained-history details:",
                    share(summary: summary, window: window, now: now, allTime: true)].joined(separator: "\n")
        }
        let songs = "\(summary.uniqueTracks.formatted()) \(summary.uniqueTracks == 1 ? "song" : "songs")"
        let artists = "\(summary.uniqueArtists.formatted()) \(summary.uniqueArtists == 1 ? "artist" : "artists")"
        var lines = [
            "Velvet Thorn · My listening",
            "\(period(window, allTime: allTime)) · \(dateRange(window: window, now: now, allTime: allTime, firstSavedDay: summary.days.first?.date))",
            "",
            "\(time(summary.seconds)) listened",
            "\(plays(summary.plays)) · \(songs) · \(artists)"
        ]
        if let artist = summary.topArtists.first { lines.append("Top artist: \(artist.name)") }
        if summary.streak > 0 { lines.append("\(summary.streak)-day current listening streak") }
        lines.append(contentsOf: ["", "On repeat"])
        for (index, ranking) in summary.topTracks.prefix(5).enumerated() {
            lines.append("\(index + 1). \(ranking.track.title) · \(ranking.track.artistName)")
        }
        lines.append(contentsOf: ["", "Made from my saved listening."])
        if allTime { lines.append(savedHistoryNote) }
        return lines.joined(separator: "\n")
    }
}

private struct RecapShareRequest: Identifiable {
    let id = UUID()
    let content: RecapShareCardContent
    let text: String
    let tracks: [Track]
}

struct RecapShareCardImage {
    let uiImage: UIImage
    let image: Image
    let periodTitle: String

    init(image: UIImage, periodTitle: String) {
        uiImage = image
        self.image = Image(uiImage: image)
        self.periodTitle = periodTitle
    }
}

@MainActor
private struct RecapShareCardPreview: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let request: RecapShareRequest
    @State private var card: RecapShareCardImage?
    @State private var renderFailed = false
    @State private var attempt = 0
    @State private var includesSummaryText = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let card {
                        card.image
                            .resizable()
                            .aspectRatio(RecapShareCard.size.width / RecapShareCard.size.height, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: AppCorner.card))
                            .overlay(RoundedRectangle(cornerRadius: AppCorner.card).stroke(AppTheme.primaryText.opacity(0.12)))
                            .accessibilityLabel("Stats Card, \(card.periodTitle)")
                            .accessibilityValue("\(Int(card.uiImage.size.width)) by \(Int(card.uiImage.size.height)) pixels")
                            .accessibilityIdentifier("recap.share.previewImage")
                        Toggle("Include Summary Text", isOn: $includesSummaryText)
                            .toggleStyle(CompactSwitchToggleStyle())
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("recap.share.includeText")
                        ShareLink(item: card.image, message: includesSummaryText ? Text(request.text) : nil,
                                   preview: SharePreview("Velvet Thorn Stats, \(card.periodTitle)", image: card.image)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .appFont(.headline, weight: .semibold)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundStyle(AppTheme.onAccent)
                                .background(AppTheme.accent, in: Capsule())
                        }
                        .buttonStyle(AppNavigationIntentButtonStyle(.plain))
                        .accessibilityIdentifier("recap.share.previewShare")
                    } else if renderFailed {
                        Text("Couldn’t prepare the listening card.")
                        Button("Try Again") { attempt += 1 }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("recap.share.retry")
                    } else {
                        ProgressView("Preparing your listening card…")
                            .accessibilityIdentifier("recap.share.loading")
                    }
                    Text(includesSummaryText ? "Shares the image and its summary text." : "Shares only the image.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("recap.share.contents")
                    if let note = request.content.coverageNote {
                        Text(note).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle("Stats Card")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "recap.share.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .accessibilityIdentifier("recap.share.preview")
        .task(id: "\(attempt)|\(colorScheme == .dark)") {
            card = nil
            renderFailed = false
            let artwork = await RecapShareCardRenderer.cachedArtwork(for: request.tracks)
            guard !Task.isCancelled else { return }
            if let image = RecapShareCardRenderer.render(request.content, artwork: artwork,
                accent: model.library.preferences.accent.color, colorScheme: colorScheme) {
                card = RecapShareCardImage(image: image, periodTitle: request.content.periodTitle)
            } else {
                renderFailed = true
            }
        }
    }
}
