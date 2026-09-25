import XCTest
@testable import GanaBajana

@MainActor
final class LibraryMixPublicationTests: XCTestCase {
    private typealias Fixtures = RecommendationFixtures

    private func mix(_ tracks: [Track], period: String = "day", kind: GeneratedPlaylistKind = .dailyMix) -> GeneratedPlaylist {
        GeneratedPlaylist(kind: kind, tracks: tracks, generatedAt: Fixtures.now,
                          periodKey: period, seedArtists: ["Seed artist"])
    }

    func testPublicationUsesCurrentDislikesWithoutFilteringLanguagesOrUnclassifiedSongs() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.preferences.languages = [.hindi]
            let hindi = Fixtures.track("hindi", language: .hindi)
            let english = Fixtures.track("english", language: .english)
            let disliked = Fixtures.track("disliked", language: .english)
            let unknown = Fixtures.track("unknown")
            let pending = mix([hindi, english, disliked, unknown])
            library.preferences.languages = [.english]
            library.toggleDislike(disliked)

            library.saveMix(pending)
            XCTAssertNil(library.errorMessage)
            var expected = pending
            expected.tracks = [hindi, english, unknown]
            XCTAssertEqual(library.mix(.dailyMix), expected)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), expected)
        }
    }

    func testPublicationKeepsEveryLanguageAfterCorrectionsAndLegacyPreferenceChanges() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            library.preferences.languages = [.english]
            let correctedHindi = Fixtures.track("corrected-hindi", language: .english)
            let correctedEnglish = Fixtures.track("corrected-english", language: .hindi)
            let tamil = Fixtures.track("tamil")
            let unclassified = Fixtures.track("unclassified", language: .hindi)
            let unknown = Fixtures.track("unknown", title: "Hindi is only part of this title")
            XCTAssertTrue(library.setRecordingLanguageOverride("hi", for: correctedHindi.id))
            XCTAssertTrue(library.setRecordingLanguageOverride("en", for: correctedEnglish.id))
            XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: tamil.id))
            XCTAssertTrue(library.setRecordingLanguageOverride("unclassified", for: unclassified.id))
            library.preferences.languageNudges[.tamil] = .less
            library.saveMix(mix([correctedHindi, correctedEnglish, tamil, unclassified, unknown]))

            XCTAssertNil(library.errorMessage)
            let reopened = LibraryStore(directory: directory)
            XCTAssertEqual(reopened.mix(.dailyMix)?.tracks, [correctedHindi, correctedEnglish, tamil, unclassified, unknown])
            XCTAssertEqual(reopened.recordingLanguageOverrides, library.recordingLanguageOverrides)
        }
    }

    func testFilteredEmptyResultDoesNotClaimThePeriodOrReplaceTheLastSavedMix() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let previous = mix([Fixtures.track("previous", language: .english)], period: "previous-day")
            library.saveMix(previous)
            let disliked = Fixtures.track("disliked", language: .hindi)
            library.toggleDislike(disliked)
            library.preferences.languages = [.hindi]
            let pending = mix([disliked], period: "current-day")
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            library.saveMix(pending)
            XCTAssertEqual(library.mix(.dailyMix), previous)
            XCTAssertEqual(try Data(contentsOf: url), saved)

            let retry = mix([Fixtures.track("eligible", language: .hindi)], period: "current-day")
            library.saveMix(retry)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), retry)
        }
    }

    func testPersistedEligibleMixStaysStableWithinItsPeriodAndRefreshesNextPeriod() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let first = mix([Fixtures.track("first", language: .english)])
            library.saveMix(first)
            let reopened = LibraryStore(directory: directory)
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            let saved = try Data(contentsOf: url)
            reopened.saveMix(mix([Fixtures.track("replacement", language: .english)]))
            XCTAssertEqual(reopened.mix(.dailyMix), first)
            XCTAssertEqual(try Data(contentsOf: url), saved)

            let tomorrow = mix([Fixtures.track("tomorrow", language: .english)], period: "next-day")
            reopened.saveMix(tomorrow)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), tomorrow)
        }
    }

    func testLanguagePreferenceAndCorrectionChangesPreserveTheSavedMixForItsPeriod() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let song = Fixtures.track("hindi", language: .hindi)
            let original = mix([song])
            library.saveMix(original)
            library.preferences.languages = [.english]
            library.preferences.languageNudges[.tamil] = .less
            XCTAssertTrue(library.setRecordingLanguageOverride("ta", for: song.id))
            let replacement = mix([Fixtures.track("english", language: .english)])
            library.saveMix(replacement)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), original)
        }
    }

    func testDislikingEverySavedTrackAllowsANonemptyMixInTheSamePeriod() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let song = Fixtures.track("disliked")
            library.saveMix(mix([song]))
            library.toggleDislike(song)
            XCTAssertNil(library.mix(.dailyMix))
            let reopened = LibraryStore(directory: directory)
            reopened.saveMix(mix([song]))
            XCTAssertNil(reopened.mix(.dailyMix), "An all-disliked result must not reserve the period")
            let replacement = mix([Fixtures.track("eligible")])
            reopened.saveMix(replacement)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), replacement)
        }
    }

    func testFailedMixWriteDoesNotReserveThePeriodAndCanBeRetried() throws {
        try withLibraryTestDirectory { directory in
            let library = LibraryStore(directory: directory)
            let pending = mix([Fixtures.track("eligible")])
            let url = directory.appendingPathComponent(LibraryPersistence.fileName)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            library.saveMix(pending)
            XCTAssertNotNil(library.errorMessage)
            XCTAssertNil(library.mix(.dailyMix))
            try FileManager.default.removeItem(at: url)
            library.saveMix(pending)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(LibraryStore(directory: directory).mix(.dailyMix), pending)
        }
    }
}
