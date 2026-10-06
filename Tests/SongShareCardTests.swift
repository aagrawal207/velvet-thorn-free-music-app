import SwiftUI
import XCTest
@testable import GanaBajana

@MainActor
final class SongShareCardTests: XCTestCase {
    private let track = Track(id: "abcdefghijk", title: "Tum Hi Ho", credits: [ArtistCredit(name: "Arijit Singh")],
                              albumTitle: "Aashiqui 2", duration: 262)

    func testContentUsesTrackFactsAndDetailsWhenKnown() throws {
        let plain = SongShareCardContent(track: track)
        XCTAssertEqual(plain.title, "Tum Hi Ho")
        XCTAssertEqual(plain.artists, "Arijit Singh")
        XCTAssertEqual(plain.releaseLine, "Aashiqui 2")
        XCTAssertEqual(plain.metaLine, "4:22 · YouTube Music")
        XCTAssertEqual(plain.listenLine, "Listen on YouTube Music")
        XCTAssertEqual(plain.appName, "Velvet Thorn")
        XCTAssertEqual(plain.url?.absoluteString, "https://music.youtube.com/watch?v=abcdefghijk")

        var details = TrackDetails(track: track)
        details.albumTitle = "Aashiqui 2 (Original Motion Picture Soundtrack)"
        details.releaseDateText = "2013-04-01"
        let detailed = SongShareCardContent(track: track, details: details)
        XCTAssertEqual(detailed.releaseLine, "Aashiqui 2 (Original Motion Picture Soundtrack) · 2013")

        details.releaseDateText = "unknown"
        XCTAssertNil(SongShareCardContent(track: track, details: details).year)

        let saavn = SongShareCardContent(track: Track(id: "saavn:xyz", title: "Kesariya", duration: nil))
        XCTAssertEqual(saavn.listenLine, "Listen on JioSaavn")
        XCTAssertEqual(saavn.metaLine, "JioSaavn")
        XCTAssertNil(saavn.releaseLine)
        XCTAssertEqual(SongShareCardContent(track: Track(id: "gaana:1", title: "Song")).listenLine, "Listen on Gaana")
    }

    func testCardRendersAtTheFixedSizeInLightAndDark() throws {
        let content = SongShareCardContent(track: track)
        let light = try XCTUnwrap(SongShareCardRenderer.render(content, artwork: nil, colorScheme: .light))
        let dark = try XCTUnwrap(SongShareCardRenderer.render(content, artwork: nil, colorScheme: .dark))
        for image in [light, dark] {
            XCTAssertEqual(image.size, SongShareCard.size)
            XCTAssertEqual(image.scale, 1)
        }
        // Bottom-left corner is plain background: near white in light, near black in dark.
        let lightCorner = try luminance(light, at: CGPoint(x: 8, y: 1340))
        let darkCorner = try luminance(dark, at: CGPoint(x: 8, y: 1340))
        XCTAssertGreaterThan(lightCorner, 0.8)
        XCTAssertLessThan(darkCorner, 0.15)
        attach(light, "song-share-card-light")
        attach(dark, "song-share-card-dark")
    }

    func testCardDrawsTheListenersAccentRatherThanTheSystemTint() throws {
        let image = try XCTUnwrap(SongShareCardRenderer.render(SongShareCardContent(track: track), artwork: nil,
                                                               colorScheme: .dark, accent: Color(red: 1, green: 0, blue: 0)))
        // The play glyph sits at the start of the footer row, 72 points in from the left and bottom edges.
        let samples = try (0..<30).flatMap { dx in try (0..<30).map { dy in try rgb(image, at: CGPoint(x: 74 + dx, y: 1246 + dy)) } }
        XCTAssertTrue(samples.contains { $0.red > 0.8 && $0.green < 0.25 && $0.blue < 0.25 }, "The footer glyph uses the passed accent")
        XCTAssertFalse(samples.contains { $0.blue > 0.8 && $0.red < 0.3 }, "No system blue tint")
    }

    func testLongNamesTruncateInsideTheCard() throws {
        let long = Track(id: "abcdefghijk",
                         title: String(repeating: "A very long song title that keeps going ", count: 6),
                         credits: (0..<12).map { ArtistCredit(name: "Artist number \($0)") },
                         albumTitle: String(repeating: "Endless album name ", count: 8), duration: 5_000)
        let content = SongShareCardContent(track: long)
        let image = try XCTUnwrap(SongShareCardRenderer.render(content, artwork: nil, colorScheme: .dark))
        XCTAssertEqual(image.size, SongShareCard.size, "Long text never grows the card")
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        let withArtwork = try XCTUnwrap(SongShareCardRenderer.render(content, artwork: artwork, colorScheme: .light))
        XCTAssertEqual(withArtwork.size, SongShareCard.size)
        attach(image, "song-share-card-long-dark")
        attach(withArtwork, "song-share-card-long-light-artwork")
    }

    func testDetailsLookupGivesUpAtTheDeadline() async {
        let slow = SlowDetailsProvider()
        let started = ContinuousClock.now
        let result = await SongShareCardRenderer.details(from: slow, for: track, deadline: .milliseconds(200))
        XCTAssertNil(result)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let fast = await SongShareCardRenderer.details(from: FastDetailsProvider(), for: track)
        XCTAssertEqual(fast?.albumTitle, "From cache")
    }

    // MARK: - Helpers

    private func luminance(_ image: UIImage, at point: CGPoint) throws -> Double {
        let color = try rgb(image, at: point)
        return 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
    }

    private func rgb(_ image: UIImage, at point: CGPoint) throws -> (red: Double, green: Double, blue: Double) {
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: -point.x, y: -(CGFloat(cgImage.height) - point.y), width: CGFloat(cgImage.width),
                                         height: CGFloat(cgImage.height)))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["WP25_CAPTURE_DIR"], let data = image.pngData() {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

private struct SlowDetailsProvider: TrackDetailsProviding {
    func details(for track: Track, refresh: Bool) async -> TrackDetails? {
        try? await Task.sleep(for: .seconds(10))
        return TrackDetails(track: track)
    }
}

private struct FastDetailsProvider: TrackDetailsProviding {
    func details(for track: Track, refresh: Bool) async -> TrackDetails? {
        var details = TrackDetails(track: track)
        details.albumTitle = "From cache"
        return details
    }
}
