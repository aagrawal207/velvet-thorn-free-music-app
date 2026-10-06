import OSLog
import SwiftUI

/// The bottom row's download control beside AirPlay: one 44-point target whose glyph is the download state of the
/// current song. Tapping downloads, cancels, retries or asks before removing; the More sheet keeps its own row.
@MainActor
struct PlayerDownloadButton: View {
    private static let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Player")
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var removalCandidate: Track?
    let track: Track?

    static let size: CGFloat = 44
    static let symbolSize: CGFloat = 20
    static let ringLineWidth: CGFloat = 2
    static let disabledOpacity: Double = 0.4

    enum Presentation: Equatable {
        /// No song, no download center, a song whose stream cannot be stored as one file, or offline with no local copy.
        case unavailable
        case idle
        case waiting(forWiFi: Bool)
        case downloading(Double)
        case downloaded
        case failed
    }

    var body: some View {
        let presentation = presentation
        Button {
            act(on: presentation)
        } label: {
            glyph(for: presentation)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(presentation == .unavailable)
        .accessibilityLabel(label(for: presentation))
        .accessibilityValue(value(for: presentation))
        .accessibilityIdentifier("player.download")
        .confirmationDialog("Remove Download?", isPresented: isConfirmingRemoval, titleVisibility: .visible,
                            presenting: removalCandidate) { candidate in
            Button("Remove Download") { remove(candidate) }
                .accessibilityIdentifier("player.download.remove")
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            // One short line: the iOS 26 anchored dialog clips a second message line behind its action.
            Text("Stays cached for now.")
        }
    }

    // MARK: State

    var presentation: Presentation {
        guard let track, model.downloads.isAvailable else { return .unavailable }
        switch model.downloadState(for: track) {
        case .downloaded: return .downloaded
        case .downloading(let fraction): return .downloading(fraction.isFinite ? min(max(fraction, 0), 1) : 0)
        case .queued: return .waiting(forWiFi: false)
        case .waitingForWiFi: return .waiting(forWiFi: true)
        case .failed: return canStartOffline(track) ? .failed : .unavailable
        case nil: return streamsWithoutAFile(track) || !canStartOffline(track) ? .unavailable : .idle
        }
    }

    /// Offline, only promoting a complete cached copy can succeed; pending items stay so a tap can still cancel.
    private func canStartOffline(_ track: Track) -> Bool {
        !model.isOffline || model.hasLocalCopy(track)
    }

    /// Gaana's own HLS streams cannot be stored as one file; a fallback file for the same song can. Until the
    /// stream is known the button stays off rather than promising a download that would fail.
    private func streamsWithoutAFile(_ track: Track) -> Bool {
        guard track.source == .gaana else { return false }
        guard model.player.currentTrack?.id == track.id, let url = model.player.currentStreamURL else { return true }
        return !CompositeStreamResolver.isCacheable(ResolvedStream(url: url))
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { removalCandidate != nil }, set: { if !$0 { removalCandidate = nil } })
    }

    // MARK: Actions

    private func act(on presentation: Presentation) {
        guard let track else { return }
        guard presentation != .unavailable else { return }
        Self.log.info("event=player_download_tap state=\(Self.logState(presentation), privacy: .public)")
        switch presentation {
        case .unavailable:
            return
        case .idle, .failed:
            model.download(track)
        case .waiting, .downloading:
            model.downloads.cancel(track.id)
        case .downloaded:
            // Capture the song now: the dialog outlives a song change and must remove what the listener saw.
            removalCandidate = track
        }
    }

    private func remove(_ track: Track) {
        Self.log.info("event=player_download_tap state=removeConfirmed")
        Task { await model.removeDownload(track) }
    }

    // MARK: Appearance

    private static func logState(_ presentation: Presentation) -> String {
        switch presentation {
        case .unavailable: "unavailable"
        case .idle: "idle"
        case .waiting(let forWiFi): forWiFi ? "waitingForWiFi" : "queued"
        case .downloading: "downloading"
        case .downloaded: "downloaded"
        case .failed: "failed"
        }
    }

    private func label(for presentation: Presentation) -> String {
        switch presentation {
        case .unavailable: "Download Unavailable"
        case .idle: "Download"
        case .waiting(let forWiFi): forWiFi ? "Waiting for Wi-Fi" : "Download Queued"
        case .downloading(let fraction): "Downloading, \(Self.spokenPercent(fraction))"
        case .downloaded: "Downloaded"
        case .failed: "Download Failed, Retry"
        }
    }

    private func value(for presentation: Presentation) -> String {
        if case .downloading(let fraction) = presentation { return Self.spokenPercent(fraction) }
        return ""
    }

    /// Shares `DownloadState.percent`'s clamp (99 until promoted) so the button and the More row agree.
    private static func spokenPercent(_ fraction: Double) -> String {
        "\(DownloadState.percent(fraction).dropLast()) percent"
    }

    @ViewBuilder
    private func glyph(for presentation: Presentation) -> some View {
        switch presentation {
        case .downloading(let fraction):
            progressRing(fraction)
        case .waiting:
            // The dotted ring keeps the idle glyph's shape and weight while reading as not started.
            symbol("arrow.down.circle.dotted", color: AppTheme.artworkSecondaryText)
        case .downloaded:
            symbol("arrow.down.circle.fill", color: AppTheme.accent)
        case .failed:
            symbol("exclamationmark.arrow.circlepath", color: AppTheme.artworkSecondaryText)
        case .idle:
            symbol("arrow.down.circle", color: AppTheme.artworkSecondaryText)
        case .unavailable:
            symbol("arrow.down.circle", color: AppTheme.artworkSecondaryText)
                .opacity(Self.disabledOpacity)
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: Self.symbolSize, weight: .medium))
            .foregroundStyle(color)
            // State swaps show at once; only the ring's fraction and the press animate.
            .transaction { $0.animation = nil }
    }

    /// A 20-point ring in place of the symbol: the track circle, the accent arc and a stop square, since a tap cancels.
    private func progressRing(_ fraction: Double) -> some View {
        ZStack {
            // Inset by half the stroke so the ring's outer edge matches the 20-point symbol box, not 22.
            Circle()
                .inset(by: Self.ringLineWidth / 2)
                .stroke(AppTheme.artworkSecondaryText.opacity(0.35), lineWidth: Self.ringLineWidth)
            Circle()
                .inset(by: Self.ringLineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: Self.ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fraction)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(AppTheme.artworkSecondaryText)
                .frame(width: 6, height: 6)
        }
        .frame(width: Self.symbolSize, height: Self.symbolSize)
        .transaction { $0.animation = nil }
    }
}
