import Foundation
@testable import GanaBajana

enum AlbumDescriptionFixtures {
    static let id = CatalogFixtures.graduationID
    static let otherID = CatalogFixtures.albumID
    static let title = "Paper Satellites"
    static let artist = "Test Singer"
    static let source = "https://en.wikipedia.org/wiki/Paper_Satellites_(album)"
    static let license = "https://creativecommons.org/licenses/by-sa/3.0/legalcode"
    static let text = "Paper Satellites is a studio album by Test Singer. This synthetic paragraph exercises album descriptions and their source attribution."

    static func collection(id: String = AlbumDescriptionFixtures.id, title: String = AlbumDescriptionFixtures.title) -> MusicCollection {
        MusicCollection(id: id, title: title, kind: .album)
    }

    static func document(id: String = AlbumDescriptionFixtures.id, title: String = AlbumDescriptionFixtures.title) -> AlbumDescription {
        AlbumDescription(albumID: id, albumTitle: title, credits: [ArtistCredit(name: artist, id: CatalogFixtures.kanyeID)],
                         text: text, sourceURL: URL(string: source)!, license: .ccBYSA3,
                         licenseURL: URL(string: license)!, isExcerpt: false)
    }

    static func description(text: String = AlbumDescriptionFixtures.text, source: String = AlbumDescriptionFixtures.source,
                            license: String = AlbumDescriptionFixtures.license,
                            version: String = "3.0") -> [String: Any] {
        ["musicDescriptionShelfRenderer": ["description": ["runs": [
            ["text": text + "\n\nFrom Wikipedia ("],
            ["text": "https://en.wikipedia.org/wiki/Paper...", "navigationEndpoint": ["urlEndpoint": ["url": source]]],
            ["text": ") under Creative Commons Attribution CC-BY-SA \(version) ("],
            ["text": "https://creativecommons.org/licenses/...", "navigationEndpoint": ["urlEndpoint": ["url": license]]],
            ["text": ")"],
        ]]]]
    }

    static func header(title: String = AlbumDescriptionFixtures.title, artist: String = AlbumDescriptionFixtures.artist,
                       text: String = AlbumDescriptionFixtures.text, source: String = AlbumDescriptionFixtures.source,
                       license: String = AlbumDescriptionFixtures.license, version: String = "3.0") -> [String: Any] {
        var header = CatalogFixtures.albumHeader(title: title, artist: artist)
        header["description"] = description(text: text, source: source, license: license, version: version)
        return header
    }

    static func page(header: [String: Any] = AlbumDescriptionFixtures.header(), continuation: String? = nil) throws -> CatalogJSON {
        try CatalogFixtures.json(CatalogFixtures.browse([CatalogFixtures.albumSong()], continuation: continuation, header: header))
    }

    static func page(selectedHeader: CatalogJSON, unselectedHeader: CatalogJSON? = nil,
                     relatedHeader: CatalogJSON? = nil) -> CatalogJSON {
        var contents: [CatalogJSON] = []
        if let relatedHeader {
            contents.append(["musicCarouselShelfRenderer": ["contents": [["musicResponsiveHeaderRenderer": relatedHeader]]]])
        }
        contents.append(["musicResponsiveHeaderRenderer": selectedHeader])
        var tabs: [CatalogJSON] = []
        if let unselectedHeader {
            tabs.append(["tabRenderer": ["selected": false, "content": ["sectionListRenderer": ["contents": [
                ["musicResponsiveHeaderRenderer": unselectedHeader],
            ]]]]])
        }
        tabs.append(["tabRenderer": ["selected": true, "content": ["sectionListRenderer": ["contents": .array(contents)]]]])
        return ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": .array(tabs)]]]
    }

    static func replacingCredits(in header: CatalogJSON, with names: [String]) throws -> CatalogJSON {
        var result = header.object
        result["straplineTextOne"] = try CatalogFixtures.json([
            "runs": CatalogFixtures.artistRuns(names.map { (name: $0, id: CatalogFixtures.arijitID) }),
        ])
        return .object(result)
    }
}
