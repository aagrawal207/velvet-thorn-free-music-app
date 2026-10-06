import CryptoKit
import Foundation
import YouTubeKit

enum ExtractorUpdateFailure: String, Error, Sendable, CaseIterable {
    case tooLarge, malformed, incompatible, incompatibleBuild, invalidRules, hashMismatch, invalidSignature
    case untrustedKey, staleRevision, cancelled, storage, storageChanged, feedNotConfigured, network

    var message: String {
        switch self {
        case .tooLarge: "This update exceeds the size limit."
        case .malformed, .invalidRules: "This file is not a supported compatibility update."
        case .incompatible, .incompatibleBuild: "This update is not compatible with this app version."
        case .hashMismatch: "The update is damaged or has been changed."
        case .invalidSignature, .untrustedKey: "The update’s publisher could not be verified."
        case .staleRevision: "This revision has already been used, or is older than an installed update."
        case .cancelled: "The update was cancelled."
        case .storage, .storageChanged: "Update storage could not be read or saved. Bundled rules remain available."
        case .feedNotConfigured: "No trusted update feed is configured. You can import a file from a source you trust."
        case .network: "The update feed could not be reached. Try again later."
        }
    }
}

struct ExtractorAppCompatibility: Sendable {
    let bundleID: String
    let build: Int
    static var current: Self {
        .init(bundleID: Bundle.main.bundleIdentifier ?? "", build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0)
    }
}

struct ExtractorUpdatePayload: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let extractorABI: Int
    let appBundleID: String
    let minimumAppBuild: Int
    let maximumAppBuild: Int
    let revision: Int64
    let rules: ExtractionCompatibility
}

struct ExtractorUpdateEnvelope: Codable, Sendable {
    let formatVersion: Int
    let payload: Data
    let sha256: String
    let keyID: String?
    let signature: Data?
}

enum ExtractorUpdateSource: String, Codable, Sendable { case manual, signedFeed }

struct ValidatedExtractorUpdate: Sendable {
    let payload: ExtractorUpdatePayload
    let envelope: Data
    let source: ExtractorUpdateSource
    let digest: String
    let publisherVerified: Bool
}

enum ExtractorUpdateValidator {
    static let maximumPackageBytes = 65_536
    static let maximumPayloadBytes = 32_768
    static let signingDomain = Data("Breezy.ExtractorUpdate.v1\n".utf8)

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ data: Data, source: ExtractorUpdateSource, app: ExtractorAppCompatibility,
                         trustedKeys: [String: Data], after highestRevision: Int64 = 0) throws -> ValidatedExtractorUpdate {
        guard data.count <= maximumPackageBytes else { throw ExtractorUpdateFailure.tooLarge }
        do {
            let object = try boundedObject(data, maximumBytes: maximumPackageBytes)
            try keys(object, required: ["formatVersion", "payload", "sha256"], optional: ["keyID", "signature"])
            let envelope = try JSONDecoder().decode(ExtractorUpdateEnvelope.self, from: data)
            guard envelope.formatVersion == 1 else { throw ExtractorUpdateFailure.incompatible }
            guard envelope.payload.count <= maximumPayloadBytes else { throw ExtractorUpdateFailure.tooLarge }
            guard ExtractionCompatibility.isSHA256(envelope.sha256), hash(envelope.payload) == envelope.sha256 else {
                throw ExtractorUpdateFailure.hashMismatch
            }
            let verified: Bool
            if let keyID = envelope.keyID, let signature = envelope.signature {
                guard keyID.utf8.count <= 64, let rawKey = trustedKeys[keyID], rawKey.count == 32,
                      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
                    throw ExtractorUpdateFailure.untrustedKey
                }
                guard signature.count == 64, key.isValidSignature(signature, for: signingDomain + envelope.payload) else {
                    throw ExtractorUpdateFailure.invalidSignature
                }
                verified = true
            } else {
                guard envelope.keyID == nil, envelope.signature == nil, source == .manual else {
                    throw ExtractorUpdateFailure.invalidSignature
                }
                verified = false
            }
            let payloadObject = try boundedObject(envelope.payload, maximumBytes: maximumPayloadBytes)
            try keys(payloadObject, required: ["schemaVersion", "extractorABI", "appBundleID", "minimumAppBuild", "maximumAppBuild", "revision", "rules"])
            guard let rulesObject = payloadObject["rules"] as? [String: Any] else { throw ExtractorUpdateFailure.malformed }
            try keys(rulesObject, required: ["timestampKeys", "visitorKeys", "players"])
            guard let players = rulesObject["players"] as? [[String: Any]], players.count <= 16 else { throw ExtractorUpdateFailure.invalidRules }
            for player in players {
                try keys(player, required: ["sha256"], optional: ["signature", "throttling"])
                for name in ["signature", "throttling"] where player[name] != nil {
                    guard let steps = player[name] as? [[String: Any]], steps.count <= 64 else { throw ExtractorUpdateFailure.invalidRules }
                    for step in steps { try keys(step, required: ["operation", "argument"]) }
                }
            }
            let payload = try JSONDecoder().decode(ExtractorUpdatePayload.self, from: envelope.payload)
            guard payload.schemaVersion == 1, payload.extractorABI == 1, app.build > 0,
                  payload.appBundleID == app.bundleID, payload.minimumAppBuild > 0,
                  payload.maximumAppBuild >= payload.minimumAppBuild else {
                throw ExtractorUpdateFailure.incompatible
            }
            guard payload.revision > 0, payload.revision <= 9_007_199_254_740_991 else { throw ExtractorUpdateFailure.malformed }
            guard payload.revision > highestRevision else { throw ExtractorUpdateFailure.staleRevision }
            do { try payload.rules.validate() } catch { throw ExtractorUpdateFailure.invalidRules }
            guard (payload.minimumAppBuild...payload.maximumAppBuild).contains(app.build) else {
                throw ExtractorUpdateFailure.incompatibleBuild
            }
            return .init(payload: payload, envelope: data, source: source, digest: envelope.sha256, publisherVerified: verified)
        } catch let failure as ExtractorUpdateFailure { throw failure }
        catch { throw ExtractorUpdateFailure.malformed }
    }

    static func keys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let actual = Set(object.keys)
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else { throw ExtractorUpdateFailure.malformed }
    }

    static func boundedObject(_ data: Data, maximumBytes: Int) throws -> [String: Any] {
        guard data.count <= maximumBytes else { throw ExtractorUpdateFailure.tooLarge }
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
            } else if byte == 34 { inString = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 16 else { throw ExtractorUpdateFailure.malformed }
            } else if byte == 125 || byte == 93 { depth -= 1 }
        }
        guard depth == 0, !inString, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractorUpdateFailure.malformed
        }
        return object
    }
}
