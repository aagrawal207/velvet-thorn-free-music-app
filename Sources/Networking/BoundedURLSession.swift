import Foundation

enum BoundedResponseError: Error, Equatable, Sendable {
    case tooLarge
    case invalidLimit
}

extension URLSession {
    /// The inclusive limit ranges from 1 byte through 64 MiB; HTTP status and payload validation belong to callers.
    /// Declared length is an upper-bound check, not an EOF equality check, because delivery may decode the body.
    func boundedData(for request: URLRequest, maximumBytes: Int, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard (1...(64 * 1024 * 1024)).contains(maximumBytes) else { throw BoundedResponseError.invalidLimit }

        do {
            let (body, response) = try await self.chunkedBody(for: request, delegate: delegate)
            return try await withTaskCancellationHandler {
                var reachedEOF = false
                // Leaving the chunk loop does not stop a request whose body is still arriving or stalled.
                defer { if !reachedEOF { body.cancel() } }
                try Task.checkCancellation()
                let expectedLength = response.expectedContentLength
                guard expectedLength <= Int64(maximumBytes) else { throw BoundedResponseError.tooLarge }

                var data = Data()
                data.reserveCapacity(Int(max(0, expectedLength)))
                for try await chunk in body {
                    try Task.checkCancellation()
                    guard chunk.count <= maximumBytes - data.count else { throw BoundedResponseError.tooLarge }
                    data.append(chunk)
                }
                try Task.checkCancellation()
                reachedEOF = true
                return (data, response)
            } onCancel: {
                body.cancel()
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
