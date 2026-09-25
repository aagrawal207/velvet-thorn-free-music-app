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
        XCTAssertEqual(RadioEra.allCases.map(\.styleQuerySuffix), ["", " before 2000", " 2015 and later"])
    }

    func testDefaultsFollowTheTappedStationWithoutRequiringLanguageSelection() throws {
        for id in ["hindi-classics", "english-golden-oldies"] {
            let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
            let configuration = RadioConfiguration(station: station)
            XCTAssertEqual(configuration.era, .older)
            XCTAssertEqual(configuration.languages, [.hindi, .english], "Automatic setup preserves every legacy cue language")
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

    func testOptionalArtistHintsKeepTheirBudgetWithoutALanguageRequirement() {
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
        XCTAssertEqual(configuration.validationMessage, "Choose up to four artist hints.")
        configuration.artists = []
        XCTAssertNil(configuration.validationMessage)
        XCTAssertEqual(configuration.experience().variants, configuration.station.variants)
    }

    func testAutomaticAndEmptyLanguageDraftsPreserveAllVariantsForProfileBasedRadio() {
        for station in RadioExperience.stations {
            let automatic = RadioConfiguration(station: station)
            var empty = RadioConfiguration(station: station, languages: [])
            empty.era = .newer
            empty.artists = [ArtistCredit(name: "Optional artist", id: "UCoptional")]
            XCTAssertNil(automatic.validationMessage)
            XCTAssertNil(empty.validationMessage)
            XCTAssertEqual(automatic.experience().variants, station.variants)
            let experience = empty.experience()
            XCTAssertEqual(experience.variants, station.variants)
            XCTAssertEqual(experience.queryTemplates, station.queryTemplates)
            XCTAssertEqual(experience.defaultEra, .newer)
            XCTAssertEqual(experience.artistHints, empty.artists)
            XCTAssertEqual(RadioConfiguration.defaultArtists(station: station, languages: []),
                           RadioConfiguration.defaultArtists(station: station, languages: Set(MusicLanguage.allCases)))
        }
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
        let hindi = try XCTUnwrap(experience.selection(for: [.hindi]), "Any non-empty language set has a selection")
        XCTAssertTrue(hindi.seeds.isEmpty, "English cues never masquerade as Hindi cues")
        XCTAssertEqual(hindi.contentLabel, "Hindi · Anytime · 1 artist hint")
        XCTAssertNil(experience.selection(for: []))
    }

    func testEveryStationValidatesAndHasWordingForEveryLanguageSet() throws {
        let sets: [Set<MusicLanguage>] = [[.hindi], [.english], [.hindi, .english]]
        for station in RadioExperience.stations {
            for language in MusicLanguage.allCases {
                XCTAssertGreaterThanOrEqual(station.styleQueries(for: language).count, 2, "\(station.id) \(language)")
                XCTAssertEqual(station.queryTemplates[language]?.count ?? 0, 3, "\(station.id) declares three \(language) templates")
            }
            for languages in sets {
                var value = RadioConfiguration(station: station, languages: languages)
                XCTAssertNil(value.validationMessage, "\(station.id) \(languages)")
                value.artists = RadioConfiguration.defaultArtists(station: station, languages: languages)
                value.artists.removeAll()
                let configured = value.experience()
                let selection = try XCTUnwrap(configured.selection(for: languages), "\(station.id) \(languages)")
                XCTAssertEqual(selection.seeds, station.selection(for: languages)?.seeds)
                XCTAssertEqual(selection.styleQueries, station.selection(for: languages)?.styleQueries)
                XCTAssertGreaterThanOrEqual(selection.styleQueries.count, 2 * languages.count)
                XCTAssertTrue(configured.artistHints.isEmpty)
                XCTAssertEqual(configured.group, station.group)
            }
            XCTAssertEqual(station.styleQueries, station.selection(for: [.hindi, .english])?.styleQueries)
        }
    }

    func testAnyLanguageSetIsValidAndOnlyTheChosenLanguagesCuesAreKept() throws {
        let cases: [(String, Set<MusicLanguage>, String)] = [
            ("hindi-gym", [.english], "English · Anytime"),
            ("melancholy", [.hindi], "Hindi · Anytime"),
        ]
        for (id, languages, label) in cases {
            let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == id })
            var configuration = RadioConfiguration(station: station, languages: languages)
            XCTAssertNil(configuration.validationMessage, "A station starts in any language, with or without hints")
            XCTAssertTrue(RadioConfiguration.defaultArtists(station: station, languages: languages).isEmpty)
            configuration.artists = [ArtistCredit(name: "Optional Artist", id: "UCoptionalArtist")]
            XCTAssertNil(configuration.validationMessage)
            let experience = configuration.experience()
            XCTAssertTrue(experience.variants.isEmpty, "Cues tagged for another language stay out of the session")
            XCTAssertTrue(experience.seeds.isEmpty)
            XCTAssertEqual(experience.artistHints.map(\.name), ["Optional Artist"])
            let selection = try XCTUnwrap(experience.selection(for: languages))
            XCTAssertEqual(selection.contentLabel, "\(label) · 1 artist hint")
            XCTAssertEqual(selection.styleQueries, station.selection(for: languages)?.styleQueries)
            XCTAssertGreaterThanOrEqual(selection.styleQueries.count, 2)
            XCTAssertEqual(selection.description, station.description)
        }
    }

    func testSynthesizedWordingNamesTheLanguageAndInterleavesAcrossLanguages() throws {
        let station = RadioExperience(id: "english-wording", title: "Night Drive", description: "Fixture", symbol: "radio",
            discoveryLanguages: [.english], contentLabel: "English", seeds: [], styleQueries: ["night drive songs", "late highway songs"])
        let hindi = station.styleQueries(for: .hindi)
        XCTAssertEqual(hindi, ["Hindi night drive songs", "night drive Hindi music"])
        XCTAssertTrue(hindi.allSatisfy { $0.contains("Hindi") })
        XCTAssertEqual(station.styleQueries(for: .english), ["night drive songs", "late highway songs"])
        let combined = try XCTUnwrap(station.selection(for: [.hindi, .english]))
        XCTAssertEqual(combined.styleQueries, ["Hindi night drive songs", "night drive songs", "night drive Hindi music", "late highway songs"])
        XCTAssertEqual(combined.contentLabel, "Hindi + English")
        XCTAssertEqual(station.selection(for: [.hindi])?.contentLabel, "Hindi")

        let cueOnly = ExperienceRadioFixtures.melancholy
        XCTAssertTrue(cueOnly.styleQueries(for: .hindi).isEmpty, "A station with no wording anywhere stays cue-only")
        XCTAssertTrue(cueOnly.styleQueries.isEmpty)

        let templated = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let both = try XCTUnwrap(templated.selection(for: [.hindi, .english]))
        XCTAssertEqual(both.styleQueries[0], templated.styleQueries(for: .hindi)[0])
        XCTAssertEqual(both.styleQueries[1], templated.styleQueries(for: .english)[0])
        XCTAssertEqual(both.styleQueries[2], templated.styleQueries(for: .hindi)[1])
        XCTAssertEqual(templated.styleQueries(for: .hindi), ["Hindi sad songs", "Bollywood melancholy songs", "sad Hindi acoustic songs"])
    }

    func testConfiguredVariantsKeepTheirOwnAudienceCuesAndCopy() throws {
        let mixed = try XCTUnwrap(RadioExperience.stations.first { $0.id == "left-field-rap" })
        let experience = RadioConfiguration(station: mixed, languages: [.hindi, .english]).experience()
        XCTAssertEqual(experience.variants, mixed.variants)
        XCTAssertEqual(experience.selection(for: [.english])?.seeds.map(\.artist.name), ["Kanye West", "Tyler, The Creator"])
        XCTAssertEqual(experience.selection(for: [.hindi])?.seeds.map(\.artist.name), ["Char Diwaari", "Seedhe Maut"])
        XCTAssertEqual(experience.selection(for: [.english])?.contentLabel, "English · Anytime")
        XCTAssertEqual(experience.selection(for: [.hindi, .english])?.contentLabel, "Hindi + English · Anytime")

        let gym = try XCTUnwrap(RadioExperience.stations.first { $0.id == "hindi-gym" })
        var configuration = RadioConfiguration(station: gym, languages: [.hindi])
        configuration.languages.insert(.english)
        XCTAssertNil(configuration.validationMessage)
        let scoped = configuration.experience()
        XCTAssertEqual(scoped.cueLanguages, [.hindi])
        XCTAssertTrue(try XCTUnwrap(scoped.selection(for: [.english])).seeds.isEmpty)
        XCTAssertEqual(scoped.selection(for: [.hindi])?.contentLabel, "Hindi + Punjabi · Anytime")
        XCTAssertEqual(scoped.selection(for: [.hindi, .english])?.contentLabel, "Hindi + Punjabi + English · Anytime")
        XCTAssertEqual(scoped.seeds, gym.seeds)
        XCTAssertEqual(scoped.selection(for: [.hindi, .english])?.styleQueries, gym.selection(for: [.hindi, .english])?.styleQueries)
    }
}
