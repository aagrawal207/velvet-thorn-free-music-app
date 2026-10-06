import Foundation
import OSLog

enum AudioExportArtworkResolver {
    static func resolve(for track: Track, loader: ArtworkLoader = .shared) async throws -> Data? {
        try Task.checkCancellation()
        let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")
        guard let url = track.artworkURL else {
            log.info("event=export_artwork outcome=unknown")
            return nil
        }
        var attempted = Set<URL>()
        for tier in [ArtworkURL.Tier.large, .standard, .thumbnail] {
            let candidates = ArtworkURL.candidates(for: url, tier: tier)
            guard candidates.contains(where: { !attempted.contains($0) }) else { continue }
            attempted.formUnion(candidates)
            let image = await loader.image(for: url, tier: tier, maxPixels: AudioExportArtwork.maximumPixels)
            try Task.checkCancellation()
            if let image {
                let jpeg = try AudioExportArtwork.jpeg(from: image)
                log.info("event=export_artwork outcome=loaded")
                return jpeg
            }
        }
        log.notice("event=export_artwork outcome=unavailable")
        throw AudioExportError.artworkUnavailable
    }
}
