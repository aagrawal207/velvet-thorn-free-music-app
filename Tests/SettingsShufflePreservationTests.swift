import Foundation
import XCTest
@testable import GanaBajana

final class SettingsShufflePreservationTests: XCTestCase {
    func testSavedRandomWithoutProvenanceIsNeverRewritten() throws {
        let savedPreferences = [
            #"{"shuffleStyle":"random","saveListeningHistory":false,"discoveryFamiliarity":"newMusic"}"#,
            #"{"shuffleStyle":"random","shuffleDefaultMigrated":false}"#,
            #"{"shuffleStyle":"random","shuffleDefaultMigrated":true}"#
        ]
        for json in savedPreferences {
            var preferences = try LibrarySyncCodec.decode(UserPreferences.self, from: Data(json.utf8))
            let before = try LibrarySyncPreferences.fields(preferences)
            // A stored Random without an origin marker can be an explicit choice from an older build.
            XCTAssertFalse(preferences.migrateShuffleDefault(), json)
            XCTAssertEqual(preferences.shuffleStyle, .random, json)
            XCTAssertEqual(try LibrarySyncPreferences.fields(preferences), before,
                           "Re-evaluating defaults must not invent a preference edit or compatibility-marker revision")
        }
    }
}
