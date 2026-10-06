import SwiftUI
import UIKit

/// The facts printed on a song card. Album and year come from Song details only when that lookup answers.
struct SongShareCardContent: Equatable, Sendable {
    var title: String
    var artists: String
    var album: String?
    var year: String?
    var duration: String?
    var sourceName: String
    var listenLine: String
    var appName = "Velvet Thorn"
    var url: URL?

    init(track: Track, details: TrackDetails? = nil) {
        title = track.title
        artists = track.artistName
        let album = (details?.albumTitle ?? track.albumTitle)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album?.isEmpty == false ? album : nil
        year = Self.year(from: details)
        duration = PlaybackTiming.validDuration(track.duration).map(TimeText.duration)
        sourceName = track.source.title
        listenLine = "Listen on \(track.source.title)"
        url = track.shareURL
    }

    /// "Album · 2013", or whichever half is known.
    var releaseLine: String? {
        let parts = [album, year].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var metaLine: String { [duration, sourceName].compactMap { $0 }.joined(separator: " · ") }

    private static func year(from details: TrackDetails?) -> String? {
        if let date = details?.releaseDate {
            return String(Calendar(identifier: .gregorian).component(.year, from: date))
        }
        guard let text = details?.releaseDateText, text.count >= 4 else { return nil }
        let prefix = String(text.prefix(4))
        return prefix.allSatisfy(\.isNumber) ? prefix : nil
    }
}

/// A 1080 by 1350 portrait card (the 4:5 shape Messages and social apps show uncropped), drawn at scale 1.
struct SongShareCard: View {
    static let size = CGSize(width: 1080, height: 1350)
    private static let padding: CGFloat = 72
    private static let artworkSide: CGFloat = 760

    let content: SongShareCardContent
    let artwork: UIImage?
    /// Passed in because `Color.accentColor` does not follow the app's tint inside `ImageRenderer`.
    var accent: Color = AppAccent.coral.color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artworkView
                .frame(maxWidth: .infinity)
            Spacer().frame(height: 44)
            Text(content.title)
                .font(.system(size: 60, weight: .bold))
                .foregroundStyle(primary)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(content.artists)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 6)
            if let release = content.releaseLine {
                Text(release)
                    .font(.system(size: 32))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 10)
            }
            Text(content.metaLine)
                .font(.system(size: 30))
                .monospacedDigit()
                .foregroundStyle(secondary)
                .lineLimit(1)
                .padding(.top, 6)
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(accent)
                Text(content.listenLine)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(primary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(content.appName)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(secondary)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(background)
    }

    private var isDark: Bool { colorScheme == .dark }
    private var primary: Color { isDark ? .white : Color(white: 0.08) }
    private var secondary: Color { isDark ? Color(white: 0.72) : Color(white: 0.36) }

    private var background: some View {
        ZStack {
            LinearGradient(colors: isDark ? [Color(white: 0.12), Color(white: 0.04)] : [.white, Color(white: 0.92)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(isDark ? 0.28 : 0.16), .clear],
                           center: UnitPoint(x: 0.85, y: 0.1), startRadius: 0, endRadius: 900)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        Group {
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform")
                        .font(.system(size: 220, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: Self.artworkSide, height: Self.artworkSide)
        .clipShape(shape)
        .shadow(color: .black.opacity(isDark ? 0.5 : 0.18), radius: 30, y: 12)
    }
}

@MainActor
enum SongShareCardRenderer {
    /// Renders at scale 1 so the bitmap is exactly 1080 by 1350 pixels whatever the screen.
    static func render(_ content: SongShareCardContent, artwork: UIImage?, colorScheme: ColorScheme,
                       accent: Color = AppAccent.coral.color) -> UIImage? {
        let renderer = ImageRenderer(content: SongShareCard(content: content, artwork: artwork, accent: accent)
            .environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(SongShareCard.size)
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Song details only when they arrive within the deadline; a slow lookup leaves album and year off the card.
    static func details(from provider: any TrackDetailsProviding, for track: Track,
                        deadline: Duration = .seconds(2)) async -> TrackDetails? {
        let (stream, continuation) = AsyncStream<TrackDetails?>.makeStream()
        let lookup = Task {
            continuation.yield(await provider.details(for: track, refresh: false))
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: deadline)
            continuation.yield(nil)
            continuation.finish()
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next() ?? nil
        lookup.cancel()
        timer.cancel()
        return first
    }
}

/// Preview of the rendered card with one Share button that sends the picture and the song link together.
@MainActor
struct SongShareCardPage: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let track: Track
    @State private var image: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: AppCorner.card))
                            .accessibilityLabel("Song card for \(track.title)")
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 320)
                            .accessibilityLabel("Preparing song card")
                    }
                }
                .frame(maxWidth: 420)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(image == nil ? "Preparing song card" : "Song card for \(track.title)")
                .accessibilityIdentifier("songShare.preview")
                shareButton
                if let url = track.shareURL {
                    ShareLink(item: url, preview: SharePreview(track.title)) {
                        Label("Share Link Only", systemImage: "link")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("songShare.linkOnly")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.background)
        .accessibilityIdentifier("songShare.page")
        .task(id: colorScheme) {
            let details = await SongShareCardRenderer.details(from: model.songDetails, for: track)
            let artwork: UIImage? = if let url = track.artworkURL {
                await ArtworkLoader.shared.image(for: url, tier: .large, maxPixels: 1080)
            } else { nil }
            guard !Task.isCancelled else { return }
            image = SongShareCardRenderer.render(SongShareCardContent(track: track, details: details),
                                                 artwork: artwork, colorScheme: colorScheme,
                                                 accent: model.library.preferences.accent.color)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let image {
            let picture = Image(uiImage: image)
            ShareLink(item: picture, subject: Text(track.title),
                      message: Text(track.shareURL?.absoluteString ?? track.title),
                      preview: SharePreview(track.title, image: picture)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .appFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .appGlass(in: Capsule(), interactive: true)
            .accessibilityIdentifier("songShare.share")
        }
    }
}

/// The song menu's presentation of the card page, with its own Done button.
@MainActor
struct SongShareCardSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track

    var body: some View {
        NavigationStack {
            SongShareCardPage(track: track)
                .navigationTitle("Share Song")
                .navigationBarTitleDisplayMode(.inline)
                .appSheetDoneButton(id: "songShare.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
    }
}
