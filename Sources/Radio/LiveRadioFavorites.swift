import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LiveRadioFavorites {
    static let capacity = 200
    static let maximumBytes = 2_097_152
    private struct Document: Codable {
        var version = 1
        var stations: [LiveRadioStation] = []
    }

    private(set) var stations: [LiveRadioStation] = []
    private(set) var errorMessage: String?
    private(set) var requiresReload = false
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var baseline: Data?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "LiveRadio")

    /// Nil is explicitly memory-only for fixtures and unit hosts.
    init(url: URL?) {
        self.url = url
        reload()
    }

    static func defaultURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GanaBajana", isDirectory: true).appendingPathComponent("live-radio-favorites.json")
    }

    func contains(_ station: LiveRadioStation) -> Bool { stations.contains { $0.id == station.id } }

    func reload() {
        do {
            let data = try readDisk()
            let document = try data.map { try JSONDecoder().decode(Document.self, from: $0) } ?? Document()
            guard document.version == 1, document.stations.count <= Self.capacity,
                  Set(document.stations.map(\.id)).count == document.stations.count,
                  document.stations.allSatisfy(\.isValid) else { throw LiveRadioError.storage }
            stations = document.stations
            baseline = data
            requiresReload = false
            errorMessage = nil
        } catch {
            requiresReload = true
            errorMessage = LiveRadioError.storage.localizedDescription
            log.error("event=live_radio_favorites operation=load outcome=preserved")
        }
    }

    @discardableResult
    func toggle(_ station: LiveRadioStation) -> Bool {
        guard !requiresReload else { return false }
        do {
            guard station.isValid else { throw LiveRadioError.invalidStation }
            var next = stations
            if let index = next.firstIndex(where: { $0.id == station.id }) { next.remove(at: index) }
            else {
                guard next.count < Self.capacity else {
                    errorMessage = "You can save up to 200 stations. Remove one before adding another."
                    return false
                }
                next.append(station)
            }
            let data = try JSONEncoder().encode(Document(stations: next))
            guard data.count <= Self.maximumBytes else { throw LiveRadioError.storage }
            if let url {
                guard try readDisk() == baseline else { requiresReload = true; throw LiveRadioError.storage }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                baseline = data
            }
            stations = next
            errorMessage = nil
            log.info("event=live_radio_favorites operation=write outcome=success count=\(next.count)")
            return true
        } catch {
            errorMessage = LiveRadioError.storage.localizedDescription
            log.error("event=live_radio_favorites operation=write outcome=preserved")
            return false
        }
    }

    private func readDisk() throws -> Data? {
        guard let url else { return nil }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch {
            // FileHandle can report Cocoa 4/260 or POSIX ENOENT; permission and path-shape errors must still block writes.
            if Self.isMissingFile(error) { return nil }
            throw error
        }
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, Self.maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximumBytes else { throw LiveRadioError.storage }
        }
        return data
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return error.code == Int(POSIXErrorCode.ENOENT.rawValue) }
        guard error.domain == NSCocoaErrorDomain,
              error.code == CocoaError.Code.fileReadNoSuchFile.rawValue || error.code == CocoaError.Code.fileNoSuchFile.rawValue else { return false }
        // Only a missing-file wrapper may be inspected; unrelated failures must never authorize replacement.
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(POSIXErrorCode.ENOENT.rawValue)
        }
        return true
    }
}
