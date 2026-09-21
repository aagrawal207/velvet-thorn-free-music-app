import ImageIO
import SwiftUI
import UIKit

enum AppTheme {
    // Pure black dark mode, white light mode, neutral greys, one vivid accent; gold and violet are language tints only.
    // RootView supplies the palette; SwiftUI resolves this color in each view's environment.
    static var accent: Color { .accentColor }
    static let gold = adaptive(light: 0xA87400, dark: 0xF7C948)
    static let violet = adaptive(light: 0x6858D6, dark: 0xA78BFA)
    static let background = adaptive(light: 0xFFFFFF, dark: 0x000000)
    // Every palette pairs its opaque fill with the page color, including the brighter dark-mode accents.
    static let onAccent = background
    static let surface = adaptive(light: 0xF4F4F7, dark: 0x121214)
    static let raised = adaptive(light: 0xE8E8EE, dark: 0x1E1E22)
    static let primaryText = adaptive(light: 0x0B0B10, dark: 0xFFFFFF)
    static let secondaryText = adaptive(light: 0x6D6D78, dark: 0x9A9AA3)

    fileprivate static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension AppAccent {
    var color: Color {
        switch self {
        case .coral: AppTheme.adaptive(light: 0xDC3159, dark: 0xFF5A7A)
        case .mint: AppTheme.adaptive(light: 0x007A59, dark: 0x4DE0B0)
        case .ocean: AppTheme.adaptive(light: 0x086BCE, dark: 0x64B5FF)
        case .violet: AppTheme.adaptive(light: 0x7446D1, dark: 0xB79AFF)
        case .amber: AppTheme.adaptive(light: 0x936000, dark: 0xFFC15A)
        case .rose: AppTheme.adaptive(light: 0xB93080, dark: 0xFF83BB)
        case .teal: AppTheme.adaptive(light: 0x007A83, dark: 0x53D7E0)
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
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
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
            image = nil
            imageTier = nil
            guard let url else { return }
            let target = ArtworkURL.tier(forDisplaySize: size)
            let pixels = Int((size * displayScale).rounded(.up))
            if target > .thumbnail, let quick = await ArtworkLoader.shared.image(for: url, tier: .thumbnail, maxPixels: pixels) {
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
    private let cache = NSCache<NSString, UIImage>()
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
        cache.totalCostLimit = 96 << 20
    }

    func storageUsage() -> Usage {
        var decodedBytes: Int64 = 0
        cacheKeys = cacheKeys.filter { key in
            guard let image = cache.object(forKey: key as NSString) else { return false }
            decodedBytes += Int64(Self.cost(of: image))
            return true
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

    func image(for url: URL, tier: ArtworkURL.Tier, maxPixels: Int) async -> UIImage? {
        guard !Task.isCancelled, clearingTask == nil else { return nil }
        let generation = self.generation
        let candidates = ArtworkURL.candidates(for: url, tier: tier)
        // Larger tiers only need more pixels when the view is actually larger; cap decode at the tier size.
        let pixels = min(max(32, maxPixels), tier.pixels * 2)
        for candidate in candidates {
            guard !Task.isCancelled, generation == self.generation, clearingTask == nil else { return nil }
            let key = "\(pixels)|\(candidate.absoluteString)"
            if let cached = cache.object(forKey: key as NSString) { return cached }
            let image = await waitForImage(candidate, key: key, maxPixels: pixels, generation: generation)
            guard !Task.isCancelled, generation == self.generation, clearingTask == nil else { return nil }
            if let image {
                cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
                cacheKeys.insert(key)
                cacheKeys = cacheKeys.filter { cache.object(forKey: $0 as NSString) != nil }
                return image
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
                    Text(subtitle).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
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
    var symbol: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(AppTheme.accent)
                .frame(width: 80, height: 80).background(AppTheme.surface, in: Circle())
            Text(title).appFont(.title3, weight: .semibold).foregroundStyle(AppTheme.primaryText)
            Text(message).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: 350)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
