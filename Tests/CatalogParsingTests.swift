import XCTest
@testable import GanaBajana

final class CatalogParsingTests: XCTestCase {
    func testSongMetadataUsesNavigationRatherThanPlayCountColumn() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(title: "तुम ही हो", explicit: true), CatalogFixtures.song(),
            CatalogFixtures.song(id: "not-video", title: "Invalid"), CatalogFixtures.song(id: "FOA9iyxsW_A", title: "  "),
        ], continuation: "next+/%3D"))
        let page = try CatalogParser.search(root, filter: .songs)
        XCTAssertEqual(page.tracks.count, 1)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.title, "तुम ही हो")
        XCTAssertEqual(track.artists, ["Arijit Singh"])
        XCTAssertEqual(track.artistID, CatalogFixtures.arijitID)
        XCTAssertEqual(track.albumTitle, "Aashiqui 2")
        XCTAssertEqual(track.albumID, CatalogFixtures.albumID)
        XCTAssertEqual(track.duration, 262)
        XCTAssertEqual(track.artworkURL?.lastPathComponent, "hqdefault.jpg")
        XCTAssertTrue(track.isExplicit)
        XCTAssertEqual(track.isAudioRecording, true)
        XCTAssertNil(track.language)
        XCTAssertEqual(track.playCount, 1_200_000_000)
        XCTAssertEqual(page.continuation, "next+/%3D")
    }

    func testSongRowCreditsEveryLinkedArtistWithItsOwnID() throws {
        let credited: [(name: String, id: String)] = [
            ("Pritam", CatalogFixtures.pritamID), ("Shashwat Singh", CatalogFixtures.shashwatID),
            ("Antara Mitra", CatalogFixtures.antaraID), ("Arijit Singh", CatalogFixtures.arijitID),
        ]
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya", artists: credited, album: "Brahmastra", duration: "4:28"),
            CatalogFixtures.song(id: "wx89ZdkwtS8", title: "Duet", artists: [("Arijit Singh", CatalogFixtures.arijitID), ("ARIJIT SINGH", CatalogFixtures.arijitID)]),
        ]))
        let page = try CatalogParser.search(root, filter: .songs)
        let track = try XCTUnwrap(page.tracks.first)
        XCTAssertEqual(track.credits.map(\.name), ["Pritam", "Shashwat Singh", "Antara Mitra", "Arijit Singh"])
        XCTAssertEqual(track.credits.map(\.id), [CatalogFixtures.pritamID, CatalogFixtures.shashwatID, CatalogFixtures.antaraID, CatalogFixtures.arijitID],
                       "Each byline run keeps its own browseId, not just the first")
        XCTAssertEqual(track.artistID, CatalogFixtures.pritamID, "The primary artist stays the first credit")
        XCTAssertEqual(track.artistName, "Pritam, Shashwat Singh, Antara Mitra, Arijit Singh")
        XCTAssertEqual(track.artistCollection?.id, CatalogFixtures.pritamID)
        XCTAssertEqual(track.albumTitle, "Brahmastra")
        XCTAssertEqual(track.duration, 268, "Separator runs never become durations or artists")
        XCTAssertEqual(page.tracks.last?.credits, [ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID)],
                       "Repeated names are one credit, case-insensitively")
        XCTAssertTrue(page.credits.isEmpty, "Only album pages carry header credits")
    }

    func testAlbumHeaderStraplineCreditsRowsWithoutAnArtistColumn() throws {
        let rows = [
            CatalogFixtures.albumSong(id: "PsO6ZnUZI0g", title: "Good Morning", duration: "3:15", plays: "158M plays"),
            CatalogFixtures.albumSong(id: "FEKEjpTzB0Q", title: "Good Life (feat. T-Pain)", duration: "3:27", plays: "300M plays"),
        ]
        let root = try CatalogFixtures.json(CatalogFixtures.browse(rows, header: CatalogFixtures.albumHeader()))
        let page = try CatalogParser.browse(root, id: CatalogFixtures.graduationID)
        let kanye = ArtistCredit(name: "Kanye West", id: CatalogFixtures.kanyeID)
        XCTAssertEqual(page.title, "Graduation")
        XCTAssertEqual(page.credits, [kanye], "The header's straplineTextOne names the album artist; subtitle runs are release type and year")
        XCTAssertEqual(page.tracks.map(\.id), ["PsO6ZnUZI0g", "FEKEjpTzB0Q"])
        XCTAssertEqual(page.tracks.first?.credits, [kanye], "Rows with an empty artist column inherit the linked album artist")
        XCTAssertEqual(page.tracks.last?.credits, [kanye, ArtistCredit(name: "T-Pain")], "The title's feature joins the inherited credit without an id")
        XCTAssertEqual(page.tracks.map(\.artistName), ["Kanye West", "Kanye West, T-Pain"])
        XCTAssertEqual(page.tracks.last?.artistID, CatalogFixtures.kanyeID)
        XCTAssertEqual(page.tracks.map(\.albumTitle), ["Graduation", "Graduation"])
        XCTAssertEqual(page.tracks.map(\.albumID), [CatalogFixtures.graduationID, CatalogFixtures.graduationID])
        XCTAssertEqual(page.tracks.map(\.duration), [195, 207])
        XCTAssertEqual(page.tracks.map(\.playCount), [158_000_000, 300_000_000])
        XCTAssertTrue(page.tracks.allSatisfy { $0.artworkURL != nil })

        let legacy = CatalogFixtures.browse(rows, header: [
            "title": CatalogFixtures.text("Graduation"),
            "straplineText": ["runs": [CatalogFixtures.browseRun("Kanye West", id: CatalogFixtures.kanyeID, type: "MUSIC_PAGE_TYPE_ARTIST")]],
        ])
        XCTAssertEqual(try CatalogParser.browse(CatalogFixtures.json(legacy), id: CatalogFixtures.graduationID).credits, [kanye],
                       "The older straplineText key still credits the album")
        let playlist = try CatalogParser.browse(root, id: "VLPLtest")
        XCTAssertTrue(playlist.credits.isEmpty, "Only album pages take the header artist as credits")
        XCTAssertTrue(playlist.tracks.isEmpty, "Outside an album, rows without an ATV confirmation stay out")
    }

    func testInheritedAlbumContextCannotLeakIntoAnotherAlbumOrAPlaylist() throws {
        let initial = try CatalogFixtures.json(CatalogFixtures.browse([], header: CatalogFixtures.albumHeader()))
        let context = CatalogParser.rowContext(initial, id: CatalogFixtures.graduationID)
        let next = try CatalogFixtures.json(["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.albumSong(id: "FEKEjpTzB0Q", title: "Good Life (feat. T-Pain)", confirmed: true),
        ]]]]])
        for id in [CatalogFixtures.albumID, "VLPLanotherPlaylist"] {
            let page = try CatalogParser.browse(next, id: id, inheriting: context)
            let track = try XCTUnwrap(page.tracks.first)
            XCTAssertTrue(page.credits.isEmpty)
            XCTAssertNil(page.title)
            XCTAssertNil(track.albumTitle)
            XCTAssertEqual(track.credits, [ArtistCredit(name: "T-Pain")])
            XCTAssertNotEqual(track.albumID, CatalogFixtures.graduationID)
        }
    }

    func testFeaturedArtistsNamedInTitlesJoinTheCreditsWithoutAnID() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(id: "FEKEjpTzB0Q", title: "Good Life (feat. T-Pain)", artist: "Kanye West", artistID: CatalogFixtures.kanyeID, album: "Graduation"),
            CatalogFixtures.song(id: "NJAv_7lHUIU", title: "Kesariya (From \"Brahmastra\")"),
            CatalogFixtures.song(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil (feat. Arijit Singh)"),
        ]))
        let tracks = try CatalogParser.search(root, filter: .songs).tracks
        XCTAssertEqual(tracks.map(\.id), ["FEKEjpTzB0Q", "NJAv_7lHUIU", "wx89ZdkwtS8"])
        XCTAssertEqual(tracks[0].credits, [ArtistCredit(name: "Kanye West", id: CatalogFixtures.kanyeID), ArtistCredit(name: "T-Pain")])
        XCTAssertEqual(tracks[0].artistName, "Kanye West, T-Pain")
        XCTAssertEqual(tracks[0].artistID, CatalogFixtures.kanyeID, "An unlinked feature never becomes the primary artist")
        XCTAssertEqual(tracks[0].allCredits, tracks[0].credits, "Features already in the credits are not offered twice")
        XCTAssertEqual(tracks[1].credits, [ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID)], "A film credit is not a feature")
        XCTAssertEqual(tracks[2].credits, [ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID)], "A feature the byline already links is not duplicated")

        let radio = try CatalogParser.radio(CatalogFixtures.json(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: "W3_c4-4OMbM", title: "Six Days (Remix) (feat. Mos Def)", artist: "DJ Shadow"),
        ])))
        XCTAssertEqual(radio.first?.credits, [ArtistCredit(name: "DJ Shadow"), ArtistCredit(name: "Mos Def")],
                       "An unlinked byline is one credit without an id, followed by the title's feature")
        XCTAssertNil(radio.first?.artistID)
        XCTAssertNil(radio.first?.artistCollection)
    }

    func testPlayCountsComeFromSearchAlbumRadioAndQueueRowsWithoutBecomingArtists() throws {
        let search = try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(), CatalogFixtures.song(id: CatalogFixtures.englishID, title: "STAY", plays: nil),
        ])), filter: .songs)
        XCTAssertEqual(search.tracks.map(\.playCount), [1_200_000_000, nil], "A row without a count stays unknown, never zero")

        let album = try CatalogParser.browse(CatalogFixtures.json(CatalogFixtures.browse([
            CatalogFixtures.albumSong(), CatalogFixtures.albumSong(id: CatalogFixtures.englishID, title: "Sunn Raha Hai", plays: "12,345 plays"),
        ])), id: CatalogFixtures.albumID)
        XCTAssertEqual(album.tracks.map(\.playCount), [845_000, 12_345])
        XCTAssertEqual(album.tracks.map(\.duration), [262, 262], "The fixed duration column is still read beside the plays column")
        XCTAssertEqual(album.tracks.first?.artists, [], "The plays column never becomes an unlinked artist")

        let radio = try CatalogParser.radio(CatalogFixtures.json(CatalogFixtures.radio([
            CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh", album: "Aashiqui 2", views: "12M views"),
            CatalogFixtures.radioTrack(id: CatalogFixtures.englishID, title: "STAY", artist: "Justin Bieber", views: "845K views"),
        ])))
        XCTAssertEqual(radio.map(\.playCount), [12_000_000, 845_000])
        XCTAssertEqual(radio.map(\.artists), [["Arijit Singh"], ["Justin Bieber"]])
        XCTAssertEqual(radio.first?.albumTitle, "Aashiqui 2")

        let queue = try CatalogParser.queue(CatalogFixtures.json(CatalogFixtures.queue([
            CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh", views: "1.2B views"),
        ])))
        XCTAssertEqual(queue.first?.playCount, 1_200_000_000)

        let artist = try CatalogParser.browse(CatalogFixtures.json(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua", plays: "98M plays"),
        ])), id: CatalogFixtures.arijitID)
        XCTAssertEqual(artist.tracks.first?.playCount, 98_000_000)
    }

    func testPlayCountIsDroppedWhenTheRowSubstitutesAnotherRecording() throws {
        var row = CatalogFixtures.song(id: "NUo8CKI34o4")["musicResponsiveListItemRenderer"] as! [String: Any]
        row["atvExternalVideoId"] = CatalogFixtures.hindiID
        let page = try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([["musicResponsiveListItemRenderer": row]])), filter: .songs)
        XCTAssertEqual(page.tracks.first?.id, CatalogFixtures.hindiID)
        XCTAssertNil(page.tracks.first?.playCount, "The video's count does not describe the substituted audio recording")
        XCTAssertNil(page.tracks.first?.duration)
    }

    func testCollectionsAreClassifiedByProviderIdentityNotRequestedFilter() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.collection(id: CatalogFixtures.albumID, title: "Aashiqui 2", type: "MUSIC_PAGE_TYPE_ALBUM"),
            CatalogFixtures.collection(id: CatalogFixtures.arijitID, title: "Arijit Singh", type: "MUSIC_PAGE_TYPE_ARTIST"),
            CatalogFixtures.collection(id: CatalogDiscovery.hindiPlaylist, title: "Bollywood Hitlist", type: "MUSIC_PAGE_TYPE_PLAYLIST"),
            CatalogFixtures.song(),
        ]))
        for (filter, kind) in [(SearchFilter.albums, CollectionKind.album), (.artists, .artist), (.playlists, .playlist)] {
            let page = try CatalogParser.search(root, filter: filter)
            XCTAssertEqual(page.collections.count, 1)
            XCTAssertEqual(page.collections.first?.kind, kind)
            XCTAssertTrue(page.tracks.isEmpty)
            XCTAssertNotNil(page.collections.first?.artworkURL)
        }
    }

    func testDirectSearchAndTopCardVariantsDoNotHarvestMenuTracks() throws {
        let actual = CatalogFixtures.song()
        let root = try CatalogFixtures.json(["contents": ["sectionListRenderer": ["contents": [
            ["itemSectionRenderer": ["contents": [actual]]],
            ["musicCardShelfRenderer": ["title": CatalogFixtures.text("Arijit Singh"),
                "contents": [actual], "menu": ["contents": [CatalogFixtures.song(id: CatalogFixtures.englishID)]]]],
        ]]]])
        XCTAssertEqual(try CatalogParser.search(root, filter: .songs).tracks.map(\.id), [CatalogFixtures.hindiID])
    }

    func testContinuationUsesContentTokenAndIgnoresSortReload() throws {
        let page = try CatalogParser.browse(CatalogFixtures.json(CatalogFixtures.browse([CatalogFixtures.song()], continuation: "tracks-page-2")), id: "VLPLtest")
        XCTAssertEqual(page.continuation, "tracks-page-2")
        XCTAssertEqual(page.title, "Aashiqui 2")
        let terminal = try CatalogParser.browse(CatalogFixtures.json(CatalogFixtures.browse([CatalogFixtures.song()])), id: "VLPLtest")
        XCTAssertNil(terminal.continuation)
        let continued = try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song()], continued: true)), filter: .songs)
        XCTAssertEqual(continued.tracks.count, 1)
    }

    func testContinuationInsideCommandExecutorDoesNotInvokeOtherCommands() throws {
        let root = try CatalogFixtures.json(["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.song(),
            ["continuationItemRenderer": ["continuationEndpoint": ["commandExecutorCommand": ["commands": [
                ["playlistVotingRefreshPopupCommand": [:]],
                ["continuationCommand": ["request": "CONTINUATION_REQUEST_TYPE_BROWSE", "token": "nested-browse-token"]],
            ]]]]],
        ]]]]])
        XCTAssertEqual(CatalogParser.continuation(root), "nested-browse-token")
        XCTAssertEqual(try CatalogParser.browse(root, id: CatalogDiscovery.hindiPlaylist).tracks.count, 1)
    }

    func testAlbumRowsInheritAlbumMetadataAndArtworkButNotRelatedAlbums() throws {
        let bare: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": CatalogFixtures.hindiID],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": CatalogFixtures.text("Tum Hi Ho")]]],
            "fixedColumns": [["musicResponsiveListItemFixedColumnRenderer": ["text": CatalogFixtures.text("4:22")]]],
        ]]
        let page = try CatalogParser.browse(CatalogFixtures.json(CatalogFixtures.browse([bare])), id: CatalogFixtures.albumID)
        XCTAssertEqual(page.tracks.first?.albumTitle, "Aashiqui 2")
        XCTAssertEqual(page.tracks.first?.albumID, CatalogFixtures.albumID)
        XCTAssertNotNil(page.tracks.first?.artworkURL)
        XCTAssertEqual(page.tracks.first?.duration, 262)
        XCTAssertTrue(page.collections.isEmpty)
    }

    func testRadioPrefersExplicitAudioCounterpartAndSkipsPodcasts() throws {
        let video = CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Tum Hi Ho video", artist: "Arijit Singh", type: "MUSIC_VIDEO_TYPE_OMV")
        let audio = CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh")
        let root = try CatalogFixtures.json(CatalogFixtures.radio([
            ["playlistPanelVideoWrapperRenderer": ["primaryRenderer": video, "counterpart": [["counterpartRenderer": audio]]]],
            audio,
            CatalogFixtures.radioTrack(id: CatalogFixtures.englishID, title: "Podcast", artist: "Host", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"),
        ]))
        let tracks = try CatalogParser.radio(root)
        XCTAssertEqual(tracks.map(\.id), [CatalogFixtures.hindiID])
        XCTAssertEqual(tracks.first?.artists, ["Arijit Singh"])
    }

    func testAppendActionAndUnavailableRows() throws {
        var unavailable = CatalogFixtures.song(id: CatalogFixtures.englishID)["musicResponsiveListItemRenderer"] as! [String: Any]
        unavailable["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        let root = try CatalogFixtures.json(["onResponseReceivedActions": [["appendContinuationItemsAction": ["continuationItems": [
            CatalogFixtures.song(), ["musicResponsiveListItemRenderer": unavailable],
            ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "after-action"]]]],
        ]]]]])
        let page = try CatalogParser.search(root, filter: .songs)
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID])
        XCTAssertEqual(page.continuation, "after-action")
    }

    func testMalformedEnvelopeAndInvalidDurations() throws {
        XCTAssertThrowsError(try CatalogJSON.decode(Data("{broken".utf8)))
        XCTAssertThrowsError(try CatalogParser.search(CatalogFixtures.json(["responseContext": [:]]), filter: .songs))
        XCTAssertEqual(try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([])), filter: .songs).tracks.count, 0)
        XCTAssertNil(CatalogText.duration("3:99"))
        XCTAssertNil(CatalogText.duration("NaN"))
        XCTAssertNil(CatalogText.duration("-1:20"))
        XCTAssertEqual(CatalogText.duration("1:02:03"), 3_723)
        XCTAssertNil(CatalogText.imageURL("javascript:alert(1)"))
        XCTAssertNil(CatalogText.imageURL("https://user:password@example.com/image"))
    }

    func testLanguageTargetingDoesNotTurnEveryLatinTitleOrIndianArtistIntoEvidence() {
        let unknown = Track(id: "xTvyyoF_LZX", title: "Lovely Song", artists: ["Unknown artist"])
        XCTAssertFalse(CatalogDiscovery.accepts(unknown, language: .english))
        let bengali = Track(id: "FOA9iyxsW_B", title: "Song (Bengali Version)", artists: ["Arijit Singh"])
        XCTAssertFalse(CatalogDiscovery.accepts(bengali, language: .hindi))
        let likely = Track(id: "wx89ZdkwtS8", title: "Ae Dil Hai Mushkil", artists: ["Arijit Singh"])
        let selected = CatalogDiscovery.select([likely, likely], language: .hindi)
        XCTAssertEqual(selected.count, 1)
        XCTAssertNil(selected.first?.language)
        XCTAssertFalse(CatalogDiscovery.accepts(CatalogDiscovery.starters(for: .hindi)[0], language: .english))
    }

    func testChartPreservesRanksViewsDatesAndAudioIdentity() throws {
        var unavailable = CatalogFixtures.chartRow(id: "FOA9iyxsW_A", rank: 2)
        unavailable["isAvailable"] = false
        let root = try CatalogFixtures.json(CatalogFixtures.chart([
            CatalogFixtures.chartRow(id: "FyS5dAywkEo", rank: 7, views: "154951658", audioID: "wx89ZdkwtS8"),
            CatalogFixtures.chartRow(rank: 1), unavailable,
            CatalogFixtures.chartRow(id: "also-invalid", rank: 3, audioID: nil),
            CatalogFixtures.chartRow(id: "FyS5dAywkEo", rank: 8, audioID: "wx89ZdkwtS8"),
        ]))
        let fetched = try XCTUnwrap(CatalogChartParser.date("2026-09-19"))
        let chart = try CatalogChartParser.parseSongChart(root, language: .hindi, region: "in", fetchedAt: fetched)
        XCTAssertEqual(chart.entries.map(\.rank), [1, 7])
        XCTAssertEqual(chart.entries.last?.track.id, "wx89ZdkwtS8")
        XCTAssertEqual(chart.entries.last?.views, 154_951_658)
        XCTAssertEqual(chart.entries.first?.previousRank, 2)
        XCTAssertNil(chart.entries.last?.track.duration)
        XCTAssertNil(chart.entries.first?.track.artistID)
        XCTAssertEqual(chart.periodEnd, CatalogChartParser.date("2026-09-10"))
        XCTAssertEqual(chart.periodStart, CatalogChartParser.date("2026-09-04"))
        XCTAssertEqual(chart.fetchedAt, fetched)
        XCTAssertEqual(chart.language, .hindi)
        XCTAssertEqual(chart.source, "YouTube Charts · Weekly songs · selected for you")
        XCTAssertEqual(chart.title, "Weekly picks")
        XCTAssertNil(chart.entries.last?.track.language)
        XCTAssertTrue(chart.entries.allSatisfy { $0.track.isAudioRecording == true })
        XCTAssertTrue(chart.entries.allSatisfy { $0.track.artworkURL != nil })
    }

    func testChartCreditsKeepUnlinkedPrimariesAndEachCollaboratorsOwnID() throws {
        let cases: [[ArtistCredit]] = [
            [ArtistCredit(name: "Primary Singer"), ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID),
             ArtistCredit(name: "Pritam", id: CatalogFixtures.pritamID)],
            [ArtistCredit(name: "Arijit Singh", id: CatalogFixtures.arijitID), ArtistCredit(name: "Pritam", id: CatalogFixtures.pritamID),
             ArtistCredit(name: "Shashwat Singh", id: CatalogFixtures.shashwatID)],
        ]
        for credits in cases {
            var row = CatalogFixtures.chartRow(audioID: "wx89ZdkwtS8")
            row["artists"] = credits.map { credit -> [String: Any] in
                var artist: [String: Any] = ["name": credit.name]
                if let id = credit.id { artist["externalChannelId"] = id }
                return artist
            }
            let chart = try parseChart(CatalogFixtures.chart([row]))
            let track = try XCTUnwrap(chart.entries.first?.track)
            XCTAssertEqual(track.credits, credits)
            XCTAssertNil(track.language)
            XCTAssertEqual(chart.entries.first?.rank, 1)
        }
    }

    func testChartDoesNotInventMissingRanksCountsDatesOrLanguage() throws {
        var unranked = CatalogFixtures.chartRow()
        unranked["chartEntryMetadata"] = [:]
        XCTAssertTrue(try parseChart(CatalogFixtures.chart([unranked])).entries.isEmpty)
        let negativeViews = try parseChart(CatalogFixtures.chart([CatalogFixtures.chartRow(views: "-10")]))
        XCTAssertNil(negativeViews.entries.first?.views)
        XCTAssertThrowsError(try parseChart(CatalogFixtures.chart([CatalogFixtures.chartRow()], endDate: nil)))
        XCTAssertThrowsError(try parseChart(CatalogFixtures.chart([CatalogFixtures.chartRow()], endDate: "2026-02-30")))
        XCTAssertThrowsError(try parseChart(CatalogFixtures.chart([CatalogFixtures.chartRow()], type: "VIDEOS_LOP")))
        XCTAssertThrowsError(try parseChart(CatalogFixtures.chart([CatalogFixtures.chartRow()], region: "global")))
        XCTAssertNil(CatalogChartParser.date("2026-9-10"))
        XCTAssertNil(CatalogChartParser.date("2026-+9-10"))
    }

    func testRegionalSongPicksRequireATVAndDoNotInferLanguageFromCountry() throws {
        var noAudio = CatalogFixtures.chartRow(id: "FyS5dAywkEo", rank: 1, audioID: nil)
        noAudio["encryptedVideoId"] = "FyS5dAywkEo"
        let root = try CatalogFixtures.json(CatalogFixtures.chart([
            noAudio,
            CatalogFixtures.chartRow(rank: 3, audioID: "XfEMj-z3TtA", artist: "Justin Bieber"),
            CatalogFixtures.chartRow(rank: 8, artist: "Arijit Singh"),
        ], region: "us"))
        let chart = try CatalogChartParser.parseSongChart(root, language: .english, region: "us", fetchedAt: Date())
        XCTAssertEqual(chart.entries.map(\.rank), [3])
        XCTAssertEqual(chart.entries.first?.track.id, "XfEMj-z3TtA")
        XCTAssertNil(chart.entries.first?.track.language)
        XCTAssertTrue(chart.subtitle.contains("United States"))
        XCTAssertEqual(chart.entries.first?.track.artworkURL?.absoluteString, "https://i.ytimg.com/vi/XfEMj-z3TtA/hqdefault.jpg")
    }

    func testExplicitVideoAndEpisodeRowsAreRejectedEvenWithUnrelatedMenuATV() throws {
        var video = CatalogFixtures.radioTrack(id: "NUo8CKI34o4", title: "Tum Hi Ho (Official Video)", artist: "Arijit Singh", type: "MUSIC_VIDEO_TYPE_OMV")["playlistPanelVideoRenderer"] as! [String: Any]
        video["menu"] = ["navigationEndpoint": ["watchEndpoint": CatalogFixtures.watch(CatalogFixtures.hindiID)]]
        let rows = [["playlistPanelVideoRenderer": video],
                    CatalogFixtures.radioTrack(id: "ic8j13piAhQ", title: "Clip", artist: "Taylor Swift", type: "MUSIC_VIDEO_TYPE_UGC"),
                    CatalogFixtures.radioTrack(id: "FOA9iyxsW_A", title: "Episode", artist: "Arijit Singh", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"),
                    CatalogFixtures.radioTrack(id: CatalogFixtures.hindiID, title: "Tum Hi Ho", artist: "Arijit Singh")]
        XCTAssertEqual(try CatalogParser.radio(CatalogFixtures.json(CatalogFixtures.radio(rows))).map(\.id), [CatalogFixtures.hindiID])
    }

    func testFreshSearchOverlaySuppliesTheATVType() throws {
        let row: [String: Any] = ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": CatalogFixtures.hindiID],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": CatalogFixtures.text("Tum Hi Ho")]]],
            "overlay": ["musicItemThumbnailOverlayRenderer": ["content": ["musicPlayButtonRenderer": [
                "playNavigationEndpoint": ["watchEndpoint": CatalogFixtures.watch(CatalogFixtures.hindiID)],
            ]]]],
        ]]
        let tracks = try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([row])), filter: .songs).tracks
        XCTAssertEqual(tracks.first?.isAudioRecording, true)
        XCTAssertEqual(tracks.first?.id, CatalogFixtures.hindiID)
    }

    func testSpellingCorrectionIsParsedOnlyWhenItChangesTheQuery() throws {
        let showing = CatalogFixtures.search([CatalogFixtures.song()], correction: CatalogFixtures.showingResultsFor(original: "Arjit Singh", corrected: "Arijit Singh"))
        let page = try CatalogParser.search(CatalogFixtures.json(showing), filter: .songs, query: "Arjit Singh")
        XCTAssertEqual(page.correctedQuery, "Arijit Singh", "Italic and plain runs are joined")
        XCTAssertEqual(page.tracks.count, 1, "The banner section does not hide the shelf")
        XCTAssertEqual(try CatalogParser.search(CatalogFixtures.json(showing), filter: .songs).correctedQuery, "Arijit Singh", "originalQuery stands in without a caller query")
        XCTAssertNil(try CatalogParser.search(CatalogFixtures.json(showing), filter: .songs, query: "arijit singh").correctedQuery)
        XCTAssertEqual(try CatalogParser.search(CatalogFixtures.json(showing), filter: .artists, query: "Arjit Singh").correctedQuery, "Arijit Singh")
        let suggestion = CatalogFixtures.search([], correction: CatalogFixtures.didYouMean(corrected: "Arijit Singh"))
        XCTAssertEqual(try CatalogParser.search(CatalogFixtures.json(suggestion), filter: .songs, query: "Arjit Singh").correctedQuery, "Arijit Singh")
        XCTAssertNil(try CatalogParser.search(CatalogFixtures.json(suggestion), filter: .songs, query: "ARIJIT SINGH").correctedQuery)
        XCTAssertNil(try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song()])), filter: .songs, query: "Tum Hi Ho").correctedQuery)
    }

    func testUnconfirmedSongRowsBecomeCandidatesInProviderOrderButNotTracks() throws {
        var podcast = CatalogFixtures.song(id: "ic8j13piAhQ", title: "Episode", confirmed: false)["musicResponsiveListItemRenderer"] as! [String: Any]
        podcast["navigationEndpoint"] = ["watchEndpoint": CatalogFixtures.watch("ic8j13piAhQ", type: "MUSIC_VIDEO_TYPE_PODCAST_EPISODE")]
        var greyed = CatalogFixtures.song(id: "NUo8CKI34o4", title: "Unavailable", confirmed: false)["musicResponsiveListItemRenderer"] as! [String: Any]
        greyed["musicItemRendererDisplayPolicy"] = "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
        let root = try CatalogFixtures.json(CatalogFixtures.search([
            CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", confirmed: false),
            CatalogFixtures.collection(id: CatalogFixtures.arijitID, title: "Arijit Singh", type: "MUSIC_PAGE_TYPE_ARTIST"),
            CatalogFixtures.song(),
            ["musicResponsiveListItemRenderer": podcast], ["musicResponsiveListItemRenderer": greyed],
            CatalogFixtures.song(id: CatalogFixtures.englishID, title: "Blinding Lights", artist: "The Weeknd", confirmed: false),
            CatalogFixtures.song(id: "FOA9iyxsW_A", title: "Agar Tum Saath Ho", confirmed: false),
        ]))
        XCTAssertEqual(try CatalogParser.search(root, filter: .songs).tracks.map(\.id), [CatalogFixtures.hindiID], "Unconfirmed rows stay out of the strict page")
        XCTAssertEqual(CatalogParser.searchAudioCandidateIDs(root), ["FOA9iyxsW_A", CatalogFixtures.hindiID, CatalogFixtures.englishID],
                       "Candidates keep provider order, include confirmed rows, and skip collections, podcasts, and greyed-out rows")
    }

    func testGoogleHostedThumbnailsAreRequestedAtTheStandardSquareAndYtimgIsLeftAlone() throws {
        let song = try CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song(thumbnail: CatalogFixtures.googleArtwork("Cover"))]))
        XCTAssertEqual(try CatalogParser.search(song, filter: .songs).tracks.first?.artworkURL?.absoluteString,
                       "https://yt3.googleusercontent.com/Cover=w544-h544-l90-rj")
        let artist = try CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.artistRow()]))
        XCTAssertEqual(try CatalogParser.search(artist, filter: .artists).collections.first?.artworkURL?.absoluteString,
                       "https://yt3.googleusercontent.com/ArtistmPoQ=w544-h544-p-l90-rj", "Provider crop flags survive the resize")
        let frame = try CatalogParser.search(try CatalogFixtures.json(CatalogFixtures.search([CatalogFixtures.song()])), filter: .songs)
        XCTAssertEqual(frame.tracks.first?.artworkURL?.absoluteString, "https://i.ytimg.com/vi/\(CatalogFixtures.hindiID)/hqdefault.jpg")
        XCTAssertEqual(CatalogText.artwork(.null, videoID: CatalogFixtures.englishID)?.absoluteString, "https://i.ytimg.com/vi/\(CatalogFixtures.englishID)/hqdefault.jpg")
    }

    func testArtistPageSeparatesHeaderTopSongsReleasesAndRelatedArtists() throws {
        let root = try CatalogFixtures.json(CatalogFixtures.artistPage(songs: [
            CatalogFixtures.song(id: "i1o1p_DD6TU", title: "Gehra Hua"), CatalogFixtures.song(),
        ], albums: [
            CatalogFixtures.collection(id: "MPREb_LFp4PGrIxoH", title: "Romance Reloaded", type: "MUSIC_PAGE_TYPE_ALBUM", subtitle: "Album • 2026"),
            CatalogFixtures.collection(id: "MPREb_rV5VAlzAHFb", title: "Ramayana", type: "MUSIC_PAGE_TYPE_ALBUM", subtitle: "Single • 2026"),
        ], related: [
            CatalogFixtures.collection(id: "UCzJRkr4MuVD7sEGHR_zRSEQ", title: "Tulsi Kumar", type: "MUSIC_PAGE_TYPE_ARTIST", subtitle: "257M monthly audience"),
        ]))
        let page = try CatalogParser.browse(root, id: CatalogFixtures.arijitID)
        XCTAssertEqual(page.title, "Arijit Singh")
        XCTAssertEqual(page.tracks.map(\.id), ["i1o1p_DD6TU", CatalogFixtures.hindiID])
        XCTAssertEqual(page.collections.map(\.id), ["MPREb_LFp4PGrIxoH", "MPREb_rV5VAlzAHFb", "UCzJRkr4MuVD7sEGHR_zRSEQ"])
        XCTAssertEqual(page.collections.map(\.kind), [.album, .album, .artist])
        XCTAssertEqual(page.collections.first?.subtitle, "Album • 2026")
        let header = CatalogParser.artistHeader(root)
        XCTAssertEqual(header.name, "Arijit Singh")
        XCTAssertEqual(header.artworkURL?.absoluteString, "https://lh3.googleusercontent.com/\(CatalogFixtures.artistBannerHash)=w544-h544-p-l90-rj",
                        "The widest banner is re-requested as a smart-cropped square")
    }

    func testArtistMonthlyAudiencePreservesTheProviderUnitDespiteTheLegacyFieldName() throws {
        var fields = ArtistSpotlightMonthlyAudienceFixtures.header().object
        fields["monthlyListenerCount"] = ["runs": [["text": "12.3"], ["text": "M monthly "], ["text": "audience"]]]
        let root = try ArtistSpotlightMonthlyAudienceFixtures.response(header: .object(fields),
            pageDescription: "Artist • 88M monthly listeners")
        let header = CatalogParser.artistHeader(root)
        XCTAssertEqual(header.name, ArtistSpotlightMonthlyAudienceFixtures.name)
        XCTAssertEqual(header.monthlyAudience?.value, 12_300_000)
        XCTAssertEqual(header.monthlyAudience?.label, "12.3M monthly audience")
        XCTAssertEqual(header.monthlyAudience?.kind, .audience, "The field name must not rename the provider's audience as listeners")
        XCTAssertEqual(header.monthlyAudience?.source, .headerCount, "The dedicated header statistic wins over page description")
        XCTAssertEqual(try CatalogParser.browse(root, id: ArtistSpotlightMonthlyAudienceFixtures.artistID).tracks.first?.playCount, 1_200_000_000)

        fields["monthlyListenerCount"] = ["simpleText": "1,234 monthly listeners"]
        let listeners = CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(header: .object(fields))).monthlyAudience
        XCTAssertEqual(listeners?.value, 1_234)
        XCTAssertEqual(listeners?.label, "1,234 monthly listeners")
        XCTAssertEqual(listeners?.kind, .listeners)
    }

    func testMonthlyAudienceUsesOnlyAnExplicitDescriptionForTheSameArtist() throws {
        let root = try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: nil,
            pageDescription: "Artist • 42K monthly listeners")
        let audience = CatalogParser.artistHeader(root).monthlyAudience
        XCTAssertEqual(audience?.value, 42_000)
        XCTAssertEqual(audience?.label, "42K monthly listeners")
        XCTAssertEqual(audience?.source, .pageDescription)
        XCTAssertNil(CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: nil,
            pageDescription: "Artist • 42K monthly listeners", pageTitle: "Someone Else")).monthlyAudience)

        var fields = ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: nil).object
        fields["description"] = ["simpleText": "605M monthly audience"]
        let described = CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(header: .object(fields))).monthlyAudience
        XCTAssertEqual(described?.value, 605_000_000)
        XCTAssertEqual(described?.source, .headerDescription)
        fields["description"] = ["simpleText": "A collaborator once reached 42M monthly listeners on another platform."]
        XCTAssertNil(CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(header: .object(fields))).monthlyAudience)
    }

    func testMissingMonthlyAudienceCannotComeFromSubscribersSongCountsOrRelatedArtists() throws {
        let missing = try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: nil,
            pageDescription: "Artist • 1.2B views")
        XCTAssertNil(CatalogParser.artistHeader(missing).monthlyAudience)
        XCTAssertNil(ArtistPage(id: "fixture", name: "Artist").monthlyAudience)
        let nonMonthlyFields: [CatalogJSON] = [.number(605_000_000), "605M", ["simpleText": "4.49M subscribers"],
                                              ["simpleText": "1.2B plays"], ["simpleText": "12M views"], .null]
        for field in nonMonthlyFields {
            var fields = ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: nil).object
            fields["monthlyListenerCount"] = field
            fields["subscriberCount"] = "605M"
            fields["subscriptionCount"] = 605_000_000
            let root = try ArtistSpotlightMonthlyAudienceFixtures.response(header: .object(fields))
            XCTAssertNil(CatalogParser.artistHeader(root).monthlyAudience, field.text)
        }
    }

    func testMalformedMonthlyLabelsStayUnknownAndExplicitZeroIsPreserved() throws {
        for label in ["monthly audience", "-12M monthly audience", "+12M monthly audience", "NaN monthly listeners",
                      "Infinity monthly audience", "1,23M monthly audience", "999999999999999999999T monthly audience",
                      "12M monthly subscribers", "12M plays monthly", "Artist • 12M monthly audience • 9M monthly listeners"] {
            XCTAssertNil(CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: label)).monthlyAudience, label)
        }
        let zero = CatalogParser.artistHeader(try ArtistSpotlightMonthlyAudienceFixtures.response(monthlyLabel: "0 monthly audience")).monthlyAudience
        XCTAssertEqual(zero?.value, 0)
        XCTAssertEqual(zero?.label, "0 monthly audience", "Only an explicit provider zero may be displayed")
    }

    func testArtistMonthlyHeaderCannotBeReplacedByNestedCarouselsMenusOrASecondHeader() throws {
        let own = ArtistSpotlightMonthlyAudienceFixtures.header()
        let other = ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: "999M monthly audience")
        let distractions: [CatalogJSON] = [
            ["musicCarouselShelfRenderer": ["contents": [["musicResponsiveHeaderRenderer": other]]]],
            ["musicShelfRenderer": ["header": ["musicResponsiveHeaderRenderer": other]]],
            ["menu": ["musicImmersiveHeaderRenderer": other]],
        ]
        for items in [distractions, Array(distractions.reversed())] {
            let root: CatalogJSON = ["header": ["musicImmersiveHeaderRenderer": own],
                                    "contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": [
                                        "content": ["sectionListRenderer": ["contents": .array(items)]]],
                                    ]]]]]
            XCTAssertEqual(CatalogParser.artistHeader(root).monthlyAudience?.value, 12_300_000)
            var withoutOwn = root.object
            withoutOwn.removeValue(forKey: "header")
            XCTAssertNil(CatalogParser.artistHeader(.object(withoutOwn)).monthlyAudience)
        }
        let missingOwn: CatalogJSON = ["header": ["musicImmersiveHeaderRenderer": ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: nil)],
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": [
                "contents": [["musicResponsiveHeaderRenderer": other]],
            ]]]]]]]]
        XCTAssertNil(CatalogParser.artistHeader(missingOwn).monthlyAudience, "A missing statistic is not permission to switch page headers")
    }

    func testMonthlyAudienceFindsOnlyTheSelectedTabsOwnResponsiveHeaderInEitherLayout() {
        let own = ArtistSpotlightMonthlyAudienceFixtures.header()
        let other = ArtistSpotlightMonthlyAudienceFixtures.header(monthlyLabel: "999M monthly audience")
        for layout in ["singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer"] {
            let items: [CatalogJSON] = [
                ["musicCarouselShelfRenderer": ["contents": [["musicResponsiveHeaderRenderer": other]]]],
                ["musicResponsiveHeaderRenderer": own],
                ["musicShelfRenderer": ["header": ["musicImmersiveHeaderRenderer": other]]],
            ]
            for ordered in [items, Array(items.reversed())] {
                let root: CatalogJSON = ["contents": .object([layout: ["tabs": [
                    ["tabRenderer": ["selected": false, "content": ["sectionListRenderer": ["contents": [["musicResponsiveHeaderRenderer": other]]]]]],
                    ["tabRenderer": ["selected": true, "content": ["sectionListRenderer": ["contents": .array(ordered)]]]],
                ]]])]
                let header = CatalogParser.artistHeader(root)
                XCTAssertEqual(header.name, ArtistSpotlightMonthlyAudienceFixtures.name)
                XCTAssertEqual(header.monthlyAudience?.value, 12_300_000, layout)
            }
        }
    }

    private func parseChart(_ object: [String: Any]) throws -> ChartSnapshot {
        try CatalogChartParser.parseSongChart(CatalogFixtures.json(object), language: .hindi, region: "in", fetchedAt: Date())
    }
}
