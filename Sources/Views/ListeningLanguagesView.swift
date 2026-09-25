import SwiftUI

@MainActor
struct ListeningLanguagesView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTuningExpanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let summary = model.listeningLanguageSummary(for: .month, now: Date())
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last 30 days")
                            .appFont(.title3, weight: .bold)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("listeningLanguages.window")
                        Text("The languages in the songs you played.")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    libraryNotice
                    if !model.library.preferences.saveListeningHistory { historyPaused }
                    if summary.totalPlays > 0 {
                        overview(summary)
                        breakdown(summary)
                        classificationStatus
                    } else {
                        emptyListening
                    }
                    tuning
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Languages come from recording metadata or matched lyrics. Your saved song corrections take priority. Lyrics checks analyze text on this device.")
                            .accessibilityIdentifier("listeningLanguages.source")
                        Text("A play counts after 30 seconds, or halfway through a song shorter than a minute. Percentages include every counted play, including Unclassified.")
                            .accessibilityIdentifier("listeningLanguages.counting")
                    }
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("listeningLanguages.content")
        }
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .navigationTitle("Listening languages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { model.refreshListeningLanguages() }
    }

    private func overview(_ summary: ListeningLanguageSummary) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
        return VStack(alignment: .leading, spacing: 16) {
            layout {
                metric(summary.totalPlays, title: "Counted plays", id: "plays")
                metric(summary.totalSongs, title: "Different songs", id: "songs")
            }
            Divider()
            Text("Language identified for \(summary.identifiedPlays.formatted()) of \(summary.totalPlays.formatted()) counted plays.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("listeningLanguages.coverage")
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
        .accessibilityIdentifier("listeningLanguages.total.\(id)")
    }

    private func breakdown(_ summary: ListeningLanguageSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(summary.rows) { row in
                languageRow(row.language.title, plays: row.plays, songs: row.songs, share: row.share,
                            color: color(for: row.language), id: row.id)
            }
            if summary.unclassifiedPlays > 0 {
                if !summary.rows.isEmpty { Divider() }
                languageRow("Unclassified", plays: summary.unclassifiedPlays, songs: summary.unclassifiedSongs,
                            share: Double(summary.unclassifiedPlays) / Double(summary.totalPlays),
                            color: AppTheme.secondaryText, id: "unclassified")
                Text("Unclassified songs have no single identified language. They stay eligible for recommendations.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listeningLanguages.breakdown")
    }

    private func languageRow(_ title: String, plays: Int, songs: Int, share: Double, color: Color, id: String) -> some View {
        let percentage = share.formatted(.percent.precision(.fractionLength(0...1)))
        let counts = "\(plays.formatted()) \(plays == 1 ? "play" : "plays") · \(songs.formatted()) \(songs == 1 ? "song" : "songs")"
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        return VStack(alignment: .leading, spacing: 10) {
            layout {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).appFont(.headline, weight: .semibold)
                    Text(counts).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(percentage).appFont(.title3, weight: .semibold).monospacedDigit()
            }
            ProgressView(value: share, total: 1)
                .tint(color)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(counts), \(percentage) of all counted plays")
        .accessibilityIdentifier("listeningLanguages.row.\(id)")
    }

    private var classificationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if model.languageDiscovery.isChecking { ProgressView().accessibilityHidden(true) }
                Text(checkStatus)
                    .appFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("listeningLanguages.status")
            }
            if model.library.preferences.saveListeningHistory,
               model.languageDiscovery.hasPendingChecks || model.languageDiscovery.hadFailures {
                Button { model.refreshListeningLanguages() } label: {
                    Label("Check more songs", systemImage: "arrow.clockwise")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .disabled(model.languageDiscovery.isChecking)
                .accessibilityIdentifier("listeningLanguages.checkMore")
                Text("Checks run in short batches. Recent checks may need time before another attempt.")
                    .appFont(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(AppTheme.secondaryText)
    }

    private var checkStatus: String {
        if !model.library.preferences.saveListeningHistory { return "Language checks are paused." }
        if model.languageDiscovery.isChecking { return "Checking song languages…" }
        if model.languageDiscovery.hadFailures { return "Some songs could not be checked. Your listening totals still include them." }
        if model.languageDiscovery.hasPendingChecks { return "More songs are waiting for a language check." }
        return "No language checks running."
    }

    private var emptyListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.library.events.isEmpty ? "Your listening starts with a song" : "No counted plays in this window",
                  systemImage: "music.note")
                .appFont(.headline, weight: .semibold)
            Text(model.library.preferences.saveListeningHistory
                 ? "Play music you love. Counted plays from the last 30 days will appear here as you listen."
                 : "No counted plays in the last 30 days. Turn on listening history to include new listening.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("listeningLanguages.empty")
    }

    private var historyPaused: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Listening history is off", systemImage: "pause.circle")
                .appFont(.headline, weight: .semibold)
            Text("Existing stats stay here. New listening isn't added while history is off.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            Button { model.updatePreferences { $0.saveListeningHistory = true } } label: {
                Text("Turn on listening history")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("listeningLanguages.enableHistory")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listeningLanguages.historyOff")
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isTuningExpanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tune recommendations").appFont(.headline, weight: .semibold)
                        Text(model.library.preferences.languageNudges.isAutomatic ? "Optional" : "Your adjustments are saved")
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: isTuningExpanded ? "chevron.up" : "chevron.down")
                        .appFont(.subheadline, weight: .semibold)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tune recommendations")
            .accessibilityValue(isTuningExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows optional language adjustments")
            .accessibilityIdentifier("listeningLanguages.tune")
            if isTuningExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Adjustments don't change your stats. They guide your next Home refresh, new radios, and newly generated Daily Mix and Discover Weekly playlists. Saved mixes stay the same.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("listeningLanguages.tuningNote")
                    ForEach(ArtistSongLanguage.allCases) { language in
                        nudgeMenu(language)
                    }
                    Divider()
                    Button { model.resetLanguageNudges() } label: {
                        Label("Reset adjustments", systemImage: "arrow.counterclockwise")
                            .appFont(.subheadline, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
                    .disabled(model.library.preferences.languageNudges.isAutomatic)
                    .accessibilityIdentifier("listeningLanguages.reset")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.card))
    }

    private func nudgeMenu(_ language: ArtistSongLanguage) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return Menu {
            Picker(language.title, selection: Binding(
                get: { model.library.preferences.languageNudges[language] },
                set: { model.setLanguageNudge($0, for: language) }
            )) {
                ForEach(LanguageRecommendationNudge.allCases) { nudge in
                    Text(nudge.title)
                        .tag(nudge)
                        .accessibilityIdentifier("listeningLanguages.choice.\(language.rawValue).\(nudge.rawValue)")
                }
            }
        } label: {
            layout {
                Text(language.title)
                    .appFont(.body, weight: .medium)
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label(model.library.preferences.languageNudges[language].title, systemImage: "chevron.up.chevron.down")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(language.title) recommendations")
        .accessibilityValue(model.library.preferences.languageNudges[language].title)
        .accessibilityHint("Adjusts recommendations without changing listening statistics")
        .accessibilityIdentifier("listeningLanguages.nudge.\(language.rawValue)")
    }

    @ViewBuilder
    private var libraryNotice: some View {
        if let error = model.library.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your library needs attention", systemImage: "exclamationmark.triangle")
                    .appFont(.headline, weight: .semibold)
                Text(error).appFont(.subheadline).fixedSize(horizontal: false, vertical: true)
                if model.library.requiresReload {
                    LibraryReloadButton(identifier: "listeningLanguages.reload")
                }
            }
            .foregroundStyle(AppTheme.accent)
            .accessibilityIdentifier("listeningLanguages.libraryError")
        }
    }

    private func color(for language: ArtistSongLanguage) -> Color {
        switch language {
        case .hindi: AppTheme.gold
        case .english: AppTheme.violet
        default: AppTheme.accent
        }
    }
}
