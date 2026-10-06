import Foundation
import Synchronization

enum YouTubeAccountWriteError: String, Error, LocalizedError, Sendable {
    case notSignedIn, notOptedIn, invalidTarget, notOwned, busy, retired, offline
    case unauthorized, rateLimited, rejected, couldNotConfirm, permissionStorage, unreadable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Reconnect YouTube in Settings before allowing changes."
        case .notOptedIn: "Turn on Allow YouTube Changes on this device first."
        case .invalidTarget: "This item does not have a supported YouTube identifier."
        case .notOwned: "Choose a playlist YouTube identifies as yours. Refresh the playlist list."
        case .busy: "Wait for the current YouTube request to finish."
        case .retired: "The account or permission changed. Open YouTube Changes again."
        case .offline: "You're offline. Nothing was sent. Try again when connected."
        case .unauthorized: "YouTube did not accept this sign-in. Reconnect in Settings."
        case .rateLimited: "YouTube asked to wait. Try again later."
        case .rejected: "YouTube refused this request. Check the account in YouTube Music."
        case .couldNotConfirm: "Could not confirm the YouTube change. Check YouTube Music before trying again."
        case .permissionStorage: "YouTube changes are off. The permission could not be saved or read on this device. Retry before closing the app."
        case .unreadable: "Your YouTube playlists could not be read. Try refreshing them."
        }
    }
}

enum YouTubeAccountWriteAction: String, CaseIterable, Sendable {
    case like, removeLike, addToPlaylist, subscribe, unsubscribe

    var title: String {
        switch self {
        case .like: "Like on YouTube"
        case .removeLike: "Remove YouTube Like"
        case .addToPlaylist: "Add to YouTube Playlist"
        case .subscribe: "Subscribe on YouTube"
        case .unsubscribe: "Unsubscribe on YouTube"
        }
    }

    var endpoint: String {
        switch self {
        case .like: "like/like"
        case .removeLike: "like/removelike"
        case .addToPlaylist: "browse/edit_playlist"
        case .subscribe: "subscription/subscribe"
        case .unsubscribe: "subscription/unsubscribe"
        }
    }
}

enum YouTubeAccountWriteTarget {
    static func videoID(_ track: Track) -> String? {
        guard track.source == .youTubeMusic else { return nil }
        return CatalogText.videoID(track.id)
    }

    static func channelID(_ artist: ArtistCredit) -> String? {
        guard let id = artist.id, CatalogText.artistID(id) == id else { return nil }
        return id
    }

    static func playlistID(_ browseID: String) -> String? {
        guard browseID.hasPrefix("VLPL"), CatalogText.identifier(browseID) == browseID,
              browseID.count > 4 else { return nil }
        return String(browseID.dropFirst(2))
    }
}

/// One operation's admission gate. Revocation and task resume share the same lock; nothing queues for a later session.
final class YouTubeAccountWriteAccess: Sendable {
    let session: YouTubeAccountSession
    let generation: UUID
    private struct State: Sendable {
        var retired = false
        var tasks: [UUID: URLSessionTask] = [:]
    }
    private let state = Mutex(State())

    init(session: YouTubeAccountSession, generation: UUID) {
        self.session = session
        self.generation = generation
    }

    func check() throws {
        try Task.checkCancellation()
        guard !state.withLock({ $0.retired }) else { throw YouTubeAccountWriteError.retired }
    }

    func admit(_ task: URLSessionTask, id: UUID) throws {
        try state.withLock { state in
            guard !state.retired, !Task.isCancelled else { throw YouTubeAccountWriteError.retired }
            state.tasks[id] = task
            task.resume()
        }
    }

    func finished(_ id: UUID) { _ = state.withLock { $0.tasks.removeValue(forKey: id) } }

    func retire() {
        let tasks = state.withLock { state in
            state.retired = true
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
    }
}

extension YouTubeAccountSession {
    /// Cookie domain/path/expiry checks are specific to this native music transport, independent of playback auth.
    func applyMusicWriteAuth(to request: inout URLRequest, now: Date) throws {
        for field in ["Cookie", "Authorization", "X-Origin", "X-Goog-AuthUser", "X-Youtube-Bootstrap-Logged-In"] {
            request.setValue(nil, forHTTPHeaderField: field)
        }
        request.httpShouldHandleCookies = false
        guard YouTubeAccountWriteClient.isAllowedURL(request.url), request.httpMethod == "POST" else {
            throw YouTubeAccountWriteError.invalidTarget
        }
        let path = request.url!.path
        let scoped = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let domainMatches = domain == "music.youtube.com" || domain == ".music.youtube.com"
                || domain == ".youtube.com"
            let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path)
                && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
            return domainMatches && cookie.path.hasPrefix("/") && pathMatches
                && (cookie.expires.map { $0 > now } ?? true)
        }
        let separators = Set("()<>@,;:\\\"/[]?={} \t".utf8)
        guard scoped.count <= 128, scoped.allSatisfy({ cookie in
            !cookie.name.isEmpty && cookie.name.utf8.allSatisfy { (33...126).contains($0) && !separators.contains($0) }
                && cookie.value.utf8.allSatisfy { (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }
        }) else { throw YouTubeAccountWriteError.unauthorized }
        // Duplicate auth-cookie names can select a different Google account than the signed hash.
        let names = scoped.map(\.name)
        guard Set(names).count == names.count else { throw YouTubeAccountWriteError.unauthorized }
        var scopedSession = YouTubeAccountSession(cookies: scoped, signedInAt: signedInAt)
        guard scopedSession.isAuthenticated,
              scoped.contains(where: { ["SAPISID", "__Secure-3PAPISID"].contains($0.name) && !$0.value.isEmpty }),
              scopedSession.cookieHeader.utf8.count <= 16_384,
              now.timeIntervalSince1970.isFinite, (0...253_402_300_799).contains(now.timeIntervalSince1970) else {
            throw YouTubeAccountWriteError.unauthorized
        }
        let origin = YouTubeAccountWriteClient.origin
        // ytmusicapi browser auth signs with 3PAPISID when supplied; keep the original scoped Cookie header intact.
        if scoped.contains(where: { $0.name == "__Secure-3PAPISID" && !$0.value.isEmpty }) {
            scopedSession.cookies.removeAll { $0.name == "SAPISID" }
        }
        scopedSession.apply(to: &request, origin: origin, now: now)
        request.setValue(scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
    }
}
