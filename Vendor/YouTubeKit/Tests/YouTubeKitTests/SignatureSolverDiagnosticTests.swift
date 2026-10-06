#if canImport(JavaScriptCore)
import JavaScriptCore
import XCTest
@testable import YouTubeKit

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
final class SignatureSolverDiagnosticTests: XCTestCase {
    private let challenge = "private-challenge-sentinel"
    private let signedMaterial = "signed-media-sentinel"

    private func makeSolver(_ script: String) throws -> SignatureSolver {
        let context = try XCTUnwrap(JSContext())
        let solver = try SignatureSolver(js: "", context: context)
        context.evaluateScript(script)
        XCTAssertNil(context.exception)
        return solver
    }

    private func assertFailure(_ solver: SignatureSolver, expected: SignatureSolverError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try solver.batchSolve(request: .init(nInputs: [challenge], sigInputs: [signedMaterial])), file: file, line: line) { error in
            XCTAssertEqual(error as? SignatureSolverError, expected, file: file, line: line)
            let descriptions = error.localizedDescription + String(reflecting: error)
            XCTAssertFalse(descriptions.contains(challenge), file: file, line: line)
            XCTAssertFalse(descriptions.contains(signedMaterial), file: file, line: line)
        }
    }

    func testMalformedBatchDiscardsSignedResultsAndRawDecoderError() throws {
        let solver = try makeSolver("""
        jsc = function(input) {
            return {type: 'result', responses: [
                {type: 'result', data: {[input.requests[0].challenges[0]]: input.requests[1].challenges[0]}},
                {type: input.requests[1].challenges[0]}
            ]};
        };
        """)
        assertFailure(solver, expected: .jsonDecodingFailed)
    }

    func testJavaScriptExceptionCannotEscapeInTheThrownError() throws {
        let solver = try makeSolver("""
        jsc = function(input) { throw new Error(input.requests[0].challenges[0] + input.requests[1].challenges[0]); };
        """)
        assertFailure(solver, expected: .evaluationFailed)
    }

    func testSolverErrorDiscardsProviderControlledErrorText() throws {
        let solver = try makeSolver("""
        jsc = function(input) {
            return {type: 'result', responses: [
                {type: 'error', error: input.requests[0].challenges[0] + input.requests[1].challenges[0]},
                {type: 'result', data: {}}
            ]};
        };
        """)
        assertFailure(solver, expected: .solverError)
    }

    func testErrorWithoutAnExplanationStillFailsRecoverably() throws {
        let solver = try makeSolver("jsc = function() { return {type: 'result', responses: [{type: 'error'}, {type: 'result', data: {}}]}; };")
        assertFailure(solver, expected: .solverError)
    }

    func testValidBatchStillReturnsBothSolutionMaps() throws {
        let solver = try makeSolver("""
        jsc = function() {
            return {type: 'result', responses: [
                {type: 'result', data: {'n-fixture': 'n-solution'}},
                {type: 'result', data: {'sig-fixture': 'sig-solution'}}
            ]};
        };
        """)
        let result = try solver.batchSolve(request: .init(nInputs: ["n-fixture"], sigInputs: ["sig-fixture"]))
        XCTAssertEqual(result.nMap, ["n-fixture": "n-solution"])
        XCTAssertEqual(result.sigMap, ["sig-fixture": "sig-solution"])
    }
}
#endif
