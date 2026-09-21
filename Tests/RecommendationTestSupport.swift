import Foundation
import os
import XCTest
@testable import GanaBajana

enum RecommendationTestFailure: Error {
    case storage(String)
    case unexpectedRequest(String)
    case provider(String)
}

/// Canned catalog that records every call; unknown ids fail like a provider would.
actor RecommendationCatalogMock: MusicCatalogProviding {
    private var radios: [String: [Track]] = [:]
    private var artistPages: [String: ArtistPage] = [:]
    private var failingRadioSeeds: Set<String> = []
    private var failingArtistIDs: Set<String> = []
    private var beforeArtist: (@Sendable (String) async -> Void)?
    private(set) var radioRequests: [(seed: Track, language: MusicLanguage)] = []
    private(set) var artistRequests: [String] = []

    var callCount: Int { radioRequests.count + artistRequests.count }

    func setRadio(_ tracks: [Track], for seedID: String) { radios[seedID] = tracks }
    func setArtist(_ page: ArtistPage) { artistPages[page.id] = page }
    func failRadio(for seedID: String) { failingRadioSeeds.insert(seedID) }
    func failArtist(_ id: String) { failingArtistIDs.insert(id) }
    func setBeforeArtist(_ hook: (@Sendable (String) async -> Void)?) { beforeArtist = hook }

    func search(query: String, filter: SearchFilter, continuation: String?) async throws -> CatalogPage {
        throw RecommendationTestFailure.unexpectedRequest("search: \(query)")
    }

    func browse(id: String) async throws -> CatalogPage {
        throw RecommendationTestFailure.unexpectedRequest("browse: \(id)")
    }

    func artist(id: String) async throws -> ArtistPage {
        artistRequests.append(id)
        if let beforeArtist { await beforeArtist(id) }
        if failingArtistIDs.contains(id) { throw RecommendationTestFailure.provider("artist \(id)") }
        guard let page = artistPages[id] else { throw RecommendationTestFailure.unexpectedRequest("artist: \(id)") }
        return page
    }

    func recommendations(seed: Track, language: MusicLanguage) async throws -> [Track] {
        radioRequests.append((seed, language))
        if failingRadioSeeds.contains(seed.id) { throw RecommendationTestFailure.provider("radio \(seed.id)") }
        return radios[seed.id] ?? []
    }

    func discovery(languages: Set<MusicLanguage>) async throws -> [DiscoverySection] {
        throw RecommendationTestFailure.unexpectedRequest("discovery")
    }
}

@MainActor
final class ReleaseNotifierMock: ReleaseNotifying {
    private let authorized: Bool
    private var authorizationRequestCount = 0
    private var accepted: [ArtistRelease] = []
    var authorizationRequests: Int { get async { authorizationRequestCount } }
    var notified: [ArtistRelease] { get async { accepted } }

    init(authorized: Bool = true) { self.authorized = authorized }

    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequestCount += 1
        return authorized
    }

    func existingIdentifiers() async -> Set<String> {
        Set(accepted.map(\.notificationIdentifier))
    }

    func submit(_ release: ArtistRelease, completion: @escaping @Sendable (Bool) -> Void) {
        accepted.append(release)
        completion(true)
    }
}

/// Adjustable wall clock for time-dependent code that takes a `now` closure.
final class RecommendationTestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ date: Date = RecommendationFixtures.now) { state = OSAllocatedUnfairLock(initialState: date) }

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
func withRecommendationLibrary(_ body: @MainActor (LibraryStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GanaBajana-RecommendationTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = LibraryStore(directory: directory)
    if let error = library.errorMessage { throw RecommendationTestFailure.storage(error) }
    try await body(library)
}

enum RecommendationFixtures {
    /// 2026-05-28 UTC: fixed so decay math is reproducible yet in the past for the library's date validation.
    static let now = Date(timeIntervalSince1970: 1_780_000_000)
    static let calendar = libraryTestCalendar()

    static func track(_ id: String, title: String? = nil, artist: String = "An Artist", artistID: String? = nil,
                      duration: TimeInterval? = 240, language: MusicLanguage? = nil, audio: Bool? = true) -> Track {
        Track(id: id, title: title ?? "Song \(id)", artists: [artist], artistID: artistID, duration: duration,
              language: language, isAudioRecording: audio)
    }

    static func tracks(_ prefix: String, count: Int, artist: String, language: MusicLanguage? = nil) -> [Track] {
        (1...count).map { track("\(prefix)-\($0)", artist: artist, language: language) }
    }

    static func event(_ track: Track, daysAgo: Double, seconds: TimeInterval, now: Date = now) -> ListeningEvent {
        ListeningEvent(id: UUID(), track: track, startedAt: now.addingTimeInterval(-daysAgo * 86_400), listenedSeconds: seconds)
    }

    static func page(_ id: String, name: String, topSongs: [Track] = [], releases: [MusicCollection] = [],
                     related: [MusicCollection] = []) -> ArtistPage {
        ArtistPage(id: id, name: name, topSongs: topSongs, releases: releases, relatedArtists: related)
    }

    static func release(_ id: String, title: String, subtitle: String) -> MusicCollection {
        MusicCollection(id: id, title: title, subtitle: subtitle, kind: .album)
    }

    static func relatedArtist(_ id: String, name: String) -> MusicCollection {
        MusicCollection(id: id, title: name, subtitle: "Artist", kind: .artist)
    }

    // Seed universe shared by the engine tests.
    static let arijit1 = track("arijit-1", title: "Tum Hi Ho", artist: "Arijit Singh", artistID: "UCarijit", duration: 262, language: .hindi)
    static let arijit2 = track("arijit-2", title: "Kesariya", artist: "Arijit Singh", artistID: "UCarijit", duration: 269, language: .hindi)
    static let arijit3 = track("arijit-3", title: "Channa Mereya", artist: "Arijit Singh", artistID: "UCarijit", duration: 290, language: .hindi)
    static let weeknd1 = track("weeknd-1", title: "Blinding Lights", artist: "The Weeknd", artistID: "UCweeknd", duration: 202, language: .english)
    static let weeknd2 = track("weeknd-2", title: "Starboy", artist: "The Weeknd", artistID: "UCweeknd", duration: 230, language: .english)
    static let pritam1 = track("pritam-1", title: "Ae Dil Hai Mushkil", artist: "Pritam", artistID: "UCpritam", duration: 270, language: .hindi)
    static let tap = track("tap-1", title: "Accidental Tap", artist: "Tap Artist", duration: 200)

    /// Three artists with channel ids, listened recently; strong enough to leave cold start.
    static func events(now: Date = now) -> [ListeningEvent] {
        [
            event(arijit1, daysAgo: 1, seconds: 250, now: now),
            event(arijit1, daysAgo: 2, seconds: 250, now: now),
            event(arijit1, daysAgo: 3, seconds: 250, now: now),
            event(arijit2, daysAgo: 1, seconds: 200, now: now),
            event(arijit2, daysAgo: 4, seconds: 200, now: now),
            event(weeknd1, daysAgo: 1, seconds: 190, now: now),
            event(weeknd1, daysAgo: 2, seconds: 150, now: now),
            event(weeknd2, daysAgo: 2, seconds: 180, now: now),
            event(arijit3, daysAgo: 5, seconds: 150, now: now),
            event(pritam1, daysAgo: 6, seconds: 120, now: now),
            event(tap, daysAgo: 0.5, seconds: 0.5, now: now),
        ]
    }

    static func profile(now: Date = now) -> TasteProfile {
        TasteProfile.build(events: events(now: now), favorites: [], playlists: [], recents: [], now: now)
    }

    /// Radios for the top seeds plus artist pages with related artists, enough for a full Discover Weekly.
    static func catalog() async -> RecommendationCatalogMock {
        let catalog = RecommendationCatalogMock()
        var radio1 = (1...5).flatMap { tracks("a\($0)", count: 2, artist: "New A\($0)", language: .hindi) }
        radio1 += tracks("bulk", count: 10, artist: "Bulk Artist", language: .hindi)
        radio1 += [
            arijit2, tap,
            track("a-karaoke", title: "Tum Hi Ho (Karaoke Version)", artist: "Karaoke Crew", language: .hindi),
            track("a-slowed", title: "Kesariya - Slowed + Reverb", artist: "Lofi Crew", language: .hindi),
            track("a-video", title: "Live Performance", artist: "New A1", language: .hindi, audio: false),
            track("a-long", title: "Full Movie Songs", artist: "New A2", duration: 1_200, language: .hindi),
            track("a-short", title: "Ringtone", artist: "New A3", duration: 20, language: .hindi),
        ]
        await catalog.setRadio(radio1, for: arijit1.id)
        var radio2 = (1...5).flatMap { tracks("b\($0)", count: 2, artist: "New B\($0)", language: .hindi) }
        radio2.append(track("arijit-new", title: "Unheard Arijit", artist: "Arijit Singh", artistID: "UCarijit", language: .hindi))
        await catalog.setRadio(radio2, for: arijit2.id)
        await catalog.setRadio((1...5).flatMap { tracks("c\($0)", count: 2, artist: "New C\($0)", language: .english) }, for: weeknd1.id)
        await catalog.setRadio((1...5).flatMap { tracks("d\($0)", count: 2, artist: "New D\($0)", language: .english) }, for: weeknd2.id)

        await catalog.setArtist(page("UCarijit", name: "Arijit Singh",
                                     topSongs: [arijit1, arijit2, arijit3,
                                                track("arijit-top-4", title: "Top Four", artist: "Arijit Singh", artistID: "UCarijit", language: .hindi),
                                                track("arijit-top-5", title: "Top Five", artist: "Arijit Singh", artistID: "UCarijit", language: .hindi)],
                                     related: [relatedArtist("UCshreya", name: "Shreya Ghoshal"), relatedArtist("UCatif", name: "Atif Aslam"),
                                               relatedArtist("UCsonu", name: "Sonu Nigam")]))
        await catalog.setArtist(page("UCweeknd", name: "The Weeknd",
                                     topSongs: [weeknd1, weeknd2, track("weeknd-3", title: "Save Your Tears", artist: "The Weeknd", artistID: "UCweeknd", language: .english)],
                                     related: [relatedArtist("UCdrake", name: "Drake"), relatedArtist("UCpost", name: "Post Malone")]))
        await catalog.setArtist(page("UCpritam", name: "Pritam",
                                     topSongs: [pritam1, track("pritam-2", title: "Gerua", artist: "Pritam", artistID: "UCpritam", language: .hindi)],
                                     related: [relatedArtist("UCshreya", name: "Shreya Ghoshal"), relatedArtist("UCvishal", name: "Vishal Mishra")]))
        for (id, name) in [("UCshreya", "Shreya Ghoshal"), ("UCatif", "Atif Aslam"), ("UCsonu", "Sonu Nigam"),
                           ("UCdrake", "Drake"), ("UCpost", "Post Malone"), ("UCvishal", "Vishal Mishra")] {
            let language: MusicLanguage = ["UCdrake", "UCpost"].contains(id) ? .english : .hindi
            await catalog.setArtist(page(id, name: name, topSongs: (1...3).map {
                track("\(id)-\($0)", artist: name, artistID: id, language: language)
            }))
        }
        return catalog
    }
}
