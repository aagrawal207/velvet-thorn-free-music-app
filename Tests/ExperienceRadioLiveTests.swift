import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioLiveTests: XCTestCase {
    func testEveryStationResolvesAPlayableRadioQueueInEachLanguageAndBoth() async throws {
        try requireLiveTests()
        let engine = ExperienceRadioEngine(catalog: YouTubeMusicService())
        let languageSets: [Set<MusicLanguage>] = [[.hindi], [.english], [.hindi, .english]]
        for station in RadioExperience.stations {
            for languages in languageSets {
                let label = "\(station.title) \(languages.map(\.rawValue).sorted())"
                let configuration = RadioConfiguration(station: station, languages: languages)
                XCTAssertTrue(configuration.artists.isEmpty)
                XCTAssertNil(configuration.validationMessage, label)
                let batch = try await engine.start(configuration.experience(), disliked: [], languages: languages)
                XCTAssertGreaterThanOrEqual(batch.tracks.count, ExperienceRadioEngine.minimumQueueSize, label)
                XCTAssertFalse(batch.buckets.isEmpty, label)
                XCTAssertTrue(batch.tracks.allSatisfy { $0.isAudioRecording == true && CatalogText.videoID($0.id) != nil }, label)
                XCTAssertEqual(Set(batch.tracks.map(\.id)).count, batch.tracks.count, label)
                XCTAssertEqual(Set(batch.tracks.map { SongTitle.core($0.title) }).count, batch.tracks.count, label)
                XCTAssertTrue(batch.tracks.contains { batch.discoveryTrackIDs.contains($0.id) }, label)
                let evidence = "\(station.radioTitle) [\(languages.map(\.rawValue).sorted().joined(separator: "+"))]: \(batch.tracks.count) songs\n"
                    + batch.buckets.map { "\($0.anchor.title), \($0.anchor.artistName) [\($0.anchor.id)]" }.joined(separator: "\n")
                let attachment = XCTAttachment(string: evidence)
                attachment.name = "\(station.id)-\(languages.map(\.rawValue).sorted().joined(separator: "-"))"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testMelancholyRadioContinuesWithFreshSongs() async throws {
        try requireLiveTests()
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let engine = ExperienceRadioEngine(catalog: YouTubeMusicService())
        let initial = try await engine.start(station, disliked: [])
        let next = try await engine.continueRadio(buckets: initial.buckets, round: 0, queue: initial.tracks, disliked: [])
        XCTAssertFalse(next.tracks.isEmpty)
        XCTAssertTrue(Set(next.tracks.map(\.id)).isDisjoint(with: initial.tracks.map(\.id)))
        XCTAssertTrue(next.tracks.allSatisfy { $0.isAudioRecording == true })
    }

    func testHindiOnlyMelancholyStartsFromWordingAlone() async throws {
        try requireLiveTests()
        let station = try XCTUnwrap(RadioExperience.stations.first { $0.id == "melancholy" })
        let engine = ExperienceRadioEngine(catalog: YouTubeMusicService())
        let configuration = RadioConfiguration(station: station, languages: [.hindi])
        XCTAssertNil(configuration.validationMessage)
        let experience = configuration.experience()
        XCTAssertTrue(experience.seeds.isEmpty, "Melancholy has English cues only; Hindi starts from its wording")
        let batch = try await engine.start(experience, disliked: [], languages: [.hindi])
        XCTAssertGreaterThanOrEqual(batch.tracks.count, ExperienceRadioEngine.minimumQueueSize)
        XCTAssertFalse(batch.buckets.isEmpty)
        XCTAssertTrue(batch.tracks.allSatisfy { $0.isAudioRecording == true })
    }

    private func requireLiveTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Use GanaBajanaLive to verify station discovery against YouTube Music.")
    }
}
