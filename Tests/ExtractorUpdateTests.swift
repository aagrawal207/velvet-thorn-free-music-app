import CryptoKit
import XCTest
import YouTubeKit
@testable import GanaBajana

enum ExtractorUpdateFixtures {
    static let app = ExtractorAppCompatibility(bundleID: "com.agraabhi.ganabajana", build: 8)

    static func payload(revision: Int64 = 1, minimum: Int = 8, maximum: Int = 8, schema: Int = 1, abi: Int = 1,
                        rules: ExtractionCompatibility = .init(timestampKeys: ["signatureEpoch"], visitorKeys: ["VISITOR_TOKEN"])) throws -> Data {
        try JSONEncoder().encode(ExtractorUpdatePayload(schemaVersion: schema, extractorABI: abi,
            appBundleID: app.bundleID, minimumAppBuild: minimum, maximumAppBuild: maximum, revision: revision, rules: rules))
    }

    static func envelope(_ payload: Data, key: Curve25519.Signing.PrivateKey? = nil, keyID: String = "test",
                         hash: String? = nil, signature: Data? = nil) throws -> Data {
        try JSONEncoder().encode(ExtractorUpdateEnvelope(formatVersion: 1, payload: payload,
            sha256: hash ?? ExtractorUpdateValidator.hash(payload), keyID: key == nil ? nil : keyID,
            signature: try signature ?? key?.signature(for: ExtractorUpdateValidator.signingDomain + payload)))
    }

    static func package(revision: Int64 = 1) throws -> Data { try envelope(payload(revision: revision)) }

    static func validate(_ data: Data, source: ExtractorUpdateSource = .manual, keys: [String: Data] = [:],
                         after: Int64 = 0) throws -> ValidatedExtractorUpdate {
        try ExtractorUpdateValidator.validate(data, source: source, app: app, trustedKeys: keys, after: after)
    }
}

final class ExtractorUpdateTests: XCTestCase {
    func testManualChecksumDoesNotClaimPublisherAuthentication() throws {
        let checked = try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.package())
        XCTAssertFalse(checked.publisherVerified)
        XCTAssertEqual(checked.payload.revision, 1)
    }

    func testSignedPackageAndSignatureTamperingAreIndependentOfHash() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try ExtractorUpdateFixtures.payload()
        let good = try ExtractorUpdateFixtures.envelope(payload, key: key)
        let keys = ["test": key.publicKey.rawRepresentation]
        XCTAssertTrue(try ExtractorUpdateFixtures.validate(good, source: .signedFeed, keys: keys).publisherVerified)
        let badSignature = try ExtractorUpdateFixtures.envelope(payload, key: key, signature: Data(repeating: 0, count: 64))
        assertFailure(.invalidSignature) { try ExtractorUpdateFixtures.validate(badSignature, source: .signedFeed, keys: keys) }
        assertFailure(.untrustedKey) { try ExtractorUpdateFixtures.validate(good, source: .signedFeed) }
        let wrongKey = Curve25519.Signing.PrivateKey()
        assertFailure(.invalidSignature) {
            try ExtractorUpdateFixtures.validate(good, source: .signedFeed, keys: ["test": wrongKey.publicKey.rawRepresentation])
        }
    }

    func testPayloadTamperingWithRecomputedHashStillFailsSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let original = try ExtractorUpdateFixtures.payload()
        let signature = try key.signature(for: ExtractorUpdateValidator.signingDomain + original)
        let changed = try ExtractorUpdateFixtures.envelope(ExtractorUpdateFixtures.payload(revision: 2), key: key, signature: signature)
        assertFailure(.invalidSignature) {
            try ExtractorUpdateFixtures.validate(changed, source: .signedFeed, keys: ["test": key.publicKey.rawRepresentation])
        }
    }

    func testHashMismatchRejectedForManualAndSignedSources() throws {
        let payload = try ExtractorUpdateFixtures.payload()
        let data = try ExtractorUpdateFixtures.envelope(payload, hash: String(repeating: "0", count: 64))
        for source in [ExtractorUpdateSource.manual, .signedFeed] {
            assertFailure(.hashMismatch) { try ExtractorUpdateFixtures.validate(data, source: source) }
        }
    }

    func testUnsignedFeedCannotInheritManualTrust() throws {
        assertFailure(.invalidSignature) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.package(), source: .signedFeed) }
    }

    func testVersionABIBuildAndRevisionGates() throws {
        for payload in [try ExtractorUpdateFixtures.payload(schema: 2), try ExtractorUpdateFixtures.payload(abi: 2),
                        try ExtractorUpdateFixtures.payload(minimum: 9, maximum: 8)] {
            assertFailure(.incompatible) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.envelope(payload)) }
        }
        for payload in [try ExtractorUpdateFixtures.payload(minimum: 9, maximum: 9), try ExtractorUpdateFixtures.payload(minimum: 7, maximum: 7)] {
            assertFailure(.incompatibleBuild) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.envelope(payload)) }
        }
        for revision in [Int64(1), 2] {
            assertFailure(.staleRevision) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.package(revision: revision), after: 2) }
        }
        for revision in [Int64(0), -1, Int64.max] {
            assertFailure(.malformed) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.package(revision: revision)) }
        }
    }

    func testUnknownConfigurationSurfaceAndExecutableContentRejected() throws {
        let raw = try ExtractorUpdateFixtures.payload()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        var rules = try XCTUnwrap(object["rules"] as? [String: Any])
        for key in ["playerJS", "regex", "requestHeaders", "cookie", "feedURL", "nativeLibrary"] {
            rules[key] = "untrusted-content"
            object["rules"] = rules
            let changed = try JSONSerialization.data(withJSONObject: object)
            assertFailure(.malformed) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.envelope(changed)) }
            rules.removeValue(forKey: key)
        }
    }

    func testInvalidAndOversizedRulesFailClosed() throws {
        for rules in [ExtractionCompatibility(timestampKeys: ["(a+)+$"]),
                      ExtractionCompatibility(visitorKeys: ["A", "A"]),
                      ExtractionCompatibility(visitorKeys: [String(repeating: "a", count: 65)]),
                      ExtractionCompatibility(players: [.init(sha256: "not-a-hash", signature: [.init(operation: .reverse, argument: 0)])]),
                      ExtractionCompatibility(players: [.init(sha256: String(repeating: "a", count: 64), signature: [.init(operation: .swapFirst, argument: -1)])])] {
            assertFailure(.invalidRules) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.envelope(ExtractorUpdateFixtures.payload(rules: rules))) }
        }
        assertFailure(.tooLarge) { try ExtractorUpdateFixtures.validate(Data(repeating: 32, count: 65_537)) }
        assertFailure(.tooLarge) { try ExtractorUpdateFixtures.validate(ExtractorUpdateFixtures.envelope(Data(repeating: 32, count: 32_769))) }
        assertFailure(.malformed) { try ExtractorUpdateFixtures.validate(Data("not json".utf8)) }
        assertFailure(.malformed) {
            try ExtractorUpdateValidator.boundedObject(Data((String(repeating: "[", count: 17) + String(repeating: "]", count: 17)).utf8), maximumBytes: 100)
        }
    }

    func testFeedConfigurationRejectsCredentialsQueryAndUnpinnedTrust() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        for text in ["http://example.invalid/update", "https://user:pass@example.invalid/update", "https://example.invalid/update?secret=x",
                     "https://example.invalid/update#fragment", "https://example.invalid:8443/update"] {
            XCTAssertThrowsError(try ExtractorUpdateFeed(url: XCTUnwrap(URL(string: text)), trustedKeys: ["test": key]))
        }
        XCTAssertThrowsError(try ExtractorUpdateFeed(url: XCTUnwrap(URL(string: "https://example.invalid/update")), trustedKeys: [:]))
    }

    private func assertFailure<T>(_ expected: ExtractorUpdateFailure, file: StaticString = #filePath, line: UInt = #line,
                                  _ action: () throws -> T) {
        XCTAssertThrowsError(try action(), file: file, line: line) {
            XCTAssertEqual($0 as? ExtractorUpdateFailure, expected, file: file, line: line)
        }
    }
}
