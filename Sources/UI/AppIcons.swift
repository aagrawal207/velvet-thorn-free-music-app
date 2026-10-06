import Observation
import SwiftUI
import UIKit

/// One selectable app icon. Asset names follow a fixed scheme: `AppIcon` for the primary set,
/// `AppIcon-<id>` for alternates, and `IconPreview-<id>` for the in-app preview image of every option.
struct AppIconOption: Identifiable, Hashable, Sendable {
    enum Family: String, CaseIterable, Sendable {
        case leafnote, thorn, more

        var title: String {
            switch self {
            case .leafnote: "Leafnote"
            case .thorn: "Thorn"
            case .more: "More Icons"
            }
        }
    }

    let id: String
    let title: String
    let isPrimary: Bool
    let family: Family

    init(id: String, title: String, isPrimary: Bool = false, family: Family) {
        self.id = id
        self.title = title
        self.isPrimary = isPrimary
        self.family = family
    }

    var previewImageName: String { "IconPreview-\(id)" }
    var alternateIconName: String? { isPrimary ? nil : "AppIcon-\(id)" }
}

enum AppIcons {
    /// Order matches the generator recipes in tools/generate-artwork.swift; the first entry is the shipped default.
    /// IDs keep saved icon choices, preview assets, and accessibility identifiers stable; titles are display-only.
    static let all: [AppIconOption] = [
        AppIconOption(id: "Beat", title: "Leafnote", isPrimary: true, family: .leafnote),
        AppIconOption(id: "LeafPaper", title: "Paper", family: .leafnote),
        AppIconOption(id: "LeafSky", title: "Sky", family: .leafnote),
        AppIconOption(id: "LeafBlossom", title: "Blossom", family: .leafnote),
        AppIconOption(id: "LeafMidnight", title: "Midnight", family: .leafnote),
        AppIconOption(id: "LeafViolet", title: "Violet", family: .leafnote),
        AppIconOption(id: "LeafSunset", title: "Sunset", family: .leafnote),
        AppIconOption(id: "LeafMono", title: "Mono", family: .leafnote),
        AppIconOption(id: "Thorn", title: "Thorn", family: .thorn),
        AppIconOption(id: "Sonnet", title: "Sonnet", family: .thorn),
        AppIconOption(id: "ThornEdge", title: "Edge", family: .thorn),
        AppIconOption(id: "ThornFrost", title: "Frost", family: .thorn),
        AppIconOption(id: "ThornNoir", title: "Noir", family: .thorn),
        AppIconOption(id: "ThornVenom", title: "Venom", family: .thorn),
        AppIconOption(id: "ThornDusk", title: "Dusk", family: .thorn),
        AppIconOption(id: "ThornBlush", title: "Blush", family: .thorn),
        AppIconOption(id: "Notes", title: "Drift", family: .more),
        AppIconOption(id: "Boombox", title: "Moonleaf", family: .more),
        AppIconOption(id: "Speaker", title: "Ripple", family: .more),
        AppIconOption(id: "Waves", title: "Tide", family: .more),
    ]

    static var primary: AppIconOption { all[0] }

    /// The primary's named asset remains an alias for installations with that alternate selected.
    static func option(named alternateName: String?) -> AppIconOption {
        guard let alternateName else { return primary }
        return all.first { "AppIcon-\($0.id)" == alternateName } ?? primary
    }

    /// False for a retired icon set that an older installation still has selected; the `AppIcon-Beat` alias counts.
    static func isKnown(alternateName: String) -> Bool {
        all.contains { "AppIcon-\($0.id)" == alternateName }
    }
}

@MainActor
protocol AppIconSystem {
    var alternateIconName: String? { get }
    var supportsAlternateIcons: Bool { get }
    func setAlternateIconName(_ name: String?) async throws
    func claimOrphanReset() -> Bool
}

@MainActor
final class UIKitAppIconSystem: AppIconSystem {
    private static var hasRequestedOrphanReset = false

    var alternateIconName: String? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UIApplication.shared.alternateIconName
    }

    var supportsAlternateIcons: Bool {
        Bundle.main.bundleIdentifier != nil && UIApplication.shared.supportsAlternateIcons
    }

    func setAlternateIconName(_ name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }

    // The native reset is process-wide; injected systems keep their own launch state.
    func claimOrphanReset() -> Bool {
        guard !Self.hasRequestedOrphanReset else { return false }
        Self.hasRequestedOrphanReset = true
        return true
    }
}

/// Reads and changes the home-screen icon. iOS shows its own confirmation alert after a change.
@MainActor @Observable
final class AppIconController {
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private var installedAlternateName: String?
    @ObservationIgnored private let system: any AppIconSystem
    @ObservationIgnored private let enabled: Bool
    @ObservationIgnored private var desired: AppIconOption?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var applyTask: Task<Void, Error>?

    init(system: any AppIconSystem = UIKitAppIconSystem(), enabled: Bool = true) {
        self.system = system
        self.enabled = enabled
        installedAlternateName = enabled ? system.alternateIconName : nil
        if hasOrphanedAlternate, supportsAlternateIcons, system.claimOrphanReset() {
            request(AppIcons.primary)
        }
    }

    var current: AppIconOption { AppIcons.option(named: installedAlternateName) }
    var supportsAlternateIcons: Bool { enabled && system.supportsAlternateIcons }

    func request(_ option: AppIconOption) {
        desired = option
        generation = UUID()
        errorMessage = nil
        guard enabled, applyTask == nil else { return }
        installedAlternateName = system.alternateIconName
        guard option != current || hasOrphanedAlternate else { return }
        guard supportsAlternateIcons else {
            errorMessage = AppIconError.unsupported.localizedDescription
            return
        }
        isApplying = true
        applyTask = Task { @MainActor in try await self.applyLatest() }
    }

    /// Awaited callers share the queue; a superseded selection reports cancellation.
    func select(_ option: AppIconOption) async throws {
        try Task.checkCancellation()
        request(option)
        let generation = self.generation
        guard supportsAlternateIcons else {
            if option != current || hasOrphanedAlternate { throw AppIconError.unsupported }
            return
        }
        guard let applyTask else { return }
        let result = await applyTask.result
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        try result.get()
    }

    private var hasOrphanedAlternate: Bool {
        guard let installedAlternateName else { return false }
        return !AppIcons.isKnown(alternateName: installedAlternateName)
    }

    private func applyLatest() async throws {
        defer {
            applyTask = nil
            isApplying = false
        }
        while let option = desired {
            guard option != current || hasOrphanedAlternate else { return }
            guard supportsAlternateIcons else {
                errorMessage = AppIconError.unsupported.localizedDescription
                throw AppIconError.unsupported
            }
            let generation = self.generation
            do {
                // UIKit may finish a change after cancellation, so drain it before applying newer intent.
                try await system.setAlternateIconName(option.alternateIconName)
                installedAlternateName = option.alternateIconName
            } catch {
                installedAlternateName = system.alternateIconName
                guard generation == self.generation else { continue }
                errorMessage = error.localizedDescription
                throw error
            }
            if generation == self.generation { return }
        }
    }
}

enum AppIconError: LocalizedError {
    case unsupported
    var errorDescription: String? { "This device doesn’t allow changing the app icon." }
}
