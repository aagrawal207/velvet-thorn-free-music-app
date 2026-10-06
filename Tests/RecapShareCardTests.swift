import SwiftUI
import UIKit
import XCTest
@testable import GanaBajana

/// The Recap share card renders a fixed-size picture whose layout never depends on how long a name is.
@MainActor
final class RecapShareCardTests: XCTestCase {
    private let longTitle = "Kabhi Alvida Naa Kehna (Extended Film Version with Reprise and Instrumental)"
    private let longArtist = "Shankar Ehsaan Loy featuring Shreya Ghoshal and Sonu Nigam, Arijit Singh"

    private var longContent: RecapShareCardContent {
        RecapShareCardContent(
            periodTitle: "Your last 365 days", dateRange: "Sep 26, 2025 – Sep 26, 2026",
            totalValue: "123,456", totalUnit: "minutes listened",
            songs: (1...4).map { .init(id: "LongName00\($0)", title: "\(longTitle) \($0)", artist: longArtist) },
            artists: [longArtist, "Alka Yagnik and the Extremely Long Orchestra Name", "Ed Sheeran", "Fourth artist"],
            genres: [GenreFamily.bollywood.title, GenreFamily.hindustani.title, GenreFamily.soundtrack.title],
            languages: ["Hindi", "English", "Tamil"])
    }

    func testRendersExactly1080By1350PixelsWithVisibleContentInLightAndDark() throws {
        var backgrounds: [ColorScheme: Double] = [:]
        for scheme in [ColorScheme.light, .dark] {
            let image = try XCTUnwrap(RecapShareCardRenderer.render(longContent, artwork: [:], accent: AppAccent.coral.color,
                                                                    colorScheme: scheme))
            let cgImage = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(cgImage.width, 1080)
            XCTAssertEqual(cgImage.height, 1350)
            XCTAssertEqual(image.scale, 1)
            let pixels = try XCTUnwrap(RGBAPixels(cgImage))
            // Text and tiles make the card far from a flat fill: many distinct luminance levels across the canvas.
            XCTAssertGreaterThan(pixels.distinctLuminanceLevels(step: 9), 40, "\(scheme) card must carry drawn content")
            backgrounds[scheme] = pixels.luminance(x: 1070, y: 1340)
            attach(image, name: "recap-share-card-long-names-\(scheme == .dark ? "dark" : "light")")
        }
        let light = try XCTUnwrap(backgrounds[.light]), dark = try XCTUnwrap(backgrounds[.dark])
        XCTAssertGreaterThan(light, 0.9, "The light card ends on a near-white base")
        XCTAssertLessThan(dark, 0.1, "The dark card ends on a near-black base")
    }

    func testLongNamesAreShortenedToTheCardBudgetAndListsKeepThree() {
        let content = longContent
        XCTAssertEqual(content.songs.count, 3)
        XCTAssertEqual(content.artists.count, 3)
        for song in content.songs {
            XCTAssertLessThanOrEqual(song.title.count, RecapShareCardContent.songTitleLimit)
            XCTAssertTrue(song.title.hasSuffix("…"))
            XCTAssertLessThanOrEqual(song.artist.count, RecapShareCardContent.songArtistLimit)
            XCTAssertTrue(song.artist.hasSuffix("…"))
        }
        XCTAssertLessThanOrEqual(content.artists[0].count, RecapShareCardContent.columnLimit)
        XCTAssertEqual(content.artists[2], "Ed Sheeran", "Short names stay whole")
        XCTAssertEqual(RecapShareCardContent.clipped("  Kesariya  ", limit: 30), "Kesariya")
        XCTAssertEqual(RecapShareCardContent.clipped("abcdef", limit: 4), "abc…")
        XCTAssertEqual(RecapShareCardContent.clipped("abcd", limit: 4), "abcd")
    }

    func testSummaryContentUsesTheWindowPeriodTopThreeAndClassifiedFamilies() {
        let tracks = (1...4).map { Track(id: "Track000000\($0)", title: "Song \($0)", credits: [ArtistCredit(name: "Artist \($0)")]) }
        var summary = ListeningSummary()
        summary.seconds = 5_359
        summary.topTracks = tracks.map { RankedTrack(track: $0, seconds: 100, plays: 1) }
        summary.topArtists = (1...4).map { RankedArtist(name: "Artist \($0)", seconds: 100, plays: 1) }
        var genres = ListeningGenreSummary()
        genres.rows = [GenreListeningStat(family: .pop, plays: 2, songs: 2, share: 0.6),
                       GenreListeningStat(family: .rock, plays: 1, songs: 1, share: 0.4)]
        let content = RecapShareCardContent(summary: summary, window: .month, now: Date(), genres: genres,
                                            languages: ListeningLanguageSummary())
        XCTAssertEqual(content.periodTitle, "Your last 30 days")
        XCTAssertEqual(content.totalValue, 89.formatted())
        XCTAssertEqual(content.totalUnit, "minutes listened")
        XCTAssertEqual(content.songs.map(\.title), ["Song 1", "Song 2", "Song 3"])
        XCTAssertEqual(content.artists, ["Artist 1", "Artist 2", "Artist 3"])
        XCTAssertEqual(content.genres, [GenreFamily.pop.title, GenreFamily.rock.title])
        XCTAssertTrue(content.languages.isEmpty)

        summary.seconds = 42
        let short = RecapShareCardContent(summary: summary, window: .week, now: Date(), genres: ListeningGenreSummary(),
                                          languages: ListeningLanguageSummary())
        XCTAssertEqual(short.totalUnit, "seconds listened")
        XCTAssertEqual(short.totalValue, "42")
        XCTAssertTrue(short.genres.isEmpty)
    }

    func testLoadedTopArtworkTintsTheBackgroundAndMissingArtworkDrawsThePlaceholder() throws {
        let red = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let content = longContent
        let tinted = try XCTUnwrap(RecapShareCardRenderer.render(content, artwork: [content.songs[0].id: red],
                                                                 accent: AppAccent.ocean.color, colorScheme: .dark))
        let plain = try XCTUnwrap(RecapShareCardRenderer.render(content, artwork: [:], accent: AppAccent.ocean.color,
                                                                colorScheme: .dark))
        let tintedPixels = try XCTUnwrap(tinted.cgImage.flatMap(RGBAPixels.init))
        let plainPixels = try XCTUnwrap(plain.cgImage.flatMap(RGBAPixels.init))
        let tintedTop = tintedPixels.rgb(x: 1060, y: 20), plainTop = plainPixels.rgb(x: 1060, y: 20)
        XCTAssertGreaterThan(tintedTop.red, tintedTop.blue, "The red cover's palette leads the gradient")
        XCTAssertGreaterThan(plainTop.blue, plainTop.red, "Without artwork the ocean accent leads it")
        attach(tinted, name: "recap-share-card-palette-dark")
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// Top-left origin, matching the card's layout coordinates.
    func rgb(x: Int, y: Int) -> (red: Double, green: Double, blue: Double) {
        let index = (y * width + x) * 4
        return (Double(bytes[index]) / 255, Double(bytes[index + 1]) / 255, Double(bytes[index + 2]) / 255)
    }

    func luminance(x: Int, y: Int) -> Double {
        let value = rgb(x: x, y: y)
        return 0.2126 * value.red + 0.7152 * value.green + 0.0722 * value.blue
    }

    func distinctLuminanceLevels(step: Int) -> Int {
        var levels = Set<Int>()
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) { levels.insert(Int(luminance(x: x, y: y) * 255)) }
        }
        return levels.count
    }
}
