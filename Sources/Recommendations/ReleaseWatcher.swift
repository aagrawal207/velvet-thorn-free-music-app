import Foundation
import OSLog
import UserNotifications

protocol ReleaseNotificationSubmitting: Sendable {
    func existingIdentifiers() async -> Set<String>
    /// Initiate submission synchronously; only completion may be deferred beyond the caller's eligibility check.
    /// Complete exactly once, reporting acceptance even if cancellation follows initiation.
    @MainActor
    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void)
}

protocol ReleaseNotifying: ReleaseNotificationSubmitting {
    func requestAuthorizationIfNeeded() async -> Bool
}

struct SystemReleaseNotificationSubmitter: ReleaseNotificationSubmitting {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Releases")

    func existingIdentifiers() async -> Set<String> {
        guard Bundle.main.bundleIdentifier != nil else { return [] }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return Set(pending.map(\.identifier) + delivered.map(\.request.identifier))
    }

    @MainActor
    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil, !Task.isCancelled else {
            completion(false)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "New from \(release.artistName)"
        content.body = release.subtitle.isEmpty ? release.title : "\(release.title) · \(release.subtitle)"
        content.sound = .default
        content.userInfo = ["releaseTitle": release.title, "releaseSubtitle": release.subtitle]
        let request = UNNotificationRequest(identifier: release.notificationIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: { @Sendable error in
            if let error {
                Self.log.notice("Release notification failed: \(error.localizedDescription, privacy: .public)")
                completion(false)
            } else {
                completion(true)
            }
        })
    }
}

/// Delivers release alerts through UNUserNotificationCenter immediately, without a trigger.
struct LocalReleaseNotifier: ReleaseNotifying {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Releases")
    private let submitter: any ReleaseNotificationSubmitting

    init(submitter: any ReleaseNotificationSubmitting = SystemReleaseNotificationSubmitter()) {
        self.submitter = submitter
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        // The notification center needs a bundle identity; bare test runners and previews have none.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch {
                Self.log.notice("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    func existingIdentifiers() async -> Set<String> {
        await submitter.existingIdentifiers()
    }

    @MainActor
    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void) {
        guard !Task.isCancelled else {
            completion(false)
            return
        }
        submitter.submit(release, completion: completion)
    }
}

/// Polls followed artists for releases they have not been seen with before and records them in the library.
@MainActor
final class ReleaseWatcher {
    static let checkInterval: TimeInterval = 6 * 3600
    static let artistsPerRun = 8

    private let library: LibraryStore
    private let catalog: any MusicCatalogProviding
    private let notifier: any ReleaseNotifying
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Releases")
    private var isChecking = false

    init(library: LibraryStore, catalog: any MusicCatalogProviding,
         notifier: any ReleaseNotifying = LocalReleaseNotifier(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.library = library
        self.catalog = catalog
        self.notifier = notifier
        self.now = now
    }

    /// Asks for notification permission (or reports the existing grant) for release alerts.
    func requestAlertsAuthorization() async -> Bool {
        await notifier.requestAuthorizationIfNeeded()
    }

    /// Checks the artists most overdue for a look and returns how many new releases were recorded.
    @discardableResult
    func checkNow(force: Bool = false) async -> Int {
        guard !Task.isCancelled, !isChecking else { return 0 }
        isChecking = true
        defer { isChecking = false }

        let checkedAt = now()
        let due = library.followedArtists.filter { artist in
            guard !force, let last = artist.lastCheckedAt else { return true }
            return checkedAt.timeIntervalSince(last) >= Self.checkInterval
        }.sorted { left, right in
            let leftChecked = left.lastCheckedAt ?? .distantPast
            let rightChecked = right.lastCheckedAt ?? .distantPast
            if leftChecked != rightChecked { return leftChecked < rightChecked }
            if left.followedAt != right.followedAt { return left.followedAt < right.followedAt }
            return left.id < right.id
        }.prefix(Self.artistsPerRun)
        let catalog = self.catalog
        let pages = await withTaskGroup(of: (String, Result<ArtistPage, any Error>).self) { group in
            for artist in due {
                group.addTask {
                    do { return (artist.id, .success(try await catalog.artist(id: artist.id))) }
                    catch { return (artist.id, .failure(error)) }
                }
            }
            var results: [String: Result<ArtistPage, any Error>] = [:]
            for await (id, result) in group { results[id] = result }
            return results
        }
        guard !Task.isCancelled else { return 0 }

        var announcements: [ArtistRelease] = []
        let gregorian = Calendar(identifier: .gregorian)
        let currentYear = gregorian.component(.year, from: checkedAt)
        for artist in due {
            guard !Task.isCancelled else { break }
            // Re-read the store: the listener may have unfollowed while the page was loading.
            guard let current = library.followedArtists.first(where: { $0.id == artist.id }) else { continue }
            switch pages[artist.id] {
            case .success(let page):
                let releases = page.releases.filter { $0.kind == .album && !$0.id.isEmpty }
                let ids = releases.map(\.id)
                let known = Set(current.knownReleaseIDs)
                guard current.hasEstablishedReleaseBaseline else {
                    // No baseline yet: everything visible today is old news, so nothing is announced.
                    library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: ids, newReleases: [], checkedAt: checkedAt)
                    continue
                }
                let alreadyListed = Set(library.releases.map(\.id))
                let fresh = releases.filter { release in
                    guard !known.contains(release.id), !alreadyListed.contains(release.id),
                          let year = Self.releaseYear(from: release.subtitle) else { return false }
                    return year == currentYear || year == currentYear - 1
                }.map { release in
                    ArtistRelease(id: release.id, title: release.title, subtitle: release.subtitle, artistID: artist.id,
                                  artistName: current.name, artworkURL: release.artworkURL, discoveredAt: checkedAt)
                }
                if library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: ids, newReleases: fresh, checkedAt: checkedAt) {
                    let savedIDs = Set(library.releases.map(\.id))
                    announcements += fresh.filter { savedIDs.contains($0.id) }
                }
            case .failure(let error):
                log.notice("Release check for \(artist.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                // Marking the attempt keeps a broken artist from monopolizing every run's slots.
                library.recordReleaseCheck(artistID: artist.id, knownReleaseIDs: [], newReleases: [],
                                           checkedAt: checkedAt, catalogReadSucceeded: false)
            case nil:
                continue
            }
        }

        await deliverPendingNotifications()
        return announcements.count
    }

    private func deliverPendingNotifications() async {
        let pending = library.pendingReleaseNotifications
        guard !Task.isCancelled, let first = pending.first, library.canDeliverReleaseNotification(first),
              await notifier.requestAuthorizationIfNeeded() else { return }
        for release in pending {
            guard !Task.isCancelled, library.preferences.newReleaseAlerts else { break }
            guard library.canDeliverReleaseNotification(release) else { continue }
            let existing = await notifier.existingIdentifiers()
            let accepted: Bool
            if existing.contains(release.notificationIdentifier) {
                accepted = true
            } else {
                accepted = await withCheckedContinuation { continuation in
                    // Eligibility and platform initiation share one main-actor turn after every async preflight.
                    guard !Task.isCancelled, library.canDeliverReleaseNotification(release) else {
                        continuation.resume(returning: false)
                        return
                    }
                    notifier.submit(release) { @Sendable accepted in continuation.resume(returning: accepted) }
                }
            }
            if accepted {
                // An accepted in-flight request is acknowledged even if cancellation arrived during submission.
                guard library.acknowledgeReleaseNotification(id: release.id) else { break }
            }
        }
    }

    /// The first four-digit 19xx/20xx year in a provider subtitle such as "Album • 2025".
    static func releaseYear(from subtitle: String) -> Int? {
        var digits: [Character] = []
        func candidate() -> Int? {
            guard digits.count == 4, let year = Int(String(digits)), (1900...2099).contains(year) else { return nil }
            return year
        }
        for character in subtitle {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else {
                if let year = candidate() { return year }
                digits.removeAll()
            }
        }
        return candidate()
    }
}
