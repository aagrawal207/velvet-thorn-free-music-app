import Foundation

enum CatalogChartParser {
    static func content(_ root: CatalogJSON) throws -> CatalogJSON {
        guard let renderer = root.values(for: "musicAnalyticsSectionRenderer").first,
              renderer["content"].isObject else { throw MusicServiceError.invalidResponse }
        return renderer["content"]
    }

    static func parseSongChart(_ root: CatalogJSON, language: MusicLanguage, region: String,
                               fetchedAt: Date) throws -> ChartSnapshot {
        let content = try content(root)
        let request = content["perspectiveMetadata"]["requestParams"]["chartParams"]
        let actualRegion = request["countryCode"].string.map(normalizedRegion)
        guard actualRegion == normalizedRegion(region),
              request["chartType"].string == "CHART_TYPE_TRACKS",
              request["chartPeriodType"].string == "CHART_PERIOD_TYPE_WEEKLY" else {
            throw MusicServiceError.invalidResponse
        }
        let groups = content["trackTypes"].array
        guard let group = groups.first(where: {
            $0["chartPeriodType"].string == "CHART_PERIOD_TYPE_WEEKLY" && $0["listType"].string == "TOP_VIEWS_CHART"
        }), let end = date(group["endDate"].string),
            let start = calendar.date(byAdding: .day, value: -6, to: end) else { throw MusicServiceError.invalidResponse }
        var entries = group["trackViews"].array.compactMap { row -> ChartEntry? in
            guard row["isAvailable"].bool != false, row["isVisible"].bool != false,
                  let rank = row["chartEntryMetadata"]["currentPosition"].int, rank > 0,
                  let title = CatalogText.clean(row["name"].string),
                  let id = CatalogText.videoID(row["atvExternalVideoId"].string) else { return nil }
            var names = Set<String>()
            let credits = row["artists"].array.compactMap { artist -> ArtistCredit? in
                guard let name = CatalogText.clean(artist["name"].string), names.insert(name.lowercased()).inserted else { return nil }
                return ArtistCredit(name: name, id: CatalogText.artistID(artist["externalChannelId"].string))
            }
            let track = Track(id: id, title: title, credits: credits,
                              artworkURL: CatalogText.artwork(.null, videoID: id),
                              isExplicit: row["isExplicit"].bool ?? false, isAudioRecording: true)
            let views = row["viewCount"].int64.flatMap { $0 >= 0 ? $0 : nil }
            let previous = row["chartEntryMetadata"]["previousPosition"].int.flatMap { $0 > 0 ? $0 : nil }
            return ChartEntry(rank: rank, track: track, views: views, previousRank: previous)
        }
        entries = entries.enumerated().sorted {
            $0.element.rank == $1.element.rank ? $0.offset < $1.offset : $0.element.rank < $1.element.rank
        }.map(\.element)
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.track.id).inserted }
        let selected = Dictionary(uniqueKeysWithValues: CatalogDiscovery.select(entries.map(\.track), language: language).map { ($0.id, $0) })
        entries = entries.compactMap { entry in
            guard let track = selected[entry.track.id] else { return nil }
            return ChartEntry(rank: entry.rank, track: track, views: entry.views, previousRank: entry.previousRank)
        }
        let country = switch normalizedRegion(region) {
        case "in": "India"
        case "us": "United States"
        default: "Global"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        let dates = formatter.string(from: start) + " – " + formatter.string(from: end)
        return ChartSnapshot(id: "youtube-weekly-picks-\(normalizedRegion(region))-\(language.rawValue)-\(group["endDate"].text)",
                             title: "Weekly picks", subtitle: "\(country) · \(dates)",
                             source: "YouTube Charts · Weekly songs · selected for you", language: language,
                             periodStart: start, periodEnd: end, fetchedAt: fetchedAt, entries: entries)
    }

    static func date(_ text: String?) -> Date? {
        guard let text, text.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day ? date : nil
    }

    private static func normalizedRegion(_ value: String) -> String {
        let value = value.lowercased()
        return value == "zz" ? "global" : value
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
