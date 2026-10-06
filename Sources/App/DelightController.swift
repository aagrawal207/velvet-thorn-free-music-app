import Foundation
import Observation
import OSLog

/// Session state, device-local flags and toasts for the hidden delights; `Delights.swift` holds the rules and
/// docs/DELIGHTS.md the triggers. The model reaches it only through the hooks below.
@MainActor @Observable
final class DelightController {
    /// `UserDefaults` keys on this device only; none of them is part of the library or iCloud sync.
    enum Key {
        static let likesCenturyShown = "delight.likesCentury.shown"
        static let anniversaryDismissed = "delight.anniversary.dismissed"
        static let sleepPausedAt = "delight.sleepPause.pausedAt"
    }

    private(set) var heartBurst: HeartBurst?
    /// Completed About rounds; the Version row's light haptic is keyed to it.
    private(set) var aboutFlourishes = 0
    private(set) var dismissedAnniversaryYear: Int?

    @ObservationIgnored var clock: () -> Date
    @ObservationIgnored var calendar: Calendar = .autoupdatingCurrent
    @ObservationIgnored var locale: Locale = .autoupdatingCurrent
    @ObservationIgnored var playFlourish: @MainActor () -> Void
    @ObservationIgnored private weak var model: MusicAppModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Delights")
    @ObservationIgnored private var repeatStreak = RepeatStreak()
    @ObservationIgnored private var aboutTaps = AboutTapCounter()
    @ObservationIgnored private var isSceneActive = true
    @ObservationIgnored private var heartBurstTask: Task<Void, Never>?
    @ObservationIgnored private var loggedLateNight: Int?
    @ObservationIgnored private var loggedAnniversaryYear: Int?
    @ObservationIgnored private var cachedOrigin: (history: UInt64, lifetime: UInt64, origin: ListeningOrigin?)?
    @ObservationIgnored private var symbolToast: (message: String, symbol: String)?

    init(model: MusicAppModel?, defaults: UserDefaults = DelightController.defaultStore(),
         clock: @escaping () -> Date = { Date() }) {
        self.model = model
        self.defaults = defaults
        self.clock = clock
        let tabla = TablaFlourishPlayer()
        playFlourish = { tabla.play() }
        dismissedAnniversaryYear = defaults.object(forKey: Key.anniversaryDismissed) as? Int
        observeRepeatMode()
    }

    /// Real launches use the standard domain. Test hosts share the app's domain, so once-only flags get a scratch
    /// suite that each new controller clears.
    nonisolated static func defaultStore() -> UserDefaults {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil || process.arguments.contains("--uitesting") {
            let name = "com.agraabhi.ganabajana.delights.fixture"
            if let store = UserDefaults(suiteName: name) {
                store.removePersistentDomain(forName: name)
                return store
            }
        }
        #endif
        return .standard
    }

    // MARK: Likes

    /// Only explicit likes that added a song call this; imports, iCloud merges and promotions of liked songs do not.
    func likeAdded(likedCount: Int) {
        guard LikesCentury.celebrates(likedCount: likedCount,
                                      alreadyShown: defaults.bool(forKey: Key.likesCenturyShown)) else { return }
        defaults.set(true, forKey: Key.likesCenturyShown)
        startHeartBurst()
        show(DelightCopy.likesCentury, symbol: "heart.fill", kind: .likesCentury)
    }

    /// Like All Songs reads this before its confirmation, so the once-only century keeps the banner it just took.
    var isShowingCentury: Bool { model?.toast == DelightCopy.likesCentury }

    private func startHeartBurst() {
        let burst = HeartBurst(startedAt: Date())
        heartBurst = burst
        heartBurstTask?.cancel()
        heartBurstTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(HeartBurst.duration + 0.1))
            guard let self, self.heartBurst == burst else { return }
            self.heartBurst = nil
        }
    }

    // MARK: Repeat One

    func trackStarted(_ track: Track) {
        guard let player = model?.player else { return }
        let entries = player.queueEntries
        let index = player.currentIndex
        let occurrence = entries.indices.contains(index) && entries[index].track.id == track.id ? entries[index].id : nil
        guard repeatStreak.trackStarted(trackID: track.id, occurrence: occurrence, repeatMode: player.repeatMode) else { return }
        show(DelightCopy.repeatTen, symbol: nil, kind: .repeatTen)
    }

    /// The player reports starts but not mode changes, so the streak watches `repeatMode` itself.
    private func observeRepeatMode() {
        guard let player = model?.player else { return }
        withObservationTracking {
            _ = player.repeatMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.repeatModeChanged() }
        }
    }

    private func repeatModeChanged() {
        guard let player = model?.player else { return }
        repeatStreak.repeatModeChanged(to: player.repeatMode)
        observeRepeatMode()
    }

    // MARK: About

    func versionTapped() {
        guard let message = aboutTaps.tap(at: clock()) else { return }
        aboutFlourishes += 1
        playFlourish()
        show(message, symbol: nil, kind: .aboutTabla)
    }

    // MARK: Sleep timer

    /// Runs just before the timer pauses; a timer that finds the music already paused stays quiet.
    func sleepTimerFired(wasPlaying: Bool) {
        guard wasPlaying else { return }
        if isSceneActive {
            defaults.removeObject(forKey: Key.sleepPausedAt)
            show(DelightCopy.sleepForeground, symbol: "moon.zzz.fill", kind: .sleepPaused)
        } else {
            // Persisted, so a relaunch after iOS ends the suspended app still delivers the line.
            defaults.set(clock().timeIntervalSince1970, forKey: Key.sleepPausedAt)
        }
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        guard defaults.object(forKey: Key.sleepPausedAt) != nil else { return }
        let pausedAt = Date(timeIntervalSince1970: defaults.double(forKey: Key.sleepPausedAt))
        defaults.removeObject(forKey: Key.sleepPausedAt)
        guard let message = SleepPauseMessage.background(pausedAt: pausedAt, now: clock(), locale: locale,
                                                         timeZone: calendar.timeZone) else { return }
        show(message, symbol: "moon.zzz.fill", kind: .sleepPaused)
    }

    func sceneDidResignActive() {
        isSceneActive = false
    }

    // MARK: Equalizer and late night

    func equalizerLineShown(_ extreme: EqualizerExtreme) {
        record(extreme.kind)
    }

    /// The eyebrow re-renders every minute and on every player open; one record per night is enough.
    func lateNightShown(at date: Date) {
        let night = LateNightEyebrow.night(at: date, calendar: calendar)
        guard loggedLateNight != night else { return }
        loggedLateNight = night
        record(.lateNight)
    }

    // MARK: Anniversary

    func anniversaryCard() -> AnniversaryCard? {
        anniversaryCard(at: clock())
    }

    func anniversaryCard(at now: Date) -> AnniversaryCard? {
        guard let library = model?.library, library.preferences.saveListeningHistory else { return nil }
        let lifetime = library.lifetimeListeningSummary
        func card(_ origin: ListeningOrigin?) -> AnniversaryCard? {
            AnniversaryDelight.card(origin: origin, lifetimeSeconds: lifetime.seconds, historyEnabled: true,
                                    dismissedYear: dismissedAnniversaryYear, now: now, calendar: calendar)
        }
        // Receipts cover every retained session, so outside the anniversary week no event is scanned for the first song.
        if let coverage = lifetime.coverageStartedAt, card(ListeningOrigin(startedAt: coverage, firstSongTitle: nil)) == nil {
            return nil
        }
        return card(listeningOrigin(in: library))
    }

    func anniversaryShown(_ card: AnniversaryCard) {
        guard loggedAnniversaryYear != card.anniversaryYear else { return }
        loggedAnniversaryYear = card.anniversaryYear
        record(.anniversary)
    }

    func dismissAnniversary(_ card: AnniversaryCard) {
        dismissedAnniversaryYear = card.anniversaryYear
        defaults.set(card.anniversaryYear, forKey: Key.anniversaryDismissed)
    }

    /// Keyed by both revisions: a receipt-only change after detail pruning moves the origin without a history change.
    private func listeningOrigin(in library: LibraryStore) -> ListeningOrigin? {
        let history = library.historyRevision
        let lifetime = library.lifetimeListeningRevision
        if let cachedOrigin, cachedOrigin.history == history, cachedOrigin.lifetime == lifetime {
            return cachedOrigin.origin
        }
        let origin = ListeningOrigin.make(coverageStartedAt: library.lifetimeListeningSummary.coverageStartedAt,
                                          events: library.events)
        cachedOrigin = (history: history, lifetime: lifetime, origin: origin)
        return origin
    }

    // MARK: Toasts and metrics

    /// The banner's leading glyph for a delight toast it is currently showing.
    func toastSymbol(for message: String) -> String? {
        guard let symbolToast, symbolToast.message == message else { return nil }
        return symbolToast.symbol
    }

    private func show(_ message: String, symbol: String?, kind: DelightKind) {
        symbolToast = symbol.map { (message: message, symbol: $0) }
        model?.showToast(message)
        record(kind)
    }

    private func record(_ kind: DelightKind) {
        log.info("event=delight kind=\(kind.rawValue, privacy: .public) shown=1")
    }
}
