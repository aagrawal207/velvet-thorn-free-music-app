import OSLog
import SwiftUI
import UIKit

/// Everything the share card shows, already shortened, so the rendered layout never depends on name length.
struct RecapShareCardContent: Equatable {
    struct Song: Equatable {
        let id: String
        let title: String
        let artist: String
    }

    static let songTitleLimit = 30
    static let songArtistLimit = 40
    static let columnLimit = 20

    var periodTitle: String
    var dateRange: String
    var totalValue: String
    var totalUnit: String
    var songs: [Song]
    var artists: [String]
    var genres: [String]
    var languages: [String]
    var coverageNote: String? = nil
    var rankingsUseRetainedHistory = false

    init(periodTitle: String, dateRange: String, totalValue: String, totalUnit: String,
         songs: [Song], artists: [String], genres: [String], languages: [String]) {
        self.periodTitle = Self.clipped(periodTitle, limit: 32)
        self.dateRange = Self.clipped(dateRange, limit: 48)
        self.totalValue = totalValue
        self.totalUnit = totalUnit
        self.songs = songs.prefix(3).map {
            Song(id: $0.id, title: Self.clipped($0.title, limit: Self.songTitleLimit),
                 artist: Self.clipped($0.artist, limit: Self.songArtistLimit))
        }
        self.artists = artists.prefix(3).map { Self.clipped($0, limit: Self.columnLimit) }
        self.genres = genres.prefix(3).map { Self.clipped($0, limit: Self.columnLimit) }
        self.languages = languages.prefix(3).map { Self.clipped($0, limit: Self.columnLimit) }
    }

    init(summary: ListeningSummary, window: ListeningWindow, now: Date,
         genres: ListeningGenreSummary, languages: ListeningLanguageSummary, allTime: Bool = false,
         lifetime: LifetimeListeningSummary? = nil) {
        let seconds = allTime ? (lifetime?.seconds ?? summary.seconds) : summary.seconds
        let usesSeconds = seconds < 60
        self.init(periodTitle: allTime ? (lifetime == nil ? "All available history" : "Lifetime Listening") : window.subtitle,
                  dateRange: RecapText.dateRange(window: window, now: now, allTime: allTime,
                      firstSavedDay: allTime ? (lifetime?.coverageStartedAt ?? summary.days.first?.date) : summary.days.first?.date),
                  totalValue: usesSeconds ? RecapText.secondsValue(seconds) : Int(seconds / 60).formatted(),
                  totalUnit: RecapText.totalUnit(seconds),
                  songs: summary.topTracks.prefix(3).map { Song(id: $0.track.id, title: $0.track.title, artist: $0.track.artistName) },
                  artists: summary.topArtists.prefix(3).map(\.name),
                  genres: genres.top(3).map(\.family.title),
                  languages: languages.rows.prefix(3).map(\.language.title))
        coverageNote = allTime ? (lifetime == nil ? RecapText.savedHistoryNote : RecapText.lifetimeDetailNote) : nil
        rankingsUseRetainedHistory = allTime && lifetime != nil
    }

    /// Cuts at a character budget sized for the card's column at its font; `lineLimit(1)` stays as the last guard.
    static func clipped(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit, limit > 1 else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// A 1080 by 1350 portrait card at scale 1, so points and pixels match and every block has a fixed height.
struct RecapShareCard: View {
    static let size = CGSize(width: 1080, height: 1350)
    private static let padding: CGFloat = 72
    private static let artworkSide: CGFloat = 112

    let content: RecapShareCardContent
    /// Already-loaded artwork by track ID; a missing entry draws the placeholder tile.
    let artwork: [String: UIImage]
    let accent: Color
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: 184, alignment: .topLeading)
            total.frame(height: 226, alignment: .topLeading)
            Spacer(minLength: 24)
            songs.frame(height: 430, alignment: .topLeading)
            Spacer(minLength: 24)
            columns.frame(height: 212, alignment: .topLeading)
            Spacer(minLength: 16)
            footer.frame(height: content.coverageNote == nil ? 36 : 68, alignment: .bottomLeading)
        }
        .padding(Self.padding)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(background)
        .foregroundStyle(primaryText)
        .environment(\.colorScheme, colorScheme)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var primaryText: Color { isDark ? .white : Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x10 / 255) }
    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.74) : Color(red: 0x3F / 255, green: 0x3F / 255, blue: 0x49 / 255)
    }
    private var baseColor: Color {
        isDark ? Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x10 / 255) : Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xFC / 255)
    }

    /// Top song palette when its artwork is loaded, otherwise the accent; tints keep the text contrast of the base.
    private var background: some View {
        let top: Color
        if let image = content.songs.first.flatMap({ artwork[$0.id] }), let palette = ArtworkPalette.extract(from: image) {
            top = palette.tint(palette.primary, luminance: isDark ? 0.06 : 0.6, saturation: 0.25...0.7).color
        } else {
            top = accent.opacity(isDark ? 0.45 : 0.35)
        }
        return ZStack {
            baseColor
            LinearGradient(colors: [top, baseColor], startPoint: .top, endPoint: .bottom)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(accent)
                Text("Velvet Thorn")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
            }
            Text(content.periodTitle)
                .font(.system(size: 66, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(content.dateRange)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.totalValue)
                .font(.system(size: 150, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(content.totalUnit)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
    }

    private var songs: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading(content.rankingsUseRetainedHistory ? "Top songs · Retained history" : "Top songs")
            ForEach(Array(content.songs.enumerated()), id: \.offset) { index, song in
                HStack(spacing: 24) {
                    Text("\(index + 1)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(secondaryText)
                        .frame(width: 40, alignment: .leading)
                    artworkTile(for: song)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(song.title)
                            .font(.system(size: 40, weight: .semibold))
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: Self.artworkSide)
            }
        }
    }

    @ViewBuilder
    private func artworkTile(for song: RecapShareCardContent.Song) -> some View {
        if let image = artwork[song.id] {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.artworkSide, height: Self.artworkSide)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            ArtworkView(url: nil, title: song.title, size: Self.artworkSide, cornerRadius: 12)
        }
    }

    /// Artists on the left; genres on the right, or languages when no genre is classified yet.
    private var columns: some View {
        let right: (title: String, rows: [String])? = !content.genres.isEmpty ? ("Top genres", content.genres)
            : !content.languages.isEmpty ? ("Languages", content.languages) : nil
        return HStack(alignment: .top, spacing: 48) {
            if !content.artists.isEmpty { column("Top artists", rows: content.artists) }
            if let right { column(right.title, rows: right.rows) }
        }
    }

    private func column(_ title: String, rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(title)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row)
                    .font(.system(size: 36, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                if !content.genres.isEmpty, !content.languages.isEmpty {
                    Text("Languages: \(content.languages.joined(separator: " · "))")
                        .lineLimit(1)
                    Spacer(minLength: 24)
                }
                Text("Made from my listening")
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .font(.system(size: 26, weight: .medium))
            if let note = content.coverageNote {
                Text(note)
                    .font(.system(size: 19, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(secondaryText)
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 26, weight: .bold))
            .tracking(2)
            .foregroundStyle(secondaryText)
            .lineLimit(1)
    }
}

@MainActor
enum RecapShareCardRenderer {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Recap")

    /// 8-bit sRGB at scale 1: exactly 1080 by 1350 pixels whatever the device scale.
    static func render(_ content: RecapShareCardContent, artwork: [String: UIImage], accent: Color,
                       colorScheme: ColorScheme) -> UIImage? {
        let resolvedAccent = Color(uiColor: UIColor(accent).resolvedColor(
            with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)))
        let card = RecapShareCard(content: content, artwork: artwork, accent: resolvedAccent, colorScheme: colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.colorMode = .nonLinear
        renderer.proposedSize = ProposedViewSize(RecapShareCard.size)
        let image = renderer.uiImage
        let size = RecapShareCard.size
        let rendered = image?.cgImage.map { $0.width == Int(size.width) && $0.height == Int(size.height) } ?? false
        log.debug("event=recap_share_card outcome=\(rendered ? "rendered" : "failed", privacy: .public) appearance=\(colorScheme == .dark ? "dark" : "light", privacy: .public) artwork=\(artwork.count, privacy: .public)")
        return rendered ? image : nil
    }

    /// Reads only artwork the loader already holds, so building a card never starts a network request.
    static func cachedArtwork(for tracks: [Track]) async -> [String: UIImage] {
        var images: [String: UIImage] = [:]
        for track in tracks.prefix(3) {
            guard let url = track.artworkURL,
                  let data = await ArtworkLoader.shared.cachedThumbnail(for: url),
                  let image = UIImage(data: data) else { continue }
            images[track.id] = image
        }
        return images
    }
}
