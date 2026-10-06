import CarPlay
import UIKit

@MainActor
final class CarPlayNowPlayingControls: NSObject, CPNowPlayingTemplateObserver {
    enum Control: Sendable { case shuffle, repeatMode, favorite, superLike }

    /// One snapshot-derived button: the symbol, label and selection CarPlay displays for a control.
    struct ButtonState: Equatable, Sendable {
        let control: Control
        let symbol: String
        let label: String
        let isSelected: Bool
    }

    private var snapshot: CompanionSnapshot?
    private var generation = UUID()
    private var request: (@MainActor @Sendable (CompanionRequest, CompanionSnapshot) -> Void)?
    private var upNext: (@MainActor @Sendable () -> Void)?
    private(set) var buttons: [CPNowPlayingButton] = []
    private(set) var buttonStates: [ButtonState] = []

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
            || old?.isFavorite != new?.isFavorite || old?.isSuperLiked != new?.isSuperLiked
            || old?.shuffleEnabled != new?.shuffleEnabled || old?.repeatMode != new?.repeatMode {
            rebuildButtons()
        }
    }

    func activate(_ control: Control) {
        guard let snapshot, let playing = snapshot.nowPlaying, let request else { return }
        let action: CompanionAction
        switch control {
        case .shuffle: action = .setShuffle(!playing.shuffleEnabled)
        case .favorite: action = .setFavorite(!playing.isFavorite)
        case .superLike: action = .setSuperLiked(!playing.isSuperLiked)
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

    /// Order is fixed at shuffle, repeat, favorite, super like; CarPlay allows five extra buttons.
    static func buttonStates(for playing: CompanionNowPlaying?) -> [ButtonState] {
        let mode = playing?.repeatMode ?? .off
        let favorite = playing?.isFavorite == true
        let superLiked = playing?.isSuperLiked == true
        return [
            ButtonState(control: .shuffle, symbol: "shuffle", label: "Shuffle", isSelected: playing?.shuffleEnabled == true),
            ButtonState(control: .repeatMode, symbol: mode == .one ? "repeat.1" : "repeat",
                        label: mode == .one ? "Repeat one" : (mode == .all ? "Repeat all" : "Repeat off"), isSelected: mode != .off),
            ButtonState(control: .favorite, symbol: superLiked ? "bolt.heart.fill" : (favorite ? "heart.fill" : "heart"),
                        label: favorite ? "Remove favorite" : "Favorite", isSelected: favorite),
            ButtonState(control: .superLike, symbol: superLiked ? "bolt.heart.fill" : "bolt.heart",
                        label: superLiked ? "Change to favorite" : "Super like", isSelected: superLiked),
        ]
    }

    private func rebuildButtons() {
        generation = UUID()
        buttonStates = Self.buttonStates(for: snapshot?.nowPlaying)
        buttons = buttonStates.map { button($0) }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    private func button(_ state: ButtonState) -> CPNowPlayingImageButton {
        let token = generation
        let control = state.control
        let image = UIImage(systemName: state.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24)) ?? UIImage()
        let button = CPNowPlayingImageButton(image: image.withRenderingMode(.alwaysTemplate)) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.activate(control)
            }
        }
        button.accessibilityLabel = state.label
        button.isSelected = state.isSelected
        button.isEnabled = snapshot?.nowPlaying != nil && request != nil
        return button
    }
}
