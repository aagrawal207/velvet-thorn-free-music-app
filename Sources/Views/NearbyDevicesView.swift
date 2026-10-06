import SwiftUI
import UIKit

/// Devices sheet: this device, nearby Velvet Thorn devices with remote controls, and moving playback between them.
struct NearbyDevicesView: View {
    let controller: NearbyDevicesController

    @Environment(MusicAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NearbyDevicesList(controller: controller)
                .navigationTitle("Devices")
                .navigationBarTitleDisplayMode(.inline)
                .appSheetDoneButton(id: "nearby.done") { AppNavigationIntent.perform(in: model) { dismiss() } }
        }
        .appSheetChrome()
    }
}

/// The Devices content, pushed inside Settings and Song Options or hosted by the sheet above.
struct NearbyDevicesList: View {
    let controller: NearbyDevicesController

    @Environment(MusicAppModel.self) private var model
    @State private var showsPairing = false
    @State private var confirmsKeyReset = false
    @State private var keyResetFailed = false

    private var isEnabled: Binding<Bool> {
        Binding(get: { controller.isEnabled }, set: { $0 ? controller.enable() : controller.disable() })
    }

    var body: some View {
            List {
                Section {
                    Toggle("Find Nearby Devices", isOn: isEnabled)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("nearby.enabled")
                } footer: {
                    Text("Playback control and transfers stay on your local network. The connection key syncs through iCloud Keychain.")
                }

                Section {
                    thisDeviceRow
                } header: {
                    Text("This Device")
                }

                if controller.isEnabled {
                    enabledSections
                } else {
                    Section {
                        Text("Turn on Find Nearby Devices to see and control Velvet Thorn on your other iPhone, iPad or Mac.")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("nearby.off")
                    }
                }

                Section {
                    Button("Reset Device Key", role: .destructive) { confirmsKeyReset = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("nearby.resetKey")
                    if keyResetFailed {
                        Text("The device key couldn't be saved. Try again.")
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("nearby.resetKey.error")
                    }
                } footer: {
                    Text("Resetting disconnects every device that uses the current key.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .accessibilityIdentifier("nearby.list")
            // Opening this screen is the explicit action that may show the Local Network prompt, until a choice is saved.
            .onAppear { controller.enableOnFirstVisit() }
            .sheet(isPresented: $showsPairing) {
                NearbyPairingSheet(controller: controller)
            }
            .confirmationDialog("Reset Device Key?", isPresented: $confirmsKeyReset, titleVisibility: .visible) {
                Button("Reset Device Key", role: .destructive) { keyResetFailed = !controller.resetLinkKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your other devices will need to pair again unless iCloud Keychain syncs the new key.")
            }
    }

    @ViewBuilder
    private var enabledSections: some View {
                if case .failed(let message) = controller.transferState {
                    Section {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(message)
                                .appFont(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Dismiss") { controller.dismissTransferFailure() }
                                .buttonStyle(.plain)
                                .foregroundStyle(AppTheme.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("nearby.transferError.dismiss")
                        }
                        .accessibilityIdentifier("nearby.transferError")
                    }
                }

                Section {
                    if controller.peers.isEmpty {
                        Text("No other devices found. Open Velvet Thorn on your iPhone, iPad or Mac on the same Wi-Fi network.")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("nearby.empty")
                    } else {
                        ForEach(Array(controller.peers.enumerated()), id: \.element.id) { index, peer in
                            NearbyPeerRow(controller: controller, peer: peer, index: index)
                        }
                    }
                } header: {
                    Text("Nearby Devices")
                } footer: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Devices signed in to the same iCloud account connect automatically when iCloud Keychain is on. Otherwise, pair them once with a code.")
                        Button("Pair With a Code") { showsPairing = true }
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppTheme.accent)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("nearby.pairCode")
                    }
                    .padding(.top, 10)
                }
    }

    private var thisDeviceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.deviceKind.symbolName)
                .appFont(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayName)
                    .appFont(.body, weight: .semibold)
                Text(model.player.displayTitle.map { title in
                    [title, model.player.displaySubtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                } ?? "Nothing playing")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nearby.thisDevice")
    }
}

private struct NearbyPeerRow: View {
    let controller: NearbyDevicesController
    let peer: NearbyPeer
    let index: Int

    @State private var scrubPosition: Double?

    private var nowPlaying: CompanionNowPlaying? { peer.nowPlaying?.snapshot.nowPlaying }
    private var isPreparing: Bool { controller.transferState == .preparing(peerID: peer.id) }
    private var canControl: Bool { peer.isConnected && nowPlaying != nil && !controller.isTransferring }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let nowPlaying {
                HStack(spacing: 12) {
                    ArtworkView(url: peer.nowPlaying?.artworkURL, title: nowPlaying.title, size: 48, cornerRadius: AppCorner.compact)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.title)
                            .appFont(.body, weight: .medium)
                            .lineLimit(1)
                        Text(nowPlaying.artist)
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
                controls(nowPlaying)
                seekBar(nowPlaying)
            } else {
                Text("Nothing playing")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            if let error = peer.controlError {
                Text(error)
                    .appFont(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("nearby.controlError.\(index)")
            }
            actions
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nearby.device.\(index)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: peer.kind.symbolName)
                .appFont(.title3)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .appFont(.body, weight: .semibold)
                    .lineLimit(1)
                Text(peer.isConnected ? "Connected" : "Reconnecting")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            Spacer(minLength: 0)
            if isPreparing {
                ProgressView()
                    .accessibilityLabel("Moving playback")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func controls(_ nowPlaying: CompanionNowPlaying) -> some View {
        HStack(spacing: 4) {
            controlButton("backward.fill", label: "Previous", id: "nearby.previous.\(index)") { send(.previous) }
            controlButton(nowPlaying.isPlaying || nowPlaying.isLoading ? "pause.fill" : "play.fill",
                          label: nowPlaying.isPlaying || nowPlaying.isLoading ? "Pause" : "Play",
                          id: "nearby.playPause.\(index)") {
                send(nowPlaying.isPlaying || nowPlaying.isLoading ? .pause : .play)
            }
            controlButton("forward.fill", label: "Next", id: "nearby.next.\(index)") { send(.next) }
            Spacer(minLength: 0)
            controlButton("shuffle", label: nowPlaying.shuffleEnabled ? "Turn Off Shuffle" : "Shuffle",
                          id: "nearby.shuffle.\(index)", active: nowPlaying.shuffleEnabled) {
                send(.setShuffle(!nowPlaying.shuffleEnabled))
            }
            controlButton(nowPlaying.repeatMode == .one ? "repeat.1" : "repeat", label: repeatLabel(nowPlaying.repeatMode),
                          id: "nearby.repeat.\(index)", active: nowPlaying.repeatMode != .off) {
                send(.setRepeatMode(nextRepeatMode(nowPlaying.repeatMode)))
            }
            likeButton(nowPlaying)
        }
        .disabled(!canControl)
    }

    private func likeButton(_ nowPlaying: CompanionNowPlaying) -> some View {
        let symbol = nowPlaying.isSuperLiked ? "bolt.heart.fill" : nowPlaying.isFavorite ? "heart.fill" : "heart"
        return Image(systemName: symbol)
            .appFont(.body, weight: .semibold)
            .foregroundStyle(nowPlaying.isFavorite ? AppTheme.accent : AppTheme.secondaryText)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { send(.setFavorite(!nowPlaying.isFavorite)) }
            .onLongPressGesture(minimumDuration: 0.4) { send(.setSuperLiked(!nowPlaying.isSuperLiked)) }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(nowPlaying.isSuperLiked ? "Super Liked" : nowPlaying.isFavorite ? "Liked" : "Like")
            .accessibilityAction { send(.setFavorite(!nowPlaying.isFavorite)) }
            .accessibilityAction(named: nowPlaying.isSuperLiked ? "Change to Like" : "Super Like") {
                send(.setSuperLiked(!nowPlaying.isSuperLiked))
            }
            .accessibilityIdentifier("nearby.like.\(index)")
    }

    private func controlButton(_ symbol: String, label: String, id: String, active: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .appFont(.body, weight: .semibold)
                .foregroundStyle(active ? AppTheme.accent : AppTheme.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func seekBar(_ nowPlaying: CompanionNowPlaying) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let duration = max(nowPlaying.duration, 0)
            let live = peer.position(at: controller.now()) ?? nowPlaying.position
            let shown = scrubPosition ?? min(live, duration)
            HStack(spacing: 8) {
                Text(Self.time(shown))
                    .appFont(.caption, design: .monospaced)
                    .foregroundStyle(AppTheme.secondaryText)
                Slider(value: Binding(get: { shown }, set: { scrubPosition = $0 }), in: 0...max(duration, 1)) { editing in
                    guard !editing, let target = scrubPosition else { return }
                    scrubPosition = nil
                    send(.seek(target))
                }
                .disabled(!canControl || duration <= 0)
                .frame(minHeight: 44)
                .accessibilityLabel("Position")
                .accessibilityValue(Self.time(shown))
                .accessibilityIdentifier("nearby.seek.\(index)")
                Text(Self.time(duration))
                    .appFont(.caption, design: .monospaced)
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if nowPlaying != nil {
                Button("Play Here") { controller.playHere(from: peer.id) }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(!peer.isConnected || controller.isTransferring)
                    .accessibilityIdentifier("nearby.playHere.\(index)")
            }
            if controller.canSendPlayback {
                Button("Play on \(peer.displayName)") { controller.playOn(peer.id) }
                    .buttonStyle(.bordered)
                    .lineLimit(1)
                    .frame(minHeight: 44)
                    .disabled(!peer.isConnected || controller.isTransferring)
                    .accessibilityIdentifier("nearby.sendTo.\(index)")
            }
        }
    }

    // Capture the displayed track before the Task so a late tap cannot act on a newer song.
    private func send(_ action: CompanionAction) {
        let id = peer.id
        let displayed = nowPlaying?.trackID
        Task { await controller.send(action, to: id, displayedTrackID: displayed) }
    }

    private func nextRepeatMode(_ mode: CompanionRepeatMode) -> CompanionRepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    private func repeatLabel(_ mode: CompanionRepeatMode) -> String {
        switch mode {
        case .off: "Repeat"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

private struct NearbyPairingSheet: View {
    let controller: NearbyDevicesController

    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.show
    @State private var entered = ""

    private enum Mode: Hashable { case show, enter }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Pairing", selection: $mode) {
                    Text("Show a Code").tag(Mode.show)
                    Text("Enter a Code").tag(Mode.enter)
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("nearby.pairing.mode")

                switch mode {
                case .show: showContent
                case .enter: enterContent
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.background)
            .navigationTitle("Pair With a Code")
            .navigationBarTitleDisplayMode(.inline)
            .appSheetDoneButton(id: "nearby.pairing.done") { dismiss() }
        }
        .appSheetChrome()
        .onDisappear {
            controller.cancelPairingCode()
            controller.dismissPairingResult()
        }
    }

    @ViewBuilder
    private var showContent: some View {
        if let code = controller.pairingCode {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, Int(code.expiresAt - controller.now()))
                VStack(alignment: .leading, spacing: 12) {
                    Text(code.display)
                        .appFont(.title2, weight: .semibold, design: .monospaced)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .accessibilityLabel(code.display.map(String.init).joined(separator: " "))
                        .accessibilityIdentifier("nearby.pairing.code")
                    Button {
                        UIPasteboard.general.string = code.display
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("nearby.pairing.copy")
                    Text("Enter this code on your other device. It works once and expires in \(remaining / 60):\(String(format: "%02d", remaining % 60)).")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
            }
        } else if controller.pairingState == .paired {
            Text("The other device is paired with this device.")
                .appFont(.subheadline)
                .accessibilityIdentifier("nearby.pairing.paired")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Show a code here, then enter it on the device you want to connect.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                Button("Show Code") { controller.showPairingCode() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(!controller.isEnabled)
                    .accessibilityIdentifier("nearby.pairing.show")
            }
        }
    }

    @ViewBuilder
    private var enterContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter or paste the 16-character code shown on your other device.")
                .appFont(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
            TextField("XXXX-XXXX-XXXX-XXXX", text: $entered)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .appFont(.title3, design: .monospaced)
                .frame(minHeight: 44)
                .accessibilityLabel("Pairing Code")
                .accessibilityIdentifier("nearby.pairing.entry")
            switch controller.pairingState {
            case .joining:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting…").appFont(.subheadline)
                }
            case .paired:
                Text("This device is paired.")
                    .appFont(.subheadline)
                    .accessibilityIdentifier("nearby.pairing.paired")
            case .failed(let message):
                Text(message)
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("nearby.pairing.error")
            case .idle:
                EmptyView()
            }
            Button("Connect") { controller.joinPairing(code: entered) }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!NearbyPairingCode.isWellFormed(entered) || controller.pairingState == .joining || !controller.isEnabled)
                .accessibilityIdentifier("nearby.pairing.connect")
        }
    }
}

extension NearbyDeviceKind {
    var symbolName: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        }
    }
}
