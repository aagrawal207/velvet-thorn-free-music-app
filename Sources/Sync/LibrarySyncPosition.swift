import Foundation

struct LibrarySyncPosition: Codable, Hashable, Comparable, Sendable {
    static let maximumDepth = 1024
    var digits: [UInt16]

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.digits.lexicographicallyPrecedes(rhs.digits) }

    static func between(_ lower: Self?, _ upper: Self?, revision: LibrarySyncRevision) throws -> Self {
        if let lower, let upper, !(lower < upper) { throw LibrarySyncError.invalidData("playlist order") }
        var prefix: [UInt16] = []
        var upperIsOpen = upper == nil
        for index in 0..<maximumDepth {
            let left = lower.flatMap { index < $0.digits.count ? $0.digits[index] : nil } ?? 0
            let right = upperIsOpen ? UInt16.max : upper.flatMap { index < $0.digits.count ? $0.digits[index] : nil } ?? UInt16.max
            if Int(right) - Int(left) > 1 {
                // Sequential appends should not exhaust half the remaining rank space on every song.
                prefix.append(upper == nil && lower != nil ? left + 1 : UInt16((Int(left) + Int(right)) / 2))
                let suffix = "\(revision.writer.uuidString):\(revision.milliseconds):\(revision.counter)".utf8.map { UInt16($0) + 1 }
                prefix.append(contentsOf: suffix)
                guard prefix.count <= maximumDepth else { throw LibrarySyncError.invalidData("overly deep playlist order") }
                let result = Self(digits: prefix)
                guard lower.map({ $0 < result }) ?? true, upper.map({ result < $0 }) ?? true else {
                    throw LibrarySyncError.invalidData("playlist order")
                }
                return result
            }
            prefix.append(left)
            if left < right { upperIsOpen = true }
        }
        throw LibrarySyncError.invalidData("overly deep playlist order")
    }

    // Longest increasing subsequence preserves untouched positions instead of stamping every shifted song.
    static func stableIDs(previous: [String], candidate: [String]) -> Set<String> {
        let indices = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element, $0.offset) })
        let common = candidate.compactMap { id in indices[id].map { (id, $0) } }
        var tails: [Int] = []
        var predecessors = Array(repeating: -1, count: common.count)
        for index in common.indices {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if common[tails[middle]].1 < common[index].1 { low = middle + 1 }
                else { high = middle }
            }
            if low > 0 { predecessors[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) }
            else { tails[low] = index }
        }
        var result = Set<String>()
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            result.insert(common[cursor].0)
            cursor = predecessors[cursor]
        }
        return result
    }
}
