import Foundation
import YouTubeKit

@MainActor
final class ExtractorUpdateStore {
    struct Record: Codable, Equatable {
        let envelope: Data
        let source: ExtractorUpdateSource
    }

    struct State: Codable {
        var version = 1
        var highestRevision: Int64 = 0
        var active: Record?
        var knownGood: Record?
        var previousKnownGood: Record?
    }

    private struct Disk: Codable {
        let version: Int
        let payload: Data
        let sha256: String
    }

    static let maximumDiskBytes = 393_216
    private(set) var state = State()
    private(set) var failure: ExtractorUpdateFailure?
    private(set) var recoveredUnconfirmed = false
    private let fileURL: URL
    private let app: ExtractorAppCompatibility
    private let trustedKeys: [String: Data]
    private let feedKeys: [String: Data]
    private var diskBaseline: Data?
    private let write: (Data, URL) throws -> Void

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GanaBajana/ExtractorUpdates", isDirectory: true)
    }

    init(directory: URL, app: ExtractorAppCompatibility, trustedKeys: [String: Data] = [:], feedKeys: [String: Data] = [:],
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.fileURL = directory.appendingPathComponent("state.json")
        self.app = app
        self.trustedKeys = trustedKeys
        self.feedKeys = feedKeys
        self.write = write
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let data = try ExtractorUpdateFile.read(fileURL, maximumBytes: Self.maximumDiskBytes)
            diskBaseline = data
            let object = try ExtractorUpdateValidator.boundedObject(data, maximumBytes: Self.maximumDiskBytes)
            try ExtractorUpdateValidator.keys(object, required: ["version", "payload", "sha256"])
            let disk = try JSONDecoder().decode(Disk.self, from: data)
            guard disk.version == 1, ExtractorUpdateValidator.hash(disk.payload) == disk.sha256 else {
                throw ExtractorUpdateFailure.storage
            }
            let stateObject = try ExtractorUpdateValidator.boundedObject(disk.payload, maximumBytes: Self.maximumDiskBytes)
            try ExtractorUpdateValidator.keys(stateObject, required: ["version", "highestRevision"], optional: ["active", "knownGood", "previousKnownGood"])
            var loaded = try JSONDecoder().decode(State.self, from: disk.payload)
            guard loaded.version == 1, (0...9_007_199_254_740_991).contains(loaded.highestRevision) else {
                throw ExtractorUpdateFailure.storage
            }
            for record in [loaded.active, loaded.knownGood, loaded.previousKnownGood].compactMap({ $0 }) {
                do {
                    let checked = try validate(record)
                    guard checked.payload.revision <= loaded.highestRevision else { throw ExtractorUpdateFailure.storage }
                } catch ExtractorUpdateFailure.incompatibleBuild {
                    // An app upgrade can retire old build ranges without resetting the revision floor.
                    continue
                }
            }
            if let good = loaded.knownGood, (try? validate(good)) == nil { loaded.knownGood = nil }
            if let previous = loaded.previousKnownGood, (try? validate(previous)) == nil { loaded.previousKnownGood = nil }
            if loaded.active != loaded.knownGood {
                loaded.active = loaded.knownGood
                recoveredUnconfirmed = true
                try commit(loaded)
            } else {
                state = loaded
                if let active = loaded.active, (try? validate(active)) == nil { state.active = nil }
            }
        } catch {
            state = State()
            failure = .storage
        }
    }

    var active: ValidatedExtractorUpdate? { state.active.flatMap { try? validate($0) } }
    func activate(_ candidate: ValidatedExtractorUpdate) throws {
        let checked = try ExtractorUpdateValidator.validate(candidate.envelope, source: candidate.source, app: app,
                                                           trustedKeys: candidate.source == .signedFeed ? feedKeys : trustedKeys,
                                                           after: state.highestRevision)
        var next = state
        next.highestRevision = checked.payload.revision
        next.active = .init(envelope: checked.envelope, source: checked.source)
        try commit(next)
    }

    func confirmWorking() throws {
        guard let active = state.active, active != state.knownGood else { return }
        var next = state
        next.previousKnownGood = next.knownGood
        next.knownGood = active
        try commit(next)
    }

    func rollback() throws {
        var next = state
        if next.active != next.knownGood {
            next.active = next.knownGood
        } else {
            next.active = next.previousKnownGood
            next.knownGood = next.previousKnownGood
            next.previousKnownGood = nil
        }
        try commit(next)
    }

    func useBundled() throws {
        guard state.active != nil || state.knownGood != nil else { return }
        var next = state
        next.active = nil
        // Keep the last working package available, but do not reactivate it automatically on restart.
        next.previousKnownGood = next.knownGood
        next.knownGood = nil
        try commit(next)
    }

    private func validate(_ record: Record) throws -> ValidatedExtractorUpdate {
        try ExtractorUpdateValidator.validate(record.envelope, source: record.source, app: app,
                                             trustedKeys: record.source == .signedFeed ? feedKeys : trustedKeys)
    }

    private func commit(_ next: State) throws {
        guard failure == nil else { throw ExtractorUpdateFailure.storage }
        do {
            let current = FileManager.default.fileExists(atPath: fileURL.path)
                ? try ExtractorUpdateFile.read(fileURL, maximumBytes: Self.maximumDiskBytes) : nil
            guard current == diskBaseline else { throw ExtractorUpdateFailure.storageChanged }
            let payload = try JSONEncoder().encode(next)
            let data = try JSONEncoder().encode(Disk(version: 1, payload: payload, sha256: ExtractorUpdateValidator.hash(payload)))
            guard data.count <= Self.maximumDiskBytes else { throw ExtractorUpdateFailure.tooLarge }
            var directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
            try write(data, fileURL)
            diskBaseline = data
            state = next
        } catch let error as ExtractorUpdateFailure { throw error }
        catch { throw ExtractorUpdateFailure.storage }
    }
}
