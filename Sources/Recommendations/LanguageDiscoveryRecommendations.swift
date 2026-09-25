import Foundation
import OSLog

extension RecommendationEngine {
    func languageDiscovery(profile: TasteProfile, languageProfile: ListeningLanguageProfile,
                           limit: Int = 2, familiarity: DiscoveryFamiliarity = .balanced) async throws -> [DiscoverySection] {
        var balance = DiscoveryBalanceMetrics()
        defer {
            balance.emit(mode: familiarity, scope: .languageDiscovery)
            Self.log.info("automaticDiscoverySuccess=\(balance.success) automaticDiscoveryEmpty=\(balance.empty) automaticDiscoveryFailure=\(balance.failure) automaticDiscoveryCancelled=\(balance.cancelled)")
        }
        do {
            try Task.checkCancellation()
            let more = languageProfile.orderedLanguages.filter { languageProfile.nudges[$0] == .more }
            var seen = Set<ArtistSongLanguage>()
            let targets = Array((more + languageProfile.orderedLanguages).filter { seen.insert($0).inserted }
                .prefix(max(0, min(limit, 2))))
            guard !targets.isEmpty else { return [] }
            let seeds = profile.topTracks(limit: profile.trackAffinity.count).filter {
                Self.isDiscoveryAudio($0) && !profile.dislikedTrackIDs.contains($0.id)
            }
            // Each of two targets gets one seed radio and one search fallback, never extra fan-out per candidate.
            let results = try await withThrowingTaskGroup(of: (Int, LanguageDiscoveryResult).self) { group in
                for (index, language) in targets.enumerated() {
                    let hasPlays = languageProfile.summary.rows.contains { $0.language == language && $0.plays > 0 }
                    let seed = hasPlays ? seeds.first { languageProfile.language(for: $0) == language } : nil
                    group.addTask {
                        (index, try await self.discoverLanguage(language, seed: seed, profile: profile,
                                                               languageProfile: languageProfile, familiarity: familiarity))
                    }
                }
                var collected: [(Int, LanguageDiscoveryResult)] = []
                for try await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            try Task.checkCancellation()
            let sections = results.compactMap(\.section)
            if results.allSatisfy({ !$0.hadResponse }), let error = results.compactMap(\.lastError).last {
                throw (error as? MusicServiceError)
                    ?? MusicServiceError.unavailable("Breezy couldn’t load recommendations. Please try again.")
            }
            balance.record(sections.flatMap(\.tracks), profile: profile)
            return sections
        } catch {
            balance.record(error: error)
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private struct LanguageDiscoveryResult: Sendable {
        var section: DiscoverySection?
        var hadResponse = false
        var lastError: (any Error)?
    }

    private enum LanguageDiscoveryRequest: Sendable {
        case radio(Track), search(String)
    }

    private func discoverLanguage(_ language: ArtistSongLanguage, seed: Track?, profile: TasteProfile,
                                  languageProfile: ListeningLanguageProfile,
                                  familiarity: DiscoveryFamiliarity) async throws -> LanguageDiscoveryResult {
        var result = LanguageDiscoveryResult()
        var requests: [LanguageDiscoveryRequest] = seed.map { [.radio($0)] } ?? []
        requests.append(.search("\(language.title) songs"))
        for request in requests {
            try Task.checkCancellation()
            do {
                let tracks: [Track]
                switch request {
                case .radio(let seed): tracks = try await catalog.radio(seed: seed)
                case .search(let query): tracks = try await catalog.search(query: query, filter: .songs, continuation: nil).tracks
                }
                try Task.checkCancellation()
                result.hadResponse = true
                let candidates = tracks.enumerated().filter {
                    $0.element.id != seed?.id && !profile.dislikedTrackIDs.contains($0.element.id) && Self.isDiscoveryAudio($0.element)
                }.map {
                    Candidate(track: $0.element, score: 1, order: $0.offset).weighted(by: languageProfile)
                        .weighted(by: familiarity, heardTrackIDs: profile.heardTrackIDs)
                }
                let picks = Self.select(candidates.sorted(by: Candidate.ranks).map(\.track),
                                        limit: Self.sectionTrackLimit, artistCap: Self.dailyMixArtistCap)
                guard !picks.isEmpty else { continue }
                let editorialLanguage: MusicLanguage? = switch language {
                case .hindi: .hindi
                case .english: .english
                default: nil
                }
                result.section = DiscoverySection(id: "discovery.language.\(language.rawValue)", title: "\(language.title) to explore",
                    subtitle: Self.discoverySubtitle(language, profile: languageProfile), language: editorialLanguage, tracks: picks)
                return result
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                result.lastError = error
            }
        }
        return result
    }

    private static func isDiscoveryAudio(_ track: Track) -> Bool {
        track.isAudioRecording == true && CatalogText.clean(track.id) != nil && CatalogText.clean(track.title) != nil
            && isRecommendable(track, languages: [])
    }

    private static func discoverySubtitle(_ language: ArtistSongLanguage, profile: ListeningLanguageProfile) -> String {
        if profile.summary.rows.contains(where: { $0.language == language && $0.plays > 0 }) { return "Inspired by your listening" }
        if profile.nudges[language] == .more { return "A little more \(language.title)" }
        return "A starting point while Breezy learns your listening"
    }
}
