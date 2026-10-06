import SwiftUI
import UIKit

/// Short album/credit lists fit their content; from six credits on the sheet scrolls and offers the full height.
@MainActor
struct PlayerArtistPickerSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let track: Track
    let onArtist: (ArtistCredit) -> Void
    var onAlbum: ((MusicCollection) -> Void)? = nil
    @State private var fittedHeight: CGFloat?

    private var credits: [ArtistCredit] { track.allCredits }
    private var album: MusicCollection? { onAlbum == nil ? nil : track.albumCollection }
    private var identifier: String { onAlbum == nil ? "player.artists" : "player.browse" }

    var body: some View {
        NavigationStack {
            PlayerArtistRows(credits: credits, onArtist: onArtist, album: album, onAlbum: onAlbum,
                             onFittedHeight: { fittedHeight = $0 })
                .navigationTitle(onAlbum == nil ? "Go to Artist" : "Album and Artists")
                .navigationBarTitleDisplayMode(.inline)
                .appSheetDoneButton(id: "\(identifier).done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .presentationDetents(detents)
        // Regular widths present a form sheet; fitting it vertically keeps the same content-sized feel as the phone.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).sheet")
    }

    private var detents: Set<PresentationDetent> {
        let height = fittedHeight ?? PlayerArtistRows.estimatedHeight(rows: credits.count, hasAlbum: album != nil)
        return credits.count > PlayerArtistRows.fittedRowLimit ? [.height(height), .large] : [.height(height)]
    }
}

/// Artist choices as a surface card of TrackRow-like rows, shared by the picker sheet and the options page.
@MainActor
struct PlayerArtistRows: View {
    @Environment(MusicAppModel.self) private var model
    static let fittedRowLimit = 5
    private static let rowHeight: CGFloat = 56
    private static let cardPadding = EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20)
    private static let estimatedBarHeight: CGFloat = 56
    private static let sectionSpacing: CGFloat = 12

    let credits: [ArtistCredit]
    let onArtist: (ArtistCredit) -> Void
    var album: MusicCollection? = nil
    var onAlbum: ((MusicCollection) -> Void)? = nil
    /// Includes the optional album, navigation bar and the first `fittedRowLimit` artist rows.
    var onFittedHeight: ((CGFloat) -> Void)? = nil
    @State private var rowHeights: [Int: CGFloat] = [:]
    @State private var albumHeight: CGFloat = Self.rowHeight
    @State private var barHeight: CGFloat = Self.estimatedBarHeight

    static func estimatedHeight(rows: Int, hasAlbum: Bool = false) -> CGFloat {
        estimatedBarHeight + cardPadding.top + cardPadding.bottom + CGFloat(min(rows, fittedRowLimit)) * rowHeight
            + (hasAlbum ? rowHeight + (rows > 0 ? sectionSpacing : 0) : 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Self.sectionSpacing) {
                if let album, let onAlbum {
                    Button { onAlbum(album) } label: {
                        PlayerOptionLabel(title: "Go to Album", symbol: "square.stack", subtitle: album.title, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go to Album")
                    .accessibilityValue(album.title)
                    .accessibilityIdentifier("player.browse.album")
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height.isFinite, height > 0 else { return }
                        albumHeight = height
                        reportFittedHeight()
                    }
                }

                if !credits.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                            Button {
                                onArtist(credit)
                            } label: {
                                HStack(spacing: 12) {
                                    PlayerArtistArtwork(credit: credit, resolver: model.artistArtwork)
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
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(credit.name)
                            .accessibilityIdentifier("player.artist.\(index)")
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                guard height.isFinite, height > 0 else { return }
                                rowHeights[index] = height
                                reportFittedHeight()
                            }
                        }
                    }
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppCorner.sheetCard))
                }
            }
            .padding(Self.cardPadding)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
            // Inside the sheet the top inset is the navigation bar, which the fitted detent has to include.
            barHeight = inset > 0 ? inset : Self.estimatedBarHeight
            reportFittedHeight()
        }
        .accessibilityIdentifier(onAlbum == nil ? "player.artists.list" : "player.browse.list")
    }

    private func reportFittedHeight() {
        guard let onFittedHeight else { return }
        let rows = (0..<min(credits.count, Self.fittedRowLimit)).reduce(CGFloat(0)) { $0 + (rowHeights[$1] ?? Self.rowHeight) }
        let albumSection = album != nil && onAlbum != nil ? albumHeight + (credits.isEmpty ? 0 : Self.sectionSpacing) : 0
        onFittedHeight(barHeight + Self.cardPadding.top + Self.cardPadding.bottom + rows + albumSection)
    }
}

@MainActor
private struct PlayerArtistArtwork: View {
    let credit: ArtistCredit
    let resolver: ArtistArtworkResolver
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var imageCredit: ArtistCredit?
    @State private var generation = UUID()

    var body: some View {
        ZStack {
            Color.clear
            if imageCredit == credit, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: credit, priority: .utility) {
            guard !Task.isCancelled else { return }
            let request = UUID()
            generation = request
            image = nil
            imageCredit = nil
            let loaded = await resolver.image(for: credit, maxPixels: Int((44 * displayScale).rounded(.up)))
            guard !Task.isCancelled, generation == request else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                image = loaded
                imageCredit = credit
            }
        }
        .onDisappear {
            generation = UUID()
            image = nil
            imageCredit = nil
        }
    }
}
