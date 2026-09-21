//
//  Chunking.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 03.05.2025.
//

import Foundation

enum RemoteChunkingError: Error, Equatable, LocalizedError {
    case invalidChunkSize
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidChunkSize: return "The remote service requested an unsupported message chunk size."
        case .messageTooLarge: return "The remote response is too large to send."
        }
    }
}

struct RemoteMessageChunkPlan {
    static let maximumChunkSize = 1_048_576
    let chunkSize: Int
    let totalChunks: UInt32

    static func validate(maxChunkSize: Int?) throws {
        guard let maxChunkSize else { return }
        guard (1...maximumChunkSize).contains(maxChunkSize) else { throw RemoteChunkingError.invalidChunkSize }
    }

    init(byteCount: Int, maxChunkSize: Int) throws {
        try Self.validate(maxChunkSize: maxChunkSize)
        guard byteCount >= 0 else { throw RemoteChunkingError.messageTooLarge }
        let count = byteCount / maxChunkSize + (byteCount % maxChunkSize == 0 ? 0 : 1)
        guard let totalChunks = UInt32(exactly: count) else { throw RemoteChunkingError.messageTooLarge }
        self.chunkSize = maxChunkSize
        self.totalChunks = totalChunks
    }
}

extension FixedWidthInteger {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

@available(iOS 13.0, watchOS 6.0, tvOS 13.0, macOS 10.15, *)
extension URLSessionWebSocketTask {
    
    /// - parameter maxChunkSize: The maximum size of a chunk. If nil, the entire object is sent in one chunk without any header.
    func send(_ value: some Encodable, maxChunkSize: Int?, encoder: JSONEncoder = JSONEncoder()) async throws {
        try RemoteMessageChunkPlan.validate(maxChunkSize: maxChunkSize)
        guard let maxChunkSize else {
            try await send(value, encoder: encoder)
            return
        }
        
        let encoded = try encoder.encode(value)
        let plan = try RemoteMessageChunkPlan(byteCount: encoded.count, maxChunkSize: maxChunkSize)
        
        let packetIdentifier = UInt32.random(in: 0...UInt32.max)
        
        func headerBytes(for offset: UInt32, totalChunks: UInt32) -> Data {
            // 4 byte each
            var header = Data(capacity: 12)
            header.append(packetIdentifier.bigEndianData)
            header.append(offset.bigEndianData)
            header.append(totalChunks.bigEndianData)
            return header
        }
        
        var offset = 0
        for chunkIndex in 0..<plan.totalChunks {
            let end = offset + min(plan.chunkSize, encoded.count - offset)
            let slice = encoded[offset..<end]
            let header = headerBytes(for: chunkIndex, totalChunks: plan.totalChunks)
            try await send(.data(header + slice))
            offset = end
        }
    }
    
}
