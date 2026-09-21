import Combine
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var isKeyboardVisible = false

    var body: some View {
        @Bindable var model = model
        let preferredColor = model.library.preferences.accent.color

        ZStack {
            navigation
                .accessibilityHidden(!model.library.preferences.hasCompletedWelcome)

            if !model.library.preferences.hasCompletedWelcome {
                WelcomeView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .appFont(.body)
        .preferredColorScheme(preferredColorScheme)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                   value: model.library.preferences.hasCompletedWelcome)
        .overlay(alignment: .top) { RootMessageBanner() }
        .fullScreenCover(isPresented: $model.isPlayerPresented) {
            NowPlayingView()
                .preferredColorScheme(preferredColorScheme)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            NavigationStack {
                SettingsView()
            }
            .preferredColorScheme(preferredColorScheme)
            .presentationDragIndicator(.visible)
        }
        .accentColor(preferredColor)
        .tint(preferredColor)
        .task(id: model.toast) {
            guard let message = model.toast else { return }
            guard !model.library.requiresReload || message != model.library.errorMessage else { return }
            do {
                try await Task.sleep(for: .seconds(4))
                try Task.checkCancellation()
                if model.toast == message { model.toast = nil }
            } catch { }
        }
        .onChange(of: model.library.errorMessage, initial: true) { _, message in
            if let message, model.toast != message { model.showToast(message) }
        }
        .onChange(of: PlaybackFailureFeedback.message(for: model.player)) { previous, message in
            if let message, !model.isPlayerPresented {
                model.showToast(message)
            } else if let previous, model.toast == previous {
                model.toast = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        #if DEBUG
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { DebugBootstrap.beginLayoutDiagnostics() }
            if phase == .background { DebugBootstrap.endLayoutDiagnostics() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            DebugBootstrap.logLayout("orientation")
        }
        .onChange(of: model.isPlayerPresented) { _, presented in
            DebugBootstrap.logLayout("player=\(presented)")
        }
        #endif
    }

    @ViewBuilder
    private var navigation: some View {
        if #available(iOS 26.0, *) {
            nativeTabs.tabBarMinimizeBehavior(.never)
        } else {
            nativeTabs
        }
    }

    private var nativeTabs: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectTab($0) })) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack(path: model.navigationPath(for: .home)) {
                    HomeView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(isKeyboardVisible: isKeyboardVisible))
            }
            .accessibilityIdentifier("tab.home")

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: model.navigationPath(for: .search)) {
                    SearchView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(isKeyboardVisible: isKeyboardVisible))
            }
            .accessibilityIdentifier("tab.search")

            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                NavigationStack(path: model.navigationPath(for: .library)) {
                    LibraryView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(isKeyboardVisible: isKeyboardVisible))
            }
            .accessibilityIdentifier("tab.library")

            Tab("Recap", systemImage: "chart.bar", value: AppTab.recap) {
                NavigationStack(path: model.navigationPath(for: .recap)) {
                    RecapView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(isKeyboardVisible: isKeyboardVisible))
            }
            .accessibilityIdentifier("tab.recap")
        }
        .toolbar(isKeyboardVisible ? .hidden : .automatic, for: .tabBar)
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.library.preferences.appearance {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

@MainActor
private struct MiniPlayerNavigationLayout: ViewModifier {
    @Environment(MusicAppModel.self) private var model
    let isKeyboardVisible: Bool

    func body(content: Content) -> some View {
        // Reserve the player's intrinsic height in the stack's viewport, including direct NavigationLink destinations.
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            player
        }
    }

    @ViewBuilder
    private var player: some View {
        if let track = model.player.currentTrack, !isKeyboardVisible {
            MiniPlayer(track: track)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }
}

@MainActor
private struct MiniPlayer: View {
    @Environment(MusicAppModel.self) private var model
    let track: Track

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.isPlayerPresented = true
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(url: track.artworkURL, title: track.title, size: 44, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .appFont(.subheadline, weight: .semibold)
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                        if model.player.errorMessage != nil {
                            Label("Couldn’t play", systemImage: "exclamationmark.circle")
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.accent)
                                .lineLimit(1)
                        } else {
                            Text(track.artistName)
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open player, \(track.title), \(track.artistName)")
            .accessibilityValue(playbackStatus)
            .accessibilityIdentifier("miniPlayer.open")
            .layoutPriority(1)

            Button {
                if model.player.errorMessage != nil { model.player.retry() }
                else { model.player.togglePlayback() }
            } label: {
                ZStack {
                    Image(systemName: model.player.errorMessage != nil ? "arrow.clockwise" : playbackActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .opacity(model.player.isLoading ? 0 : 1)
                    ProgressView()
                        .tint(AppTheme.primaryText)
                        .opacity(model.player.isLoading ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(model.player.errorMessage != nil ? "Retry playback" : playbackActive ? "Pause" : "Play")
            .accessibilityValue(model.player.errorMessage ?? (model.player.isLoading ? "Loading" : ""))
            .accessibilityIdentifier("miniPlayer.playPause")

            Button {
                model.player.next()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next song")
            .accessibilityIdentifier("miniPlayer.next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 64)
        .appGlass(in: Capsule(), interactive: true)
        .overlay {
            GeometryReader { geometry in
                // Reserve the rounded ends even when larger text makes the capsule taller.
                let width = max(0, geometry.size.width - geometry.size.height)
                Capsule()
                    .fill(AppTheme.raised)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: width * progress)
                    }
                    .frame(width: width, height: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        // The group's focus bounds include the glass padding, while each button retains its own target.
        .contentShape(.accessibility, Capsule())
        .accessibilityIdentifier("miniPlayer.container")
    }

    private var playbackActive: Bool { model.player.isPlaying || model.player.isLoading }

    private var playbackStatus: String {
        if let error = model.player.errorMessage { return "Playback failed. \(error)" }
        let state = model.player.isLoading ? "Loading" : model.player.isPlaying ? "Playing" : "Paused"
        return "\(state), \(TimeText.duration(model.player.position)) elapsed"
    }

    private var progress: Double {
        let duration = model.player.duration > 0 ? model.player.duration : (track.duration ?? 0)
        guard duration.isFinite, duration > 0, model.player.position.isFinite else { return 0 }
        return min(max(model.player.position / duration, 0), 1)
    }
}

@MainActor
private struct WelcomeView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var languages: Set<MusicLanguage> = [.hindi, .english]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 9) {
                        Image(AppIcons.primary.previewImageName).resizable().frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text("Breezy")
                            .foregroundStyle(AppTheme.primaryText)
                    }
                    .appFont(.title2, weight: .bold, design: .rounded)
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Sing along.\nPlay it loud.")
                            .appFont(.largeTitle, weight: .bold, design: .rounded)
                            .foregroundStyle(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Pick the languages you want on Home. Search covers everything.")
                            .appFont(.body)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    VStack(spacing: 12) {
                        ForEach(MusicLanguage.allCases) { language in
                            languageChoice(language)
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Keep at least one selected. You can change this later in Settings.")
                            .appFont(.footnote)
                            .foregroundStyle(AppTheme.secondaryText)

                        if let error = model.library.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .appFont(.footnote)
                                .foregroundStyle(AppTheme.accent)
                            if model.library.requiresReload {
                                LibraryReloadButton(identifier: "welcome.libraryReload")
                            }
                        }

                        Button {
                            var preferences = model.library.preferences
                            preferences.languages = languages
                            preferences.hasCompletedWelcome = true
                            model.library.preferences = preferences
                        } label: {
                            HStack {
                                Text("Start listening")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .appFont(.headline, weight: .semibold)
                            .foregroundStyle(AppTheme.onAccent)
                            .padding(.horizontal, 22)
                            .frame(minHeight: 56)
                            .background(AppTheme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("welcome.continue")
                    }
                    .padding(.bottom, 28)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 560)
                .frame(minHeight: geometry.size.height.isFinite ? max(0, geometry.size.height) : 0, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .background {
            AppTheme.background.ignoresSafeArea()
                .overlay(alignment: .topTrailing) {
                    RadialGradient(colors: [AppTheme.accent.opacity(0.12), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 460)
                        .ignoresSafeArea()
                }
        }
        .onAppear {
            let saved = model.library.preferences.languages
            languages = saved.isEmpty ? [.hindi, .english] : saved
        }
    }

    private func languageChoice(_ language: MusicLanguage) -> some View {
        let selected = languages.contains(language)
        let color = language == .hindi ? AppTheme.gold : AppTheme.violet

        return Button {
            if selected {
                if languages.count > 1 { languages.remove(language) }
            } else {
                languages.insert(language)
            }
        } label: {
            HStack(spacing: 18) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(language == .hindi ? "अ" : "Aa")
                        .appFont(.title, weight: .semibold)
                        .foregroundStyle(color)
                        .frame(width: 48)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.title)
                        .appFont(.headline, weight: .semibold)
                        .foregroundStyle(AppTheme.primaryText)
                    Text(language.subtitle)
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? color : AppTheme.secondaryText)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? color.opacity(0.10) : AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? color.opacity(0.65) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("welcome.\(language.rawValue)")
    }
}

@MainActor
struct RootMessageBanner: View {
    @Environment(MusicAppModel.self) private var model

    var body: some View {
        if let message = model.toast {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(message)
                        .appFont(.subheadline)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("message.text")
                    if message == PlaybackFailureFeedback.message(for: model.player) {
                        Button { model.player.retry() } label: {
                            Text("Retry")
                                .appFont(.subheadline, weight: .semibold)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape([.interaction, .accessibility], Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Retry playback")
                        .accessibilityIdentifier("message.playbackRetry")
                    }
                    Button {
                        model.toast = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            // Plain image buttons otherwise expose only the glyph and can hit controls beneath the banner.
                            .contentShape([.interaction, .accessibility], Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                    .accessibilityIdentifier("message.dismiss")
                }
                if model.library.requiresReload, message == model.library.errorMessage {
                    LibraryReloadButton(identifier: "message.libraryReload")
                        .padding(.trailing, 16)
                }
            }
            .foregroundStyle(AppTheme.primaryText)
            .padding(.leading, 16)
            .appGlass(in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }
}

@MainActor
struct LibraryReloadButton: View {
    @Environment(MusicAppModel.self) private var model
    let identifier: String

    var body: some View {
        Button { model.reloadSavedLibrary() } label: {
            Label("Reload saved library", systemImage: "arrow.clockwise")
                .appFont(.subheadline, weight: .semibold)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Loads saved changes and keeps your current playback")
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private enum PlaybackFailureFeedback {
    static func message(for player: PlayerController) -> String? {
        guard let track = player.currentTrack, let error = player.errorMessage else { return nil }
        return "Couldn’t play \(track.title). \(error)"
    }
}
