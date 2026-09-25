import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var secondaryTextColor: Color = AppTheme.secondaryText
}

@MainActor
struct ArtworkBackdrop: View {
    let url: URL?
    let fallbackTint: Color
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var state = ArtworkBackdropState()

    var body: some View {
        ArtworkBackdropSurface(artwork: state.displayed, fallbackTint: fallbackTint, reduceMotion: reduceMotion,
                               reduceTransparency: reduceTransparency, increaseContrast: colorSchemeContrast == .increased)
            .task(id: url) {
                guard let request = state.begin(url) else { return }
                defer { state.cancel(request) }
                // Blur and palette sampling share the bounded decode already used by the backdrop.
                let loaded = await ArtworkLoader.shared.image(for: request.url, tier: .standard, maxPixels: 300)
                state.complete(loaded, for: request)
            }
            .onDisappear { state.cancel() }
    }
}

// Displayed artwork outlives its request so a slow replacement never passes through the placeholder.
@MainActor
struct ArtworkBackdropState {
    struct Artwork {
        let url: URL
        let image: UIImage
        let palette: ArtworkPalette
    }

    struct Request: Equatable {
        let url: URL
        let id = UUID()
    }

    private(set) var displayed: Artwork?
    private var pending: Request?

    mutating func begin(_ url: URL?) -> Request? {
        guard !Task.isCancelled else { return nil }
        pending = nil
        guard let url else {
            displayed = nil
            return nil
        }
        guard displayed?.url != url else { return nil }
        let request = Request(url: url)
        pending = request
        return request
    }

    @discardableResult
    mutating func complete(_ image: UIImage?, for request: Request) -> Bool {
        guard pending == request else { return false }
        pending = nil
        guard !Task.isCancelled else { return false }
        displayed = image.map { Artwork(url: request.url, image: $0, palette: ArtworkPalette.extract(from: $0) ?? .neutral) }
        return true
    }

    mutating func cancel(_ request: Request? = nil) {
        if request == nil || pending == request { pending = nil }
    }
}

@MainActor
struct ArtworkBackdropSurface: View {
    let artwork: ArtworkBackdropState.Artwork?
    let fallbackTint: Color
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.background
                if let artwork {
                    let style = ArtworkBackdropStyle(palette: artwork.palette, colorScheme: colorScheme,
                                                      reduceTransparency: reduceTransparency,
                                                      increaseContrast: increaseContrast)
                    ZStack {
                        LinearGradient(stops: style.baseStops.map { Gradient.Stop(color: $0.color.color, location: $0.location) },
                                       startPoint: .top, endPoint: .bottom)
                        if style.artworkOpacity > 0 {
                            Image(uiImage: artwork.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .saturation(style.artworkSaturation)
                                .blur(radius: 70, opaque: true)
                                // Blur feathers the edges; overscan keeps the fade outside the viewport.
                                .scaleEffect(1.3)
                                .opacity(style.artworkOpacity)
                                .blendMode(style.artworkBlend)
                        }
                        LinearGradient(stops: style.scrimStops.map {
                            Gradient.Stop(color: AppTheme.background.opacity($0.opacity), location: $0.location)
                        }, startPoint: .top, endPoint: .bottom)
                    }
                    // The blend must resolve against the tint alone, not the page behind the backdrop.
                    .compositingGroup()
                    .id(artwork.url)
                    .transition(reduceMotion ? .identity : .opacity)
                } else {
                    fallback
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: artwork?.url)
        .transaction {
            if reduceMotion {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if reduceTransparency || increaseContrast {
            fallbackTint.opacity(0.08)
        } else {
            ZStack {
                LinearGradient(colors: [fallbackTint.opacity(0.18), .clear], startPoint: .top, endPoint: .center)
                LinearGradient(colors: [AppTheme.background.opacity(0.35), AppTheme.background.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

extension ArtworkPalette {
    /// Sampling failed; the blur alone still tints the page without inventing a hue.
    static let neutral = ArtworkPalette(primary: RGB(red: 0.5, green: 0.5, blue: 0.5), secondary: RGB(red: 0.5, green: 0.5, blue: 0.5),
                                        averageLuminance: 0.5, isChromatic: false)
}
