import Foundation
import XCTest
@testable import GanaBajana

final class MusicWidgetRouteTests: XCTestCase {
    func testOpenRoutesUseExpectedURLsForAllThreeWidgetKinds() throws {
        let cases: [(MusicWidgetKind, String)] = [
            (.recentlyPlayed, "ganabajana://widget/open?kind=recentlyPlayed"),
            (.likedSongs, "ganabajana://widget/open?kind=likedSongs"),
            (.mixes, "ganabajana://widget/open?kind=mixes"),
        ]
        for (kind, raw) in cases {
            let route = MusicWidgetRoute.open(kind)
            XCTAssertEqual(route.url.absoluteString, raw)
            XCTAssertEqual(MusicWidgetRoute(url: try XCTUnwrap(URL(string: raw))), route)
            XCTAssertEqual(MusicWidgetRoute(url: route.url), route)
            XCTAssertEqual(route.source, kind)
            XCTAssertFalse(route.startsPlayback)
        }
    }

    func testTrackRoutesCaptureEitherSavedListAndTheRecordingID() throws {
        let cases: [(MusicWidgetKind, String)] = [
            (.recentlyPlayed, "ganabajana://widget/play?source=recentlyPlayed&id=AaB_c-12345"),
            (.likedSongs, "ganabajana://widget/play?source=likedSongs&id=AaB_c-12345"),
        ]
        for (source, raw) in cases {
            let route = MusicWidgetRoute.playTrack(source: source, id: "AaB_c-12345")
            XCTAssertEqual(route.url.absoluteString, raw)
            XCTAssertEqual(MusicWidgetRoute(url: try XCTUnwrap(URL(string: raw))), route)
            XCTAssertEqual(MusicWidgetRoute(url: route.url), route)
            XCTAssertEqual(route.source, source)
            XCTAssertTrue(route.startsPlayback)
        }
    }

    func testMixRoutesCaptureBothSavedPeriodsAndExplicitPlayIntent() throws {
        let cases: [(GeneratedPlaylistKind, String, Bool, String)] = [
            (.dailyMix, "2026-09-23", false, "ganabajana://widget/mix?kind=dailyMix&period=2026-09-23&play=0"),
            (.dailyMix, "2026-09-23", true, "ganabajana://widget/mix?kind=dailyMix&period=2026-09-23&play=1"),
            (.discoverWeekly, "2026-W39", false, "ganabajana://widget/mix?kind=discoverWeekly&period=2026-W39&play=0"),
            (.discoverWeekly, "2026-W39", true, "ganabajana://widget/mix?kind=discoverWeekly&period=2026-W39&play=1"),
        ]
        for (kind, period, play, raw) in cases {
            let route = MusicWidgetRoute.mix(kind: kind, periodKey: period, play: play)
            XCTAssertEqual(route.url.absoluteString, raw)
            XCTAssertEqual(MusicWidgetRoute(url: try XCTUnwrap(URL(string: raw))), route)
            XCTAssertEqual(MusicWidgetRoute(url: route.url), route)
            XCTAssertEqual(route.source, .mixes)
            XCTAssertEqual(route.startsPlayback, play)
        }
    }

    func testReservedPercentAndUnicodeValuesSurviveExactlyOneDecode() throws {
        let id = "Aa%2F/?&=#+雪é"
        let raw = "ganabajana://widget/play?source=likedSongs&id=Aa%252F%2F%3F%26%3D%23%2B%E9%9B%AA%C3%A9"
        XCTAssertEqual(MusicWidgetRoute(url: try XCTUnwrap(URL(string: raw))), .playTrack(source: .likedSongs, id: id))

        for source in [MusicWidgetKind.likedSongs, .recentlyPlayed] {
            for value in [id, "Mixed CASE + daily", "दैनिक-🎵-100%"] {
                let route = MusicWidgetRoute.playTrack(source: source, id: value)
                let items = try XCTUnwrap(URLComponents(url: route.url, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(items.count, 2, "Reserved characters must remain inside the ID")
                XCTAssertEqual(items.first { $0.name == "id" }?.value, value)
                XCTAssertEqual(MusicWidgetRoute(url: route.url), route)
            }
        }
        let mix = MusicWidgetRoute.mix(kind: .dailyMix, periodKey: "Day%2F/雪+&play=0", play: true)
        XCTAssertEqual(MusicWidgetRoute(url: mix.url), mix)
        let plus = try XCTUnwrap(URL(string: "ganabajana://widget/play?id=A+B&source=likedSongs"))
        XCTAssertEqual(MusicWidgetRoute(url: plus), .playTrack(source: .likedSongs, id: "A+B"))
    }

    func testOnlySchemeAndAuthorityAreCaseInsensitive() throws {
        let upperAuthority = try XCTUnwrap(URL(string: "GANABAJANA://WIDGET/play?id=AbC&source=likedSongs"))
        XCTAssertEqual(MusicWidgetRoute(url: upperAuthority), .playTrack(source: .likedSongs, id: "AbC"))
        XCTAssertNotEqual(MusicWidgetRoute(url: upperAuthority), .playTrack(source: .likedSongs, id: "abc"))
        let period = MusicWidgetRoute.mix(kind: .discoverWeekly, periodKey: "Week-A", play: false)
        XCTAssertEqual(MusicWidgetRoute(url: period.url), period)
        XCTAssertNotEqual(MusicWidgetRoute(url: period.url), .mix(kind: .discoverWeekly, periodKey: "week-a", play: false))
        try assertRejected([
            "ganabajana://widget/Open?kind=likedSongs",
            "ganabajana://widget/open?Kind=likedSongs",
            "ganabajana://widget/open?kind=LikedSongs",
            "ganabajana://widget/play?source=RecentlyPlayed&id=AbC",
            "ganabajana://widget/mix?kind=DailyMix&period=day&play=1",
        ])
    }

    func testDuplicateParametersIncludingEncodedNamesAreRejected() throws {
        try assertRejected([
            "ganabajana://widget/open?kind=likedSongs&kind=likedSongs",
            "ganabajana://widget/open?kind=likedSongs&%6Bind=recentlyPlayed",
            "ganabajana://widget/play?source=likedSongs&id=one&id=two",
            "ganabajana://widget/play?source=likedSongs&id=one&%69d=one",
            "ganabajana://widget/play?source=likedSongs&source=recentlyPlayed&id=one",
            "ganabajana://widget/mix?kind=dailyMix&period=day&play=0&play=1",
            "ganabajana://widget/mix?kind=dailyMix&period=day&period=other&play=1",
            "ganabajana://widget/mix?kind=dailyMix&kind=discoverWeekly&period=day&play=1",
        ])
    }

    func testUnknownMissingAndValuelessParametersAreRejectedForEveryAction() throws {
        try assertRejected([
            "ganabajana://widget/open",
            "ganabajana://widget/open?kind",
            "ganabajana://widget/open?kind=",
            "ganabajana://widget/open?kind=likedSongs&id=one",
            "ganabajana://widget/open?kind=likedSongs&=extra",
            "ganabajana://widget/play?source=likedSongs",
            "ganabajana://widget/play?id=one",
            "ganabajana://widget/play?source=likedSongs&id",
            "ganabajana://widget/play?source=likedSongs&id=one&play=1",
            "ganabajana://widget/play?kind=likedSongs&id=one",
            "ganabajana://widget/mix?kind=dailyMix&period=day",
            "ganabajana://widget/mix?kind=dailyMix&play=1",
            "ganabajana://widget/mix?period=day&play=1",
            "ganabajana://widget/mix?kind=dailyMix&period&play=1",
            "ganabajana://widget/mix?kind=dailyMix&period=day&autoplay=1",
            "ganabajana://widget/mix?kind=dailyMix&period=day&play=1&id=one",
        ])
    }

    func testUnknownKindsMixTrackSourcesAndNonBinaryPlayFlagsAreRejected() throws {
        try assertRejected([
            "ganabajana://widget/open?kind=dailyMix",
            "ganabajana://widget/open?kind=unknown",
            "ganabajana://widget/play?source=mixes&id=one",
            "ganabajana://widget/play?source=unknown&id=one",
            "ganabajana://widget/mix?kind=mixes&period=day&play=1",
            "ganabajana://widget/mix?kind=unknown&period=day&play=1",
        ] + ["true", "false", "yes", "01", "2", "-1", ""].map {
            "ganabajana://widget/mix?kind=dailyMix&period=day&play=\($0)"
        })
        XCTAssertNil(MusicWidgetRoute(url: MusicWidgetRoute.playTrack(source: .mixes, id: "one").url))
    }

    func testForeignSchemesMalformedAuthoritiesAndUnexpectedPathsAreRejected() throws {
        try assertRejected([
            "https://widget/open?kind=likedSongs",
            "otherapp://widget/open?kind=likedSongs",
            "ganabajana://search/open?kind=likedSongs",
            "ganabajana://widget.example/open?kind=likedSongs",
            "ganabajana://widget./open?kind=likedSongs",
            "ganabajana://user@widget/open?kind=likedSongs",
            "ganabajana://user:password@widget/open?kind=likedSongs",
            "ganabajana://widget:443/open?kind=likedSongs",
            "ganabajana://widget/open?kind=likedSongs#fragment",
            "ganabajana://widget/open?kind=likedSongs#",
            "ganabajana:///widget/open?kind=likedSongs",
            "ganabajana:widget/open?kind=likedSongs",
            "/open?kind=likedSongs",
            "ganabajana://widget?kind=likedSongs",
            "ganabajana://widget/?kind=likedSongs",
            "ganabajana://widget/open/?kind=likedSongs",
            "ganabajana://widget//open?kind=likedSongs",
            "ganabajana://widget/open/extra?kind=likedSongs",
            "ganabajana://widget/open%2Fextra?kind=likedSongs",
            "ganabajana://widget/../open?kind=likedSongs",
            "ganabajana://widget/unknown?kind=likedSongs",
        ])
    }

    func testIDAndPeriodBoundsMeasureUTF8BytesRatherThanCharacters() {
        for value in [String(repeating: "a", count: 256), String(repeating: "é", count: 128)] {
            let song = MusicWidgetRoute.playTrack(source: .recentlyPlayed, id: value)
            let mix = MusicWidgetRoute.mix(kind: .dailyMix, periodKey: value, play: false)
            XCTAssertEqual(MusicWidgetRoute(url: song.url), song)
            XCTAssertEqual(MusicWidgetRoute(url: mix.url), mix)
        }
        for value in [String(repeating: "a", count: 257), String(repeating: "é", count: 129)] {
            XCTAssertNil(MusicWidgetRoute(url: MusicWidgetRoute.playTrack(source: .likedSongs, id: value).url))
            XCTAssertNil(MusicWidgetRoute(url: MusicWidgetRoute.mix(kind: .discoverWeekly, periodKey: value, play: true).url))
        }
    }

    func testEmptyPaddedAndEmbeddedControlValuesAreRejected() {
        let values = ["", " ", " leading", "trailing ", "\u{00A0}padded", "padded\u{00A0}",
                      "a\u{0000}b", "a\tb", "a\nb", "a\rb", "a\u{007F}b", "a\u{0085}b"]
        for value in values {
            XCTAssertNil(MusicWidgetRoute(url: MusicWidgetRoute.playTrack(source: .likedSongs, id: value).url), value.debugDescription)
            XCTAssertNil(MusicWidgetRoute(url: MusicWidgetRoute.mix(kind: .dailyMix, periodKey: value, play: true).url), value.debugDescription)
        }
    }

    func testOversizedURLsAndExcessQueryItemsAreRejected() throws {
        let oversized = MusicWidgetRoute.playTrack(source: .likedSongs, id: String(repeating: "雪", count: 2_000)).url
        XCTAssertGreaterThan(oversized.absoluteString.utf8.count, 4_096)
        XCTAssertNil(MusicWidgetRoute(url: oversized))
        try assertRejected(["ganabajana://widget/open?kind=likedSongs&one=1&two=2&three=3"])
    }

    private func assertRejected(_ rawURLs: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for raw in rawURLs {
            let url = try XCTUnwrap(URL(string: raw), "Fixture must reach the route parser: \(raw)", file: file, line: line)
            XCTAssertNil(MusicWidgetRoute(url: url), raw, file: file, line: line)
        }
    }
}
