import Charts
import SwiftUI

@MainActor
struct RecapView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var window: ListeningWindow = .week
    @State private var showsAllRepeatTracks = false
    @ScaledMetric(relativeTo: .largeTitle) private var totalFontSize: CGFloat = 44

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            // Listening updates arrive between timeline ticks and must not be treated as future sessions.
            let now = Date()
            let summary = model.library.summary(for: window, now: now)
            ScrollView {
                // Stable section heights avoid a lazy-placement loop when a populated recap becomes empty.
                VStack(alignment: .leading, spacing: 26) {
                    header
                    windowSelector
                    LibraryStoreNotices()
                    if summary.seconds > 0 {
                        hero(summary, now: now)
                        metrics(summary)
                        onRepeat(summary)
                        dayChart(summary, now: now)
                        if !summary.topArtists.isEmpty { artists(summary) }
                        sharing(summary, now: now)
                    } else {
                        emptyRecap
                    }
                    countingNotes
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Your listening, lately")
                .appFont(.largeTitle, weight: .bold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("A rolling recap, made from your listening.")
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
                } label: {
                    Text(option.title)
                        .appFont(.subheadline, weight: .semibold)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .foregroundStyle(window == option ? AppTheme.onAccent : AppTheme.primaryText)
                        .background(window == option ? AppTheme.accent : AppTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.title), last \(option.days) days")
                .accessibilityAddTraits(window == option ? .isSelected : [])
                .accessibilityIdentifier("recap.window.\(option.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recap.window")
    }

    private func hero(_ summary: ListeningSummary, now: Date) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))

        return VStack(alignment: .leading, spacing: 20) {
            Text("YOUR LAST \(window.days) DAYS")
                .appFont(.caption, weight: .bold)
                .tracking(1.5)
                .foregroundStyle(AppTheme.secondaryText)

            layout {
                if let track = summary.topTracks.first?.track {
                    ArtworkView(url: track.artworkURL, title: track.title, size: 116, cornerRadius: 8)
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.seconds < 60 ? RecapText.secondsValue(summary.seconds) : summary.minutes.formatted())
                        .font(.system(size: totalFontSize, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.25)
                    Text(summary.seconds < 60 ? "seconds listened" : "minutes listened")
                        .appFont(.headline, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recap.totalListening")
            }

            if let track = summary.topTracks.first?.track {
                Text("Most listened: \(track.title)")
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
                    Text("Top artist")
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                    Text(artist.name)
                        .appFont(.title2, weight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recap.topArtist")
            } else {
                Text("Artist credits aren’t available for these songs.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Text(RecapText.dateRange(window: window, now: now))
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

    private func metrics(_ summary: ListeningSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 140), spacing: 12)], spacing: 12) {
            RecapMetric(value: summary.plays, title: "Counted plays", symbol: "play.circle", identifier: "recap.plays")
            RecapMetric(value: summary.uniqueTracks, title: "Different songs", symbol: "music.note", identifier: "recap.songs")
            RecapMetric(value: summary.uniqueArtists, title: "Artists", symbol: "person.2", identifier: "recap.artists")
            RecapMetric(value: summary.streak, title: "Current day streak", symbol: "flame", identifier: "recap.streak")
        }
    }

    private func onRepeat(_ summary: ListeningSummary) -> some View {
        let rankings = Array(summary.topTracks.prefix(25))
        let tracks = rankings.map(\.track)
        let visible = showsAllRepeatTracks ? rankings : Array(rankings.prefix(5))

        return VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "On repeat", subtitle: "Your most-listened songs from the last \(window.days) days, ranked by time.")
            LibraryQueueButtons(tracks: tracks, title: "On repeat", identifier: "recap.onRepeat")
            VStack(spacing: 4) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, ranking in
                    TrackRow(
                        track: ranking.track, tracks: tracks, rank: index + 1,
                        subtitle: "\(ranking.track.artistName) · \(RecapText.time(ranking.seconds)) listened · \(RecapText.plays(ranking.plays))",
                        accessibilityMetadata: "Your listening in the last \(window.days) days: \(RecapText.time(ranking.seconds)) listened, \(RecapText.plays(ranking.plays))"
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("recap.track.\(ranking.id)")
                }
            }
            if rankings.count > 5 {
                Button {
                    showsAllRepeatTracks.toggle()
                } label: {
                    Label(showsAllRepeatTracks ? "Show fewer songs" : "Show all \(rankings.count) songs",
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
    }

    private func dayChart(_ summary: ListeningSummary, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Day by day", subtitle: "Time spent with your music.")
            RecapDayChart(days: summary.days, window: window, now: now)
                .id(window)
            Text(window == .year
                 ? "Minutes per day. Swipe through the year; the view opens on your latest month."
                 : "Minutes per day. The first and last days may be partial.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func artists(_ summary: ListeningSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Artists in rotation")
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

    private func sharing(_ summary: ListeningSummary, now: Date) -> some View {
        VStack(spacing: 10) {
            ShareLink(item: RecapText.share(summary: summary, window: window, now: now)) {
                Label("Share your recap", systemImage: "square.and.arrow.up")
                    .appFont(.headline, weight: .semibold)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(AppTheme.onAccent)
                    .background(AppTheme.accent, in: Capsule())
            }
            .buttonStyle(AppNavigationIntentButtonStyle(.plain))
            .accessibilityIdentifier("recap.share")
            Text("Your listening stays on this device until you choose to share it.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var emptyRecap: some View {
        VStack(spacing: 22) {
            EmptyStateView(
                symbol: "waveform", title: model.library.events.isEmpty ? "Your recap starts with a song" : "Nothing saved in this window",
                message: model.library.preferences.saveListeningHistory
                    ? "Play something you love. Your listening time, favorite artists, and most-played songs will take shape here."
                    : "Turn on listening history to build a recap from the songs you actually play."
            )
            Button { model.openSearch("") } label: {
                Label("Find music", systemImage: "magnifyingglass")
                    .appFont(.body)
                    .foregroundStyle(AppTheme.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("recap.findMusic")
            Text("No saved listening in the last \(window.days) days.")
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
        DisclosureGroup("How it’s counted") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only time actually listened counts. Pausing and seeking don’t add minutes.")
                Text("A play counts once per listening session after 30 seconds, or halfway through a song shorter than a minute.")
                Text("Each window rolls back \(window.days) days from now. Listening is grouped by the session’s start date, so the first and last dates can be partial.")
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

private enum RecapText {
    static func secondsValue(_ seconds: TimeInterval) -> String {
        seconds > 0 && seconds < 1 ? "< 1" : Int(seconds).formatted()
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

    static func dateRange(window: ListeningWindow, now: Date) -> String {
        let start = Calendar.current.date(byAdding: .day, value: -window.days, to: now) ?? now
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(start.formatted(style)) – \(now.formatted(style))"
    }

    static func share(summary: ListeningSummary, window: ListeningWindow, now: Date) -> String {
        let songs = "\(summary.uniqueTracks.formatted()) \(summary.uniqueTracks == 1 ? "song" : "songs")"
        let artists = "\(summary.uniqueArtists.formatted()) \(summary.uniqueArtists == 1 ? "artist" : "artists")"
        var lines = [
            "Breezy · My listening, lately",
            "Last \(window.days) days · \(dateRange(window: window, now: now))",
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
        lines.append(contentsOf: ["", "Made from my actual listening on this device."])
        return lines.joined(separator: "\n")
    }
}
