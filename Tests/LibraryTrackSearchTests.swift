import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class LibraryTrackSearchTests: XCTestCase {
    private var cafe: Track {
        Track(id: "cafe", title: "Café at Midnight", credits: [ArtistCredit(name: "Björk"), ArtistCredit(name: "Beyoncé")],
              albumTitle: "Déjà Vu", duration: 240)
    }

    private var river: Track {
        Track(id: "river", title: "River Song", artists: ["A. R. Rahman"], albumTitle: "Nightfall", duration: 240)
    }

    private var other: Track { Track(id: "other", title: "Quiet Sky", duration: 240) }

    func testTitleEveryCreditedArtistAndAlbumUseCaseAndDiacriticInsensitiveMatching() {
        let tracks = [other, cafe, river]
        for query in ["CAFE", "cáfé", "MIDNIGHT", "bjork", "BEYONCE", "déja vu"] {
            XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: query).tracks.map(\.id), ["cafe"], query)
        }
        for query in ["A.R. RAHMAN", "ar rahman", "nightfall", "ríver"] {
            XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: query).tracks.map(\.id), ["river"], query)
        }
    }

    func testAllTermsMustMatchOneSongAndCanSpanTitleCreditsAndAlbum() {
        let partial = Track(id: "partial", title: "Café", artists: ["Someone Else"], albumTitle: "Another Album")
        let tracks = [partial, river, cafe]
        XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: "  beyonce\nCAFE   deja ").tracks, [cafe])
        XCTAssertTrue(LibraryTrackSearch(tracks: tracks, query: "cafe rahman").tracks.isEmpty)
        XCTAssertTrue(LibraryTrackSearch(tracks: tracks, query: "cafe missing").tracks.isEmpty)
    }

    func testSubstringAndNonLatinQueriesMatchWithoutInventingMissingMetadata() {
        let hindi = Track(id: "hindi", title: "तुम ही हो", artists: ["अरिजीत सिंह"], albumTitle: "आशिकी 2")
        let tracks = [other, river, hindi]
        XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: "iver").tracks, [river])
        XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: "तुम").tracks, [hindi])
        XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: "अरिजीत").tracks, [hindi])
        XCTAssertEqual(LibraryTrackSearch(tracks: tracks, query: "आशिकी").tracks, [hindi])
        XCTAssertTrue(LibraryTrackSearch(tracks: tracks, query: "unknown artist").tracks.isEmpty)
        XCTAssertTrue(LibraryTrackSearch(tracks: tracks, query: "other").tracks.isEmpty, "Recording IDs are not song metadata")
    }

    func testEmptyWhitespaceAndPunctuationQueriesRestoreOrderAndOccurrences() {
        let tracks = [river, other, cafe, river]
        for query in ["", "  \n\t ", "— & !"] {
            let selection = LibraryTrackSearch(tracks: tracks, query: query)
            XCTAssertFalse(selection.isFiltering, query)
            XCTAssertEqual(selection.tracks, tracks, query)
        }
        let empty = LibraryTrackSearch(tracks: [], query: "cafe")
        XCTAssertTrue(empty.tracks.isEmpty)
        XCTAssertTrue(empty.isFiltering)
        XCTAssertFalse(empty.canReorder(currentTracks: []))
    }

    func testFilteringPreservesOrderSameNamedRecordingsAndDuplicateOccurrences() {
        let studio = Track(id: "studio", title: "Echo", albumTitle: "Studio", duration: 240)
        let live = Track(id: "live", title: "Echo", albumTitle: "Live", duration: 240)
        let selection = LibraryTrackSearch(tracks: [live, other, studio, live], query: "echo")
        XCTAssertEqual(selection.tracks, [live, studio, live])
        XCTAssertEqual(selection.removalIDs(at: IndexSet([0, 2])), ["live"], "Removal is idempotent by recording ID")
        XCTAssertEqual(selection.removalIDs(at: IndexSet([0, 1, 2])), ["live", "studio"], "Matching titles do not merge recordings")
    }

    func testRemovalOffsetsResolveAgainstVisibleResultsIncludingNoncontiguousAndStaleOffsets() {
        let selection = LibraryTrackSearch(tracks: [other, cafe, Track(id: "gap", title: "Silence"), river], query: "night")
        XCTAssertEqual(selection.tracks.map(\.id), ["cafe", "river"])
        XCTAssertEqual(selection.removalIDs(at: IndexSet(integer: 0)), ["cafe"])
        XCTAssertEqual(selection.removalIDs(at: IndexSet(integer: 1)), ["river"])
        XCTAssertEqual(selection.removalIDs(at: IndexSet([0, 1, 99])), ["cafe", "river"])
        XCTAssertEqual(selection.removalIDs(at: IndexSet(integer: 99)), [])
        XCTAssertEqual(selection.removalIDs(at: IndexSet()), [])
    }

    func testReorderingRequiresAnUnfilteredSnapshotWithTheCurrentSourceOrder() {
        let tracks = [cafe, river]
        let all = LibraryTrackSearch(tracks: tracks, query: " \n ")
        XCTAssertTrue(all.canReorder(currentTracks: tracks))
        XCTAssertFalse(all.canReorder(currentTracks: Array(tracks.reversed())))
        XCTAssertFalse(all.canReorder(currentTracks: [cafe]))
        XCTAssertFalse(all.canReorder(currentTracks: tracks + [other]))
        var enriched = cafe
        enriched.albumTitle = "Updated album metadata"
        XCTAssertTrue(all.canReorder(currentTracks: [enriched, river]), "Metadata enrichment does not move an index")

        let matchingAll = LibraryTrackSearch(tracks: tracks, query: "night")
        XCTAssertEqual(matchingAll.tracks, tracks)
        XCTAssertFalse(matchingAll.canReorder(currentTracks: tracks), "A nonempty filter still disables reordering when every song matches")
    }

    func testFilteredPlaylistRemovalPersistsTheVisibleRecordingAndPreservesNamesakesAndLikes() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let studio = Track(id: "studio", title: "Echo", albumTitle: "Studio", duration: 240)
            let live = Track(id: "live", title: "Echo", albumTitle: "Live in Zürich", duration: 240)
            let id = store.createPlaylist(name: "Echoes")
            [studio, other, live, river].forEach { store.add($0, to: id) }
            store.toggleFavorite(live)
            var duplicate = live
            duplicate.title = "A newer title for the same recording"
            store.add(duplicate, to: id)
            XCTAssertEqual(store.playlists[0].tracks, [studio, other, live, river])

            let drag = LibraryTrackSearch(tracks: store.playlists[0].tracks, query: "")
            let selection = LibraryTrackSearch(tracks: store.playlists[0].tracks, query: "ZURICH")
            XCTAssertEqual(selection.tracks, [live])
            for trackID in selection.removalIDs(at: IndexSet(integer: 0)) { store.remove(trackID: trackID, from: id) }
            XCTAssertEqual(store.playlists[0].tracks, [studio, other, river])
            XCTAssertFalse(drag.canReorder(currentTracks: store.playlists[0].tracks))
            XCTAssertTrue(LibraryTrackSearch(tracks: store.playlists[0].tracks, query: "zurich").tracks.isEmpty)

            let reopened = LibraryStore(directory: directory)
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(reopened.playlists[0].tracks, [studio, other, river])
            XCTAssertEqual(reopened.favorites, [live])
        }
    }

    func testFilteredUnlikeRemovesOnlyTheSelectedRecordingAndImmediatelyRecomputesMatches() throws {
        try withLibraryTestDirectory { directory in
            let store = LibraryStore(directory: directory)
            let studio = Track(id: "studio", title: "Echo", albumTitle: "Studio")
            let live = Track(id: "live", title: "Echo", albumTitle: "Live")
            [studio, live].forEach { store.toggleFavorite($0) }
            let selection = LibraryTrackSearch(tracks: store.favorites, query: "studio")
            store.toggleFavorite(try XCTUnwrap(selection.tracks.first))
            XCTAssertTrue(LibraryTrackSearch(tracks: store.favorites, query: "studio").tracks.isEmpty)
            XCTAssertEqual(LibraryTrackSearch(tracks: store.favorites, query: "").tracks, [live])
            XCTAssertEqual(LibraryStore(directory: directory).favorites, [live])
        }
    }

    func testChangingAndClearingLibraryQueriesPreservesSelectedQueueOccurrenceAndGlobalSearch() async throws {
        let context = try makeContext(snapshot: PlaybackSnapshot(queue: [cafe, river, cafe], currentIndex: 2, position: 54.25))
        [other, river, cafe].forEach { context.library.toggleFavorite($0) }
        let playlistID = context.library.createPlaylist(name: "Saved selection")
        [other, cafe, river].forEach { context.library.add($0, to: playlistID) }
        context.model.searchQuery = "A deliberate catalog query"
        context.library.recordSearch("Earlier catalog query")
        let before = context.library.playback
        let preferences = context.library.preferences
        for query in ["beyonce", "not in this library", "", "rahman", "  "] {
            _ = LibraryTrackSearch(tracks: context.library.favorites, query: query)
            _ = LibraryTrackSearch(tracks: context.library.playlists[0].tracks, query: query)
            XCTAssertEqual(context.player.queue, [cafe, river, cafe])
            XCTAssertEqual(context.player.currentIndex, 2)
            XCTAssertEqual(context.player.position, 54.25)
            assertSnapshot(context.library.playback, equals: before)
        }
        XCTAssertEqual(context.model.searchQuery, "A deliberate catalog query")
        XCTAssertEqual(context.library.recentSearches, ["Earlier catalog query"])
        XCTAssertEqual(context.library.preferences, preferences)
        assertSnapshot(LibraryStore(directory: context.directory).playback, equals: before)
        let requests = await context.catalog.searches.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRowPlaybackCapturesTheFilteredSelectionDespiteLaterQueryChangesAndRemoval() async throws {
        let context = try makeContext()
        let id = context.library.createPlaylist(name: "Saved selection")
        [other, cafe, river].forEach { context.library.add($0, to: id) }
        let selection = LibraryTrackSearch(tracks: context.library.playlists[0].tracks, query: "night")
        context.model.play(river, in: selection.tracks)
        let request = try await context.streams.streams.request(at: 0)
        XCTAssertEqual(request.input.track, river)
        XCTAssertEqual(context.player.queue, [cafe, river])
        XCTAssertEqual(context.player.currentIndex, 1)
        try await context.streams.streams.complete(request, with: .failure(MusicServiceError.unavailable("Offline fixture")))
        try await AppModelFixtures.eventually { context.player.errorMessage != nil }
        context.player.seek(to: 42.25)
        let before = context.library.playback

        context.library.remove(trackID: river.id, from: id)
        XCTAssertEqual(LibraryTrackSearch(tracks: context.library.playlists[0].tracks, query: "").tracks, [other, cafe])
        XCTAssertTrue(LibraryTrackSearch(tracks: context.library.playlists[0].tracks, query: "river").tracks.isEmpty)
        XCTAssertEqual(context.player.queue, [cafe, river])
        XCTAssertEqual(context.player.currentTrack, river)
        XCTAssertEqual(context.player.currentIndex, 1)
        XCTAssertEqual(context.player.position, 42.25)
        assertSnapshot(context.library.playback, equals: before)
        assertSnapshot(LibraryStore(directory: context.directory).playback, equals: before)
        XCTAssertTrue(context.library.recentSearches.isEmpty)
        let catalogRequests = await context.catalog.searches.requests
        XCTAssertTrue(catalogRequests.isEmpty)
    }

    func testPlayAndShuffleUseOnlyTheCapturedMatchesAndRetainRepeatedOccurrences() throws {
        let context = try makeContext()
        let source = [cafe, other, river, cafe]
        let selection = LibraryTrackSearch(tracks: source, query: "night")
        context.model.play(selection.tracks, shuffle: true)
        context.player.pause()
        let selected = try XCTUnwrap(context.player.currentTrack)
        XCTAssertTrue(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue.map(\.id).sorted(), ["cafe", "cafe", "river"])
        XCTAssertEqual(context.library.playback.originalQueue, [cafe, river, cafe])
        let before = context.library.playback
        XCTAssertEqual(LibraryTrackSearch(tracks: source, query: "").tracks, source)
        assertSnapshot(context.library.playback, equals: before)
        context.player.toggleShuffle()
        XCTAssertEqual(context.player.queue, [cafe, river, cafe])
        XCTAssertEqual(context.player.currentTrack, selected)

        context.model.play(selection.tracks)
        context.player.pause()
        XCTAssertFalse(context.player.shuffleEnabled)
        XCTAssertEqual(context.player.queue, [cafe, river, cafe])
        XCTAssertEqual(context.player.currentIndex, 0)
        XCTAssertEqual(LibraryStore(directory: context.directory).playback.queue, [cafe, river, cafe])
    }

    func testHistoryEnablePreferencesRespectFailedWritesThenResumeDurableLanguageLearning() throws {
        let context = try makeContext()
        context.model.updatePreferences { $0.saveListeningHistory = false }
        var song = cafe
        song.language = .hindi
        let progress = try XCTUnwrap(context.player.onListeningProgress)
        let started = Date().addingTimeInterval(-120)
        try context.withBlockedLibraryFile {
            context.model.updatePreferences { $0.saveListeningHistory = true }
            XCTAssertNotNil(context.library.errorMessage)
            XCTAssertFalse(context.library.preferences.saveListeningHistory)
            XCTAssertTrue(progress(song, UUID(), started, 30))
            XCTAssertTrue(context.library.events.isEmpty)
        }

        context.model.updatePreferences { $0.saveListeningHistory = true }
        XCTAssertTrue(context.library.preferences.saveListeningHistory)
        XCTAssertTrue(progress(song, UUID(), started, 30))
        XCTAssertEqual(context.model.listeningLanguageSummary().totalPlays, 1)
        XCTAssertEqual(context.model.listeningLanguageProfile.orderedLanguages, [.hindi])
        let reopened = LibraryStore(directory: context.directory)
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.preferences.saveListeningHistory)
        XCTAssertEqual(reopened.events.map(\.track.id), [song.id])
    }

    private func assertSnapshot(_ actual: PlaybackSnapshot, equals expected: PlaybackSnapshot,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.queue, expected.queue, file: file, line: line)
        XCTAssertEqual(actual.originalQueue, expected.originalQueue, file: file, line: line)
        XCTAssertEqual(actual.currentIndex, expected.currentIndex, file: file, line: line)
        XCTAssertEqual(actual.position, expected.position, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.shuffleEnabled, expected.shuffleEnabled, file: file, line: line)
        XCTAssertEqual(actual.repeatMode, expected.repeatMode, file: file, line: line)
    }

    private func makeContext(snapshot: PlaybackSnapshot = PlaybackSnapshot()) throws -> AppModelTestContext {
        let context = try AppModelTestContext(snapshot: snapshot)
        context.model.updatePreferences { $0.autoplay = false }
        addTeardownBlock { try await context.close() }
        return context
    }
}
