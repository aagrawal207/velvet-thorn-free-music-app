import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AppIconsTests: XCTestCase {
    func testPickerOffersSevenChoicesWithLeafnoteAsThePrimary() {
        XCTAssertEqual(AppIcons.all.map(\.id), ["Beat", "Notes", "Boombox", "Speaker", "Waves", "Thorn", "Sonnet"])
        XCTAssertEqual(AppIcons.all.map(\.title), ["Leafnote", "Drift", "Moonleaf", "Ripple", "Tide", "Thorn", "Sonnet"])
        XCTAssertEqual(AppIcons.all.filter(\.isPrimary), [AppIcons.primary])
        XCTAssertEqual(AppIcons.primary.id, "Beat")
        XCTAssertNil(AppIcons.primary.alternateIconName)
        XCTAssertEqual(AppIcons.all.dropFirst().map(\.alternateIconName),
                       ["AppIcon-Notes", "AppIcon-Boombox", "AppIcon-Speaker", "AppIcon-Waves", "AppIcon-Thorn", "AppIcon-Sonnet"])
    }

    func testEveryChoiceHasABundledPreviewImage() {
        for option in AppIcons.all {
            XCTAssertNotNil(UIImage(named: option.previewImageName), option.previewImageName)
        }
    }

    func testCurrentAlternatesAndThePrimaryAliasResolveAndAreKnown() throws {
        XCTAssertEqual(AppIcons.option(named: nil), AppIcons.primary)
        XCTAssertEqual(AppIcons.option(named: "AppIcon-Beat"), AppIcons.primary)
        XCTAssertTrue(AppIcons.isKnown(alternateName: "AppIcon-Beat"))
        for option in AppIcons.all.dropFirst() {
            let name = try XCTUnwrap(option.alternateIconName)
            XCTAssertEqual(AppIcons.option(named: name), option)
            XCTAssertTrue(AppIcons.isKnown(alternateName: name))
        }
    }

    func testRetiredAlternatesPresentAsLeafnoteAndAreNotKnown() {
        let retired = ["AppIcon-Copper", "AppIcon-Dhol", "AppIcon-Headphones", "AppIcon-Vinyl", "AppIcon-Cassette",
                       "AppIcon-Peacock", "AppIcon-Mic", "AppIcon-Tabla", "AppIcon-Sargam", "AppIcon-Bansuri"]
        for name in retired {
            XCTAssertEqual(AppIcons.option(named: name), AppIcons.primary, name)
            XCTAssertFalse(AppIcons.isKnown(alternateName: name), name)
            XCTAssertNil(UIImage(named: "IconPreview-\(name.dropFirst("AppIcon-".count))"), name)
        }
    }
}
