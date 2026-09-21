//
//  Concurrency.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 13.12.23.
//

import Foundation

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension Sequence {
    
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values = [T]()
        
        for element in self {
            try await values.append(transform(element))
        }
        
        return values
    }
    
    func concurrentMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async -> T) async -> [T] where Element: Sendable {
        await withTaskGroup(of: (Int, T).self) { group in
            var count = 0
            for (index, element) in enumerated() {
                group.addTask { (index, await transform(element)) }
                count += 1
            }
            // Player preference order must survive out-of-order completion and parent cancellation.
            var values = [T?](repeating: nil, count: count)
            for await (index, value) in group { values[index] = value }
            return values.compactMap { $0 }
        }
    }
    
}
