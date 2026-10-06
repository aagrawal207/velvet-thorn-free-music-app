import Foundation
@testable import GanaBajana

actor AsyncListeningCheckpointGate {
    private var heldAttempts: Set<Int>
    private var entries: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var attempts = 0
    private(set) var enteredOnMainThread = false

    init(heldAttempts: Set<Int> = [1]) { self.heldAttempts = heldAttempts }

    func enter(wasMainThread: Bool) async {
        attempts += 1
        let attempt = attempts
        enteredOnMainThread = enteredOnMainThread || wasMainThread
        entries.removeValue(forKey: attempt)?.resume()
        guard heldAttempts.contains(attempt) else { return }
        await withCheckedContinuation { releases[attempt] = $0 }
    }

    func waitForEntry(_ attempt: Int = 1) async {
        guard attempts < attempt else { return }
        await withCheckedContinuation { entries[attempt] = $0 }
    }

    func release(_ attempt: Int = 1) { releases.removeValue(forKey: attempt)?.resume() }

    func holdNextPreparation() -> Int {
        let attempt = attempts + 1
        heldAttempts.insert(attempt)
        return attempt
    }
}

@MainActor
func asyncCheckpointModel(library: LibraryStore, player: PlayerController) -> MusicAppModel {
    let lyrics = AppModelLyricsProvider()
    return MusicAppModel(library: library, player: player, catalog: AppModelCatalogProvider(),
                         charts: AppModelChartsProvider(), lyrics: lyrics,
                         account: YouTubeAccountStore(secrets: MemorySecretStore(), registry: YouTubeSessionRegistry()),
                         recordingLanguageService: ArtistSpotlightLanguageService(provider: lyrics),
                         generatesMixes: false, asynchronousListeningCheckpoints: true)
}

@MainActor
func stopAsyncCheckpointPlayer(_ player: PlayerController) {
    player.onListeningProgress = nil
    player.onSnapshotChanged = nil
    player.onSnapshotIntentChanged = nil
    player.onListeningCheckpoint = nil
    player.pause()
}
