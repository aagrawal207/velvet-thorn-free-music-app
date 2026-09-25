import Combine
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if DEBUG
    @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var keyboardHiding = KeyboardChromeHiding.nothing

    var body: some View {
        @Bindable var model = model
        let preferredColor = model.library.preferences.accent.color

        ZStack {
            navigation
                .accessibilityHidden(hidesNavigation)

            if !model.library.preferences.hasCompletedWelcome {
                WelcomeView()
                    .transition(.opacity)
                    .zIndex(1)
            }
            #if DEBUG
            if model.isWidgetPreviewPresented { DebugWidgetPreviewView().zIndex(2) }
            #endif
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
            .appSheetChrome()
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            guard KeyboardNotice.isLocal(notification.userInfo) else { return }
            keyboardHiding = KeyboardChromeHiding(keyboardHeight: KeyboardNotice.endFrameHeight(notification.userInfo),
                                                  isRegularWidth: AppLayout.isRegularWidth(horizontalSizeClass),
                                                  isMacDesignedForIPad: AppPlatform.isMacDesignedForIPad)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            guard KeyboardNotice.isLocal(notification.userInfo) else { return }
            keyboardHiding = .nothing
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
        .overlay(alignment: .bottomLeading) {
            if DebugWidgetSupport.sharesWithExtension {
                VStack(spacing: 0) {
                    Text("Widget fixture availability")
                        .accessibilityIdentifier("widgetFixture.availability")
                        .accessibilityValue(DebugWidgetSupport.sharedSnapshot.availability.rawValue)
                    Text("Widget fixture artwork")
                        .accessibilityIdentifier("widgetFixture.artwork")
                        .accessibilityValue(String(DebugWidgetSupport.sharedSnapshot.artwork.count))
                }
                .font(.system(size: 1))
                .allowsHitTesting(false)
            }
            if DebugCachedAudioFixture.isActive {
                VStack(spacing: 0) {
                    Text("Fixture network requests")
                        .accessibilityIdentifier("cacheFixture.networkRequests")
                        .accessibilityValue(String(DebugCachedAudioFixture.networkRequestCount))
                    Text("Fixture playback source")
                        .accessibilityIdentifier("cacheFixture.playbackSource")
                        .accessibilityValue(model.player.currentStreamURL?.isFileURL == true ? "local" : "none")
                    if let error = DebugCachedAudioFixture.setupError {
                        Text(error).accessibilityIdentifier("cacheFixture.setupError")
                    }
                }
                .font(.system(size: 1))
                .allowsHitTesting(false)
            }
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
                .modifier(MiniPlayerNavigationLayout(hidesPlayerForKeyboard: keyboardHiding.hidesMiniPlayer))
            }
            .accessibilityIdentifier("tab.home")

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack(path: model.navigationPath(for: .search)) {
                    SearchView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(hidesPlayerForKeyboard: keyboardHiding.hidesMiniPlayer))
            }
            .accessibilityIdentifier("tab.search")

            Tab("Library", systemImage: "square.stack", value: AppTab.library) {
                NavigationStack(path: model.navigationPath(for: .library)) {
                    LibraryView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                        .navigationDestination(item: widgetLibraryDestination) { kind in
                            LibrarySavedSongsView(kind: kind).id(model.libraryRootGeneration)
                        }
                }
                .modifier(MiniPlayerNavigationLayout(hidesPlayerForKeyboard: keyboardHiding.hidesMiniPlayer))
            }
            .accessibilityIdentifier("tab.library")

            Tab("Recap", systemImage: "chart.bar", value: AppTab.recap) {
                NavigationStack(path: model.navigationPath(for: .recap)) {
                    RecapView().navigationDestination(for: MusicCollection.self) { CollectionDetailView(collection: $0) }
                }
                .modifier(MiniPlayerNavigationLayout(hidesPlayerForKeyboard: keyboardHiding.hidesMiniPlayer))
            }
            .accessibilityIdentifier("tab.recap")
        }
        .toolbar(keyboardHiding.hidesTabBar ? .hidden : .automatic, for: .tabBar)
    }

    private var preferredColorScheme: ColorScheme? {
        switch model.library.preferences.appearance {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    private var hidesNavigation: Bool {
        #if DEBUG
        !model.library.preferences.hasCompletedWelcome || model.isWidgetPreviewPresented
        #else
        !model.library.preferences.hasCompletedWelcome
        #endif
    }

    private var widgetLibraryDestination: Binding<LibrarySavedSongsView.Kind?> {
        AppNavigationIntent.binding(Binding(get: { model.widgetLibraryDestination }, set: { model.widgetLibraryDestination = $0 }),
                                    in: model, isCurrent: { model.selectedTab == .library })
    }
}

@MainActor
private struct MiniPlayerNavigationLayout: ViewModifier {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let hidesPlayerForKeyboard: Bool
    @State private var showsCachedSongs = false

    func body(content: Content) -> some View {
        // Reserve the player's intrinsic height in the stack's viewport, including direct NavigationLink destinations.
        VStack(spacing: 0) {
            if model.isOffline { offlineBar }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            player
        }
        .sheet(isPresented: AppNavigationIntent.binding($showsCachedSongs, in: model)) {
            NavigationStack {
                CachedSongsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            AppSheetDoneButton(id: "cachedSongs.done") { showsCachedSongs = false }
                        }
                    }
            }
            .appSheetChrome()
        }
    }

    private var offlineBar: some View {
        Button {
            AppNavigationIntent.perform(in: model) { showsCachedSongs = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                Text("You’re offline").appFont(.subheadline, weight: .semibold)
                Spacer(minLength: 8)
                Text("Cached songs").appFont(.subheadline)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .foregroundStyle(AppTheme.primaryText)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
            .frame(maxWidth: .infinity)
            .background(AppTheme.raised)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You’re offline. Open cached songs")
        .accessibilityIdentifier("offline.cachedSongs")
    }

    @ViewBuilder
    private var player: some View {
        if let track = model.player.currentTrack, !hidesPlayerForKeyboard {
            MiniPlayer(track: track)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: AppLayout.floatingMaxWidth(for: horizontalSizeClass))
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }
}

@MainActor
private struct MiniPlayer: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
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
                                .foregroundStyle(AppTheme.primaryText)
                                .lineLimit(1)
                        } else {
                            Text(track.artistName)
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.primaryText.opacity(0.75))
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
        .background {
            GeometryReader { geometry in
                let width = geometry.size.width * progress
                Rectangle()
                    .fill(AppTheme.accent.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: width, height: geometry.size.height)
                    // Playback's time axis stays physically left-to-right in every layout direction.
                    .position(x: width / 2, y: geometry.size.height / 2)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transaction { transaction in
                // Seeks and track resets must not inherit navigation animations, including with Reduce Motion.
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .appGlass(in: Capsule(), interactive: true)
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
        guard let duration = PlaybackTiming.validDuration(model.player.duration)
            ?? PlaybackTiming.validDuration(track.duration) else { return 0 }
        return PlaybackTiming.position(model.player.position, duration: duration) / duration
    }
}

@MainActor
private struct WelcomeView: View {
    @Environment(MusicAppModel.self) private var model

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
                        Text("Play music you love. Breezy learns your listening languages along the way.")
                            .appFont(.body)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        if let error = model.library.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .appFont(.footnote)
                                .foregroundStyle(AppTheme.accent)
                            if model.library.requiresReload {
                                LibraryReloadButton(identifier: "welcome.libraryReload")
                            }
                        }

                        Button {
                            model.updatePreferences { $0.hasCompletedWelcome = true }
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
                        .accessibilityLabel("Start listening")
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
        .accessibilityIdentifier("welcome.screen")
    }
}

@MainActor
struct RootMessageBanner: View {
    @Environment(MusicAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
            .frame(maxWidth: AppLayout.floatingMaxWidth(for: horizontalSizeClass))
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
