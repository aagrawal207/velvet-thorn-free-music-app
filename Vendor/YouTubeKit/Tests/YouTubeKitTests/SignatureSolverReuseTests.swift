#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import XCTest
@testable import YouTubeKit

/// Uses a synthetic player that the bundled yt-ejs helper accepts: its `n` step appends "-n" and its
/// signature step reverses the challenge. Real-player parity remains covered by the live NSig/Signature suites.
@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class SignatureSolverReuseTests: XCTestCase {
    private static let player = #"(function(g){var U=function(){};U.prototype.set=function(k,v){this.p[k]=v};U.prototype.get=function(k){return this.p[k]};U.prototype.clone=function(){return this};U.prototype.mix=function(){if(this.p.s)this.p.s=this.p.s.split("").reverse().join("");if(this.p.n)this.p.n=this.p.n+"-n"};var Q={k:function(){}};var mk=function(url,key,value){Q.k("alr","yes");var u=new U();u.p={};if(value!==undefined)u.p[key]=value;return u};}).call(this);"#

    private func variant(_ tag: String) -> String { Self.player + "\n//" + tag }

    override func setUpWithError() throws {
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
    }

    override func tearDownWithError() throws {
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
    }

    private func solve(_ js: String, cache: SignatureSolverCache, n: [String] = ["xyz"], sig: [String] = ["abc"]) throws -> SignatureSolver.SolveResponse {
        try SignatureSolver(js: js, cache: cache).batchSolve(request: .init(nInputs: n, sigInputs: sig))
    }

    func testSecondSolverForSameScriptReusesPreprocessedContext() throws {
        let cache = SignatureSolverCache(capacity: 2)
        let first = try solve(Self.player, cache: cache)
        XCTAssertEqual(first.nMap, ["xyz": "xyz-n"])
        XCTAssertEqual(first.sigMap, ["abc": "cba"])
        let prepared = try XCTUnwrap(cache.cachedPlayer(for: Self.player))
        XCTAssertTrue(prepared.context.objectForKeyedSubscript("__ytkPreprocessed").isString)
        XCTAssertTrue(prepared.context.objectForKeyedSubscript("__ytkPlayer").isUndefined)

        let second = try solve(Self.player, cache: cache, n: ["qrs"], sig: ["def"])
        XCTAssertEqual(second.nMap, ["qrs": "qrs-n"])
        XCTAssertEqual(second.sigMap, ["def": "fed"])
        XCTAssertEqual(cache.preparedCount, 1)
        XCTAssertTrue(cache.cachedPlayer(for: Self.player) === prepared)
    }

    func testEqualScriptWithDistinctStorageStillReuses() throws {
        let cache = SignatureSolverCache(capacity: 2)
        _ = try solve(Self.player, cache: cache)
        let copy = String(decoding: Array(Self.player.utf8), as: UTF8.self)
        _ = try solve(copy, cache: cache)
        XCTAssertEqual(cache.preparedCount, 1)
    }

    func testCachedResultsMatchUpstreamSingleShotPath() throws {
        let n = ["xyz", "Ab12", "zz9"], sig = ["abc", "Q1w2e3"]
        let cache = SignatureSolverCache(capacity: 2)
        let cold = try solve(Self.player, cache: cache, n: n, sig: sig)
        let warm = try solve(Self.player, cache: cache, n: n, sig: sig)

        // Upstream flow: whole player JSON-encoded into a fresh context, no preprocessed output.
        let context = try XCTUnwrap(JSContext())
        _ = try SignatureSolver(js: Self.player, context: context)
        let input: [String: Any] = ["type": "player", "player": Self.player, "output_preprocessed": false,
                                    "requests": [["type": "n", "challenges": n], ["type": "sig", "challenges": sig]]]
        let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: input), encoding: .utf8))
        context.setObject(json, forKeyedSubscript: "swiftInput" as NSString)
        let out = try XCTUnwrap(context.evaluateScript("JSON.stringify(jsc(JSON.parse(swiftInput)))")?.toString())
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let responses = try XCTUnwrap(parsed["responses"] as? [[String: Any]])
        let legacyN = try XCTUnwrap(responses[0]["data"] as? [String: String])
        let legacySig = try XCTUnwrap(responses[1]["data"] as? [String: String])

        XCTAssertEqual(cold.nMap, legacyN)
        XCTAssertEqual(cold.sigMap, legacySig)
        XCTAssertEqual(warm.nMap, legacyN)
        XCTAssertEqual(warm.sigMap, legacySig)
    }

    func testConcurrentSolvesAreSerializedAndCorrect() throws {
        let cache = SignatureSolverCache(capacity: 2)
        let results = Locked<[Int: SignatureSolver.SolveResponse]>([:])
        let failures = Locked<Int>(0)
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            do {
                let response = try SignatureSolver(js: Self.player, cache: cache)
                    .batchSolve(request: .init(nInputs: ["n\(i)x"], sigInputs: ["s\(i)y"]))
                results.withLock { $0[i] = response }
            } catch {
                failures.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(failures.value, 0)
        for i in 0..<16 {
            let response = try XCTUnwrap(results.value[i])
            XCTAssertEqual(response.nMap, ["n\(i)x": "n\(i)x-n"])
            XCTAssertEqual(response.sigMap, ["s\(i)y": "y\(String(String(i).reversed()))s"])
        }
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(try XCTUnwrap(cache.cachedPlayer(for: Self.player)).peakConcurrentSolves, 1)
    }

    func testFailureOnReusedContextEvictsAndRetriesWithFreshContext() throws {
        let cache = SignatureSolverCache(capacity: 2)
        _ = try solve(Self.player, cache: cache)
        let poisoned = try XCTUnwrap(cache.cachedPlayer(for: Self.player))
        poisoned.context.evaluateScript("jsc = function() { throw new Error('poisoned'); };")

        let response = try solve(Self.player, cache: cache)
        XCTAssertEqual(response.nMap, ["xyz": "xyz-n"])
        XCTAssertEqual(response.sigMap, ["abc": "cba"])
        XCTAssertEqual(cache.preparedCount, 2)
        let replacement = try XCTUnwrap(cache.cachedPlayer(for: Self.player))
        XCTAssertFalse(replacement === poisoned)
    }

    func testFirstUseFailureEvictsWithoutAnExtraRetry() throws {
        let cache = SignatureSolverCache(capacity: 2)
        let broken = "var notAPlayer = 1;"
        XCTAssertThrowsError(try solve(broken, cache: cache)) {
            XCTAssertEqual($0 as? SignatureSolverError, .evaluationFailed)
        }
        XCTAssertEqual(cache.preparedCount, 1)
        XCTAssertEqual(cache.count, 0)
        // The caller's existing rebuild-on-failure retry gets its own fresh context.
        XCTAssertThrowsError(try solve(broken, cache: cache))
        XCTAssertEqual(cache.preparedCount, 2)
    }

    func testCapacityEvictsLeastRecentlyUsedPlayer() throws {
        let cache = SignatureSolverCache(capacity: 2)
        let a = variant("a"), b = variant("b"), c = variant("c")
        _ = try solve(a, cache: cache)
        _ = try solve(b, cache: cache)
        _ = try solve(a, cache: cache)
        _ = try solve(c, cache: cache)
        XCTAssertEqual(cache.preparedCount, 3)
        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.cachedPlayer(for: a))
        XCTAssertNil(cache.cachedPlayer(for: b))
        XCTAssertNotNil(cache.cachedPlayer(for: c))
        _ = try solve(b, cache: cache)
        XCTAssertEqual(cache.preparedCount, 4)
    }

    func testReleaseDropsCachedContexts() throws {
        let cache = SignatureSolverCache(capacity: 2)
        _ = try solve(Self.player, cache: cache)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        _ = try solve(Self.player, cache: cache)
        XCTAssertEqual(cache.preparedCount, 2)

        let unique = variant(UUID().uuidString)
        _ = try SignatureSolver(js: unique).batchSolve(request: .init(nInputs: ["xyz"], sigInputs: []))
        XCTAssertNotNil(SignatureSolverCache.shared.cachedPlayer(for: unique))
        YouTubeKitHooks.releaseSignatureSolverCache()
        XCTAssertNil(SignatureSolverCache.shared.cachedPlayer(for: unique))
    }

    func testRulePackageTransformsKeepSemanticsWithCachedContext() throws {
        let cache = SignatureSolverCache(capacity: 2)
        _ = try solve(Self.player, cache: cache)
        let stale = try SignatureSolver(js: Self.player, cache: cache)

        let partial = ExtractionCompatibility(players: [.init(sha256: try ExtractionCompatibility.playerHash(Self.player),
            signature: [.init(operation: .dropFirst, argument: 2)])])
        try YouTubeKitHooks.installExtractionCompatibility(partial)
        let mixed = try solve(Self.player, cache: cache, n: ["xyz"], sig: ["abcdef"])
        XCTAssertEqual(mixed.sigMap, ["abcdef": "cdef"])
        XCTAssertEqual(mixed.nMap, ["xyz": "xyz-n"])
        XCTAssertEqual(cache.preparedCount, 1)
        XCTAssertThrowsError(try stale.batchSolve(request: .init(nInputs: ["xyz"], sigInputs: []))) {
            XCTAssertTrue($0 is CancellationError)
        }

        let full = ExtractionCompatibility(players: [.init(sha256: try ExtractionCompatibility.playerHash(Self.player),
            signature: [.init(operation: .reverse, argument: 0)], throttling: [.init(operation: .rotateLeft, argument: 1)])])
        try YouTubeKitHooks.installExtractionCompatibility(full)
        let untouched = SignatureSolverCache(capacity: 2)
        let native = try solve(Self.player, cache: untouched, n: ["xyz"], sig: ["abcdef"])
        XCTAssertEqual(native.nMap, ["xyz": "yzx"])
        XCTAssertEqual(native.sigMap, ["abcdef": "fedcba"])
        XCTAssertEqual(untouched.preparedCount, 0)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func withLock(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
#endif
