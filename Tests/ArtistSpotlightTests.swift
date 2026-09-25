import XCTest
@testable import GanaBajana

@MainActor
final class ArtistSpotlightTests: XCTestCase {
    func testProviderCountsDescendWithZeroBeforeUnknownAndDeterministicTies() {
        let tracks = [
            ArtistSpotlightTestSupport.track("nil", title: "A missing count"),
            ArtistSpotlightTestSupport.track("negative", title: "Z invalid count", count: -20),
            ArtistSpotlightTestSupport.track("zero", title: "Zero", count: 0),
            ArtistSpotlightTestSupport.track("tie-b", title: "Same title", count: 500),
            ArtistSpotlightTestSupport.track("tie-a", title: "Same title", count: 500),
            ArtistSpotlightTestSupport.track("alpha", title: "Alpha", count: 500),
            ArtistSpotlightTestSupport.track("most", title: "Zebra", count: 9_000_000),
        ]
        let expected = ["most", "alpha", "tie-a", "tie-b", "zero", "nil", "negative"]
        XCTAssertEqual(ArtistSpotlight.sorted(tracks).map(\.id), expected)
        XCTAssertEqual(ArtistSpotlight.sorted(Array(tracks.reversed())).map(\.id), expected)
        XCTAssertNil(ArtistSpotlight.sorted(tracks).last?.playCount)
    }

    func testDuplicateIDsFillMissingMetadataWithoutSummingOrCollapsingLanguageVersions() {
        var missing = ArtistSpotlightTestSupport.track("one", title: "Same song")
        missing.duration = nil
        let complete = ArtistSpotlightTestSupport.track("one", title: "Same song", count: 700, language: .hindi)
        let newerCount = ArtistSpotlightTestSupport.track("one", title: "Same song", count: 900)
        let dubbed = ArtistSpotlightTestSupport.track("dubbed", title: "Same song", count: 800)
        let result = ArtistSpotlight.sorted([missing, complete, newerCount, dubbed])
        XCTAssertEqual(result.map(\.id), ["dubbed", "one"])
        XCTAssertEqual(result.last?.playCount, 700, "The first available listing count wins; counts are not combined")
        XCTAssertEqual(result.last?.duration, 240)
        XCTAssertEqual(result.last?.language, .hindi)
    }

    func testConflictingDuplicateLanguageMetadataDoesNotBecomeAnAssertion() {
        let hindi = ArtistSpotlightTestSupport.track("one", count: 700, language: .hindi)
        let english = ArtistSpotlightTestSupport.track("one", count: 700, language: .english)
        XCTAssertNil(ArtistSpotlight.mergedTracks([hindi, english]).first?.language)
    }

    func testCountsBelongToMatchedIDsAndCannotComeFromCoversOrChangedTitles() {
        let original = ArtistSpotlightTestSupport.track("original", title: "River Lights")
        let artist = ArtistSpotlightTestSupport.page([original])
        var unrelated = original
        unrelated.credits = [ArtistCredit(name: "Someone Else", id: "UCelse")]
        unrelated.playCount = 100_000
        var wrongTitle = original
        wrongTitle.title = "River Lights (Live)"
        wrongTitle.playCount = 50_000
        let otherID = ArtistSpotlightTestSupport.track("other-version", title: original.title, count: 1_000_000)
        XCTAssertNil(ArtistSpotlight.matchingCount(for: original, in: [unrelated, wrongTitle, otherID], artist: artist))
        var exact = original
        exact.playCount = 750
        XCTAssertEqual(ArtistSpotlight.matchingCount(for: original, in: [unrelated, otherID, exact], artist: artist), 750)
    }

    func testSecondaryAndUnlinkedInitialCreditsMatchWithoutFuzzyArtistContamination() {
        let artist = ArtistSpotlightFixtures.page
        var song = ArtistSpotlightTestSupport.track("collaboration")
        song.credits = [ArtistCredit(name: "Primary Singer", id: "UCprimary"), ArtistSpotlightFixtures.artist]
        XCTAssertTrue(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: "Singer & A.R. Rahman")]
        XCTAssertTrue(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: "A. R. Rehman")]
        XCTAssertFalse(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: artist.name, id: "UCunrelated")]
        XCTAssertFalse(ArtistSpotlight.credits(artist, on: song))
    }

    func testRoleFollowsCreditPositionAndTitleFeatureClausesNeverMakeAnArtistPrimary() {
        let artist = ArtistSpotlightFixtures.page
        var song = ArtistSpotlightTestSupport.track("linked")
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .primary)
        song.credits = [ArtistCredit(name: "Primary Singer", id: "UCprimary"), ArtistSpotlightFixtures.artist]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured)
        song.credits = [ArtistCredit(name: "Primary Singer", id: "UCprimary"), ArtistCredit(name: "Second", id: "UCsecond"),
                        ArtistSpotlightFixtures.artist]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured)
        song.credits = [ArtistCredit(name: "A.R. Rahman")]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .primary, "An unlinked exact name still leads the credits")
        song.credits = [ArtistCredit(name: "A.R. Rahman & Singer")]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .primary)
        song.credits = [ArtistCredit(name: "Singer & A.R. Rahman")]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured, "A compound credit names its first artist as primary")
        song.credits = [ArtistCredit(name: "Rail Collective")]
        song.title = "Night Train (feat. A. R. Rahman)"
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured)
        song.credits = []
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured, "A feature clause is never a primary credit")
        song.title = "Night Train"
        XCTAssertNil(ArtistSpotlight.role(of: artist, on: song))
        song.credits = [ArtistCredit(name: "A. R. Rehman")]
        XCTAssertNil(ArtistSpotlight.role(of: artist, on: song), "Near misses never match")
        song.credits = [ArtistCredit(name: artist.name, id: "UCunrelated")]
        XCTAssertNil(ArtistSpotlight.role(of: artist, on: song), "A same-named artist with another page id is someone else")
        XCTAssertFalse(ArtistSpotlight.credits(artist, on: song))
        song.credits = [ArtistCredit(name: artist.name, id: "UCunrelated"), ArtistSpotlightFixtures.artist]
        XCTAssertEqual(ArtistSpotlight.role(of: artist, on: song), .featured)
    }

    func testLanguageFiltersRetainPopularityOrderAndAllKeepsUnclassifiedSongs() {
        let tracks = [ArtistSpotlightTestSupport.track("ta", count: 900),
                      ArtistSpotlightTestSupport.track("hi-low", count: 100, language: .hindi),
                      ArtistSpotlightTestSupport.track("te", count: 500),
                      ArtistSpotlightTestSupport.track("hi-high", count: 700),
                      ArtistSpotlightTestSupport.track("en", count: 300, language: .english),
                      ArtistSpotlightTestSupport.track("unknown-count"),
                      ArtistSpotlightTestSupport.track("unclassified", count: 800)]
        let languages: [String: ArtistSongLanguageResult] = [
            "ta": .identified(.tamil, source: .matchedLyrics), "te": .identified(.telugu, source: .matchedLyrics),
            "hi-high": .identified(.hindi, source: .matchedLyrics), "unknown-count": .identified(.tamil, source: .matchedLyrics),
            "unclassified": .unclassified(.uncertainLanguage),
        ]
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .all, languages: languages).map(\.id),
                       ["ta", "unclassified", "hi-high", "te", "en", "hi-low", "unknown-count"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.hindi), languages: languages).map(\.id), ["hi-high", "hi-low"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.tamil), languages: languages).map(\.id), ["ta", "unknown-count"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.telugu), languages: languages).map(\.id), ["te"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .language(.english), languages: languages).map(\.id), ["en"])
        XCTAssertEqual(ArtistSpotlight.filtered(tracks, by: .unclassified, languages: languages).map(\.id), ["unclassified"])
    }

    func testOneAvailableLanguageStillShowsAllAndUnknownDoesNotInheritArtistLanguage() {
        let hindi = ArtistSpotlightTestSupport.track("hi", language: .hindi)
        let unknown = ArtistSpotlightTestSupport.track("unknown")
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([hindi, unknown]))
        XCTAssertEqual(loader.filters, [.all, .language(.hindi), .unclassified])
        XCTAssertEqual(loader.unclassifiedCount, 1)
        XCTAssertEqual(loader.collection.title, "This is A. R. Rahman")
        XCTAssertEqual(loader.collection.kind, .mix)
        XCTAssertNil(loader.collection.language)
    }

    // MARK: - Alternate releases

    private func release(_ id: String, title: String, count: Int64? = 1_200_000_000, album: String, albumID: String,
                         explicit: Bool = false, duration: TimeInterval? = 243, artwork: String? = nil) -> Track {
        Track(id: id, title: title, credits: [ArtistSpotlightFixtures.artist], albumTitle: album, albumID: albumID,
              duration: duration, artworkURL: artwork.flatMap { URL(string: "https://example.invalid/\($0)") },
              isExplicit: explicit, isAudioRecording: true, playCount: count)
    }

    private let releases = [MusicCollection(id: "MPRE-sour", title: "SOUR", subtitle: "Album • 2021", kind: .album),
                            MusicCollection(id: "MPRE-single", title: "drivers license", subtitle: "Single • 2021", kind: .album),
                            MusicCollection(id: "MPRE-ep", title: "Early songs", subtitle: "EP • 2020 • 5 songs", kind: .album)]

    func testAlternateReleasesOfOneSongCollapseToTheAlbumRowWithoutSummingCounts() {
        let single = release("single", title: "drivers license", album: "drivers license", albumID: "MPRE-single")
        let album = release("album", title: "drivers license", album: "SOUR", albumID: "MPRE-sour", explicit: true)
        let other = release("other", title: "deja vu", count: 1_100_000_000, album: "SOUR", albumID: "MPRE-sour")
        let artist = ArtistSpotlightTestSupport.page([single, other], releases: releases)

        let collapsed = ArtistSpotlight.distinctSongs([single, other, album], artist: artist)
        XCTAssertEqual(collapsed.map(\.id), ["album", "other"], "The album release wins and keeps the song's first position")
        XCTAssertEqual(collapsed.first?.playCount, 1_200_000_000, "One release's own total; nothing is added")
        XCTAssertTrue(collapsed.first?.isExplicit == true)

        let listedAlbum = ArtistSpotlightTestSupport.page([album], releases: releases)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([album, single], artist: listedAlbum).map(\.id), ["album"])
        XCTAssertEqual(ArtistSpotlight.distinctSongs([single, album], artist: listedAlbum).map(\.id), ["album"])

        let epTrack = release("ep", title: "drivers license", album: "Early songs", albumID: "MPRE-ep")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([single, epTrack], artist: listedAlbum).map(\.id), ["ep"], "An EP is a release the song belongs to")
        let unknownRelease = release("compilation", title: "drivers license", album: "Hits", albumID: "MPRE-unknown")
        let listedSingle = ArtistSpotlightTestSupport.page([single], releases: releases)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([single, unknownRelease], artist: listedSingle).map(\.id), ["single"],
                       "An unknown release type does not outrank the provider's listed single")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([unknownRelease, album], artist: listedAlbum).map(\.id), ["album"])
    }

    func testDifferentPerformancesLanguageLabelsAndRunningTimesStaySeparate() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        let studio = release("studio", title: "Creep", count: 2_200_000_000, album: "Pablo Honey", albumID: "MPRE-ph", duration: 239)
        let live = release("live", title: "Creep (Live)", count: 2_200_000_000, album: "Pablo Honey", albumID: "MPRE-ph", duration: 239)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([studio, live], artist: artist).count, 2)
        let liveAlbum = release("live-album", title: "Creep", count: 2_200_000_000, album: "Live at the Astoria", albumID: "MPRE-la", duration: 239)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([studio, liveAlbum], artist: artist).count, 2, "The album title names the performance")
        let rerecording = release("tv", title: "Creep", count: 2_200_000_000, album: "Pablo Honey (Taylor's Version)", albumID: "MPRE-tv", duration: 239)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([studio, rerecording], artist: artist).count, 2)

        let hindi = release("hindi", title: "Kesariya", count: 500, album: "Brahmastra", albumID: "MPRE-b")
        let tamil = release("tamil", title: "Kesariya (Tamil)", count: 500, album: "Brahmastra (Tamil)", albumID: "MPRE-bt")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([hindi, tamil], artist: artist).count, 2, "A dubbed version is its own recording")
        let teluguRelease = release("telugu", title: "Kesariya", count: 500, album: "Brahmastra [Telugu]", albumID: "MPRE-bte")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([hindi, teluguRelease], artist: artist).count, 2, "The release can carry the language label")
        var hindiMetadata = hindi
        hindiMetadata.language = .hindi
        var englishMetadata = hindi
        englishMetadata.id = "english"
        englishMetadata.language = .english
        XCTAssertEqual(ArtistSpotlight.distinctSongs([hindiMetadata, englishMetadata], artist: artist).count, 2)

        let sevenHundred = release("a", title: "Same song", count: 700, album: "One", albumID: "MPRE-1")
        let eightHundred = release("b", title: "Same song", count: 800, album: "Two", albumID: "MPRE-2")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([sevenHundred, eightHundred], artist: artist).map(\.playCount), [700],
                       "Each release has its own total; the surviving row keeps its own, and nothing is added")
        let short = release("short", title: "Same song", count: 700, album: "One", albumID: "MPRE-1", duration: 229)
        let long = release("long", title: "Same song", count: 700, album: "Two", albumID: "MPRE-2", duration: 240)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([short, long], artist: artist).count, 2, "Eleven seconds apart is another edit")
        let close = release("close", title: "Same song", count: 700, album: "Two", albumID: "MPRE-2", duration: 230)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([short, close], artist: artist).count, 1)

        var otherPrimary = release("other-primary", title: "Same song", count: 700, album: "One", albumID: "MPRE-1")
        otherPrimary.credits = [ArtistCredit(name: "Someone Else", id: "UCelse"), ArtistSpotlightFixtures.artist]
        XCTAssertEqual(ArtistSpotlight.distinctSongs([sevenHundred, otherPrimary], artist: artist).count, 2,
                       "The first-named artist is part of the song's identity")
    }

    func testFeatureClausesRemastersAndExplicitLabelsDescribeTheSameSong() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        var clause = release("clause", title: "Night Train (feat. A. R. Rahman)", count: 300, album: "Rails", albumID: "MPRE-r")
        clause.credits = [ArtistCredit(name: "Rail Collective")]
        var credited = release("credited", title: "Night Train", count: 300, album: "Rails", albumID: "MPRE-r")
        credited.credits = [ArtistCredit(name: "Rail Collective"), ArtistSpotlightFixtures.artist]
        XCTAssertEqual(ArtistSpotlight.distinctSongs([clause, credited], artist: artist).count, 1)

        let original = release("original", title: "No Surprises", count: 614_000_000, album: "OK Computer", albumID: "MPRE-ok", duration: 229)
        let remaster = release("remaster", title: "No Surprises (Remastered 2017)", count: 614_000_000,
                               album: "OK Computer OKNOTOK 1997 2017", albumID: "MPRE-oknotok", duration: 230)
        XCTAssertEqual(ArtistSpotlight.distinctSongs([remaster, original], artist: artist).map(\.id), ["original"],
                       "Same release rank and total: the plainer title represents the song")
        let labelled = release("labelled", title: "good 4 u (Explicit)", count: 995_000_000, album: "SOUR", albumID: "MPRE-sour", explicit: true)
        let plain = release("plain", title: "good 4 u", count: 995_000_000, album: "good 4 u", albumID: "MPRE-single")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([plain, labelled], artist: artist).map(\.id), ["labelled"])
    }

    func testAlbumPreferenceKeepsOnlyTheChosenRecordingsMetadata() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        let uncounted = release("uncounted", title: "traitor", count: nil, album: "SOUR", albumID: "MPRE-sour", duration: 230)
        let counted = release("counted", title: "traitor", count: 910_000_000, album: "traitor", albumID: "MPRE-single",
                              explicit: true, duration: 231, artwork: "traitor")
        let collapsed = ArtistSpotlight.distinctSongs([uncounted, counted], artist: artist)
        XCTAssertEqual(collapsed, [uncounted], "The album keeps its own nil count/artwork and its own badge and duration")
        XCTAssertEqual(ArtistSpotlight.distinctSongs([counted, uncounted], artist: artist), [uncounted])

        let bare = release("bare", title: "happier", count: 752_000_000, album: "SOUR", albumID: "MPRE-sour", duration: nil)
        let detailed = release("detailed", title: "happier", count: 752_000_000, album: "happier", albumID: "MPRE-single", duration: 176, artwork: "happier")
        let merged = ArtistSpotlight.distinctSongs([detailed, bare], artist: artist)
        XCTAssertEqual(merged, [detailed, bare], "A missing duration cannot borrow another ID's evidence to establish an alias")
    }

    func testListedAlternateReleasesCollapseBeforeTheSpotlightLoaderShowsThem() {
        let single = release("single", title: "drivers license", album: "drivers license", albumID: "MPRE-single")
        let album = release("album", title: "drivers license", album: "SOUR", albumID: "MPRE-sour", explicit: true)
        let loader = ArtistSpotlightLoader(artist: ArtistSpotlightTestSupport.page([single, album], releases: releases))
        XCTAssertEqual(loader.visibleTracks.map(\.id), ["album"])
        XCTAssertEqual(loader.collection.tracks.count, 1)
    }

    func testNamedPerformancesPartsAndUnsupportedTitleLanguagesStaySeparate() {
        let artist = ArtistSpotlightTestSupport.page([])
        let titles = [
            ("Creep (Live at Reading 2009)", "Creep (Live at the Astoria 1994)"),
            ("River Lights (Alice Remix)", "River Lights (Bob Remix)"),
            ("Home (Part I)", "Home (Part II)"),
            ("Home - First Movement", "Home - Second Movement"),
            ("River Lights (Demo Take 1)", "River Lights (Demo Take 2)"),
            ("River Lights (Kannada)", "River Lights (Malayalam)"),
        ]
        for (left, right) in titles {
            let a = release("a", title: left, album: "Record", albumID: "MPRE-a", duration: 239)
            let b = release("b", title: right, album: "Record", albumID: "MPRE-b", duration: 240)
            for tracks in [[a, b], [b, a]] {
                XCTAssertEqual(Set(ArtistSpotlight.distinctSongs(tracks, artist: artist).map(\.id)), ["a", "b"], left)
            }
        }
    }

    func testFullReleaseQualifiersAndUnsupportedReleaseLanguagesStaySeparate() {
        let artist = ArtistSpotlightTestSupport.page([])
        let albums = [("Live at Reading 2009", "Live at the Astoria 1994"),
                      ("Record (Alice Remix)", "Record (Bob Remix)"),
                      ("Record (Kannada)", "Record (Malayalam)"),
                      ("Record (Deluxe Version)", "Record (Taylor's Version)")]
        for (left, right) in albums {
            let a = release("a", title: "River Lights", album: left, albumID: "MPRE-a")
            let b = release("b", title: "River Lights", album: right, albumID: "MPRE-b")
            XCTAssertEqual(ArtistSpotlight.distinctSongs([a, b], artist: artist).count, 2, left)
            XCTAssertEqual(ArtistSpotlight.distinctSongs([b, a], artist: artist).count, 2, left)
        }
    }

    func testIncidentalAlbumWordsAndCosmeticRemasterLabelsDoNotSplitAliases() {
        let artist = ArtistSpotlightTestSupport.page([])
        for album in ["Take Care", "Live Through This", "Radio Days"] {
            let a = release("a", title: "River Lights", album: album, albumID: "MPRE-a")
            let b = release("b", title: "River Lights", album: "River Lights", albumID: "MPRE-b")
            XCTAssertEqual(ArtistSpotlight.distinctSongs([a, b], artist: artist).count, 1, album)
        }
        let original = release("original", title: "No Surprises", count: 614_000_000, album: "OK Computer",
                               albumID: "MPRE-ok", duration: 229, artwork: "original")
        for annotation in ["(Remastered Version)", "(Remastered 2017)", "- 2017 Remaster", "(Album Version)"] {
            let other = release("other", title: "No Surprises \(annotation)", count: 615_000_000,
                                album: "OK Computer (Deluxe Edition)", albumID: "MPRE-reissue", duration: 230, artwork: "reissue")
            XCTAssertEqual(ArtistSpotlight.distinctSongs([other, original], artist: artist), [original], annotation)
        }
    }

    func testExplicitAndMissingBadgeTwinsKeepTheExplicitRecordingsOwnMetadata() {
        for title in ["drivers license", "deja vu", "good 4 u"] {
            let missingBadge = release("missing", title: title, album: "SOUR", albumID: "MPRE-sour", artwork: "sour")
            let explicit = release("explicit", title: title, album: "SOUR", albumID: "MPRE-sour", explicit: true, artwork: "sour")
            let artist = ArtistSpotlightTestSupport.page([missingBadge], releases: releases)
            XCTAssertEqual(ArtistSpotlight.distinctSongs([missingBadge, explicit], artist: artist), [explicit])
            XCTAssertEqual(ArtistSpotlight.distinctSongs([explicit, missingBadge], artist: artist), [explicit])
        }
    }

    func testKnownCleanAndEditQualifiersAreNeverTreatedAsMissingBadges() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        let original = release("original", title: "good 4 u", album: "SOUR", albumID: "MPRE-sour", explicit: true)
        for label in ["Clean", "Clean Version", "Clean Edit", "Censored", "Radio Edit"] {
            let titled = release("titled", title: "good 4 u (\(label))", album: "SOUR", albumID: "MPRE-sour")
            let released = release("released", title: "good 4 u", album: "SOUR (\(label))", albumID: "MPRE-sour")
            XCTAssertEqual(ArtistSpotlight.distinctSongs([original, titled], artist: artist).count, 2, label)
            XCTAssertEqual(ArtistSpotlight.distinctSongs([original, released], artist: artist).count, 2, label)
        }
    }

    func testDifferentFeatureArtistsAndLinkedPerformerIdentitiesStaySeparate() {
        let artist = ArtistSpotlightTestSupport.page([])
        let solo = release("solo", title: "Levitating", album: "Record", albumID: "MPRE-a", duration: 203)
        var first = solo
        first.id = "first"
        first.title = "Levitating (feat. First Guest)"
        var second = solo
        second.id = "second"
        second.credits.append(ArtistCredit(name: "Second Guest", id: "UCsecond"))
        XCTAssertEqual(ArtistSpotlight.distinctSongs([solo, first, second], artist: artist).count, 3)

        first.title = solo.title
        first.credits = [ArtistCredit(name: "Same Name", id: "UCone"), ArtistSpotlightFixtures.artist]
        second.credits = [ArtistCredit(name: "Same Name", id: "UCtwo"), ArtistSpotlightFixtures.artist]
        var unlinked = first
        unlinked.id = "unlinked"
        unlinked.credits[0].id = nil
        for tracks in permutations(first, second, unlinked) {
            XCTAssertEqual(Set(ArtistSpotlight.distinctSongs(tracks, artist: artist).map(\.id)), ["first", "second", "unlinked"])
        }
    }

    func testDurationChainsCannotMergeIncompatibleEndpointsInAnyPermutation() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        let short = release("short", title: "River Lights", album: "Single", albumID: "MPRE-single", duration: 200)
        let middle = release("middle", title: "River Lights", album: "SOUR", albumID: "MPRE-sour", duration: 209)
        let long = release("long", title: "River Lights", album: "Other", albumID: "MPRE-other", duration: 218)
        for tracks in permutations(short, middle, long) {
            XCTAssertEqual(Set(ArtistSpotlight.distinctSongs(tracks, artist: artist).map(\.id)), ["middle", "long"])
        }
    }

    func testUnknownLanguageCannotBridgeConflictingRecordingsInAnyPermutation() {
        let artist = ArtistSpotlightTestSupport.page([], releases: releases)
        let unknown = release("unknown", title: "River Lights", album: "SOUR", albumID: "MPRE-sour")
        var hindi = release("hindi", title: "River Lights", album: "Single", albumID: "MPRE-single")
        hindi.language = .hindi
        var english = hindi
        english.id = "english"
        english.language = .english
        for tracks in permutations(unknown, hindi, english) {
            XCTAssertEqual(Set(ArtistSpotlight.distinctSongs(tracks, artist: artist).map(\.id)), ["unknown", "hindi", "english"])
        }
        var checkedHindi = hindi
        checkedHindi.language = nil
        var checkedEnglish = english
        checkedEnglish.language = nil
        let checked: [String: ArtistSongLanguageResult] = ["hindi": .identified(.hindi, source: .youTubeAudioLanguage),
                                                          "english": .identified(.english, source: .matchedLyrics)]
        let display = ArtistSpotlight.displaySongs([unknown, checkedHindi, checkedEnglish], artist: artist, languages: checked)
        XCTAssertEqual(display.tracks.count, 3)
        XCTAssertEqual(ArtistSpotlight.displaySongs([unknown, checkedHindi], artist: artist,
            languages: ["hindi": .unclassified(.conflictingEvidence)]).tracks.count, 2)
    }

    func testMissingInvalidDurationsAndMissingPerformersCannotEstablishAliases() {
        let artist = ArtistSpotlightTestSupport.page([])
        let known = release("known", title: "River Lights", album: "Record", albumID: "MPRE-a")
        let durations: [TimeInterval?] = [nil, 0, -1, TimeInterval.nan, TimeInterval.infinity, -TimeInterval.infinity, 86_401]
        for duration in durations {
            let other = release("other", title: "River Lights", album: "Record", albumID: "MPRE-b", duration: duration)
            XCTAssertEqual(ArtistSpotlight.distinctSongs([known, other], artist: artist).count, 2)
            XCTAssertEqual(ArtistSpotlight.distinctSongs([other, known], artist: artist).count, 2)
        }
        var a = known
        a.credits = []
        var b = a
        b.id = "b"
        XCTAssertEqual(ArtistSpotlight.distinctSongs([a, b], artist: artist).count, 2)
    }

    func testRepresentativeChoiceIsPermutationStableWithoutBorrowingFlagsOrArtwork() {
        let fixture = ArtistSpotlightTestSupport.releaseAliases()
        var cleanAlbum = fixture.album
        cleanAlbum.isExplicit = false
        var explicitSingle = fixture.single
        explicitSingle.isExplicit = true
        var explicitAlbum = fixture.album
        explicitAlbum.id = "explicit-album"
        let artist = ArtistSpotlightTestSupport.page([cleanAlbum], releases: fixture.page.releases)
        for tracks in permutations(cleanAlbum, explicitSingle, explicitAlbum) {
            XCTAssertEqual(ArtistSpotlight.distinctSongs(tracks, artist: artist), [explicitAlbum])
        }
        XCTAssertEqual(ArtistSpotlight.distinctSongs([cleanAlbum, explicitSingle], artist: artist), [cleanAlbum])
    }

    func testKnownCompilationIsLowerPriorityWithoutGuessingUnknownReleaseTypes() {
        var fixture = ArtistSpotlightTestSupport.releaseAliases()
        var compilation = fixture.single
        compilation.id = "compilation"
        compilation.albumID = "MPRE-compilation"
        fixture.page.releases.append(MusicCollection(id: "MPRE-compilation", title: "Collected Songs", subtitle: "Compilation • 2025", kind: .album))
        XCTAssertEqual(ArtistSpotlight.distinctSongs([compilation, fixture.album], artist: fixture.page), [fixture.album])
        var unknown = fixture.single
        unknown.id = "unknown"
        unknown.albumID = "MPRE-unknown"
        unknown.albumTitle = "Unknown Album"
        XCTAssertEqual(ArtistSpotlight.distinctSongs([unknown, fixture.single], artist: fixture.page), [fixture.single])
    }

    private func permutations(_ a: Track, _ b: Track, _ c: Track) -> [[Track]] {
        [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]]
    }
}
