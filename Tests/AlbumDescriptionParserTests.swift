import XCTest
@testable import GanaBajana

@MainActor
final class AlbumDescriptionParserTests: XCTestCase {
    func testRecordedEnglishAndHindiAlbumHeadersRetainTheirActualAttribution() throws {
        let cases = [("album-description-graduation", "MPREb_KCNeTnK02S7", "Graduation", ["Kanye West"]),
                     ("album-description-aashiqui-2", "MPREb_E4GfUXfDfhy", "Aashiqui 2", ["Jeet Gannguli", "Ankit Tiwari", "Mithoon"])]
        for (file, id, title, artists) in cases {
            let root = try recordedPage(file)
            let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: id))
            XCTAssertTrue(description.text.hasPrefix(title + " is "))
            XCTAssertEqual(description.credits.map(\.name), artists)
            XCTAssertTrue(description.credits.allSatisfy { $0.id != nil })
            XCTAssertEqual(description.licenseURL.absoluteString, AlbumDescriptionFixtures.license)
            XCTAssertEqual(description.license, .ccBYSA3)
            XCTAssertFalse(description.text.contains("https://"))
        }
    }

    func testAlbumHeaderPreservesGenuineTextLinkedAttributionAndSuppliedLicense() throws {
        let root = try AlbumDescriptionFixtures.page()
        let page = try CatalogParser.browse(root, id: AlbumDescriptionFixtures.id)
        let description = try XCTUnwrap(page.albumDescription)
        XCTAssertEqual(description.text, AlbumDescriptionFixtures.text)
        XCTAssertEqual(description.albumID, AlbumDescriptionFixtures.id)
        XCTAssertEqual(description.albumTitle, AlbumDescriptionFixtures.title)
        XCTAssertEqual(description.credits.map(\.name), [AlbumDescriptionFixtures.artist])
        XCTAssertEqual(description.sourceURL.absoluteString, AlbumDescriptionFixtures.source)
        XCTAssertEqual(description.licenseURL.absoluteString, AlbumDescriptionFixtures.license)
        XCTAssertEqual(description.license, .ccBYSA3)
        XCTAssertEqual(description.attribution, "Wikipedia via YouTube Music")
        XCTAssertFalse(description.text.contains("From Wikipedia"))
        XCTAssertFalse(description.text.contains("https://"))
        XCTAssertFalse(description.isExcerpt)
        XCTAssertEqual(page.tracks.map(\.id), [CatalogFixtures.hindiID])
    }

    func testLicenseFourIsOnlyUsedWhenTheProviderActuallySuppliesIt() throws {
        for suffix in ["", "/", "/legalcode", "/deed.en"] {
            let url = "https://creativecommons.org/licenses/by-sa/4.0" + suffix
            let matching = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(license: url, version: "4.0"))
            XCTAssertEqual(CatalogAlbumDescriptionParser.parse(matching, id: AlbumDescriptionFixtures.id)?.license, .ccBYSA4)
            let conflicting = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(license: url))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(conflicting, id: AlbumDescriptionFixtures.id))
        }
    }

    func testMetadataSubtitlesArtistBiosAndOtherCollectionKindsAreNotDescriptions() throws {
        var header = CatalogFixtures.albumHeader(title: AlbumDescriptionFixtures.title, artist: AlbumDescriptionFixtures.artist)
        header["description"] = CatalogFixtures.text("Album • Test Singer")
        var root = try AlbumDescriptionFixtures.page(header: header).object
        root["microformat"] = ["microformatDataRenderer": ["title": .string(AlbumDescriptionFixtures.title),
                                                         "description": .string(AlbumDescriptionFixtures.text)]]
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(.object(root), id: AlbumDescriptionFixtures.id))
        let attributed = try AlbumDescriptionFixtures.page()
        for id in [CatalogFixtures.kanyeID, "MPADtest", "VLtest", "PLtest", "", "MPREbad/id"] {
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(attributed, id: id), id)
        }
        XCTAssertNil(try CatalogParser.search(CatalogFixtures.json(CatalogFixtures.search([])), filter: .albums).albumDescription)
        XCTAssertNil(CatalogPage().albumDescription, "Older catalog implementations need no new argument")
    }

    func testDescriptionsInRelatedShelvesOrAnUnselectedTabAreNotAdopted() throws {
        let foreign = try CatalogFixtures.json(AlbumDescriptionFixtures.header())
        let header: CatalogJSON = ["musicResponsiveHeaderRenderer": foreign]
        let root: CatalogJSON = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
            ["tabRenderer": ["selected": true, "content": ["sectionListRenderer": ["contents": [
                ["musicCarouselShelfRenderer": ["contents": [header]]],
            ]]]]],
            ["tabRenderer": ["content": ["sectionListRenderer": ["contents": [header]]]]],
        ]]]]
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id))
    }

    func testSelectedAlbumHeaderWinsOverUnselectedHeaderWithSameTitleAndDifferentArtist() throws {
        let selected = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        let unselected = try AlbumDescriptionFixtures.replacingCredits(in: selected, with: ["Chris Martin"])
        let root = AlbumDescriptionFixtures.page(selectedHeader: selected, unselectedHeader: unselected)
        let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: CatalogFixtures.graduationID))
        XCTAssertEqual(description.albumTitle, "Graduation")
        XCTAssertEqual(description.credits, [ArtistCredit(name: "Kanye West", id: CatalogFixtures.kanyeID)])
        XCTAssertTrue(description.text.hasPrefix("Graduation is the third studio album by the American rapper Kanye West."))
        XCTAssertEqual(try CatalogParser.browse(root, id: CatalogFixtures.graduationID).albumDescription, description)
    }

    func testSelectedAlbumHeaderWinsOverUnselectedHeaderWithDifferentTitle() throws {
        let graduation = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        let aashiqui = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-aashiqui-2"))
        let cases = [(graduation, aashiqui, CatalogFixtures.graduationID, "Graduation", ["Kanye West"], "Graduation_(album)"),
                     (aashiqui, graduation, CatalogFixtures.albumID, "Aashiqui 2", ["Jeet Gannguli", "Ankit Tiwari", "Mithoon"], "Aashiqui_2_(soundtrack)")]
        for (selected, unselected, id, title, artists, article) in cases {
            let root = AlbumDescriptionFixtures.page(selectedHeader: selected, unselectedHeader: unselected)
            let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: id), title)
            XCTAssertEqual(description.albumTitle, title)
            XCTAssertEqual(description.credits.map(\.name), artists)
            XCTAssertTrue(description.text.hasPrefix(title + " is "))
            XCTAssertEqual(description.sourceURL.absoluteString, "https://en.wikipedia.org/wiki/" + article)
        }
    }

    func testRelatedHeaderCannotReplaceSelectedAlbumMetadata() throws {
        let selected = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        let related = [try AlbumDescriptionFixtures.replacingCredits(in: selected, with: ["Chris Martin"]),
                       CatalogParser.pageHeaderRenderer(try recordedPage("album-description-aashiqui-2"))]
        for header in related {
            let root = AlbumDescriptionFixtures.page(selectedHeader: selected, relatedHeader: header)
            let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: CatalogFixtures.graduationID))
            XCTAssertEqual(description.albumTitle, "Graduation")
            XCTAssertEqual(description.credits, [ArtistCredit(name: "Kanye West", id: CatalogFixtures.kanyeID)])
            XCTAssertEqual(description.sourceURL.absoluteString, "https://en.wikipedia.org/wiki/Graduation_(album)")
        }
    }

    func testSelectedHeaderCannotBorrowMissingOrConflictingCredits() throws {
        let matching = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        for artists in [[], ["Chris Martin"]] {
            let selected = try AlbumDescriptionFixtures.replacingCredits(in: matching, with: artists)
            let pages = [AlbumDescriptionFixtures.page(selectedHeader: selected, unselectedHeader: matching),
                         AlbumDescriptionFixtures.page(selectedHeader: selected, relatedHeader: matching)]
            for root in pages {
                XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: CatalogFixtures.graduationID), "\(artists)")
            }
        }
    }

    func testSelectedHeaderMustSupplyItsOwnAlbumType() throws {
        let matching = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        for kind in ["", "Artist", "Playlist", "Song", "Single"] {
            var invalid = matching.object
            invalid["subtitle"] = try CatalogFixtures.json(CatalogFixtures.text(kind))
            let selected = AlbumDescriptionFixtures.page(selectedHeader: .object(invalid), unselectedHeader: matching)
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(selected, id: CatalogFixtures.graduationID), kind)
            let unselected = AlbumDescriptionFixtures.page(selectedHeader: matching, unselectedHeader: .object(invalid))
            XCTAssertEqual(CatalogAlbumDescriptionParser.parse(unselected, id: CatalogFixtures.graduationID)?.credits.map(\.name), ["Kanye West"])
        }
    }

    func testWrongAlbumArtistFilmSongAndDisambiguationContentAreRejected() throws {
        let invalid: [(String, String, String)] = [
            ("Another Album is a studio album by Test Singer. This description is long enough but belongs to another album.", AlbumDescriptionFixtures.artist, AlbumDescriptionFixtures.source),
            (AlbumDescriptionFixtures.text, "Another Singer", AlbumDescriptionFixtures.source),
            ("Paper Satellites is a film by Test Singer with a soundtrack album. A film plot must not become an album description.", AlbumDescriptionFixtures.artist, AlbumDescriptionFixtures.source),
            ("Paper Satellites is a song by Test Singer from a studio album. A song description must not become an album description.", AlbumDescriptionFixtures.artist, AlbumDescriptionFixtures.source),
            ("Paper Satellites is a singer known for a studio album with Test Singer. This synthetic biography is not album prose.", AlbumDescriptionFixtures.artist, AlbumDescriptionFixtures.source),
            ("Paper Satellites may refer to an album by Test Singer, a film, or another work. This is a synthetic disambiguation page.", AlbumDescriptionFixtures.artist, AlbumDescriptionFixtures.source),
            (AlbumDescriptionFixtures.text, AlbumDescriptionFixtures.artist, "https://en.wikipedia.org/wiki/Paper_Satellites_(disambiguation)"),
            (AlbumDescriptionFixtures.text, AlbumDescriptionFixtures.artist, "https://en.wikipedia.org/wiki/Test_Singer"),
            (AlbumDescriptionFixtures.text, AlbumDescriptionFixtures.artist, "https://en.wikipedia.org/wiki/Another_Album"),
        ]
        for (text, artist, source) in invalid {
            let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(artist: artist, text: text, source: source))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id), "\(text) | \(artist) | \(source)")
        }
    }

    func testRecordedGraduationRejectsGuestOnlyArtistCredits() throws {
        let header = CatalogParser.pageHeaderRenderer(try recordedPage("album-description-graduation"))
        for artists in [["Chris Martin"], ["Kanye West", "Chris Martin"]] {
            let changed = try AlbumDescriptionFixtures.replacingCredits(in: header, with: artists)
            let root = AlbumDescriptionFixtures.page(selectedHeader: changed)
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: CatalogFixtures.graduationID), "\(artists)")
        }
    }

    func testRecordedAlbumsRejectProducerOnlyArtistCredits() throws {
        let cases = [("album-description-graduation", CatalogFixtures.graduationID, "DJ Toomp"),
                     ("album-description-aashiqui-2", CatalogFixtures.albumID, "Bhushan Kumar")]
        for (file, id, producer) in cases {
            let header = CatalogParser.pageHeaderRenderer(try recordedPage(file))
            let changed = try AlbumDescriptionFixtures.replacingCredits(in: header, with: [producer])
            let root = AlbumDescriptionFixtures.page(selectedHeader: changed)
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: id), producer)
        }
    }

    func testGuestProducerAndComparisonMentionsCannotSatisfyAlbumCredits() throws {
        let clauses = ["featuring Guest Singer", "produced by Guest Singer", "compared with Guest Singer"]
        for clause in clauses {
            for text in ["Paper Satellites is a studio album by Test Singer, \(clause). This synthetic description retains the album's actual lead artist.",
                         AlbumDescriptionFixtures.text + " A later paragraph discusses music \(clause)."] {
                let header = try CatalogFixtures.json(AlbumDescriptionFixtures.header(text: text))
                for artists in [["Guest Singer"], ["Test Singer", "Guest Singer"]] {
                    let changed = try AlbumDescriptionFixtures.replacingCredits(in: header, with: artists)
                    XCTAssertNil(CatalogAlbumDescriptionParser.parse(AlbumDescriptionFixtures.page(selectedHeader: changed),
                                                                    id: AlbumDescriptionFixtures.id), "\(artists) | \(text)")
                }
                XCTAssertEqual(CatalogAlbumDescriptionParser.parse(AlbumDescriptionFixtures.page(selectedHeader: header),
                                                                  id: AlbumDescriptionFixtures.id)?.credits.map(\.name), ["Test Singer"])
            }
        }
    }

    func testConflictingSoundtrackLeadCannotBeRepairedByLaterComposition() throws {
        let text = "Paper Satellites is a soundtrack album by Another Artist. The music was composed by Test Singer for the film."
        let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(text: text,
            source: "https://en.wikipedia.org/wiki/Paper_Satellites_(soundtrack)"))
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id))
    }

    func testRecordedSoundtrackRequiresEveryComposersActualRelationship() throws {
        let root = try recordedPage("album-description-aashiqui-2")
        let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: CatalogFixtures.albumID))
        XCTAssertEqual(description.credits.map(\.name), ["Jeet Gannguli", "Ankit Tiwari", "Mithoon"])
        XCTAssertTrue(description.text.contains("The songs of the film were mostly composed by Jeet Gannguli"))
        XCTAssertTrue(description.text.contains("Mithoon and Ankit Tiwari composed two songs each as guest composers"))

        let payload = String(decoding: try root.encoded(), as: UTF8.self)
        let changes = [("were mostly composed by Jeet Gannguli", "were mostly produced by Jeet Gannguli"),
                       ("Mithoon and Ankit Tiwari composed two songs each as guest composers", "Mithoon and Ankit Tiwari made guest appearances"),
                       ("Mithoon and Ankit Tiwari composed two songs each as guest composers", "Mithoon and Ankit Tiwari were compared with the main composer")]
        for (original, replacement) in changes {
            XCTAssertTrue(payload.contains(original))
            let changed = try CatalogJSON.decode(Data(payload.replacingOccurrences(of: original, with: replacement).utf8))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(changed, id: CatalogFixtures.albumID), replacement)
        }
    }

    func testSoundtracksUseAlbumHeaderComposersAndPreserveInitialsAndLaterCreditMentions() throws {
        let texts = ["Paper Satellites is the soundtrack to a synthetic film. The description discusses the soundtrack album.\nThe music was composed by A.R. Rahman for this fixture.",
                     "Paper Satellites is a soundtrack composed by A.R. Rahman. This synthetic description ties the composer directly to the soundtrack.",
                     "Paper Satellites is the soundtrack to a synthetic film. A.R. Rahman composed the music for the film."]
        for text in texts {
            let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(artist: "A. R. Rahman", text: text,
                source: "https://en.wikipedia.org/wiki/Paper_Satellites_(soundtrack)"))
            let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id), text)
            XCTAssertEqual(description.text, text)
            XCTAssertEqual(description.credits.map(\.name), ["A. R. Rahman"])
        }
    }

    func testAlbumVersionsAreNotCollapsedUsingSongTitleHeuristics() throws {
        for title in ["Paper Satellites (Live)", "Paper Satellites (Remix)", "Paper Satellites (Deluxe)"] {
            let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(title: title))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id), title)
        }
    }

    func testExtendedPlaysRequireEveryAlbumCreditAndNativeTitleMarksStayDistinct() throws {
        let text = "Paper Satellites is an extended play by Test Singer and Second Artist. This synthetic fixture preserves both album credits."
        var header = AlbumDescriptionFixtures.header(text: text, source: "https://en.wikipedia.org/wiki/Paper_Satellites_(EP)")
        header["subtitle"] = CatalogFixtures.text("EP")
        header["straplineTextOne"] = ["runs": CatalogFixtures.artistRuns([
            (name: "Test Singer", id: CatalogFixtures.kanyeID), (name: "Second Artist", id: CatalogFixtures.arijitID),
        ])]
        XCTAssertNotNil(CatalogAlbumDescriptionParser.parse(try AlbumDescriptionFixtures.page(header: header), id: AlbumDescriptionFixtures.id))
        header["description"] = AlbumDescriptionFixtures.description()
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(try AlbumDescriptionFixtures.page(header: header), id: AlbumDescriptionFixtures.id),
                     "A partial credit match is not enough")

        let native = "काल is a studio album by Test Singer. This synthetic description checks that native-script title marks remain meaningful."
        let source = "https://en.wikipedia.org/wiki/काल_(album)"
        let matching = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(title: "काल", text: native, source: source))
        XCTAssertNotNil(CatalogAlbumDescriptionParser.parse(matching, id: AlbumDescriptionFixtures.id))
        let different = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(title: "कल", text: native, source: source))
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(different, id: AlbumDescriptionFixtures.id))
    }

    func testMissingForgedOrUnlicensedAttributionIsRejected() throws {
        let sources = ["http://en.wikipedia.org/wiki/Paper_Satellites_(album)",
                       "https://en.wikipedia.org.evil.invalid/wiki/Paper_Satellites_(album)",
                       "https://en.wikipedia.org@evil.invalid/wiki/Paper_Satellites_(album)",
                       "https://en.wikipedia.org/wiki/Paper_Satellites_(album)?redirect=bad",
                       "https://en.wikipedia.org/wiki/Special:Search", "javascript:alert(1)"]
        for source in sources {
            let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(source: source))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id), source)
        }
        for license in ["https://creativecommons.org/licenses/by/3.0/", "https://creativecommons.org.evil.invalid/licenses/by-sa/3.0/",
                        "https://creativecommons.org/licenses/by-sa/3.0/legalcode?extra=1", "https://example.org/license"] {
            let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(license: license))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id), license)
        }
        var header = AlbumDescriptionFixtures.header()
        header["description"] = CatalogFixtures.text(AlbumDescriptionFixtures.text + "\n\nFrom Wikipedia (unlinked)")
        XCTAssertNil(CatalogAlbumDescriptionParser.parse(try AlbumDescriptionFixtures.page(header: header), id: AlbumDescriptionFixtures.id))
    }

    func testLongTextIsBoundedAtAWordBoundaryAndOversizedOrMarkupTextIsAbsent() throws {
        let long = AlbumDescriptionFixtures.text + " " + String(repeating: "Additional synthetic text. ", count: 150)
        let root = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(text: long))
        let description = try XCTUnwrap(CatalogAlbumDescriptionParser.parse(root, id: AlbumDescriptionFixtures.id))
        XCTAssertTrue(description.isExcerpt)
        XCTAssertLessThanOrEqual(description.text.count, CatalogAlbumDescriptionParser.maximumDisplayCharacters + 1)
        XCTAssertTrue(description.text.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(description.text.dropLast())))
        let next = long.dropFirst(description.text.count - 1).first
        XCTAssertTrue(next?.isWhitespace == true)
        for text in [AlbumDescriptionFixtures.text + String(repeating: "x", count: CatalogAlbumDescriptionParser.maximumTextBytes),
                     AlbumDescriptionFixtures.text + " <script>bad</script>", AlbumDescriptionFixtures.text + " [[Bad markup]]"] {
            let invalid = try AlbumDescriptionFixtures.page(header: AlbumDescriptionFixtures.header(text: text))
            XCTAssertNil(CatalogAlbumDescriptionParser.parse(invalid, id: AlbumDescriptionFixtures.id))
        }
    }

    private func recordedPage(_ file: String) throws -> CatalogJSON {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: "json")
            ?? bundle.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
        return try CatalogJSON.decode(Data(contentsOf: url))
    }
}
