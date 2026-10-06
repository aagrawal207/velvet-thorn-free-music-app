import SwiftUI

struct LyricsView: View {
    let track: Track
    let recordingLanguage: String?
    private let requestLoad: (@MainActor (Track, String?) -> Void)?
    @Environment(MusicAppModel.self) private var model
    @State private var loader: LyricsLoader
    @State private var retry = 0

    init(track: Track, loader: LyricsLoader = LyricsLoader(), recordingLanguage: String? = nil,
         requestLoad: (@MainActor (Track, String?) -> Void)? = nil) {
        self.track = track
        self.recordingLanguage = recordingLanguage
        self.requestLoad = requestLoad
        _loader = State(initialValue: loader)
    }

    private struct RequestID: Hashable {
        let track: Track
        let retry: Int
        let language: String?
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
        let requestedLanguage = requestedTrack.id == track.id ? recordingLanguage : nil
        VStack(spacing: 0) {
            caption(for: requestedTrack)
            if loader.track != requestedTrack {
                loading
            } else {
                switch loader.state {
                case .loading:
                    loading
                case .failed(let message):
                    status(symbol: "wifi.exclamationmark", title: "Couldn’t load lyrics", message: message) {
                        Button { retry &+= 1 } label: {
                            Text("Try Again")
                                .appFont(.body)
                                .foregroundStyle(AppTheme.onAccent)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .controlSize(.large)
                        .accessibilityIdentifier("lyrics.retry")
                    }
                case .loaded(let document):
                    variantControls(for: requestedTrack)
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
        .task(id: RequestID(track: requestedTrack, retry: retry, language: requestedLanguage)) {
            guard !Task.isCancelled else { return }
            if let requestLoad { requestLoad(requestedTrack, requestedLanguage) }
            else { await loader.load(for: requestedTrack, using: model.lyrics, recordingLanguage: requestedLanguage) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.screen")
    }

    @ViewBuilder
    private func variantControls(for track: Track) -> some View {
        let selectedID = loader.selectedDocument?.selectionID
        let selectedVariant = loader.variants.first { $0.id == selectedID }
        VStack(alignment: .leading, spacing: 4) {
            if loader.variants.count > 1 {
                Menu {
                    ForEach(loader.variants) { variant in
                        Button {
                            loader.selectVariant(id: variant.id, for: track)
                        } label: {
                            if selectedID == variant.id {
                                Label(variant.title(recordingLanguage: loader.recordingLanguage), systemImage: "checkmark")
                            } else {
                                Text(variant.title(recordingLanguage: loader.recordingLanguage))
                            }
                        }
                        .accessibilityIdentifier("lyrics.variant.\(variant.id)")
                    }
                } label: {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lyric Version").appFont(.caption)
                            Text(selectedVariant?.title(recordingLanguage: loader.recordingLanguage) ?? "Published Text")
                                .appFont(.callout, weight: .semibold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lyrics.variantPicker")
                Text("Latin text may be a romanisation or translation.")
                    .appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            if loader.isDiscoveringVariants {
                Text("Checking other lyric versions…")
                    .appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("lyrics.variants.loading")
            } else if let message = loader.variantMessage {
                Button { retry &+= 1 } label: {
                    Text(message).appFont(.caption)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lyrics.variants.retry")
            }
        }
        .padding(.horizontal, 28)
    }

    /// The sheet title already says Lyrics; one line names the song so the artwork header's space goes to lines.
    private func caption(for track: Track) -> some View {
        Text("\(track.title) · \(track.artistName)")
            .appFont(.footnote, weight: .medium)
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 2)
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
                .id("\(track.id):\(document.selectionID)")
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
            .id(document.selectionID)
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
                Text("Availability varies by recording and source.")
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var currentLineID: Int?
    @State private var isFollowing = true

    private var offset: TimeInterval {
        LyricsTiming.boundedOffset(model.library.lyricsOffset(for: track.id))
    }

    private var isCurrentTrack: Bool { model.player.currentTrack?.id == track.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !isCurrentTrack {
                        Text("Play this song to follow along.")
                            .appFont(.callout).foregroundStyle(AppTheme.secondaryText)
                    }
                    Color.clear.frame(height: 12).accessibilityHidden(true)
                    ForEach(document.lines) { line in
                        lyricButton(line, proxy: proxy)
                    }
                    LyricsSourceView(document: document).padding(.top, 36)
                    // Room for the pinned timing capsule and for centering the last lines while following.
                    Color.clear.frame(height: 140).accessibilityHidden(true)
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
            .overlay(alignment: .bottom) {
                // Both controls float over the lines so the lyrics keep the full height.
                VStack(alignment: .trailing, spacing: 12) {
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
                        .padding(.trailing, 4)
                        .accessibilityLabel("Return to current lyric")
                        .accessibilityIdentifier("lyrics.follow")
                    }
                    timingControls
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyrics.synced")
    }

    // Some accents sit below primary text's contrast on light backdrops; Increase Contrast keeps the strongest colour.
    private var activeLineColor: Color {
        colorSchemeContrast == .increased ? AppTheme.primaryText : AppTheme.accent
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
            .foregroundStyle(active ? activeLineColor : AppTheme.secondaryText.opacity(0.72))
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

    /// One 44-point row in a glass capsule. Accessibility sizes stack the label above the buttons.
    private var timingControls: some View {
        VStack(spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize { timingLabel.padding(.top, 8) }
            HStack(spacing: 4) {
                Button { setOffset(offset - LyricsTiming.step) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(offset <= -LyricsTiming.maximumOffset)
                .opacity(offset <= -LyricsTiming.maximumOffset ? 0.4 : 1)
                .accessibilityLabel("Show lyrics half a second earlier")
                .accessibilityIdentifier("lyrics.offset.earlier")

                if !dynamicTypeSize.isAccessibilitySize { timingLabel }

                Button { setOffset(offset + LyricsTiming.step) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .disabled(offset >= LyricsTiming.maximumOffset)
                .opacity(offset >= LyricsTiming.maximumOffset ? 0.4 : 1)
                .accessibilityLabel("Show lyrics half a second later")
                .accessibilityIdentifier("lyrics.offset.later")

                if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }

                Button { setOffset(0) } label: {
                    Text("Reset")
                        .appFont(.footnote, weight: .semibold)
                        .padding(.horizontal, 10)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Capsule())
                }
                .disabled(offset == 0)
                .opacity(offset == 0 ? 0.4 : 1)
                .accessibilityLabel("Reset lyric timing")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryText)
        .tint(AppTheme.accent)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .appGlass(in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .contain)
    }

    private var timingLabel: some View {
        Text("Lyric timing · \(offsetLabel)")
            .monospacedDigit()
            .appFont(.footnote, weight: .medium)
            .foregroundStyle(AppTheme.secondaryText)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
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
        LyricsAttributionView(document: document)
        .appFont(.caption)
        .foregroundStyle(AppTheme.secondaryText)
        .tint(AppTheme.accent)
    }
}
