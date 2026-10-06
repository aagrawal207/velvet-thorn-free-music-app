import Foundation

/// Configuration is supplied by the host, never by an update package. There is no default endpoint or trust key.
struct ExtractorUpdateFeed: Sendable {
    let url: URL
    let trustedKeys: [String: Data]

    init(url: URL, trustedKeys: [String: Data]) throws {
        guard url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil || url.port == 443,
              (1...4).contains(trustedKeys.count),
              trustedKeys.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 64 && $0.value.count == 32 }) else {
            throw ExtractorUpdateFailure.feedNotConfigured
        }
        self.url = url
        self.trustedKeys = trustedKeys
    }

    func fetch() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await fetch(using: session)
    }

    func fetch(using session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.boundedData(for: request, maximumBytes: ExtractorUpdateValidator.maximumPackageBytes,
                                                              delegate: ExtractorFeedRedirectPolicy())
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == url else {
                throw ExtractorUpdateFailure.network
            }
            return data
        } catch is CancellationError { throw ExtractorUpdateFailure.cancelled }
        catch is BoundedResponseError { throw ExtractorUpdateFailure.tooLarge }
        catch let error as ExtractorUpdateFailure { throw error }
        catch { throw ExtractorUpdateFailure.network }
    }
}

final class ExtractorFeedRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

enum ExtractorUpdateFile {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw ExtractorUpdateFailure.malformed }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ExtractorUpdateFailure.storage }
        guard let size = values.fileSize, size <= maximumBytes else { throw ExtractorUpdateFailure.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ExtractorUpdateFailure.tooLarge }
        return data
    }

    static func importFile(_ url: URL) async throws -> Data {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try read(url, maximumBytes: ExtractorUpdateValidator.maximumPackageBytes)
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
