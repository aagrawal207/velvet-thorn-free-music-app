import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AppIconsTests: XCTestCase {
    func testPickerOffersTwentyChoicesInThreeFamiliesWithLeafnoteAsThePrimary() {
        XCTAssertEqual(AppIcons.all.map(\.id), ["Beat", "LeafPaper", "LeafSky", "LeafBlossom", "LeafMidnight", "LeafViolet",
                                                 "LeafSunset", "LeafMono", "Thorn", "Sonnet", "ThornEdge", "ThornFrost", "ThornNoir",
                                                 "ThornVenom", "ThornDusk", "ThornBlush", "Notes", "Boombox", "Speaker", "Waves"])
        XCTAssertEqual(AppIcons.all.map(\.title), ["Leafnote", "Paper", "Sky", "Blossom", "Midnight", "Violet", "Sunset", "Mono",
                                                    "Thorn", "Sonnet", "Edge", "Frost", "Noir", "Venom", "Dusk", "Blush",
                                                    "Drift", "Moonleaf", "Ripple", "Tide"])
        XCTAssertEqual(Set(AppIcons.all.map(\.id)).count, AppIcons.all.count)
        XCTAssertEqual(AppIcons.all.filter(\.isPrimary), [AppIcons.primary])
        XCTAssertEqual(AppIcons.primary.id, "Beat")
        XCTAssertNil(AppIcons.primary.alternateIconName)
        XCTAssertEqual(AppIcons.all.dropFirst().compactMap(\.alternateIconName), AppIcons.all.dropFirst().map { "AppIcon-\($0.id)" })
        // Families are contiguous so the picker's sections keep the catalog order.
        XCTAssertEqual(AppIcons.all.map(\.family).reduce(into: [AppIconOption.Family]()) { if $0.last != $1 { $0.append($1) } },
                       AppIconOption.Family.allCases)
        XCTAssertEqual(AppIcons.all.filter { $0.family == .leafnote }.count, 8)
        XCTAssertEqual(AppIcons.all.filter { $0.family == .thorn }.count, 8)
    }

    func testEveryChoiceIsAnAlternateTheBundleDeclares() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("A Mac app has one icon; the picker is hidden because alternate icons are iOS-only")
        #endif
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(declared["CFBundleAlternateIcons"] as? [String: Any])
        for option in AppIcons.all.dropFirst() {
            XCTAssertNotNil(alternates[try XCTUnwrap(option.alternateIconName)], option.id)
        }
        XCTAssertNotNil(alternates["AppIcon-Beat"], "The primary's compatibility alias stays installed")
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
