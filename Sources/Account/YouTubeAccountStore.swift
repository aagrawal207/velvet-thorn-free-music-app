import Foundation
import Observation
import OSLog
import Security
import Synchronization

/// Small secret storage the account store writes its session through; tests substitute memory.
protocol SecretStoring: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func delete(_ key: String) throws
}

enum SecretStoreError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let text = SecCopyErrorMessageString(status, nil).map { String($0) } ?? "code \(status)"
            return "The device keychain refused the request (\(text))."
        }
    }
}

/// Generic-password Keychain items readable after the first unlock, so a locked phone can still load the
/// next song in the background.
final class KeychainSecretStore: SecretStoring {
    private let service: String

    init(service: String = "com.agraabhi.ganabajana.youtube-account") {
        self.service = service
    }

    func read(_ key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.status(status)
        }
    }

    func write(_ data: Data, key: String) throws {
        let query = baseQuery(key)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.status(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.status(added) }
    }

    func delete(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.status(status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}

final class MemorySecretStore: SecretStoring {
    private let values = Mutex<[String: Data]>([:])

    init(initial: [String: Data] = [:]) {
        values.withLock { $0 = initial }
    }

    func read(_ key: String) throws -> Data? { values.withLock { $0[key] } }
    func write(_ data: Data, key: String) throws { values.withLock { $0[key] = data } }
    func delete(_ key: String) throws { _ = values.withLock { $0.removeValue(forKey: key) } }
}

/// Owns the optional YouTube sign-in. The session lives only in the Keychain and the in-process registry;
/// nothing about the account is written to the library store.
@MainActor @Observable
final class YouTubeAccountStore {
    static let secretKey = "session"

    private(set) var session: YouTubeAccountSession?
    private(set) var errorMessage: String?
    private(set) var isSignOutPending = false
    /// Mirrors the registry so Settings can explain why signing in helps; refreshed on demand.
    private(set) var lastBotCheckAt: Date?

    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let registry: YouTubeSessionRegistry
    @ObservationIgnored private let signOutIntent: any YouTubeSignOutIntentStoring
    @ObservationIgnored private let cookieStorage: HTTPCookieStorage?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Account")

    convenience init() {
        self.init(secrets: KeychainSecretStore(), registry: .shared,
                  signOutIntent: FileSignOutIntentStore(), cookieStorage: .shared)
    }

    init(secrets: any SecretStoring, registry: YouTubeSessionRegistry = .shared,
         signOutIntent: any YouTubeSignOutIntentStoring = MemorySignOutIntentStore(),
         cookieStorage: HTTPCookieStorage? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.secrets = secrets
        self.registry = registry
        self.signOutIntent = signOutIntent
        self.cookieStorage = cookieStorage
        self.now = now
        load()
    }

    var isSignedIn: Bool { session != nil }

    /// True when the stored cookies have an expiry that already passed; the user has to sign in again.
    var isExpired: Bool {
        guard let expiry = session?.expiresAt else { return false }
        return expiry <= now()
    }

    /// Stores the cookies from a completed web sign-in. Returns false when they do not describe an account.
    @discardableResult
    func signIn(cookies: [HTTPCookie]) -> Bool {
        guard !isSignOutPending else {
            errorMessage = "Finish signing out before signing in again."
            return false
        }
        guard let captured = YouTubeAccountSession(capturing: cookies, signedInAt: now()) else {
            errorMessage = "That sign-in did not finish. Try again."
            return false
        }
        return save(captured)
    }

    @discardableResult
    func signOut() -> Bool {
        isSignOutPending = true
        session = nil
        registry.update(session: nil)
        purgeLegacyCookies()

        // The marker must reach disk before deletion; Keychain failures can outlive this process.
        do {
            try signOutIntent.setPending(true)
        } catch {
            errorMessage = "Sign-out couldn't be saved on this device. Retry before closing the app."
            log.error("event=account_sign_out_intent_write_failed")
            return false
        }
        do {
            try secrets.delete(Self.secretKey)
        } catch {
            errorMessage = "Your YouTube sign-in is turned off, but its saved data couldn't be removed. Retry sign-out."
            log.error("event=account_delete_failed")
            return false
        }
        do {
            try signOutIntent.setPending(false)
        } catch {
            errorMessage = "Your saved sign-in was removed. Retry to finish signing out."
            log.error("event=account_sign_out_intent_clear_failed")
            return false
        }
        isSignOutPending = false
        errorMessage = nil
        log.info("event=account_signed_out")
        return true
    }

    func refreshDiagnostics() {
        lastBotCheckAt = registry.lastBotCheckAt
    }

    /// The gate stopped mattering once a sign-in exists, so a fresh session clears the reminder.
    private func save(_ session: YouTubeAccountSession) -> Bool {
        do {
            try secrets.write(try JSONEncoder().encode(session), key: Self.secretKey)
        } catch {
            errorMessage = "Your sign-in couldn't be saved on this device. Try again."
            log.error("event=account_save_failed")
            return false
        }
        self.session = session
        errorMessage = nil
        registry.update(session: session)
        registry.clearBotCheck()
        lastBotCheckAt = nil
        log.info("event=account_signed_in cookies=\(session.cookies.count)")
        return true
    }

    private func load() {
        lastBotCheckAt = registry.lastBotCheckAt
        registry.update(session: nil)
        purgeLegacyCookies()
        do {
            if try signOutIntent.isPending() {
                isSignOutPending = true
                errorMessage = "Your YouTube sign-in is turned off. Retry sign-out to remove its saved data."
                return
            }
        } catch {
            isSignOutPending = true
            errorMessage = "Saved sign-out status couldn't be checked. Retry sign-out before signing in."
            log.error("event=account_sign_out_intent_read_failed")
            return
        }
        do {
            guard let data = try secrets.read(Self.secretKey) else { return }
            let stored = try JSONDecoder().decode(YouTubeAccountSession.self, from: data)
            guard stored.isAuthenticated else {
                try secrets.delete(Self.secretKey)
                return
            }
            session = stored
            registry.update(session: stored)
        } catch {
            errorMessage = "Your saved YouTube sign-in couldn't be loaded. Try signing in again."
            log.error("event=account_load_failed")
        }
    }

    private func purgeLegacyCookies() {
        guard let cookieStorage else { return }
        for cookie in cookieStorage.cookies ?? [] where StoredCookie(cookie).appliesToYouTube {
            cookieStorage.deleteCookie(cookie)
        }
    }
}
