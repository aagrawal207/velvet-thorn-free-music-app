import UIKit
import XCTest
@testable import GanaBajana

/// Pure helpers behind the Settings visual system and the iCloud status slot.
@MainActor
final class SettingsRowLayoutTests: XCTestCase {
    /// Every wording `ICloudLibrarySync` can publish. Mirrored here so the two-line reservation is checked against real copy.
    private static let statusTexts = [
        "iCloud sync is off", "Waiting to sync with iCloud", "iCloud sync is off. Your library is on this device.",
        "Checking iCloud Drive…", "Reading your iCloud library…", "Waiting for iCloud to download your library…",
        "Saving your library to iCloud Drive…", "Handed to iCloud. Other devices may update later.",
        "Sign in to iCloud and turn on iCloud Drive to sync.", "iCloud storage is full", "Waiting for iCloud Drive",
        "iCloud sync needs attention", "Your Apple Account changed. Turn sync on to use this account.",
        "Checking your Apple Account…", "iCloud sync timed out", "Sync settings need attention", "Sync is paused",
    ]

    func testRowMetricsKeepTheDocumentedShape() {
        XCTAssertEqual(SettingsRowMetrics.iconSize, 28)
        XCTAssertEqual(SettingsRowMetrics.textInset, 40)
        XCTAssertEqual(SettingsRowMetrics.minHeight, 44)
        XCTAssertEqual(SettingsRowMetrics.insets.leading, 20)
        XCTAssertEqual(SettingsRowMetrics.insets.trailing, 20)
        XCTAssertEqual(SettingsRowMetrics.sectionSpacing, 24)
        XCTAssertEqual(SettingsRowMetrics.footerTopSpacing, 10)
    }

    func testStatusGlyphFollowsTheSyncState() {
        XCTAssertEqual(SettingsCloudSyncStatus(isEnabled: false, isSyncing: false, hasError: false, text: "off").symbolName, "icloud.slash")
        XCTAssertEqual(SettingsCloudSyncStatus(isEnabled: true, isSyncing: true, hasError: false, text: "reading").symbolName,
                       "arrow.triangle.2.circlepath.icloud")
        XCTAssertEqual(SettingsCloudSyncStatus(isEnabled: true, isSyncing: false, hasError: true, text: "full").symbolName,
                       "exclamationmark.icloud")
        XCTAssertEqual(SettingsCloudSyncStatus(isEnabled: true, isSyncing: false, hasError: false, text: "waiting").symbolName, "icloud")
        // Off wins over a stale error so the glyph never claims attention for a paused sync.
        XCTAssertEqual(SettingsCloudSyncStatus(isEnabled: false, isSyncing: false, hasError: true, text: "paused").symbolName, "icloud.slash")
    }

    func testStatusProjectionReadsTheSyncObject() throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let device = harness.device(debounce: .seconds(1000))
        let status = SettingsCloudSyncStatus(device.sync)
        XCTAssertEqual(status, SettingsCloudSyncStatus(isEnabled: true, isSyncing: false, hasError: false,
                                                       text: "Waiting to sync with iCloud"))
        device.sync.setEnabled(false)
        XCTAssertFalse(SettingsCloudSyncStatus(device.sync).isEnabled)
        XCTAssertNotEqual(SettingsCloudSyncStatus(device.sync), status)
    }

    func testSlotReservesTwoLinesOnlyBelowAccessibilitySizes() {
        XCTAssertEqual(SettingsCloudSyncStatus.reservedLineCount(for: .large), 2)
        XCTAssertEqual(SettingsCloudSyncStatus.reservedLineCount(for: .xxxLarge), 2)
        XCTAssertNil(SettingsCloudSyncStatus.reservedLineCount(for: .accessibility1))
        XCTAssertNil(SettingsCloudSyncStatus.reservedLineCount(for: .accessibility5))
        XCTAssertEqual(SettingsCloudSyncStatus.holdDuration, .milliseconds(700))
    }

    /// The reserved slot must hold every status without truncation at the largest non-accessibility size on the
    /// narrowest supported phone (iPhone SE: 375 points wide, 343-point card, 20-point insets, 22-point glyph column).
    func testEveryStatusFitsTheReservedLinesOnTheSmallestPhone() {
        let slotWidth: CGFloat = 375 - 2 * 16 - 2 * 20 - 22
        let font = UIFont.systemFont(ofSize: UIFontMetrics(forTextStyle: .footnote)
            .scaledValue(for: AppTypography.size(for: .footnote),
                         compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)))
        let lineHeight = font.lineHeight
        for text in Self.statusTexts {
            let bounds = (text as NSString).boundingRect(with: CGSize(width: slotWidth, height: .greatestFiniteMagnitude),
                                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                         attributes: [.font: font], context: nil)
            let lines = Int((bounds.height / lineHeight).rounded(.up))
            XCTAssertLessThanOrEqual(lines, SettingsCloudSyncStatus.reservedLines, "\(text) needs \(lines) lines at \(slotWidth) points")
        }
    }

    /// One sync operation publishes several status texts within milliseconds. Shown directly under the iCloud
    /// row, each change re-laid out the row; a 700 ms hold hides every state that does not last.
    func testOneSyncOperationPassesThroughShortLivedStatusTexts() async throws {
        let harness = LibrarySyncTestHarness()
        defer { harness.remove() }
        let device = harness.device(debounce: .milliseconds(10))
        device.library.toggleFavorite(libraryTestTrack())
        device.sync.start()
        let recorder = StatusRecorder(sync: device.sync)
        recorder.observe()
        await device.sync.syncNow()
        recorder.stop()
        let texts = recorder.entries.map(\.text)
        // Observation re-arms on the main actor, so states set within one turn can collapse into the next entry.
        XCTAssertGreaterThanOrEqual(texts.count, 2, "\(texts)")
        XCTAssertEqual(texts.first, "Checking iCloud Drive…")
        XCTAssertEqual(texts.last, "Handed to iCloud. Other devices may update later.")
        XCTAssertEqual(device.sync.statusText, texts.last)
        let holds = zip(recorder.entries, recorder.entries.dropFirst()).map { $1.at - $0.at }
        for hold in holds {
            XCTAssertLessThan(hold, 0.7, "Intermediate states last well under the 700 ms hold: \(holds)")
        }
        recorder.entries.forEach { print("status-transition", String(format: "%.1f ms", $0.at * 1000), $0.text) }
    }
}

/// Records every `statusText` change with a timestamp through observation tracking.
@MainActor
private final class StatusRecorder {
    struct Entry { let text: String; let at: TimeInterval }
    private let sync: ICloudLibrarySync
    private let start = Date()
    private var active = true
    private(set) var entries: [Entry] = []

    init(sync: ICloudLibrarySync) { self.sync = sync }

    func observe() {
        guard active else { return }
        withObservationTracking {
            _ = sync.statusText
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                entries.append(Entry(text: sync.statusText, at: Date().timeIntervalSince(start)))
                observe()
            }
        }
    }

    func stop() { active = false }
}
