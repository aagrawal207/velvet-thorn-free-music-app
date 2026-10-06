import Foundation

/// Credential-free, device-only permission. SecItemUpdate replaces this entire record atomically.
@MainActor
final class YouTubeAccountWritePermissionStore {
    struct Permission: Codable, Equatable, Sendable {
        var version = 1
        var sessionID: UUID?
        var generation: UUID
        var allow: Bool
    }

    private let secrets: any SecretStoring
    private let key = "permission"
    private var baseline: Data?
    private var loaded = false

    init(secrets: any SecretStoring = KeychainSecretStore(service: "com.agraabhi.ganabajana.youtube-write-permission")) {
        self.secrets = secrets
    }

    func read() throws -> Permission? {
        do {
            let data = try secrets.read(key)
            if loaded, data != baseline { throw YouTubeAccountWriteError.permissionStorage }
            let permission = try data.map { data in
                guard data.count <= 4_096 else { throw YouTubeAccountWriteError.permissionStorage }
                let value = try JSONDecoder().decode(Permission.self, from: data)
                guard value.version == 1, !value.allow || value.sessionID != nil else {
                    throw YouTubeAccountWriteError.permissionStorage
                }
                return value
            }
            baseline = data
            loaded = true
            return permission
        } catch { throw YouTubeAccountWriteError.permissionStorage }
    }

    func setAllowed(_ allow: Bool, sessionID: UUID?) throws -> Permission {
        _ = try read()
        guard !allow || sessionID != nil else { throw YouTubeAccountWriteError.notSignedIn }
        let value = Permission(sessionID: sessionID, generation: UUID(), allow: allow)
        do {
            let data = try JSONEncoder().encode(value)
            try secrets.write(data, key: key)
            baseline = data
            return value
        } catch { throw YouTubeAccountWriteError.permissionStorage }
    }
}
