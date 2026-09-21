import Foundation
import XCTest
@testable import GanaBajana

@MainActor
final class RadioConfigurationTests: XCTestCase {
    func testDatedErasRequireKnownYearsWithinTheirBoundaries() {
        let cases: [(Int?, Bool, Bool)] = [
            (nil, false, false), (1899, false, false), (1900, true, false), (1999, true, false),
            (2000, false, false), (2014, false, false), (2015, false, true), (2026, false, true), (2027, false, false),
        ]
        for (year, older, newer) in cases {
            XCTAssertTrue(RadioEra.anytime.accepts(year: year, currentYear: 2026))
            XCTAssertEqual(RadioEra.older.accepts(year: year, currentYear: 2026), older, "Year: \(String(describing: year))")
            XCTAssertEqual(RadioEra.newer.accepts(year: year, currentYear: 2026), newer, "Year: \(String(describing: year))")
        }
    }

    func testDefaultsFollowTheTappedStationAndItsMatchingLanguageVariant() throws {
        for id in ["hindi-classics", "english-golden-oldies"] {
            let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
            let configuration = RadioConfiguration(station: station, languages: [.hindi, .english])
            XCTAssertEqual(configuration.era, .older)
            XCTAssertEqual(configuration.languages, station.discoveryLanguages)
            XCTAssertTrue(configuration.artists.isEmpty)
            XCTAssertEqual(RadioConfiguration.defaultArtists(station: station, languages: configuration.languages).count, 4)
            XCTAssertTrue(station.seeds.allSatisfy { $0.yearSource != nil && RadioEra.older.accepts(year: $0.year) })
        }
        let mixed = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let english = RadioConfiguration(station: mixed, languages: [.english])
        let hindi = RadioConfiguration(station: mixed, languages: [.hindi])
        XCTAssertEqual(english.era, .anytime)
        XCTAssertTrue(english.artists.isEmpty && hindi.artists.isEmpty)
        XCTAssertEqual(RadioConfiguration.defaultArtists(station: mixed, languages: english.languages).map(\.name), ["Kanye West", "Tyler, The Creator"])
        XCTAssertEqual(RadioConfiguration.defaultArtists(station: mixed, languages: hindi.languages).map(\.name), ["Char Diwaari", "Seedhe Maut"])
    }

    func testZeroOrSingleArtistHintsAreValidWhileLanguageAndHintBudgetRemainRequired() {
        var configuration = RadioConfiguration(station: ExperienceRadioFixtures.melancholy, languages: [.english])
        XCTAssertNil(configuration.validationMessage)
        configuration.artists = [ArtistCredit(name: "A. R. Rahman")]
        XCTAssertNil(configuration.validationMessage)
        configuration.artists = [ArtistCredit(name: "A. R. Rahman"), ArtistCredit(name: "AR Rahman"), ArtistCredit(name: " ")]
        XCTAssertNil(configuration.validationMessage)
        XCTAssertEqual(configuration.experience().artistHints.count, 1)
        configuration.artists.append(ArtistCredit(name: "Shreya Ghoshal"))
        XCTAssertNil(configuration.validationMessage)
        configuration.artists = (0..<5).map { ArtistCredit(name: "Artist \($0)") }
        XCTAssertEqual(configuration.validationMessage, "Choose up to four artist hints.")
        configuration.languages = []
        XCTAssertEqual(configuration.validationMessage, "Choose at least one language.")
    }

    func testEffectiveExperienceKeepsTheMoodDefinitionAndAnIndependentHintSnapshot() throws {
        let f = ExperienceRadioFixtures.self
        var configuration = RadioConfiguration(station: f.melancholy, languages: [.english])
        configuration.artists = [f.melancholy.seeds[1].artist]
        let experience = configuration.experience()
        configuration.era = .newer
        configuration.languages = [.hindi]
        configuration.artists = []
        XCTAssertTrue(experience.id.hasPrefix("fixture-melancholy.setup."))
        XCTAssertEqual(experience.stationID, f.melancholy.id)
        XCTAssertEqual(experience.title, f.melancholy.title)
        XCTAssertEqual(experience.defaultEra, .anytime)
        XCTAssertEqual(experience.seeds, f.melancholy.seeds)
        XCTAssertEqual(experience.artistHints, [f.melancholy.seeds[1].artist])
        XCTAssertEqual(experience.selection(for: [.english])?.contentLabel, "English · Anytime · 1 artist hint")
        XCTAssertNil(experience.selection(for: [.hindi]))
    }

    func testEveryStationHasMoodQueriesAndClearingHintsKeepsItsDefaults() throws {
        for station in RadioExperience.stations {
            var value = RadioConfiguration(station: station, languages: station.discoveryLanguages)
            value.artists = RadioConfiguration.defaultArtists(station: station, languages: value.languages)
            value.artists.removeAll()
            let configured = value.experience()
            XCTAssertEqual(configured.seeds, station.seeds)
            XCTAssertEqual(configured.styleQueries, station.styleQueries)
            XCTAssertFalse(configured.styleQueries.isEmpty)
            XCTAssertTrue(configured.artistHints.isEmpty)
            XCTAssertNotNil(configured.selection(for: value.languages))
        }
    }

    func testDisjointLanguagesCannotRetagAStationsDefaultsEvenWithArtistHints() throws {
        let cases: [(String, Set<MusicLanguage>, String)] = [
            ("hindi-gym", [.english], "Choose Hindi for this station."),
            ("melancholy", [.hindi], "Choose English for this station."),
        ]
        for (id, languages, message) in cases {
            let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
            var configuration = RadioConfiguration(station: station, languages: languages)
            configuration.artists = [ArtistCredit(name: "Optional Artist", id: "UCoptionalArtist")]
            XCTAssertEqual(configuration.validationMessage, message)
            let experience = configuration.experience()
            XCTAssertTrue(experience.discoveryLanguages.isEmpty)
            XCTAssertTrue(experience.variants.isEmpty)
            XCTAssertTrue(experience.seeds.isEmpty)
            XCTAssertTrue(experience.styleQueries.isEmpty)
            XCTAssertNil(experience.selection(for: languages))
            XCTAssertNil(experience.selection(for: station.discoveryLanguages))
        }
    }

    func testConfiguredVariantsKeepTheirOwnAudienceCuesAndCopy() throws {
        let mixed = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let experience = RadioConfiguration(station: mixed, languages: [.hindi, .english]).experience()
        XCTAssertEqual(experience.variants, mixed.variants)
        XCTAssertEqual(experience.selection(for: [.english])?.seeds.map(\.artist.name), ["Kanye West", "Tyler, The Creator"])
        XCTAssertEqual(experience.selection(for: [.hindi])?.seeds.map(\.artist.name), ["Char Diwaari", "Seedhe Maut"])
        XCTAssertEqual(experience.selection(for: [.english])?.contentLabel, "English · Anytime")
        XCTAssertEqual(experience.selection(for: [.hindi, .english])?.contentLabel, "English + Hindi · Anytime")

        let gym = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        var configuration = RadioConfiguration(station: gym, languages: [.hindi])
        configuration.languages.insert(.english)
        XCTAssertNil(configuration.validationMessage)
        let scoped = configuration.experience()
        XCTAssertEqual(scoped.discoveryLanguages, [.hindi])
        XCTAssertNil(scoped.selection(for: [.english]))
        XCTAssertEqual(scoped.selection(for: [.hindi])?.contentLabel, "Hindi + Punjabi · Anytime")
        XCTAssertEqual(scoped.seeds, gym.seeds)
        XCTAssertEqual(scoped.styleQueries, gym.styleQueries)
    }
}
