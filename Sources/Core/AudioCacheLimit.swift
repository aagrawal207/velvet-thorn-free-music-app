import Foundation

enum AudioCacheLimit: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case mb250 = "250MiB"
    case mb500 = "500MiB"
    case gb1 = "1GiB"
    case gb2 = "2GiB"
    case gb5 = "5GiB"

    static let defaultLimit: AudioCacheLimit = .gb1

    var id: String { rawValue }

    var bytes: Int64 {
        switch self {
        case .mb250: 250 << 20
        case .mb500: 500 << 20
        case .gb1: 1 << 30
        case .gb2: 2 << 30
        case .gb5: 5 << 30
        }
    }

    /// A separate song bound keeps metadata scans bounded even when audio files are small.
    var maximumSongs: Int {
        switch self {
        case .mb250: 50
        case .mb500: 100
        case .gb1: 200
        case .gb2: 400
        case .gb5: 1_000
        }
    }

    var title: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
