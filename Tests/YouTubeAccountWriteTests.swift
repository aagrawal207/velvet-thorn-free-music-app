import Foundation
import XCTest
@testable import GanaBajana

final class YouTubeAccountWriteTests: XCTestCase {
    func testRequestShapesForAllFiveExplicitActions() throws {
        let cases: [(YouTubeAccountWriteAction, String, String?, CatalogJSON)] = [
            (.like, YouTubeWriteFixtures.videoID, nil, ["target": ["videoId": "abcdefghijk"]]),
            (.removeLike, YouTubeWriteFixtures.videoID, nil, ["target": ["videoId": "abcdefghijk"]]),
            (.subscribe, YouTubeWriteFixtures.channelID, nil, ["channelIds": ["UCabcdefghijklmnopqrstuv"]]),
            (.unsubscribe, YouTubeWriteFixtures.channelID, nil, ["channelIds": ["UCabcdefghijklmnopqrstuv"]]),
            (.addToPlaylist, YouTubeWriteFixtures.videoID, YouTubeWriteFixtures.playlistID,
             ["playlistId": "PLfixture_owned", "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": "abcdefghijk"]]]),
        ]
        for (action, target, playlist, expected) in cases {
            let body = try YouTubeAccountWriteClient.mutationBody(action, targetID: target, playlistID: playlist)
            XCTAssertEqual(CatalogJSON.object(body), expected)
            let request = try YouTubeAccountWriteClient.request(endpoint: action.endpoint, body: body,
                version: YouTubeWriteFixtures.version, account: YouTubeWriteFixtures.account, now: YouTubeWriteFixtures.now)
            XCTAssertEqual(request.url?.path, "/youtubei/v1/" + action.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-YouTube-Client-Name"), "67")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://music.youtube.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Origin"), "https://music.youtube.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://music.youtube.com/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "SAPISIDHASH 1700000000_" + AccountFixtures.sha1Hex("1700000000 abc123 https://music.youtube.com"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            let sent = try CatalogJSON.decode(XCTUnwrap(request.httpBody))
            XCTAssertEqual(sent["context"]["client"]["clientName"].string, "WEB_REMIX")
        }
    }

    func testHostPathSchemePortAndUserInfoGuardStripsSecrets() throws {
        for url in ["https://www.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json",
                    "https://music.youtube.com.example.org/youtubei/v1/like/like?prettyPrint=false&alt=json",
                    "http://music.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json",
                    "https://music.youtube.com:443/youtubei/v1/like/like?prettyPrint=false&alt=json",
                    "https://user@music.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json",
                    "https://music.youtube.com/youtubei/v1/playlist/delete?prettyPrint=false&alt=json",
                    "https://music.youtube.com/youtubei/v1/like/%6Cike?prettyPrint=false&alt=json",
                    "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json&url=other",
                    "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json#other"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
            request.httpMethod = "POST"
            for name in ["Cookie", "Authorization", "X-Origin"] { request.setValue("stale-secret", forHTTPHeaderField: name) }
            XCTAssertThrowsError(try YouTubeWriteFixtures.account.applyMusicWriteAuth(to: &request, now: YouTubeWriteFixtures.now))
            for name in ["Cookie", "Authorization", "X-Origin"] { XCTAssertNil(request.value(forHTTPHeaderField: name)) }
        }
    }

    func testScopedCookiesExpiryInjectionAndFresh3PHash() throws {
        var account = YouTubeWriteFixtures.account
        account.cookies += [
            .init(name: "OTHER", value: "foreign", domain: "www.youtube.com"),
            .init(name: "EXPIRED", value: "old", domain: ".youtube.com", expires: YouTubeWriteFixtures.now),
            .init(name: "PATH", value: "wrong", domain: ".youtube.com", path: "/watch"),
            .init(name: "__Secure-3PAPISID", value: "third", domain: ".youtube.com"),
        ]
        var signatures = Set<String>()
        for seconds in [0.0, 1.0] {
            let request = try YouTubeAccountWriteClient.request(endpoint: "like/like", body: [:], version: YouTubeWriteFixtures.version,
                account: account, now: YouTubeWriteFixtures.now.addingTimeInterval(seconds))
            let header = try XCTUnwrap(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(header.contains("OTHER")); XCTAssertFalse(header.contains("EXPIRED")); XCTAssertFalse(header.contains("PATH"))
            let timestamp = 1_700_000_000 + Int(seconds)
            let signature = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(signature, "SAPISIDHASH \(timestamp)_" + AccountFixtures.sha1Hex("\(timestamp) third https://music.youtube.com"))
            signatures.insert(signature)
        }
        XCTAssertEqual(signatures.count, 2)
        account.cookies.append(.init(name: "BAD", value: "value\r\nCookie: injected", domain: ".youtube.com"))
        XCTAssertThrowsError(try YouTubeAccountWriteClient.request(endpoint: "like/like", body: [:], version: YouTubeWriteFixtures.version,
            account: account, now: YouTubeWriteFixtures.now))
    }

    func testForeignSourcesAndNonChannelBrowseIDsAreUnavailable() {
        for id in ["saavn:abcdefghijk", "gaana:abcdefghijk", "abcdefghij", "abcdefghijk!", " abcdefghijk"] {
            XCTAssertNil(YouTubeAccountWriteTarget.videoID(Track(id: id, title: "Fixture")))
        }
        for id in ["MPLAUCabcdefghijklmnopqrstuv", "MPADabcdefghijklmnopqrstuv", "saavn:artist:123", "UCshort", " UCabcdefghijklmnopqrstuv"] {
            XCTAssertNil(YouTubeAccountWriteTarget.channelID(.init(name: "Artist", id: id)))
        }
        XCTAssertNotNil(YouTubeAccountWriteTarget.channelID(YouTubeWriteFixtures.artist))
        XCTAssertNil(YouTubeAccountWriteTarget.channelID(.init(name: "Name Only")))
    }

    func testOnlyMatchingOwnedPlaylistMenuAndHeaderAreAccepted() throws {
        let root = YouTubeWriteFixtures.playlists(rows: [
            YouTubeWriteFixtures.playlistRow(id: YouTubeWriteFixtures.playlistID, owned: true),
            YouTubeWriteFixtures.playlistRow(id: "VLPLforeign", owned: false),
            YouTubeWriteFixtures.playlistRow(id: "VLLM", owned: true),
        ])
        XCTAssertEqual(try YouTubeAccountWriteParser.ownedPlaylists(root).items.map(\.id), [YouTubeWriteFixtures.playlistID])
        XCTAssertTrue(YouTubeAccountWriteParser.ownsPlaylist(YouTubeWriteFixtures.ownedHeader(), browseID: YouTubeWriteFixtures.playlistID))
        XCTAssertFalse(YouTubeAccountWriteParser.ownsPlaylist(YouTubeWriteFixtures.ownedHeader(id: "VLPLsomeone_else"), browseID: YouTubeWriteFixtures.playlistID))
        XCTAssertFalse(YouTubeAccountWriteParser.ownsPlaylist(["owned": true], browseID: YouTubeWriteFixtures.playlistID))
        XCTAssertThrowsError(try YouTubeAccountWriteParser.ownedPlaylists(YouTubeWriteFixtures.playlists(rows: [], continuation: String(repeating: "x", count: 65_537))))
    }

    func testAcknowledgementMustMatchTargetAndExpectedState() {
        XCTAssertTrue(YouTubeAccountWriteParser.addAcknowledged(YouTubeWriteFixtures.added, videoID: YouTubeWriteFixtures.videoID))
        XCTAssertFalse(YouTubeAccountWriteParser.addAcknowledged(["status": "STATUS_SUCCEEDED"], videoID: YouTubeWriteFixtures.videoID))
        XCTAssertFalse(YouTubeAccountWriteParser.addAcknowledged(YouTubeWriteFixtures.added, videoID: "wrongIDxxxx"))
        XCTAssertTrue(YouTubeAccountWriteParser.subscriptionAcknowledged(YouTubeWriteFixtures.subscription(), channelID: YouTubeWriteFixtures.channelID, subscribed: true))
        XCTAssertFalse(YouTubeAccountWriteParser.subscriptionAcknowledged(YouTubeWriteFixtures.subscription(), channelID: YouTubeWriteFixtures.channelID, subscribed: false))
        XCTAssertFalse(YouTubeAccountWriteParser.subscriptionAcknowledged(["actions": [["toast": "Done"]]], channelID: YouTubeWriteFixtures.channelID, subscribed: true))
        XCTAssertEqual(YouTubeAccountWriteParser.likeState(YouTubeWriteFixtures.likeState(liked: true), videoID: YouTubeWriteFixtures.videoID), true)
        XCTAssertEqual(YouTubeAccountWriteParser.likeState(YouTubeWriteFixtures.likeState(liked: false), videoID: YouTubeWriteFixtures.videoID), false)
        XCTAssertNil(YouTubeAccountWriteParser.likeState(YouTubeWriteFixtures.likeState(liked: true, signedIn: false), videoID: YouTubeWriteFixtures.videoID))
        XCTAssertNil(YouTubeAccountWriteParser.likeState(YouTubeWriteFixtures.likeState(liked: true, videoID: "otherxxxxxx"), videoID: YouTubeWriteFixtures.videoID))
    }

    func testMalformedUnknownAndGatedHTTP200NeverConfirmsOrRetries() async throws {
        for text in ["not json", "{}", #"{"status":"STATUS_UNKNOWN","actions":[{}]}"#,
                     #"{"status":true,"actions":[{}]}"#,
                     #"{"actions":[{"showEngagementPanelEndpoint":{"identifier":{"tag":"GATE"}}}]}"#] {
            let mock = CatalogMockSession { _ in CatalogStub(data: Data(text.utf8)) }
            defer { mock.close() }
            let client = makeClient(mock)
            do {
                try await client.perform(.subscribe, targetID: YouTubeWriteFixtures.channelID, playlistID: nil, access: YouTubeWriteFixtures.access)
                XCTFail("Malformed/unknown response confirmed")
            } catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .couldNotConfirm) }
            XCTAssertEqual(mock.state.requests.count, 1)
        }
    }

    func testAmbiguousNetworkAndServerFailureHaveOneAttempt() async throws {
        for code in [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet] {
            let mock = CatalogMockSession { _ in throw URLError(code) }
            defer { mock.close() }
            do { try await makeClient(mock).perform(.like, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: YouTubeWriteFixtures.access); XCTFail() }
            catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .couldNotConfirm) }
            XCTAssertEqual(mock.state.requests.count, 1)
        }
        let mock = CatalogMockSession { _ in CatalogStub(status: 503, data: Data("{}".utf8)) }
        defer { mock.close() }
        do { try await makeClient(mock).perform(.like, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: YouTubeWriteFixtures.access); XCTFail() }
        catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .couldNotConfirm) }
        XCTAssertEqual(mock.state.requests.count, 1)
    }

    func testAuthorizationRejectionAndRateLimit() async throws {
        for code in [401, 403, 429] {
            let mock = CatalogMockSession { _ in CatalogStub(status: code, headers: ["Content-Type": "application/json", "Retry-After": "120"], data: Data("{}".utf8)) }
            defer { mock.close() }
            let client = makeClient(mock)
            do { try await client.perform(.like, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: YouTubeWriteFixtures.access); XCTFail() }
            catch { XCTAssertEqual(error as? YouTubeAccountWriteError, code == 429 ? .rateLimited : .unauthorized) }
            if code == 429 {
                do { try await client.perform(.like, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: YouTubeWriteFixtures.access); XCTFail() }
                catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .rateLimited) }
            }
            XCTAssertEqual(mock.state.requests.count, 1)
        }
        XCTAssertThrowsError(try YouTubeAccountWriteParser.validateEnvelope(["error": ["status": "UNAUTHENTICATED"]]))
        XCTAssertThrowsError(try YouTubeAccountWriteParser.validateEnvelope(["responseContext": ["mainAppWebResponseContext": ["loggedOut": true]]]))
    }

    func testPlaylistOwnershipIsRecheckedBeforeAnyMutation() async throws {
        let mock = CatalogMockSession { _ in CatalogStub(data: try YouTubeWriteFixtures.ownedHeader(id: "VLPLsomeone_else").encoded()) }
        defer { mock.close() }
        do {
            try await makeClient(mock).perform(.addToPlaylist, targetID: YouTubeWriteFixtures.videoID, playlistID: YouTubeWriteFixtures.playlistID, access: YouTubeWriteFixtures.access)
            XCTFail()
        } catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .notOwned) }
        XCTAssertEqual(mock.state.requests.map { $0.url?.path }, ["/youtubei/v1/browse"])
    }

    func testPlaylistAddAndLikeUseIndependentAcknowledgement() async throws {
        let add = CatalogMockSession { request in
            CatalogStub(data: try (request.url?.path == "/youtubei/v1/browse" ? YouTubeWriteFixtures.ownedHeader() : YouTubeWriteFixtures.added).encoded())
        }
        defer { add.close() }
        try await makeClient(add).perform(.addToPlaylist, targetID: YouTubeWriteFixtures.videoID, playlistID: YouTubeWriteFixtures.playlistID, access: YouTubeWriteFixtures.access)
        XCTAssertEqual(add.state.requests.count, 2)
        for liked in [true, false] {
            let like = CatalogMockSession { request in
                let root: CatalogJSON = request.url?.path == "/youtubei/v1/next" ? YouTubeWriteFixtures.likeState(liked: liked) : ["actions": [["fixtureAction": [:]]]]
                return CatalogStub(data: try root.encoded())
            }
            defer { like.close() }
            try await makeClient(like).perform(liked ? .like : .removeLike, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: YouTubeWriteFixtures.access)
            XCTAssertEqual(like.state.requests.count, 2)
        }
    }

    func testOwnedPlaylistPaginationAndRepeatedCursorBound() async throws {
        let mock = CatalogMockSession { request in
            let body = try CatalogJSON.decode(request.httpBody ?? Data())
            let continued = body["continuation"].string != nil
            let root = YouTubeWriteFixtures.playlists(rows: [YouTubeWriteFixtures.playlistRow(id: continued ? "VLPLsecond" : YouTubeWriteFixtures.playlistID, owned: true)], continuation: continued ? nil : "second", continued: continued)
            return CatalogStub(data: try root.encoded())
        }
        defer { mock.close() }
        let result = try await makeClient(mock).ownedPlaylists(access: YouTubeWriteFixtures.access)
        XCTAssertEqual(result.items.map(\.id), [YouTubeWriteFixtures.playlistID, "VLPLsecond"])
        XCTAssertFalse(result.isLimited)
        XCTAssertEqual(mock.state.requests.count, 2)

        let repeated = CatalogMockSession { _ in CatalogStub(data: try YouTubeWriteFixtures.playlists(rows: [], continuation: "same").encoded()) }
        defer { repeated.close() }
        do { _ = try await makeClient(repeated).ownedPlaylists(access: YouTubeWriteFixtures.access); XCTFail() }
        catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .unreadable) }
        XCTAssertEqual(repeated.state.requests.count, 2)
    }

    func testDeclaredAndChunkedOversizeResponsesAreRejected() async throws {
        for declaresLength in [true, false] {
            let mock = CatalogMockSession { _ in
                var headers = ["Content-Type": "application/json"]
                if declaresLength { headers["Content-Length"] = String(YouTubeAccountWriteTransfer.maximumBytes + 1) }
                return CatalogStub(headers: headers, data: Data(repeating: 32, count: YouTubeAccountWriteTransfer.maximumBytes + 1))
            }
            defer { mock.close() }
            do { try await makeClient(mock).perform(.subscribe, targetID: YouTubeWriteFixtures.channelID, playlistID: nil, access: YouTubeWriteFixtures.access); XCTFail() }
            catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .couldNotConfirm) }
            XCTAssertEqual(mock.state.requests.count, 1)
        }
    }

    func testRedirectDelegateRefusesEvenSameHost() throws {
        let session = YouTubeAccountWriteClient.accountSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://music.youtube.com/youtubei/v1/like/like?prettyPrint=false&alt=json")!
        let transfer = YouTubeAccountWriteTransfer(expectedURL: url)
        let task = session.dataTask(with: url)
        for destination in [url, URL(string: "https://example.org/collect")!] {
            let recorder = CatalogTestRecorder<Bool>()
            transfer.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: destination)) { recorder.record($0 == nil) }
            XCTAssertEqual(recorder.values, [true])
        }
        task.cancel()
    }

    func testRetiredAccessNeverStartsARequest() async throws {
        let mock = CatalogMockSession { _ in XCTFail("Retired access sent a request"); return CatalogStub(data: Data("{}".utf8)) }
        defer { mock.close() }
        let access = YouTubeWriteFixtures.access
        access.retire()
        do { try await makeClient(mock).perform(.like, targetID: YouTubeWriteFixtures.videoID, playlistID: nil, access: access); XCTFail() }
        catch { XCTAssertEqual(error as? YouTubeAccountWriteError, .retired) }
        XCTAssertTrue(mock.state.requests.isEmpty)
    }

    private func makeClient(_ mock: CatalogMockSession) -> YouTubeAccountWriteClient {
        YouTubeAccountWriteClient(session: mock.session, version: { YouTubeWriteFixtures.version }, now: { YouTubeWriteFixtures.now })
    }
}

@MainActor
final class YouTubeAccountWriteControllerTests: XCTestCase {
    func testLegacySessionDecodesButRequiresReconnectForWrites() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(YouTubeWriteFixtures.account)) as! [String: Any]
        json.removeValue(forKey: "writeSessionID")
        let data = try JSONSerialization.data(withJSONObject: json)
        let secrets = MemorySecretStore(initial: [YouTubeAccountStore.secretKey: data])
        let account = makeAccount(secrets: secrets)
        XCTAssertTrue(account.isSignedIn)
        XCTAssertNil(account.session?.writeSessionID)
        let controller = makeController(account)
        controller.setAllowsChanges(true)
        XCTAssertFalse(controller.allowsChanges)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.notSignedIn.localizedDescription)
        XCTAssertEqual(try secrets.read(YouTubeAccountStore.secretKey), data)
        controller.shutdown()
    }

    func testSignedOutOptOutAndOfflineNeverReachTransport() async throws {
        let account = makeAccount()
        let stub = YouTubeWriteStubClient()
        let controller = makeController(account, client: stub)
        controller.perform(.like, track: YouTubeWriteFixtures.track, context: controller.context)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.notSignedIn.localizedDescription)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        controller.perform(.like, track: YouTubeWriteFixtures.track, context: controller.context)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.notOptedIn.localizedDescription)
        let calls = await stub.calls
        XCTAssertEqual(calls, 0)
        let offline = YouTubeAccountWriteController(account: account, permissions: .init(secrets: MemorySecretStore()), client: stub, isOffline: { true })
        offline.setAllowsChanges(true)
        offline.perform(.like, track: YouTubeWriteFixtures.track, context: offline.context)
        XCTAssertEqual(offline.message, YouTubeAccountWriteError.offline.localizedDescription)
        let offlineCalls = await stub.calls
        XCTAssertEqual(offlineCalls, 0)
        controller.shutdown(); offline.shutdown()
    }

    func testPermissionSurvivesSameSessionButNotAccountOrDeviceReplacement() throws {
        let accountSecrets = MemorySecretStore()
        let account = makeAccount(secrets: accountSecrets)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let secrets = MemorySecretStore()
        let first = makeController(account, secrets: secrets)
        XCTAssertFalse(first.allowsChanges)
        first.setAllowsChanges(true)
        XCTAssertTrue(first.allowsChanges)
        let reloadedAccount = makeAccount(secrets: accountSecrets)
        let reloaded = makeController(reloadedAccount, secrets: secrets)
        XCTAssertTrue(reloaded.allowsChanges)
        let differentDevice = makeController(reloadedAccount)
        XCTAssertFalse(differentDevice.allowsChanges)
        XCTAssertTrue(account.signOut())
        XCTAssertFalse(first.allowsChanges)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        XCTAssertFalse(first.allowsChanges)
        first.shutdown(); reloaded.shutdown(); differentDevice.shutdown()
    }

    func testStrictPermissionRecordsAndConcurrentEditsArePreserved() throws {
        for data in [Data("broken".utf8), Data(#"{"version":2,"allow":false,"generation":"72B807DC-F2D3-440C-85E0-1FE1B5D69654"}"#.utf8),
                     Data(#"{"version":1,"allow":"true","generation":"72B807DC-F2D3-440C-85E0-1FE1B5D69654"}"#.utf8)] {
            let secrets = MemorySecretStore(initial: ["permission": data])
            let store = YouTubeAccountWritePermissionStore(secrets: secrets)
            XCTAssertThrowsError(try store.setAllowed(true, sessionID: UUID()))
            XCTAssertEqual(try secrets.read("permission"), data)
        }
        let secrets = MemorySecretStore()
        let first = YouTubeAccountWritePermissionStore(secrets: secrets)
        _ = try first.setAllowed(true, sessionID: UUID())
        let other = YouTubeAccountWritePermissionStore(secrets: secrets)
        let off = try other.setAllowed(false, sessionID: nil)
        XCTAssertThrowsError(try first.setAllowed(true, sessionID: UUID()))
        XCTAssertEqual(try other.read(), off)
    }

    func testFailedRevokeDisablesInMemoryAndShowsRetryError() throws {
        let account = makeAccount()
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let secrets = YouTubeWriteFailingSecrets()
        let controller = YouTubeAccountWriteController(account: account, permissions: .init(secrets: secrets), client: YouTubeWriteStubClient())
        controller.setAllowsChanges(true)
        XCTAssertTrue(controller.allowsChanges)
        secrets.failWrites()
        controller.setAllowsChanges(false)
        XCTAssertFalse(controller.allowsChanges)
        XCTAssertNotNil(controller.permissionError)
        controller.shutdown()
    }

    func testDuplicateTapsAreDroppedAndSessionSwitchRetiresStaleCompletion() async throws {
        let account = makeAccount()
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let stub = YouTubeWriteStubClient(held: true)
        let controller = makeController(account, client: stub)
        controller.setAllowsChanges(true)
        let old = controller.context
        controller.perform(.like, track: YouTubeWriteFixtures.track, context: old)
        controller.perform(.like, track: YouTubeWriteFixtures.track, context: old)
        for _ in 0..<100 {
            if await stub.calls > 0 { break }
            await Task.yield()
        }
        let calls = await stub.calls
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(account.signOut())
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        controller.setAllowsChanges(true)
        controller.perform(.like, track: YouTubeWriteFixtures.track, context: old)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.retired.localizedDescription)
        await stub.release()
        await Task.yield()
        XCTAssertNotEqual(controller.message, "Confirmed on YouTube.")
        controller.shutdown()
    }

    func testRevokeCancelsRealFakeSessionTransferAndNeverConfirms() async throws {
        let mock = CatalogMockSession { _ in CatalogStub(data: try YouTubeWriteFixtures.subscription().encoded(), delay: 5) }
        defer { mock.close() }
        let account = makeAccount()
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let client = YouTubeAccountWriteClient(session: mock.session, version: { YouTubeWriteFixtures.version })
        let controller = makeController(account, client: client)
        controller.setAllowsChanges(true)
        controller.setSubscribed(true, artist: YouTubeWriteFixtures.artist, context: controller.context)
        for _ in 0..<200 {
            if !mock.state.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(mock.state.requests.count, 1)
        controller.setAllowsChanges(false)
        for _ in 0..<200 {
            if mock.state.cancellations > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(mock.state.cancellations, 0)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.couldNotConfirm.localizedDescription)
        XCTAssertFalse(controller.allowsChanges)
        controller.shutdown()
    }

    func testPlaylistSelectionRequiresFreshListFromThisContext() async throws {
        let account = makeAccount()
        XCTAssertTrue(account.signIn(cookies: AccountFixtures.signedIn))
        let stub = YouTubeWriteStubClient()
        let controller = makeController(account, client: stub)
        controller.setAllowsChanges(true)
        controller.perform(.addToPlaylist, track: YouTubeWriteFixtures.track, playlist: YouTubeWriteFixtures.playlist, context: controller.context)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.notOwned.localizedDescription)
        controller.loadOwnedPlaylists(context: controller.context)
        for _ in 0..<100 where controller.isBusy { await Task.yield() }
        XCTAssertEqual(controller.playlists.map(\.id), [YouTubeWriteFixtures.playlistID])
        let wrong = MusicCollection(id: "VLPLforeign", title: "Foreign")
        controller.perform(.addToPlaylist, track: YouTubeWriteFixtures.track, playlist: wrong, context: controller.context)
        XCTAssertEqual(controller.message, YouTubeAccountWriteError.notOwned.localizedDescription)
        let old = controller.context
        controller.cancel()
        XCTAssertTrue(controller.playlists.isEmpty)
        controller.perform(.addToPlaylist, track: YouTubeWriteFixtures.track, playlist: YouTubeWriteFixtures.playlist, context: old)
        let calls = await stub.calls
        XCTAssertEqual(calls, 1)
        controller.shutdown()
    }

    private func makeAccount(secrets: MemorySecretStore = .init()) -> YouTubeAccountStore {
        YouTubeAccountStore(secrets: secrets, registry: YouTubeSessionRegistry())
    }

    private func makeController(_ account: YouTubeAccountStore, secrets: MemorySecretStore = .init(),
                                client: any YouTubeAccountWriteProviding = YouTubeWriteStubClient()) -> YouTubeAccountWriteController {
        .init(account: account, permissions: .init(secrets: secrets), client: client)
    }
}
