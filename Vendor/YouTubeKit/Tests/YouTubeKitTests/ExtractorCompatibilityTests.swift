import Foundation
import XCTest
@testable import YouTubeKit
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class ExtractorCompatibilityTests: XCTestCase {
    func testExistingTimestampFixtureRenamedFieldRequiresActivatedRule() throws {
        let original = "signatureTimestamp:20515"
        let changed = original.replacingOccurrences(of: "signatureTimestamp", with: "signatureEpoch")
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        XCTAssertEqual(Extraction.extractSignatureTimestamp(fromJS: original), 20515)
        XCTAssertNil(Extraction.extractSignatureTimestamp(fromJS: changed))
        try YouTubeKitHooks.installExtractionCompatibility(.init(timestampKeys: ["signatureEpoch"]))
        XCTAssertEqual(Extraction.extractSignatureTimestamp(fromJS: changed), 20515)
        XCTAssertEqual(Extraction.extractSignatureTimestamp(fromJS: original), 20515)
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
        XCTAssertNil(Extraction.extractSignatureTimestamp(fromJS: changed))
    }

    func testIdentifierMatchingAndInputBounds() throws {
        let rules = ExtractionCompatibility(timestampKeys: ["signatureEpoch"], visitorKeys: ["VISITOR_TOKEN"])
        try rules.validate()
        XCTAssertNil(rules.signatureTimestamp(in: "not_signatureEpoch:20515"))
        XCTAssertNil(rules.signatureTimestamp(in: "signatureEpoch:2051512"))
        XCTAssertEqual(rules.signatureTimestamp(in: #"{"signatureEpoch": 205151}"#), 205151)
        XCTAssertEqual(rules.visitorData(in: #"{"VISITOR_TOKEN": "test%3D_-"}"#), "test%3D_-")
        XCTAssertNil(rules.visitorData(in: #"{"VISITOR_TOKEN": "invalid\"value"}"#))
        XCTAssertNil(rules.visitorData(in: String(repeating: "x", count: 4_000_001)))
        XCTAssertNil(rules.signatureTimestamp(in: String(repeating: "x", count: 12_000_001)))
        XCTAssertThrowsError(try ExtractionCompatibility(timestampKeys: ["(a+)+$"]).validate())
        XCTAssertThrowsError(try ExtractionCompatibility(visitorKeys: Array(repeating: "a", count: 9)).validate())
    }

    func testBoundedNativeOperationsHaveIndependentExpectedResults() throws {
        typealias Step = ExtractionCompatibility.Step
        XCTAssertEqual(try ExtractionCompatibility.transform("abcdef", steps: [Step(operation: .reverse, argument: 0)]), "fedcba")
        XCTAssertEqual(try ExtractionCompatibility.transform("abcdef", steps: [Step(operation: .dropFirst, argument: 2)]), "cdef")
        XCTAssertEqual(try ExtractionCompatibility.transform("abcdef", steps: [Step(operation: .swapFirst, argument: 8)]), "cbadef")
        XCTAssertEqual(try ExtractionCompatibility.transform("abcdef", steps: [Step(operation: .rotateLeft, argument: 8)]), "cdefab")
        XCTAssertThrowsError(try ExtractionCompatibility.transform("", steps: [Step(operation: .swapFirst, argument: 1)]))
        XCTAssertThrowsError(try ExtractionCompatibility.transform("abc", steps: [Step(operation: .dropFirst, argument: 3), Step(operation: .swapFirst, argument: 1)]))
        XCTAssertThrowsError(try ExtractionCompatibility.transform("abc", steps: [Step(operation: .swapFirst, argument: -1)]))
        XCTAssertThrowsError(try ExtractionCompatibility.transform(String(repeating: "a", count: 4097), steps: [Step(operation: .reverse, argument: 0)]))
        XCTAssertThrowsError(try ExtractionCompatibility.transform("🙂", steps: [Step(operation: .reverse, argument: 0)]))
    }

#if canImport(JavaScriptCore)
    func testActualManifestSignaturePathWorksAfterInstallingExactPlayerPlan() throws {
        // This renames the timestamp fixture from ExtractionBudgetIntegrationTests and uses synthetic challenges.
        let js = "var signatureTimestamp = {signatureEpoch:20000};"
        let info = try JSONDecoder().decode(InnerTube.VideoInfo.self, from: Data("{}".utf8))
        let format = try JSONDecoder().decode(InnerTube.StreamingData.Format.self, from: Data(#"{"itag":140,"mimeType":"audio/mp4","url":"https://fixture.googlevideo.com/videoplayback?n=abcdef","s":"abcdef","sp":"sig"}"#.utf8))
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        var oldManifest = [format]
        XCTAssertThrowsError(try Extraction.applySignature(streamManifest: &oldManifest, videoInfo: info, js: js))
        let rules = ExtractionCompatibility(players: [.init(sha256: try ExtractionCompatibility.playerHash(js),
            signature: [.init(operation: .reverse, argument: 0), .init(operation: .dropFirst, argument: 2)],
            throttling: [.init(operation: .swapFirst, argument: 2), .init(operation: .rotateLeft, argument: 1)])])
        try YouTubeKitHooks.installExtractionCompatibility(rules)
        var updatedManifest = [format]
        try Extraction.applySignature(streamManifest: &updatedManifest, videoInfo: info, js: js)
        let url = try XCTUnwrap(updatedManifest.first?.url)
        let items = try XCTUnwrap(URLComponents(string: url)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "sig" }?.value, "dcba")
        XCTAssertEqual(items.first { $0.name == "n" }?.value, "badefc")
        var wrongPlayer = [format]
        XCTAssertThrowsError(try Extraction.applySignature(streamManifest: &wrongPlayer, videoInfo: info, js: js + " "))
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
        var rolledBack = [format]
        XCTAssertThrowsError(try Extraction.applySignature(streamManifest: &rolledBack, videoInfo: info, js: js))
    }

    func testSolverCreatedBeforeActivationCannotReturnOldGeneration() throws {
        try YouTubeKitHooks.installExtractionCompatibility(.bundled)
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let solver = try SignatureSolver(js: "")
        try YouTubeKitHooks.installExtractionCompatibility(.init(timestampKeys: ["signatureEpoch"]))
        XCTAssertThrowsError(try solver.batchSolve(request: .init(nInputs: [], sigInputs: []))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testPartialUpdateLeavesOtherChallengeTypeWithBundledSolver() throws {
        let js = "fixture-player"
        let rules = ExtractionCompatibility(players: [.init(sha256: try ExtractionCompatibility.playerHash(js),
            signature: [.init(operation: .reverse, argument: 0)])])
        try YouTubeKitHooks.installExtractionCompatibility(rules)
        defer { try? YouTubeKitHooks.installExtractionCompatibility(.bundled) }
        let context = try XCTUnwrap(JSContext())
        let solver = try SignatureSolver(js: js, context: context)
        context.evaluateScript(#"jsc = function(input) { if(input.requests[1].challenges.length) throw Error('unexpected signature work'); return {type:'result',responses:[{type:'result',data:{'n-fixture':'bundled-result'}},{type:'result',data:{}}]}; };"#)
        let result = try solver.batchSolve(request: .init(nInputs: ["n-fixture"], sigInputs: ["abcdef"]))
        XCTAssertEqual(result.nMap["n-fixture"], "bundled-result")
        XCTAssertEqual(result.sigMap["abcdef"], "fedcba")
    }
#endif
}
