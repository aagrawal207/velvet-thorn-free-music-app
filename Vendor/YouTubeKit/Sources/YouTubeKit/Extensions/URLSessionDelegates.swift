//
//  URLSessionDelegates.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 29.08.23.
//

import Foundation

final class ConfigurableURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    
    let allowsRedirects: Bool
    let applyCookiesOnRedirect: Bool
    let saveIntermediateResponses: Bool
    
    private let lock = NSLock()
    private var responses = [HTTPURLResponse]()
    var intermediateResponses: [HTTPURLResponse] { lock.withLock { responses } }
    
    init(allowsRedirect: Bool, applyCookiesOnRedirect: Bool, saveIntermediateResponses: Bool) {
        self.allowsRedirects = allowsRedirect
        self.applyCookiesOnRedirect = applyCookiesOnRedirect
        self.saveIntermediateResponses = saveIntermediateResponses
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if !allowsRedirects {
            completionHandler(nil)
            return
        }
        
        if saveIntermediateResponses {
            lock.withLock { responses.append(response) }
        }
        
        var modifiedRequest = request
        modifiedRequest.httpShouldHandleCookies = false
        
        if applyCookiesOnRedirect, let responseURL = response.url {
            var headers = [String: String]()
            for (key, value) in response.allHeaderFields {
                guard let key = key as? String, let value = value as? String else { continue }
                headers[key] = value
            }
            let oldCookies = HTTPCookie.cookies(withResponseHeaderFields: request.allHTTPHeaderFields ?? [:], for: request.url ?? responseURL)
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: responseURL)
            let combinedCookies = oldCookies + cookies
            
            for (key, value) in HTTPCookie.requestHeaderFields(with: combinedCookies) {
                modifiedRequest.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        completionHandler(modifiedRequest)
    }
    
}
