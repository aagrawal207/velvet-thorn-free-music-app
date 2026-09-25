import Foundation

enum CatalogAlbumDescriptionParser {
    static let maximumTextBytes = 32 * 1_024
    static let maximumDisplayCharacters = 2_400

    static func hasReadableHeader(_ root: CatalogJSON) -> Bool {
        root["contents"].isObject && CatalogText.clean(CatalogParser.pageHeaderRenderer(root)["title"].text) != nil
    }

    static func parse(_ root: CatalogJSON, id: String) -> AlbumDescription? {
        guard AlbumDescriptionIdentity.albumID(id) != nil else { return nil }
        let header = CatalogParser.pageHeaderRenderer(root)
        let credits = CatalogParser.albumHeaderCredits(header)
        let kind = header["subtitle"].text.components(separatedBy: CharacterSet(charactersIn: "•·"))
            .first.map(SearchRelevance.normalize) ?? ""
        guard let title = CatalogText.clean(header["title"].text), title.utf8.count <= 512,
              ["album", "soundtrack", "ep", "extended play"].contains(kind), !credits.isEmpty,
              credits.allSatisfy({ $0.name.utf8.count <= 256 }) else { return nil }

        let shelf = header["description"]["musicDescriptionShelfRenderer"]
        let description = shelf.isObject ? shelf["description"] : header["description"]
        let runs = description["runs"].array
        guard !runs.isEmpty, runs.count <= 64 else { return nil }
        let raw = description.text.replacingOccurrences(of: "\r\n", with: "\n")
        guard raw.utf8.count <= maximumTextBytes,
              let footer = raw.range(of: "\n\nFrom Wikipedia (", options: .backwards),
              let text = CatalogText.clean(String(raw[..<footer.lowerBound])), text.count >= 80,
              text.range(of: #"<[^>]+>|\[\[|\]\]"#, options: .regularExpression) == nil else { return nil }

        // The displayed URL labels are truncated. Only the footer's navigation endpoints carry the source links.
        var offset = 0
        var links: [URL] = []
        let footerOffset = raw.distance(from: raw.startIndex, to: footer.lowerBound)
        for run in runs {
            let runText = run["text"].text.replacingOccurrences(of: "\r\n", with: "\n")
            defer { offset += runText.count }
            if let destination = run["navigationEndpoint"]["urlEndpoint"]["url"].string {
                guard offset >= footerOffset, let url = publicURL(destination) else { return nil }
                links.append(url)
            }
        }
        guard links.count == 2, let articleTitle = wikipediaTitle(links[0]),
              let license = license(links[1]),
              raw[footer.lowerBound...].contains("under Creative Commons Attribution CC-BY-SA \(license.rawValue) ("),
              AlbumDescriptionIdentity.matches(text: text, title: title, credits: credits, articleTitle: articleTitle) else { return nil }

        let excerpt = AlbumDescriptionIdentity.excerpt(text, maximumCharacters: maximumDisplayCharacters)
        return AlbumDescription(albumID: id, albumTitle: title, credits: credits, text: excerpt.text,
                                sourceURL: links[0], license: license, licenseURL: links[1], isExcerpt: excerpt.shortened)
    }

    private static func publicURL(_ value: String) -> URL? {
        guard value.utf8.count <= 2_048, let url = URL(string: value), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private static func wikipediaTitle(_ url: URL) -> String? {
        guard url.host?.lowercased() == "en.wikipedia.org", url.path.hasPrefix("/wiki/"),
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding else { return nil }
        let title = String(path.dropFirst("/wiki/".count)).replacingOccurrences(of: "_", with: " ")
        guard !title.contains(":"), title.utf8.count <= 512 else { return nil }
        return CatalogText.clean(title)
    }

    private static func license(_ url: URL) -> AlbumDescription.License? {
        guard url.host?.lowercased() == "creativecommons.org" else { return nil }
        for license in [AlbumDescription.License.ccBYSA3, .ccBYSA4] {
            let base = "/licenses/by-sa/\(license.rawValue)"
            if [base, base + "/", base + "/legalcode", base + "/deed.en"].contains(url.path) { return license }
        }
        return nil
    }
}
