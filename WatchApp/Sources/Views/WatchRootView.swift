import SwiftUI

@MainActor
struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: WatchCompanionModel
    @State private var path: [String] = []

    init(model: WatchCompanionModel? = nil) {
        _model = State(initialValue: model ?? WatchAppSession.shared.model)
    }

    var body: some View {
        NavigationStack(path: $path) {
            WatchNowPlayingView()
                .navigationTitle("Breezy")
                .navigationDestination(for: String.self) { location in
                    WatchBrowseView(location: location) { path.removeAll() }
                }
        }
        .environment(model)
        .tint(WatchTheme.accent)
        .transaction { if reduceMotion { $0.animation = nil } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setForeground(phase == .active)
        }
    }
}

enum WatchTheme {
    static let accent = Color(red: 0.66, green: 0.93, blue: 0.84)
    static let petal = Color(red: 1, green: 0.62, blue: 0.56)
    static let surface = Color(red: 0.11, green: 0.12, blue: 0.14)
}

struct WatchRecordMark: View {
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            Circle().fill(WatchTheme.surface)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(size / 12)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).padding(size / 6)
            Circle().fill(WatchTheme.accent).padding(size * 0.26)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.27, weight: .semibold))
                .foregroundStyle(.black)
            Circle().fill(WatchTheme.petal).frame(width: size / 12, height: size / 12)
                .offset(x: size * 0.3, y: -size * 0.32)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
struct WatchConnectionView: View {
    @Environment(WatchCompanionModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.connectionTitle, systemImage: model.connection.canMessage ? "iphone" : "iphone.slash")
                .font(.footnote.weight(.semibold))
            Text(model.connectionDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            WatchRefreshButton()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch.connection")
    }
}

@MainActor
struct WatchRefreshButton: View {
    @Environment(WatchCompanionModel.self) private var model

    var body: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label(model.isRefreshing ? "Updating…" : "Refresh", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("watch.refresh")
    }
}

@MainActor
struct WatchNoticeView: View {
    @Environment(WatchCompanionModel.self) private var model
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsReconciliation {
                WatchRefreshButton()
            } else {
                Button { model.dismissNotice() } label: {
                    Text("Dismiss").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }
            }
        }
        .padding(8)
        .background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("watch.notice")
    }
}

struct WatchLibraryFailureView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Library needs attention", systemImage: "exclamationmark.triangle")
                .font(.footnote.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(WatchTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.library.error")
    }
}
