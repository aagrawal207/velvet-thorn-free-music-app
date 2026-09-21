import SwiftUI

enum AppTypography {
    static func size(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 28
        case .title: 24
        case .title2: 20
        case .title3: 18
        case .headline, .body: 15
        case .callout, .subheadline: 14
        case .footnote: 12
        case .caption: 12
        case .caption2: 11
        @unknown default: 15
        }
    }
}

extension View {
    func appFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                 design: Font.Design = .default) -> some View {
        modifier(AppFontModifier(style: style, weight: weight, design: design))
    }
}

private struct AppFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(style: Font.TextStyle, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: AppTypography.size(for: style), relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}
