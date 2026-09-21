import Foundation

enum CatalogJSON: Codable, Sendable, Equatable {
    case object([String: CatalogJSON])
    case array([CatalogJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([CatalogJSON].self) { self = .array(value) }
        else { self = try .object(container.decode([String: CatalogJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> CatalogJSON { object[key] ?? .null }

    var object: [String: CatalogJSON] {
        if case .object(let value) = self { return value }
        return [:]
    }

    var array: [CatalogJSON] {
        if case .array(let value) = self { return value }
        return []
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return string.flatMap(Int.init)
    }

    var int64: Int64? {
        if case .number(let value) = self { return Int64(exactly: value) }
        return string.flatMap(Int64.init)
    }

    var text: String {
        string ?? self["simpleText"].string ?? self["runs"].array.compactMap { $0["text"].string }.joined()
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    func values(for key: String, depth: Int = 0) -> [CatalogJSON] {
        guard depth < 32 else { return [] }
        switch self {
        case .object(let dictionary):
            if let value = dictionary[key] { return [value] }
            return dictionary.keys.sorted().flatMap { dictionary[$0]?.values(for: key, depth: depth + 1) ?? [] }
        case .array(let items): return items.flatMap { $0.values(for: key, depth: depth + 1) }
        default: return []
        }
    }

    static func decode(_ data: Data) throws -> CatalogJSON {
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw MusicServiceError.invalidResponse }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension CatalogJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: CatalogJSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, CatalogJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
    }
}

enum CatalogText {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func videoID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 11,
              value.utf8.allSatisfy({ identifierBytes.contains($0) }) else { return nil }
        return value
    }

    static func identifier(_ value: String?) -> String? {
        guard let value = clean(value), value.utf8.count <= 256,
              value.utf8.allSatisfy({ identifierBytes.contains($0) }) else { return nil }
        return value
    }

    static func artistID(_ value: String?) -> String? {
        guard let value = identifier(value), value.hasPrefix("UC"), value.count == 24 else { return nil }
        return value
    }

    static func duration(_ value: String) -> TimeInterval? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return seconds.isFinite && seconds > 0 && seconds <= 359_999 ? seconds : nil
    }

    static func artwork(_ value: CatalogJSON, videoID: String? = nil) -> URL? {
        let thumbnails = value.values(for: "thumbnails").flatMap(\.array)
        let ranked = thumbnails.enumerated().sorted {
            let left = Double($0.element["width"].int ?? 0) * Double($0.element["height"].int ?? 0)
            let right = Double($1.element["width"].int ?? 0) * Double($1.element["height"].int ?? 0)
            return left == right ? $0.offset > $1.offset : left > right
        }
        for thumbnail in ranked {
            if let url = imageURL(thumbnail.element["url"].string) { return upscaled(url) }
        }
        guard let id = self.videoID(videoID) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    /// Rows only list 60–120 px thumbnails; Google user-content hosts serve any size, so ask for the standard
    /// square up front. ytimg names are left alone because not every size exists for every recording.
    private static func upscaled(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(),
              host.hasSuffix("googleusercontent.com") || host.hasSuffix("ggpht.com") else { return url }
        return ArtworkURL.preferred(url, tier: .standard)
    }

    static func imageURL(_ value: String?) -> URL? {
        guard var value = clean(value) else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { videoID($0.id) != nil && clean($0.title) != nil && seen.insert($0.id).inserted }
    }

    static func uniqueCollections(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seen = Set<String>()
        return collections.filter { !$0.id.isEmpty && clean($0.title) != nil && seen.insert($0.id).inserted }
    }

    static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap(clean).filter { seen.insert($0.lowercased()).inserted }
    }

    private static let identifierBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
}
