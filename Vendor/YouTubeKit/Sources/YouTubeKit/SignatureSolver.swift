//
//  SignatureSolver.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 04.10.2025.
//

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
import os.log

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
class SignatureSolver {

    static let log = OSLog(SignatureSolver.self)

    private let playerJS: String
    private let compatibility: ExtractionCompatibilitySnapshot
    private let compatibilityPlayer: ExtractionCompatibility.Player?
    // An injected context is test-owned and never enters the shared cache.
    private let injected: PreparedSignaturePlayer?
    private let cache: SignatureSolverCache

    init(js: String, context: JSContext? = nil, cache: SignatureSolverCache = .shared) throws {
        self.playerJS = js
        let snapshot = YouTubeKitHooks.extractionCompatibility
        compatibility = snapshot
        compatibilityPlayer = try snapshot.rules.player(for: js)
        self.cache = cache
        injected = try context.map { try PreparedSignaturePlayer(js: js, context: $0) }
    }
    
    private struct Request: Codable {
        let type: RequestType
        let challenges: [String]
        
        enum RequestType: String, Codable {
            case n, sig
        }
    }
    
    private struct Response: Codable {
        struct Item: Codable {
            let type: ItemType
            let data: [String: String]?
            
            enum ItemType: String, Codable {
                case result
                case error
            }
        }
        let type: String
        let responses: [Item]
        let preprocessed_player: String?
    }
    
    private func decode(_ out: String) throws -> Response {
        guard let data = out.data(using: .utf8) else {
            throw SignatureSolverError.encodingFailed
        }
        
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            // JavaScript output and decoder errors can contain challenges, signatures, and signed URLs.
            os_log("event=signature_solver_failed category=invalid_response", log: Self.log, type: .error)
            throw SignatureSolverError.jsonDecodingFailed
        }
    }
    
    // MARK: - Public
    
    struct SolveRequest {
        var nInputs: [String]
        var sigInputs: [String]
    }
    
    struct SolveResponse {
        let nMap: [String: String]
        let sigMap: [String: String]
    }
    
    func batchSolve(request: SolveRequest) throws -> SolveResponse {
        guard request.nInputs.count <= 256, request.sigInputs.count <= 256 else {
            throw ExtractionCompatibility.Failure.inputBounds
        }
        if compatibilityPlayer != nil {
            var totalBytes = 0
            for input in request.nInputs + request.sigInputs {
                guard input.utf8.count <= 4096 else { throw ExtractionCompatibility.Failure.inputBounds }
                totalBytes += input.utf8.count
                guard totalBytes <= 65_536 else { throw ExtractionCompatibility.Failure.inputBounds }
            }
        }
        guard compatibility.generation == YouTubeKitHooks.extractionCompatibility.generation else { throw CancellationError() }
        var updatedN: [String: String] = [:]
        var updatedSig: [String: String] = [:]
        if let plan = compatibilityPlayer?.throttling {
            for input in request.nInputs { updatedN[input] = try ExtractionCompatibility.transform(input, steps: plan) }
        }
        if let plan = compatibilityPlayer?.signature {
            for input in request.sigInputs { updatedSig[input] = try ExtractionCompatibility.transform(input, steps: plan) }
        }
        let remainingN = compatibilityPlayer?.throttling == nil ? request.nInputs : []
        let remainingSig = compatibilityPlayer?.signature == nil ? request.sigInputs : []
        let outcome = compatibilityPlayer == nil ? "bundled" : (remainingN.isEmpty && remainingSig.isEmpty ? "updated" : "partial")
        os_log("event=extraction_compatibility outcome=%{public}@", log: Self.log, type: .debug, outcome)
        if remainingN.isEmpty && remainingSig.isEmpty {
            guard compatibility.generation == YouTubeKitHooks.extractionCompatibility.generation else { throw CancellationError() }
            return SolveResponse(nMap: updatedN, sigMap: updatedSig)
        }
        let requests = [
            Request(type: .n, challenges: remainingN),
            Request(type: .sig, challenges: remainingSig)
        ]

        guard let requestsJSON = String(data: try JSONEncoder().encode(requests), encoding: .utf8) else {
            throw SignatureSolverError.encodingFailed
        }
        var nMap = updatedN
        var sigMap = updatedSig
        let solved: (nMap: [String: String], sigMap: [String: String])
        if let injected {
            solved = try attempt(injected, requests: requests, requestsJSON: requestsJSON, reused: false)
        } else {
            let lease = try cache.lease(js: playerJS)
            do {
                solved = try attempt(lease.player, requests: requests, requestsJSON: requestsJSON, reused: lease.reused)
            } catch {
                cache.evict(lease.player)
                guard lease.reused, lease.player.hasSucceeded else { throw error }
                let fresh = try cache.lease(js: playerJS)
                do {
                    solved = try attempt(fresh.player, requests: requests, requestsJSON: requestsJSON, reused: fresh.reused)
                } catch {
                    cache.evict(fresh.player)
                    throw error
                }
            }
        }
        nMap.merge(solved.nMap) { _, new in new }
        sigMap.merge(solved.sigMap) { _, new in new }

        guard compatibility.generation == YouTubeKitHooks.extractionCompatibility.generation else { throw CancellationError() }
        return SolveResponse(nMap: nMap, sigMap: sigMap)
    }

    private func attempt(_ player: PreparedSignaturePlayer, requests: [Request], requestsJSON: String, reused: Bool) throws -> (nMap: [String: String], sigMap: [String: String]) {
        let prepareMS = reused ? 0 : player.prepareMilliseconds
        var solveMS = 0
        var preprocessed = false
        var success = false
        defer {
            os_log("event=signature_solver reuse=%ld prepare_ms=%ld solve_ms=%ld preprocessed=%ld outcome=%{public}@",
                   log: Self.log, type: .info, reused ? 1 : 0, prepareMS, solveMS, preprocessed ? 1 : 0, success ? "success" : "failure")
        }
        let solve = try player.solve(requestsJSON: requestsJSON)
        solveMS = solve.milliseconds
        preprocessed = solve.usedPreprocessed
        let response = try decode(solve.output)

        var nMap: [String: String] = [:]
        var sigMap: [String: String] = [:]

        // Responses come back in same order as requests
        for (request, item) in zip(requests, response.responses) {
            switch item.type {
            case .error:
                os_log("event=signature_solver_failed category=challenge_rejected", log: Self.log, type: .error)
                throw SignatureSolverError.solverError
            case .result:
                if let data = item.data {
                    switch request.type {
                    case .n:
                        nMap.merge(data) { _, new in new }
                    case .sig:
                        sigMap.merge(data) { _, new in new }
                    }
                }
            }
        }
        player.markSucceeded()
        success = true
        return (nMap, sigMap)
    }
}
#endif
