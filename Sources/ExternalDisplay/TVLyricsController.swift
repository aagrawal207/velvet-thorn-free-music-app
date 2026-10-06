import Foundation
import Observation
import OSLog
import UIKit

@MainActor @Observable
final class TVLyricsController {
    struct SelectionToken: Equatable, Sendable {
        fileprivate let trackID: String
        fileprivate let generation: UUID
    }

    enum StopReason: String { case user, privacy, signOut, suspended, runtimeReplaced }

    private(set) var isEnabled = false
    private(set) var isPhonePresented = false
    private(set) var isPhoneSceneActive = false
    private(set) var manualPageIndex = 0
    private(set) var selectionRevision: UInt64 = 0
    private(set) var selectionLabel: String?
    private var selectedDocument: LyricsDocument?
    private var selectedTimeline: TVLyricsTimeline?
    private var selectedArtwork: UIImage?
    private var phoneIsVisible = false
    private var externalScenes: [UUID: Bool] = [:]
    @ObservationIgnored private var trackedID: String?
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private let readTrack: @MainActor () -> Track?
    @ObservationIgnored private let readPosition: @MainActor () -> TimeInterval
    @ObservationIgnored private let readDuration: @MainActor () -> TimeInterval
    @ObservationIgnored private let readOffset: @MainActor (String) -> TimeInterval
    @ObservationIgnored private let idleTimer: TVLyricsIdleTimer
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "TVLyrics")

    init(track: @escaping @MainActor () -> Track?, position: @escaping @MainActor () -> TimeInterval,
         duration: @escaping @MainActor () -> TimeInterval,
         lyricsOffset: @escaping @MainActor (String) -> TimeInterval,
         idleTimer: TVLyricsIdleTimer) {
        readTrack = track
        readPosition = position
        readDuration = duration
        readOffset = lyricsOffset
        self.idleTimer = idleTimer
        trackedID = track()?.id
        observeTrack()
    }

    convenience init(player: PlayerController, lyricsOffset: @escaping @MainActor (String) -> TimeInterval) {
        self.init(track: { player.currentTrack }, position: { player.position }, duration: { player.duration },
                  lyricsOffset: lyricsOffset, idleTimer: .system())
    }

    var currentTrack: Track? { readTrack() }
    var position: TimeInterval { readPosition() }
    var duration: TimeInterval? {
        PlaybackTiming.validDuration(readDuration()) ?? PlaybackTiming.validDuration(currentTrack?.duration)
    }
    var offset: TimeInterval { currentTrack.map { LyricsTiming.boundedOffset(readOffset($0.id)) } ?? 0 }
    var isContentVisible: Bool { isEnabled && isPhoneSceneActive }
    var hasExternalDisplay: Bool { !externalScenes.isEmpty }

    // The live identity fence also applies before the observation callback's main-actor hop completes.
    var document: LyricsDocument? {
        guard let selectedDocument, selectedDocument.trackID == currentTrack?.id else { return nil }
        return selectedDocument
    }

    var timeline: TVLyricsTimeline? { document == nil ? nil : selectedTimeline }
    var artwork: UIImage? { document == nil ? nil : selectedArtwork }
    var lineWindow: TVLyricsTimeline.LineWindow {
        timeline?.window(at: position, offset: offset, duration: duration) ?? .init()
    }
    var manualPage: String? {
        guard let pages = timeline?.pages, pages.indices.contains(manualPageIndex) else { return nil }
        return pages[manualPageIndex]
    }

    /// Capture before asynchronous selection work; a newer selection retires older same-track variants too.
    func beginSelection(for trackID: String) -> SelectionToken? {
        synchronizeTrack()
        guard currentTrack?.id == trackID else { return nil }
        clearSelection()
        return SelectionToken(trackID: trackID, generation: selectionGeneration)
    }

    @discardableResult
    func select(_ document: LyricsDocument, token: SelectionToken, label: String? = nil,
                artwork: UIImage? = nil) -> Bool {
        synchronizeTrack()
        guard token.generation == selectionGeneration, token.trackID == currentTrack?.id,
              document.trackID == token.trackID else {
            log.info("event=selection_rejected reason=stale_or_mismatched")
            return false
        }
        selectedDocument = document
        selectedTimeline = TVLyricsTimeline(document: document)
        selectedArtwork = artwork
        selectionLabel = label
        manualPageIndex = 0
        selectionRevision &+= 1
        let mode = selectedTimeline?.mode.rawValue ?? "unavailable"
        log.info("event=selection mode=\(mode, privacy: .public)")
        return true
    }

    @discardableResult
    func start() -> Bool {
        synchronizeTrack()
        guard currentTrack != nil, isPhoneSceneActive else { return false }
        if !isEnabled { log.info("event=presentation state=started") }
        isEnabled = true
        isPhonePresented = true
        updateIdleTimer()
        return true
    }

    func stop(reason: StopReason = .user) {
        if isEnabled { log.info("event=presentation state=stopped reason=\(reason.rawValue, privacy: .public)") }
        isEnabled = false
        isPhonePresented = false
        phoneIsVisible = false
        clearSelection()
        updateIdleTimer()
    }

    func returnToLyrics() {
        guard isEnabled, hasExternalDisplay else { return }
        isPhonePresented = false
        phoneIsVisible = false
        updateIdleTimer()
    }

    func setPhoneSceneActive(_ active: Bool) {
        isPhoneSceneActive = active
        synchronizeTrack()
        updateIdleTimer()
    }

    func phonePresentationVisibilityChanged(_ visible: Bool) {
        phoneIsVisible = visible && isPhonePresented
        updateIdleTimer()
    }

    func connectExternalScene(_ id: UUID, active: Bool) {
        let isNew = externalScenes[id] == nil
        externalScenes[id] = active
        if isNew { log.info("event=external_scene state=connected") }
        updateIdleTimer()
    }

    func setExternalSceneActive(_ id: UUID, active: Bool) {
        guard externalScenes[id] != nil else { return }
        externalScenes[id] = active
        updateIdleTimer()
    }

    func disconnectExternalScene(_ id: UUID) {
        guard externalScenes.removeValue(forKey: id) != nil else { return }
        log.info("event=external_scene state=disconnected")
        updateIdleTimer()
    }

    func canDisplayOnExternalScene(_ id: UUID) -> Bool {
        isContentVisible && externalScenes[id] == true
    }

    func movePage(by delta: Int) {
        guard isContentVisible, let pages = timeline?.pages, !pages.isEmpty else { return }
        if delta > 0 { manualPageIndex = min(pages.count - 1, manualPageIndex + 1) }
        if delta < 0 { manualPageIndex = max(0, manualPageIndex - 1) }
    }

    func synchronizeTrack() {
        let id = currentTrack?.id
        guard trackedID != id else { return }
        trackedID = id
        clearSelection()
        if id == nil { stop() }
    }

    private func clearSelection() {
        selectionGeneration = UUID()
        selectedDocument = nil
        selectedTimeline = nil
        selectedArtwork = nil
        selectionLabel = nil
        manualPageIndex = 0
        selectionRevision &+= 1
    }

    private func updateIdleTimer() {
        idleTimer.update(isPresenting: isContentVisible && (phoneIsVisible || externalScenes.values.contains(true)))
    }

    private func observeTrack() {
        withObservationTracking {
            _ = readTrack()?.id
        } onChange: { [weak self] in
            // Observation fires before mutation, so read the completed track change on the next actor turn.
            Task { @MainActor [weak self] in
                self?.synchronizeTrack()
                self?.observeTrack()
            }
        }
    }
}
