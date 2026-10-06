import Foundation
import XCTest
#if os(watchOS)
@testable import GanaBajanaWatch
#else
@testable import GanaBajana
#endif

final class CompanionProtocolTests: XCTestCase {
    func testEveryActionRoundTripsWithTheSameRequestIdentity() throws {
        let playlist = "playlist:\(UUID().uuidString)"
        let actions: [CompanionAction] = [
            .snapshot, .browse("root"), .browse(playlist), .play, .pause, .next, .previous, .seek(12.75),
            .setFavorite(true), .setFavorite(false), .setSuperLiked(true), .setSuperLiked(false),
            .setShuffle(true), .setShuffle(false), .setRepeatMode(.off), .setRepeatMode(.all), .setRepeatMode(.one),
            .playItem(location: "queue", itemID: "item:2", revision: "content-revision"),
        ]
        for action in actions {
            let request = CompanionRequest(action: action, expectedTrackID: "recording-id")
            let decoded = try CompanionWire.decode(CompanionRequest.self, from: CompanionWire.encode(request))
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.version, CompanionWire.version)
            XCTAssertEqual(decoded.version, 2)
        }
        let first = CompanionRequest(action: .snapshot)
        let second = CompanionRequest(action: .snapshot)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNil(first.expectedTrackID)
    }

    func testVersionTwoFixturesKeepSynthesizedEnumWireShape() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let seek = Data("""
        {"version":2,"id":"\(id.uuidString)","action":{"seek":{"_0":42.25}},"expectedTrackID":"song"}
        """.utf8)
        XCTAssertEqual(try CompanionWire.decode(CompanionRequest.self, from: seek),
                       CompanionRequest(id: id, action: .seek(42.25), expectedTrackID: "song"))
        let superLike = Data("""
        {"version":2,"id":"\(id.uuidString)","action":{"setSuperLiked":{"_0":true}},"expectedTrackID":"song"}
        """.utf8)
        XCTAssertEqual(try CompanionWire.decode(CompanionRequest.self, from: superLike),
                       CompanionRequest(id: id, action: .setSuperLiked(true), expectedTrackID: "song"))
        let selection = CompanionRequest(id: id, action: .playItem(location: "favorites", itemID: "item:0", revision: "rev"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(selection)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        let action = try XCTUnwrap(object["action"] as? [String: Any])
        let arguments = try XCTUnwrap(action["playItem"] as? [String: String])
        XCTAssertEqual(arguments, ["location": "favorites", "itemID": "item:0", "revision": "rev"])
        let demotion = CompanionRequest(id: id, action: .setSuperLiked(false))
        let demotionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(demotion)) as? [String: Any])
        XCTAssertEqual(demotionObject["version"] as? Int, 2)
        let demotionAction = try XCTUnwrap(demotionObject["action"] as? [String: Any])
        XCTAssertEqual(demotionAction.keys.sorted(), ["setSuperLiked"])
        XCTAssertEqual(demotionAction["setSuperLiked"] as? [String: Bool], ["_0": false])
        for mode in [CompanionRepeatMode.off, .all, .one] {
            XCTAssertEqual(String(decoding: try CompanionWire.encode(mode), as: UTF8.self), "\"\(mode.rawValue)\"")
        }
    }

    func testVersionOneRequestsAreUnsupportedWhileVersionTwoIsSent() throws {
        let id = UUID().uuidString
        for action in [#"{"play":{}}"#, #"{"setFavorite":{"_0":true}}"#, #"{"setSuperLiked":{"_0":true}}"#, #"{"snapshot":{}}"#] {
            for version in [0, 1, 3] {
                let data = Data("{\"version\":\(version),\"id\":\"\(id)\",\"action\":\(action)}".utf8)
                XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: data), "\(version) \(action)") { error in
                    XCTAssertEqual(error as? CompanionWireError, .unsupportedVersion, "\(version) \(action)")
                }
            }
        }
        for version in [0, 1, 3] {
            XCTAssertThrowsError(try CompanionRequest(version: version, action: .play).validate()) { error in
                XCTAssertEqual(error as? CompanionWireError, .unsupportedVersion)
            }
        }
        XCTAssertEqual(CompanionRequest(action: .setSuperLiked(true)).version, 2)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(CompanionRequest(action: .play))) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(CompanionWireError.unsupportedVersion.errorDescription,
                       "Update Velvet Thorn on your iPhone and Apple Watch to use these controls.")
    }

    func testResponseAndSnapshotCanRoundTripOffTheMainActor() async throws {
        let nowPlaying = makeNowPlaying(title: "रात की धुन 🎶", position: 25.5, duration: 240)
        let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 99,
                                         updatedAt: Date(timeIntervalSince1970: 1_800_000_000), nowPlaying: nowPlaying,
                                         libraryError: "Your library change couldn’t be saved.")
        let page = CompanionPage(location: "root", title: "Library", revision: "revision", items: [
            CompanionItem(id: "favorites", title: "Favorites", subtitle: "", destination: "favorites"),
        ], isTruncated: false)
        let response = CompanionResponse(id: UUID(), accepted: true, snapshot: snapshot, page: page,
                                         executionLease: CompanionExecutionLease(id: UUID(), sessionID: snapshot.sessionID))
        let decoded = try await Task.detached {
            try CompanionWire.decode(CompanionResponse.self, from: CompanionWire.encode(response))
        }.value
        XCTAssertEqual(decoded, response)
        XCTAssertNil(decoded.error)
        XCTAssertNotNil(decoded.executionLease)
        XCTAssertNotNil(decoded.snapshot.libraryError)
        let empty = CompanionResponse(id: UUID(), accepted: true,
                                      snapshot: CompanionSnapshot(sessionID: UUID(), sequence: 0, updatedAt: Date(), nowPlaying: nil))
        XCTAssertNil(empty.page)
        XCTAssertEqual(try CompanionWire.decode(CompanionResponse.self, from: CompanionWire.encode(empty)), empty)
    }

    func testMalformedOrAmbiguousRequestsCannotDecodeIntoCommands() throws {
        let id = UUID().uuidString
        let invalidActions = [
            "{}", "null", "[]", #"{"unknown":{}}"#, #"{"next":{},"pause":{}}"#,
            #"{"next":{},"unknown":{}}"#, #"{"play":{"ignored":true}}"#,
            #"{"seek":{}}"#, #"{"seek":{"_0":"12"}}"#, #"{"seek":{"_0":"NaN"}}"#,
            #"{"seek":{"_0":-1}}"#, #"{"seek":{"_0":12,"other":42}}"#,
            #"{"setFavorite":{"_0":1}}"#, #"{"setRepeatMode":{"_0":"forever"}}"#,
            #"{"setSuperLiked":{}}"#, #"{"setSuperLiked":{"_0":1}}"#, #"{"setSuperLiked":{"_0":"true"}}"#,
            #"{"setSuperLiked":{"_0":null}}"#, #"{"setSuperLiked":{"_0":true,"_1":false}}"#,
            #"{"setSuperLiked":{"value":true}}"#, #"{"setSuperLiked":true}"#, #"{"setSuperLiked":{"_0":true},"setFavorite":{"_0":true}}"#,
            #"{"playItem":{"location":"queue","itemID":"item:0"}}"#,
        ]
        for action in invalidActions {
            let data = Data("{\"version\":2,\"id\":\"\(id)\",\"action\":\(action)}".utf8)
            XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: data), action) { error in
                XCTAssertNotEqual(error as? CompanionWireError, .unsupportedVersion, "The action, not the version, must fail: \(action)")
            }
        }
        let invalidEnvelopes = [
            "{\"id\":\"\(id)\",\"action\":{\"play\":{}}}",
            #"{"version":2,"action":{"play":{}}}"#,
            #"{"version":2,"id":"invalid","action":{"play":{}}}"#,
            #"{"version":"2","id":"\#(id)","action":{"play":{}}}"#,
            "{\"version\":2,\"id\":\"\(id)\",\"action\":{\"play\":{}},\"extra\":true}",
            "{\"version\":2,\"id\":\"\(id)\",\"action\":{\"play\":{}},\"expectedTrackID\":\"\"}",
        ]
        for envelope in invalidEnvelopes {
            XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: Data(envelope.utf8)), envelope)
        }
    }

    func testValidationRejectsUnknownVersionsLocationsAndUnboundedIdentifiers() throws {
        let badRequests: [CompanionRequest] = [
            .init(version: 0, action: .play), .init(version: 1, action: .pause), .init(version: 3, action: .pause),
            .init(action: .browse("")), .init(action: .browse("ROOT")), .init(action: .browse("search")),
            .init(action: .browse("playlist:not-a-uuid")), .init(action: .browse("https://example.com")),
            .init(action: .browse("root/../queue")), .init(action: .browse(String(repeating: "x", count: 70_000))),
            .init(action: .seek(.nan)), .init(action: .seek(.infinity)), .init(action: .seek(-.infinity)),
            .init(action: .seek(-0.1)), .init(action: .play, expectedTrackID: "  \n"),
            .init(action: .play, expectedTrackID: String(repeating: "a", count: 257)),
            .init(action: .playItem(location: "queue", itemID: "", revision: "revision")),
            .init(action: .playItem(location: "queue", itemID: "item:0", revision: "")),
            .init(action: .playItem(location: "queue", itemID: "item:0", revision: String(repeating: "r", count: 65))),
        ]
        for request in badRequests { XCTAssertThrowsError(try request.validate()) }
        let playlist = UUID()
        for location in ["root", "favorites", "recent", "playlists", "queue", "playlist:\(playlist.uuidString.lowercased())"] {
            XCTAssertNoThrow(try CompanionRequest(action: .browse(location)).validate())
        }
        XCTAssertEqual(CompanionWire.canonicalLocation("playlist:\(playlist.uuidString.lowercased())"),
                       "playlist:\(playlist.uuidString)")
    }

    func testWireByteLimitIncludesIgnoredWhitespaceBeforeDecoding() throws {
        let request = CompanionRequest(action: .snapshot)
        var data = try CompanionWire.encode(request)
        data.append(Data(repeating: 32, count: CompanionWire.maximumMessageBytes - data.count))
        XCTAssertEqual(try CompanionWire.decode(CompanionRequest.self, from: data), request)
        data.append(32)
        XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: data)) { error in
            XCTAssertEqual(error as? CompanionWireError, .oversizedMessage)
        }
        XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: Data()))
        XCTAssertThrowsError(try CompanionWire.encode(String(repeating: "x", count: CompanionWire.maximumMessageBytes))) { error in
            XCTAssertEqual(error as? CompanionWireError, .oversizedMessage)
        }
    }

    func testEscapingAndUnicodeCannotPushAFortyRowResponsePastSixtyKiB() throws {
        let hostileText = String(repeating: "\u{0001}\"\\/\u{2028}🎶क", count: 5_000)
        let items = (0..<45).map { index in
            CompanionItem(id: String(repeating: "x", count: 250) + "-\(index)", title: hostileText,
                          subtitle: hostileText, destination: "playlist:11111111-2222-3333-4444-555555555555")
        }
        let page = CompanionPage(location: "playlists", title: hostileText, revision: String(repeating: "r", count: 64),
                                 items: items, isTruncated: false)
        XCTAssertEqual(page.items.count, 40)
        XCTAssertTrue(page.isTruncated)
        XCTAssertTrue(page.title.hasSuffix("…"))
        XCTAssertTrue(page.items.allSatisfy { $0.title.hasSuffix("…") && $0.subtitle.hasSuffix("…") })
        let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: .max, updatedAt: Date(),
                                         nowPlaying: makeNowPlaying(title: hostileText, artist: hostileText, error: hostileText),
                                         libraryError: hostileText)
        let response = CompanionResponse(id: UUID(), accepted: false, snapshot: snapshot, page: page, error: hostileText,
                                         executionLease: CompanionExecutionLease(id: UUID(), sessionID: snapshot.sessionID))
        let plainJSON = try JSONEncoder().encode(response)
        XCTAssertLessThanOrEqual(plainJSON.count, 60 * 1_024)
        XCTAssertEqual(try CompanionWire.decode(CompanionResponse.self, from: CompanionWire.encode(response)), response)
        for text in [page.title, page.items[0].title, page.items[0].subtitle,
                     try XCTUnwrap(response.error), try XCTUnwrap(snapshot.libraryError)] {
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(text).count - 2, CompanionWire.maximumTextBytes)
        }
        XCTAssertFalse(CompanionPage(location: "queue", title: "Queue", revision: "rev",
                                     items: Array(items.prefix(40)), isTruncated: false).isTruncated)
    }

    func testDecodedPagesAlsoRespectTheRowAndTextLimits() throws {
        let items = (0..<41).map { ["id": "item:\($0)", "title": String(repeating: "q", count: 500), "subtitle": "Artist"] }
        let object: [String: Any] = [
            "location": "queue", "title": "Queue", "revision": "revision", "isTruncated": false, "items": items,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let page = try CompanionWire.decode(CompanionPage.self, from: data)
        XCTAssertEqual(page.items.count, 40)
        XCTAssertTrue(page.isTruncated)
        XCTAssertLessThanOrEqual(page.items[0].title.utf8.count, CompanionWire.maximumTextBytes)
        let duplicate = CompanionPage(location: "queue", title: "Queue", revision: "revision", items: [
            CompanionItem(id: "same", title: "First", subtitle: ""), CompanionItem(id: "same", title: "Second", subtitle: ""),
        ], isTruncated: false)
        XCTAssertThrowsError(try CompanionWire.decode(CompanionPage.self, from: CompanionWire.encode(duplicate)))
    }

    func testOversizedIdentitiesAreRejectedRatherThanTruncatedIntoAnotherItem() throws {
        let oversizedID = String(repeating: "i", count: CompanionWire.maximumIdentifierBytes + 1)
        let item = CompanionItem(id: oversizedID, title: "Song", subtitle: "Artist")
        XCTAssertEqual(item.id, oversizedID)
        XCTAssertThrowsError(try JSONEncoder().encode(item))
        let page = CompanionPage(location: "queue", title: "Queue", revision: String(repeating: "r", count: 65),
                                 items: [], isTruncated: false)
        XCTAssertThrowsError(try JSONEncoder().encode(page))
        let invalidDestination = CompanionItem(id: "folder", title: "Folder", subtitle: "", destination: "search")
        XCTAssertThrowsError(try JSONEncoder().encode(invalidDestination))
    }

    func testInvalidPlaybackNumbersBecomeFinitePresentationValues() throws {
        for position in [Double.nan, .infinity, -.infinity, -42] {
            let value = makeNowPlaying(position: position, duration: 240)
            XCTAssertEqual(value.position, 0)
            XCTAssertNoThrow(try CompanionWire.encode(value))
        }
        for duration in [Double.nan, .infinity, -.infinity, -1] {
            let value = makeNowPlaying(position: 12, duration: duration)
            XCTAssertEqual(value.duration, 0)
            XCTAssertEqual(value.position, 12)
        }
        XCTAssertEqual(makeNowPlaying(position: 500, duration: 240).position, 240)
    }

    func testExecutionLeaseRoundTripsWithoutSenderOrReceiverWallClockFields() throws {
        let lease = CompanionExecutionLease(id: UUID(), sessionID: UUID())
        XCTAssertEqual(try CompanionWire.decode(CompanionExecutionLease.self, from: CompanionWire.encode(lease)), lease)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(lease)) as? [String: String])
        XCTAssertEqual(object, ["id": lease.id.uuidString, "sessionID": lease.sessionID.uuidString])
        let request = CompanionRequest(action: .setFavorite(true), expectedTrackID: "recording-id", executionLease: lease)
        XCTAssertEqual(try CompanionWire.decode(CompanionRequest.self, from: CompanionWire.encode(request)), request)
        XCTAssertNotEqual(request, CompanionRequest(id: request.id, action: request.action, expectedTrackID: request.expectedTrackID))
    }

    func testPayloadsWithoutOptionalKeysDefaultExecutionLeaseAndLibraryErrorToNil() throws {
        let id = UUID().uuidString
        let minimalRequest = Data("{\"version\":2,\"id\":\"\(id)\",\"action\":{\"snapshot\":{}}}".utf8)
        let request = try CompanionWire.decode(CompanionRequest.self, from: minimalRequest)
        XCTAssertNil(request.executionLease)
        XCTAssertNil(request.expectedTrackID)
        XCTAssertNil(CompanionRequest(action: .play).executionLease)

        let minimalResponse = Data("""
        {"id":"\(id)","accepted":true,"snapshot":{"sessionID":"\(id)","sequence":1,"updatedAt":0}}
        """.utf8)
        let response = try CompanionWire.decode(CompanionResponse.self, from: minimalResponse)
        XCTAssertNil(response.executionLease)
        XCTAssertNil(response.snapshot.libraryError)
        XCTAssertNil(response.snapshot.nowPlaying)
        XCTAssertNil(CompanionResponse(id: UUID(), accepted: true, snapshot: response.snapshot).executionLease)
    }

    func testMalformedExecutionLeasesCannotDecodeIntoCommands() throws {
        let id = UUID().uuidString
        let invalidLeases = [
            "{}", "[]", "42", "\"lease\"", "{\"id\":\"\(id)\"}", "{\"sessionID\":\"\(id)\"}",
            "{\"id\":\"invalid\",\"sessionID\":\"\(id)\"}", "{\"id\":\"\(id)\",\"sessionID\":null}",
            "{\"id\":\"\(id)\",\"sessionID\":7}", "{\"id\":\"\(id)\",\"sessionID\":\"\(id)\",\"expiresAt\":0}",
        ]
        for lease in invalidLeases {
            let data = Data("{\"version\":2,\"id\":\"\(id)\",\"action\":{\"next\":{}},\"executionLease\":\(lease)}".utf8)
            XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: data), lease) { error in
                XCTAssertNotEqual(error as? CompanionWireError, .unsupportedVersion, lease)
            }
        }
        let largeID = String(repeating: "x", count: CompanionWire.maximumMessageBytes)
        let oversized = Data("""
        {"version":2,"id":"\(id)","action":{"next":{}},"executionLease":{"id":"\(largeID)","sessionID":"\(id)"}}
        """.utf8)
        XCTAssertThrowsError(try CompanionWire.decode(CompanionRequest.self, from: oversized)) { error in
            XCTAssertEqual(error as? CompanionWireError, .oversizedMessage)
        }
    }

    func testLibraryErrorParticipatesInSnapshotEqualityAndDecodeBoundsIndependentlyOfPlayback() throws {
        let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 1, updatedAt: Date(), nowPlaying: makeNowPlaying())
        let failed = CompanionSnapshot(sessionID: snapshot.sessionID, sequence: snapshot.sequence, updatedAt: snapshot.updatedAt,
                                       nowPlaying: snapshot.nowPlaying, libraryError: "Saved library unavailable")
        XCTAssertNotEqual(failed, snapshot)
        XCTAssertEqual(failed.nowPlaying, snapshot.nowPlaying)
        XCTAssertNil(failed.nowPlaying?.errorMessage)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(snapshot)) as? [String: Any])
        object["libraryError"] = String(repeating: "Library detail ", count: 100)
        let decoded = try CompanionWire.decode(CompanionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let libraryError = try XCTUnwrap(decoded.libraryError)
        XCTAssertTrue(libraryError.hasSuffix("…"))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(libraryError).count - 2, CompanionWire.maximumTextBytes)
        XCTAssertEqual(decoded.nowPlaying, snapshot.nowPlaying)
        object["libraryError"] = 17
        XCTAssertThrowsError(try CompanionWire.decode(CompanionSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testSnapshotSuperLikeKeyIsRequiredAlwaysEncodedAndNeverTrueWithoutAFavorite() throws {
        let superLiked = makeNowPlaying(favorite: true, superLiked: true)
        XCTAssertTrue(superLiked.isSuperLiked)
        XCTAssertEqual(try CompanionWire.decode(CompanionNowPlaying.self, from: CompanionWire.encode(superLiked)), superLiked)
        for (favorite, tier) in [(false, false), (true, false), (true, true)] {
            let value = makeNowPlaying(favorite: favorite, superLiked: tier)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(value)) as? [String: Any])
            XCTAssertEqual(object["isFavorite"] as? Bool, favorite)
            XCTAssertEqual(object["isSuperLiked"] as? Bool, tier, "The tier is encoded even when false")
            XCTAssertEqual(try CompanionWire.decode(CompanionNowPlaying.self, from: JSONSerialization.data(withJSONObject: object)), value)
        }

        XCTAssertFalse(makeNowPlaying(favorite: false, superLiked: true).isSuperLiked, "A super like is a subset of favorites")
        XCTAssertEqual(makeNowPlaying(favorite: false, superLiked: true), makeNowPlaying(favorite: false, superLiked: false))
        XCTAssertFalse(CompanionNowPlaying(trackID: "recording-id", title: "Song", artist: "Artist", position: 0, duration: 0,
                                           isPlaying: false, isLoading: false, isFavorite: false, shuffleEnabled: false,
                                           repeatMode: .off).isSuperLiked, "The tier defaults to false")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(superLiked)) as? [String: Any])
        object["isFavorite"] = false
        let normalised = try CompanionWire.decode(CompanionNowPlaying.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(normalised.isFavorite)
        XCTAssertFalse(normalised.isSuperLiked, "A wire payload cannot claim a super like on an unliked song")

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(superLiked)) as? [String: Any])
        object.removeValue(forKey: "isSuperLiked")
        XCTAssertThrowsError(try CompanionWire.decode(CompanionNowPlaying.self, from: JSONSerialization.data(withJSONObject: object)),
                             "A version 1 snapshot without the tier is not a version 2 snapshot")
        for invalid: Any in [1, "true", NSNull(), [true]] {
            object["isSuperLiked"] = invalid
            XCTAssertThrowsError(try CompanionWire.decode(CompanionNowPlaying.self, from: JSONSerialization.data(withJSONObject: object)),
                                 "\(invalid)")
        }

        let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 3, updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         nowPlaying: superLiked)
        let decoded = try CompanionWire.decode(CompanionSnapshot.self, from: CompanionWire.encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.nowPlaying?.isSuperLiked, true)
        XCTAssertNotEqual(snapshot, CompanionSnapshot(sessionID: snapshot.sessionID, sequence: 3, updatedAt: snapshot.updatedAt,
                                                      nowPlaying: makeNowPlaying(favorite: true, superLiked: false)),
                          "The tier participates in snapshot equality")
    }

    func testSnapshotAccentRoundTripsEveryCaseAndIsOmittedWhenNil() throws {
        XCTAssertEqual(CompanionAccent.allCases.map(\.rawValue), ["coral", "mint", "ocean", "violet", "amber", "rose", "teal"])
        XCTAssertEqual(CompanionAccent.fallback, .coral)
        for accent in CompanionAccent.allCases {
            let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 4, updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                             nowPlaying: makeNowPlaying(), accent: accent)
            let data = try CompanionWire.encode(snapshot)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["accent"] as? String, accent.rawValue)
            XCTAssertEqual(try CompanionWire.decode(CompanionSnapshot.self, from: data), snapshot)
            let response = CompanionResponse(id: UUID(), accepted: true, snapshot: snapshot)
            XCTAssertEqual(try CompanionWire.decode(CompanionResponse.self, from: CompanionWire.encode(response)).snapshot.accent, accent)
        }
        let plain = CompanionSnapshot(sessionID: UUID(), sequence: 1, updatedAt: Date(), nowPlaying: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(plain)) as? [String: Any])
        XCTAssertNil(object["accent"])
        XCTAssertNotEqual(plain, CompanionSnapshot(sessionID: plain.sessionID, sequence: 1, updatedAt: plain.updatedAt,
                                                   nowPlaying: nil, accent: .coral), "The accent participates in equality")
    }

    func testMissingUnknownOrMistypedAccentDecodesToNilWithoutLosingTheSnapshot() throws {
        let id = UUID().uuidString
        let missing = Data("{\"sessionID\":\"\(id)\",\"sequence\":1,\"updatedAt\":0}".utf8)
        XCTAssertNil(try CompanionWire.decode(CompanionSnapshot.self, from: missing).accent)

        let snapshot = CompanionSnapshot(sessionID: UUID(), sequence: 2, updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                         nowPlaying: makeNowPlaying(), libraryError: "Library unavailable", accent: .teal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CompanionWire.encode(snapshot)) as? [String: Any])
        for invalid: Any in ["lime", "Coral", "", 3, true, NSNull(), ["coral"], ["value": "coral"]] {
            object["accent"] = invalid
            let decoded = try CompanionWire.decode(CompanionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(decoded.accent, "\(invalid)")
            XCTAssertEqual(decoded.nowPlaying, snapshot.nowPlaying, "\(invalid)")
            XCTAssertEqual(decoded.libraryError, snapshot.libraryError, "\(invalid)")
            XCTAssertEqual(decoded.sequence, snapshot.sequence, "\(invalid)")
        }
    }

    private func makeNowPlaying(title: String = "Song", artist: String = "Artist", position: Double = 12,
                                duration: Double = 240, favorite: Bool = true, superLiked: Bool = false,
                                error: String? = nil) -> CompanionNowPlaying {
        CompanionNowPlaying(trackID: "recording-id", title: title, artist: artist, position: position, duration: duration,
                            isPlaying: false, isLoading: true, isFavorite: favorite, isSuperLiked: superLiked, shuffleEnabled: true,
                            repeatMode: .all, errorMessage: error)
    }
}
