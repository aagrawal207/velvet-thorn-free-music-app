# Gana Bajana patch notes for YouTubeKit

Upstream: https://github.com/alexeichhorn/YouTubeKit, version 0.4.9, revision e5b7d0396ce12bf3444f0d209e8436c83373b7af (MIT, see LICENSE).

Why vendored: `InnerTube` builds its own `URLRequest` and `YouTube.videoInfos` hard-codes the clients it queries, so optional YouTube sign-in needs hooks for account cookies and SAPISIDHASH on the TVHTML5 player client. The local tree also includes extraction compatibility fixes. CI config, `Scripts/` and dotfiles were dropped.

## Account and reviewed security patches

- `Sources/YouTubeKit/YouTubeKitHooks.swift`: exposes `requestDecorator` and `includesTVClient`. Decoration is restricted to TVHTML5 player requests.
- `Sources/YouTubeKit/InnerTube.swift`: applies the decorator after client headers and disables request cookie handling. The session and decorator can be injected for isolated tests.
- `Sources/YouTubeKit/ExtractionTransport.swift` and `ExtractionDataDelegate.swift`: supply cookie-free ephemeral sessions and per-task receipt limits. `InnerTube`, watch/embed HTML, player JavaScript, and remote extraction use explicit response budgets (SEC-2, SEC-4).
- `Sources/YouTubeKit/YouTube.swift`: `videoInfos` queries `[.visionOS, .web, .tv]` when `includesTVClient()` is true, otherwise `[.visionOS, .web]`.
- `Sources/YouTubeKit/Models/ITag.swift`: adds itag `774` (WebM Opus, about 256 kbps) to the DASH audio table. `Stream(format:)` drops formats with an unknown itag, so without this row a Premium high-quality Opus format returned to the signed-in TVHTML5 lookup would never reach the app's ranking. Itag `141` (AAC 256 kbps) was already listed. No client, header, or cookie behaviour changes; availability still depends on what YouTube returns for the account.
- `Sources/YouTubeKit/Remote/RemoteYouTubeClient.swift` and `Extensions/URLSessionDelegates.swift`: remote requests and redirected requests disable automatic cookies. Explicit remote-protocol redirect cookies remain request-scoped. Remote chunk-size validation runs before the requested HTTP work.
- `Sources/YouTubeKit/Remote/Chunking.swift`: accepts optional chunk sizes from 1 byte through 1 MiB. Invalid sizes throw `RemoteChunkingError.invalidChunkSize` before encoding. Quotient/remainder ceiling division, checked UInt32 header counts, and remaining-byte slice bounds avoid division and overflow traps (SEC-3).
- `Sources/YouTubeKit/SignatureSolver.swift` and `Errors.swift`: solver diagnostics emit only `javascript_exception`, `invalid_response`, or `challenge_rejected` categories. JavaScript exception text, malformed result batches, and decoder/provider error payloads are discarded from diagnostics and thrown errors. `jsonDecodingFailed` and `solverError` are payload-free enum cases (SEC-5).
- `Sources/YouTubeKit/Extensions/AsyncCompatibility.swift`: shares the lock-protected task cancellation holder with the receipt-limited reader and marks completion handlers `@Sendable`. Extraction no longer uses the completion-body shims.
- `Sources/YouTubeKit/Extensions/Concurrency.swift`: uses ordered task-group results so cancelling a full lookup cancels its player requests. An individual player size rejection still permits valid sibling results.

The host app's `YouTubeAccountStore` purges legacy YouTube-domain cookies from its own shared cookie jar on production load and sign-out. Credentials stay in the device-only Keychain. A credential-free, atomic pending-sign-out file prevents reactivation after failed deletion; injected account fixtures use independent memory intent stores by default.

## Receipt-time resource budgets

| HTTP resource | Maximum received body | Elapsed deadline per request |
| --- | ---: | ---: |
| Watch and embed HTML | 4,000,000 bytes | 30 seconds |
| InnerTube JSON, including player responses | 4,000,000 bytes | 30 seconds |
| Player JavaScript | 12,000,000 bytes | 45 seconds |
| Server-directed remote HTTP responses | 8,000,000 bytes | 45 seconds |

The HTML and player limits match the app's fast-path limits, so falling through to full extraction cannot bypass them. JavaScript has more room for larger player bundles. Remote bodies have a smaller limit because JSON encoding retains the body and adds a base64 copy: 8,000,000 bytes become at most 10,666,668 base64 bytes, plus the JSON metadata. The remote encoder disables slash escaping to avoid doubling slash-heavy base64.

`URLSessionDataDelegate` rejects an excessive declared length before accepting the body and checks each received data chunk before appending. Unknown or understated lengths receive the same cumulative limit. Declared length is not an EOF equality requirement because transfer decoding can change the byte count. The implementation supports the package's existing iOS 13/macOS 10.15 availability without a completion-buffering fallback.

A per-task timer covers headers, redirects, and the body; arriving bytes do not reset it. Sessions also cap the resource timeout at 45 seconds, and requests cap the inactivity timeout at 15 seconds. Overflow throws the payload-free `ExtractionTransportError.responseTooLarge`; elapsed deadlines throw `URLError.timedOut`; caller cancellation becomes `CancellationError`. Rejection cancels the affected data task, not its shared session. Remote extraction also cancels its WebSocket task when its caller cancels.

`ExtractionTransport.data` requires a `Budget`. `makeSession` creates reusable bounded sessions. Existing injected ordinary `URLSession` instances remain supported through an owned bounded session that copies their configuration and forwards redirect policy, with automatic cookies and caches disabled. The public `YouTube` initializers keep their existing arguments; an internal session-injected initializer forwards the fixture session through full extraction. `RemoteYouTubeClient.response(for:)` exposes the shared bounded HTTP stage internally for tests before response encoding.

## Data-Only Extractor Compatibility

`ExtractionCompatibility.swift` adds a validated immutable rule model and a lock-protected registry exposed through `YouTubeKitHooks.extractionCompatibility` and `installExtractionCompatibility(_:)`. The host publishes only after durable package acceptance. Rules allow literal timestamp/visitor field names and bounded native signature/throttling transform plans pinned to the SHA-256 of the original player source. No update-supplied JavaScript, native code, regex, endpoint or header is accepted.

`Extraction.extractSignatureTimestamp` tries configured field aliases before bundled matching. The host fast path consumes the visitor aliases. `SignatureSolver.batchSolve`, the current `Extraction.applySignature` path, applies exact-player plans and delegates missing challenge types to bundled yt-ejs. Operations are reverse, drop-first, swap-first and rotate-left, bounded by 64 steps, 4,096-byte ASCII challenges and a 65,536-byte batch total when a player rule matches. Solver snapshots reject a changed registry generation before returning. `Cipher` remains the legacy implementation and is not the update entry point.

`ExtractorCompatibilityTests` covers a renamed existing timestamp fixture, native operation/input bounds, the actual manifest signature application path, mismatched player hashes, rollback, stale solver generations and partial bundled fallback. XCTest solver test types carry the availability of the compatibility/CryptoKit API. No package resources or license text changed. Host package trust, persistence, Files UI and coordinator wiring are documented in [`docs/EXTRACTOR_UPDATES.md`](../../docs/EXTRACTOR_UPDATES.md). This worker did not run builds or tests for the extractor update changes.

### Swift Testing Suite Compatibility (Test-Only)

The coordinator reported that the filtered `ExtractorCompatibilityTests` invocation could not compile the full vendor test target: Xcode 27's Swift Testing `@Test` macro rejected the enclosing `NSigTests` suite's explicit iOS 13/watchOS 6/tvOS 13/macOS 10.15 availability. `SignatureTests` had the same annotation. Those suite annotations were introduced during the extractor compatibility work, not inherited from upstream.

The test-only correction removes the two obsolete suite attributes. `Package.swift` has no active `platforms` override; the coordinator's current test compilation targets macOS 14, above the solver/CryptoKit macOS 10.15 floor and the async URLSession macOS 12 floor. No runtime early-return guard is needed for that target. All existing parameterized cases, assertions and function-local availability checks remain intact. No tests were disabled or excluded, and no production source or package deployment settings changed. This correction was source-reviewed only; the coordinator owns the rerun and its results.

## Prepared Signature Solver Reuse

`Sources/YouTubeKit/SignatureSolverCache.swift` holds the JavaScriptCore setup that `SignatureSolver.init` used to repeat for every client response: shims, meriyah, astring and yt-ejs. `PreparedSignaturePlayer` is one context per player script. The raw player is set once as a JS string; the first solve asks yt-ejs for `output_preprocessed`, keeps the result in the context and drops the raw script. Later solves pass `type: "preprocessed_player"`, so meriyah/astring do not run again and the player is never JSON-encoded. This uses yt-ejs's own `main` input contract, unchanged. Only the small challenge list crosses the bridge, through `call(withArguments:)`. One lock per context serializes every JavaScript call. Different players can run in parallel.

`SignatureSolverCache.shared` is a process-wide LRU of 2 contexts keyed by exact player source. String equality short-circuits on the shared `YouTube.__js` storage. A `DispatchSource` memory-pressure source (warning and critical) empties it. `YouTubeKitHooks.releaseSignatureSolverCache()` lets the host drop it too. Each entry retains its player string and preprocessed heap. A rollover keeps the old player until it ages out.

`SignatureSolver` stays a per-call object. It still captures the compatibility snapshot at construction and checks generations before and after solving, applies native rule-package transforms first, and asks JavaScript only for the remaining challenge types. A batch fully covered by rules builds no context. Injected test contexts never enter the cache. When a solve fails on a context, that context is evicted. If the context had already solved successfully, the batch retries once on a fresh context. A first-use failure is thrown as before, because it would repeat for the same script, and `YouTube.streams` keeps its own re-download retry.

Metric (`os_log`, info): `event=signature_solver reuse=<0|1> prepare_ms=<n> solve_ms=<n> preprocessed=<0|1> outcome=<success|failure>`, plus `event=signature_solver_evicted reason=<capacity|failure|memory_pressure|released>`. No URL, hash, challenge or player text is logged. `SignatureSolverReuseTests` covers reuse, equal-content keys, parity with the upstream single-shot input, concurrent serialization, failure eviction with and without retry, LRU order, release, and rule-package semantics, using a synthetic player that the bundled yt-ejs accepts. Real players are covered by the network-backed `NSigTests` and `SignatureTests`, which now go through the shared cache.

## Earlier Regression Coverage

Added vendor tests:
- `ITagsTests.testPremiumAudioTiersAreKnownDashAudio`: itags 141 and 774 resolve as 256 kbps DASH audio alongside 140 and 251 (`swift test --filter ITagsTests`, macOS host).
- `ExtractionTransportTests`: sentinel `Set-Cookie` responses, pre-existing jar cookies, TV-only manual authentication, and subsequent signed-out requests. The fixture uses an isolated URLSession protocol rather than provider traffic.
- `RemoteChunkingTests`: zero, negative, `Int.max`, oversized chunks, exact/remainder boundaries, UInt32 count limits, and rejection before encoding or sending.
- `SignatureSolverDiagnosticTests`: malformed batches containing signed material, JavaScript exceptions, provider-controlled error text, and valid solution maps.
- `BoundedExtractionTransportTests`: excessive declared lengths, unknown/understated lengths, coalesced chunks, exact boundaries, partial failures, cancellation before headers/EOF, headerless and slow-drip deadlines, same-URL siblings, and ordinary injected sessions.
- `ExtractionBudgetIntegrationTests`: actual watch/embed/player/JavaScript budgets, simulated caller fallthrough into `YouTube.streams`, valid player siblings, parent cancellation, all remote redirect modes, and bounded base64 expansion. `ExtractionStreamingTestSupport.swift` releases headers, chunks, and EOF independently; cancellation assertions occur before EOF.

Host tests in `Tests/AccountSignOutTests.swift`, `Tests/AccountAuthBridgeTests.swift`, and `Tests/AccountSignInTests.swift` cover durable retry, scoped cookie cleanup, request-header removal, cancelled/deferred capture, and navigation-error retry in the same non-persistent web store.

Validation by this worker is source inspection and Swift syntax parsing only. The coordinator owns builds, execution, and native test evidence. Vendor XCTest cases run separately from the app's unit-test scheme; a zero-test Swift Testing export does not represent these XCTest results.

To update: reconcile the complete local diff with the new upstream tree, retain the account/security behavior above and existing extraction fixes, then update the upstream version here and in `Resources/Acknowledgements.txt`. Preserve `LICENSE` verbatim.
