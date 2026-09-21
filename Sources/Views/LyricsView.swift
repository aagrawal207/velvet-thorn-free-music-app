import SwiftUI

struct LyricsView: View {
    let track: Track
    @Environment(MusicAppModel.self) private var model
    @State private var loader = LyricsLoader()
    @State private var retry = 0

    private struct RequestID: Hashable {
        let track: Track
        let retry: Int
    }

    private var currentTrack: Track {
        var current = model.player.currentTrack ?? track
        current.duration = LyricsMatcher.validDuration(current.duration)?.rounded()
        let duration = model.player.duration
        if model.player.currentTrack?.id == current.id, duration.isFinite, duration >= 1 {
            current.duration = duration.rounded()
        }
        return current
    }

    var body: some View {
        let requestedTrack = currentTrack
        VStack(spacing: 0) {
            header(for: requestedTrack)
            if loader.track != requestedTrack {
                loading
            } else {
                switch loader.state {
                case .loading:
                    loading
                case .failed(let message):
                    status(symbol: "wifi.exclamationmark", title: "Couldn’t load lyrics", message: message) {
                        Button { retry &+= 1 } label: {
                            Text("Try again")
                                .appFont(.body)
                                .foregroundStyle(AppTheme.onAccent)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.large)
                        .accessibilityIdentifier("lyrics.retry")
                    }
                case .loaded(let document):
                    content(document, track: requestedTrack)
                }
            }
        }
        .background {
            LinearGradient(colors: [AppTheme.accent.opacity(0.12), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(AppTheme.background)
                .ignoresSafeArea()
        }
        .foregroundStyle(AppTheme.primaryText)
        .navigationTitle("Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: RequestID(track: requestedTrack, retry: retry)) {
            await loader.load(for: requestedTrack, using: model.lyrics)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.screen")
    }

    private func header(for track: Track) -> some View {
        HStack(spacing: 14) {
            ArtworkView(url: track.artworkURL, title: track.title, size: 52, cornerRadius: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title).appFont(.headline, weight: .semibold).lineLimit(2)
                Text(track.artistName).appFont(.subheadline).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView().tint(AppTheme.accent)
            Text("Finding lyrics…").appFont(.callout).foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lyrics.loading")
    }

    @ViewBuilder
    private func content(_ document: LyricsDocument, track: Track) -> some View {
        switch document.kind {
        case .synced:
            SyncedLyricsContent(track: track, document: document)
                .id("\(track.id):\(document.sourceID ?? 0)")
        case .plain:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Plain lyrics · Timing isn’t available")
                        .appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                    ForEach(Array((document.plainText ?? "").components(separatedBy: .newlines).enumerated()), id: \.offset) { line in
                        Text(line.element.isEmpty ? " " : line.element)
                            .appFont(.title2, weight: .semibold)
                            .lineSpacing(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityHidden(line.element.isEmpty)
                    }
                    LyricsSourceView(document: document).padding(.top, 16)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .accessibilityIdentifier("lyrics.plain")
        case .instrumental:
            status(symbol: "waveform", title: "Instrumental",
                   message: "This recording is listed as instrumental.") {
                LyricsSourceView(document: document)
            }
            .accessibilityIdentifier("lyrics.instrumental")
        case .unavailable:
            status(symbol: "text.quote", title: "No lyrics for this recording",
                   message: "No matching lyrics were found in the available sources.") {
                Text("Lyrics are checked with LRCLIB and YouTube Music.")
                    .appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            .accessibilityIdentifier("lyrics.unavailable")
        }
    }

    private func status<Accessory: View>(symbol: String, title: String, message: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(AppTheme.accent).accessibilityHidden(true)
                Text(title).appFont(.title2, weight: .bold).accessibilityAddTraits(.isHeader)
                Text(message).appFont(.body).foregroundStyle(AppTheme.secondaryText)
                accessory().padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct SyncedLyricsContent: View {
    let track: Track
    let document: LyricsDocument
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var currentLineID: Int?
    @State private var isFollowing = true

    private var offset: TimeInterval {
        LyricsTiming.boundedOffset(model.library.lyricsOffset(for: track.id))
    }

    private var isCurrentTrack: Bool { model.player.currentTrack?.id == track.id }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !isCurrentTrack {
                            Text("Play this song to follow along.")
                                .appFont(.callout).foregroundStyle(AppTheme.secondaryText)
                        }
                        Color.clear.frame(height: 48).accessibilityHidden(true)
                        ForEach(document.lines) { line in
                            lyricButton(line, proxy: proxy)
                        }
                        LyricsSourceView(document: document).padding(.top, 36)
                        Color.clear.frame(height: 160).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 28)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        isFollowing = false
                    }
                }
                .onChange(of: model.player.position, initial: true) { _, position in
                    updateActiveLine(at: position)
                }
                .onChange(of: offset) { _, _ in updateActiveLine(at: model.player.position) }
                .onChange(of: isCurrentTrack) { _, _ in updateActiveLine(at: model.player.position) }
                .onChange(of: currentLineID) { _, id in
                    if isFollowing, let id { follow(id, proxy: proxy) }
                }
                .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
                    if enabled { isFollowing = false }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowing, isCurrentTrack {
                        Button {
                            isFollowing = true
                            if let id = currentLineID ?? document.lines.first?.id { follow(id, proxy: proxy) }
                        } label: {
                            Label(currentLineID == nil ? "Follow lyrics" : "Current line", systemImage: "location.fill")
                                .appFont(.callout, weight: .semibold)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 48)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.primaryText)
                        .background(AppTheme.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppTheme.accent.opacity(0.5)))
                        .padding(20)
                        .accessibilityLabel("Return to current lyric")
                        .accessibilityIdentifier("lyrics.follow")
                    }
                }
            }
            timingControls
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.synced")
    }

    private func lyricButton(_ line: LyricLine, proxy: ScrollViewProxy) -> some View {
        let active = line.id == currentLineID
        let seekTime = LyricsTiming.seekPosition(for: line, offset: offset, duration: track.duration)
        return Button {
            guard isCurrentTrack else { return }
            model.player.seek(to: seekTime)
            isFollowing = true
            follow(line.id, proxy: proxy)
        } label: {
            Group {
                if line.text.isEmpty {
                    Image(systemName: "ellipsis").font(.largeTitle.weight(.bold))
                } else {
                    Text(line.text)
                        .appFont(.largeTitle, weight: .bold, design: .rounded)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .foregroundStyle(active ? AppTheme.primaryText : AppTheme.secondaryText.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isCurrentTrack)
        .id(line.id)
        .accessibilityLabel(line.text.isEmpty ? "Instrumental break" : line.text)
        .accessibilityValue(active ? "Current line" : "")
        .accessibilityHint("Seek to \(TimeText.duration(seekTime))")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("lyrics.line.\(line.id)")
    }

    private var timingControls: some View {
        VStack(spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize { timingLabel }
            HStack(spacing: 12) {
                Button { setOffset(offset - LyricsTiming.step) } label: {
                    Image(systemName: "minus").frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .disabled(offset <= -LyricsTiming.maximumOffset)
                .accessibilityLabel("Show lyrics half a second earlier")
                .accessibilityIdentifier("lyrics.offset.earlier")

                if !dynamicTypeSize.isAccessibilitySize { timingLabel }

                Button { setOffset(offset + LyricsTiming.step) } label: {
                    Image(systemName: "plus").frame(width: 48, height: 48).contentShape(Rectangle())
                }
                .disabled(offset >= LyricsTiming.maximumOffset)
                .accessibilityLabel("Show lyrics half a second later")
                .accessibilityIdentifier("lyrics.offset.later")

                Button("Reset") { setOffset(0) }
                    .appFont(.callout)
                    .frame(minWidth: 48, minHeight: 48)
                    .disabled(offset == 0)
                    .accessibilityLabel("Reset lyric timing")
            }
        }
        .buttonStyle(.plain)
        .tint(AppTheme.accent)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surface.opacity(0.96))
        .accessibilityElement(children: .contain)
    }

    private var timingLabel: some View {
        VStack(spacing: 2) {
            Text("Lyric timing").appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            Text(offsetLabel).monospacedDigit().appFont(.callout, weight: .semibold)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var offsetLabel: String {
        if abs(offset) < 0.001 { return "On time" }
        let value = abs(offset).formatted(.number.precision(.fractionLength(0...2)))
        return "\(value)s \(offset > 0 ? "later" : "earlier")"
    }

    private func setOffset(_ value: TimeInterval) {
        model.library.setLyricsOffset(LyricsTiming.boundedOffset(value), for: track.id)
        if let error = model.library.errorMessage { model.showToast(error) }
    }

    private func updateActiveLine(at position: TimeInterval) {
        let index = isCurrentTrack
            ? LRCParser.activeLineIndex(in: document.lines, at: position, offset: offset, duration: track.duration)
            : nil
        let id = index.map { document.lines[$0].id }
        if id != currentLineID { currentLineID = id }
    }

    private func follow(_ id: Int, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct LyricsSourceView: View {
    let document: LyricsDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LyricsAttributionView(document: document)
            if let title = document.matchedTitle, let artist = document.matchedArtist {
                Text("Matched: \(title) · \(artist)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appFont(.caption)
        .foregroundStyle(AppTheme.secondaryText)
        .tint(AppTheme.accent)
    }
}
