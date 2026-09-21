import SwiftUI

@MainActor
struct ArtistSpotlightCard: View {
    @State private var loader: ArtistSpotlightLoader

    init(artist: ArtistPage) {
        _loader = State(initialValue: ArtistSpotlightLoader(artist: artist))
    }

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
                    Text("Popular songs · Explore by language")
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
            .task(id: loader.reloadRequest) {
                await loader.load(catalog: model.catalog, lyrics: model.lyrics, force: loader.reloadRequest > 0, library: model.library)
            }
            .onChange(of: model.library.recordingLanguageOverrides) { _, _ in loader.overridesChanged() }
            .onDisappear { loader.cancel() }
    }
}

@MainActor
struct ArtistSpotlightControls: View {
    let loader: ArtistSpotlightLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ArtistSpotlight.countProvenance)
                    .appFont(.caption, weight: .semibold)
                    .accessibilityIdentifier("artist.spotlight.countProvenance")
                Text("YouTube Music plays for the available recordings, not a complete all-time chart.")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                if loader.missingPlayCounts > 0 {
                    Text(loader.missingPlayCounts == 1 ? "1 song without a play count appears last."
                         : "\(loader.missingPlayCounts) songs without play counts appear last.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }

            if loader.isLoadingSongs {
                progress("Checking available songs and play counts")
            }

            if !loader.tracks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(loader.filters) { filter in
                            languageButton(filter)
                        }
                    }
                }
                .accessibilityIdentifier("artist.spotlight.languages")

                if loader.isCheckingLanguages {
                    progress("Checking song languages · \(loader.checkedLanguageCount) of \(loader.tracks.count) checked")
                }
                if loader.unclassifiedCount > 0 {
                    Text("\(loader.unclassifiedCount) \(loader.unclassifiedCount == 1 ? "song is" : "songs are") unclassified and still available in All.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("artist.spotlight.unclassified")
                }
                if loader.availableLanguages.isEmpty, !loader.isBusy {
                    Text("Song languages are still unconfirmed. You can set a song's language below.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                if loader.hasInferredLanguages {
                    Text(ArtistSpotlight.lyricsProvenance)
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("artist.spotlight.languageProvenance")
                }
                if loader.hasLikelyLanguages {
                    Text("Likely languages are suggestions and stay in Unclassified until confirmed. Tap a song's language to correct it.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                if loader.canCheckMoreLanguages {
                    Button("Check more song languages", systemImage: "text.magnifyingglass") {
                        loader.checkMoreLanguages()
                    }
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .disabled(loader.isBusy)
                    .accessibilityIdentifier("artist.spotlight.checkLanguages")
                } else if loader.hasFailedLanguageChecks {
                    Button("Retry language checks", systemImage: "arrow.clockwise") {
                        loader.checkMoreLanguages(retryFailures: true)
                    }
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .disabled(loader.isBusy)
                    .accessibilityIdentifier("artist.spotlight.retryLanguages")
                }
            } else if !loader.isLoadingSongs {
                EmptyStateView(symbol: "music.note.list", title: "No songs available yet",
                               message: "The provider hasn't returned playable songs for this artist.")
            }

            if loader.hadCatalogFailures || (loader.hasLoaded && loader.tracks.isEmpty) {
                if loader.hadCatalogFailures {
                    Text("Some songs or play counts couldn't be checked. Showing the available songs.")
                        .appFont(.caption)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Button("Try again", systemImage: "arrow.clockwise") { loader.requestReload() }
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44)
                    .disabled(loader.isBusy)
                    .accessibilityIdentifier("artist.spotlight.retry")
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
            Text(title).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
