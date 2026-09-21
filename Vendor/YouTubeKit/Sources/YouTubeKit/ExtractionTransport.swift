import Foundation

enum ExtractionTransportError: Error, Equatable, LocalizedError {
    case responseTooLarge
    case invalidBudget

    var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "The extraction response exceeded its size limit."
        case .invalidBudget: return "The extraction request has an invalid resource budget."
        }
    }
}

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
enum ExtractionTransport {
    struct Budget: Sendable {
        let maximumBytes: Int
        let timeout: TimeInterval

        static let html = Budget(maximumBytes: 4_000_000, timeout: 30)
        static let player = Budget(maximumBytes: 4_000_000, timeout: 30)
        static let javaScript = Budget(maximumBytes: 12_000_000, timeout: 45)
        static let remote = Budget(maximumBytes: 8_000_000, timeout: 45)

        func validate() throws {
            guard (1...16_000_000).contains(maximumBytes), timeout.isFinite, timeout > 0, timeout <= 60 else {
                throw ExtractionTransportError.invalidBudget
            }
        }
    }

    static let session = makeSession()

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        return configuration
    }

    static func makeSession(configuration supplied: URLSessionConfiguration? = nil,
                            redirectDelegate: URLSessionTaskDelegate? = nil) -> URLSession {
        let config = supplied.map { $0.copy() as! URLSessionConfiguration } ?? configuration()
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = min(config.timeoutIntervalForResource, 45)
        let delegate = ExtractionDataDelegate(redirectDelegate: redirectDelegate)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    static func data(for request: URLRequest, budget: Budget,
                     session: URLSession = ExtractionTransport.session) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        try budget.validate()
        guard let delegate = session.delegate as? ExtractionDataDelegate else {
            // Injected sessions supply configuration and redirect policy without enabling completion-body buffering.
            let bounded = makeSession(configuration: session.configuration, redirectDelegate: session.delegate as? URLSessionTaskDelegate)
            defer { bounded.finishTasksAndInvalidate() }
            return try await data(for: request, budget: budget, session: bounded)
        }
        var request = request
        request.httpShouldHandleCookies = false
        request.timeoutInterval = min(request.timeoutInterval, min(15, budget.timeout))
        do {
            let result = try await delegate.data(for: request, budget: budget, session: session)
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
