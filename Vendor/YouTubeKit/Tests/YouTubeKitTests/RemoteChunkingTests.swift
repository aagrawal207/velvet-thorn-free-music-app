import Foundation
import XCTest
@testable import YouTubeKit

@available(iOS 15.0, watchOS 8.0, tvOS 15.0, macOS 12.0, *)
final class RemoteChunkingTests: XCTestCase {
    func testRejectsZeroNegativeAndUnboundedRemoteChunkSizes() {
        for size in [0, -1, Int.min, Int.max, RemoteMessageChunkPlan.maximumChunkSize + 1] {
            XCTAssertThrowsError(try RemoteMessageChunkPlan(byteCount: 7, maxChunkSize: size)) {
                XCTAssertEqual($0 as? RemoteChunkingError, .invalidChunkSize)
            }
        }
        XCTAssertNoThrow(try RemoteMessageChunkPlan.validate(maxChunkSize: nil))
    }

    func testChunkCountsRoundUpAtBoundariesWithoutAdditionOverflow() throws {
        for (bytes, size, expected) in [(0, 1, 0), (1, 1, 1), (2, 1, 2), (6, 3, 2), (7, 3, 3),
                                       (1, 1_048_576, 1), (1_048_576, 1_048_576, 1), (1_048_577, 1_048_576, 2)] {
            let plan = try RemoteMessageChunkPlan(byteCount: bytes, maxChunkSize: size)
            XCTAssertEqual(plan.totalChunks, UInt32(expected))
        }
    }

    func testChunkCountMustFitTheUnsignedWireHeaderWithoutAllocatingThePayload() throws {
        guard Int.bitWidth == 64 else { return }
        let largestCount = Int(UInt32.max)
        XCTAssertEqual(try RemoteMessageChunkPlan(byteCount: largestCount, maxChunkSize: 1).totalChunks, UInt32.max)
        for byteCount in [largestCount + 1, Int.max] {
            XCTAssertThrowsError(try RemoteMessageChunkPlan(byteCount: byteCount, maxChunkSize: 1)) {
                XCTAssertEqual($0 as? RemoteChunkingError, .messageTooLarge)
            }
        }
        XCTAssertThrowsError(try RemoteMessageChunkPlan(byteCount: Int.max, maxChunkSize: RemoteMessageChunkPlan.maximumChunkSize)) {
            XCTAssertEqual($0 as? RemoteChunkingError, .messageTooLarge)
        }
    }

    func testInvalidSizesAreRejectedBeforeEncodingOrSending() async {
        struct Unencodable: Encodable {
            struct UnexpectedEncoding: Error { }
            func encode(to encoder: Encoder) throws {
                XCTFail("Invalid remote sizes must be rejected before encoding")
                throw UnexpectedEncoding()
            }
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.invalid/unit")!)
        defer { task.cancel(); session.invalidateAndCancel() }
        for size in [0, -1, Int.max] {
            do {
                try await task.send(Unencodable(), maxChunkSize: size)
                XCTFail("Expected a recoverable chunk-size error")
            } catch {
                XCTAssertEqual(error as? RemoteChunkingError, .invalidChunkSize)
            }
        }
    }
}
