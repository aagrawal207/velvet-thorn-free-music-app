import Foundation

enum WatchRequestError: Error, Equatable, Sendable {
    case unreachable
    case busy
    case timedOut
    case connectionChanged
    case invalidReply
    case mismatchedReply
    case deliveryFailed
    case staleContext
    case leaseUnavailable
    case preflightRejected
}

@MainActor
final class WatchRequestClient {
    nonisolated static let replyDeadline: TimeInterval = 8

    private struct Pending {
        let request: CompanionRequest
        let generation: UUID
        let continuation: CheckedContinuation<CompanionResponse, any Error>
        let deadline: Task<Void, Never>
        let expiresAt: TimeInterval
    }

    private let transport: any WatchTransport
    private let waitForDeadline: @Sendable () async throws -> Void
    private let uptime: @MainActor () -> TimeInterval
    private var pending: [UUID: Pending] = [:]
    private var generation = UUID()
    private var mutationReservation: UUID?
    private var started = false

    private(set) var state: WatchConnectionState
    var onStateChange: (@MainActor (WatchConnectionState) -> Void)?
    var onSnapshot: (@MainActor (CompanionSnapshot) -> Void)?

    init(
        transport: any WatchTransport,
        waitForDeadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(8)) },
        uptime: @escaping @MainActor () -> TimeInterval = { WatchClock.now }
    ) {
        self.transport = transport
        self.waitForDeadline = waitForDeadline
        self.uptime = uptime
        state = transport.state
    }

    func start() {
        guard !started else { return }
        started = true
        transport.onEvent = { [weak self] event in self?.receive(event) }
        transport.activate()
        state = transport.state
        onStateChange?(state)
    }

    func refreshConnection() {
        transport.activate()
        transport.refreshState()
    }

    func request(
        _ request: CompanionRequest,
        displayed: CompanionSnapshot? = nil,
        validateBeforeMutation: @MainActor (CompanionSnapshot) -> Bool = { _ in true },
        willSendMutation: @MainActor () -> Void = {}
    ) async throws -> CompanionResponse {
        try Task.checkCancellation()
        try request.validate()
        if WatchActionPolicy.isReadOnly(request.action) { return try await send(request) }
        guard state.canMessage, transport.state.canMessage else { throw WatchRequestError.unreachable }
        guard let displayed, request.expectedTrackID == displayed.nowPlaying?.trackID else {
            throw WatchRequestError.staleContext
        }
        guard mutationReservation == nil else { throw WatchRequestError.busy }
        let reservation = UUID()
        let generation = self.generation
        mutationReservation = reservation
        defer { if mutationReservation == reservation { mutationReservation = nil } }

        let preflight = try await send(CompanionRequest(action: .snapshot))
        try Task.checkCancellation()
        guard preflight.accepted else { throw WatchRequestError.preflightRejected }
        guard let lease = preflight.executionLease else { throw WatchRequestError.leaseUnavailable }
        guard lease.sessionID == displayed.sessionID,
              WatchActionPolicy.matches(request.action, displayed: displayed, current: preflight.snapshot) else {
            throw WatchRequestError.staleContext
        }
        let authorized = CompanionRequest(version: request.version, id: request.id, action: request.action,
                                          expectedTrackID: request.expectedTrackID, executionLease: lease)
        // The mutation's deadline starts after lease issuance; a delayed first delivery still expires on the phone.
        return try await send(authorized) {
            guard self.generation == generation, self.mutationReservation == reservation,
                  validateBeforeMutation(preflight.snapshot) else { throw WatchRequestError.staleContext }
            willSendMutation()
        }
    }

    private func send(
        _ request: CompanionRequest,
        beforeSend: @MainActor () throws -> Void = {}
    ) async throws -> CompanionResponse {
        try Task.checkCancellation()
        let data = try CompanionWire.encode(request)
        guard state.canMessage, transport.state.canMessage else { throw WatchRequestError.unreachable }
        guard pending.count < 4, pending[request.id] == nil else { throw WatchRequestError.busy }
        if !WatchActionPolicy.isReadOnly(request.action),
           pending.values.contains(where: { !WatchActionPolicy.isReadOnly($0.request.action) }) {
            throw WatchRequestError.busy
        }
        let generation = self.generation
        let response: CompanionResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do { try beforeSend() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = Task { [weak self, waitForDeadline] in
                    do { try await waitForDeadline() } catch { return }
                    self?.finish(request.id, generation: generation, result: .failure(WatchRequestError.timedOut))
                }
                pending[request.id] = Pending(request: request, generation: generation,
                                              continuation: continuation, deadline: deadline,
                                              expiresAt: uptime() + Self.replyDeadline)
                transport.send(data) { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.receiveReply(result, id: request.id, generation: generation)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(request.id, generation: generation, result: .failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        return response
    }

    func cancelAll() {
        retirePending(with: CancellationError())
    }

    private func receive(_ event: WatchTransportEvent) {
        switch event {
        case .stateChanged(let newState):
            if state.canMessage && !newState.canMessage {
                retirePending(with: WatchRequestError.connectionChanged)
            }
            state = newState
            onStateChange?(newState)
        case .deactivated:
            retirePending(with: WatchRequestError.connectionChanged)
            state = .inactive
            onStateChange?(state)
            transport.activate()
        case .applicationContext(let data):
            guard let snapshot = try? CompanionWire.decode(CompanionSnapshot.self, from: data) else { return }
            onSnapshot?(snapshot)
        case .request(_, let reply):
            reply.finish(Data())
        }
    }

    private func receiveReply(_ result: Result<Data, WatchTransportFailure>, id: UUID, generation: UUID) {
        guard let request = pending[id], request.generation == generation else { return }
        guard uptime() < request.expiresAt else {
            finish(id, generation: generation, result: .failure(WatchRequestError.timedOut))
            return
        }
        switch result {
        case .failure:
            finish(id, generation: generation, result: .failure(WatchRequestError.deliveryFailed))
        case .success(let data):
            do {
                let response = try CompanionWire.decode(CompanionResponse.self, from: data)
                guard response.id == id else {
                    finish(id, generation: generation, result: .failure(WatchRequestError.mismatchedReply))
                    return
                }
                finish(id, generation: generation, result: .success(response))
            } catch {
                finish(id, generation: generation, result: .failure(WatchRequestError.invalidReply))
            }
        }
    }

    private func finish(_ id: UUID, generation: UUID, result: Result<CompanionResponse, any Error>) {
        guard let request = pending[id], request.generation == generation else { return }
        pending.removeValue(forKey: id)
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func retirePending(with error: any Error) {
        generation = UUID()
        mutationReservation = nil
        let retired = pending.values
        pending.removeAll()
        for request in retired {
            request.deadline.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
