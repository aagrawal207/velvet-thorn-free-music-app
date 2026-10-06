import Foundation

enum DownloadState: Equatable, Sendable {
    case queued
    case waitingForWiFi
    case downloading(fraction: Double)
    case downloaded(bytes: Int64)
    case failed(reason: String)

    /// Queued, waiting or transferring: the item still wants to finish.
    var isPending: Bool {
        switch self {
        case .queued, .waitingForWiFi, .downloading: true
        case .downloaded, .failed: false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .queued: "Waiting"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .downloading(let fraction): "Downloading \(Self.percent(fraction))"
        case .downloaded: "Downloaded"
        case .failed: "Failed"
        }
    }

    static func percent(_ fraction: Double) -> String {
        let bounded = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        // 100% is shown only by the downloaded state; a transfer that is still validating stays at 99%.
        return "\(Int((min(bounded, 0.99) * 100).rounded(.down)))%"
    }
}

struct DownloadItem: Identifiable, Equatable, Sendable {
    let id: String
    let track: Track
    var state: DownloadState
    let enqueuedAt: Date
    var waitingReason: DownloadWaitingReason?

    var statusTitle: String { waitingReason?.title ?? state.title }

    init(track: Track, state: DownloadState = .queued, enqueuedAt: Date) {
        id = track.id
        self.track = track
        self.state = state
        self.enqueuedAt = enqueuedAt
    }
}

enum DownloadWaitingReason: String, Codable, Sendable {
    case foregroundResolution, processing, connection, storage

    var title: String {
        switch self {
        case .foregroundResolution: "Open Velvet Thorn to refresh the download"
        case .processing: "Waiting to verify audio"
        case .connection: "Waiting for a connection"
        case .storage: "Download queue could not be saved"
        }
    }
}

enum CollectionDownloadState: Equatable, Sendable {
    case none
    case downloading(done: Int, total: Int)
    case downloaded

    var title: String {
        switch self {
        case .none: "Download"
        case .downloading(let done, let total): "Downloading \(done.formatted()) of \(total.formatted())"
        case .downloaded: "Downloaded"
        }
    }
}

/// Identity and URL-free acquisition bookkeeping; display metadata is re-resolved from the library after relaunch.
struct DownloadQueueRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumEntries = 2_000

    var version: Int
    var trackIDs: [String]
    var pending: [BackgroundPendingDownload]?

    init(trackIDs: [String]) {
        version = Self.currentVersion
        self.trackIDs = Array(trackIDs.prefix(Self.maximumEntries))
    }

    static func load(from url: URL) -> DownloadQueueRecord? {
        try? read(from: url)
    }

    static func read(from url: URL) throws -> DownloadQueueRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 2 << 20 else { throw BackgroundDownloadFailure.staging }
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard [1, 2].contains(record.version), record.trackIDs.count <= maximumEntries,
              record.trackIDs.allSatisfy(AudioCache.isProviderTrackID), Set(record.trackIDs).count == record.trackIDs.count else {
            throw BackgroundDownloadFailure.staging
        }
        if record.version == 2 {
            guard let pending = record.pending, pending.map(\.id) == record.trackIDs,
                  Set(pending.map(\.token)).count == pending.count, pending.allSatisfy(\.isValid) else {
                throw BackgroundDownloadFailure.staging
            }
        } else if record.pending != nil {
            throw BackgroundDownloadFailure.staging
        }
        return record
    }

    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2 << 20 else { throw BackgroundDownloadFailure.staging }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

struct BackgroundPendingDownload: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case queued, transferring, staged, failed }
    let id: String
    var token = UUID()
    var enqueuedAt = Date()
    var attempts = 0
    var phase: Phase = .queued
    var expiresAt: Date?
    var retryAt: Date?
    var allowCellular = false
    var metadata: AudioCache.Sidecar?
    var failure: BackgroundDownloadFailure?

    var isValid: Bool {
        (0...3).contains(attempts) && (metadata?.bytes ?? 0) >= 0
            && (metadata?.bytes ?? 0) <= AudioCache.maximumFileBytes
            && metadata?.track == nil
            && (metadata == nil || ["m4a", "wav", "webm"].contains(metadata?.fileExtension ?? ""))
            && (metadata?.duration == nil || PlaybackTiming.validDuration(metadata?.duration) != nil)
            && (metadata?.fileExtension != "webm" || metadata?.quality?.codec == .opus)
            && (phase != .transferring || (metadata != nil && expiresAt != nil))
            && (phase != .staged || metadata != nil)
    }

}
