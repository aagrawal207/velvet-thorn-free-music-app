import SwiftUI

@MainActor
struct ArtistSpotlightCard: View {
    /// Owned by the artist page, which starts the shared song load before this card is ever opened.
    let loader: ArtistSpotlightLoader

    var body: some View {
        AppNavigationLink {
            ArtistSpotlightView(loader: loader)
        } label: {
            HStack(spacing: 16) {
                ArtworkView(url: loader.artist.artworkURL, title: loader.artist.name, size: 72, cornerRadius: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(loader.collection.title)
                        .appFont(.headline, weight: .bold)
                        .foregroundStyle(AppTheme.primaryText)
                    Text("Popular songs from YouTube Music")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loader.collection.title)
        .accessibilityHint("Open popular songs sorted by available YouTube Music play counts")
        .accessibilityIdentifier("artist.spotlight.open")
    }
}

@MainActor
struct ArtistSpotlightView: View {
    @Environment(MusicAppModel.self) private var model
    let loader: ArtistSpotlightLoader

    var body: some View {
        CollectionDetailView(collection: loader.collection, spotlight: loader)
            // requestReload() resets the loader itself; the id change only re-runs this once per Try again.
            .task(id: loader.reloadRequest) {
                await loader.load(catalog: model.catalog, lyrics: model.lyrics, library: model.library)
            }
            // The song load outlives this screen because the artist page beneath it shows the same tracks.
            .onDisappear { loader.cancelLanguageChecks() }
    }
}

@MainActor
struct ArtistSpotlightControls: View {
    @Environment(\.secondaryTextColor) private var secondaryText
    let loader: ArtistSpotlightLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ArtistSpotlight.countProvenance)
                    .appFont(.caption, weight: .semibold)
                    .accessibilityIdentifier("artist.spotlight.countProvenance")
                Text("YouTube Music plays for the available recordings, not a complete all-time chart.")
                    .appFont(.caption)
                    .foregroundStyle(secondaryText)
                if loader.missingPlayCounts > 0 {
                    Text(loader.missingPlayCounts == 1 ? "1 song without a play count appears last."
                         : "\(loader.missingPlayCounts) songs without play counts appear last.")
                        .appFont(.caption)
                        .foregroundStyle(secondaryText)
                }
            }

            if loader.isLoadingSongs {
                progress("Checking available songs and play counts")
            }

            if !loader.tracks.isEmpty {
                languageDisclosure
                if loader.isBrowsingLanguages { languageBrowser }
            } else if !loader.isLoadingSongs {
                EmptyStateView(symbol: "music.note.list", title: "No songs available yet",
                               message: "The provider hasn't returned playable songs for this artist.")
            }

            if loader.hadCatalogFailures || (loader.hasLoaded && loader.tracks.isEmpty) {
                if loader.hadCatalogFailures {
                    Text("Some songs or play counts couldn't be checked. Showing the available songs.")
                        .appFont(.caption)
                        .foregroundStyle(secondaryText)
                }
                Button("Try again", systemImage: "arrow.clockwise") { loader.requestReload() }
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .disabled(loader.isBusy)
                    .accessibilityIdentifier("artist.spotlight.retry")
            }
        }
    }

    private var languageDisclosure: some View {
        Button { loader.isBrowsingLanguages.toggle() } label: {
            HStack(spacing: 8) {
                Label(loader.languageControlTitle, systemImage: "globe")
                    .appFont(.subheadline, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if loader.filter != .all {
                    Text(loader.filter.title).appFont(.caption, weight: .semibold).lineLimit(1)
                } else if loader.hasUsefulLanguageFacets {
                    Text(loader.availableLanguages.count.formatted()).appFont(.caption).monospacedDigit()
                }
                Image(systemName: loader.isBrowsingLanguages ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(secondaryText)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(loader.languageControlTitle)
        .accessibilityValue("\(loader.isBrowsingLanguages ? "Expanded" : "Collapsed"), \(loader.filter.title), \(loader.availableLanguages.count) confirmed languages")
        .accessibilityHint("Show filters, check languages, or correct an individual song")
        .accessibilityIdentifier("artist.spotlight.browseLanguages")
    }

    private var languageBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(loader.filters) { filter in languageButton(filter) }
                }
            }
            .accessibilityIdentifier("artist.spotlight.languages")

            if loader.isCheckingLanguages {
                progress("Checking song languages · \(loader.checkedLanguageCount) of \(loader.tracks.count) checked")
            }
            if loader.unclassifiedCount > 0 {
                Text("\(loader.unclassifiedCount) \(loader.unclassifiedCount == 1 ? "song is" : "songs are") unclassified and still available in All.")
                    .appFont(.caption)
                    .foregroundStyle(secondaryText)
                    .accessibilityIdentifier("artist.spotlight.unclassified")
            }
            Text("Tap a song's language below to review its source or correct it.")
                .appFont(.caption)
                .foregroundStyle(secondaryText)
            if loader.hasInferredLanguages {
                Text(ArtistSpotlight.lyricsProvenance)
                    .appFont(.caption)
                    .foregroundStyle(secondaryText)
                    .accessibilityIdentifier("artist.spotlight.languageProvenance")
            }
            if loader.hasLikelyLanguages {
                Text("Likely languages are suggestions and stay in Unclassified until confirmed.")
                    .appFont(.caption)
                    .foregroundStyle(secondaryText)
            }
            if loader.canCheckMoreLanguages {
                Button { loader.checkMoreLanguages() } label: {
                    Label("Check more song languages", systemImage: "text.magnifyingglass")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(loader.isBusy)
                .accessibilityIdentifier("artist.spotlight.checkLanguages")
            }
            if loader.hasFailedLanguageChecks {
                Button { loader.checkMoreLanguages(retryFailures: true) } label: {
                    Label("Retry language checks", systemImage: "arrow.clockwise")
                        .appFont(.subheadline, weight: .semibold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(loader.isBusy)
                .accessibilityIdentifier("artist.spotlight.retryLanguages")
            }
        }
    }

    private func languageButton(_ filter: ArtistSpotlightFilter) -> some View {
        let selected = loader.filter == filter
        let count = loader.count(for: filter)
        return Button { loader.filter = filter } label: {
            HStack(spacing: 6) {
                Text(filter.title).appFont(.subheadline, weight: .semibold)
                Text(count.formatted()).appFont(.caption).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(selected ? AppTheme.onAccent : AppTheme.primaryText)
            .background(selected ? AppTheme.accent : AppTheme.surface, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(count) \(count == 1 ? "song" : "songs")")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("artist.spotlight.language.\(filter.id)")
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().tint(AppTheme.accent)
            Text(title).appFont(.caption).foregroundStyle(secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
