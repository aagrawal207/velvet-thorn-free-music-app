import Foundation

enum CatalogParser {
    /// Album-page metadata that rows inherit; album rows carry no artist column, so the header credits them.
    struct RowContext: Sendable {
        var albumTitle: String?
        var albumID: String?
        var credits: [ArtistCredit] = []
        var artworkURL: URL?
        /// Playlists list what their owner added: a music video or upload with no linked album recording stays
        /// as a video entry (`isAudioRecording == false`). Search, radio, artist and album pages keep audio only.
        var keepsVideoRows = false
    }

    /// Video entry types a playlist row may carry; podcasts stay excluded by `isPlayableRow`.
    private static let videoEntryTypes: Set<String> = ["MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC"]

    static func search(_ root: CatalogJSON, filter: SearchFilter, query: String? = nil) throws -> CatalogPage {
        try validate(root)
        var page = CatalogPage(title: filter.title)
        for (kind, renderer) in rows(root) {
            if filter == .songs {
                if let track = track(renderer, rendererKind: kind) { page.tracks.append(track) }
            } else if let collection = collection(renderer) {
                let expected: CollectionKind = switch filter {
                case .albums: .album
                case .artists: .artist
                default: .playlist
                }
                if collection.kind == expected { page.collections.append(collection) }
            }
        }
        page.tracks = CatalogText.uniqueTracks(page.tracks)
        page.collections = CatalogText.uniqueCollections(page.collections)
        page.continuation = continuation(root)
        page.correctedQuery = correctedQuery(root, query: query)
        return page
    }

    /// The provider's spelling correction ("Showing results for …" or "Did you mean …"), when it differs from
    /// the query that was sent; `originalQuery` in the response stands in when the caller has no query.
    static func correctedQuery(_ root: CatalogJSON, query: String? = nil) -> String? {
        for name in ["showingResultsForRenderer", "didYouMeanRenderer"] {
            for renderer in root.values(for: name) {
                guard let corrected = CatalogText.clean(renderer["correctedQuery"].text), corrected.utf8.count <= 4_096 else { continue }
                let original = CatalogText.clean(query) ?? CatalogText.clean(renderer["originalQuery"].text)
                if let original, original.lowercased() == corrected.lowercased() { continue }
                return corrected
            }
        }
        return nil
    }

    /// Song-row video IDs in provider order, including rows the strict parser dropped only for lacking an ATV
    /// confirmation. The extra IDs are unverified; get_queue must confirm them before they are shown.
    static func searchAudioCandidateIDs(_ root: CatalogJSON) -> [String] {
        var seen = Set<String>()
        return rows(root).compactMap { kind, renderer -> String? in
            if let recording = track(renderer, rendererKind: kind) { return recording.id }
            guard isPlayableRow(renderer), !isCollectionRow(renderer, rendererKind: kind), rowTitle(renderer) != nil else { return nil }
            return plainVideoID(renderer)
        }.filter { seen.insert($0).inserted }
    }

    /// Artist identity from the browse header; artist pages carry the name and banner there, not in rows.
    static func artistHeader(_ root: CatalogJSON) -> (name: String?, artworkURL: URL?, monthlyAudience: ArtistPage.MonthlyAudience?) {
        let header = artistHeaderRenderer(root)
        let name = CatalogText.clean(header["title"].text)
        var audience = monthlyAudience(header["monthlyListenerCount"].text, source: .headerCount)
            ?? monthlyAudience(header["description"].text, source: .headerDescription)
        let metadata = root["microformat"]["microformatDataRenderer"]
        if audience == nil, let name, let metadataName = CatalogText.clean(metadata["title"].text),
           name.caseInsensitiveCompare(metadataName) == .orderedSame {
            audience = monthlyAudience(metadata["description"].text, source: .pageDescription)
        }
        return (name, CatalogText.artwork(header["foregroundThumbnail"]) ?? CatalogText.artwork(header["thumbnail"]), audience)
    }

    private static func monthlyAudience(_ text: String, source: ArtistPage.MonthlyAudience.Source) -> ArtistPage.MonthlyAudience? {
        guard text.utf8.count <= 2_048 else { return nil }
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "•·")).compactMap(CatalogText.clean)
        let label: String
        if parts.count == 1 { label = parts[0] }
        else if parts.count == 2, parts[0].caseInsensitiveCompare("Artist") == .orderedSame { label = parts[1] }
        else { return nil }

        // The legacy monthlyListenerCount key currently labels an audience, not listeners.
        // Require the unit in the text; a bare count or a biography's incidental number is ambiguous.
        let pattern = #"^([0-9]+(?:,[0-9]{3})*(?:\.[0-9]+)?[kmbt]?)\s+monthly\s+(audience|listeners?)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let countRange = Range(match.range(at: 1), in: label),
              let unitRange = Range(match.range(at: 2), in: label),
              let value = PlayCountText.parseNumber(String(label[countRange])) else { return nil }
        let kind: ArtistPage.MonthlyAudience.Kind = label[unitRange].lowercased() == "audience" ? .audience : .listeners
        return ArtistPage.MonthlyAudience(value: value, label: label, kind: kind, source: source)
    }

    static func rowContext(_ root: CatalogJSON, id: String, inheriting inherited: RowContext? = nil) -> RowContext {
        guard id.hasPrefix("MPRE") || id.hasPrefix("MPAL") else { return RowContext(keepsVideoRows: id.hasPrefix("VL")) }
        let header = header(root)
        let title = CatalogText.clean(header["title"].text)
            ?? CatalogText.clean(root["microformat"]["microformatDataRenderer"]["title"].text)
        let credits = albumHeaderCredits(header)
        let previous = inherited?.albumID == id ? inherited : nil
        let inheritedCredits = previous?.credits ?? []
        return RowContext(albumTitle: previous?.albumTitle ?? title, albumID: id,
                          credits: inheritedCredits.isEmpty ? credits : inheritedCredits,
                          artworkURL: previous?.artworkURL ?? CatalogText.artwork(header))
    }

    static func albumHeaderCredits(_ header: CatalogJSON) -> [ArtistCredit] {
        artistRuns(header["straplineTextOne"]["runs"].array + header["straplineText"]["runs"].array
                   + header["subtitle"]["runs"].array)
    }

    static func browse(_ root: CatalogJSON, id: String, inheriting inherited: RowContext? = nil) throws -> CatalogPage {
        try validate(root)
        let header = header(root)
        let context = rowContext(root, id: id, inheriting: inherited)
        let title = context.albumTitle ?? CatalogText.clean(header["title"].text)
            ?? CatalogText.clean(root["microformat"]["microformatDataRenderer"]["title"].text)
        let isArtist = id.hasPrefix("UC") || id.hasPrefix("MPAD")
        var page = CatalogPage(title: title, credits: context.credits,
                               albumDescription: CatalogAlbumDescriptionParser.parse(root, id: id))
        for (kind, renderer) in rows(root, includeCarousels: isArtist) {
            if let track = track(renderer, rendererKind: kind, context: context) { page.tracks.append(track) }
            else if let collection = collection(renderer) { page.collections.append(collection) }
        }
        page.tracks = CatalogText.uniqueTracks(page.tracks)
        page.collections = CatalogText.uniqueCollections(page.collections)
        page.continuation = continuation(root)
        return page
    }

    /// Rows of a page whose context the caller fixes up front: account library pages (liked songs, history) keep
    /// music videos as video entries like playlists do and have no album header to inherit from.
    static func browse(_ root: CatalogJSON, context: RowContext) throws -> CatalogPage {
        try validate(root)
        var page = CatalogPage(title: CatalogText.clean(header(root)["title"].text)
            ?? CatalogText.clean(root["microformat"]["microformatDataRenderer"]["title"].text))
        for (kind, renderer) in rows(root, includeCarousels: false) {
            if let track = track(renderer, rendererKind: kind, context: context) { page.tracks.append(track) }
            else if let collection = collection(renderer) { page.collections.append(collection) }
        }
        page.tracks = CatalogText.uniqueTracks(page.tracks)
        page.collections = CatalogText.uniqueCollections(page.collections)
        page.continuation = continuation(root)
        return page
    }

    static func radio(_ root: CatalogJSON) throws -> [Track] {
        try validate(root)
        let queues = root.values(for: "playlistPanelRenderer") + root.values(for: "playlistPanelContinuation")
        guard !queues.isEmpty else { throw MusicServiceError.invalidResponse }
        return CatalogText.uniqueTracks(queues.flatMap { queue in
            rows(queue).compactMap { track($0.1, rendererKind: $0.0) }
        })
    }

    static func queue(_ root: CatalogJSON, inheriting context: RowContext = RowContext()) throws -> [Track] {
        guard root["queueDatas"] != .null else { throw MusicServiceError.invalidResponse }
        return CatalogText.uniqueTracks(root["queueDatas"].array.flatMap { entry in
            rows(entry["content"]).compactMap { track($0.1, rendererKind: $0.0, context: context) }
        })
    }

    /// Per browse row, the recordings that may represent it, best first: a confirmed audio row is itself; otherwise
    /// the credits link's album recording (an `MPTC` candidate that get_queue must confirm), then the row's own
    /// video entry when the page keeps those. Rows that contribute nothing are omitted.
    static func browseRowCandidates(_ root: CatalogJSON, inheriting context: RowContext = RowContext()) -> [[String]] {
        var seen = Set<String>()
        return rows(root, includeCarousels: false).compactMap { kind, renderer -> [String]? in
            let recording = track(renderer, rendererKind: kind, context: context)
            if let recording, recording.isAudioRecording == true { return seen.insert(recording.id).inserted ? [recording.id] : nil }
            var ids: [String] = []
            // Credits may identify the album recording behind an unavailable music clip.
            // These are candidates only; get_queue must confirm ATV metadata before use.
            for browse in renderer.values(for: "browseEndpoint") {
                guard browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string == "MUSIC_PAGE_TYPE_TRACK_CREDITS",
                      let id = browse["browseId"].string, id.hasPrefix("MPTC"),
                      let candidate = CatalogText.videoID(String(id.dropFirst(4))) else { continue }
                ids.append(candidate)
                break
            }
            if let recording { ids.append(recording.id) }
            let fresh = ids.filter { seen.insert($0).inserted }
            return fresh.isEmpty ? nil : fresh
        }
    }

    /// The audio-only candidate order of a browse page: confirmed rows and credits-linked album recordings.
    static func audioCandidateIDs(_ root: CatalogJSON) -> [String] {
        browseRowCandidates(root).flatMap(\.self)
    }

    /// A validated audio row may have replaced an album clip; the clip's explicit credits link can carry
    /// the provider's song total, but a same-title search result or an upload's views cannot.
    static func enrichPlayCounts(_ tracks: [Track], from root: CatalogJSON) -> [Track] {
        var byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var matched = Set<String>()
        for (kind, renderer) in rows(root) {
            guard isPlayableRow(renderer), !isCollectionRow(renderer, rendererKind: kind),
                  let title = rowTitle(renderer), let count = playCount(renderer) else { continue }
            let primaryID = plainVideoID(renderer)
            let links = Set(renderer.values(for: "browseEndpoint").compactMap { browse -> String? in
                guard browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string == "MUSIC_PAGE_TYPE_TRACK_CREDITS",
                      let id = browse["browseId"].string, id.hasPrefix("MPTC") else { return nil }
                return CatalogText.videoID(String(id.dropFirst(4)))
            })
            let ids = [primaryID].compactMap { $0 } + (links.count == 1 ? Array(links) : [])
            let metadata = Array(flexTexts(renderer).dropFirst()) + [renderer["longBylineText"], renderer["subtitle"]]
            let credits = artistRuns(metadata.flatMap { $0["runs"].array })
            for id in ids where !matched.contains(id) {
                guard var track = byID[id], track.isAudioRecording == true,
                      countMatches(track, title: title, credits: credits, requiresCredits: id != primaryID) else { continue }
                track.playCount = count
                byID[id] = track
                matched.insert(id)
            }
        }
        return tracks.map { byID[$0.id] ?? $0 }
    }

    private static func countMatches(_ track: Track, title: String, credits: [ArtistCredit], requiresCredits: Bool) -> Bool {
        let expected = SearchRelevance.normalize(LyricsMatcher.cleanTitle(title, artists: credits.map(\.name)))
        guard !expected.isEmpty,
              expected == SearchRelevance.normalize(LyricsMatcher.cleanTitle(track.title, artists: track.artists)),
              !requiresCredits || !credits.isEmpty else { return false }
        return credits.allSatisfy { credit in
            track.credits.contains { actual in
                if let left = credit.id, let right = actual.id { return left == right }
                return SearchRelevance.normalize(credit.name) == SearchRelevance.normalize(actual.name)
            }
        }
    }

    static func continuation(_ root: CatalogJSON) -> String? {
        let containers = ["musicShelfContinuation", "musicPlaylistShelfContinuation", "playlistPanelContinuation",
                          "musicPlaylistShelfRenderer", "musicShelfRenderer", "playlistPanelRenderer"]
        for name in containers {
            for container in root.values(for: name) {
                for data in container["continuations"].array {
                    if let token = token(data["nextContinuationData"]["continuation"])
                        ?? token(data["nextRadioContinuationData"]["continuation"]) { return token }
                }
                if let token = itemContinuation(container["contents"]) { return token }
            }
        }
        for action in root.values(for: "appendContinuationItemsAction") {
            if let token = itemContinuation(action["continuationItems"]) { return token }
        }
        return nil
    }

    private static func itemContinuation(_ contents: CatalogJSON) -> String? {
        for item in contents.array.reversed() {
            let endpoint = item["continuationItemRenderer"]["continuationEndpoint"]
            if let token = token(endpoint["continuationCommand"]["token"]) { return token }
            for command in endpoint["commandExecutorCommand"]["commands"].array {
                if command["continuationCommand"]["request"].string == "CONTINUATION_REQUEST_TYPE_BROWSE",
                   let token = token(command["continuationCommand"]["token"]) { return token }
            }
        }
        return nil
    }

    private static func token(_ value: CatalogJSON) -> String? {
        guard let text = CatalogText.clean(value.string), text.utf8.count <= 65_536 else { return nil }
        return text
    }

    private static func validate(_ root: CatalogJSON) throws {
        guard root.isObject, root["error"] == .null,
              root["contents"].isObject || root["continuationContents"].isObject
                || !root["onResponseReceivedActions"].array.isEmpty
                || !root["onResponseReceivedEndpoints"].array.isEmpty else { throw MusicServiceError.invalidResponse }
    }

    private static func rows(_ root: CatalogJSON, includeCarousels: Bool = true) -> [(String, CatalogJSON)] {
        var result: [(String, CatalogJSON)] = []
        collect(root, includeCarousels: includeCarousels, depth: 0, result: &result)
        return result
    }

    private static func collect(_ node: CatalogJSON, includeCarousels: Bool, depth: Int,
                                result: inout [(String, CatalogJSON)]) {
        guard depth < 32, result.count < 2_000 else { return }
        if !includeCarousels && node["musicCarouselShelfRenderer"].isObject { return }
        if let wrapper = node.object["playlistPanelVideoWrapperRenderer"] {
            let candidates = wrapper.values(for: "playlistPanelVideoRenderer")
            if let primary = candidates.first(where: { videoType($0) == "MUSIC_VIDEO_TYPE_ATV" }) ?? candidates.first {
                result.append(("playlistPanelVideoRenderer", primary))
            }
            return
        }
        for name in ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "playlistPanelVideoRenderer"] {
            if let renderer = node.object[name] {
                result.append((name, renderer))
                return
            }
        }
        if let card = node.object["musicCardShelfRenderer"] {
            result.append(("musicCardShelfRenderer", card))
            collect(card["contents"], includeCarousels: includeCarousels, depth: depth + 1, result: &result)
            return
        }
        switch node {
        case .array(let nodes):
            for child in nodes { collect(child, includeCarousels: includeCarousels, depth: depth + 1, result: &result) }
        case .object(let object):
            for key in object.keys.sorted() where !nonContentKeys.contains(key) {
                guard let child = object[key] else { continue }
                if key == "tabs" {
                    let tabs = child.array
                    let selected = tabs.first { $0["tabRenderer"]["selected"].bool == true }
                        ?? tabs.first { $0["tabRenderer"]["content"] != .null }
                    if let selected { collect(selected, includeCarousels: includeCarousels, depth: depth + 1, result: &result) }
                } else {
                    collect(child, includeCarousels: includeCarousels, depth: depth + 1, result: &result)
                }
            }
        default: break
        }
    }

    private static let nonContentKeys: Set<String> = [
        "header", "menu", "overlay", "thumbnail", "thumbnails", "background", "frameworkUpdates", "microformat",
        "trackingParams", "buttons", "navigationEndpoint", "onTap", "continuations", "subheaders", "footer",
    ]

    private static let headerRenderers = ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicImmersiveHeaderRenderer",
                                          "musicVisualHeaderRenderer", "musicHeaderRenderer"]

    private static func header(_ root: CatalogJSON) -> CatalogJSON {
        for name in headerRenderers {
            if let header = root.values(for: name).first { return header }
        }
        return .null
    }

    static func artistHeaderRenderer(_ root: CatalogJSON) -> CatalogJSON {
        pageHeaderRenderer(root)
    }

    static func pageHeaderRenderer(_ root: CatalogJSON) -> CatalogJSON {
        func directHeader(_ container: CatalogJSON) -> CatalogJSON? {
            for name in headerRenderers where container[name].isObject { return container[name] }
            return nil
        }
        if let header = directHeader(root["header"]) { return header }
        // Responsive headers can be top-level items in the selected tab. Descending into shelves
        // would attribute a related artist's audience or another album's description to this page.
        for layout in ["singleColumnBrowseResultsRenderer", "twoColumnBrowseResultsRenderer"] {
            let tabs = root["contents"][layout]["tabs"].array
            let tab = tabs.first { $0["tabRenderer"]["selected"].bool == true }
                ?? tabs.first { $0["tabRenderer"]["content"].isObject }
            guard let tab else { continue }
            let content = tab["tabRenderer"]["content"]["sectionListRenderer"]
            if let header = directHeader(content["header"]) { return header }
            for item in content["contents"].array {
                if let header = directHeader(item) { return header }
            }
        }
        return .null
    }

    private static func track(_ renderer: CatalogJSON, rendererKind: String, context: RowContext = RowContext()) -> Track? {
        guard isPlayableRow(renderer), !isCollectionRow(renderer, rendererKind: rendererKind) else { return nil }
        let flex = flexTexts(renderer)
        let title = rowTitle(renderer)
        let navigation = primaryNavigation(renderer)
        let watches = playbackWatches(renderer)
        let audio = watches.first { watchType($0) == "MUSIC_VIDEO_TYPE_ATV" }
        let confirmedAudio = audio != nil || CatalogText.videoID(renderer["atvExternalVideoId"].string) != nil
            || renderer["musicVideoType"].string == "MUSIC_VIDEO_TYPE_ATV"
        let type = videoType(renderer)
        let isVideoEntry = type.map(videoEntryTypes.contains) == true && context.keepsVideoRows
        guard confirmedAudio || isVideoEntry
            || ((type == nil || type == "MUSIC_VIDEO_TYPE_UNKNOWN") && context.albumID != nil) else { return nil }
        let id = CatalogText.videoID(renderer["atvExternalVideoId"].string)
            ?? CatalogText.videoID(audio?["videoId"].string)
            ?? plainVideoID(renderer)
        guard let id, let title else { return nil }
        let primaryID = renderer["videoId"].string ?? renderer["playlistItemData"]["videoId"].string
            ?? navigation["watchEndpoint"]["videoId"].string
        let changedRecording = primaryID != nil && primaryID != id

        let metadataTexts = Array(flex.dropFirst()) + [renderer["longBylineText"], renderer["subtitle"]]
        let runs = metadataTexts.flatMap { $0["runs"].array }
        var credits = artistRuns(runs)
        if credits.isEmpty {
            let fallback = CatalogText.clean(renderer["shortBylineText"].text)
                ?? metadataTexts.compactMap { unlinkedArtist($0["runs"].array) }.first
            if let fallback { credits = [ArtistCredit(name: fallback)] }
        }
        if credits.isEmpty { credits = context.credits }
        // Providers leave English features unlinked ("Good Life (feat. T-Pain)" credits only Kanye West).
        var seen = Set(credits.map { $0.name.lowercased() })
        credits += ArtistCredit.featured(inTitle: title).filter { seen.insert($0.name.lowercased()).inserted }
        let album = runs.first { run in
            let id = run["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
            return id.hasPrefix("MPRE") || id.hasPrefix("MPAL")
        }
        let fixed = renderer["fixedColumns"].array.map { $0["musicResponsiveListItemFixedColumnRenderer"]["text"].text }
        let runTexts = runs.compactMap { $0["text"].string }
        let duration = ([renderer["lengthText"].text] + fixed + runTexts).compactMap(CatalogText.duration).first
        let playCount = Self.playCount(renderer)
        let badges = renderer["badges"].values(for: "iconType").compactMap(\.string)
            + renderer["subtitleBadges"].values(for: "iconType").compactMap(\.string)
        let explicit = badges.contains { $0.contains("EXPLICIT") }
            || renderer["badges"].values(for: "label").contains { $0.string?.lowercased() == "explicit" }
        return Track(id: id, title: title, credits: credits,
                     albumTitle: album.flatMap { CatalogText.clean($0["text"].string) } ?? context.albumTitle,
                     albumID: album?["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? context.albumID,
                     duration: changedRecording ? nil : duration,
                     artworkURL: changedRecording ? (context.artworkURL ?? CatalogText.artwork(.null, videoID: id))
                        : (CatalogText.artwork(renderer) ?? context.artworkURL ?? CatalogText.artwork(.null, videoID: id)),
                     isExplicit: explicit, isAudioRecording: confirmedAudio ? true : (isVideoEntry ? false : nil),
                     playCount: changedRecording ? nil : playCount)
    }

    private static func playCount(_ renderer: CatalogJSON) -> Int64? {
        let fields = Array(flexTexts(renderer).dropFirst()) + [renderer["longBylineText"], renderer["subtitle"]]
            + renderer["fixedColumns"].array.map { $0["musicResponsiveListItemFixedColumnRenderer"]["text"] }
        for field in fields {
            let runs = field["runs"].array
            // Linked artist/album names are metadata, even when their literal titles look like count labels.
            let text = runs.isEmpty ? field.text : runs.map { $0["navigationEndpoint"] == .null ? $0["text"].text : " • " }.joined()
            for part in text.components(separatedBy: CharacterSet(charactersIn: "•·")) {
                if let count = PlayCountText.parse(part, unit: .plays) { return count }
            }
            if CatalogText.clean(text) == nil,
               let count = PlayCountText.parse(field["accessibility"]["accessibilityData"]["label"].text, unit: .plays) { return count }
        }
        return nil
    }

    private static func collection(_ renderer: CatalogJSON) -> MusicCollection? {
        guard let (id, kind) = collectionID(renderer), let title = rowTitle(renderer) else { return nil }
        let subtitle = CatalogText.clean(renderer["subtitle"].text)
            ?? flexTexts(renderer).dropFirst().compactMap { CatalogText.clean($0.text) }.joined(separator: " · ")
        return MusicCollection(id: id, title: title, subtitle: subtitle, artworkURL: CatalogText.artwork(renderer), kind: kind)
    }

    private static func isPlayableRow(_ renderer: CatalogJSON) -> Bool {
        renderer["isPlayable"].bool != false && renderer["isAvailable"].bool != false
            && renderer["musicItemRendererDisplayPolicy"].string != "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"
            && videoType(renderer) != "MUSIC_VIDEO_TYPE_PODCAST_EPISODE"
    }

    private static func isCollectionRow(_ renderer: CatalogJSON, rendererKind: String) -> Bool {
        let navigation = primaryNavigation(renderer)
        let pageType = navigation["browseEndpoint"]["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
        if let pageType, ["MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_PLAYLIST"].contains(pageType) { return true }
        return rendererKind != "playlistPanelVideoRenderer" && collectionID(renderer) != nil
    }

    private static func rowTitle(_ renderer: CatalogJSON) -> String? {
        CatalogText.clean(renderer["title"].text) ?? flexTexts(renderer).first.flatMap { CatalogText.clean($0.text) }
    }

    /// The row's own video ID, without the ATV substitutions `track` applies.
    private static func plainVideoID(_ renderer: CatalogJSON) -> String? {
        CatalogText.videoID(renderer["videoId"].string)
            ?? CatalogText.videoID(renderer["playlistItemData"]["videoId"].string)
            ?? CatalogText.videoID(primaryNavigation(renderer)["watchEndpoint"]["videoId"].string)
            ?? playbackWatches(renderer).compactMap { CatalogText.videoID($0["videoId"].string) }.first
    }

    private static func collectionID(_ renderer: CatalogJSON) -> (String, CollectionKind)? {
        let navigation = primaryNavigation(renderer)
        if let id = CatalogText.identifier(navigation["browseEndpoint"]["browseId"].string) {
            if id.hasPrefix("UC") { return (id, .artist) }
            if id.hasPrefix("MPRE") || id.hasPrefix("MPAL") { return (id, .album) }
            if id.hasPrefix("VL") { return (id, .playlist) }
        }
        let watch = navigation["watchPlaylistEndpoint"] != .null ? navigation["watchPlaylistEndpoint"] : navigation["watchEndpoint"]
        if watch["videoId"] == .null, let id = CatalogText.identifier(watch["playlistId"].string),
           id.hasPrefix("PL") || id.hasPrefix("RDCLAK") || id.hasPrefix("OLAK") {
            return ("VL" + id, .playlist)
        }
        return nil
    }

    private static func primaryNavigation(_ renderer: CatalogJSON) -> CatalogJSON {
        if renderer["navigationEndpoint"].isObject { return renderer["navigationEndpoint"] }
        for run in renderer["title"]["runs"].array + (flexTexts(renderer).first?["runs"].array ?? []) {
            if run["navigationEndpoint"].isObject { return run["navigationEndpoint"] }
        }
        return renderer["onTap"]
    }

    private static func flexTexts(_ renderer: CatalogJSON) -> [CatalogJSON] {
        renderer["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
    }

    /// Every artist-linked run as its own credit, in provider order. Each run carries its own browseId, so a
    /// "Pritam, Shashwat Singh & Arijit Singh" byline yields three linked credits rather than one id.
    private static func artistRuns(_ runs: [CatalogJSON]) -> [ArtistCredit] {
        var seen = Set<String>()
        return runs.compactMap { run -> ArtistCredit? in
            let browse = run["navigationEndpoint"]["browseEndpoint"]
            let id = CatalogText.artistID(browse["browseId"].string)
            let linksArtist = id != nil
                || browse["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string == "MUSIC_PAGE_TYPE_ARTIST"
            guard linksArtist, let name = CatalogText.clean(run["text"].string), seen.insert(name.lowercased()).inserted else { return nil }
            return ArtistCredit(name: name, id: id)
        }
    }

    private static func unlinkedArtist(_ runs: [CatalogJSON]) -> String? {
        let labels: Set<String> = ["song", "video", "album", "single", "ep", "playlist", "artist"]
        for run in runs {
            guard let text = CatalogText.clean(run["text"].string), text != "•", text != "&", text != ",",
                  run["navigationEndpoint"] == .null, !labels.contains(text.lowercased()),
                  CatalogText.duration(text) == nil, Double(text) == nil,
                  !text.lowercased().contains("plays"), !text.lowercased().contains("views"),
                  !text.lowercased().contains("subscribers") else { continue }
            return text
        }
        return nil
    }

    private static func watchType(_ watch: CatalogJSON) -> String? {
        watch["watchEndpointMusicSupportedConfigs"]["watchEndpointMusicConfig"]["musicVideoType"].string ?? watch["musicVideoType"].string
    }

    private static func playbackWatches(_ renderer: CatalogJSON) -> [CatalogJSON] {
        [renderer["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"],
         primaryNavigation(renderer)["watchEndpoint"], renderer["onTap"]["watchEndpoint"]].filter(\.isObject)
    }

    private static func videoType(_ renderer: CatalogJSON) -> String? {
        let types = playbackWatches(renderer).compactMap(watchType) + [renderer["musicVideoType"].string].compactMap { $0 }
        return types.contains("MUSIC_VIDEO_TYPE_ATV") ? "MUSIC_VIDEO_TYPE_ATV" : types.first
    }
}
