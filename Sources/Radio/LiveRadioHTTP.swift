import Foundation

enum LiveRadioHTTP {
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return config
    }

    static func directory(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        let session = URLSession(configuration: configuration())
        defer { session.invalidateAndCancel() }
        return try await PlaybackDeadline.run(seconds: 12) {
            let (data, response) = try await session.boundedData(for: request, maximumBytes: maximumBytes,
                                                               delegate: LiveRadioRedirects(allowsStreams: false))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType == "application/json" else { throw LiveRadioError.invalidResponse }
            return data
        }
    }
}

/// Each instance belongs to one request; directory redirects are refused and stream redirects stay public HTTPS.
final class LiveRadioRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowsStreams: Bool
    private let lock = NSLock()
    private var redirects = 0

    init(allowsStreams: Bool) { self.allowsStreams = allowsStreams }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        lock.lock()
        redirects += 1
        let allowed = allowsStreams && redirects <= 3 && request.url.map(LiveRadioURLPolicy.permits) == true
        lock.unlock()
        guard allowed else { completionHandler(nil); return }
        var clean = URLRequest(url: request.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        clean.httpShouldHandleCookies = false
        clean.setValue("Breezy/1.0", forHTTPHeaderField: "User-Agent")
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

protocol LiveRadioResolving: Sendable {
    func resolve(_ station: LiveRadioStation) async throws -> LiveRadioConnection
}

/// Redirect targets are ephemeral; favorites retain only the public directory entry.
struct LiveRadioConnection: Sendable {
    let station: LiveRadioStation
    let streamingURL: URL
    let sourceProof: LiveRadioSourceProof

    init(station: LiveRadioStation, streamingURL: URL, sourceProof: LiveRadioSourceProof = .unverified) {
        self.station = station
        self.streamingURL = streamingURL
        self.sourceProof = sourceProof
    }

    /// HLS assets expose their tracks only on the player item; the probe already rejected video variants,
    /// non-HTTPS entries and oversized playlists, so the item's readiness decides the rest.
    func hasPlaylistProof(for assetURL: URL) -> Bool {
        guard assetURL == streamingURL, case .hls = sourceProof else { return false }
        return LiveRadioURLPolicy.permits(assetURL)
    }

    func hasElementaryProof(for assetURL: URL) -> Bool {
        guard !station.isHLS, assetURL == streamingURL, case .elementary(let proof) = sourceProof else { return false }
        return proof.matches(assetURL)
    }
}

actor LiveRadioStreamResolver: LiveRadioResolving {
    func resolve(_ station: LiveRadioStation) async throws -> LiveRadioConnection {
        guard station.isValid else { throw LiveRadioError.invalidStation }
        let session = URLSession(configuration: LiveRadioHTTP.configuration())
        defer { session.invalidateAndCancel() }
        return try await PlaybackDeadline.run(seconds: 12) {
            var request = URLRequest(url: station.streamingURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            request.setValue("Breezy/1.0", forHTTPHeaderField: "User-Agent")
            LiveRadioDiagnostics.record(.probeResponse, .began)
            let received: (URLSessionChunkedBody, URLResponse)
            do {
                received = try await session.chunkedBody(for: request, delegate: LiveRadioRedirects(allowsStreams: true))
            } catch {
                LiveRadioDiagnostics.record(.probeResponse, Task.isCancelled || error is CancellationError ? .cancelled : .failed)
                throw error
            }
            let (body, response) = received
            defer { body.cancel() }
            return try await withTaskCancellationHandler {
                var stage = LiveRadioDiagnostics.Stage.probeResponse
                do {
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                          let url = response.url, LiveRadioURLPolicy.permits(url) else { throw LiveRadioError.unavailable }
                    LiveRadioDiagnostics.record(stage, .passed)
                    stage = .probeMIME
                    let mime = http.mimeType?.lowercased() ?? ""
                    let hls = station.isHLS || ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime)
                    guard hls || LiveRadioElementaryProof.format(contentType: mime, stationCodec: station.codec) != nil else {
                        throw LiveRadioError.invalidStation
                    }
                    LiveRadioDiagnostics.record(stage, .passed)
                    stage = .probeBody
                    let limit = hls ? 65_536 : LiveRadioElementaryProof.maximumBytes
                    if hls, response.expectedContentLength > Int64(limit) { throw LiveRadioError.tooLarge }
                    var data = Data()
                    var elementaryProof: LiveRadioElementaryProof?
                    receiving: for try await chunk in body {
                        try Task.checkCancellation()
                        var rest = chunk[...]
                        while !rest.isEmpty {
                            guard data.count < limit else { throw LiveRadioError.tooLarge }
                            // Slices stop at each 512-byte offset so proof inspection sees the same prefixes however chunks arrive.
                            let boundary = hls ? limit : min(limit, (data.count / 512 + 1) * 512)
                            let take = min(rest.count, boundary - data.count)
                            data.append(rest.prefix(take))
                            rest = rest.dropFirst(take)
                            if !hls, data.count.isMultiple(of: 512) {
                                elementaryProof = LiveRadioElementaryProof.inspect(data, contentType: mime, url: url,
                                                                                   stationCodec: station.codec)
                                if elementaryProof != nil || data.count == limit { break receiving }
                            }
                        }
                    }
                    guard !data.isEmpty else { throw LiveRadioError.invalidResponse }
                    LiveRadioDiagnostics.record(stage, .passed)
                    let sourceProof: LiveRadioSourceProof
                    if hls {
                        stage = .probePlaylist
                        try Self.validatePlaylist(data, base: url)
                        LiveRadioDiagnostics.record(stage, .passed)
                        sourceProof = .hls
                    } else {
                        stage = .probeElementary
                        guard let proof = elementaryProof ?? LiveRadioElementaryProof.inspect(data, contentType: mime, url: url,
                                                                                               stationCodec: station.codec) else {
                            throw LiveRadioError.invalidStation
                        }
                        LiveRadioDiagnostics.record(stage, .passed)
                        sourceProof = .elementary(proof)
                    }
                    LiveRadioDiagnostics.record(.probeComplete, .passed)
                    return LiveRadioConnection(station: station, streamingURL: url, sourceProof: sourceProof)
                } catch {
                    LiveRadioDiagnostics.record(stage, Task.isCancelled || error is CancellationError ? .cancelled : .failed)
                    throw error
                }
            } onCancel: { body.cancel() }
        }
    }

    static func validatePlaylist(_ data: Data, base: URL) throws {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
            throw LiveRadioError.invalidStation
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count <= 1_024 else { throw LiveRadioError.tooLarge }
        var references = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL, LiveRadioURLPolicy.permits(url) else {
                    throw LiveRadioError.invalidStation
                }
                references += 1
            } else if line.hasPrefix("#EXT-X-") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let tag = String(parts[0])
                guard tag != "#EXT-X-I-FRAME-STREAM-INF", tag != "#EXT-X-I-FRAMES-ONLY" else {
                    throw LiveRadioError.invalidStation
                }
                let payload = parts.count == 2 ? parts[1] : Substring()
                let leadingName = payload.prefix(while: isAttributeNameCharacter)
                guard attributeTags.contains(tag) || payload.dropFirst(leadingName.count).first == "=" else { continue }
                let attributes = try playlistAttributes(payload)
                guard attributes["RESOLUTION"] == nil, attributes["TYPE"]?.value.uppercased() != "VIDEO" else {
                    throw LiveRadioError.invalidStation
                }
                if let codecs = attributes["CODECS"]?.value {
                    let families = codecs.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).lowercased().split(separator: ".").first.map(String.init) ?? ""
                    }
                    guard videoCodecs.isDisjoint(with: families) else { throw LiveRadioError.invalidStation }
                }
                for key in ["URI", "SERVER-URI"] {
                    guard let uri = attributes[key] else { continue }
                    guard uri.quoted, !uri.value.isEmpty,
                          let url = URL(string: uri.value, relativeTo: base)?.absoluteURL,
                          LiveRadioURLPolicy.permits(url) else { throw LiveRadioError.invalidStation }
                    references += 1
                }
            }
        }
        guard references > 0 else { throw LiveRadioError.invalidStation }
    }

    private static let attributeTags: Set<String> = [
        "#EXT-X-KEY", "#EXT-X-SESSION-KEY", "#EXT-X-MAP", "#EXT-X-MEDIA", "#EXT-X-STREAM-INF",
        "#EXT-X-SESSION-DATA", "#EXT-X-DATERANGE", "#EXT-X-START", "#EXT-X-DEFINE", "#EXT-X-PART",
        "#EXT-X-PART-INF", "#EXT-X-SERVER-CONTROL", "#EXT-X-PRELOAD-HINT", "#EXT-X-RENDITION-REPORT", "#EXT-X-SKIP",
        "#EXT-X-CONTENT-STEERING"
    ]
    private static let videoCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "vp08", "vp09", "av01", "dvh1", "dvhe"]

    private static func isAttributeNameCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    /// Quoted commas belong to values, including CODECS lists and URLs; duplicate names are ambiguous and rejected.
    private static func playlistAttributes(_ payload: Substring) throws -> [String: (value: String, quoted: Bool)] {
        var remaining = payload
        var result: [String: (value: String, quoted: Bool)] = [:]
        while !remaining.isEmpty {
            remaining = remaining.drop(while: { $0 == " " || $0 == "\t" })
            let name = remaining.prefix(while: isAttributeNameCharacter)
            guard !name.isEmpty, name.count <= 64, result.count < 64 else { throw LiveRadioError.invalidStation }
            let key = name.uppercased()
            // Some broadcasters (All India Radio) repeat CODECS; both lists are kept so the video check sees each.
            guard result[key] == nil || key == "CODECS" else { throw LiveRadioError.invalidStation }
            remaining = remaining.dropFirst(name.count).drop(while: { $0 == " " || $0 == "\t" })
            guard remaining.first == "=" else { throw LiveRadioError.invalidStation }
            remaining = remaining.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            let quoted = remaining.first == "\""
            let value: String
            if quoted {
                remaining = remaining.dropFirst()
                guard let end = remaining.firstIndex(of: "\"") else { throw LiveRadioError.invalidStation }
                value = String(remaining[..<end])
                remaining = remaining[remaining.index(after: end)...]
            } else {
                let raw = remaining.prefix(while: { $0 != "," })
                value = raw.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !value.contains("\"") else { throw LiveRadioError.invalidStation }
                remaining = remaining.dropFirst(raw.count)
            }
            if let earlier = result[key] {
                result[key] = (earlier.value + "," + value, earlier.quoted && quoted)
            } else {
                result[key] = (value, quoted)
            }
            remaining = remaining.drop(while: { $0 == " " || $0 == "\t" })
            if remaining.isEmpty { break }
            guard remaining.first == "," else { throw LiveRadioError.invalidStation }
            remaining = remaining.dropFirst()
            guard !remaining.isEmpty else { throw LiveRadioError.invalidStation }
        }
        guard !result.isEmpty else { throw LiveRadioError.invalidStation }
        return result
    }
}
