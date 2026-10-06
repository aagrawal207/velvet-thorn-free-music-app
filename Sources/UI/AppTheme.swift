import ImageIO
import SwiftUI
import UIKit

/// Corner radii shared by containers; Home tiles keep their own 4/6-point corners.
enum AppCorner {
    /// Compact containers: player artwork, small cards, and pinned control capsules' inner shapes.
    static let compact: CGFloat = 10
    static let card: CGFloat = 16
    /// Grouped rows inside sheets, including the artist picker and the options pages.
    static let sheetCard: CGFloat = 20
}

extension View {
    /// Every sheet shows the grabber on the page color with the shared palette, so chrome never differs per sheet.
    func appSheetChrome() -> some View {
        presentationDragIndicator(.visible)
            .presentationBackground(AppTheme.background)
            .foregroundStyle(AppTheme.primaryText)
            .appAccentChrome()
            .modifier(MacSheetSizing())
    }

    /// Applies the saved accent. Sheets, covers and `ImageRenderer` can miss the root's accent and fall back to the coral asset.
    func appAccentChrome() -> some View {
        modifier(AppAccentChrome())
    }

    /// Standard trailing Done for a sheet's navigation bar.
    func appSheetDoneButton(id: String, action: @escaping () -> Void) -> some View {
        toolbar {
            if #available(iOS 26.0, *) {
                // The button draws its own capsule inside a 44-point target; the bar's automatic glass would hug the target.
                ToolbarItem(placement: .topBarTrailing) {
                    AppSheetDoneButton(id: id, action: action)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    AppSheetDoneButton(id: id, action: action)
                }
            }
        }
    }
}

/// The one Done style for sheets: semibold body text with a real 44-point hit region.
struct AppSheetDoneButton: View {
    let id: String
    let action: () -> Void
    /// A sheet stacked on another sheet renders at 0.96 scale on iOS 26, so 46 layout points keep 44 on screen.
    private static let targetSize: CGFloat = 46

    var body: some View {
        if #available(iOS 26.0, *) {
            // The system glass style fixes its capsule at about 36 points and ignores a taller label, so the
            // capsule is drawn here at that size and the plain button around it owns the hit shape.
            Button(action: action) {
                Text("Done")
                    .appFont(.body, weight: .semibold)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 36)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .frame(minWidth: Self.targetSize, minHeight: Self.targetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
        } else {
            Button(action: action) {
                Text("Done")
                    .appFont(.body, weight: .semibold)
                    .frame(minWidth: Self.targetSize, minHeight: Self.targetSize)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier(id)
        }
    }
}

@MainActor
enum AppAccessibilityAnnouncements {
    struct Boundary: Sendable {
        var isVoiceOverRunning: @MainActor @Sendable () -> Bool
        var schedule: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
        var send: @MainActor @Sendable (UIAccessibility.Notification, NSAttributedString) -> Void
    }

    private static let platform = Boundary(
        isVoiceOverRunning: { UIAccessibility.isVoiceOverRunning },
        schedule: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { action() }
        },
        send: { UIAccessibility.post(notification: $0, argument: $1) }
    )

    static func post(_ message: String) {
        post(message, using: platform)
    }

    static func post(_ message: String, using boundary: Boundary) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, boundary.isVoiceOverRunning() else { return }
        // Let menu and sheet dismissal finish; queued announcements leave navigation focus where it is.
        boundary.schedule(0.35) {
            guard boundary.isVoiceOverRunning() else { return }
            let announcement = NSAttributedString(string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true])
            boundary.send(.announcement, announcement)
        }
    }
}

extension View {
    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

@MainActor
struct AppGlassContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Square artwork that shows a small cached image first and sharpens to the size the surface needs.
struct ArtworkView: View {
    var url: URL?
    var title: String
    var size: CGFloat
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?
    @State private var imageTier: ArtworkURL.Tier?
    @State private var imageURL: URL?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The body stays a plain read: rows re-evaluate often, and URL candidate lookups here cost scroll frames.
        let shown = imageURL == url ? image : nil
        ZStack {
            if let visible = shown {
                Image(uiImage: visible).resizable().scaledToFill()
            } else {
                ArtworkPlaceholder(title: title)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .animation(.easeOut(duration: 0.25), value: imageTier)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                imageTier = nil
                imageURL = nil
                return
            }
            let target = targetTier
            let pixels = pixels
            // Reappearing restarts this task; the sharp image it already shows needs no reload.
            if imageURL == url, imageTier == target, image != nil { return }
            // A decoded copy in memory appears without a cross-fade, which SwiftUI rasterizes on the CPU for every
            // visible tile at once when a screen returns.
            if let cached = ArtworkLoader.shared.memoryImage(for: url, tier: target, maxPixels: pixels) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    image = cached
                    imageTier = target
                    imageURL = url
                }
                return
            }
            if imageURL != url {
                image = nil
                imageTier = nil
                imageURL = url
            }
            if target > .thumbnail, imageTier == nil,
               let quick = await ArtworkLoader.shared.image(for: url, tier: .thumbnail, maxPixels: pixels) {
                guard !Task.isCancelled, imageTier == nil else { return }
                image = quick
                imageTier = .thumbnail
            }
            if let sharp = await ArtworkLoader.shared.image(for: url, tier: target, maxPixels: pixels) {
                guard !Task.isCancelled else { return }
                image = sharp
                imageTier = target
            }
        }
    }

    private var targetTier: ArtworkURL.Tier { ArtworkURL.tier(forDisplaySize: size) }
    private var pixels: Int { Int((size * displayScale).rounded(.up)) }
}

/// Decoded bitmaps shared by the loader and synchronous first-frame reads. `NSCache` synchronizes internally.
final class ArtworkMemoryCache: @unchecked Sendable {
    let storage = NSCache<NSString, UIImage>()

    func object(forKey key: NSString) -> UIImage? { storage.object(forKey: key) }
}

/// Downloads, downsamples, and caches artwork. Decoded bitmaps are bounded by the requested pixel size
/// so a large source never costs more memory than the view that shows it.
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private static let maximumResponseBytes = 12 << 20

    struct Usage: Equatable, Sendable {
        let diskBytes: Int64
        let responseMemoryBytes: Int64
        let decodedBytes: Int64
        let decodedImages: Int
        let diskCapacity: Int64
        let responseMemoryCapacity: Int64
        let decodedCapacity: Int64
        let pendingImages: Int
    }

    private struct Flight {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }

    private let session: URLSession
    private let responseCache: URLCache?
    private let resourceTimeout: TimeInterval
    private let memory = ArtworkMemoryCache()
    private var cache: NSCache<NSString, UIImage> { memory.storage }
    private var cacheKeys: Set<String> = []
    private var inFlight: [String: Flight] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var clearingTask: Task<Void, Never>?

    var activeWaiterCount: Int { inFlight.values.reduce(0) { $0 + $1.waiters.count } }

    init(session: URLSession? = nil, resourceTimeout: TimeInterval = 30) {
        let timeout = resourceTimeout.isFinite && resourceTimeout > 0 ? min(resourceTimeout, 30) : 30
        let selectedSession: URLSession
        if let session {
            selectedSession = session
        } else {
            #if DEBUG
            let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            #else
            let testing = false
            #endif
            let configuration = testing ? URLSessionConfiguration.ephemeral : .default
            #if DEBUG
            if DebugArtworkURLProtocol.isEnabled { configuration.protocolClasses = [DebugArtworkURLProtocol.self] }
            #endif
            configuration.urlCache = URLCache(memoryCapacity: 24 << 20, diskCapacity: testing ? 0 : 256 << 20,
                                               diskPath: testing ? nil : "artwork")
            configuration.requestCachePolicy = .returnCacheDataElseLoad
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = timeout
            selectedSession = URLSession(configuration: configuration)
        }
        self.session = selectedSession
        self.resourceTimeout = timeout
        responseCache = selectedSession.configuration.urlCache
        memory.storage.totalCostLimit = 96 << 20
    }

    private static let keyPruneThreshold = 2_048

    private func pruneEvictedKeys() {
        for key in cacheKeys where cache.object(forKey: key as NSString) == nil { cacheKeys.remove(key) }
    }

    func storageUsage() -> Usage {
        var decodedBytes: Int64 = 0
        pruneEvictedKeys()
        for key in cacheKeys {
            if let image = cache.object(forKey: key as NSString) { decodedBytes += Int64(Self.cost(of: image)) }
        }
        return Usage(diskBytes: Int64(responseCache?.currentDiskUsage ?? 0),
                     responseMemoryBytes: Int64(responseCache?.currentMemoryUsage ?? 0),
                     decodedBytes: decodedBytes, decodedImages: cacheKeys.count,
                     diskCapacity: Int64(responseCache?.diskCapacity ?? 0),
                     responseMemoryCapacity: Int64(responseCache?.memoryCapacity ?? 0),
                      decodedCapacity: Int64(cache.totalCostLimit), pendingImages: inFlight.count + retiring.count)
    }

    func clearCache() async -> Usage {
        if let clearingTask {
            await clearingTask.value
            return storageUsage()
        }
        generation = UUID()
        let flights = Array(inFlight.values)
        inFlight.removeAll()
        for flight in flights {
            retiring[flight.token] = flight.task
            flight.waiters.values.forEach { $0.resume(returning: nil) }
        }
        let pending = Array(retiring.values)
        pending.forEach { $0.cancel() }
        let work = Task<Void, Never> { [self] in
            for task in pending { _ = await task.value }
            cache.removeAllObjects()
            cacheKeys.removeAll()
            responseCache?.removeAllCachedResponses()
        }
        clearingTask = work
        await work.value
        clearingTask = nil
        return storageUsage()
    }

    /// The decoded bitmap `image(for:tier:maxPixels:)` would return from memory, read synchronously so a view
    /// can draw it in its first frame. `NSCache` is thread-safe; a miss says nothing about disk or network.
    nonisolated func memoryImage(for url: URL, tier: ArtworkURL.Tier, maxPixels: Int) -> UIImage? {
        let pixels = Self.decodePixels(maxPixels, tier: tier)
        for candidate in ArtworkURL.candidates(for: url, tier: tier) {
            if let cached = memory.object(forKey: Self.key(candidate, pixels: pixels)) { return cached }
        }
        return nil
    }

    // Larger tiers only need more pixels when the view is actually larger; cap decode at the tier size.
    private nonisolated static func decodePixels(_ maxPixels: Int, tier: ArtworkURL.Tier) -> Int {
        min(max(32, maxPixels), tier.pixels * 2)
    }

    private nonisolated static func key(_ candidate: URL, pixels: Int) -> NSString {
        "\(pixels)|\(candidate.absoluteString)" as NSString
    }

    func image(for url: URL, tier: ArtworkURL.Tier, maxPixels: Int) async -> UIImage? {
        guard !Task.isCancelled, clearingTask == nil else { return nil }
        let generation = self.generation
        let candidates = ArtworkURL.candidates(for: url, tier: tier)
        let pixels = Self.decodePixels(maxPixels, tier: tier)
        for candidate in candidates {
            guard !Task.isCancelled, generation == self.generation, clearingTask == nil else { return nil }
            let key = "\(pixels)|\(candidate.absoluteString)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            // `finish` caches the image before resuming waiters, so nothing here writes state after the resume.
            let image = await waitForImage(candidate, key: key, maxPixels: pixels, generation: generation)
            guard !Task.isCancelled, generation == self.generation, clearingTask == nil else { return nil }
            if let image { return image }
        }
        return nil
    }

    func cachedThumbnail(for url: URL, maxPixels: Int = WidgetLibrarySnapshot.maximumArtworkPixels,
                         maximumBytes: Int = WidgetLibrarySnapshot.maximumArtworkBytes) -> Data? {
        guard !Task.isCancelled, clearingTask == nil, let responseCache, maxPixels > 0, maximumBytes > 0 else { return nil }
        let pixels = min(maxPixels, WidgetLibrarySnapshot.maximumArtworkPixels)
        let byteLimit = min(maximumBytes, WidgetLibrarySnapshot.maximumArtworkBytes)
        var seen = Set<URL>()
        let candidates = [ArtworkURL.Tier.thumbnail, .standard, .large].flatMap { ArtworkURL.candidates(for: url, tier: $0) } + [url]
        for candidate in candidates where seen.insert(candidate).inserted {
            guard !Task.isCancelled else { return nil }
            // Inspect cached responses directly: even returnCacheDataDontLoad would create a URLSession request.
            guard let cached = responseCache.cachedResponse(for: URLRequest(url: candidate)),
                  let response = cached.response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= Int64(Self.maximumResponseBytes),
                  !cached.data.isEmpty, cached.data.count <= Self.maximumResponseBytes,
                  let image = Self.downsample(cached.data, maxPixels: pixels) else { continue }
            for quality in [0.8, 0.6, 0.4] {
                guard !Task.isCancelled else { return nil }
                if let data = image.jpegData(compressionQuality: CGFloat(quality)), data.count <= byteLimit,
                   WidgetLibrarySnapshot.isValidArtwork(data) { return data }
            }
        }
        return nil
    }

    private func waitForImage(_ url: URL, key: String, maxPixels: Int, generation: UUID) async -> UIImage? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                guard !Task.isCancelled, generation == self.generation, clearingTask == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = cache.object(forKey: key as NSString) {
                    continuation.resume(returning: cached)
                    return
                }
                if var flight = inFlight[key] {
                    flight.waiters[waiterID] = continuation
                    inFlight[key] = flight
                    return
                }
                let token = UUID()
                let session = self.session
                let timeout = resourceTimeout
                let task = Task.detached(priority: .userInitiated) { [self] in
                    let image = await Self.fetchWithDeadline(url, session: session, maxPixels: maxPixels,
                                                            timeout: timeout)
                    await finish(image, key: key, token: token, generation: generation)
                }
                inFlight[key] = Flight(token: token, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
    }

    private func cancel(waiterID: UUID, key: String) {
        guard var flight = inFlight[key], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        if flight.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            // A later caller needs a new flight, while cache clearing must still await this cancelled reader.
            retiring[flight.token] = flight.task
            flight.task.cancel()
        } else {
            inFlight[key] = flight
        }
        waiter.resume(returning: nil)
    }

    private func finish(_ image: UIImage?, key: String, token: UUID, generation: UUID) {
        retiring.removeValue(forKey: token)
        guard let flight = inFlight[key], flight.token == token else { return }
        inFlight.removeValue(forKey: key)
        let result = generation == self.generation && clearingTask == nil && !flight.task.isCancelled ? image : nil
        if let result {
            cache.setObject(result, forKey: key as NSString, cost: Self.cost(of: result))
            cacheKeys.insert(key)
            // Evicted keys are only dropped past a cap; a prune on every insert made each load O(cached images).
            if cacheKeys.count > Self.keyPruneThreshold { pruneEvictedKeys() }
        }
        flight.waiters.values.forEach { $0.resume(returning: result) }
    }

    private nonisolated static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }

    private nonisolated static func fetchWithDeadline(_ url: URL, session: URLSession, maxPixels: Int,
                                                     timeout: TimeInterval) async -> UIImage? {
        // A steady trickle cannot renew this budget; the group drains the reader before the flight finishes.
        await withTaskGroup(of: UIImage?.self) { group in
            group.addTask { await fetch(url, session: session, maxPixels: maxPixels) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { }
                return nil
            }
            let image = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : image
        }
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession, maxPixels: Int) async -> UIImage? {
        guard !Task.isCancelled,
              let (data, response) = try? await session.boundedData(for: URLRequest(url: url), maximumBytes: maximumResponseBytes),
              !Task.isCancelled,
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        return downsample(data, maxPixels: maxPixels)
    }

    private nonisolated static func downsample(_ data: Data, maxPixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), !Task.isCancelled else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct ArtworkPlaceholder: View {
    let title: String
    private var hue: Double {
        Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }) / 65_535
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0x2A / 255, green: 0x2A / 255, blue: 0x2E / 255),
                                        Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Low-saturation title hue keeps neighbouring placeholders distinguishable without reading as colour.
                Color(hue: hue, saturation: 0.25, brightness: 0.6).opacity(0.14)
                RadialGradient(colors: [AppTheme.accent.opacity(0.22), .clear],
                               center: UnitPoint(x: 0.85, y: 0.15), startRadius: 0, endRadius: geometry.size.width * 0.75)
                Image(systemName: "waveform")
                    .font(.system(size: geometry.size.width * 0.28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

/// Section title with optional trailing actions. Subtitles belong in detail views, not on Home.
struct SectionHeader<Trailing: View>: View {
    @Environment(\.secondaryTextColor) private var secondaryTextColor
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).appFont(.title2, weight: .bold)
                    .foregroundStyle(AppTheme.primaryText).accessibilityAddTraits(.isHeader)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).appFont(.subheadline).foregroundStyle(secondaryTextColor)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EmptyStateView: View {
    @Environment(\.secondaryTextColor) private var secondaryText
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(AppTheme.accent)
                .frame(width: 80, height: 80).background(AppTheme.surface, in: Circle())
            Text(title).appFont(.title3, weight: .semibold).foregroundStyle(AppTheme.primaryText)
            Text(message).appFont(.subheadline).foregroundStyle(secondaryText)
                .frame(maxWidth: 350)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// Reads the preference itself so a hosted presentation re-renders when the accent changes.
private struct AppAccentChrome: ViewModifier {
    @Environment(MusicAppModel.self) private var model: MusicAppModel?

    func body(content: Content) -> some View {
        if let color = model?.library.preferences.accent.color {
            content.accentColor(color).tint(color)
        } else {
            content.tint(AppTheme.accent)
        }
    }
}

/// Catalyst's default form sheet is about 470 by 400 points, too small for Settings and long lists.
private struct MacSheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        if AppPlatform.isMacCatalyst {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
