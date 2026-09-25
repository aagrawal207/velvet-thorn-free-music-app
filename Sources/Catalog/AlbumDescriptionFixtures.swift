#if DEBUG
import Foundation

extension DebugMusicFixtures: AlbumDescriptionProviding {
    func albumDescription(id: String) async throws -> AlbumDescription? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting"), arguments.contains("--seed-ui"),
              arguments.contains("--album-description-fixture"), id == Self.albumID else { return nil }
        return try await DebugAlbumDescriptionControl.shared.description(id: id)
    }
}

private actor DebugAlbumDescriptionControl {
    static let shared = DebugAlbumDescriptionControl()
    private var hasFailed = false

    func description(id: String) async throws -> AlbumDescription? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--album-description-slow") { try await Task.sleep(for: .seconds(4)) }
        if arguments.contains("--album-description-fail-once"), !hasFailed {
            hasFailed = true
            throw MusicServiceError.network("Synthetic album-description failure")
        }
        if arguments.contains("--album-description-empty") { return nil }
        return AlbumDescription(albumID: id, albumTitle: "Evening favorites", credits: [DebugMusicFixtures.arijitSingh],
            text: """
            Synthetic album-description fixture. This text exercises the collapsed preview while the album's songs remain playable. The source and license links stay visible beside the description controls.

            This second paragraph is fixture text for the expanded state. It is deliberately long enough to change the description's height, so the UI workflow can verify that Read more and Show less change the visible content. It makes no claims about a real album or artist.
            """,
            sourceURL: URL(string: "https://en.wikipedia.org/wiki/Album")!, license: .ccBYSA3,
            licenseURL: URL(string: "https://creativecommons.org/licenses/by-sa/3.0/legalcode")!, isExcerpt: false)
    }
}
#endif
