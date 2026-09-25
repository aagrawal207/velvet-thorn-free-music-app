import SwiftUI

@MainActor
struct WatchPlaybackOptionsView: View {
    @Environment(WatchCompanionModel.self) private var model

    var body: some View {
        List {
            if let displayed = model.timeline.snapshot, let track = displayed.nowPlaying {
                Toggle(isOn: Binding(get: { track.shuffleEnabled }, set: { enabled in
                    let action = CompanionAction.setShuffle(enabled)
                    Task { await model.command(action, displayed: displayed) }
                })) {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(minHeight: 44)
                }
                .disabled(!model.canControl)
                .accessibilityIdentifier("watch.shuffle")

                Button {
                    let action = CompanionAction.setRepeatMode(nextRepeatMode(track.repeatMode))
                    Task { await model.command(action, displayed: displayed) }
                } label: {
                    HStack {
                        Label("Repeat", systemImage: track.repeatMode == .one ? "repeat.1" : "repeat")
                        Spacer(minLength: 4)
                        Text(repeatTitle(track.repeatMode)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(!model.canControl)
                .accessibilityValue(repeatTitle(track.repeatMode))
                .accessibilityHint("Cycles between off, all songs, and one song")
                .accessibilityIdentifier("watch.repeat")
            } else {
                Text("Choose a song on iPhone to change playback options.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if model.pendingCommand != nil {
                Text("Sending to iPhone…").font(.footnote).foregroundStyle(.secondary)
            }
            if let notice = model.notice { WatchNoticeView(message: notice) }
            if let error = model.libraryError { WatchLibraryFailureView(message: error) }
            if !model.isCurrent { WatchConnectionView() }
        }
        .navigationTitle("Playback")
    }

    private func nextRepeatMode(_ mode: CompanionRepeatMode) -> CompanionRepeatMode {
        switch mode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    private func repeatTitle(_ mode: CompanionRepeatMode) -> String {
        switch mode {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }
}
