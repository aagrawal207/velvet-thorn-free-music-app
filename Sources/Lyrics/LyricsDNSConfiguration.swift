import Foundation
import Network
import OSLog

enum LyricsDNSConfiguration {
    enum Resolver: String, CaseIterable, Sendable {
        case cloudflare
        case google

        var endpoint: URL {
            switch self {
            case .cloudflare: URL(string: "https://cloudflare-dns.com/dns-query")!
            case .google: URL(string: "https://dns.google/dns-query")!
            }
        }
    }

    /// Opts in all default-context DNS in this app process, including catalog/artwork; call before creating sessions.
    /// Existing encrypted DNS/Private Relay takes precedence. Device DNS settings and TLS validation are unchanged.
    @MainActor
    static func enableForCurrentProcess(using resolver: Resolver = .cloudflare) {
        // URLSession inherits this context; it has no public per-session DNS resolver configuration.
        // https://developer.apple.com/videos/play/wwdc2020/10047/?time=727
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            true, fallbackResolver: .https(resolver.endpoint, serverAddresses: [])
        )
        LyricsDiagnostics.logger.info("encryptedDNSConfigured=1 fallbackResolver=\(resolver.rawValue, privacy: .public)")
    }

    @MainActor
    static func configure(enabled: Bool) {
        if enabled { enableForCurrentProcess() }
        else { NWParameters.PrivacyContext.default.requireEncryptedNameResolution(false, fallbackResolver: nil) }
    }
}
