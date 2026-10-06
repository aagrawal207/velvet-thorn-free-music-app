import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AppAccentTests: XCTestCase {
    func testMissingOrNullAccentLoadsCoralAndPreservesExistingPreferencesAndMusic() throws {
        for explicitNull in [false, true] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.preferences.languages = [.english]
                document.preferences.appearance = .light
                document.preferences.hasCompletedWelcome = true
                document.preferences.saveListeningHistory = false
                document.preferences.autoplay = false
                document.preferences.homeLayout.setVisible(false, for: .charts)
                document.preferences.homeLayout.move(from: IndexSet(integer: 5), to: 0)
                document.favorites = [libraryTestTrack()]
                document.playback = PlaybackSnapshot(queue: document.favorites, position: 19)
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
                if explicitNull { preferences["accent"] = NSNull() }
                else { preferences.removeValue(forKey: "accent") }
                json["preferences"] = preferences
                let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)

                let store = LibraryStore(directory: directory)
                XCTAssertNil(store.errorMessage)
                XCTAssertEqual(store.preferences.accent, .coral)
                XCTAssertEqual(store.preferences, document.preferences)
                XCTAssertEqual(store.favorites, document.favorites)
                XCTAssertEqual(store.playback.queue, document.playback.queue)
                XCTAssertEqual(store.playback.position, 19)
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testEveryAccentRoundTripsThroughTheVersionedLibrary() throws {
        for accent in AppAccent.allCases {
            var document = LibraryDocument()
            document.preferences.accent = accent
            document.preferences.appearance = .system
            document.preferences.homeLayout.setVisible(false, for: .recentlyPlayed)
            document.preferences.crossfadeSeconds = 5
            document.favorites = [libraryTestTrack()]
            let data = try LibraryPersistence.encode(document)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
            XCTAssertEqual(preferences["accent"] as? String, accent.rawValue)
            XCTAssertEqual(json["version"] as? Int, LibraryPersistence.currentVersion)

            let restored = try LibraryPersistence.decode(data, now: Date())
            XCTAssertEqual(restored.preferences, document.preferences)
            XCTAssertEqual(restored.favorites, document.favorites)
        }
    }

    func testInvalidAccentPreservesTheOriginalLibraryInsteadOfOverwritingIt() throws {
        for invalidAccent in [42, "future-accent"] as [Any] {
            try withLibraryTestDirectory { directory in
                var document = LibraryDocument()
                document.favorites = [libraryTestTrack()]
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryPersistence.encode(document)) as? [String: Any])
                var preferences = try XCTUnwrap(json["preferences"] as? [String: Any])
                preferences["accent"] = invalidAccent
                json["preferences"] = preferences
                let data = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
                let url = directory.appendingPathComponent(LibraryPersistence.fileName)
                try LibraryPersistence.write(data, to: url, replacing: nil)

                let store = LibraryStore(directory: directory)
                XCTAssertNotNil(store.errorMessage)
                store.preferences.accent = .mint
                XCTAssertEqual(store.preferences.accent, .coral)
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testModelSelectionPublishesAndPersistsWithoutChangingPlaybackOrHomeLayout() async throws {
        let song = libraryTestTrack()
        let context = try AppModelTestContext(snapshot: PlaybackSnapshot(queue: [song], position: 12))
        addTeardownBlock { @MainActor in try await context.close() }
        context.model.updatePreferences {
            $0.appearance = .light
            $0.homeLayout.setVisible(false, for: .charts)
            $0.homeLayout.move(from: IndexSet(integer: 5), to: 0)
        }
        context.library.toggleFavorite(song)
        var expectedPreferences = context.library.preferences
        expectedPreferences.accent = .mint
        let playbackSettings = context.player.settings

        context.model.updatePreferences { $0.accent = .mint }
        XCTAssertNil(context.library.errorMessage)
        XCTAssertEqual(context.model.library.preferences, expectedPreferences)
        XCTAssertEqual(context.player.currentTrack, song)
        XCTAssertEqual(context.player.position, 12)
        XCTAssertEqual(context.player.settings, playbackSettings)

        let listeningProgress = try XCTUnwrap(context.player.onListeningProgress)
        XCTAssertTrue(listeningProgress(song, UUID(), Date().addingTimeInterval(-60), 30))
        let restored = LibraryStore(directory: context.directory)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.preferences, expectedPreferences)
        XCTAssertEqual(restored.favorites, [song])
        XCTAssertEqual(restored.playback.queue, [song])
        XCTAssertEqual(restored.playback.position, 12)
        XCTAssertEqual(restored.events.first?.listenedSeconds, 30)

        let searches = await context.catalog.searches.requests
        let discovery = await context.catalog.discoveries.requests
        let radio = await context.catalog.autoplayRadios.requests
        let charts = await context.charts.charts.requests
        XCTAssertTrue(searches.isEmpty && discovery.isEmpty && radio.isEmpty && charts.isEmpty)
    }

    func testRejectedModelWriteDoesNotPublishAnUnsavedAccent() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let otherWriter = LibraryStore(directory: context.directory)
        otherWriter.preferences.accent = .ocean
        XCTAssertNil(otherWriter.errorMessage)
        let url = context.directory.appendingPathComponent(LibraryPersistence.fileName)
        let saved = try Data(contentsOf: url)

        context.model.updatePreferences { $0.accent = .mint }
        XCTAssertNotNil(context.library.errorMessage)
        XCTAssertEqual(context.model.library.preferences.accent, .coral)
        XCTAssertEqual(LibraryStore(directory: context.directory).preferences.accent, .ocean)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testUIKitPaletteColorsAdaptAndMeetTextContrastInBothAppearances() {
        let expected: [(AppAccent, UInt, UInt)] = [
            (.coral, 0xDC3159, 0xFF5A7A),
            (.mint, 0x007A59, 0x4DE0B0),
            (.ocean, 0x086BCE, 0x64B5FF),
            (.violet, 0x7446D1, 0xB79AFF),
            (.amber, 0x936000, 0xFFC15A),
            (.rose, 0xB93080, 0xFF83BB),
            (.teal, 0x007A83, 0x53D7E0),
        ]
        XCTAssertEqual(Set(expected.map(\.0)), Set(AppAccent.allCases))
        for (accent, light, dark) in expected {
            let color = UIColor(accent.color)
            assertColor(color, appearance: .light, hex: light, name: accent.title)
            assertColor(color, appearance: .dark, hex: dark, name: accent.title)
        }
    }

    func testBundledAccentAssetUsesCoralInBothAppearances() throws {
        let color = try XCTUnwrap(UIColor(named: "AccentColor", in: Bundle(for: MusicAppModel.self), compatibleWith: nil))
        assertColor(color, appearance: .light, hex: 0xDC3159, name: "AccentColor")
        assertColor(color, appearance: .dark, hex: 0xFF5A7A, name: "AccentColor")
    }

    func testOpaqueAccentControlForegroundMeetsContrastForEveryPaletteAndAppearance() throws {
        for accent in AppAccent.allCases {
            for appearance in [UIUserInterfaceStyle.light, .dark] {
                let foreground = try components(UIColor(AppTheme.onAccent), appearance: appearance)
                let fill = try components(UIColor(accent.color), appearance: appearance)
                XCTAssertEqual(foreground[3], 1)
                XCTAssertEqual(fill[3], 1)
                let foregroundLuminance = luminance(foreground)
                let fillLuminance = luminance(fill)
                let contrast = (max(foregroundLuminance, fillLuminance) + 0.05) / (min(foregroundLuminance, fillLuminance) + 0.05)

                XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(accent.title) foreground on its opaque \(appearance) control fill")
            }
        }
    }

    func testRenderedLibraryPlayButtonUsesItsContrastingForegroundOnBrightAndLightPalettes() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        let cases: [(AppAccent, ColorScheme, UInt, UInt)] = [
            (.mint, .dark, 0x4DE0B0, 0x000000),
            (.amber, .dark, 0xFFC15A, 0x000000),
            (.coral, .dark, 0xFF5A7A, 0x000000),
            (.coral, .light, 0xDC3159, 0xFFFFFF),
        ]
        for (accent, scheme, fill, foreground) in cases {
            context.model.updatePreferences { $0.accent = accent }
            let control = LibraryQueueButtons(tracks: [libraryTestTrack()], title: "Fixture songs", identifier: "rendered.play")
                .frame(width: 320, height: 50)
                .background(AppTheme.background)
                .environment(context.model)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, .large)
                .accentColor(accent.color)
                .tint(accent.color)
            let renderer = ImageRenderer(content: control)
            renderer.scale = 2
            var rendered: CGImage?
            UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
                rendered = renderer.cgImage
            }
            let image = try XCTUnwrap(rendered)
            // Sample inside the first capsule so page-colored pixels can only come from its label and symbol.
            let colors = try renderedColors(image, in: CGRect(x: 48, y: 20, width: 212, height: 60))
            let fillPixels = matchingPixels(fill, in: colors)
            let foregroundPixels = matchingPixels(foreground, in: colors)

            XCTAssertGreaterThan(fillPixels, 500, "\(accent.title) \(scheme) must render the selected accent fill")
            XCTAssertGreaterThan(foregroundPixels, 25, "\(accent.title) \(scheme) must render contrasting Play text and symbol")
        }
    }

    func testSheetChromeAppliesTheSavedAccentWithoutTheRootModifier() async throws {
        let context = try AppModelTestContext()
        addTeardownBlock { @MainActor in try await context.close() }
        context.model.updatePreferences { $0.accent = .mint }

        func render(_ chrome: Bool) throws -> [UInt: Int] {
            let icon = SettingsRowIcon(systemImage: "square.fill")
                .frame(width: 60, height: 60)
                .background(AppTheme.background)
            // Settings is a sheet: it sees the model, but not RootView's `.accentColor`.
            let content = Group {
                if chrome { icon.appSheetChrome() } else { icon }
            }
            .environment(context.model)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            var rendered: CGImage?
            UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { rendered = renderer.cgImage }
            return try renderedColors(try XCTUnwrap(rendered), in: CGRect(x: 0, y: 0, width: 120, height: 120))
        }

        let plain = try render(false)
        XCTAssertEqual(matchingPixels(0x4DE0B0, in: plain), 0, "Without the chrome the icon falls back to a default accent")
        let chromed = try render(true)
        XCTAssertGreaterThan(matchingPixels(0x4DE0B0, in: chromed), 50, "Sheet chrome must draw Settings icons in the saved accent")
        XCTAssertEqual(matchingPixels(0xFF5A7A, in: chromed), 0)
    }

    private func components(_ color: UIColor, appearance: UIUserInterfaceStyle) throws -> [Double] {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        let hasRGB = resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return try XCTUnwrap(hasRGB ? [Double(red), Double(green), Double(blue), Double(alpha)] : nil,
                             "The foreground and fill must resolve to RGB colors")
    }

    private func luminance(_ components: [Double]) -> Double {
        let linear = components.prefix(3).map { value in
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }

    private func renderedColors(_ image: CGImage, in rect: CGRect) throws -> [UInt: Int] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let rgba = buffer.bindMemory(to: UInt8.self)
            var counts: [UInt: Int] = [:]
            for y in Int(rect.minY)..<min(height, Int(rect.maxY)) {
                for x in Int(rect.minX)..<min(width, Int(rect.maxX)) {
                    let index = (y * width + x) * 4
                    guard rgba[index + 3] == 255 else { continue }
                    let rgb = (UInt(rgba[index]) << 16) | (UInt(rgba[index + 1]) << 8) | UInt(rgba[index + 2])
                    counts[rgb, default: 0] += 1
                }
            }
            return counts
        }
    }

    private func matchingPixels(_ expected: UInt, in colors: [UInt: Int]) -> Int {
        colors.reduce(0) { total, entry in
            let matches = [16, 8, 0].allSatisfy { shift in
                abs(Int((entry.key >> shift) & 255) - Int((expected >> shift) & 255)) <= 2
            }
            return total + (matches ? entry.value : 0)
        }
    }

    private func assertColor(_ color: UIColor, appearance: UIUserInterfaceStyle, hex: UInt, name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha), name, file: file, line: line)
        XCTAssertEqual(red, CGFloat((hex >> 16) & 255) / 255, accuracy: 0.0001, name, file: file, line: line)
        XCTAssertEqual(green, CGFloat((hex >> 8) & 255) / 255, accuracy: 0.0001, name, file: file, line: line)
        XCTAssertEqual(blue, CGFloat(hex & 255) / 255, accuracy: 0.0001, name, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.0001, name, file: file, line: line)
        let linear = [red, green, blue].map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        let background: Double = appearance == .dark ? 0 : 1
        let contrast = (max(luminance, background) + 0.05) / (min(luminance, background) + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name) must meet text contrast in \(appearance)", file: file, line: line)
    }
}
