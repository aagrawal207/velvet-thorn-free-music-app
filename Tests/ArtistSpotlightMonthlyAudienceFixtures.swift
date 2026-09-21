import Foundation
@testable import GanaBajana

enum ArtistSpotlightMonthlyAudienceFixtures {
    static let artistID = "UCtJe0RYzgPddQXKtWduxz_w"
    static let name = "A. R. Rahman"

    // The live WEB_REMIX header puts its monthly label beside an unrelated subscription button.
    // Deliberately different fixture counts expose confusion between audience, subscribers, and plays.
    static func header(monthlyLabel: String? = "12.3M monthly audience") -> CatalogJSON {
        var fields: [String: CatalogJSON] = [
            "title": ["runs": [["text": .string(name)]]],
            "description": ["runs": [["text": "An artist biography with no monthly statistic."]]],
            "subscriptionButton": ["subscribeButtonRenderer": [
                "subscriberCountText": ["runs": [["text": "4.49M"]]],
                "subscriberCountWithSubscribeText": ["runs": [["text": "4.49M"]]],
                "longSubscriberCountText": ["runs": [["text": "4.49M subscribers"]]],
                "shortSubscriberCountText": ["runs": [["text": "4.49M"]]],
            ]],
        ]
        if let monthlyLabel {
            fields["monthlyListenerCount"] = ["runs": [["text": .string(monthlyLabel)]]]
        }
        return .object(fields)
    }

    static func response(header: CatalogJSON? = nil, monthlyLabel: String? = "12.3M monthly audience",
                         pageDescription: String? = nil, pageTitle: String = name) throws -> CatalogJSON {
        var root = try CatalogFixtures.json(CatalogFixtures.artistPage(id: artistID, name: name, songs: [
            CatalogFixtures.song(artist: name, artistID: artistID, plays: "1.2B plays"),
        ], related: [
            CatalogFixtures.collection(id: CatalogFixtures.arijitID, title: "Arijit Singh", type: "MUSIC_PAGE_TYPE_ARTIST",
                                       subtitle: "999M monthly audience"),
        ])).object
        root["header"] = ["musicImmersiveHeaderRenderer": header ?? Self.header(monthlyLabel: monthlyLabel)]
        if let pageDescription {
            root["microformat"] = ["microformatDataRenderer": ["title": .string(pageTitle), "description": .string(pageDescription)]]
        }
        return .object(root)
    }
}
