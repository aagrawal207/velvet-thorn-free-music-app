import Foundation

enum PlaybackStreamError: LocalizedError, Sendable {
    case invalidID, noAudio, invalidMedia, expired, timedOut, signInRequired
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidID: "This song has an invalid YouTube ID."
        case .noAudio: "No playable audio was available for this song. Try again in a moment."
        case .invalidMedia: "The audio service returned an unusable stream. Please try again."
        case .expired: "This audio link has expired. Please try again."
        case .timedOut: "Loading audio took too long. Check your connection and try again."
        case .signInRequired: "YouTube asked this device to confirm it’s not a bot. Signing in to YouTube in Settings fixes this."
        case .httpStatus: "The audio service rejected this link. Please try again."
        }
    }
}

enum PlaybackTiming {
    static func validDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0, value <= 86_400 else { return nil }
        return value
    }

    static func queryNumber(_ name: String, in url: URL) -> Double? {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == name } ?? []
        guard values.count == 1, let text = values[0].value, let number = Double(text), number.isFinite else { return nil }
        return number
    }

    static func duration(stream: ResolvedStream, track: Track) -> TimeInterval? {
        // Catalog results can refer to a shorter recording; the resolved media's duration takes precedence.
        validDuration(queryNumber("dur", in: stream.url)) ?? validDuration(stream.duration) ?? validDuration(track.duration)
    }

    static func expiry(in url: URL) -> Date? {
        guard let seconds = queryNumber("expire", in: url), seconds > 0, seconds < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func position(_ position: TimeInterval, duration: TimeInterval? = nil) -> TimeInterval {
        guard position.isFinite else { return 0 }
        return min(max(0, position), validDuration(duration) ?? 86_400)
    }
}

enum StreamValidation {
    struct ContentRange: Equatable, Sendable {
        let start: Int64
        let end: Int64
        let total: Int64

        var length: Int64 { end - start + 1 }
    }

    static func decimalByteCount(_ text: some StringProtocol) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }

    static func contentLength(in response: HTTPURLResponse) throws -> Int64? {
        guard let text = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        guard let length = decimalByteCount(text) else { throw PlaybackStreamError.invalidMedia }
        return length
    }

    static func contentRange(in response: HTTPURLResponse) throws -> ContentRange {
        guard response.statusCode == 206, let text = response.value(forHTTPHeaderField: "Content-Range"),
              text.hasPrefix("bytes "), response.mimeType?.lowercased().hasPrefix("multipart/") != true else {
            throw PlaybackStreamError.invalidMedia
        }
        let parts = text.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw PlaybackStreamError.invalidMedia }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = decimalByteCount(bounds[0]), let end = decimalByteCount(bounds[1]),
              let total = decimalByteCount(parts[1]), start <= end, end < total else {
            throw PlaybackStreamError.invalidMedia
        }
        let range = ContentRange(start: start, end: end, total: total)
        if let length = try contentLength(in: response), length != range.length { throw PlaybackStreamError.invalidMedia }
        return range
    }

    private static func validateFirstRange(response: HTTPURLResponse, prefix: Data) throws {
        if response.statusCode == 206 {
            let range = try contentRange(in: response)
            guard range.start == 0, range.length >= Int64(prefix.count) else { throw PlaybackStreamError.invalidMedia }
        }
    }

    static func validateWebM(response: HTTPURLResponse, prefix: Data) throws {
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw PlaybackStreamError.httpStatus(response.statusCode)
        }
        guard response.mimeType?.lowercased() == "audio/webm", prefix.count >= 12,
              prefix.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) else { throw PlaybackStreamError.invalidMedia }
        try validateFirstRange(response: response, prefix: prefix)
    }

    static func validate(response: HTTPURLResponse, prefix: Data) throws {
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw PlaybackStreamError.httpStatus(response.statusCode)
        }
        guard ["audio/mp4", "audio/m4a", "audio/x-m4a", "video/mp4"].contains(response.mimeType?.lowercased() ?? ""),
              prefix.count >= 12, String(data: prefix[4..<8], encoding: .ascii) == "ftyp" else {
            throw PlaybackStreamError.invalidMedia
        }
        try validateFirstRange(response: response, prefix: prefix)
    }

    static func validateSourceURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host,
               host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") else {
            throw PlaybackStreamError.invalidMedia
        }
    }

    static func validate(url: URL) async throws {
        try validateSourceURL(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PlaybackStreamError.invalidMedia }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw PlaybackStreamError.httpStatus(http.statusCode)
        }
        var prefix = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            prefix.append(byte)
            if prefix.count == 1024 { break }
        }
        try validate(response: http, prefix: prefix)
    }
}
