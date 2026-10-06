import SwiftUI
import UIKit

/// Song details page inside the player's options sheet: performers, credits, release facts, playback state and ids.
@MainActor
struct PlayerSongDetailsView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let track: Track
    let onAlbum: (MusicCollection) -> Void
    let onArtist: (ArtistCredit) -> Void

    private enum Phase: Equatable {
        case loading, loaded(TrackDetails), unavailable, offline
    }

    private struct LoadRequest: Equatable {
        var generation = 0
        var refresh = false
    }

    private static let releaseDateFormatter: DateFormatter = {
        // Release dates are calendar days stored at UTC midnight; local zones must not move them a day.
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    @State private var phase: Phase = .loading
    @State private var request = LoadRequest()
    @State private var isRefreshing = false
    @State private var showsFullDescription = false
    @State private var copiedAt: Date?

    private var details: TrackDetails? {
        if case .loaded(let details) = phase { return details }
        return nil
    }

    private var isCurrent: Bool { model.player.currentTrack?.id == track.id }

    var body: some View {
        List {
            header
            // State rows sit under the header so loading, unavailable and offline never hide below the fold.
            status
            performers
            credits
            release
            playback
            identifiers
            description
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .accessibilityIdentifier("player.details.list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard !isRefreshing else { return }
                    request = LoadRequest(generation: request.generation + 1, refresh: true)
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .frame(minWidth: 44, minHeight: 44)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .medium))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh Details")
                .accessibilityIdentifier("player.details.refresh")
            }
        }
        .task(id: request) { await load(request) }
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                ArtworkView(url: track.artworkURL, title: track.title, size: 88, cornerRadius: AppCorner.compact)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .appFont(.headline, weight: .semibold)
                        .lineLimit(3)
                        .accessibilityIdentifier("player.details.title")
                    Text(track.artistName)
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                        .accessibilityIdentifier("player.details.artists")
                    if let album = details?.albumTitle ?? track.albumTitle {
                        Text(album)
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                            .accessibilityIdentifier("player.details.albumTitle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("player.details.header")
        }
        .listRowBackground(AppTheme.surface)
    }

    @ViewBuilder
    private var performers: some View {
        let credits = track.allCredits
        if !credits.isEmpty {
            Section {
                ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                    Button {
                        onArtist(credit)
                    } label: {
                        HStack(spacing: 12) {
                            PlayerSongDetailsArtistArtwork(credit: credit, resolver: model.artistArtwork)
                            Text(credit.name)
                                .appFont(.body, weight: .medium)
                                .foregroundStyle(AppTheme.primaryText)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppTheme.secondaryText)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(credit.name)
                    .accessibilityHint("Opens the artist page")
                    .accessibilityIdentifier("player.details.performer.\(index)")
                }
            } header: {
                sectionTitle(credits.count == 1 ? "Performer" : "Performers")
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var credits: some View {
        if let details, !details.displayCredits.isEmpty {
            Section {
                ForEach(Array(details.displayCredits.enumerated()), id: \.offset) { _, credit in
                    detailRow(credit.role.title, value: credit.names.joined(separator: "\n"),
                              id: "player.details.credit.\(Self.slug(credit.role.title))")
                }
            } header: {
                sectionTitle("Credits")
            } footer: {
                if let source = details.creditSource {
                    Text(source == .musicBrainz ? "Credits from MusicBrainz" : "Credits from YouTube's release notes")
                        .appFont(.footnote)
                        .accessibilityIdentifier("player.details.credits.source")
                }
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var release: some View {
        let album = details?.albumTitle ?? track.albumTitle
        let released = releaseText
        let labelLine = details?.phonogramLine ?? details.flatMap { $0.labelNames.isEmpty ? nil : $0.labelNames.joined(separator: ", ") }
        if album != nil || released != nil || labelLine != nil || details?.copyrightLine != nil {
            Section {
                if let album {
                    if let collection = track.albumCollection {
                        Button {
                            onAlbum(collection)
                        } label: {
                            rowContent("Album", value: album, showsChevron: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Album")
                        .accessibilityValue(album)
                        .accessibilityHint("Opens the album")
                        .accessibilityIdentifier("player.details.album")
                    } else {
                        detailRow("Album", value: album, id: "player.details.album")
                    }
                }
                if let released { detailRow("Released On", value: released, id: "player.details.released") }
                if let labelLine { detailRow("Label", value: labelLine, id: "player.details.label") }
                if let copyright = details?.copyrightLine { detailRow("Copyright", value: copyright, id: "player.details.copyright") }
            } header: {
                sectionTitle("Release")
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    private var playback: some View {
        Section {
            if let duration = track.duration ?? (isCurrent && model.player.duration > 0 ? model.player.duration : nil) {
                detailRow("Duration", value: TimeText.duration(duration), id: "player.details.duration")
            }
            if isCurrent {
                detailRow("Audio Quality", value: model.player.sourceAudioQuality?.summary ?? "Quality information unavailable",
                          id: "player.details.quality")
            }
            detailRow("On This Device", value: cacheText, id: "player.details.cache")
            if let plays = PlayCountText.plays(isCurrent ? model.player.currentPlayCount : track.playCount) {
                detailRow("Plays", value: plays, id: "player.details.plays")
            }
            if model.library.preferences.saveListeningHistory {
                detailRow("Your Plays", value: yourPlays.formatted(.number), id: "player.details.yourPlays")
            }
            if let views = details?.viewCount {
                detailRow("YouTube Views", value: views.formatted(.number.grouping(.automatic)), id: "player.details.views")
            }
            if let language = track.language {
                detailRow("Language", value: language.title, id: "player.details.language")
            }
            if let genres {
                detailRow("Genres", value: genres.families.map(\.title).joined(separator: ", "), id: "player.details.genres")
            }
            if track.isExplicit {
                HStack(spacing: 8) {
                    Image(systemName: "e.square.fill")
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityHidden(true)
                    Text("Explicit")
                        .appFont(.body)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.details.explicit")
            }
        } header: {
            sectionTitle("Playback")
        } footer: {
            if genres != nil {
                Text("Genres from MusicBrainz")
                    .appFont(.footnote)
                    .accessibilityIdentifier("player.details.genres.source")
            }
        }
        .listRowBackground(AppTheme.surface)
    }

    /// Device-local genre evidence for this recording; nil until the bounded classifier has labelled it.
    private var genres: GenreDistribution? {
        guard let distribution = model.genreEvidence.distribution(for: track), distribution.isClassified else { return nil }
        return distribution
    }

    private var identifiers: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording ID")
                        .appFont(.body)
                    Text(track.id)
                        .appFont(.footnote, design: .monospaced)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                        .accessibilityIdentifier("player.details.recordingID")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = track.id
                    copiedAt = Date()
                } label: {
                    Text(copiedAt == nil ? "Copy" : "Copied")
                        .appFont(.subheadline, weight: .semibold)
                        .padding(.horizontal, 14)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .appGlass(in: Capsule(), interactive: true)
                .accessibilityLabel(copiedAt == nil ? "Copy recording ID" : "Recording ID copied")
                .accessibilityIdentifier("player.details.copyID")
            }
            .frame(minHeight: 44)
            .task(id: copiedAt) {
                guard copiedAt != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                copiedAt = nil
            }
            if let isrc = details?.isrc {
                detailRow("ISRC", value: isrc, id: "player.details.isrc")
            }
            if let recording = details?.musicBrainzRecordingID, let url = URL(string: "https://musicbrainz.org/recording/\(recording)") {
                Link(destination: url) {
                    rowContent("MusicBrainz", value: recording, showsChevron: false, symbol: "arrow.up.right.square")
                }
                .accessibilityLabel("MusicBrainz recording")
                .accessibilityValue(recording)
                .accessibilityIdentifier("player.details.musicbrainz")
            }
            if let channel = details?.channelTitle {
                detailRow("Channel", value: channel, id: "player.details.channel")
            }
            if let published = details?.publishedAt {
                detailRow("Published", value: published.formatted(date: .abbreviated, time: .omitted), id: "player.details.published")
            }
            if track.source == .youTubeMusic, let url = track.shareURL {
                Link(destination: url) {
                    HStack(spacing: 8) {
                        Text("Open in YouTube Music")
                            .appFont(.body, weight: .medium)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("player.details.openYouTube")
            }
        } header: {
            sectionTitle("Identifiers")
        }
        .listRowBackground(AppTheme.surface)
    }

    @ViewBuilder
    private var description: some View {
        if let text = details?.description, !text.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .appFont(.footnote)
                        .foregroundStyle(AppTheme.primaryText)
                        .lineLimit(showsFullDescription ? nil : 4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("player.details.description")
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsFullDescription.toggle() }
                    } label: {
                        Text(showsFullDescription ? "Show Less" : "Show More")
                            .appFont(.subheadline, weight: .semibold)
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("player.details.description.more")
                }
                .padding(.vertical, 4)
            } header: {
                sectionTitle("Description")
            }
            .listRowBackground(AppTheme.surface)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading details")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.details.loading")
            }
            .listRowBackground(AppTheme.surface)
        case .unavailable:
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details are not available for this song right now.")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("player.details.unavailable")
                    Button {
                        request = LoadRequest(generation: request.generation + 1, refresh: true)
                    } label: {
                        Text("Retry")
                            .appFont(.body, weight: .semibold)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.borderless)
                    .appGlass(in: Capsule(), interactive: true)
                    .accessibilityIdentifier("player.details.retry")
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(AppTheme.surface)
        case .offline:
            Section {
                Text("Details need a connection.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("player.details.offline")
            }
            .listRowBackground(AppTheme.surface)
        case .loaded:
            EmptyView()
        }
    }

    // MARK: - Rows

    private func sectionTitle(_ title: String) -> some View {
        Text(title).appFont(.caption)
    }

    private func detailRow(_ title: String, value: String, id: String) -> some View {
        rowContent(title, value: value, showsChevron: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(value)
            .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func rowContent(_ title: String, value: String, showsChevron: Bool, symbol: String? = nil) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    rowTitle(title)
                    HStack(alignment: .top, spacing: 8) {
                        rowValue(value, alignment: .leading)
                        rowTrailing(showsChevron: showsChevron, symbol: symbol)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    rowTitle(title)
                    Spacer(minLength: 8)
                    rowValue(value, alignment: .trailing)
                    rowTrailing(showsChevron: showsChevron, symbol: symbol)
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func rowTitle(_ title: String) -> some View {
        Text(title)
            .appFont(.body)
            .foregroundStyle(AppTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowValue(_ value: String, alignment: TextAlignment) -> some View {
        Text(value)
            .appFont(.body)
            .foregroundStyle(AppTheme.secondaryText)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }

    @ViewBuilder
    private func rowTrailing(showsChevron: Bool, symbol: String?) -> some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityHidden(true)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AppTheme.secondaryText)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Derived values

    private var releaseText: String? {
        guard let details else { return nil }
        if let date = details.releaseDate { return Self.releaseDateFormatter.string(from: date) }
        return details.releaseDateText
    }

    private var cacheText: String {
        let inventoryIsKnown = model.hasLoadedCachedSongs && model.cachedSongsUsage != nil && model.cachedSongsError == nil
        let cached = (isCurrent && model.player.isCurrentTrackCached) || (inventoryIsKnown && model.cachedPlayableTrackIDs.contains(track.id))
        if cached { return "Cached on this device" }
        if inventoryIsKnown { return model.isOffline ? "Needs a connection" : "Not cached" }
        return "Cache status unavailable"
    }

    private var yourPlays: Int {
        model.library.events.reduce(into: 0) { count, event in
            if event.track.id == track.id, event.listenedSeconds >= ListeningAnalytics.qualifyingSeconds(for: event.track) { count += 1 }
        }
    }

    private static func slug(_ title: String) -> String {
        var slug = ""
        for scalar in title.lowercased().unicodeScalars {
            let isPlain = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            slug.unicodeScalars.append(isPlain ? scalar : "-")
        }
        return slug
    }

    // MARK: - Loading

    private func load(_ request: LoadRequest) async {
        let hadContent = details != nil
        if request.refresh, hadContent { isRefreshing = true } else { phase = .loading }
        defer { isRefreshing = false }
        let result = await model.songDetails.details(for: track, refresh: request.refresh)
        guard !Task.isCancelled else { return }
        if let result {
            phase = .loaded(result)
        } else if hadContent, request.refresh {
            return
        } else {
            phase = model.isOffline ? .offline : .unavailable
        }
    }
}

/// Circular 44-point artist picture resolved through the shared bounded resolver, matching the artist chooser rows.
@MainActor
private struct PlayerSongDetailsArtistArtwork: View {
    let credit: ArtistCredit
    let resolver: ArtistArtworkResolver
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var imageCredit: ArtistCredit?

    var body: some View {
        ZStack {
            Circle().fill(AppTheme.raised)
            if imageCredit == credit, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: credit, priority: .utility) {
            image = nil
            imageCredit = nil
            let loaded = await resolver.image(for: credit, maxPixels: Int((44 * displayScale).rounded(.up)))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                image = loaded
                imageCredit = credit
            }
        }
    }
}
