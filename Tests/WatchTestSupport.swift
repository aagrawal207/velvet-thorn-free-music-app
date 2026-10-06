import Foundation
import XCTest
#if os(watchOS)
@testable import GanaBajanaWatch
#else
@testable import GanaBajana
#endif

@MainActor
final class WatchTestTransport: WatchTransport {
    struct Message {
        let data: Data
        let completion: @Sendable (Result<Data, WatchTransportFailure>) -> Void
    }

    var state: WatchConnectionState = .ready(reachable: true, installed: true, needsUnlock: false)
    var onEvent: (@MainActor (WatchTransportEvent) -> Void)?
    var automaticResponse: (@MainActor (CompanionRequest) -> CompanionResponse?)?
    var rejectsContext = false
    private(set) var activationCount = 0
    private(set) var messages: [Message] = []
    private(set) var contexts: [Data] = []
    private(set) var contextAttempts = 0

    var requests: [CompanionRequest] {
        messages.compactMap { try? CompanionWire.decode(CompanionRequest.self, from: $0.data) }
    }

    func activate() { activationCount += 1 }
    func refreshState() { onEvent?(.stateChanged(state)) }

    func send(_ data: Data, completion: @escaping @Sendable (Result<Data, WatchTransportFailure>) -> Void) {
        messages.append(Message(data: data, completion: completion))
        if let request = try? CompanionWire.decode(CompanionRequest.self, from: data),
           let response = automaticResponse?(request), let reply = try? CompanionWire.encode(response) {
            completion(.success(reply))
        }
    }

    func updateApplicationContext(_ data: Data) throws {
        contextAttempts += 1
        if rejectsContext { throw WatchTransportFailure.deliveryFailed }
        contexts.append(data)
    }

    func changeState(_ state: WatchConnectionState) {
        self.state = state
        onEvent?(.stateChanged(state))
    }

    func reply(at index: Int, snapshot: CompanionSnapshot = WatchTestSupport.snapshot(), accepted: Bool = true,
               id: UUID? = nil, page: CompanionPage? = nil, error: String? = nil,
               executionLease: CompanionExecutionLease? = nil, includeLease: Bool = true) throws {
        let request = try CompanionWire.decode(CompanionRequest.self, from: messages[index].data)
        let response = WatchTestSupport.response(for: request, snapshot: snapshot, accepted: accepted, id: id,
                                                  page: page, error: error, executionLease: executionLease, includeLease: includeLease)
        messages[index].completion(.success(try CompanionWire.encode(response)))
    }
}

enum WatchTestSupport {
    static let sessionID = UUID(uuidString: "AB181E8F-55B4-4AE8-B2EC-8470038A1800")!

    static func snapshot(
        sessionID: UUID = WatchTestSupport.sessionID, sequence: UInt64 = 1, position: Double = 42, duration: Double = 214,
        playing: Bool = true, loading: Bool = false, favorite: Bool = false, superLiked: Bool = false, error: String? = nil,
        empty: Bool = false, trackID: String = "watch-test-track", title: String = "A quiet evening",
        artist: String = "Breezy Sessions", shuffle: Bool = false, repeatMode: CompanionRepeatMode = .off,
        libraryError: String? = nil, accent: CompanionAccent? = nil
    ) -> CompanionSnapshot {
        CompanionSnapshot(sessionID: sessionID, sequence: sequence,
                          updatedAt: Date(timeIntervalSince1970: 1_750_000_000), nowPlaying: empty ? nil : CompanionNowPlaying(
                            trackID: trackID, title: title, artist: artist, position: position, duration: duration,
                            isPlaying: playing, isLoading: loading, isFavorite: favorite, isSuperLiked: superLiked,
                            shuffleEnabled: shuffle, repeatMode: repeatMode, errorMessage: error
                          ), libraryError: libraryError, accent: accent)
    }

    static func response(
        for request: CompanionRequest, snapshot: CompanionSnapshot = WatchTestSupport.snapshot(), accepted: Bool = true,
        id: UUID? = nil, page: CompanionPage? = nil, error: String? = nil,
        executionLease: CompanionExecutionLease? = nil, includeLease: Bool = true
    ) -> CompanionResponse {
        let lease = executionLease ?? (includeLease && request.action == .snapshot && accepted
            ? CompanionExecutionLease(id: UUID(), sessionID: snapshot.sessionID) : nil)
        return CompanionResponse(id: id ?? request.id, accepted: accepted, snapshot: snapshot,
                                 page: page, error: error, executionLease: lease)
    }

    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        #if os(watchOS)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WatchRequestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        #else
        try await PlaybackTestSupport.waitUntil(timeout: 2, condition)
        #endif
    }

    static func waitForDeadline(_ deadline: WatchTestDeadline, startedCount: Int = 1) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let started = await deadline.startedCount
            let waiting = await deadline.waiterCount
            if started >= startedCount, waiting > 0 { return }
            guard ContinuousClock.now < limit else { throw WatchRequestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

actor WatchTestDeadline {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private(set) var startedCount = 0
    var waiterCount: Int { waiters.count }

    func wait() async throws {
        startedCount += 1
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func fire() {
        let current = waiters.values
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

final class WatchReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}

@MainActor
final class WatchPhonePlaybackSpy {
    var snapshot = WatchTestSupport.snapshot(playing: false)
    var requests: [CompanionRequest] = []
    var observers: [UUID: @MainActor (CompanionSnapshot) -> Void] = [:]

    func handle(_ request: CompanionRequest) -> CompanionResponse {
        requests.append(request)
        return WatchTestSupport.response(for: request, snapshot: snapshot)
    }

    func observe(_ observer: @escaping @MainActor (CompanionSnapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return id
    }

    func publish(_ snapshot: CompanionSnapshot) {
        self.snapshot = snapshot
        for observer in observers.values { observer(snapshot) }
    }
}
