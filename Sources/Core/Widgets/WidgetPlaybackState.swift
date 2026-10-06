import Foundation

/// The last playback selection, as Lock Screen widgets and Controls show it. It never carries ids, URLs or positions.
struct WidgetPlaybackState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumTextBytes = 192
    static let fileName = "widget-playback.json"
    static let maximumFileBytes = 4 * 1024

    static let nowPlayingWidgetKind = "Breezy.NowPlaying"
    static let launcherWidgetKind = "Breezy.Launcher"
    static let playPauseControlKind = "com.agraabhi.ganabajana.control.playPause"
    static let openControlKind = "com.agraabhi.ganabajana.control.open"

    static let empty = WidgetPlaybackState(hasSelection: false, isPlaying: false)

    var version: Int = Self.currentVersion
    var hasSelection: Bool
    var isPlaying: Bool
    var isLiveRadio: Bool = false
    /// Nil while listening history is off, so the widget shows a generic Resume.
    var title: String?
    var subtitle: String?
    var accent: AppAccent = .coral

    func validated() -> Self? {
        guard version == Self.currentVersion, hasSelection || (!isPlaying && title == nil && subtitle == nil) else { return nil }
        for text in [title, subtitle] {
            if let text, text.isEmpty || text.utf8.count > Self.maximumTextBytes { return nil }
        }
        return self
    }

    static func bounded(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf8.count > maximumTextBytes else { return text }
        var result = ""
        for character in text {
            guard (result + String(character)).utf8.count <= maximumTextBytes - 3 else { break }
            result.append(character)
        }
        return result + "..."
    }
}

struct WidgetPlaybackStateStore: Sendable {
    let directory: URL?
    var fileURL: URL? { directory?.appendingPathComponent(WidgetPlaybackState.fileName) }

    init(directory: URL? = WidgetSnapshotStore.sharedDirectory()) {
        self.directory = directory
    }

    func read() -> WidgetPlaybackState {
        guard let fileURL, let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              data.count <= WidgetPlaybackState.maximumFileBytes,
              let state = try? JSONDecoder().decode(WidgetPlaybackState.self, from: data).validated() else { return .empty }
        return state
    }

    /// Returns false when the file already holds the same state, so callers can skip a reload.
    @discardableResult
    func write(_ state: WidgetPlaybackState) throws -> Bool {
        guard let directory, let fileURL, let valid = state.validated() else { throw WidgetSnapshotError.invalidSnapshot }
        if read() == valid, FileManager.default.fileExists(atPath: fileURL.path) { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(valid)
        guard data.count <= WidgetPlaybackState.maximumFileBytes else { throw WidgetSnapshotError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return true
    }
}
