import Foundation

struct AlbumDescription: Equatable, Sendable {
    enum License: String, Sendable {
        case ccBYSA3 = "3.0"
        case ccBYSA4 = "4.0"

        var title: String { "CC BY-SA \(rawValue)" }
    }

    let albumID: String
    let albumTitle: String
    let credits: [ArtistCredit]
    let text: String
    let sourceURL: URL
    let license: License
    let licenseURL: URL
    let isExcerpt: Bool

    var attribution: String { "Wikipedia via YouTube Music" }
}

/// A missing description is a successful lookup; transport failures remain retryable errors.
protocol AlbumDescriptionProviding: Sendable {
    func albumDescription(id: String) async throws -> AlbumDescription?
}
