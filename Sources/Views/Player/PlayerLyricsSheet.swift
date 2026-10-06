import SwiftUI

@MainActor
struct PlayerLyricsSheet: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let track = model.player.currentTrack {
                    VStack(spacing: 0) {
                        TVLyricsStartButton(controller: model.tvLyrics) { model.prepareTVLyrics() }
                            .padding(.horizontal, 20)
                        LyricsView(track: track, loader: model.lyricsSelection,
                                   recordingLanguage: model.library.recordingLanguageOverrides[track.id],
                                   requestLoad: { model.loadSelectedLyrics(for: $0, recordingLanguage: $1) })
                            .id(track.id)
                    }
                } else {
                    EmptyStateView(symbol: "quote.bubble", title: "Choose a song first",
                                   message: "Lyrics follow the song in your player.")
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "lyrics.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
        .tvLyricsPresentation(controller: model.tvLyrics)
    }
}
