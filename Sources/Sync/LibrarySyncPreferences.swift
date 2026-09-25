import Foundation

enum LibrarySyncPreferences {
    // Codable remains the field inventory, including preferences added by subsequent app versions.
    static func fields(_ preferences: UserPreferences) throws -> [String: Data] {
        let object = try JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(preferences))
        guard let dictionary = object as? [String: Any] else { throw LibrarySyncError.invalidData("preferences") }
        var result: [String: Data] = [:]
        try flatten(dictionary, prefix: "", into: &result)
        return result
    }

    static func applying(_ fields: [String: Data], to preferences: UserPreferences) throws -> UserPreferences {
        let known = try self.fields(UserPreferences())
        var object = try JSONSerialization.jsonObject(with: LibrarySyncCodec.encode(preferences)) as! [String: Any]
        for (path, data) in fields {
            guard known[path] != nil else { throw LibrarySyncError.newerVersion }
            let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            try insert(value, path: path.split(separator: "/").map(String.init), into: &object)
        }
        let decoded = try LibrarySyncCodec.decode(UserPreferences.self, from: JSONSerialization.data(withJSONObject: object))
        let roundTrip = try self.fields(decoded)
        for (key, value) in fields where roundTrip[key] != value {
            // Lenient preference decoders may clamp values; accepting that here would silently change a remote edit.
            throw LibrarySyncError.invalidData("preference \(key)")
        }
        return decoded
    }

    private static func flatten(_ object: [String: Any], prefix: String, into result: inout [String: Data]) throws {
        for (key, value) in object {
            guard !key.isEmpty, !key.contains("/") else { throw LibrarySyncError.invalidData("preference field name") }
            let path = prefix.isEmpty ? key : "\(prefix)/\(key)"
            if let nested = value as? [String: Any], !nested.isEmpty {
                try flatten(nested, prefix: path, into: &result)
            } else {
                // Set encoders have no stable iteration order. Ordered arrays, such as Home order, remain ordered.
                let canonical: Any
                if path == "languages" || path == "homeLayout/hidden", let strings = value as? [String] {
                    canonical = strings.sorted()
                } else {
                    canonical = value
                }
                result[path] = try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            }
        }
    }

    private static func insert(_ value: Any, path: [String], into object: inout [String: Any]) throws {
        guard let first = path.first else { throw LibrarySyncError.invalidData("preference path") }
        if path.count == 1 { object[first] = value; return }
        guard var nested = object[first] as? [String: Any] else { throw LibrarySyncError.newerVersion }
        try insert(value, path: Array(path.dropFirst()), into: &nested)
        object[first] = nested
    }
}
