import SwiftUI

/// Settings > Discovery > Listening genres: the last 30 days of classified plays by family, with per-family nudges.
@MainActor
struct ListeningGenresView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsOtherFamilies = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let summary = model.listeningGenreSummary(for: .month, now: Date())
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last 30 days")
                            .appFont(.title3, weight: .bold)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("genres.window")
                        Text("The genres in the songs you played.")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    libraryNotice
                    if !model.library.preferences.saveListeningHistory { historyPaused }
                    if summary.isEmpty {
                        emptyListening(summary)
                    } else {
                        coverage(summary)
                        families(summary)
                    }
                    otherFamilies(summary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Genres come from MusicBrainz, for the recordings and artists of the songs you play. Adjustments change recommendations, not your stats.")
                            .accessibilityIdentifier("genres.source")
                        Text("A play counts after 30 seconds, or halfway through a song shorter than a minute. Shares divide the plays Velvet Thorn could classify.")
                            .accessibilityIdentifier("genres.counting")
                    }
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("genres.content")
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("Listening Genres")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { model.refreshListeningGenres() }
    }

    private func coverage(_ summary: ListeningGenreSummary) -> some View {
        let percent = summary.coverage.formatted(.percent.precision(.fractionLength(0)))
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
        return VStack(alignment: .leading, spacing: 16) {
            layout {
                metric(summary.totalPlays, title: "Counted Plays", id: "plays")
                metric(summary.classifiedSongs, title: "Classified Songs", id: "songs")
            }
            Divider()
            Text("\(percent) of your plays are classified.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genres.coverage")
            if model.genreClassification.isChecking {
                HStack(spacing: 10) {
                    ProgressView().accessibilityHidden(true)
                    Text("Checking more songs")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .accessibilityIdentifier("genres.checking")
            }
        }
        .padding(20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
    }

    private func metric(_ value: Int, title: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted())
                .appFont(.largeTitle, weight: .bold, design: .rounded)
                .monospacedDigit()
            Text(title).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.formatted())
        .accessibilityIdentifier("genres.total.\(id)")
    }

    private func families(_ summary: ListeningGenreSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(summary.rows) { row in
                familyRow(row)
            }
        }
        .padding(20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genres.breakdown")
    }

    private func familyRow(_ row: GenreListeningStat) -> some View {
        let percentage = row.share.formatted(.percent.precision(.fractionLength(0...1)))
        let plays = Int(row.plays.rounded())
        let counts = "\(plays.formatted()) \(plays == 1 ? "play" : "plays") · \(row.songs.formatted()) \(row.songs == 1 ? "song" : "songs")"
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                layout {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.family.title).appFont(.headline, weight: .semibold)
                        Text(counts).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(percentage).appFont(.title3, weight: .semibold).monospacedDigit()
                }
                ProgressView(value: row.share, total: 1)
                    .tint(color(for: row.family))
                    .accessibilityHidden(true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.family.title)
            .accessibilityValue("\(counts), \(percentage) of classified plays")
            .accessibilityIdentifier("genres.family.\(row.family.rawValue)")
            nudgeMenu(row.family)
        }
    }

    /// Families without plays can still be nudged, so a listener can ask for More of something new.
    private func otherFamilies(_ summary: ListeningGenreSummary) -> some View {
        let observed = Set(summary.rows.map(\.family))
        let others = GenreFamily.allCases.filter { !observed.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsOtherFamilies.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tune Other Genres").appFont(.headline, weight: .semibold)
                        Text(model.library.preferences.genreNudges.isAutomatic ? "Optional" : "Your adjustments are saved")
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: showsOtherFamilies ? "chevron.up" : "chevron.down")
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tune Other Genres")
            .accessibilityValue(showsOtherFamilies ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows adjustments for genres you have not played yet")
            .accessibilityIdentifier("genres.more")
            if showsOtherFamilies {
                Divider()
                Text("More can bring in a genre you have not played yet. Less lowers a genre without removing it.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genres.tuningNote")
                ForEach(others) { family in
                    nudgeMenu(family)
                }
            }
            Divider()
            Button { model.resetGenreNudges() } label: {
                Label("Reset Adjustments", systemImage: "arrow.counterclockwise")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .disabled(model.library.preferences.genreNudges.isAutomatic)
            .accessibilityIdentifier("genres.reset")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
    }

    private func nudgeMenu(_ family: GenreFamily) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return Menu {
            Picker(family.title, selection: Binding(
                get: { model.library.preferences.genreNudges[family] },
                set: { model.setGenreNudge($0, for: family) }
            )) {
                ForEach(ListeningNudge.allCases) { nudge in
                    Text(nudge.title)
                        .tag(nudge)
                        .accessibilityIdentifier("genres.choice.\(family.rawValue).\(nudge.rawValue)")
                }
            }
        } label: {
            layout {
                Text(family.title)
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(model.library.preferences.genreNudges[family].title, systemImage: "chevron.up.chevron.down")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(family.title) recommendations")
        .accessibilityValue(model.library.preferences.genreNudges[family].title)
        .accessibilityHint("Adjusts recommendations without changing listening statistics")
        .accessibilityIdentifier("genres.nudge.\(family.rawValue)")
    }

    private func emptyListening(_ summary: ListeningGenreSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(summary.totalPlays > 0 ? "No genres yet" : "Your genres start with a song", systemImage: "music.note.list")
                .appFont(.headline, weight: .semibold)
            Text(summary.totalPlays > 0
                 ? "Play a few songs and Velvet Thorn learns which genres you like. \(summary.totalPlays.formatted()) counted plays are waiting for a genre check."
                 : "Play a few songs and Velvet Thorn learns which genres you like.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("genres.empty")
    }

    private var historyPaused: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Listening history is off", systemImage: "pause.circle")
                .appFont(.headline, weight: .semibold)
            Text("Existing stats stay here. New listening is not added while history is off.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            Button { model.updatePreferences { $0.saveListeningHistory = true } } label: {
                Text("Turn On Listening History")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("genres.enableHistory")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genres.historyOff")
    }

    @ViewBuilder
    private var libraryNotice: some View {
        if let error = model.library.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your library needs attention", systemImage: "exclamationmark.triangle")
                    .appFont(.headline, weight: .semibold)
                Text(error).appFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                if model.library.requiresReload {
                    LibraryReloadButton(identifier: "genres.reload")
                }
            }
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("genres.libraryError")
        }
    }

    private func color(for family: GenreFamily) -> Color {
        switch family.order % 3 {
        case 0: AppTheme.accent
        case 1: AppTheme.gold
        default: AppTheme.violet
        }
    }
}
