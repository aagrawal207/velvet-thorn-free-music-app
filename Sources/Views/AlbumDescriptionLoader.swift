import Foundation
import Observation
import OSLog

@MainActor @Observable
final class AlbumDescriptionLoader {
    enum State: Equatable {
        case idle, loading, unavailable, failed
        case loaded(AlbumDescription)
    }

    private static let logger = Logger(subsystem: "com.agraabhi.ganabajana", category: "AlbumDescriptions")
    private(set) var collection: MusicCollection?
    private(set) var state: State = .idle
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var work: Task<AlbumDescription?, Error>?
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 6) {
        self.timeout = timeout.isFinite ? min(6, max(0.01, timeout)) : 6
    }

    func reset(for collection: MusicCollection) {
        cancel()
        self.collection = collection
        state = .idle
    }

    func accept(_ description: AlbumDescription?, for collection: MusicCollection) {
        reset(for: collection)
        do { try publish(description, albumID: collection.id) }
        catch { state = .failed }
    }

    func cancel() {
        generation &+= 1
        if work != nil { Self.logger.debug("albumDescriptionCancelled=1") }
        work?.cancel()
        work = nil
        if state == .loading { state = .idle }
    }

    func load(for collection: MusicCollection, using provider: (any AlbumDescriptionProviding)?, retry: Bool = false) async {
        guard !Task.isCancelled else { return }
        if self.collection == collection, !retry {
            switch state {
            case .loaded, .unavailable, .loading, .failed: return
            case .idle: break
            }
        }
        reset(for: collection)
        guard collection.kind == .album, let provider else { state = .unavailable; return }
        state = .loading
        let requestGeneration = generation
        let started = Date()
        let task = Task { [timeout] in
            try await PlaybackDeadline.run(seconds: timeout) { try await provider.albumDescription(id: collection.id) }
        }
        work = task
        defer { if generation == requestGeneration { work = nil } }
        Self.logger.debug("albumDescriptionRetry=\(retry ? 1 : 0)")
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            try publish(result, albumID: collection.id)
            Self.logger.debug("albumDescriptionLoadSuccess=1 albumDescriptionLoadFailure=0 albumDescriptionCancelled=0 albumDescriptionLoadMilliseconds=\(Date().timeIntervalSince(started) * 1_000)")
        } catch {
            guard generation == requestGeneration else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .idle
                Self.logger.debug("albumDescriptionCancelled=1")
            } else {
                state = .failed
                Self.logger.debug("albumDescriptionLoadSuccess=0 albumDescriptionLoadFailure=1 albumDescriptionCancelled=0 albumDescriptionLoadMilliseconds=\(Date().timeIntervalSince(started) * 1_000)")
            }
        }
    }

    private func publish(_ description: AlbumDescription?, albumID: String) throws {
        if let description {
            guard description.albumID == albumID else {
                Self.logger.debug("albumDescriptionRejected=1")
                throw MusicServiceError.invalidResponse
            }
            state = .loaded(description)
        } else {
            state = .unavailable
        }
        Self.logger.debug("albumDescriptionRejected=0 albumDescriptionPresent=\(description == nil ? 0 : 1) albumDescriptionMissing=\(description == nil ? 1 : 0)")
    }
}
