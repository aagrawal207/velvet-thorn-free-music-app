import Foundation

/// Pending bodies are checked before each append. The lock also serializes timeout and completion races.
@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
final class ExtractionDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let task: URLSessionDataTask
        let maximumBytes: Int
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
        let deadline: DispatchWorkItem
        var response: URLResponse?
        var data = Data()

        init(task: URLSessionDataTask, maximumBytes: Int, continuation: CheckedContinuation<(Data, URLResponse), Error>,
             deadline: DispatchWorkItem) {
            self.task = task
            self.maximumBytes = maximumBytes
            self.continuation = continuation
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let redirectDelegate: URLSessionTaskDelegate?

    init(redirectDelegate: URLSessionTaskDelegate?) {
        self.redirectDelegate = redirectDelegate
    }

    func data(for request: URLRequest, budget: ExtractionTransport.Budget, session: URLSession) async throws -> (Data, URLResponse) {
        let cancellation = URLSessionTaskCancellationBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let deadline = DispatchWorkItem { [weak self, weak task] in
                    guard let task else { return }
                    self?.fail(task, error: URLError(.timedOut))
                }
                let entry = Pending(task: task, maximumBytes: budget.maximumBytes, continuation: continuation, deadline: deadline)
                lock.withLock { pending[task.taskIdentifier] = entry }
                // This deadline includes headers, redirects, and slow-drip bodies; receiving data never resets it.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget.timeout, execute: deadline)
                cancellation.register(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allowed = lock.withLock {
            guard let entry = pending[dataTask.taskIdentifier], response.expectedContentLength <= Int64(entry.maximumBytes) else { return false }
            entry.response = response
            entry.data.reserveCapacity(Int(max(0, response.expectedContentLength)))
            return true
        }
        if allowed {
            completionHandler(.allow)
        } else {
            fail(dataTask, error: ExtractionTransportError.responseTooLarge)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard let entry = pending[dataTask.taskIdentifier] else { return false }
            guard data.count <= entry.maximumBytes - entry.data.count else { return true }
            entry.data.append(data)
            return false
        }
        if oversized { fail(dataTask, error: ExtractionTransportError.responseTooLarge) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = take(task) else { return }
        if let error {
            entry.continuation.resume(throwing: error)
        } else if let response = entry.response {
            entry.continuation.resume(returning: (entry.data, response))
        } else {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let complete: @Sendable (URLRequest?) -> Void = { request in
            var request = request
            request?.httpShouldHandleCookies = false
            completionHandler(request)
        }
        if redirectDelegate?.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                                        newRequest: request, completionHandler: complete) == nil {
            complete(request)
        }
    }

    private func take(_ task: URLSessionTask) -> Pending? {
        let entry = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        entry?.deadline.cancel()
        return entry
    }

    private func fail(_ task: URLSessionTask, error: Error) {
        guard let entry = take(task) else { return }
        task.cancel()
        entry.continuation.resume(throwing: error)
    }
}
