//
//  SignatureSolverCache.swift
//  YouTubeKit
//
//  Gana Bajana patch: reuses prepared yt-ejs contexts across player responses and songs.
//

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
import os.log

/// One JSContext with meriyah, astring and yt-ejs loaded for a single player script.
/// JSContext is not safe for interleaved use, so every JavaScript call holds `lock`.
@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
final class PreparedSignaturePlayer: @unchecked Sendable {
    struct Solve {
        let output: String
        let usedPreprocessed: Bool
        let milliseconds: Int
    }

    let playerJS: String
    let prepareMilliseconds: Int
    private let vm: JSVirtualMachine?
    let context: JSContext
    private let lock = NSLock()
    private var preprocessed = false
    private var succeeded = false
    private let activity = NSLock()
    private var active = 0
    private var peakActive = 0

    init(js: String, context injected: JSContext? = nil) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        playerJS = js
        let vm = injected == nil ? JSVirtualMachine() : nil
        guard let ctx = injected ?? JSContext(virtualMachine: vm) else {
            throw SignatureSolverError.contextCreationFailed
        }
        self.vm = vm
        context = ctx
        let log = SignatureSolver.log
        ctx.exceptionHandler = { context, exception in
            context?.exception = exception
            os_log("event=signature_solver_failed category=javascript_exception", log: log, type: .error)
        }

        // Minimal DOM/env shims (matches `setupNodes`)
        ctx.evaluateScript(#"""
            globalThis.XMLHttpRequest = { prototype: {} };
            globalThis.URL = class URL {
                constructor(url) {
                    this.href = url;
                    const match = url.match(/^(https?:)\/\/([^/:]+)(:(\d+))?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
                    this.protocol = match ? match[1] : '';
                    this.hostname = match ? match[2] : '';
                    this.port = match && match[4] ? match[4] : '';
                    this.pathname = match && match[5] ? match[5] : '/';
                    this.search = match && match[6] ? match[6] : '';
                    this.hash = match && match[7] ? match[7] : '';
                }
            };
            globalThis.navigator = {
                userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
            };
            const window = Object.assign(Object.create(null), globalThis);
            window.location = new URL("https://www.youtube.com/watch?v=youtubekit-wins");
            const document = {};
            let self = globalThis;
        """#)

        // Load meriyah + astring UMD bundles from package resources
        func evalResource(_ name: String, _ ext: String) throws {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
                throw SignatureSolverError.resourceNotFound(name: name, extension: ext)
            }
            let src = try String(contentsOf: url, encoding: .utf8)
            ctx.evaluateScript(src)
        }
        try evalResource("meriyah", "umd.js")
        try evalResource("astring", "umd.js")

        // Load generated yt-ejs helper
        try evalResource("yt_ejs_helper", "js")

        // The raw player lives in the context once; yt-ejs's preprocessed output replaces it after the
        // first solve, so later solves skip meriyah parsing and never re-encode the script as JSON.
        ctx.setObject(js, forKeyedSubscript: "__ytkPlayer" as NSString)
        ctx.evaluateScript(#"""
            globalThis.__ytkSolve = function (requestsJSON) {
                const input = { requests: JSON.parse(requestsJSON) };
                if (typeof globalThis.__ytkPreprocessed === 'string') {
                    input.type = 'preprocessed_player';
                    input.preprocessed_player = globalThis.__ytkPreprocessed;
                } else {
                    input.type = 'player';
                    input.player = globalThis.__ytkPlayer;
                    input.output_preprocessed = true;
                }
                const output = jsc(input);
                if (output && typeof output.preprocessed_player === 'string') {
                    globalThis.__ytkPreprocessed = output.preprocessed_player;
                    globalThis.__ytkPlayer = undefined;
                    delete output.preprocessed_player;
                }
                return JSON.stringify(output);
            };
        """#)
        prepareMilliseconds = Self.milliseconds(since: start)
    }

    /// Returns the raw JSON output of `jsc`; decoding and validation stay with the caller.
    func solve(requestsJSON: String) throws -> Solve {
        lock.lock()
        defer { lock.unlock() }
        enter()
        defer { leave() }
        let start = DispatchTime.now().uptimeNanoseconds
        let usedPreprocessed = preprocessed
        context.exception = nil
        let result = context.objectForKeyedSubscript("__ytkSolve")?.call(withArguments: [requestsJSON])
        preprocessed = context.objectForKeyedSubscript("__ytkPreprocessed")?.isString ?? false
        guard let result, context.exception == nil else {
            throw SignatureSolverError.evaluationFailed
        }
        guard let out = result.toString() else {
            throw SignatureSolverError.resultConversionFailed
        }
        return Solve(output: out, usedPreprocessed: usedPreprocessed, milliseconds: Self.milliseconds(since: start))
    }

    func markSucceeded() {
        lock.lock()
        succeeded = true
        lock.unlock()
    }

    /// Only a context that has solved before can be poisoned by later state; a first-use failure is
    /// deterministic for that script and would repeat in a fresh context.
    var hasSucceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }

    var peakConcurrentSolves: Int {
        activity.lock()
        defer { activity.unlock() }
        return peakActive
    }

    private func enter() {
        activity.lock()
        active += 1
        peakActive = max(peakActive, active)
        activity.unlock()
    }

    private func leave() {
        activity.lock()
        active -= 1
        activity.unlock()
    }

    static func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }
}

/// Process-wide LRU of prepared players keyed by exact player source. Capacity 2 covers a player
/// rollover while bounding retained JavaScript heaps; memory pressure empties it.
@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
final class SignatureSolverCache: @unchecked Sendable {
    static let shared = SignatureSolverCache(capacity: 2, observesMemoryPressure: true)

    struct Lease {
        let player: PreparedSignaturePlayer
        let reused: Bool
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [PreparedSignaturePlayer] = [] // least recently used first
    private var prepared = 0
    private let memoryPressure: DispatchSourceMemoryPressure?

    init(capacity: Int, observesMemoryPressure: Bool = false) {
        self.capacity = max(1, capacity)
        guard observesMemoryPressure else {
            memoryPressure = nil
            return
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure = source
        source.setEventHandler { [weak self] in self?.removeAll(reason: "memory_pressure") }
        source.resume()
    }

    deinit {
        memoryPressure?.cancel()
    }

    func lease(js: String) throws -> Lease {
        if let hit = lookup(js) { return Lease(player: hit, reused: true) }
        // Preparation runs outside the cache lock so other players stay available meanwhile.
        let fresh = try PreparedSignaturePlayer(js: js)
        lock.lock()
        defer { lock.unlock() }
        prepared += 1
        if let index = entries.firstIndex(where: { Self.same($0.playerJS, js) }) {
            let winner = entries.remove(at: index)
            entries.append(winner)
            return Lease(player: winner, reused: true)
        }
        entries.append(fresh)
        while entries.count > capacity {
            entries.removeFirst()
            os_log("event=signature_solver_evicted reason=capacity", log: SignatureSolver.log, type: .info)
        }
        return Lease(player: fresh, reused: false)
    }

    func evict(_ player: PreparedSignaturePlayer) {
        lock.lock()
        let before = entries.count
        entries.removeAll { $0 === player }
        let removed = entries.count != before
        lock.unlock()
        if removed {
            os_log("event=signature_solver_evicted reason=failure", log: SignatureSolver.log, type: .info)
        }
    }

    func removeAll(reason: String = "released") {
        lock.lock()
        let removed = !entries.isEmpty
        entries.removeAll()
        lock.unlock()
        if removed {
            os_log("event=signature_solver_evicted reason=%{public}@", log: SignatureSolver.log, type: .info, reason)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Number of contexts this cache has built, including ones that lost a concurrent preparation race.
    var preparedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    func cachedPlayer(for js: String) -> PreparedSignaturePlayer? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { Self.same($0.playerJS, js) }
    }

    private func lookup(_ js: String) -> PreparedSignaturePlayer? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { Self.same($0.playerJS, js) }) else { return nil }
        let hit = entries.remove(at: index)
        entries.append(hit)
        return hit
    }

    /// Callers normally pass the same cached String storage, which `==` short-circuits.
    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count && lhs == rhs
    }
}
#endif
