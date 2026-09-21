import SwiftUI

struct LyricsAttributionView: View {
    let document: LyricsDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = document.sourceURL {
                Link(destination: url) {
                    Label("Lyrics · \(document.source)", systemImage: "arrow.up.right")
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityLabel("Lyrics source, \(document.source). Opens in your browser.")
            } else {
                Text("Lyrics · \(document.source)")
            }
            if let title = document.matchedTitle, let artist = document.matchedArtist {
                Text("Matched: \(title) · \(artist)").fixedSize(horizontal: false, vertical: true)
            }
        }
        .appFont(.caption)
        .foregroundStyle(AppTheme.secondaryText)
        .tint(AppTheme.accent)
    }
}
