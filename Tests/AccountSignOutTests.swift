import Synchronization
import XCTest
@testable import GanaBajana

private final class AccountPersistenceProbe: SecretStoring, YouTubeSignOutIntentStoring {
    enum Operation: Hashable, Sendable {
        case readSecret, writeSecret, deleteSecret, readIntent, markPending, clearPending
    }
    private enum Failure: Error { case unavailable }
    private struct State: Sendable {
        var secret: Data?
        var pending = false
        var failures: Set<Operation> = []
        var operations: [Operation] = []
    }
    private let state = Mutex(State())

    var secret: Data? { state.withLock { $0.secret } }
    var pending: Bool { state.withLock { $0.pending } }
    var operations: [Operation] { state.withLock { $0.operations } }
    func fail(_ operations: Set<Operation>) { state.withLock { $0.failures = operations } }
    func resetOperations() { state.withLock { $0.operations = [] } }

    private func access<Value: Sendable>(_ operation: Operation, _ body: (inout State) -> Value) throws -> Value {
        try state.withLock {
            $0.operations.append(operation)
            guard !$0.failures.contains(operation) else { throw Failure.unavailable }
            return body(&$0)
        }
    }

    func read(_ key: String) throws -> Data? { try access(.readSecret) { $0.secret } }
    func write(_ data: Data, key: String) throws { try access(.writeSecret) { $0.secret = data } }
    func delete(_ key: String) throws { try access(.deleteSecret) { $0.secret = nil } }
    func isPending() throws -> Bool { try access(.readIntent) { $0.pending } }
    func setPending(_ pending: Bool) throws {
        try access(pending ? .markPending : .clearPending) { $0.pending = pending }
    }
}

@MainActor
final class AccountSignOutTests: XCTestCase {
    private func store(_ persistence: AccountPersistenceProbe, registry: YouTubeSessionRegistry = YouTubeSessionRegistry()) -> YouTubeAccountStore {
        YouTubeAccountStore(secrets: persistence, registry: registry, signOutIntent: persistence)
    }

    func testSuccessfulSignOutPersistsIntentBeforeDeleteAndClearsItLast() {
        let persistence = AccountPersistenceProbe()
        let registry = YouTubeSessionRegistry()
        let account = store(persistence, registry: registry)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        persistence.resetOperations()

        XCTAssertTrue(account.signOut())
        XCTAssertEqual(persistence.operations, [.markPending, .deleteSecret, .clearPending])
        XCTAssertFalse(persistence.pending)
        XCTAssertFalse(account.isSignOutPending)
        XCTAssertNil(persistence.secret)
        XCTAssertNil(registry.session)
        XCTAssertNil(account.errorMessage)
    }

    func testDeletionFailureStaysPendingAcrossRelaunchAndExplicitRetryCompletes() {
        let persistence = AccountPersistenceProbe()
        let registry = YouTubeSessionRegistry()
        let account = store(persistence, registry: registry)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        persistence.fail([.deleteSecret])
        persistence.resetOperations()

        XCTAssertFalse(account.signOut(), "A failed deletion cannot authorize a success toast")
        XCTAssertEqual(persistence.operations, [.markPending, .deleteSecret])
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(registry.session)
        XCTAssertTrue(persistence.pending)
        XCTAssertNotNil(persistence.secret)
        XCTAssertNotNil(account.errorMessage)

        persistence.resetOperations()
        let restored = store(persistence)
        XCTAssertTrue(restored.isSignOutPending)
        XCTAssertFalse(restored.isSignedIn)
        XCTAssertEqual(persistence.operations, [.readIntent], "Pending sign-out must not even read the credential")
        XCTAssertFalse(restored.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertEqual(persistence.operations, [.readIntent])

        persistence.fail([])
        XCTAssertTrue(restored.signOut())
        XCTAssertFalse(restored.isSignOutPending)
        XCTAssertNil(restored.errorMessage)
        XCTAssertNil(persistence.secret)
        XCTAssertFalse(store(persistence).isSignedIn)
    }

    func testIntentWriteFailureStopsCredentialUseButDoesNotDeleteOrReportSuccess() {
        let persistence = AccountPersistenceProbe()
        let registry = YouTubeSessionRegistry()
        let account = store(persistence, registry: registry)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        persistence.fail([.markPending])
        persistence.resetOperations()

        XCTAssertFalse(account.signOut())
        XCTAssertEqual(persistence.operations, [.markPending])
        XCTAssertNotNil(persistence.secret)
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(registry.session)
        XCTAssertTrue(account.errorMessage?.contains("before closing the app") == true)

        persistence.fail([])
        XCTAssertTrue(account.signOut())
        XCTAssertNil(persistence.secret)
        XCTAssertFalse(account.isSignOutPending)
    }

    func testIntentClearFailureRetainsRetryAfterCredentialDeletion() {
        let persistence = AccountPersistenceProbe()
        let account = store(persistence)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        persistence.fail([.clearPending])

        XCTAssertFalse(account.signOut())
        XCTAssertNil(persistence.secret)
        XCTAssertTrue(persistence.pending)
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertNotNil(account.errorMessage)

        let restored = store(persistence)
        XCTAssertTrue(restored.isSignOutPending)
        XCTAssertFalse(restored.isSignedIn)
        persistence.fail([])
        XCTAssertTrue(restored.signOut())
        XCTAssertFalse(persistence.pending)
    }

    func testSignInWriteFailureDoesNotPublishCredentialsOrReportSuccess() {
        let persistence = AccountPersistenceProbe()
        let registry = YouTubeSessionRegistry()
        let account = store(persistence, registry: registry)
        persistence.fail([.writeSecret])
        XCTAssertFalse(account.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(registry.session)
        XCTAssertNil(persistence.secret)
        XCTAssertNotNil(account.errorMessage)
    }

    func testUnreadableIntentFailsClosedAndClearsAnAlreadyPopulatedRegistry() throws {
        let persistence = AccountPersistenceProbe()
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: AccountFixtures.signedIn))
        try persistence.write(JSONEncoder().encode(session), key: YouTubeAccountStore.secretKey)
        persistence.fail([.readIntent])
        persistence.resetOperations()
        let registry = YouTubeSessionRegistry()
        registry.update(session: session)

        let account = store(persistence, registry: registry)
        XCTAssertFalse(account.isSignedIn)
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertNil(registry.session)
        XCTAssertEqual(persistence.operations, [.readIntent])
        XCTAssertNotNil(persistence.secret)
        XCTAssertFalse(account.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertTrue(account.signOut(), "Retry can replace an unreadable marker before deleting the credential")
    }

    func testFileMarkerSurvivesFreshStoreInstancesWithoutContainingCredentials() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountIntent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent("pending")
        let persistence = AccountPersistenceProbe()
        let account = YouTubeAccountStore(secrets: persistence, registry: YouTubeSessionRegistry(),
                                         signOutIntent: FileSignOutIntentStore(fileURL: markerURL))
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        persistence.fail([.deleteSecret])
        XCTAssertFalse(account.signOut())
        XCTAssertEqual(try Data(contentsOf: markerURL), Data([1]))

        let restored = YouTubeAccountStore(secrets: persistence, registry: YouTubeSessionRegistry(),
                                          signOutIntent: FileSignOutIntentStore(fileURL: markerURL))
        XCTAssertTrue(restored.isSignOutPending)
        XCTAssertFalse(restored.isSignedIn)
        persistence.fail([])
        XCTAssertTrue(restored.signOut())
        XCTAssertFalse(try FileSignOutIntentStore(fileURL: markerURL).isPending())
        XCTAssertNil(persistence.secret)
    }

    func testActualFileWriteFailureLeavesCredentialIntactAndRetryAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountIntent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedParent = directory.appendingPathComponent("blocked")
        let persistence = AccountPersistenceProbe()
        let account = YouTubeAccountStore(secrets: persistence, registry: YouTubeSessionRegistry(),
                                         signOutIntent: FileSignOutIntentStore(fileURL: blockedParent.appendingPathComponent("pending")))
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        try Data([0]).write(to: blockedParent)
        persistence.resetOperations()

        XCTAssertFalse(account.signOut())
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertNotNil(account.errorMessage)
        XCTAssertNotNil(persistence.secret)
        XCTAssertTrue(persistence.operations.isEmpty)
        try FileManager.default.removeItem(at: blockedParent)
        XCTAssertTrue(account.signOut())
    }

    func testCorruptFileMarkerCannotRestoreCredentialOrEchoItsContents() throws {
        let markerURL = FileManager.default.temporaryDirectory.appendingPathComponent("AccountIntent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }
        let sentinel = "untrusted-marker-content"
        try Data(sentinel.utf8).write(to: markerURL)
        let session = try XCTUnwrap(YouTubeAccountSession(capturing: AccountFixtures.signedIn))
        let secrets = MemorySecretStore(initial: [YouTubeAccountStore.secretKey: try JSONEncoder().encode(session)])

        let account = YouTubeAccountStore(secrets: secrets, registry: YouTubeSessionRegistry(),
                                         signOutIntent: FileSignOutIntentStore(fileURL: markerURL))
        XCTAssertFalse(account.isSignedIn)
        XCTAssertTrue(account.isSignOutPending)
        XCTAssertFalse(account.errorMessage?.contains(sentinel) ?? true)
        XCTAssertTrue(account.signOut())
        XCTAssertNil(try secrets.read(YouTubeAccountStore.secretKey))
    }

    func testInjectedConstructorsHaveIndependentMemoryIntents() {
        let failingSecrets = AccountPersistenceProbe()
        let first = YouTubeAccountStore(secrets: failingSecrets, registry: YouTubeSessionRegistry())
        XCTAssertTrue(first.signIn(cookies: AccountFixtures.signedIn))
        failingSecrets.fail([.deleteSecret])
        XCTAssertFalse(first.signOut())

        let otherFixture = YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry())
        XCTAssertFalse(otherFixture.isSignOutPending)
        XCTAssertTrue(otherFixture.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertTrue(first.isSignOutPending)
    }

    func testLegacyCleanupTouchesOnlyYouTubeCookiesInTheSuppliedAppJar() throws {
        let appJar = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let otherJar = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let youtube = AccountFixtures.cookie("SID", "legacy-app-session")
        let youtubeSubdomain = AccountFixtures.cookie("SAPISID", "legacy-subdomain", domain: "music.youtube.com")
        let google = AccountFixtures.cookie("SID", "other-domain-session", domain: ".google.com")
        let unrelated = AccountFixtures.cookie("SID", "unrelated-session", domain: "notyoutube.com")
        [youtube, youtubeSubdomain, google, unrelated].forEach(appJar.setCookie)
        otherJar.setCookie(youtube)
        let persistence = AccountPersistenceProbe()
        let account = YouTubeAccountStore(secrets: persistence, registry: YouTubeSessionRegistry(), cookieStorage: appJar)

        XCTAssertEqual(Set((appJar.cookies ?? []).map(\.domain)), [".google.com", "notyoutube.com"])
        XCTAssertEqual(otherJar.cookies?.count, 1)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        appJar.setCookie(youtube)
        persistence.fail([.deleteSecret])
        XCTAssertFalse(account.signOut())
        XCTAssertFalse((appJar.cookies ?? []).contains { StoredCookie($0).appliesToYouTube })
        XCTAssertEqual(otherJar.cookies?.count, 1)
    }
}
