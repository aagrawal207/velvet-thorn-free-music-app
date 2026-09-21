import XCTest
@testable import GanaBajana

final class SearchRelevanceTests: XCTestCase {
    private let rahman = MusicCollection(id: "UCtJe0RYzgPddQXKtWduxz_w", title: "A. R. Rahman", subtitle: "Artist • 598M monthly audience", kind: .artist)
    private let arijit = MusicCollection(id: CatalogFixtures.arijitID, title: "Arijit Singh", subtitle: "Artist • 665M monthly audience", kind: .artist)

    func testNormalizeFoldsCaseDiacriticsPunctuationAndInitials() {
        for text in ["A. R. Rahman", "A.R. Rahman", "AR Rahman", "a r RAHMAN", " A.R.  Rahman! "] {
            XCTAssertEqual(SearchRelevance.normalize(text), "ar rahman", text)
        }
        XCTAssertEqual(SearchRelevance.normalize("Beyoncé – Café"), "beyonce cafe")
        XCTAssertEqual(SearchRelevance.normalize("S.P. Balasubrahmanyam"), "sp balasubrahmanyam")
        XCTAssertEqual(SearchRelevance.normalize("Jay Z"), "jay z")
        XCTAssertEqual(SearchRelevance.normalize("K.K."), "kk")
        XCTAssertEqual(SearchRelevance.normalize("Tum Hi Ho (From \"Aashiqui 2\")"), "tum hi ho from aashiqui 2")
        XCTAssertEqual(SearchRelevance.normalize("तुम ही हो"), "तुम ही हो", "Indic vowel signs are not diacritics to strip or initials to merge")
        XCTAssertEqual(SearchRelevance.normalize("  "), "")
        XCTAssertEqual(SearchRelevance.normalize(SearchRelevance.normalize("A. R. Rahman")), "ar rahman", "Normalization is idempotent")
    }

    func testSimilarityAcceptsTyposButNotDifferentNames() {
        XCTAssertGreaterThanOrEqual(SearchRelevance.similarity("arjit singh", "arijit singh"), 0.85)
        XCTAssertGreaterThanOrEqual(SearchRelevance.similarity("Arjit Singh", "Arijit Singh"), 0.85)
        XCTAssertLessThan(SearchRelevance.similarity("ar rahman", "abdel rahman el ousi"), 0.7)
        XCTAssertLessThan(SearchRelevance.similarity("tum hi ho", "arijit singh"), 0.5)
        XCTAssertEqual(SearchRelevance.similarity("A. R. Rahman", "A.R. Rahman"), 1)
        XCTAssertEqual(SearchRelevance.similarity("", ""), 1)
        XCTAssertEqual(SearchRelevance.similarity("", "arijit"), 0)
        XCTAssertEqual(SearchRelevance.similarity("abc", "xyz"), 0)
    }

    func testTiersDistinguishArtistOwnershipFromTokenOverlap() {
        let byID = Track(id: "Fi3GovijpWA", title: "Tere Bina", artists: ["A.R. Rahman", "Chinmayi"], artistID: "UCYiryVpO13KQxZT5UMjEdsQ")
        XCTAssertEqual(SearchRelevance.tier(of: byID, query: "A. R. RAHMAN", artist: rahman), 0, "A duplicate channel id still matches by credited name")
        let exactID = Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", artists: ["Arijit Singh"], artistID: CatalogFixtures.arijitID)
        XCTAssertEqual(SearchRelevance.tier(of: exactID, query: "arjit", artist: arijit), 0)
        let quran = Track(id: "OaiOf0-kISM", title: "Al Rahman", artists: ["Abdel Rahman el Ousi"], artistID: "UC1CwoEojJpBZw8gnaZUhMVQ")
        XCTAssertEqual(SearchRelevance.tier(of: quran, query: "A. R. RAHMAN", artist: rahman), 2)
        XCTAssertEqual(SearchRelevance.tier(of: quran, query: "A. R. RAHMAN", artist: nil), 2)
        let credited = Track(id: "NdAHrwXQIOU", title: "Jai Jai Ram", artists: ["A.R. Rahman", "Shreya Ghoshal"])
        XCTAssertEqual(SearchRelevance.tier(of: credited, query: "A. R. RAHMAN", artist: nil), 1)
        let unrelated = Track(id: "3XU3mFXMuZU", title: "Kehna Hi Kya", artists: ["Chitra"])
        XCTAssertEqual(SearchRelevance.tier(of: unrelated, query: "A. R. RAHMAN", artist: rahman), 3)
        XCTAssertEqual(SearchRelevance.tier(of: exactID, query: "Tum Hi Ho", artist: nil), 1)
        XCTAssertEqual(SearchRelevance.tier(of: exactID, query: "tum hi hoo", artist: nil), 2)
        XCTAssertEqual(SearchRelevance.tier(of: exactID, query: "", artist: nil), 3)
    }

    func testRankMovesTheQueriedArtistFirstAndDropsNoiseOnlyWhenAnArtistMatched() {
        let recitation1 = Track(id: "OaiOf0-kISM", title: "Al Rahman", artists: ["Abdel Rahman el Ousi"])
        let recitation2 = Track(id: "-aid8eFB1R4", title: "Al Rahman", artists: ["Mashary Rashed Al AFasy"])
        let surah = Track(id: "5FOeEV4CUCY", title: "Surah Ar-Rahman", artists: ["Kari Abdul Baset"])
        let singer = Track(id: "3XU3mFXMuZU", title: "Kehna Hi Kya", artists: ["Chitra"])
        let own = (1...9).map { Track(id: "rahman-\($0)-ID", title: "Song \($0)", artists: ["A.R. Rahman"]) }
        let provider = [recitation1, own[0], recitation2, surah, own[1], own[2], singer, own[3], own[4], own[5], own[6], own[7], own[8]]

        let ranked = SearchRelevance.rank(provider, query: "A. R. RAHMAN", artist: rahman)
        XCTAssertEqual(ranked.map(\.id), own.map(\.id) + [surah.id],
                       "Nine tier-0 tracks fill the page: partial matches and noise are dropped, a full textual match trails")

        let sparse = SearchRelevance.rank([recitation1, own[0], recitation2, singer, own[1]], query: "A. R. RAHMAN", artist: rahman)
        XCTAssertEqual(sparse.map(\.id), [own[0].id, own[1].id, recitation1.id, recitation2.id],
                       "Partial matches survive behind a thin artist tier; unrelated rows never do")

        let unmatched = SearchRelevance.rank(provider, query: "A. R. RAHMAN", artist: nil)
        XCTAssertEqual(unmatched.count, provider.count, "Without an artist nothing is dropped")
        XCTAssertEqual(unmatched.map(\.id), [own[0], surah, own[1], own[2], own[3], own[4], own[5], own[6], own[7], own[8],
                                             recitation1, recitation2, singer].map(\.id),
                       "Tiers lead in order and provider order is kept inside each tier")
    }

    func testMatchedArtistRequiresAnArtistCloseToTheQueryOrItsCorrection() {
        let smallChannel = MusicCollection(id: "UCXFuPQejJsFOcJU1esf91qQ", title: "Arijit Singh", subtitle: "Artist • 5 subscribers", kind: .artist)
        let playlist = MusicCollection(id: "VLPL123", title: "Arjit Singh", subtitle: "Playlist", kind: .playlist)
        let atif = MusicCollection(id: "UCVGomUS__PL0c4jDXa0QwXA", title: "Atif Aslam", subtitle: "Artist", kind: .artist)
        XCTAssertEqual(SearchRelevance.matchedArtist(in: [playlist, atif, arijit, smallChannel], query: "Arjit Singh")?.id, arijit.id)
        XCTAssertEqual(SearchRelevance.matchedArtist(in: [atif, arijit], query: "Arjt Sing", correctedQuery: "Arijit Singh")?.id, arijit.id)
        XCTAssertEqual(SearchRelevance.matchedArtist(in: [rahman, atif], query: "A.R. RAHMAN")?.id, rahman.id)
        XCTAssertEqual(SearchRelevance.matchedArtist(in: [atif, arijit], query: "Arijit")?.id, arijit.id, "A first name alone names the artist")
        XCTAssertNil(SearchRelevance.matchedArtist(in: [arijit, atif], query: "Tum Hi Ho"))
        XCTAssertNil(SearchRelevance.matchedArtist(in: [rahman], query: "AR"), "Two letters are too little to claim an artist")
        XCTAssertNil(SearchRelevance.matchedArtist(in: [playlist], query: "Arjit Singh"))
        XCTAssertNil(SearchRelevance.matchedArtist(in: [arijit], query: "   "))
    }
}
