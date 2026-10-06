//
//  YouTubeKitHooks.swift
//  YouTubeKit
//
//  Gana Bajana patch: lets the host app decorate InnerTube requests and opt into the TV client.
//

import Foundation

public enum YouTubeKitHooks {
    @available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
    public static var extractionCompatibility: ExtractionCompatibilitySnapshot {
        ExtractionCompatibilityRegistry.shared.snapshot()
    }

    /// Publish only after the host has durably accepted a validated package or an explicit rollback.
    @available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
    @discardableResult public static func installExtractionCompatibility(_ rules: ExtractionCompatibility) throws -> ExtractionCompatibilitySnapshot {
        try ExtractionCompatibilityRegistry.shared.install(rules)
    }

    /// Drops cached JavaScriptCore signature contexts, for example on a memory warning; the next extraction rebuilds one.
    @available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
    public static func releaseSignatureSolverCache() {
#if canImport(JavaScriptCore)
        SignatureSolverCache.shared.removeAll(reason: "released")
#endif
    }

    /// Decorates TVHTML5 player requests only; the host app reads its current session before adding account headers.
    nonisolated(unsafe) public static var requestDecorator: (@Sendable (inout URLRequest, String) -> Void)?
    /// When true, player lookups also query the TVHTML5 client, which honors account cookies.
    nonisolated(unsafe) public static var includesTVClient: @Sendable () -> Bool = { false }
}
