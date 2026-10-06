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
                .navigationTitle("Velvet Thorn")
                .navigationDestination(for: String.self) { location in
                    WatchBrowseView(location: location) { path.removeAll() }
                }
        }
        .environment(model)
        .environment(\.watchAccent, WatchTheme.color(for: model.accent))
        .tint(WatchTheme.color(for: model.accent))
        .transaction { if reduceMotion { $0.animation = nil } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setForeground(phase == .active)
        }
    }
}

enum WatchTheme {
    static let petal = Color(red: 1, green: 0.62, blue: 0.56)
    static let surface = Color(red: 0.11, green: 0.12, blue: 0.14)

    /// The phone palette's dark-appearance values; the watch is always dark and draws black glyphs on these fills.
    static func hex(for accent: CompanionAccent) -> UInt32 {
        switch accent {
        case .coral: 0xFF5A7A
        case .mint: 0x4DE0B0
        case .ocean: 0x64B5FF
        case .violet: 0xB79AFF
        case .amber: 0xFFC15A
        case .rose: 0xFF83BB
        case .teal: 0x53D7E0
        }
    }

    static func color(for accent: CompanionAccent) -> Color {
        let value = hex(for: accent)
        return Color(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

extension EnvironmentValues {
    @Entry var watchAccent: Color = WatchTheme.color(for: .fallback)
}

struct WatchRecordMark: View {
    @Environment(\.watchAccent) private var accent
    var size: CGFloat = 60

    var body: some View {
        ZStack {
            Circle().fill(WatchTheme.surface)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(size / 12)
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1).padding(size / 6)
            Circle().fill(accent).padding(size * 0.26)
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
