import Foundation

enum AppAccent: String, CaseIterable, Codable, Sendable, Identifiable {
    case coral, mint, ocean, violet, amber, rose, teal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
