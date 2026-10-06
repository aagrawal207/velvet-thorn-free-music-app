import SwiftUI
import WidgetKit

@MainActor
struct MusicWidgetView: View {
    let snapshot: WidgetLibrarySnapshot
    let kind: MusicWidgetKind
    var mixKind: GeneratedPlaylistKind = .dailyMix

    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var scaledTitle: CGFloat = 14
    @ScaledMetric(relativeTo: .caption2) private var scaledCaption: CGFloat = 11
    #if DEBUG
    @Environment(\.musicWidgetPreviewFamily) private var previewFamily
    #endif

    private var family: WidgetFamily {
        #if DEBUG
        previewFamily ?? widgetFamily
        #else
        widgetFamily
        #endif
    }

    private var presentation: MusicWidgetPresentation {
        MusicWidgetPresentation(snapshot: snapshot, kind: kind, mixKind: mixKind)
    }

    private var primary: Color { renderingMode == .fullColor ? AppTheme.primaryText : .primary }
    private var secondary: Color { renderingMode == .fullColor ? AppTheme.secondaryText : .secondary }
    private var accent: Color { renderingMode == .fullColor ? snapshot.accent.color : .primary }

    var body: some View {
        GeometryReader { geometry in
            let layout = MusicWidgetLayout(size: geometry.size, family: family, dynamicTypeSize: dynamicTypeSize,
                                           scaledTitle: scaledTitle, scaledCaption: scaledCaption)
            content(layout)
                .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                .padding(layout.padding)
        }
        .foregroundStyle(primary)
        .tint(snapshot.accent.color)
        .accentColor(snapshot.accent.color)
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                AppTheme.surface
                    .overlay {
                        LinearGradient(colors: [snapshot.accent.color.opacity(colorScheme == .dark ? 0.12 : 0.05), .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
            } else {
                Color.clear
            }
        }
        .widgetURL(presentation.widgetRoute(for: family).url)
    }

    @ViewBuilder
    private func content(_ layout: MusicWidgetLayout) -> some View {
        if layout.isSmall {
            smallContent(layout)
                .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                .contentShape(.interaction, Rectangle())
                .accessibilityRepresentation {
                    // The nonvisual shape gives WidgetKit a card-sized link instead of a descendant glyph's bounds.
                    Rectangle()
                        .frame(width: layout.contentSize.width, height: layout.contentSize.height)
                        .accessibilityElement(children: .ignore)
                        .contentShape(.accessibility, Rectangle())
                        .accessibilityLabel(presentation.smallAccessibilityLabel)
                        .accessibilityHint(presentation.emptyState != nil || kind == .mixes ? "Open in Velvet Thorn" : "Opens Velvet Thorn and plays this song")
                        .accessibilityAddTraits(.isLink)
                        .accessibilityIdentifier("widget.small.\(kind.rawValue)")
                        #if DEBUG
                        .accessibilityValue("r8-small-card-v2")
                        #endif
                        .privacySensitive(presentation.emptyState == nil)
                }
                .privacySensitive(presentation.emptyState == nil)
        } else if let state = presentation.emptyState {
            Link(destination: presentation.browseRoute.url) {
                emptyContent(state, layout: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(minHeight: MusicWidgetLayout.minimumActionHeight)
                    .contentShape([.interaction, .accessibility], Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.heading). \(state.title). \(state.message)")
            .accessibilityHint("Open in Velvet Thorn")
            .accessibilityIdentifier("widget.empty.\(kind.rawValue)")
        } else if kind == .mixes {
            mixContent(layout)
        } else {
            trackList(layout)
        }
    }

    @ViewBuilder
    private func smallContent(_ layout: MusicWidgetLayout) -> some View {
        if let state = presentation.emptyState {
            emptyContent(state, layout: layout)
        } else {
            VStack(alignment: .leading, spacing: layout.spacing) {
                smallHeading(layout)
                if layout.smallArtworkSide > 0 {
                    HStack(alignment: .bottom) {
                        if kind == .mixes {
                            MusicWidgetCollage(tracks: presentation.tracks, artwork: snapshot.artwork, side: layout.smallArtworkSide)
                        } else if let track = presentation.tracks.first {
                            MusicWidgetArtwork(data: snapshot.artwork[track.id], side: layout.smallArtworkSide)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: kind == .mixes ? "arrow.up.right" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 28, height: 28)
                            .background(accent.opacity(0.1), in: Circle())
                            .widgetAccentable()
                            .accessibilityHidden(true)
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind == .mixes ? mixKind.widgetTitle : presentation.tracks.first?.title ?? "")
                        .font(.system(size: layout.titlePointSize, weight: .semibold))
                        .lineLimit(layout.smallTitleLineLimit)
                    Text(kind == .mixes ? presentation.countText ?? "Open mix" : presentation.tracks.first?.artistName ?? "")
                        .font(.system(size: layout.captionPointSize))
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: layout.smallArtworkSide == 0 ? .infinity : nil, alignment: .bottomLeading)
                .privacySensitive()
            }
        }
    }

    private func smallHeading(_ layout: MusicWidgetLayout) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(kind.title)
                .font(.system(size: layout.headingPointSize, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .widgetAccentable()
                .accessibilityHidden(true)
        }
        .frame(height: layout.smallHeaderHeight, alignment: .top)
    }

    private func trackList(_ layout: MusicWidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            headingLink(layout, height: layout.headerHeight)
            ForEach(Array(presentation.tracks.prefix(layout.maximumTrackRows))) { track in
                if let route = presentation.trackRoute(for: track.id) {
                    Link(destination: route.url) {
                        HStack(spacing: 9) {
                            MusicWidgetArtwork(data: snapshot.artwork[track.id], side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: layout.titlePointSize, weight: .semibold))
                                    .lineLimit(layout.rowTitleLineLimit)
                                Text(track.artistName)
                                    .font(.system(size: layout.captionPointSize))
                                    .foregroundStyle(secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accent)
                                .widgetAccentable()
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: layout.rowHeight)
                        .contentShape([.interaction, .accessibility], Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(track.title), \(track.artistName)\(track.isExplicit ? ". Explicit" : "")")
                    .accessibilityHint("Open and play in Velvet Thorn")
                    .accessibilityIdentifier("widget.track.\(kind.rawValue).\(track.id)")
                    .privacySensitive()
                }
            }
        }
    }

    private func headingLink(_ layout: MusicWidgetLayout, height: CGFloat) -> some View {
        Link(destination: presentation.browseRoute.url) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    if !layout.isAccessibilitySize {
                        HStack(spacing: 3) {
                            Image(systemName: "leaf.fill").font(.system(size: 8))
                            Text("Velvet Thorn").font(.system(size: 10, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(secondary)
                        .accessibilityHidden(true)
                    }
                    Text(presentation.heading)
                        .font(.system(size: layout.headingPointSize, weight: .semibold, design: .rounded))
                        .lineLimit(kind == .mixes && layout.isAccessibilitySize ? 2 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if kind != .mixes {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                        .widgetAccentable()
                        .accessibilityHidden(true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape([.interaction, .accessibility], Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(presentation.heading)")
        .accessibilityValue(presentation.countText ?? "")
        .accessibilityHint("Browse in Velvet Thorn")
        .accessibilityIdentifier("widget.open.\(kind.rawValue)")
        .privacySensitive(presentation.countText != nil)
    }

    @ViewBuilder
    private func mixContent(_ layout: MusicWidgetLayout) -> some View {
        if layout.isLarge {
            VStack(spacing: 8) {
                headingLink(layout, height: layout.headerHeight)
                VStack(spacing: 8) {
                    MusicWidgetCollage(tracks: presentation.tracks, artwork: snapshot.artwork, side: layout.mixArtworkSide)
                    if layout.mixShowsCount { mixCaption(layout) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                playMixLink(layout)
            }
        } else {
            HStack(spacing: layout.columnSpacing) {
                MusicWidgetCollage(tracks: presentation.tracks, artwork: snapshot.artwork, side: layout.mixArtworkSide)
                VStack(alignment: .leading, spacing: layout.spacing) {
                    headingLink(layout, height: layout.mixHeaderHeight)
                    if layout.mixShowsCount { mixCaption(layout) }
                    playMixLink(layout)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private func mixCaption(_ layout: MusicWidgetLayout) -> some View {
        Text(presentation.countText ?? "Saved in Velvet Thorn")
            .font(.system(size: layout.captionPointSize))
            .foregroundStyle(secondary)
            .lineLimit(1)
            .privacySensitive()
    }

    @ViewBuilder
    private func playMixLink(_ layout: MusicWidgetLayout) -> some View {
        if let route = presentation.playMixRoute {
            Link(destination: route.url) {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill").accessibilityHidden(true)
                    Text("Play mix")
                }
                .font(.system(size: min(layout.titlePointSize, 20), weight: .semibold))
                .foregroundStyle(renderingMode == .fullColor ? AppTheme.onAccent : primary)
                .frame(maxWidth: .infinity, minHeight: MusicWidgetLayout.minimumActionHeight)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(renderingMode == .fullColor ? accent : primary.opacity(0.12))
                }
                .contentShape([.interaction, .accessibility], Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(mixKind.widgetTitle)")
            .accessibilityHint("Open and play this saved mix in Velvet Thorn")
            .accessibilityIdentifier("widget.mix.play")
        }
    }

    private func emptyContent(_ state: MusicWidgetPresentation.EmptyState, layout: MusicWidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            HStack(alignment: .top, spacing: 5) {
                Text(presentation.heading)
                    .font(.system(size: layout.headingPointSize, weight: .semibold, design: .rounded))
                    .lineLimit(layout.isSmall ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: state == .historyOff ? "eye.slash" : kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
            .frame(height: layout.emptyHeaderHeight, alignment: .top)
            VStack(alignment: .leading, spacing: layout.spacing) {
                Text(state.title)
                    .font(.system(size: layout.emptyTitlePointSize, weight: .semibold))
                    .lineLimit(layout.emptyTitleLineLimit)
                if layout.emptyMessageLineLimit > 0 {
                    Text(layout.isSmall ? state.compactMessage : state.message)
                        .font(.system(size: layout.captionPointSize))
                        .foregroundStyle(secondary)
                        .lineLimit(layout.emptyMessageLineLimit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text("Open Velvet Thorn")
                Image(systemName: "arrow.up.right").accessibilityHidden(true)
            }
            .font(.system(size: layout.captionPointSize, weight: .semibold))
            .foregroundStyle(accent)
            .widgetAccentable()
        }
    }
}
