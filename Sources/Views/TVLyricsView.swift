import SwiftUI

struct TVLyricsView: View {
    enum Surface { case phone, externalDisplay }

    let controller: TVLyricsController
    var surface: Surface = .phone
    @ScaledMetric(relativeTo: .largeTitle) private var lyricSize: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var contextSize: CGFloat = 22

    private var isPhone: Bool { surface == .phone }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(2.2, max(1, geometry.size.width / 800))
            ZStack {
                Color.black.ignoresSafeArea()
                if controller.isContentVisible {
                    VStack(spacing: 12) {
                        header
                        lyrics(scale: scale)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        footer
                    }
                    .padding(.horizontal, max(24, geometry.size.width * 0.05))
                    .padding(.vertical, isPhone ? 12 : max(24, geometry.size.height * 0.05))
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .transaction { $0.animation = nil }
        .onAppear { if isPhone { controller.phonePresentationVisibilityChanged(true) } }
        .onDisappear { if isPhone { controller.phonePresentationVisibilityChanged(false) } }
        .accessibilityIdentifier(isPhone ? "tvLyrics.phone" : "tvLyrics.external")
    }

    private var header: some View {
        HStack(spacing: 16) {
            if let artwork = controller.artwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFit().frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.currentTrack?.title ?? "TV Lyrics")
                    .font(.headline).lineLimit(1)
                if let track = controller.currentTrack {
                    Text(track.artistName).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tvLyrics.track")
            Spacer(minLength: 0)
            if isPhone {
                if controller.hasExternalDisplay {
                    Button { controller.returnToLyrics() } label: {
                        Text("Lyrics Options").font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Returns to the lyrics choices while the separate display stays on.")
                    .accessibilityIdentifier("tvLyrics.options")
                }
                Button { controller.stop() } label: {
                    Label("Stop TV Lyrics", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.15), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tvLyrics.stop")
            }
        }
    }

    @ViewBuilder
    private func lyrics(scale: CGFloat) -> some View {
        if let timeline = controller.timeline {
            switch timeline.mode {
            case .timed:
                timedLines(scale: scale)
            case .untimed:
                ScrollView {
                    Text(controller.manualPage ?? "")
                        .font(.system(size: lyricSize * scale, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }
                .id("\(controller.selectionRevision):\(controller.manualPageIndex)")
                .accessibilityIdentifier("tvLyrics.page")
            case .instrumental:
                status("Instrumental", detail: "This recording is listed as instrumental.", scale: scale)
                    .accessibilityIdentifier("tvLyrics.instrumental")
            case .unavailable:
                status("No lyrics for this recording", detail: "Choose another version in Lyrics if one is available.", scale: scale)
                    .accessibilityIdentifier("tvLyrics.unavailable")
            }
        } else {
            status("Choose Lyrics on This Device", detail: "The selected version will appear here.", scale: scale)
                .accessibilityIdentifier("tvLyrics.waiting")
        }
    }

    private func timedLines(scale: CGFloat) -> some View {
        let lines = controller.lineWindow
        return ScrollView {
            VStack(spacing: 16) {
                if let previous = lines.previous {
                    line(previous, size: contextSize * scale, current: false)
                        .accessibilityIdentifier("tvLyrics.previousLine")
                }
                if let current = lines.current {
                    line(current, size: lyricSize * scale, current: true)
                        .accessibilityIdentifier("tvLyrics.currentLine")
                } else {
                    Text(lines.next == nil ? "" : "…")
                        .font(.system(size: lyricSize * scale, weight: .bold))
                        .accessibilityLabel(lines.next == nil ? "End of lyrics" : "Lyrics start soon")
                        .accessibilityIdentifier("tvLyrics.beforeOrAfter")
                }
                if let next = lines.next {
                    line(next, size: contextSize * scale, current: false)
                        .accessibilityIdentifier("tvLyrics.nextLine")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.center)
        .id("\(controller.selectionRevision):\(lines.current?.id.description ?? "none")")
        .accessibilityIdentifier("tvLyrics.timed")
    }

    private func line(_ line: LyricLine, size: CGFloat, current: Bool) -> some View {
        let isBreak = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Text(isBreak ? "♪" : line.text)
            .font(.system(size: size, weight: current ? .bold : .medium, design: .rounded))
            .foregroundStyle(.white.opacity(current ? 1 : 0.75))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(isBreak ? "Instrumental break" : line.text)
            .accessibilityValue(current ? "Current line" : "")
            .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func status(_ title: String, detail: String, scale: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(title).font(.system(size: lyricSize * scale, weight: .bold, design: .rounded))
                Text(detail).font(.body).foregroundStyle(.white.opacity(0.8))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if controller.timeline?.mode == .untimed {
                pageControls
            }
            if let document = controller.document {
                Text(["Lyrics · \(document.source)", controller.selectionLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("tvLyrics.source")
                if let credit = document.attributionText, !credit.isEmpty {
                    Text(credit).font(.caption).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("tvLyrics.copyright")
                }
            }
            if isPhone {
                Text("For TV, open Control Center and choose Screen Mirroring. Rotate this device for a wider view.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("tvLyrics.instructions")
            }
        }
    }

    private var pageControls: some View {
        HStack(spacing: 20) {
            if isPhone {
                pageButton("Previous Page", symbol: "chevron.left", delta: -1,
                           disabled: controller.manualPageIndex == 0, identifier: "tvLyrics.page.previous")
            }
            Text("Untimed · Page \(controller.manualPageIndex + 1) of \(controller.timeline?.pages.count ?? 0)")
                .font(.footnote).monospacedDigit()
                .accessibilityIdentifier("tvLyrics.page.number")
            if isPhone {
                pageButton("Next Page", symbol: "chevron.right", delta: 1,
                           disabled: controller.manualPageIndex + 1 >= (controller.timeline?.pages.count ?? 0),
                           identifier: "tvLyrics.page.next")
            }
        }
    }

    private func pageButton(_ title: String, symbol: String, delta: Int, disabled: Bool, identifier: String) -> some View {
        Button { controller.movePage(by: delta) } label: {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
                .font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                .background(.white.opacity(0.15), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityIdentifier(identifier)
    }
}

struct TVLyricsStartButton: View {
    let controller: TVLyricsController
    var prepareSelection: @MainActor () -> Void = {}

    var body: some View {
        HStack {
            Button {
                if !controller.isEnabled { prepareSelection() }
                controller.start()
            } label: {
                Label("TV Lyrics", systemImage: "tv")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(controller.currentTrack == nil || !controller.isPhoneSceneActive)
            .accessibilityHint("Opens large lyrics. Use Control Center Screen Mirroring to show them on a TV.")
            .accessibilityIdentifier("tvLyrics.start")
            if controller.isEnabled {
                Button { controller.stop() } label: {
                    Text("Stop TV Lyrics").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("tvLyrics.stopFromOptions")
            }
        }
    }
}

private struct TVLyricsPresentation: ViewModifier {
    let controller: TVLyricsController

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { controller.isPhonePresented }, set: { presented in
            if !presented, controller.isPhonePresented { controller.stop() }
        })) {
            TVLyricsView(controller: controller)
                .interactiveDismissDisabled()
        }
    }
}

extension View {
    func tvLyricsPresentation(controller: TVLyricsController) -> some View {
        modifier(TVLyricsPresentation(controller: controller))
    }
}
