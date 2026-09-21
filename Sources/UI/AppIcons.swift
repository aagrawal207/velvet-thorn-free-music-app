import Observation
import SwiftUI
import UIKit

/// One selectable app icon. Asset names follow a fixed scheme: `AppIcon` for the primary set,
/// `AppIcon-<id>` for alternates, and `IconPreview-<id>` for the in-app preview image of every option.
struct AppIconOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let isPrimary: Bool

    var previewImageName: String { "IconPreview-\(id)" }
    var alternateIconName: String? { isPrimary ? nil : "AppIcon-\(id)" }
}

enum AppIcons {
    /// Order matches the generator recipes in tools/generate-artwork.swift; the first entry is the shipped default.
    /// IDs keep saved icon choices, preview assets, and accessibility identifiers stable; titles are display-only.
    static let all: [AppIconOption] = [
        AppIconOption(id: "Beat", title: "Leafnote", isPrimary: true),
        AppIconOption(id: "Dhol", title: "Breeze", isPrimary: false),
        AppIconOption(id: "Notes", title: "Drift", isPrimary: false),
        AppIconOption(id: "Headphones", title: "Airwave", isPrimary: false),
        AppIconOption(id: "Vinyl", title: "Groove", isPrimary: false),
        AppIconOption(id: "Boombox", title: "Moonleaf", isPrimary: false),
        AppIconOption(id: "Cassette", title: "Daybreak", isPrimary: false),
        AppIconOption(id: "Speaker", title: "Ripple", isPrimary: false),
        AppIconOption(id: "Waves", title: "Tide", isPrimary: false),
        AppIconOption(id: "Peacock", title: "Zephyr", isPrimary: false),
        AppIconOption(id: "Mic", title: "Sway", isPrimary: false),
        AppIconOption(id: "Tabla", title: "Hush", isPrimary: false),
        AppIconOption(id: "Sargam", title: "Flutter", isPrimary: false),
        AppIconOption(id: "Bansuri", title: "Loop", isPrimary: false),
    ]

    static var primary: AppIconOption { all[0] }

    /// The primary's named asset remains an alias for installations with that alternate selected.
    static func option(named alternateName: String?) -> AppIconOption {
        guard let alternateName else { return primary }
        return all.first { "AppIcon-\($0.id)" == alternateName } ?? primary
    }
}

/// Reads and changes the home-screen icon. iOS shows its own confirmation alert after a change.
@MainActor @Observable
final class AppIconController {
    private(set) var current: AppIconOption

    init() {
        current = AppIcons.option(named: Self.installedAlternateName)
    }

    var supportsAlternateIcons: Bool {
        Bundle.main.bundleIdentifier != nil && UIApplication.shared.supportsAlternateIcons
    }

    func select(_ option: AppIconOption) async throws {
        guard option != current else { return }
        guard supportsAlternateIcons else { throw AppIconError.unsupported }
        try await UIApplication.shared.setAlternateIconName(option.alternateIconName)
        current = option
    }

    private static var installedAlternateName: String? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UIApplication.shared.alternateIconName
    }
}

enum AppIconError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This device doesn’t allow changing the app icon." }
}
