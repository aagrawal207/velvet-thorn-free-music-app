//
//  YouTubeKitHooks.swift
//  YouTubeKit
//
//  Gana Bajana patch: lets the host app decorate InnerTube requests and opt into the TV client.
//

import Foundation

public enum YouTubeKitHooks {
    /// Decorates TVHTML5 player requests only; the host app reads its current session before adding account headers.
    nonisolated(unsafe) public static var requestDecorator: (@Sendable (inout URLRequest, String) -> Void)?
    /// When true, player lookups also query the TVHTML5 client, which honors account cookies.
    nonisolated(unsafe) public static var includesTVClient: @Sendable () -> Bool = { false }
}
