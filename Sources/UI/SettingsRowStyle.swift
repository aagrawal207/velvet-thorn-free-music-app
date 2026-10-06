import SwiftUI

/// The one Settings row shape: a decorative 28-point symbol tile, a body title and a trailing value or control,
/// at least 44 points tall. Explanations live in section footers, never inside a row.
enum SettingsRowMetrics {
    static let iconSize: CGFloat = 28
    static let iconCornerRadius: CGFloat = 7
    static let iconSymbolSize: CGFloat = 15
    static let iconSpacing: CGFloat = 12
    /// Where titles start and where stacked values align at accessibility sizes.
    static let textInset = iconSize + iconSpacing
    static let minHeight: CGFloat = 44
    static let trailingSpacing: CGFloat = 12
    static let stackedSpacing: CGFloat = 4
    static let footerSpacing: CGFloat = 6
    /// The system lays a footer's first line on the card's bottom edge; this is the gap to the last row.
    static let footerTopSpacing: CGFloat = 10
    /// Measured on iOS 26.5: the system default leaves no gap between a footer and the next header, so one
    /// explicit value keeps header, card and footer rhythm identical whether or not a section has a footer.
    static let sectionSpacing: CGFloat = 24
    static let insets = EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
}

/// Rounded tile with a fixed-size glyph so wide and narrow symbols carry the same visual weight.
struct SettingsRowIcon: View {
    let systemImage: String
    var tint: Color = AppTheme.accent

    var body: some View {
        RoundedRectangle(cornerRadius: SettingsRowMetrics.iconCornerRadius, style: .continuous)
            .fill(tint.opacity(0.16))
            .frame(width: SettingsRowMetrics.iconSize, height: SettingsRowMetrics.iconSize)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: SettingsRowMetrics.iconSymbolSize, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)
    }
}

struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SettingsRowMetrics.iconSpacing) {
            // Decorative glyphs keep a fixed column so large text retains the available row width.
            configuration.icon
                .frame(width: SettingsRowMetrics.iconSize, height: SettingsRowMetrics.iconSize)
                .accessibilityHidden(true)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Title with a symbol tile in the icon column.
struct SettingsRowLabel: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = AppTheme.accent

    var body: some View {
        Label {
            if let subtitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .appFont(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                Text(title)
            }
        } icon: {
            SettingsRowIcon(systemImage: systemImage, tint: tint)
        }
        .labelStyle(SettingsRowLabelStyle())
    }
}

/// Title leading and a trailing value or control; accessibility sizes stack the trailing content under the title.
struct SettingsRowContent<Label: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let label: Label
    private let trailing: Trailing

    init(@ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing) {
        self.label = label()
        self.trailing = trailing()
    }

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: SettingsRowMetrics.stackedSpacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: SettingsRowMetrics.trailingSpacing))
        layout {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .padding(.leading, stacked ? SettingsRowMetrics.textInset : 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
    }
}

/// Secondary value text for menu, navigation and information rows.
struct SettingsRowValue: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !text.isEmpty {
                Text(text)
                    .multilineTextAlignment(.trailing)
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .appFont(.caption)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(AppTheme.secondaryText)
    }
}

/// Native menu picker in the row shape: the current value sits trailing with the up/down chevron.
/// Pages without an icon column (Storage) pass no symbol and get a plain title.
struct SettingsMenuRow<Selection: Hashable, Choices: View>: View {
    let title: String
    var systemImage: String?
    @Binding var selection: Selection
    let value: String
    let id: String
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        Menu {
            Picker(title, selection: $selection) { choices() }
        } label: {
            SettingsRowContent {
                if let systemImage {
                    SettingsRowLabel(title: title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            } trailing: {
                SettingsRowValue(text: value, systemImage: "chevron.up.chevron.down")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(id)
    }
}

/// Section header in the shared caption style; the identifier is a contract other tests rely on.
struct SettingsSectionHeader: View {
    let title: String
    let id: String

    var body: some View {
        Text(title)
            .appFont(.caption, weight: .semibold)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 24, alignment: .leading)
            .accessibilityIdentifier(id)
    }
}

/// Footer paragraphs in one style. Each `Text` keeps its own identifier so tests can read a specific note.
struct SettingsFooter<Content: View>: View {
    let id: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsRowMetrics.footerSpacing) {
            content()
        }
        .appFont(.footnote)
        .foregroundStyle(AppTheme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        // Outside the container so the footer's frame starts at its first line, which is what tests measure.
        .padding(.top, SettingsRowMetrics.footerTopSpacing)
    }
}

extension View {
    /// Shared form chrome: body font, 44-point rows, system inset-grouped section spacing and the page colours.
    func settingsFormChrome() -> some View {
        appFont(.body)
            .environment(\.defaultMinListRowHeight, SettingsRowMetrics.minHeight)
            .listRowSpacing(0)
            .listSectionSpacing(SettingsRowMetrics.sectionSpacing)
            .appAccentChrome()
            .foregroundStyle(AppTheme.primaryText)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
    }

    /// Row surface and horizontal insets for a Settings section.
    func settingsSectionRows() -> some View {
        listRowBackground(AppTheme.surface)
            .listRowInsets(SettingsRowMetrics.insets)
    }

    /// A full-width tappable row body for buttons and links.
    func settingsRowTarget() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: SettingsRowMetrics.minHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}
