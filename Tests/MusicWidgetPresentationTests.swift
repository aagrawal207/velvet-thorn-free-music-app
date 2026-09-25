import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import GanaBajana

@MainActor
final class MusicWidgetPresentationTests: XCTestCase {
    private let canvases: [(WidgetFamily, CGSize)] = [
        (.systemSmall, CGSize(width: 141, height: 141)),
        (.systemMedium, CGSize(width: 292, height: 141)),
        (.systemLarge, CGSize(width: 292, height: 311)),
    ]

    func testRecentSmallSurfacePlaysTheFirstRecordingAndLargerSurfacesBrowse() {
        let first = libraryTestTrack("recent-first")
        let second = libraryTestTrack("recent-second")
        let snapshot = WidgetLibrarySnapshot(recentlyPlayed: [first, second], likedSongs: [libraryTestTrack("liked-only")])
        let presentation = MusicWidgetPresentation(snapshot: snapshot, kind: .recentlyPlayed)

        XCTAssertEqual(presentation.tracks, [first, second])
        XCTAssertEqual(presentation.widgetRoute(for: .systemSmall), .playTrack(source: .recentlyPlayed, id: "recent-first"))
        XCTAssertEqual(presentation.widgetRoute(for: .systemMedium), .open(.recentlyPlayed))
        XCTAssertEqual(presentation.widgetRoute(for: .systemLarge), .open(.recentlyPlayed))
        XCTAssertEqual(presentation.trackRoute(for: "recent-second"), .playTrack(source: .recentlyPlayed, id: "recent-second"))
        XCTAssertNil(presentation.trackRoute(for: "liked-only"))
        XCTAssertNil(presentation.countText, "A bounded recent preview is not a total listening count")
        XCTAssertEqual(presentation.timelineState, .ready)
    }

    func testHistoryOffHidesRetainedRecentsWithoutHidingLikedSongsOrSavedMixes() {
        let track = libraryTestTrack("retained-private-song")
        let mix = savedMix(.dailyMix, tracks: [track], period: "2026-09-23")
        let snapshot = WidgetLibrarySnapshot(historyEnabled: false, recentlyPlayed: [track], likedSongs: [track], mixes: [mix])
        let recent = MusicWidgetPresentation(snapshot: snapshot, kind: .recentlyPlayed)

        XCTAssertTrue(recent.tracks.isEmpty)
        XCTAssertEqual(recent.emptyState, .historyOff)
        XCTAssertEqual(recent.timelineState, .empty)
        XCTAssertEqual(recent.widgetRoute(for: .systemSmall), .open(.recentlyPlayed))
        XCTAssertNil(recent.trackRoute(for: track.id))
        XCTAssertFalse(recent.smallAccessibilityLabel.contains(track.title))
        XCTAssertFalse(recent.smallAccessibilityLabel.contains(track.artistName))
        XCTAssertEqual(MusicWidgetPresentation(snapshot: snapshot, kind: .likedSongs).tracks, [track])
        XCTAssertEqual(MusicWidgetPresentation(snapshot: snapshot, kind: .mixes).selectedMix, mix)
    }

    func testNeedsAppAndUnavailableStatesCannotExposeRetainedPersonalContent() {
        let track = libraryTestTrack("private-recording", artist: "Private credit")
        var snapshot = WidgetLibrarySnapshot(recentlyPlayed: [track], likedSongs: [track], likedSongCount: 81,
                                             mixes: [savedMix(.dailyMix, tracks: [track], period: "2026-09-23")])
        for availability in [WidgetLibrarySnapshot.Availability.needsApp, .unavailable] {
            snapshot.availability = availability
            for kind in MusicWidgetKind.allCases {
                let presentation = MusicWidgetPresentation(snapshot: snapshot, kind: kind)
                XCTAssertTrue(presentation.tracks.isEmpty)
                XCTAssertNil(presentation.selectedMix)
                XCTAssertNil(presentation.songCount)
                XCTAssertNil(presentation.playMixRoute)
                XCTAssertNil(presentation.trackRoute(for: track.id))
                XCTAssertEqual(presentation.widgetRoute(for: .systemSmall), .open(kind))
                XCTAssertEqual(presentation.browseRoute, .open(kind))
                XCTAssertEqual(presentation.timelineState, availability == .unavailable ? .unavailable : .empty)
                XCTAssertFalse(presentation.smallAccessibilityLabel.contains(track.title))
                XCTAssertFalse(presentation.smallAccessibilityLabel.contains(track.artistName))
            }
        }
    }

    func testLikedCountComesFromTheCollectionInsteadOfTheSixSongPreview() {
        let tracks = (1...6).map { libraryTestTrack("liked-\($0)") }
        let presentation = MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(likedSongs: tracks, likedSongCount: 81), kind: .likedSongs)
        XCTAssertEqual(presentation.tracks, tracks)
        XCTAssertEqual(presentation.songCount, 81)
        XCTAssertEqual(presentation.countText, "81 songs")
        XCTAssertEqual(presentation.widgetRoute(for: .systemSmall), .playTrack(source: .likedSongs, id: "liked-1"))
        XCTAssertEqual(presentation.browseRoute, .open(.likedSongs))
    }

    func testMissingOrInconsistentCountsAreOmitted() {
        let tracks = [libraryTestTrack("first"), libraryTestTrack("second")]
        for count in [0, -1, 1] {
            let snapshot = WidgetLibrarySnapshot(likedSongs: tracks, likedSongCount: count)
            XCTAssertNil(MusicWidgetPresentation(snapshot: snapshot, kind: .likedSongs).countText)
        }
        let mix = savedMix(.dailyMix, tracks: tracks, period: "2026-09-23")
        let snapshot = WidgetLibrarySnapshot(mixes: [mix], mixSongCounts: [:])
        XCTAssertNil(MusicWidgetPresentation(snapshot: snapshot, kind: .mixes).countText)

        let missingPreview = MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(likedSongCount: 12), kind: .likedSongs)
        XCTAssertEqual(missingPreview.emptyState, .likedPreviewUnavailable)
        XCTAssertEqual(missingPreview.browseRoute, .open(.likedSongs))
        XCTAssertEqual(missingPreview.widgetRoute(for: .systemSmall), .open(.likedSongs))
    }

    func testMixPreferenceKeepsTheSavedPeriodForBothOpenAndPlay() {
        let daily = savedMix(.dailyMix, tracks: [libraryTestTrack("daily-song")], period: "2026-09-23")
        let weekly = savedMix(.discoverWeekly, tracks: [libraryTestTrack("weekly-song")], period: "2026-W39")
        let snapshot = WidgetLibrarySnapshot(mixes: [weekly, daily], mixSongCounts: [daily.id: 31, weekly.id: 62])
        for (mix, expectedCount) in [(daily, 31), (weekly, 62)] {
            let presentation = MusicWidgetPresentation(snapshot: snapshot, kind: .mixes, mixKind: mix.kind)
            let open = MusicWidgetRoute.mix(kind: mix.kind, periodKey: mix.periodKey, play: false)
            let play = MusicWidgetRoute.mix(kind: mix.kind, periodKey: mix.periodKey, play: true)
            XCTAssertEqual(presentation.selectedMix, mix)
            XCTAssertEqual(presentation.tracks, mix.tracks)
            XCTAssertEqual(presentation.songCount, expectedCount)
            XCTAssertEqual(presentation.browseRoute, open)
            XCTAssertEqual(presentation.playMixRoute, play)
            XCTAssertEqual(MusicWidgetRoute(url: open.url), open)
            XCTAssertEqual(MusicWidgetRoute(url: play.url), play)
            for (family, _) in canvases {
                XCTAssertEqual(presentation.widgetRoute(for: family), open)
            }
            XCTAssertNil(presentation.trackRoute(for: mix.tracks[0].id), "Mix song taps need a period-aware route contract")
        }
    }

    func testMissingChosenMixDoesNotSubstituteTheOtherPreferenceOrOfferPlayback() {
        let weekly = savedMix(.discoverWeekly, tracks: [libraryTestTrack("weekly-song")], period: "2026-W39")
        let snapshot = WidgetLibrarySnapshot(mixes: [weekly])
        let daily = MusicWidgetPresentation(snapshot: snapshot, kind: .mixes)
        XCTAssertEqual(daily.heading, "Daily Mix")
        XCTAssertEqual(daily.emptyState, .noMix)
        XCTAssertTrue(daily.tracks.isEmpty)
        XCTAssertNil(daily.playMixRoute)
        XCTAssertNil(daily.countText)
        XCTAssertEqual(daily.widgetRoute(for: .systemSmall), .open(.mixes))

        let invalid = savedMix(.dailyMix, tracks: [libraryTestTrack()], period: "   ")
        XCTAssertNil(MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(mixes: [invalid]), kind: .mixes).playMixRoute)
        let empty = savedMix(.dailyMix, tracks: [], period: "2026-09-23")
        XCTAssertNil(MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(mixes: [empty]), kind: .mixes).playMixRoute)
    }

    func testEmptyCollectionsRemainActionableWithoutInventedSongsOrCounts() {
        let expectations: [(MusicWidgetKind, MusicWidgetPresentation.EmptyState)] = [
            (.recentlyPlayed, .noRecentSongs), (.likedSongs, .noLikedSongs), (.mixes, .noMix),
        ]
        for (kind, expected) in expectations {
            let presentation = MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(), kind: kind)
            XCTAssertEqual(presentation.emptyState, expected)
            XCTAssertEqual(presentation.timelineState, .empty)
            XCTAssertTrue(presentation.tracks.isEmpty)
            XCTAssertNil(presentation.countText)
            XCTAssertEqual(presentation.browseRoute, .open(kind))
        }
        XCTAssertEqual(MusicWidgetPresentation(snapshot: .empty, kind: .likedSongs).emptyState, .needsApp)
    }

    func testSmallAccessibilityLabelKeepsFullTitlesOrderedCreditsAndExplicitStatus() {
        let title = "A very long recording title / एक लंबा गीत नाम with a featured performance"
        let track = Track(id: "long-title", title: title,
                          credits: [ArtistCredit(name: "First credited singer"), ArtistCredit(name: "Second credited singer")],
                          isExplicit: true)
        let presentation = MusicWidgetPresentation(snapshot: WidgetLibrarySnapshot(likedSongs: [track]), kind: .likedSongs)
        XCTAssertEqual(presentation.smallAccessibilityLabel,
                       "Liked songs. Play \(title), First credited singer, Second credited singer. Explicit")
    }

    func testRowAndMixBudgetsFitSmallPhoneAndIPadCanvasesWithLargeType() {
        let sizes = canvases + [
            (.systemSmall, CGSize(width: 170, height: 170)),
            (.systemMedium, CGSize(width: 360, height: 170)),
            (.systemLarge, CGSize(width: 360, height: 379)),
            (.systemMedium, CGSize(width: 440, height: 210)),
            (.systemLarge, CGSize(width: 440, height: 440)),
        ]
        let typeSizes: [(DynamicTypeSize, CGFloat, CGFloat)] = [(.large, 14, 11), (.xxxLarge, 20, 16), (.accessibility5, 46, 35)]
        for (family, size) in sizes {
            for (typeSize, titleSize, captionSize) in typeSizes {
                let layout = MusicWidgetLayout(size: size, family: family, dynamicTypeSize: typeSize,
                                               scaledTitle: titleSize, scaledCaption: captionSize)
                let captionLine = ceil(UIFont.systemFont(ofSize: layout.captionPointSize).lineHeight)
                XCTAssertGreaterThanOrEqual(layout.contentSize.width, 44)
                XCTAssertGreaterThanOrEqual(layout.contentSize.height, 44)
                if family == .systemSmall {
                    let titleLine = ceil(UIFont.systemFont(ofSize: layout.titlePointSize).lineHeight)
                    let gaps: CGFloat = layout.smallArtworkSide > 0 ? 10 : 6
                    let occupied = layout.smallHeaderHeight + layout.smallArtworkSide
                        + titleLine * CGFloat(layout.smallTitleLineLimit) + captionLine + gaps
                    XCTAssertLessThanOrEqual(occupied, layout.contentSize.height + 1e-6, "\(size), \(typeSize)")
                } else {
                    XCTAssertGreaterThanOrEqual(layout.headerHeight, 44)
                    XCTAssertGreaterThanOrEqual(layout.rowHeight, 44)
                    XCTAssertTrue((1...6).contains(layout.maximumTrackRows))
                    let occupied = layout.headerHeight + CGFloat(layout.maximumTrackRows) * (layout.rowHeight + layout.spacing)
                    XCTAssertLessThanOrEqual(occupied, layout.contentSize.height + 1e-6, "\(size), \(typeSize)")
                    if family == .systemMedium {
                        XCTAssertGreaterThanOrEqual(layout.mixHeaderHeight, 44)
                        XCTAssertGreaterThanOrEqual(layout.contentSize.width - layout.mixArtworkSide - layout.columnSpacing, 44)
                        let controls = layout.mixHeaderHeight + MusicWidgetLayout.minimumActionHeight
                            + (layout.mixShowsCount ? captionLine + 8 : 4)
                        XCTAssertLessThanOrEqual(controls, layout.contentSize.height + 1e-6)
                    } else {
                        let occupiedMix = layout.headerHeight + layout.mixArtworkSide + MusicWidgetLayout.minimumActionHeight
                            + (layout.mixShowsCount ? captionLine + 24 : 16)
                        XCTAssertLessThanOrEqual(occupiedMix, layout.contentSize.height + 1e-6)
                    }
                }
                let emptyTitle = ceil(UIFont.systemFont(ofSize: layout.emptyTitlePointSize).lineHeight)
                let emptyOccupied = layout.emptyHeaderHeight + emptyTitle * CGFloat(layout.emptyTitleLineLimit)
                    + captionLine * CGFloat(layout.emptyMessageLineLimit + 1) + (layout.emptyMessageLineLimit > 0 ? 12 : 8)
                XCTAssertLessThanOrEqual(emptyOccupied, layout.contentSize.height + 1e-6, "empty \(size), \(typeSize)")
            }
        }
    }

    func testAccessibilityLayoutTradesArtworkAndRowsForText() {
        let small = MusicWidgetLayout(size: canvases[0].1, family: .systemSmall, dynamicTypeSize: .accessibility5,
                                      scaledTitle: 46, scaledCaption: 35)
        XCTAssertEqual(small.smallArtworkSide, 0)
        XCTAssertGreaterThan(small.titlePointSize, 14)
        XCTAssertGreaterThan(small.captionPointSize, 11)
        let normal = MusicWidgetLayout(size: canvases[2].1, family: .systemLarge, dynamicTypeSize: .large)
        let large = MusicWidgetLayout(size: canvases[2].1, family: .systemLarge, dynamicTypeSize: .accessibility5,
                                      scaledTitle: 46, scaledCaption: 35)
        XCTAssertLessThan(large.maximumTrackRows, normal.maximumTrackRows)
        XCTAssertEqual(large.rowTitleLineLimit, 2)
    }

    func testRenderingUsesOnlyArtworkForTheDisplayedRecordingID() throws {
        let track = libraryTestTrack("displayed-recording")
        let data = WidgetSnapshotTestData.jpeg(color: UIColor(red: 33 / 255, green: 160 / 255, blue: 1, alpha: 1))
        let baseline = WidgetLibrarySnapshot(recentlyPlayed: [track])
        var matching = baseline
        matching.artwork = [track.id: data]
        var unrelated = baseline
        unrelated.artwork = ["another-recording": data]
        for (family, size) in canvases {
            let absentPixels = try pixels(render(baseline, kind: .recentlyPlayed, family: family, size: size))
            let matchingPixels = try pixels(render(matching, kind: .recentlyPlayed, family: family, size: size))
            let unrelatedPixels = try pixels(render(unrelated, kind: .recentlyPlayed, family: family, size: size))
            XCTAssertGreaterThan(countPixels(matchingPixels, near: (33, 160, 255)), 500, "\(family)")
            XCTAssertEqual(absentPixels, unrelatedPixels, "Unrelated artwork must not be substituted")
            XCTAssertNotEqual(absentPixels, matchingPixels)
        }
    }

    func testMalformedArtworkAndRemoteArtworkURLsRenderTheLocalPlaceholder() throws {
        var snapshot = WidgetSnapshotTestData.snapshot()
        let original = try pixels(render(snapshot, kind: .likedSongs, family: .systemMedium, size: canvases[1].1))
        snapshot.likedSongs[0].artworkURL = URL(string: "https://widget-artwork.invalid/never-fetch.jpg")
        snapshot.artwork[snapshot.likedSongs[0].id] = Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])
        let malformed = try pixels(render(snapshot, kind: .likedSongs, family: .systemMedium, size: canvases[1].1))
        XCTAssertEqual(original, malformed)
    }

    func testRenderingHonorsTheSelectedMixInEveryFamily() throws {
        let daily = savedMix(.dailyMix, tracks: [libraryTestTrack("daily")], period: "2026-09-23")
        let weekly = savedMix(.discoverWeekly, tracks: [libraryTestTrack("weekly")], period: "2026-W39")
        let snapshot = WidgetLibrarySnapshot(mixes: [daily, weekly], artwork: [
            "daily": WidgetSnapshotTestData.jpeg(color: UIColor(red: 33 / 255, green: 160 / 255, blue: 1, alpha: 1)),
            "weekly": WidgetSnapshotTestData.jpeg(color: UIColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)),
        ])
        for (family, size) in canvases {
            let dailyPixels = try pixels(render(snapshot, kind: .mixes, family: family, size: size, mixKind: .dailyMix))
            let weeklyPixels = try pixels(render(snapshot, kind: .mixes, family: family, size: size, mixKind: .discoverWeekly))
            XCTAssertGreaterThan(countPixels(dailyPixels, near: (33, 160, 255)), 500)
            XCTAssertEqual(countPixels(dailyPixels, near: (26, 204, 51)), 0)
            XCTAssertGreaterThan(countPixels(weeklyPixels, near: (26, 204, 51)), 500)
            XCTAssertEqual(countPixels(weeklyPixels, near: (33, 160, 255)), 0)
        }
    }

    func testHistoryOffRenderingContainsNoRetainedSongTextOrImagesInAnyAppearance() throws {
        var retained = WidgetSnapshotTestData.snapshot("private-recording")
        retained.historyEnabled = false
        retained.artwork = ["private-recording": WidgetSnapshotTestData.jpeg()]
        var removed = retained
        removed.recentlyPlayed = []
        removed.artwork = [:]
        for (family, size) in canvases {
            for scheme in [ColorScheme.light, .dark] {
                for mode in [WidgetRenderingMode.fullColor, .accented, .vibrant] {
                    let before = try pixels(render(retained, kind: .recentlyPlayed, family: family, size: size, mode: mode, scheme: scheme))
                    let after = try pixels(render(removed, kind: .recentlyPlayed, family: family, size: size, mode: mode, scheme: scheme))
                    XCTAssertEqual(before, after, "\(family), \(scheme), \(mode)")
                }
            }
        }
    }

    func testUnavailableRenderingContainsNoRetainedCollectionContent() throws {
        let track = libraryTestTrack("private-recording")
        let retained = WidgetLibrarySnapshot(availability: .unavailable, recentlyPlayed: [track], likedSongs: [track],
                                             mixes: [savedMix(.dailyMix, tracks: [track], period: "2026-09-23")],
                                             artwork: [track.id: WidgetSnapshotTestData.jpeg()])
        for kind in MusicWidgetKind.allCases {
            let before = try pixels(render(retained, kind: kind, family: .systemMedium, size: canvases[1].1, typeSize: .accessibility5))
            let after = try pixels(render(.unavailable, kind: kind, family: .systemMedium, size: canvases[1].1, typeSize: .accessibility5))
            XCTAssertEqual(before, after)
        }
    }

    private func savedMix(_ kind: GeneratedPlaylistKind, tracks: [Track], period: String) -> GeneratedPlaylist {
        GeneratedPlaylist(kind: kind, tracks: tracks, generatedAt: RecommendationFixtures.now, periodKey: period, seedArtists: [])
    }

    private func render(_ snapshot: WidgetLibrarySnapshot, kind: MusicWidgetKind, family: WidgetFamily, size: CGSize,
                        mixKind: GeneratedPlaylistKind = .dailyMix, mode: WidgetRenderingMode = .fullColor,
                        scheme: ColorScheme = .light, typeSize: DynamicTypeSize = .large) throws -> CGImage {
        let content = MusicWidgetView(snapshot: snapshot, kind: kind, mixKind: mixKind)
            .environment(\.musicWidgetPreviewFamily, family)
            .environment(\.widgetRenderingMode, mode)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .frame(width: size.width, height: size.height)
            .background(AppTheme.surface)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
            image = renderer.cgImage
        }
        return try XCTUnwrap(image)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    private func countPixels(_ pixels: [UInt8], near rgb: (Int, Int, Int)) -> Int {
        stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, index in
            let matches = abs(Int(pixels[index]) - rgb.0) <= 8 && abs(Int(pixels[index + 1]) - rgb.1) <= 8
                && abs(Int(pixels[index + 2]) - rgb.2) <= 8 && pixels[index + 3] == 255
            return count + (matches ? 1 : 0)
        }
    }
}

extension WidgetSnapshotTestData {
    @MainActor
    fileprivate static func jpeg(color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
    }
}
