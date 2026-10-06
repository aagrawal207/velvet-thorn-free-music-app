#if DEBUG
import Foundation
import OSLog
import UIKit

@MainActor
final class DebugScrollPerformanceFixture: NSObject {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--uitesting") && arguments.contains("--scroll-performance-fixture")
    }

    private static var installed: DebugScrollPerformanceFixture?
    private static var setupError: String?
    private static var seedMilliseconds = 0.0
    nonisolated private static let eventCount = 2_000
    /// Realistic-scale library for the responsiveness suite: hundreds of likes and playlists, a year of history.
    nonisolated private static var isLargeLibrary: Bool { ProcessInfo.processInfo.arguments.contains("--large-library-fixture") }
    nonisolated static var largeEventCount: Int { isLargeLibrary ? 12_000 : eventCount }

    private static func largeLibraryTracks(count: Int) -> [Track] {
        let artists = (0..<60).map { ArtistCredit(name: "Fixture Artist \($0)") }
        let languages: [MusicLanguage] = [.hindi, .english]
        return (0..<count).map { index in
            var artwork = DebugArtworkURLProtocol.url("album")
            if let base = artwork { artwork = URL(string: base.absoluteString + "?n=\(index)") }
            return Track(id: String(format: "fixLarge%04d", index), title: "Fixture Song \(index) (feat. Guest \(index % 7))",
                         credits: [artists[index % artists.count], artists[(index * 7 + 3) % artists.count]],
                         albumTitle: "Fixture Album \(index / 12)", duration: 180 + Double(index % 120),
                         artworkURL: artwork, language: languages[index % languages.count], isAudioRecording: true,
                         playCount: Int64(1_000 + index * 7_919))
        }
    }

    static func seed(in directory: URL) {
        guard isEnabled else { return }
        let began = ContinuousClock.now
        do {
            guard directory.isFileURL,
                  directory.deletingLastPathComponent().lastPathComponent == "GanaBajanaUITests" else {
                throw LibraryStorageError.invalidDirectory
            }
            let now = Date()
            let base = DebugMusicFixtures.tracks
            let tracks = isLargeLibrary ? base + largeLibraryTracks(count: 800) : base
            var document = LibraryDocument()
            document.preferences.hasCompletedWelcome = true
            document.preferences.autoplay = false
            document.preferences.allowRemoteFallback = false
            document.preferences.useEncryptedDNS = false
            document.favorites = tracks
            document.playlists = [UserPlaylist(name: "Late night favorites", tracks: tracks)]
            if isLargeLibrary {
                document.superLikedIDs = Array(tracks.prefix(40).map(\.id))
                document.playlists += (0..<24).map { number in
                    UserPlaylist(name: "Fixture Playlist \(number)",
                                 tracks: Array(tracks[(number * 30)..<min(tracks.count, number * 30 + 60)]))
                }
            }
            document.playback = PlaybackSnapshot(queue: Array(tracks.prefix(3)))
            // 180 seconds exceeds these recordings' 30-second qualification threshold; every session fits inside 30 days.
            // Construct once before LibraryStore exists, avoiding a growing journal/save for every seeded session.
            // The large fixture spreads a year of sessions across the whole library; the default keeps the R16 oracle.
            let spacing: TimeInterval = isLargeLibrary ? 2_600 : 1_200
            document.events = (0..<largeEventCount).map { index in
                ListeningEvent(id: UUID(), track: tracks[index % tracks.count],
                               startedAt: now.addingTimeInterval(-Double(index + 1) * spacing), listenedSeconds: 180)
            }
            document.recentlyPlayed = tracks.prefix(isLargeLibrary ? 40 : tracks.count).enumerated().map { index, track in
                RecentListen(track: track, playedAt: now.addingTimeInterval(-Double(index + 1) * 1_200), position: 0)
            }
            for kind in [GeneratedPlaylistKind.discoverWeekly, .dailyMix, .dailyMix2, .dailyMix3] {
                let period = kind == .discoverWeekly ? RecommendationEngine.weekKey(for: now, calendar: .current)
                    : RecommendationEngine.dayKey(for: now, calendar: .current)
                document.mixes.append(GeneratedPlaylist(kind: kind, tracks: Array(tracks.prefix(50)), generatedAt: now,
                                                       periodKey: period, seedArtists: []))
            }
            let data = try LibraryPersistence.encode(document)
            _ = try LibraryPersistence.decode(data, now: now)
            try LibraryPersistence.write(data, to: directory.appendingPathComponent(LibraryPersistence.fileName), replacing: nil)
        } catch { setupError = error.localizedDescription }
        seedMilliseconds = began.duration(to: .now) / .milliseconds(1)
    }

    static func install(on model: MusicAppModel) {
        guard isEnabled, installed == nil,
              let directory = model.library.syncDeviceConfigurationURL?.deletingLastPathComponent().deletingLastPathComponent(),
              directory.deletingLastPathComponent().lastPathComponent == "GanaBajanaUITests",
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let probe = DebugScrollPerformanceFixture(model: model, directory: directory)
        installed = probe
        probe.attach(to: window)
    }

    private weak var model: MusicAppModel?
    private let directory: URL
    private let button = DebugScrollPerformanceButton(type: .system)
    private var displayLink: CADisplayLink?
    private var scrollViews: [UIScrollView] = []
    private var active = false
    private var generation = 0
    private var frames = 0
    private var scrollFrames = 0
    private var asyncScrollFrames = 0
    private var maxGapMilliseconds = 0.0
    // Hitch time follows Apple's definition: time a frame arrived later than its expected display interval.
    private var hitchMilliseconds = 0.0
    private var hitches = 0
    private var probeStart: CFTimeInterval = 0
    private var probeDuration: CFTimeInterval = 0
    private var forcesScrollFlush: Bool { !ProcessInfo.processInfo.arguments.contains("--natural-checkpoints") }
    /// Touch-armed window: frames count only from the next touch for this long, so XCUITest's own element
    /// queries before the tap and after the window never land in the measurement.
    private static let touchWindowSeconds: CFTimeInterval = 1.6
    private var touchArmed = false
    private var touchWindowStart: CFTimeInterval?
    private let autoscrollButton = DebugScrollPerformanceButton(type: .system)
    private weak var autoscrollView: UIScrollView?
    private var autoscrollStart: CFTimeInterval = 0
    private var autoscrollOrigin: CGFloat = 0
    private var autoscrollDistance: CGFloat = 0
    private static let autoscrollSpeed: CGFloat = 2_400
    private var checkpointMainMilliseconds = 0.0
    private var preparationMilliseconds = 0.0
    private var previousFrame: CFTimeInterval?
    private var wasScrolling = false
    private var lastScrollFlush: CFTimeInterval = 0
    private var commits = 0
    private var scrollCommits = 0
    private var lastCheckpoint: PlaybackListeningCheckpoint?
    private var diskVerified = false
    private var verificationError: String?

    private init(model: MusicAppModel, directory: URL) {
        self.model = model
        self.directory = directory
        super.init()
        // Delegate unchanged to the installed model callback; only durable async commits count as evidence.
        if let deliver = model.player.onListeningCheckpoint {
            model.player.onListeningCheckpoint = { [weak self, weak model] checkpoint in
                let generation = self?.generation
                let duringScroll = self?.isScrolling == true
                let before = model?.library.durableCommitCount
                let acknowledged = await deliver(checkpoint)
                if let self, self.active, generation == self.generation, acknowledged,
                   model?.library.durableCommitCount != before,
                   model?.library.lastListeningCheckpointMetrics?.outcome == "committed",
                   !checkpoint.events.isEmpty {
                    self.commits += 1
                    if duringScroll || self.isScrolling { self.scrollCommits += 1 }
                    if let metrics = model?.library.lastListeningCheckpointMetrics {
                        self.checkpointMainMilliseconds = max(self.checkpointMainMilliseconds,
                                                             metrics.mainActorMilliseconds)
                        self.preparationMilliseconds = max(self.preparationMilliseconds, metrics.preparationMilliseconds)
                    }
                    self.lastCheckpoint = checkpoint
                }
                return acknowledged
            }
        } else { Self.setupError = "Async model checkpoint callback is missing" }
    }

    private func attach(to window: UIWindow) {
        button.probe = self
        button.setTitle("Scroll probe", for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 8
        button.accessibilityIdentifier = "scrollPerformance.probe"
        button.addTarget(self, action: #selector(toggleProbe), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            button.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 4),
            button.widthAnchor.constraint(equalToConstant: 120), button.heightAnchor.constraint(equalToConstant: 44),
        ])
        guard ProcessInfo.processInfo.arguments.contains("--responsiveness-probe") else { return }
        let spy = DebugTouchSpy { [weak self] in self?.touchBegan() }
        window.addGestureRecognizer(spy)
        autoscrollButton.probe = self
        autoscrollButton.setTitle("Autoscroll", for: .normal)
        autoscrollButton.backgroundColor = .secondarySystemBackground
        autoscrollButton.layer.cornerRadius = 8
        autoscrollButton.accessibilityIdentifier = "scrollPerformance.autoscroll"
        autoscrollButton.addTarget(self, action: #selector(startAutoscroll), for: .touchUpInside)
        autoscrollButton.translatesAutoresizingMaskIntoConstraints = false
        let arm = DebugScrollPerformanceButton(type: .system)
        arm.probe = self
        arm.setTitle("Arm", for: .normal)
        arm.backgroundColor = .secondarySystemBackground
        arm.layer.cornerRadius = 8
        arm.accessibilityIdentifier = "scrollPerformance.arm"
        arm.addTarget(self, action: #selector(armTouchWindow), for: .touchUpInside)
        arm.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(autoscrollButton)
        window.addSubview(arm)
        NSLayoutConstraint.activate([
            autoscrollButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 6),
            autoscrollButton.topAnchor.constraint(equalTo: button.topAnchor),
            autoscrollButton.widthAnchor.constraint(equalToConstant: 60), autoscrollButton.heightAnchor.constraint(equalToConstant: 44),
            arm.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -6),
            arm.topAnchor.constraint(equalTo: button.topAnchor),
            arm.widthAnchor.constraint(equalToConstant: 60), arm.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    /// Instruments shows Points of Interest on the timeline, which lines trace samples up with measured windows.
    private static let pointsOfInterest = Logger(subsystem: "com.agraabhi.ganabajana", category: "PointsOfInterest")

    private func resetFrameMetrics() {
        Self.pointsOfInterest.notice("probe_window_start")
        frames = 0
        scrollFrames = 0
        maxGapMilliseconds = 0
        hitchMilliseconds = 0
        hitches = 0
        previousFrame = nil
        probeStart = CACurrentMediaTime()
        probeDuration = 0
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopWindow() {
        Self.pointsOfInterest.notice("probe_window_stop")
        active = false
        probeDuration = CACurrentMediaTime() - probeStart
        displayLink?.invalidate()
        displayLink = nil
        touchArmed = false
        touchWindowStart = nil
        autoscrollView = nil
    }

    @objc private func armTouchWindow() {
        resetFrameMetrics()
        touchArmed = true
        touchWindowStart = nil
        active = true
        startDisplayLink()
    }

    private func touchBegan() {
        guard touchArmed, touchWindowStart == nil else { return }
        resetFrameMetrics()
        touchWindowStart = CACurrentMediaTime()
    }

    /// Scrolls the vertical scroll view under the window's centre down and back at a fling-like constant speed.
    @objc private func startAutoscroll() {
        guard let window = autoscrollButton.window else { return }
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var view = window.hitTest(center, with: nil)
        var target: UIScrollView?
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 1 { target = scroll; break }
            view = current.superview
        }
        guard let target else { verificationError = "No vertical scroll view under the centre"; return }
        // Let XCUITest's post-tap idle wait settle before the measured run begins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let maximum = target.contentSize.height - target.bounds.height + target.adjustedContentInset.bottom
            self.autoscrollOrigin = target.contentOffset.y
            self.autoscrollDistance = max(0, min(10_000, maximum - self.autoscrollOrigin))
            self.autoscrollView = target
            self.resetFrameMetrics()
            self.autoscrollStart = CACurrentMediaTime()
            self.active = true
            self.startDisplayLink()
        }
    }

    private func stepAutoscroll(_ now: CFTimeInterval) {
        guard let scroll = autoscrollView else { return }
        let leg = max(0.001, Double(autoscrollDistance / Self.autoscrollSpeed))
        let elapsed = now - autoscrollStart
        let travelled: CGFloat
        if elapsed < leg {
            travelled = CGFloat(elapsed / leg) * autoscrollDistance
        } else if elapsed < leg * 2 {
            travelled = CGFloat(1 - (elapsed - leg) / leg) * autoscrollDistance
        } else {
            scroll.contentOffset.y = autoscrollOrigin
            stopWindow()
            return
        }
        scroll.contentOffset.y = autoscrollOrigin + travelled
    }

    fileprivate var diagnostics: String {
        let player = model?.player
        let error = Self.setupError ?? verificationError ?? model?.library.errorMessage ?? DebugCachedAudioFixture.setupError
        return "active=\(active ? 1 : 0);ready=\(DebugCachedAudioFixture.isReady ? 1 : 0);"
            + "frames=\(frames);scrollFrames=\(scrollFrames);maxGapMS=\(maxGapMilliseconds);"
            + "hitchMS=\(hitchMilliseconds);hitches=\(hitches);durationMS=\(probeDuration * 1_000);"
            + "asyncScrollFrames=\(asyncScrollFrames);checkpointMainMS=\(checkpointMainMilliseconds);preparationMS=\(preparationMilliseconds);"
            + "commits=\(commits);scrollCommits=\(scrollCommits);diskVerified=\(diskVerified ? 1 : 0);"
            + "position=\(player?.position ?? 0);playing=\(player?.isPlaying == true ? 1 : 0);"
            + "events=\(model?.library.events.count ?? 0);seedMS=\(Self.seedMilliseconds);"
            + "network=\(DebugCachedAudioFixture.networkRequestCount);error=\(error == nil ? 0 : 1);failure=\(error ?? "none")"
    }

    private var isScrolling: Bool { scrollViews.contains { $0.isDragging || $0.isDecelerating } }

    @objc private func toggleProbe() {
        if active {
            active = false
            probeDuration = CACurrentMediaTime() - probeStart
            displayLink?.invalidate()
            displayLink = nil
            scrollViews.removeAll()
            verifyDisk()
        } else {
            generation += 1
            frames = 0
            scrollFrames = 0
            asyncScrollFrames = 0
            maxGapMilliseconds = 0
            hitchMilliseconds = 0
            hitches = 0
            probeStart = CACurrentMediaTime()
            probeDuration = 0
            checkpointMainMilliseconds = 0
            preparationMilliseconds = 0
            previousFrame = nil
            wasScrolling = false
            lastScrollFlush = 0
            commits = 0
            scrollCommits = 0
            lastCheckpoint = nil
            diskVerified = false
            verificationError = nil
            func collect(_ view: UIView) {
                guard !view.isHidden, view.alpha > 0 else { return }
                if let scroll = view as? UIScrollView, scroll.window != nil { scrollViews.append(scroll) }
                view.subviews.forEach(collect)
            }
            if let window = button.window { collect(window) }
            active = true
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        if touchArmed {
            guard let start = touchWindowStart else { return }
            if CACurrentMediaTime() - start >= Self.touchWindowSeconds { stopWindow(); return }
        }
        if let previousFrame {
            let gap = now - previousFrame
            let expected = max(link.duration, 1.0 / 120)
            maxGapMilliseconds = max(maxGapMilliseconds, gap * 1_000)
            if gap > expected * 1.5 {
                hitches += 1
                hitchMilliseconds += (gap - expected) * 1_000
            }
        }
        previousFrame = now
        frames += 1
        if autoscrollView != nil { stepAutoscroll(CACurrentMediaTime()); scrollFrames += 1; return }
        let scrolling = isScrolling
        if scrolling {
            scrollFrames += 1
            if model?.player.isDeliveringListeningCheckpoint == true { asyncScrollFrames += 1 }
            // Sample real elapsed audio once per gesture, at most once a second, to guarantee scroll/save overlap.
            // This uses the production flush/delivery path, with no synthetic listening delta or preparation delay.
            if forcesScrollFlush, !wasScrolling, now - lastScrollFlush >= 1 {
                lastScrollFlush = now
                model?.player.flushListeningProgress()
            }
        }
        wasScrolling = scrolling
    }

    private func verifyDisk() {
        guard let checkpoint = lastCheckpoint else { verificationError = "No acknowledged listening checkpoint"; return }
        let url = directory.appendingPathComponent(LibraryPersistence.fileName)
        let generation = generation
        Task { [weak self] in
            let valid = await Task.detached(priority: .utility) {
                guard let data = try? LibraryPersistence.read(url),
                      let document = try? LibraryPersistence.decode(data, now: Date()),
                      document.events.count > DebugScrollPerformanceFixture.largeEventCount,
                      document.playback.queue.map(\.id) == checkpoint.snapshot.queue.map(\.id),
                      document.playback.currentIndex == checkpoint.snapshot.currentIndex,
                      document.playback.position >= checkpoint.snapshot.position,
                      let recent = checkpoint.recent,
                      document.recentlyPlayed.contains(where: { $0.id == recent.id && $0.position >= recent.position }) else { return false }
                return checkpoint.events.allSatisfy { captured in
                    document.events.contains { $0.id == captured.id && $0.track.id == captured.track.id
                        && $0.listenedSeconds >= captured.listenedSeconds }
                }
            }.value
            guard let self, generation == self.generation else { return }
            self.diskVerified = valid
            if !valid { self.verificationError = "Acknowledged checkpoint missing from saved library" }
        }
    }
}

/// Reports the start of every touch without recognizing, delaying or cancelling anything.
@MainActor
private final class DebugTouchSpy: UIGestureRecognizer {
    private let onBegan: () -> Void

    init(onBegan: @escaping () -> Void) {
        self.onBegan = onBegan
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onBegan()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

@MainActor
private final class DebugScrollPerformanceButton: UIButton {
    weak var probe: DebugScrollPerformanceFixture?

    // Pull diagnostics only for accessibility queries; frame sampling must not invalidate SwiftUI every frame.
    override var accessibilityValue: String? {
        get { probe?.diagnostics }
        set { }
    }
}
#endif
