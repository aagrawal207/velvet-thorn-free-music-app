import XCTest
@testable import GanaBajana

@MainActor
final class RadioHistoryStoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RadioHistoryStoreTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("radio-history.json")
    }

    private func song(_ number: Int, title: String = "Song") -> RadioSeed {
        .song(Track(id: "saavn:\(number)", title: title, artists: ["Artist"],
                    artworkURL: URL(string: "https://images.example.com/cover.jpg")))
    }

    func testRoundTripKeepsTwentyLatestSeedsAndUpdatesMetadataTuningAndOrder() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = RadioHistoryStore(url: url, historyEpoch: epoch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for index in 0..<22 {
            store.record(seed: song(index), tuning: RadioTuning(), historyEpoch: epoch, enabled: true,
                         now: date.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.entries.map(\.id), (2..<22).reversed().map { song($0).id })

        let updated = song(5, title: "Updated Song")
        let tuning = RadioTuning(familiarity: .newMusic)
        store.record(seed: updated, tuning: tuning, historyEpoch: epoch, enabled: true, now: date.addingTimeInterval(30))
        XCTAssertEqual(store.entries.count, 20)
        XCTAssertEqual(store.entries.first, RadioHistoryEntry(seed: updated, tuning: tuning, startedAt: date.addingTimeInterval(30)))
        XCTAssertEqual(store.entries[1].id, song(21).id)

        let artist = RadioSeed.artist(ArtistCredit(name: "Artist", id: "saavn:artist:42"))
        store.record(seed: artist, tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date.addingTimeInterval(31))
        let restored = RadioHistoryStore(url: url, historyEpoch: epoch)
        XCTAssertNil(restored.errorMessage)
        XCTAssertEqual(restored.entries, store.entries)
        restored.remove(id: updated.id)
        XCTAssertEqual(restored.entries.count, 19)
        XCTAssertEqual(restored.entries.first?.seed, artist)
        XCTAssertFalse(restored.entries.contains { $0.id == updated.id })
        XCTAssertEqual(RadioHistoryStore(url: url, historyEpoch: epoch).entries, restored.entries)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(raw["version"] as? Int, 1)
        XCTAssertEqual(raw["historyEpoch"] as? String, epoch.uuidString)
    }

    func testInvalidDocumentsArePreservedAndRepairRequiresExplicitReload() throws {
        let url = try temporaryURL()
        let writer = RadioHistoryStore(url: url)
        writer.record(seed: song(1), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        let good = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        let rows = try XCTUnwrap(raw["entries"] as? [[String: Any]])
        var future = raw
        future["version"] = 2
        var duplicate = raw
        duplicate["entries"] = rows + rows
        var badDate = raw
        var invalidRow = rows[0]
        invalidRow["startedAt"] = -1
        badDate["entries"] = [invalidRow]
        var payload = raw
        var opaqueRow = rows[0]
        opaqueRow["providerRequest"] = ["url": "https://example.com/signed-media?token=secret"]
        payload["entries"] = [opaqueRow]
        let rejected = try [future, duplicate, badDate, payload].map { try JSONSerialization.data(withJSONObject: $0) }
            + [Data("broken JSON".utf8), Data(repeating: 32, count: RadioHistoryStore.maximumBytes + 1)]

        for data in rejected {
            try data.write(to: url, options: .atomic)
            let store = RadioHistoryStore(url: url)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertTrue(store.entries.isEmpty)
            store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
            store.remove(id: song(1).id)
            store.synchronize(historyEpoch: UUID(), enabled: false)
            XCTAssertEqual(try Data(contentsOf: url), data)

            try good.write(to: url, options: .atomic)
            store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), good)
            store.reload(historyEpoch: nil, enabled: true)
            XCTAssertNil(store.errorMessage)
            XCTAssertTrue(store.entries.isEmpty)
            store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
            XCTAssertEqual(store.entries.map(\.id), [song(2).id])
        }
    }

    func testForeignWriteBlocksPublicationAndMutationUntilReload() throws {
        let url = try temporaryURL()
        let first = RadioHistoryStore(url: url)
        first.record(seed: song(1), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        let other = RadioHistoryStore(url: url)
        other.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        let foreign = try Data(contentsOf: url)
        first.remove(id: song(1).id)
        XCTAssertNotNil(first.errorMessage)
        XCTAssertEqual(first.entries.map(\.id), [song(1).id])
        first.record(seed: song(3), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        first.reload(historyEpoch: nil, enabled: true)
        XCTAssertNil(first.errorMessage)
        XCTAssertEqual(first.entries, other.entries)
        first.remove(id: song(1).id)
        XCTAssertEqual(RadioHistoryStore(url: url).entries.map(\.id), [song(2).id])
    }

    func testDeferredLoadDoesNotTreatAnUnavailableLibraryEpochAsAHistoryReset() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let writer = RadioHistoryStore(url: url, historyEpoch: epoch)
        writer.record(seed: song(1), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)
        let saved = try Data(contentsOf: url)
        let waiting = RadioHistoryStore(url: url, deferLoading: true)
        XCTAssertTrue(waiting.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), saved)
        waiting.synchronize(historyEpoch: epoch, enabled: true)
        XCTAssertEqual(waiting.entries.map(\.id), [song(1).id])
        XCTAssertEqual(try Data(contentsOf: url), saved)
        waiting.synchronize(historyEpoch: UUID(), enabled: true)
        XCTAssertTrue(waiting.entries.isEmpty, "A genuine clear after recovery still erases radio history")
    }

    func testEpochMismatchOnRelaunchAndMissedCallbackClearOldHistory() throws {
        let url = try temporaryURL()
        let legacy = RadioHistoryStore(url: url)
        legacy.record(seed: song(1), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        let epoch = UUID()
        let relaunched = RadioHistoryStore(url: url, historyEpoch: epoch)
        XCTAssertTrue(relaunched.entries.isEmpty)
        XCTAssertNil(relaunched.errorMessage)
        relaunched.record(seed: song(2), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)
        XCTAssertEqual(RadioHistoryStore(url: url, historyEpoch: epoch).entries.map(\.id), [song(2).id])

        let clearedEpoch = UUID()
        relaunched.record(seed: song(3), tuning: RadioTuning(), historyEpoch: clearedEpoch, enabled: true, now: date)
        XCTAssertEqual(relaunched.entries.map(\.id), [song(3).id])
        XCTAssertEqual(RadioHistoryStore(url: url, historyEpoch: clearedEpoch).entries, relaunched.entries)
        legacy.record(seed: song(4), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        XCTAssertNotNil(legacy.errorMessage)
        XCTAssertEqual(RadioHistoryStore(url: url, historyEpoch: clearedEpoch).entries, relaunched.entries)
    }

    func testHistoryOffClearsDurablyAndMemoryFixturesStayIsolated() throws {
        let url = try temporaryURL()
        let disk = RadioHistoryStore(url: url)
        let memory = RadioHistoryStore()
        let otherMemory = RadioHistoryStore()
        for store in [disk, memory] {
            store.record(seed: song(1), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
            store.synchronize(historyEpoch: nil, enabled: false)
            store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: false, now: date)
            store.reload(historyEpoch: nil, enabled: true)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertNil(store.errorMessage)
        }
        XCTAssertTrue(RadioHistoryStore(url: url).entries.isEmpty)
        memory.record(seed: song(3), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        memory.reload(historyEpoch: nil, enabled: true)
        XCTAssertEqual(memory.entries.map(\.id), [song(3).id])
        XCTAssertTrue(otherMemory.entries.isEmpty)
        XCTAssertTrue(disk.entries.isEmpty)
        memory.synchronize(historyEpoch: UUID(), enabled: true)
        XCTAssertTrue(memory.entries.isEmpty)
    }

    func testFailedPrivacyClearNeverReintroducesHistoryDuringRecovery() throws {
        let url = try temporaryURL()
        let epoch = UUID()
        let store = RadioHistoryStore(url: url, historyEpoch: epoch)
        store.record(seed: song(1), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)
        let original = try Data(contentsOf: url)
        let other = RadioHistoryStore(url: url, historyEpoch: epoch)
        other.record(seed: song(2), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)
        let foreign = try Data(contentsOf: url)
        store.synchronize(historyEpoch: epoch, enabled: false)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        store.synchronize(historyEpoch: epoch, enabled: true)
        store.record(seed: song(3), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), foreign)
        store.reload(historyEpoch: epoch, enabled: true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(RadioHistoryStore(url: url, historyEpoch: epoch).entries.isEmpty)
        store.record(seed: song(3), tuning: RadioTuning(), historyEpoch: epoch, enabled: true, now: date)

        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: url, options: .atomic)
        let newEpoch = UUID()
        store.synchronize(historyEpoch: newEpoch, enabled: true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        store.reload(historyEpoch: newEpoch, enabled: true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try original.write(to: url, options: .atomic)
        store.reload(historyEpoch: newEpoch, enabled: true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.errorMessage)
        store.record(seed: song(4), tuning: RadioTuning(), historyEpoch: newEpoch, enabled: true, now: date)
        XCTAssertEqual(RadioHistoryStore(url: url, historyEpoch: newEpoch).entries.map(\.id), [song(4).id])
    }

    func testInvalidSeedsAndDatesDoNotChangeSavedHistory() throws {
        let url = try temporaryURL()
        let store = RadioHistoryStore(url: url)
        store.record(seed: song(1), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        let original = try Data(contentsOf: url)
        let invalidSeeds: [RadioSeed] = [
            .artist(ArtistCredit(name: " ")),
            .song(Track(id: "", title: "Song")),
            .song(Track(id: "saavn:2", title: "Song", artworkURL: URL(string: "https://r.googlevideo.com/videoplayback?sig=secret")))
        ]
        for seed in invalidSeeds {
            store.record(seed: seed, tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        }
        for invalidDate in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity)] {
            store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: invalidDate)
        }
        XCTAssertEqual(store.entries.map(\.id), [song(1).id])
        XCTAssertEqual(try Data(contentsOf: url), original)
        store.record(seed: song(2), tuning: RadioTuning(), historyEpoch: nil, enabled: true, now: date)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.entries.map(\.id), [song(2).id, song(1).id])
    }
}
