import Foundation
import UIKit

/// Optional artist pictures share the catalog's lifetime; decoded images stay in the existing artwork cache.
actor ArtistArtworkResolver {
    private enum Key: Hashable, Sendable {
        case id(String), name(String)

        init?(_ credit: ArtistCredit) {
            if let id = CatalogText.clean(credit.id) {
                self = .id(id)
            } else {
                let name = SearchRelevance.normalize(credit.name)
                guard !name.isEmpty else { return nil }
                self = .name(name)
            }
        }
    }

    private struct CachedArtwork: Sendable {
        let url: URL?
        let expiresAt: Date
    }

    private struct Resolution: Sendable {
        let image: UIImage?
        let artwork: CachedArtwork
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let catalog: any MusicCatalogProviding
    private let artworkLoader: ArtworkLoader
    private let lookupTimeout: TimeInterval
    private let maximumCacheEntries: Int
    private let now: @Sendable () -> Date
    private var cache: [Key: CachedArtwork] = [:]
    private var cacheOrder: [Key] = []
    private var activeLookups = 0
    private var waiters: [Waiter] = []

    init(catalog: any MusicCatalogProviding, artworkLoader: ArtworkLoader = .shared,
         lookupTimeout: TimeInterval = 5, maximumCacheEntries: Int = 128,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.catalog = catalog
        self.artworkLoader = artworkLoader
        self.lookupTimeout = lookupTimeout.isFinite ? min(5, max(0.01, lookupTimeout)) : 5
        self.maximumCacheEntries = min(128, max(1, maximumCacheEntries))
        self.now = now
    }

    func image(for credit: ArtistCredit, maxPixels: Int) async -> UIImage? {
        guard !Task.isCancelled, let key = Key(credit) else { return nil }
        if let cached = cachedArtwork(for: key), cached.url == nil { return nil }
        do {
            // The same budget covers waiting for a slot, catalog metadata, and the small image transfer.
            let result = try await PlaybackDeadline.run(seconds: lookupTimeout) {
                try await self.load(credit, key: key, maxPixels: maxPixels)
            }
            try Task.checkCancellation()
            store(result.artwork, for: key)
            return result.image
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return nil }
            store(missingArtwork(), for: key)
            return nil
        }
    }

    private func load(_ credit: ArtistCredit, key: Key, maxPixels: Int) async throws -> Resolution {
        guard await acquire() else { throw CancellationError() }
        // Keep the slot until the provider unwinds, even if the caller's deadline has already expired.
        defer { release() }
        try Task.checkCancellation()
        let cached = cachedArtwork(for: key)
        if let cached, cached.url == nil { return Resolution(image: nil, artwork: cached) }
        let url: URL?
        if let cached { url = cached.url }
        else { url = try await artworkURL(for: credit, key: key) }
        try Task.checkCancellation()
        guard let url else { return Resolution(image: nil, artwork: missingArtwork()) }
        let image = await artworkLoader.image(for: url, tier: .thumbnail, maxPixels: maxPixels)
        try Task.checkCancellation()
        return Resolution(image: image, artwork: image == nil ? missingArtwork() : CachedArtwork(url: url, expiresAt: .distantFuture))
    }

    private func artworkURL(for credit: ArtistCredit, key: Key) async throws -> URL? {
        switch key {
        case .id(let id):
            let artist = try await catalog.artist(id: id)
            guard artist.id == id else { return nil }
            return artist.artworkURL
        case .name(let name):
            let page = try await catalog.search(query: credit.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                filter: .artists, continuation: nil)
            // Credits are identities, not typed searches: fuzzy hits and spelling corrections can depict someone else.
            let exact = page.collections.filter { SearchRelevance.normalize($0.title) == name }
            return SearchRelevance.matchedArtist(in: exact, query: credit.name)?.artworkURL
        }
    }

    private func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if activeLookups < 2 {
                    activeLookups += 1
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        if waiters.isEmpty { activeLookups -= 1 }
        else { waiters.removeFirst().continuation.resume(returning: true) }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func missingArtwork() -> CachedArtwork {
        CachedArtwork(url: nil, expiresAt: now().addingTimeInterval(30))
    }

    private func cachedArtwork(for key: Key) -> CachedArtwork? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        guard entry.expiresAt > now() else {
            cache.removeValue(forKey: key)
            return nil
        }
        cacheOrder.append(key)
        return entry
    }

    private func store(_ artwork: CachedArtwork, for key: Key) {
        cache[key] = artwork
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > maximumCacheEntries { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }
}
