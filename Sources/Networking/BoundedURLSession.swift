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
            let (bytes, response) = try await self.bytes(for: request, delegate: delegate)
            return try await withTaskCancellationHandler {
                var reachedEOF = false
                // Leaving AsyncBytes iteration does not stop a request whose body is still arriving or stalled.
                defer { if !reachedEOF { bytes.task.cancel() } }
                try Task.checkCancellation()
                let expectedLength = response.expectedContentLength
                guard expectedLength <= Int64(maximumBytes) else { throw BoundedResponseError.tooLarge }

                var data = Data()
                data.reserveCapacity(Int(max(0, expectedLength)))
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumBytes else { throw BoundedResponseError.tooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                reachedEOF = true
                return (data, response)
            } onCancel: {
                bytes.task.cancel()
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
