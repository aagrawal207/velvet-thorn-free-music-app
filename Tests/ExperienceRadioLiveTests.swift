import XCTest
@testable import GanaBajana

@MainActor
final class ExperienceRadioLiveTests: XCTestCase {
    func testEveryStationResolvesMatchingSeedsAndAPlayableRadioQueue() async throws {
        try requireLiveTests()
        let engine = ExperienceRadioEngine(catalog: YouTubeMusicService())
        for station in RadioExperience.stations {
            let configuration = RadioConfiguration(station: station, languages: station.discoveryLanguages)
            XCTAssertTrue(configuration.artists.isEmpty)
            let batch = try await engine.start(configuration.experience(), disliked: [])
            XCTAssertGreaterThanOrEqual(batch.tracks.count, 4, station.title)
            XCTAssertFalse(batch.buckets.isEmpty, station.title)
            XCTAssertTrue(batch.tracks.allSatisfy { $0.isAudioRecording == true && CatalogText.videoID($0.id) != nil }, station.title)
            XCTAssertEqual(Set(batch.tracks.map(\.id)).count, batch.tracks.count, station.title)
            XCTAssertEqual(Set(batch.tracks.map { SongTitle.core($0.title) }).count, batch.tracks.count, station.title)
            let evidence = "\(station.radioTitle): \(batch.tracks.count) songs\n"
                + batch.buckets.map { "\($0.anchor.title), \($0.anchor.artistName) [\($0.anchor.id)]" }.joined(separator: "\n")
            let attachment = XCTAttachment(string: evidence)
            attachment.name = station.id
            attachment.lifetime = .keepAlways
            add(attachment)
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

    private func requireLiveTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GANABAJANA_LIVE_TESTS"] == "1",
                          "Use GanaBajanaLive to verify station discovery against YouTube Music.")
    }
}
