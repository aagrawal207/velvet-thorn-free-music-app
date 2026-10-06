import Foundation
import Synchronization

/// A response body delivered as the `Data` chunks URLSession receives, instead of `AsyncBytes`' per-byte elements.
/// Callers own byte limits and must `cancel()` when they stop before EOF; leaving the loop does not stop the task.
struct URLSessionChunkedBody: AsyncSequence, Sendable {
    typealias Element = Data

    /// Above `highWaterBytes` of unconsumed chunks the task is suspended; it resumes once the consumer drains to `lowWaterBytes`.
    /// Suspension stops reading, so only chunks already in flight can exceed the high-water mark.
    static let highWaterBytes = 512 << 10
    static let lowWaterBytes = 128 << 10

    let task: URLSessionDataTask
    fileprivate let receiver: ChunkedBodyReceiver

    func cancel() { task.cancel() }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(receiver: receiver) }

    struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        fileprivate let receiver: ChunkedBodyReceiver

        /// Swift task cancellation cancels the URL task and surfaces as `CancellationError`; transport errors keep their type.
        func next() async throws -> Data? { try await receiver.next() }
    }
}

extension URLSession {
    /// Returns once response headers arrive, like `bytes(for:delegate:)`. Cancelling the caller cancels only this task.
    /// The optional delegate receives redirect, authentication-challenge, connectivity and metrics callbacks.
    func chunkedBody(for request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (URLSessionChunkedBody, URLResponse) {
        try await chunkedBody(task: dataTask(with: request), delegate: delegate)
    }

    /// Uses `dataTask(with: URL)` so the session configuration supplies the request defaults, as `bytes(from:)` does.
    func chunkedBody(from url: URL, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (URLSessionChunkedBody, URLResponse) {
        try await chunkedBody(task: dataTask(with: url), delegate: delegate)
    }

    private func chunkedBody(task: URLSessionDataTask, delegate: (any URLSessionTaskDelegate)?) async throws -> (URLSessionChunkedBody, URLResponse) {
        let receiver = ChunkedBodyReceiver(task: task, forwarding: delegate)
        task.delegate = receiver
        if Task.isCancelled {
            task.cancel()
            throw CancellationError()
        }
        let response = try await receiver.response()
        return (URLSessionChunkedBody(task: task, receiver: receiver), response)
    }
}

/// One receiver per task. Unchecked only because the forwarded delegate existential is not statically Sendable;
/// it is immutable and every mutable field lives behind the mutex.
final class ChunkedBodyReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum Outcome {
        case running
        case finished
        case failed(any Error)
    }

    private struct State {
        // Released at completion: the task retains its delegate, so holding it longer would be a cycle.
        var task: URLSessionDataTask?
        var responseWaiter: CheckedContinuation<URLResponse, any Error>?
        var response: URLResponse?
        var responseAbandoned = false
        var chunks: [Data] = []
        var head = 0
        var bufferedBytes = 0
        var suspended = false
        var outcome = Outcome.running
        var chunkWaiter: CheckedContinuation<Data?, any Error>?
    }

    private let forwarding: (any URLSessionTaskDelegate)?
    private let state: Mutex<State>

    init(task: URLSessionDataTask, forwarding: (any URLSessionTaskDelegate)?) {
        self.forwarding = forwarding
        state = Mutex(State(task: task))
    }

    private func cancelTask() {
        state.withLock { $0.task }?.cancel()
    }

    func response() async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, any Error>) in
                let (immediate, task): (Result<URLResponse, any Error>?, URLSessionDataTask?) = state.withLock { state in
                    if state.responseAbandoned { return (.failure(CancellationError()), nil) }
                    if let response = state.response { return (.success(response), nil) }
                    if case .failed(let error) = state.outcome { return (.failure(error), nil) }
                    if case .finished = state.outcome { return (.failure(URLError(.badServerResponse)), nil) }
                    state.responseWaiter = continuation
                    return (nil, state.task)
                }
                if let immediate { continuation.resume(with: immediate) } else { task?.resume() }
            }
        } onCancel: {
            let (waiter, task): (CheckedContinuation<URLResponse, any Error>?, URLSessionDataTask?) = state.withLock { state in
                state.responseAbandoned = true
                defer { state.responseWaiter = nil }
                return (state.responseWaiter, state.task)
            }
            task?.cancel()
            waiter?.resume(throwing: CancellationError())
        }
    }

    func next() async throws -> Data? {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
                    let immediate: Result<Data?, any Error>? = state.withLock { state in
                        if let chunk = Self.dequeue(&state) { return .success(chunk) }
                        switch state.outcome {
                        case .finished: return .success(nil)
                        case .failed(let error): return .failure(error)
                        case .running:
                            state.chunkWaiter = continuation
                            return nil
                        }
                    }
                    if let immediate { continuation.resume(with: immediate) }
                }
            } onCancel: {
                cancelTask()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func dequeue(_ state: inout State) -> Data? {
        guard state.head < state.chunks.count else { return nil }
        let chunk = state.chunks[state.head]
        state.chunks[state.head] = Data()
        state.head += 1
        if state.head == state.chunks.count {
            state.chunks.removeAll(keepingCapacity: true)
            state.head = 0
        }
        state.bufferedBytes -= chunk.count
        // Resuming under the lock orders it against a concurrent suspend from the delegate queue.
        if state.suspended, state.bufferedBytes <= URLSessionChunkedBody.lowWaterBytes {
            state.suspended = false
            state.task?.resume()
        }
        return chunk
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let waiter: CheckedContinuation<URLResponse, any Error>? = state.withLock { state in
            state.response = response
            defer { state.responseWaiter = nil }
            return state.responseWaiter
        }
        completionHandler(.allow)
        waiter?.resume(returning: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        let waiter: CheckedContinuation<Data?, any Error>? = state.withLock { state in
            guard case .running = state.outcome else { return nil }
            if let waiter = state.chunkWaiter, state.head == state.chunks.count {
                state.chunkWaiter = nil
                return waiter
            }
            state.chunks.append(data)
            state.bufferedBytes += data.count
            if !state.suspended, state.bufferedBytes >= URLSessionChunkedBody.highWaterBytes {
                state.suspended = true
                dataTask.suspend()
            }
            return nil
        }
        waiter?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (responseWaiter, chunkWaiter): (CheckedContinuation<URLResponse, any Error>?, CheckedContinuation<Data?, any Error>?) = state.withLock { state in
            state.outcome = error.map { Outcome.failed($0) } ?? .finished
            state.task = nil
            let responseWaiter = state.responseWaiter
            state.responseWaiter = nil
            let chunkWaiter = state.chunkWaiter
            state.chunkWaiter = nil
            return (responseWaiter, chunkWaiter)
        }
        responseWaiter?.resume(throwing: error ?? URLError(.badServerResponse))
        if let error { chunkWaiter?.resume(throwing: error) } else { chunkWaiter?.resume(returning: nil) }
    }

    // MARK: Forwarded task callbacks

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if forwarding?.urlSession?(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                                   completionHandler: completionHandler) == nil {
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if forwarding?.urlSession?(session, task: task, didReceive: challenge, completionHandler: completionHandler) == nil {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        forwarding?.urlSession?(session, taskIsWaitingForConnectivity: task)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        forwarding?.urlSession?(session, task: task, didFinishCollecting: metrics)
    }
}
