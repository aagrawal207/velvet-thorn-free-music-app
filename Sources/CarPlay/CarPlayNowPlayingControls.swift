import CarPlay
import UIKit

@MainActor
final class CarPlayNowPlayingControls: NSObject, CPNowPlayingTemplateObserver {
    enum Control: Sendable { case shuffle, repeatMode, favorite }

    private var snapshot: CompanionSnapshot?
    private var generation = UUID()
    private var request: (@MainActor @Sendable (CompanionRequest, CompanionSnapshot) -> Void)?
    private var upNext: (@MainActor @Sendable () -> Void)?
    private(set) var buttons: [CPNowPlayingButton] = []

    init(request: @escaping @MainActor @Sendable (CompanionRequest, CompanionSnapshot) -> Void,
         upNext: @escaping @MainActor @Sendable () -> Void) {
        self.request = request
        self.upNext = upNext
        super.init()
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Queue"
        template.isAlbumArtistButtonEnabled = false
        rebuildButtons()
        template.add(self)
    }

    func update(_ snapshot: CompanionSnapshot?) {
        let previous = self.snapshot
        self.snapshot = snapshot
        let old = previous?.nowPlaying
        let new = snapshot?.nowPlaying
        if previous?.sessionID != snapshot?.sessionID || old?.trackID != new?.trackID
            || old?.isFavorite != new?.isFavorite || old?.shuffleEnabled != new?.shuffleEnabled
            || old?.repeatMode != new?.repeatMode {
            rebuildButtons()
        }
    }

    func activate(_ control: Control) {
        guard let snapshot, let playing = snapshot.nowPlaying, let request else { return }
        let action: CompanionAction
        switch control {
        case .shuffle: action = .setShuffle(!playing.shuffleEnabled)
        case .favorite: action = .setFavorite(!playing.isFavorite)
        case .repeatMode:
            switch playing.repeatMode {
            case .off: action = .setRepeatMode(.all)
            case .all: action = .setRepeatMode(.one)
            case .one: action = .setRepeatMode(.off)
            }
        }
        request(CompanionRequest(action: action, expectedTrackID: playing.trackID), snapshot)
    }

    func disconnect() {
        generation = UUID()
        request = nil
        upNext = nil
        snapshot = nil
        buttons.forEach { $0.isEnabled = false }
        CPNowPlayingTemplate.shared.remove(self)
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in self?.upNext?() }
    }

    private func rebuildButtons() {
        generation = UUID()
        let playing = snapshot?.nowPlaying
        let mode = playing?.repeatMode ?? .off
        buttons = [
            button(.shuffle, symbol: "shuffle", label: "Shuffle", selected: playing?.shuffleEnabled == true),
            button(.repeatMode, symbol: mode == .one ? "repeat.1" : "repeat",
                   label: mode == .one ? "Repeat one" : (mode == .all ? "Repeat all" : "Repeat off"), selected: mode != .off),
            button(.favorite, symbol: playing?.isFavorite == true ? "heart.fill" : "heart",
                   label: playing?.isFavorite == true ? "Remove favorite" : "Favorite", selected: playing?.isFavorite == true)
        ]
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    private func button(_ control: Control, symbol: String, label: String, selected: Bool) -> CPNowPlayingImageButton {
        let token = generation
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)) ?? UIImage()
        let button = CPNowPlayingImageButton(image: image.withRenderingMode(.alwaysTemplate)) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.activate(control)
            }
        }
        button.accessibilityLabel = label
        button.isSelected = selected
        button.isEnabled = snapshot?.nowPlaying != nil && request != nil
        return button
    }
}
