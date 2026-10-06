import Foundation
import Synchronization

/// Per-task buffering permits an atomic admission check and rejects redirects before any credentials can follow them.
final class YouTubeAccountWriteTransfer: NSObject, URLSessionDataDelegate, Sendable {
    static let maximumBytes = 2 * 1_024 * 1_024
    private struct State {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
        var task: URLSessionDataTask?
        var response: HTTPURLResponse?
        var data = Data()
        var completed = false
        var cancelled = false
    }
    private let state = Mutex(State())
    private let expectedURL: URL

    init(expectedURL: URL) { self.expectedURL = expectedURL }

    func data(for request: URLRequest, session: URLSession, access: YouTubeAccountWriteAccess) async throws -> (Data, HTTPURLResponse) {
        let id = UUID()
        defer { access.finished(id) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let cancelled = state.withLock { state in
                    state.task = task
                    state.continuation = continuation
                    return state.cancelled
                }
                if cancelled {
                    finish(.failure(CancellationError()))
                    task.cancel()
                    return
                }
                do { try access.admit(task, id: id) }
                catch { finish(.failure(error)); task.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let task = state.withLock { state in state.cancelled = true; return state.task }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let continuation = state.withLock { state in
            guard !state.completed, let continuation = state.continuation else { return nil as CheckedContinuation<(Data, HTTPURLResponse), any Error>? }
            state.completed = true
            state.continuation = nil
            state.task = nil
            state.data.removeAll()
            return continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == expectedURL,
              YouTubeAccountWriteClient.isAllowedURL(http.url),
              http.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(YouTubeAccountWriteError.couldNotConfirm))
            return
        }
        state.withLock { $0.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = state.withLock { state in
            guard !state.completed else { return false }
            guard data.count <= Self.maximumBytes - state.data.count else { return true }
            state.data.append(data)
            return false
        }
        if tooLarge {
            dataTask.cancel()
            finish(.failure(YouTubeAccountWriteError.couldNotConfirm))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let result: Result<(Data, HTTPURLResponse), any Error> = state.withLock { state in
            guard let response = state.response else { return .failure(YouTubeAccountWriteError.couldNotConfirm) }
            return .success((state.data, response))
        }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(YouTubeAccountWriteError.couldNotConfirm))
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        completionHandler(nil)
    }
}
