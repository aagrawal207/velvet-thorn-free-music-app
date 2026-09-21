import Foundation
@testable import GanaBajana

enum CatalogFixtures {
    static let hindiID = "fsiPzT50ZiM"
    static let englishID = "J7p4bzqLvCw"
    static let arijitID = "UCDxKh1gFWeYsqePvgVzmPoQ"
    static let pritamID = "UCCTN01plFzn4npREHKT2_9Q"
    static let shashwatID = "UCq2kR5QY7sFmWgKJxLtu3nA"
    static let antaraID = "UCtM7bZpVx3nWqR9sLdKf2Yg"
    static let kanyeID = "UCRY5dYsbIN5TylSbd7gVnZg"
    static let albumID = "MPREb_E4GfUXfDfhy"
    static let graduationID = "MPREb_KCNeTnK02S7"
    static let version = "1.20260918.01.00"
    static let bootstrap = Data("<script>ytcfg.set({\"INNERTUBE_CLIENT_VERSION\":\"\(version)\"});</script>".utf8)

    static func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func json(_ value: [String: Any]) throws -> CatalogJSON { try CatalogJSON.decode(data(value)) }

    static func text(_ value: String) -> [String: Any] { ["runs": [["text": value]]] }

    static func browseRun(_ name: String, id: String, type: String) -> [String: Any] {
        ["text": name, "navigationEndpoint": ["browseEndpoint": [
            "browseId": id,
            "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": type]],
        ]]]
    }

    /// Linked artist runs as the provider writes a byline: ", " between credits and " & " before the last one.
    static func artistRuns(_ artists: [(name: String, id: String)]) -> [[String: Any]] {
        var runs: [[String: Any]] = []
        for (index, artist) in artists.enumerated() {
            if index > 0 { runs.append(["text": index == artists.count - 1 ? " & " : ", "]) }
            runs.append(browseRun(artist.name, id: artist.id, type: "MUSIC_PAGE_TYPE_ARTIST"))
        }
        return runs
    }

    static func watch(_ id: String, type: String = "MUSIC_VIDEO_TYPE_ATV") -> [String: Any] {
        ["videoId": id, "watchEndpointMusicSupportedConfigs": ["watchEndpointMusicConfig": ["musicVideoType": type]]]
    }

    static func artwork() -> [String: Any] {
        ["thumbnails": [
            ["url": "https://i.ytimg.com/vi/\(hindiID)/default.jpg", "width": 120, "height": 90],
            ["url": "https://i.ytimg.com/vi/\(hindiID)/hqdefault.jpg", "width": 480, "height": 360],
        ]]
    }

    /// The 60/120 px Google user-content pair that search rows and get_queue carry instead of ytimg frames.
    static func googleArtwork(_ hash: String = "AbCdEf", flags: String = "") -> [String: Any] {
        ["thumbnails": [
            ["url": "https://yt3.googleusercontent.com/\(hash)=w60-h60\(flags)-l90-rj", "width": 60, "height": 60],
            ["url": "https://yt3.googleusercontent.com/\(hash)=w120-h120\(flags)-l90-rj", "width": 120, "height": 120],
        ]]
    }

    /// A song search row. `artists` replaces the single `artist`/`artistID` pair with a full linked byline.
    static func song(id: String = hindiID, title: String = "Tum Hi Ho", artist: String = "Arijit Singh",
                     artistID: String = arijitID, artists: [(name: String, id: String)]? = nil,
                     album: String = "Aashiqui 2", duration: String = "4:22",
                     explicit: Bool = false, confirmed: Bool = true, thumbnail: [String: Any]? = nil,
                     plays: String? = "1.2B plays") -> [String: Any] {
        let endpoint: [String: Any] = confirmed ? watch(id) : ["videoId": id]
        let byline: [[String: Any]] = artistRuns(artists ?? [(name: artist, id: artistID)]) + [
            ["text": " • "], browseRun(album, id: albumID, type: "MUSIC_PAGE_TYPE_ALBUM"),
            ["text": " • "], ["text": duration],
        ]
        var columns: [[String: Any]] = [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                ["text": title, "navigationEndpoint": ["watchEndpoint": endpoint]],
            ]]]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": byline]]],
        ]
        if let plays { columns.append(["musicResponsiveListItemFlexColumnRenderer": ["text": text(plays)]]) }
        var row: [String: Any] = [
            "playlistItemData": ["videoId": id],
            "flexColumns": columns,
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": thumbnail ?? artwork()]],
        ]
        if explicit { row["badges"] = [["musicInlineBadgeRenderer": ["icon": ["iconType": "MUSIC_EXPLICIT_BADGE"]]]] }
        return ["musicResponsiveListItemRenderer": row]
    }

    /// An album page row as WEB_REMIX serves it: title, an empty artist column, plays, and a fixed duration column.
    static func albumSong(id: String = hindiID, title: String = "Tum Hi Ho", duration: String? = "4:22",
                          plays: String? = "845K plays", confirmed: Bool = false) -> [String: Any] {
        var columns: [[String: Any]] = [
            ["musicResponsiveListItemFlexColumnRenderer": ["text": text(title)]],
            ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [] as [[String: Any]]]]],
        ]
        if let plays { columns.append(["musicResponsiveListItemFlexColumnRenderer": ["text": text(plays)]]) }
        var row: [String: Any] = ["playlistItemData": ["videoId": id], "flexColumns": columns]
        if let duration { row["fixedColumns"] = [["musicResponsiveListItemFixedColumnRenderer": ["text": text(duration)]]] }
        if confirmed { row["onTap"] = ["watchEndpoint": watch(id)] }
        return ["musicResponsiveListItemRenderer": row]
    }

    /// The `musicResponsiveHeaderRenderer` of an album page: the artist is linked from `straplineTextOne`, while
    /// `subtitle` and `secondSubtitle` carry only the release type, year, and length.
    static func albumHeader(title: String = "Graduation", artist: String = "Kanye West", artistID: String = kanyeID,
                            year: String = "2007", songs: Int = 14) -> [String: Any] {
        [
            "title": text(title),
            "subtitle": ["runs": [["text": "Album"], ["text": " • "], ["text": year]]],
            "straplineTextOne": ["runs": [browseRun(artist, id: artistID, type: "MUSIC_PAGE_TYPE_ARTIST")]],
            "secondSubtitle": ["runs": [["text": "\(songs) songs"], ["text": " • "], ["text": "54 minutes"]]],
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": artwork()]],
        ]
    }

    static func collection(id: String, title: String, type: String, subtitle: String = "YouTube Music",
                           thumbnail: [String: Any]? = nil) -> [String: Any] {
        ["musicTwoRowItemRenderer": [
            "title": text(title), "subtitle": text(subtitle),
            "navigationEndpoint": browseRun(title, id: id, type: type)["navigationEndpoint"]!,
            "thumbnailRenderer": ["musicThumbnailRenderer": ["thumbnail": thumbnail ?? artwork()]],
        ]]
    }

    /// Artist rows in an artists search: a list item whose own navigation is the artist browse endpoint.
    static func artistRow(id: String = arijitID, name: String = "Arijit Singh", audience: String = "665M monthly audience") -> [String: Any] {
        ["musicResponsiveListItemRenderer": [
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": text(name)]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Artist"], ["text": " • "], ["text": audience]]]]],
            ],
            "navigationEndpoint": browseRun(name, id: id, type: "MUSIC_PAGE_TYPE_ARTIST")["navigationEndpoint"]!,
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": googleArtwork("Artist\(id.suffix(4))", flags: "-p")]],
        ]]
    }

    /// "Showing results for" banner: the provider already searched `corrected`, italicizing the changed word.
    static func showingResultsFor(original: String, corrected: String) -> [String: Any] {
        ["showingResultsForRenderer": [
            "showingResultsFor": text("Showing results for"),
            "correctedQuery": ["runs": [["text": String(corrected.prefix(1)), "italics": true], ["text": String(corrected.dropFirst())]]],
            "originalQuery": text(original),
        ]]
    }

    static func didYouMean(corrected: String) -> [String: Any] {
        ["didYouMeanRenderer": ["didYouMean": text("Did you mean: "), "correctedQuery": ["runs": [["text": corrected, "bold": true]]]]]
    }

    static func search(_ rows: [[String: Any]], continuation: String? = nil, continued: Bool = false,
                       correction: [String: Any]? = nil) -> [String: Any] {
        var shelf: [String: Any] = ["title": text("Songs"), "contents": rows]
        if let continuation { shelf["continuations"] = [["nextContinuationData": ["continuation": continuation]]] }
        if continued { return ["continuationContents": ["musicShelfContinuation": shelf]] }
        var sections: [[String: Any]] = []
        if let correction { sections.append(["itemSectionRenderer": ["contents": [correction]]]) }
        sections.append(["musicShelfRenderer": shelf])
        return ["contents": ["tabbedSearchResultsRenderer": ["tabs": [["tabRenderer": [
            "selected": true, "content": ["sectionListRenderer": ["contents": sections]],
        ]]]]]]
    }

    static let artistBannerHash = "W_yOqnKSDYyeVOY_AsXhuAtb6rW3vCL3GtJ9DA1GxWOrJfyeSOqzvTv_TkFHijdkVPXWutASBlRFPg"

    /// An artist browse page: immersive header, a "Top songs" shelf, and carousels of releases and related artists.
    static func artistPage(id: String = arijitID, name: String = "Arijit Singh", songs: [[String: Any]],
                           albums: [[String: Any]] = [], related: [[String: Any]] = []) -> [String: Any] {
        func carousel(_ title: String, _ items: [[String: Any]]) -> [String: Any] {
            ["musicCarouselShelfRenderer": [
                "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": text(title)]], "contents": items,
            ]]
        }
        let sections: [[String: Any]] = [
            ["musicShelfRenderer": ["title": text("Top songs"), "contents": songs]],
            carousel("Albums", albums), carousel("Fans might also like", related),
        ]
        return [
            "header": ["musicImmersiveHeaderRenderer": [
                "title": text(name),
                "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [
                    ["url": "https://lh3.googleusercontent.com/\(artistBannerHash)=w540-h225-p-l90-rj", "width": 540, "height": 225],
                    ["url": "https://lh3.googleusercontent.com/\(artistBannerHash)=w1440-h600-p-l90-rj", "width": 1440, "height": 600],
                ]]]],
            ]],
            "contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": [
                "content": ["sectionListRenderer": ["contents": sections]],
            ]]]]],
        ]
    }

    /// A two-column browse page (album or playlist). The default header is a bare "Aashiqui 2" title; pass
    /// `albumHeader()` for the full album header with its strapline artist.
    static func browse(_ rows: [[String: Any]], continuation: String? = nil, header: [String: Any]? = nil) -> [String: Any] {
        var items = rows
        if let continuation {
            items.append(["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": [
                "token": continuation, "request": "CONTINUATION_REQUEST_TYPE_BROWSE",
            ]]]])
        }
        let shelf: [String: Any] = ["musicPlaylistShelfRenderer": ["contents": items, "header": [
            "sort": ["reloadContinuationData": ["continuation": "not-a-next-page"]],
        ]]]
        return ["contents": ["twoColumnBrowseResultsRenderer": [
            "tabs": [["tabRenderer": ["content": ["sectionListRenderer": ["contents": [[
                "musicResponsiveHeaderRenderer": header ?? ["title": text("Aashiqui 2"), "thumbnail": artwork()],
            ]]]]]]],
            "secondaryContents": ["sectionListRenderer": ["contents": [shelf]]],
        ]]]
    }

    static func radioTrack(id: String, title: String, artist: String, type: String = "MUSIC_VIDEO_TYPE_ATV",
                           album: String? = nil, thumbnail: [String: Any]? = nil, views: String? = nil,
                           duration: String = "3:22") -> [String: Any] {
        var renderer: [String: Any] = [
            "videoId": id, "title": text(title), "shortBylineText": text(artist), "lengthText": text(duration),
            "navigationEndpoint": ["watchEndpoint": watch(id, type: type)], "thumbnail": thumbnail ?? artwork(),
        ]
        if album != nil || views != nil {
            var runs: [[String: Any]] = [browseRun(artist, id: arijitID, type: "MUSIC_PAGE_TYPE_ARTIST")]
            if let album { runs += [["text": " • "], browseRun(album, id: albumID, type: "MUSIC_PAGE_TYPE_ALBUM")] }
            if let views { runs += [["text": " • "], ["text": views]] }
            renderer["longBylineText"] = ["runs": runs]
        }
        return ["playlistPanelVideoRenderer": renderer]
    }

    /// A get_queue envelope for already-built `radioTrack` renderers.
    static func queue(_ items: [[String: Any]]) -> [String: Any] {
        ["queueDatas": items.map { ["content": $0] }]
    }

    static func radio(_ items: [[String: Any]]) -> [String: Any] {
        ["contents": ["singleColumnMusicWatchNextResultsRenderer": ["tabbedRenderer": [
            "watchNextTabbedResultsRenderer": ["tabs": [["tabRenderer": ["content": [
                "musicQueueRenderer": ["content": ["playlistPanelRenderer": ["contents": items]]],
            ]]]]],
        ]]]]
    }

    static func chartRow(id: String = "s2HYl12gmOY", title: String = "Parvati", rank: Int = 1,
                         views: Any = "16321798", audioID: String? = hindiID, artist: String = "Arijit Singh") -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "title": title, "name": title, "viewCount": views, "videoDuration": 286,
            "chartEntryMetadata": ["currentPosition": rank, "previousPosition": 2],
            "artists": [["name": artist, "kgMid": "/g/11nph_9d1g"]],
            "externalChannelId": "UCn9WB2Eb1QRSYkFxuPQHkxg", "thumbnail": artwork(),
            "isAvailable": true, "isVisible": true,
        ]
        if let audioID { row["atvExternalVideoId"] = audioID }
        return row
    }

    static func chart(_ rows: [[String: Any]], region: String = "in", language: String? = nil, type: String = "TRACKS",
                      endDate: String? = "2026-09-10", capabilities: [[String: Any]] = []) -> [String: Any] {
        var params: [String: Any] = ["countryCode": region, "chartType": "CHART_TYPE_" + type,
                                     "chartPeriodType": "CHART_PERIOD_TYPE_WEEKLY"]
        if let language { params["chartAttribute"] = ["language": language] }
        let songs = type == "TRACKS"
        var group: [String: Any] = ["listType": type == "VIDEOS_LOP" ? "LOP_CHART" : "TOP_VIEWS_CHART",
                                    "chartPeriodType": "CHART_PERIOD_TYPE_WEEKLY", songs ? "trackViews" : "videoViews": rows]
        if let endDate { group["endDate"] = endDate }
        return ["contents": ["sectionListRenderer": ["contents": [["musicAnalyticsSectionRenderer": ["content": [
            "perspectiveMetadata": ["requestParams": ["chartParams": params], "availableChartsInfo": capabilities],
            songs ? "trackTypes" : "videos": [group],
        ]]]]]]]
    }

    static func capability(_ language: String) -> [String: Any] {
        ["chartType": "CHART_TYPE_VIDEOS_LOP", "chartPeriodType": "CHART_PERIOD_TYPE_WEEKLY",
         "chartAttribute": ["language": language], "latestEndDate": "2026-09-10"]
    }

    static func audioResponse(_ request: URLRequest) throws -> Data? {
        if request.httpMethod == "GET" { return bootstrap }
        guard request.url?.path.hasSuffix("/music/get_queue") == true else { return nil }
        let ids = try CatalogJSON.decode(request.httpBody ?? Data())["videoIds"].array.compactMap(\.string)
        return try data(["queueDatas": ids.map { id in
            ["content": radioTrack(id: id, title: id == hindiID ? "Tum Hi Ho" : "STAY", artist: id == hindiID ? "Arijit Singh" : "Justin Bieber")]
        }])
    }
}
