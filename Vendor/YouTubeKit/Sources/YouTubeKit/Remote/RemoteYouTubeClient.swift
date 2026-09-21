//
//  RemoteYouTubeClient.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 29.08.23.
//

import Foundation

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
class RemoteYouTubeClient {
    
    let serverURL: URL
    private let session: URLSession
    
    init(serverURL: URL, session: URLSession = ExtractionTransport.session) {
        self.serverURL = serverURL
        self.session = session
    }
    
    func extractStreams(forVideoID videoID: String) async throws -> [RemoteStream] {

        var urlComponents = URLComponents(url: serverURL.appendingPathComponent("v1"), resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "videoID", value: videoID)
        ]

        var websocketRequest = URLRequest(url: urlComponents.url!)
        websocketRequest.httpShouldHandleCookies = false

        // Add app identity header if available
        if let appIdentity = AppIdentity.getCurrent() {
            websocketRequest.setValue(appIdentity.appID, forHTTPHeaderField: "X-AppID-v1")
        }

        let task = session.webSocketTask(with: websocketRequest)
        task.resume()
        
        defer {
            task.cancel()
        }
        
        enum ServerMessageType: String, Decodable {
            case urlRequest, result
        }
        
        struct ServerMessageBase: Decodable {
            let type: ServerMessageType
        }
        
        struct ServerMessage<Content: Decodable>: Decodable {
            let type: ServerMessageType
            let content: Content
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let encoder = Self.responseEncoder()
        
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let message = try await task.receive()
                let messageType = try decoder.decode(ServerMessageBase.self, from: message).type

                switch messageType {
                case .result:
                    let serverMessage = try decoder.decode(ServerMessage<[RemoteStream]>.self, from: message)
                    return serverMessage.content

                case .urlRequest:
                    let serverMessage = try decoder.decode(ServerMessage<RemoteURLRequest>.self, from: message)
                    let request = serverMessage.content
                    let remoteResponse = try await response(for: request)
                    try Task.checkCancellation()
                    try await task.send(remoteResponse, maxChunkSize: request.maxMessageChunkSize, encoder: encoder)
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func response(for request: RemoteURLRequest) async throws -> RemoteURLResponse {
        try Task.checkCancellation()
        try RemoteMessageChunkPlan.validate(maxChunkSize: request.maxMessageChunkSize)
        if !request.allowRedirects || request.applyCookiesOnRedirect {
            let delegate = ConfigurableURLSessionDelegate(allowsRedirect: request.allowRedirects, applyCookiesOnRedirect: request.applyCookiesOnRedirect,
                                                          saveIntermediateResponses: request.saveIntermediateResponses)
            let redirected = ExtractionTransport.makeSession(configuration: session.configuration, redirectDelegate: delegate)
            defer { redirected.finishTasksAndInvalidate() }
            let (data, response) = try await ExtractionTransport.data(for: request.urlRequest, budget: .remote, session: redirected)
            var remoteResponse = RemoteURLResponse(id: request.id, data: data, response: response)
            if request.saveIntermediateResponses {
                remoteResponse.intermediates = delegate.intermediateResponses.map { RemoteURLResponse(id: request.id, data: Data(), response: $0) }
            }
            return remoteResponse
        }
        let (data, response) = try await ExtractionTransport.data(for: request.urlRequest, budget: .remote, session: session)
        return RemoteURLResponse(id: request.id, data: data, response: response)
    }

    static func responseEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        // Base64 expands the bounded body by 4/3; escaping its slashes would double that worst case again.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    struct RemoteURLRequest: Decodable, Sendable {
        let id: String
        let url: URL
        let method: String
        let body: Data?
        let headers: [String: String]
        let allowRedirects: Bool
        let applyCookiesOnRedirect: Bool
        let saveIntermediateResponses: Bool
        let maxMessageChunkSize: Int?

        var urlRequest: URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.httpShouldHandleCookies = false
            return request
        }
    }

    struct RemoteURLResponse: Encodable, Sendable {
        let id: String
        let url: URL?
        let data: Data
        let statusCode: Int?
        let headers: [String: String]
        var intermediates: [RemoteURLResponse]?

        init(id: String, data: Data, response: URLResponse) {
            self.id = id
            self.url = response.url
            self.data = data
            let httpResponse = response as? HTTPURLResponse
            self.statusCode = httpResponse?.statusCode
            var headers = [String: String]()
            for (key, value) in httpResponse?.allHeaderFields ?? [:] {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key] = value
            }
            self.headers = headers
        }
    }
}
