import Foundation
import OSLog

enum LiveRadioError: Error, LocalizedError, Sendable {
    case invalidStation, invalidFilter, invalidResponse, tooLarge, unavailable, busy, storage

    var errorDescription: String? {
        switch self {
        case .invalidStation: "This station doesn’t offer a supported secure audio stream."
        case .invalidFilter: "Use a two-letter country code and shorter search filters."
        case .invalidResponse, .tooLarge: "The radio directory returned an unreadable response. Try again."
        case .unavailable: "Live radio couldn’t connect. Check your connection and try again."
        case .busy: "The radio directory is busy. Try again shortly."
        case .storage: "Station favorites couldn’t be saved. Your existing file has been kept."
        }
    }
}

struct LiveRadioFilter: Equatable, Sendable {
    var name = ""
    var countryCode = ""
    var language = ""
    var tags = ""

    static let npr = LiveRadioFilter(countryCode: "US", tags: "npr")

    func queryItems() throws -> [URLQueryItem] {
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let tagValues = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard country.isEmpty || (country.utf8.count == 2 && country.utf8.allSatisfy { (65...90).contains($0) }),
              LiveRadioStation.validText(name, maximum: 128), LiveRadioStation.validText(language, maximum: 64),
              LiveRadioStation.validText(tags, maximum: 256), tags.split(separator: ",").count <= 5 else {
            throw LiveRadioError.invalidFilter
        }
        var items = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "hidebroken", value: "true"),
                     URLQueryItem(name: "is_https", value: "true"), URLQueryItem(name: "order", value: "votes"),
                     URLQueryItem(name: "reverse", value: "true")]
        for (key, value) in [("name", name), ("countrycode", country), ("language", language), ("tagList", tagValues.joined(separator: ","))] {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { items.append(URLQueryItem(name: key, value: text)) }
        }
        if !language.isEmpty { items.append(URLQueryItem(name: "languageExact", value: "true")) }
        return items
    }
}

protocol LiveRadioDirectoryProviding: Sendable {
    func search(_ filter: LiveRadioFilter) async throws -> [LiveRadioStation]
}

actor LiveRadioDirectory: LiveRadioDirectoryProviding {
    typealias Transport = @Sendable (URLRequest, Int) async throws -> Data
    static let maximumBytes = 1_048_576
    private let transport: Transport
    private let isEnabled: Bool
    private var mirrors: [String] = []
    private var discoveredAt: ContinuousClock.Instant?
    private var inFlight = 0
    private var lastRequest: ContinuousClock.Instant?
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "LiveRadio")
    private static let bootstrap = ["de1.api.radio-browser.info", "nl1.api.radio-browser.info"]

    init(isEnabled: Bool = true, transport: @escaping Transport = LiveRadioHTTP.directory) {
        self.isEnabled = isEnabled
        self.transport = transport
    }

    func search(_ filter: LiveRadioFilter) async throws -> [LiveRadioStation] {
        guard isEnabled else { throw LiveRadioError.unavailable }
        let query = try filter.queryItems()
        guard inFlight < 2, lastRequest.map({ $0.duration(to: .now) >= .milliseconds(250) }) ?? true else {
            throw LiveRadioError.busy
        }
        inFlight += 1
        lastRequest = .now
        defer { inFlight -= 1 }
        try Task.checkCancellation()
        await discoverMirrors()
        var hosts = mirrors
        for host in Self.bootstrap where !hosts.contains(host) { hosts.append(host) }
        for (attempt, host) in hosts.prefix(3).enumerated() {
            try Task.checkCancellation()
            do {
                let request = try Self.request(host: host, path: "/json/stations/search", query: query)
                let data = try await transport(request, Self.maximumBytes)
                try Task.checkCancellation()
                let stations = try Self.decodeStations(data)
                log.info("event=live_radio_directory outcome=success attempt=\(attempt + 1) count=\(stations.count)")
                return stations
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                log.notice("event=live_radio_directory outcome=failure attempt=\(attempt + 1)")
            }
        }
        throw LiveRadioError.unavailable
    }

    private func discoverMirrors() async {
        guard discoveredAt.map({ $0.duration(to: .now) < .seconds(3_600) }) != true else { return }
        discoveredAt = .now
        // URLSession has no reverse-DNS discovery API; the documented HTTPS mirror endpoint supplies names.
        for host in Self.bootstrap {
            if Task.isCancelled { discoveredAt = nil; return }
            do {
                let request = try Self.request(host: host, path: "/json/servers", query: [])
                let data = try await transport(request, 32_768)
                try Task.checkCancellation()
                mirrors = try Self.decodeMirrors(data).shuffled()
                log.info("event=live_radio_discovery outcome=success count=\(self.mirrors.count)")
                return
            } catch {
                if Task.isCancelled || error is CancellationError { discoveredAt = nil; return }
            }
        }
        log.notice("event=live_radio_discovery outcome=fallback")
    }

    static func request(host: String, path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard validMirror(host), ["/json/servers", "/json/stations/search"].contains(path) else { throw LiveRadioError.invalidResponse }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw LiveRadioError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Breezy/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func validMirror(_ host: String) -> Bool {
        let suffix = ".api.radio-browser.info"
        guard host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && label.count <= 32 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    static func decodeMirrors(_ data: Data) throws -> [String] {
        guard data.count <= 32_768 else { throw LiveRadioError.tooLarge }
        struct Mirror: Decodable { let name: String }
        let rows = try JSONDecoder().decode([Mirror].self, from: data)
        guard rows.count <= 64 else { throw LiveRadioError.tooLarge }
        var seen = Set<String>()
        return Array(rows.map(\.name).filter { validMirror($0) && seen.insert($0).inserted }.prefix(8))
    }

    static func decodeStations(_ data: Data) throws -> [LiveRadioStation] {
        guard data.count <= maximumBytes else { throw LiveRadioError.tooLarge }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LiveRadioError.invalidResponse }
        guard rows.count <= 100 else { throw LiveRadioError.tooLarge }
        var seen = Set<UUID>()
        return rows.compactMap { row in
            guard let rawID = row["stationuuid"] as? String, let id = UUID(uuidString: rawID),
                  let name = row["name"] as? String,
                  let rawURL = row["url_resolved"] as? String, let url = URL(string: rawURL),
                  let codec = row["codec"] as? String, row["lastcheckok"] as? Int == 1,
                  let hls = row["hls"] as? Int, hls == 0 || hls == 1 else { return nil }
            func optionalURL(_ key: String) -> URL? {
                guard let raw = row[key] as? String, let url = URL(string: raw), LiveRadioURLPolicy.permits(url) else { return nil }
                return url
            }
            func list(_ key: String) -> [String] {
                (row[key] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let station = LiveRadioStation(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), streamingURL: url,
                homepageURL: optionalURL("homepage"), artworkURL: optionalURL("favicon"),
                countryCode: (row["countrycode"] as? String ?? "").uppercased(), languages: list("language"),
                tags: list("tags"), codec: codec.uppercased(), isHLS: hls == 1)
            guard station.isValid, seen.insert(id).inserted else { return nil }
            return station
        }
    }
}
