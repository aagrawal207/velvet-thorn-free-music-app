import Foundation
import Observation
import OSLog

/// A named curve saved from the equalizer; choosing it copies its gains and preamp into the Custom curve.
struct SavedEqualizerPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var gains: [Double]
    var preamp: Double

    var id: String { name }

    init(name: String, gains: [Double], preamp: Double) {
        self.name = name
        self.gains = EqualizerSettings.normalizedGains(gains)
        self.preamp = EqualizerSettings.clampedGain(preamp)
    }

    func matches(_ settings: EqualizerSettings) -> Bool {
        settings.preset == .custom && settings.gains == gains && settings.preamp == preamp
    }
}

/// Per-song equalizer overrides and saved presets, device-local at
/// `Application Support/GanaBajana/equalizer-profiles.json`. Never synced: overrides follow this device's speakers.
@Observable
@MainActor
final class EqualizerProfileStore {
    static let songCapacity = 1_000
    static let presetCapacity = 20
    static let nameLimit = 40
    static let maximumFileBytes = 2 << 20
    static let fileName = "equalizer-profiles.json"

    struct SongOverride: Codable, Equatable, Sendable {
        var id: String
        var settings: EqualizerSettings
        var usedAt: Date
    }

    enum SaveResult: Equatable { case saved, replaced, full, invalidName }

    private struct Document: Codable {
        var version = 1
        var songs: [SongOverride] = []
        var presets: [SavedEqualizerPreset] = []
    }

    private(set) var presets: [SavedEqualizerPreset] = []
    private var songs: [String: SongOverride] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Equalizer")

    /// Nil keeps the store memory-only (fixtures and unit hosts).
    init(url: URL?, now: @escaping () -> Date = { Date() }) {
        self.url = url
        self.now = now
        load()
    }

    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GanaBajana", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    var songOverrideCount: Int { songs.count }

    func override(for id: String) -> EqualizerSettings? { songs[id]?.settings }

    func hasOverride(for id: String) -> Bool { songs[id] != nil }

    /// Saves or replaces a song's settings; beyond 1,000 songs the least recently used override is dropped.
    func setOverride(_ settings: EqualizerSettings, for id: String) {
        guard !id.isEmpty else { return }
        songs[id] = SongOverride(id: id, settings: settings, usedAt: now())
        if songs.count > Self.songCapacity {
            let excess = songs.values.sorted { ($0.usedAt, $0.id) < ($1.usedAt, $1.id) }.prefix(songs.count - Self.songCapacity)
            for entry in excess { songs[entry.id] = nil }
        }
        writeNow()
    }

    func removeOverride(for id: String) {
        guard songs.removeValue(forKey: id) != nil else { return }
        writeNow()
    }

    /// Refreshes a song's place in the LRU order when it plays; the write is coalesced.
    func markUsed(_ id: String) {
        guard var entry = songs[id] else { return }
        entry.usedAt = now()
        songs[id] = entry
        scheduleWrite()
    }

    /// Up to 20 names, trimmed to 40 characters; an existing name is replaced in place.
    @discardableResult
    func savePreset(named rawName: String, from settings: EqualizerSettings) -> SaveResult {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        guard !name.isEmpty, EqualizerPreset.allCases.allSatisfy({ $0.title.caseInsensitiveCompare(name) != .orderedSame }) else {
            return .invalidName
        }
        let preset = SavedEqualizerPreset(name: name, gains: settings.effectiveGains, preamp: settings.preamp)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index] = preset
            writeNow()
            return .replaced
        }
        guard presets.count < Self.presetCapacity else { return .full }
        presets.append(preset)
        writeNow()
        return .saved
    }

    func deletePreset(named name: String) {
        let count = presets.count
        presets.removeAll { $0.name == name }
        if presets.count != count { writeNow() }
    }

    func preset(named name: String) -> SavedEqualizerPreset? { presets.first { $0.name == name } }

    func presetName(matching settings: EqualizerSettings) -> String? {
        presets.first { $0.matches(settings) }?.name
    }

    /// Writes any coalesced change immediately.
    func flush() {
        guard pendingWrite != nil else { return }
        writeNow()
    }

    // MARK: Persistence

    private func load() {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard let size = attributes[.size] as? Int, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: url) else {
            log.error("event=equalizer_profiles_load result=too_large")
            return
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else {
            log.error("event=equalizer_profiles_load result=unreadable")
            return
        }
        var loaded: [String: SongOverride] = [:]
        for song in document.songs.sorted(by: { $0.usedAt > $1.usedAt }).prefix(Self.songCapacity) where !song.id.isEmpty {
            loaded[song.id] = song
        }
        songs = loaded
        var names = Set<String>()
        presets = document.presets.filter { !$0.name.isEmpty && names.insert($0.name.lowercased()).inserted }
            .prefix(Self.presetCapacity).map { SavedEqualizerPreset(name: String($0.name.prefix(Self.nameLimit)), gains: $0.gains, preamp: $0.preamp) }
        log.info("event=equalizer_profiles_load result=ok songs=\(loaded.count) presets=\(self.presets.count)")
    }

    private func scheduleWrite() {
        guard url != nil, pendingWrite == nil else { return }
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    private func writeNow() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let url else { return }
        let document = Document(songs: songs.values.sorted { $0.id < $1.id }, presets: presets)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(document)
            try data.write(to: url, options: [.atomic])
        } catch {
            log.error("event=equalizer_profiles_write result=failed")
        }
    }
}
