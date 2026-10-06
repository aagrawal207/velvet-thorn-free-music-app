import SwiftUI

@MainActor
struct AlbumDescriptionView: View {
    @Environment(\.secondaryTextColor) private var secondaryText
    let description: AlbumDescription
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About This Album")
                .appFont(.headline)
            Text(verbatim: description.text)
                .appFont(.subheadline)
                .foregroundStyle(secondaryText)
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(isExpanded ? description.text
                    : AlbumDescriptionIdentity.excerpt(description.text, maximumCharacters: 220).text)
                .accessibilityIdentifier("album.description.text")

            Button {
                isExpanded.toggle()
            } label: {
                Label(isExpanded ? "Show less" : "Read more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .appFont(.subheadline, weight: .semibold)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.accent)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("album.description.expand")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { sourceLink; licenseLink }
                VStack(alignment: .leading, spacing: 0) { sourceLink; licenseLink }
            }
            if description.isExcerpt {
                Text("Excerpt. Read the full description at the source.")
                    .appFont(.caption)
                    .foregroundStyle(secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("album.description")
    }

    private var sourceLink: some View {
        Link(destination: description.sourceURL) {
            Text(description.attribution)
                .appFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("album.description.source")
    }

    private var licenseLink: some View {
        Link(destination: description.licenseURL) {
            Text(description.license.title)
                .appFont(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Description license, \(description.license.title)")
        .accessibilityIdentifier("album.description.license")
    }
}
