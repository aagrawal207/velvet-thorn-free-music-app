import Foundation
@testable import GanaBajana

enum LyricsTestFixtures {
    static let liveReferenceRecordings: [(track: Track, sourceID: Int)] = [
        (Track(id: "fsiPzT50ZiM", title: "Tum Hi Ho", artists: ["Arijit Singh"],
               albumTitle: "Aashiqui 2", duration: 262), 9_910_251),
        (Track(id: "NJAv_7lHUIU", title: "Kesariya (From \"Brahmastra\")", artists: ["Arijit Singh"],
               albumTitle: "Kesariya (From \"Brahmastra\")", duration: 269), 11_918_452),
        (Track(id: "FOA9iyxsW_A", title: "AGAR TUM SAATH HO", artists: ["Arijit Singh", "Alka Yagnik"],
               albumTitle: "Tamasha", duration: 342), 16_987_467),
        (Track(id: "J7p4bzqLvCw", title: "Blinding Lights", artists: ["The Weeknd"],
               albumTitle: "Blinding Lights", duration: 202), 511_842),
        (Track(id: "xTvyyoF_LZY", title: "Shape of You", artists: ["Ed Sheeran"],
               albumTitle: "Shape of You", duration: 234), 1_301_175)
    ]

    static let track = Track(id: "synthetic-recording", title: "Paper Satellites", artists: ["Test Singer"],
                             albumTitle: "Imaginary Sky", duration: 200)
    static let lrc = "[00:01.809]An invented lantern lifts\n[00:04.20]\n[00:08.001]Across a paper sky"

    static func record(id: Int = 10, title: String = "Paper Satellites", artist: String = "Test Singer",
                       album: String? = "Imaginary Sky", duration: TimeInterval? = 200,
                       instrumental: Bool = false, plain: String? = nil, synced: String? = lrc) -> LRCLIBRecord {
        LRCLIBRecord(id: id, trackName: title, artistName: artist, albumName: album, duration: duration,
                     instrumental: instrumental, plainLyrics: plain, syncedLyrics: synced)
    }

    static func response(_ record: LRCLIBRecord) throws -> LRCHTTPResponse {
        LRCHTTPResponse(data: try JSONSerialization.data(withJSONObject: json(record)), statusCode: 200)
    }

    static func response(_ records: [LRCLIBRecord]) throws -> LRCHTTPResponse {
        LRCHTTPResponse(data: try JSONSerialization.data(withJSONObject: records.map(json)), statusCode: 200)
    }

    static func clientConfiguration() -> LRCLIBClient.Configuration {
        var configuration = LRCLIBClient.Configuration()
        configuration.minimumRequestInterval = 0
        return configuration
    }

    static func items(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    static func waitForWaiters(_ count: Int, service: LRCLyricsService) async throws {
        for _ in 0..<1_000 {
            if await service.activity.waitingCallers == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw NSError(domain: "LyricsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for callers"])
    }

    private static func json(_ record: LRCLIBRecord) -> [String: Any] {
        var value: [String: Any] = ["id": record.id, "trackName": record.trackName,
                                    "artistName": record.artistName, "instrumental": record.instrumental]
        if let album = record.albumName { value["albumName"] = album }
        if let duration = record.duration { value["duration"] = duration }
        if let plain = record.plainLyrics { value["plainLyrics"] = plain }
        if let synced = record.syncedLyrics { value["syncedLyrics"] = synced }
        return value
    }
}

actor LyricsStubTransport: LRCHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> LRCHTTPResponse
    private(set) var requests: [URLRequest] = []
    private(set) var cancellations = 0
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> LRCHTTPResponse {
        let index = requests.count
        requests.append(request)
        do { return try await handler(request, index) }
        catch {
            if error is CancellationError { cancellations += 1 }
            throw error
        }
    }
}

final class LyricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)

    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

actor LyricsTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
