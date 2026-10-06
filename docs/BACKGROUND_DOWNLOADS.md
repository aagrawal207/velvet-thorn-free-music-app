# Background Downloads

## Status

R17 background downloads are implemented and integrated. Production construction, launch restoration, app-delegate reconnection and phone lifecycle are connected. The coordinator reports Core-03 and Integration-03 passing; [VERIFICATION.md](VERIFICATION.md) owns receipt details. Real OS suspension, termination and locked-device delivery remain unverified.

The existing `DownloadManager(store:transfer:...)` initializer remains available for foreground fixtures. Production uses `DownloadManager.background(store:planner:connectivity:allowCellular:queueFile:)` for OS-owned transfers.

The integrated app and test targets include the background-download implementation and coverage.

## Execution and Storage

`SystemBackgroundDownloadSession` uses `URLSessionConfiguration.background(withIdentifier:)` with the stable identifier `com.agraabhi.ganabajana.downloads.v1`. It enables launch events and connectivity waiting, disables discretionary scheduling, cookies and response caching, and creates suspended download tasks before resuming them. The identifier must remain unchanged across launches and app updates. Create one production manager/session per process, not one per window.

The scheduler admits at most two transfers or preparation workers combined. Cancelled transfers retain their slots until the OS completion callback. Each automatic cycle has at most three attempts, with 2-second and 6-second retry delays. Attempt counts and retry dates survive relaunch. Manual Retry starts a new cycle. Cellular-policy replacements and resolution cancelled by a lifecycle transition do not consume another failed attempt. Transient planning failures (a timed-out lookup, no candidate answering its probe, a superseded fetch, HTTP 429/5xx, dropped or missing network) do not spend an attempt either: they wait 5, 15, 45 and 120 seconds, per song and per session, before counting normally. Losing the network during planning parks the song until connectivity returns.

The existing `downloads-queue.json` accepts version 1 ID lists and writes version 2 background records. Each record contains the recording ID, a random operation token, attempt count, phase, retry/expiry dates, cellular policy, bounded failure category and URL-free `AudioCache.Sidecar` acquisition fields. Track display metadata is resolved through the existing library lookup. Files with an unsupported version, duplicate or invalid IDs, inconsistent records, or more than 2 MiB are preserved and block new submission. The queue holds at most 2,000 recordings. An empty version 2 queue remains as an atomic empty record.

Signed URLs and URLSession resume data are never written or logged by the app. Resolved plans live in memory. The OS necessarily retains the request URL inside its background task, including signed query parameters; this is outside the app's queue and cache persistence. Resume data is deliberately unused because it can contain the same URL. Errors crossing the delegate boundary are fixed enum values, not `NSError` descriptions or `userInfo`.

`Application Support/GanaBajana/DownloadStaging` holds token-named files and receipts, excluded from backup. The delivery delegate validates the HTTP status, content type, identity encoding, complete response/range length, regular-file size and media prefix. It copies the temporary file, synchronizes its owned copy and atomically writes a URL-free receipt **before `didFinishDownloadingTo` returns**. No asynchronous task owns URLSession's temporary location. Startup prunes unreferenced token files only after successfully reading and reconciling the queue.

Accepted files are bounded by `AudioCache.maximumFileBytes` (64 MiB). A declared YouTube `clen` above the limit is rejected before submission. Progress callbacks cancel oversized responses, and delivery rejects any oversized file. Background URLSession offers no hard maximum-response-byte setting: while the app is suspended, the OS can receive more bytes before a delegate callback can enforce this limit. Resource timeout is six hours. Staged deliveries and active cache preparation are separate storage: published downloads and cache preparation use the existing cache inventory, while delivery receipts are temporary acquisition storage.

## Resolution and Publication

Before planning, a song whose cache copy is already being written (the song that just started playing) waits up to 90 seconds for that copy and then promotes it, without a second lookup or transfer. `YouTubeStreamResolver.backgroundDownloadPlan(for:)` then waits for any lookup already in flight for the song and reuses the player's validated link when it has more than 90 seconds left; a second simultaneous lookup for one video is what made an immediate Download after Play time out. Otherwise it reads the fast-path `streams` and `aacFallbacks`. It prefers ranked AAC/progressive candidates over Opus within the quality ceiling. A fitting Opus takes precedence over above-ceiling AAC; when nothing fits, the shared lowest-offered-first rule applies. It probes up to three AAC candidates and retains up to three Opus candidates as fallback. It does not call `download`, `select(...complete: true)` or prepare Opus during planning. If the fast path cannot supply a usable file, the existing bounded YouTubeKit extractor supplies file candidates; the optional remote extractor remains opt-in. JavaScript extraction requires app runtime, but the resulting YouTube file transfer still uses the background session.

`CompositeStreamResolver.backgroundDownloadPlan(for:)` routes bare YouTube IDs to that API. Prefixed IDs reuse the provider's current link when it still makes a valid plan and otherwise force a fresh resolution. JioSaavn progressive files are eligible. Gaana's own HLS playlists are rejected. A provider fallback is eligible only when it returns a downloadable remote file. HLS or DASH manifests, including text responses at an extensionless URL, never produce a Downloaded badge. No asset-download/HLS storage feature is implied.

Plans require more than 90 seconds of remaining validity at submission. A stale reattached task, expiry detected when returning to the foreground, or HTTP 401/403/410 retires its old token. New extraction waits for the foreground and remains within the persisted attempt budget. Already delivered bytes do not need their source URL to remain valid.

`AudioCache.publishBackgroundDownload(track:part:metadata:fence:)` copies the staged input into cache-owned preparation storage and holds a reader lease while inspecting it. AAC/WAV requires a playable audio-only asset, a valid duration and actual native PCM output. A known duration must match within the larger of three seconds or two percent. WebM uses the existing `prepareOpus` implementation, which packet-copies through FFmpegBridge and verifies native PCM output; publication requires the existing sample-rate, channel and decoded-output checks. The system Opus support gate remains in the YouTube candidate selector.

Native inspection supplies `AVURLAssetOverrideMIMETypeKey` from the checked delivery format (`audio/wav` or `audio/mp4`). Cache preparation files intentionally end in `.part`, so their names cannot identify the parser. The hint selects a parser only; playable audio, codec, duration and PCM-output validation still apply.

Final publication uses `AudioDownloader.publish`, immutable Opus variant names, the cache's sidecar format and the existing download-tier deduplication/readers. A cache-generation check and `DownloadPublicationFence` protect the final synchronous publication. Cache maintenance retains inspection inputs until their reader exits and rejects a stale writer afterward. A complete cached copy can be promoted offline without extraction. A validated new delivery publishes directly into the permanent tier, avoiding an eviction window between admission and promotion.

The queue retires the ID and sends `onTierChange(id, true)` only after the store confirms a downloaded copy and the updated queue saves. A failed queue acknowledgement leaves the pending record for recovery. Publication failure retains the safe delivery and exposes Failed; explicit Retry reuses the bytes. A failed staged delivery does not retry itself at launch.

## Lifecycle and Visible State

OS transfers can continue while the app is suspended. Extraction, validation and conversion are app work and may wait for runtime. This implementation conservatively starts that work only while the phone is active and cancels its preparation workers when leaving the foreground. Delivered files then show “Waiting to verify audio” until the app can validate and publish them. Background audio playback is not treated as a guarantee of unrestricted execution time.

If iOS terminates the app, the next launch reconnects to the same session and enumerates its tasks before scheduling replacements. Matching tokens reattach without another extraction. Duplicate, stale, policy-incompatible and orphaned tasks are cancelled. A safe receipt recovers a delivery even if the process stopped before updating the queue's transferring phase. IDs absent from the supplied library lookup are removed before transfer reconciliation.

**A user force-quit stops the app's background tasks and prevents automatic relaunch for their events.** On the next explicit launch, missing tasks are reconciled against durable pending IDs and can be renewed in the foreground within the remaining attempt budget. Transfers are not promised to survive force-quit.

Wi-Fi-only requests carry both `allowsCellularAccess = false` and `allowsExpensiveNetworkAccess = false`. An expensive hotspot is treated conservatively like cellular. Changing the preference cancels and replaces submitted requests; mutating a session configuration after task creation would not change an existing request. The saved preference must be supplied during construction so restored tasks cannot run briefly under a default policy. OS cancellation may have already-received or in-flight bytes; it is not retroactive billing control.

`DownloadState` keeps its existing cases so shared view switches remain compatible. Additional wait information is carried by:

| API | Meaning |
| --- | --- |
| `DownloadItem.waitingReason` | `.foregroundResolution`, `.processing`, `.connection` or `.storage` |
| `DownloadItem.statusTitle` | Wait reason's sentence, otherwise the existing state title |
| `DownloadCenter.statusTitle(for:)` | Same status by recording ID |
| `DownloadCenter.waitingReason(for:)` | Reason for a player/menu presentation |
| `DownloadCenter.queueError` | Queue load/write failure, including failures with no visible queue rows |
| `DownloadCenter.setForeground(_:)` | Runtime eligibility; does not cancel submitted transfers |

Progress is based on OS byte callbacks, coalesced to whole percentages and capped at 99% until publication. Unknown lengths do not invent progress. Cancel removes durable intent, fences preparation and cancels the matching OS task. A queue-write failure keeps a visible error rather than acknowledging a durable cancellation. Remove Download and Delete Download first cancel pending work and then use the existing demotion/deletion APIs. A file in use is retained through the existing cache reader rules.

Download rows render `item.statusTitle`; player/menu status uses the center's status projection. `DownloadsView` displays queue errors with Try Again calling `restoreDownloadQueue()`. A repaired queue is reread; a corrupt queue is never replaced with an empty list merely because a read failed.

## Integrated Call Sites

### Scoped Local Readers for Export

Both `DownloadCenter` and `DownloadManager` expose:

```swift
func withLocalCopy<Result: Sendable>(
    for trackID: String,
    operation: @Sendable (CachedAudio) async throws -> Result
) async throws -> Result?
```

The cache implementation adds `allowOpus: Bool = true`; the manager supplies its existing runtime policy. A missing compatible local copy returns `nil` without calling the operation. Missing-duration inspection and operation errors propagate separately: an operation failure never marks valid source audio corrupt.

```swift
let result = try await downloads.withLocalCopy(for: track.id) { source in
    try await exporter.export(track: track, source: source, artwork: artwork)
}
```

The existing `AudioCache.readers` lease is acquired before lookup and remains held until the awaited operation returns or throws. Cancellation propagates through the same task; it does not release a lease while an operation is still unwinding. The operation must await all native reader cleanup before returning, rather than launching unstructured file readers that outlive the callback. No extra deadline races or detached work are introduced by this API. An operation that returns a result despite cancellation retains that result.

The lease also records the exact borrowed URL. A tier move copies and synchronizes that encoding when necessary, removes the old sidecar and retains the original media path until its readers release it. The retained original contributes to preparation bytes, not another downloaded song. A move refuses to overwrite a destination URL still borrowed by another operation. Unborrowed tier moves retain their rename behavior. `localCopy(for:)` and `preparedEntry(for:)` still return snapshots whose leases do not span subsequent caller work; asynchronous export should use the scoped API.

Lease handling emits no new identifiers or log dimensions. Existing cache removal/clear metrics report in-use retention. A filesystem cleanup failure emits `audio_cache_reader_retirement_failed`. Scoped `DownloadsTests` cover removal/clear protection, cancellation drainage, lease acquisition before duration lookup, retained URLs across demotion, and missing-copy/operation-error release. They use isolated real files and injected gates. Executed core and integration coverage is recorded in [VERIFICATION.md](VERIFICATION.md).

The accompanying recovery review also protects active background preparation parts during `clearUnused`, and reconciles cancelled-task slots against the OS task list during queue recovery. The latter is covered by `BackgroundDownloadsTests/testQueueRecoveryDropsRetiringTasksNoLongerOwnedByOS`; the existing `testCacheMaintenanceRetainsDeliveryReaderAndRejectsStalePublication` covers preparation-file lifetime.

### Production Construction in MusicAppModel

`MusicAppModel` constructs production downloads using the same cache and resolver as the player:

```swift
DownloadCenter(manager: DownloadManager.background(
    store: cache,
    planner: { try await resolver.backgroundDownloadPlan(for: $0) },
    connectivity: connectivity,
    allowCellular: library.preferences.downloadsOverCellular
))
```

`resolver` must be the concrete `CompositeStreamResolver` (or `YouTubeStreamResolver` in a YouTube-only construction). The planner API intentionally does not extend `ProviderProtocols.swift`. Keep foreground-only fixture construction on the existing initializer and isolated queue files.

`MusicAppModel.init` calls `restoreDownloadQueue()` after construction, without waiting for a window task. `GanaBajanaApp` connects the same method to its delegate for real launches. Successful restoration is idempotent; `DownloadCenter.restoreQueue` permits a later retry after failure. New downloads wait for an active restoration task.

`DownloadManager.TrackLookup` accepts a throwing async closure. The integrated lookup uses `try await MainActor.run` and checks the library before deriving known metadata:

```swift
guard library.hasLoadedDocument, !library.requiresReload else {
    throw BackgroundDownloadFailure.staging
}
```

A failed-startup placeholder must not masquerade as a library from which every queued recording was deleted. A thrown lookup preserves pending IDs and still reconnects the OS session so completion events can drain. Retry restoration after library recovery.

### UIApplicationDelegate in GanaBajanaApp

`Sources/Downloads/BackgroundDownloadCompletion.swift` supplies the single delegate used by the SwiftUI app. It also dispatches the TV lyrics scene role:

```swift
@UIApplicationDelegateAdaptor(BackgroundDownloadApplicationDelegate.self)
private var appDelegate
```

After assigning `_model`, the app connects real launches. Initial restoration already occurs in the model initializer:

```swift
if !Self.isTesting {
    appDelegate.reconnectDownloads = { model.restoreDownloadQueue() }
}
```

The supplied delegate implements this exact UIKit callback:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
)
```

Its Objective-C selector is `application:handleEventsForBackgroundURLSession:completionHandler:`. It registers the completion handler through `BackgroundDownloadCompletion.handleEvents(identifier:completionHandler:)`, then invokes the reconnection closure. The closure can be installed after the delegate callback; pending reconnection is retained. If the app acquires another UIApplicationDelegate or another background session, merge routing into that single delegate rather than adding a second adaptor.

The URLSession delegate selector `URLSessionDidFinishEventsForBackgroundURLSession:` produces a serial `.drained` event. All earlier delivery callbacks have already staged their files synchronously. The engine processes earlier queue events before forwarding the drain to `BackgroundDownloadCompletion.didDrain()`, which invokes the UIKit handler on the main actor. A drain that arrives before handler registration is retained. Completion does not wait for a foreground conversion because the received bytes and pending intent are already safe on disk. Never invoke the UIKit handler immediately after starting reattachment.

### Phone Lifecycle and Preferences

In `activateDeviceServices()`, alongside the existing restoration call:

```swift
downloads.setForeground(true)
```

In `deactivateDeviceServices()`:

```swift
downloads.setForeground(false)
```

Keep the existing `PhoneSceneLifecycle` source of phone scene phase and its playback checkpoint behavior. Keep preference propagation through `downloads.setAllowCellular(...)` after the preference saves, and keep `downloads.connectivityChanged()` on path changes. Do not use a background-task assertion or `BGAppRefreshTask` as a substitute for the session delegate. This file-transfer feature requires no new `BGTaskSchedulerPermittedIdentifiers` entry or audio background-mode assertion.

## Metrics and Coverage

Logs use subsystem `com.agraabhi.ganabajana`, category `Downloads`, event `background_download`. The bounded `outcome` values are `submitted`, `reattached`, `published`, `failed`, `queue_unreadable` and `queue_write_failed`. Failure `reason` is one of `expired`, `transport`, `invalidMedia`, `staging`, `publication` or `interrupted`. Reattachment emits an aggregate `count`. Existing cache publication/deduplication logs remain in `AudioCache`. Recording IDs, task tokens, URLs, headers, track titles and raw errors are not log dimensions. There is no per-progress log or new telemetry service.

`Tests/BackgroundDownloadsTests.swift` contains isolated boundary tests. No test here establishes actual OS suspension or physical-device behavior.

| Unit / Local Integration Scenario | Test Selector(s) |
| --- | --- |
| Stable configuration and wake settings | `testSystemConfigurationHasStableReattachmentIdentityAndLaunchEvents` |
| Core YouTube AAC file planning, Opus delivery fallback | `testFastYouTubePlanChoosesAACWithoutDownloadingOrPreparingOpus`, `testOpusOnlyFastPlanReturnsRemoteFileForDeliveryPreparation`, `testFittingOpusPreservesQualityCeilingBeforeAboveCeilingAAC` |
| Plan expiry and manifest rejection | `testExpiredPlansAndHLSCannotBeSubmitted` |
| Two-slot scheduling, suspended app preparation wait | `testTwoTransfersContinueAfterBackgroundAndThirdWaitsForRuntime` |
| Synchronous staging and duplicate callbacks | `testDeliveryCopiesSynchronouslyAndDuplicateCallbacksPublishOnce` |
| Task and receipt recovery | `testColdLaunchReattachesPendingTaskWithoutExtractingAgain`, `testColdLaunchRecoversReceiptEvenWhenQueueStillSaysTransferring`, `testTaskCompletionDuringLibraryLookupCannotLeaveAPhantomTransfer` |
| Duplicate tasks, missing metadata, v1 migration | `testDuplicateReattachedTasksKeepOneTransferAndDropMissingTrack`, `testLegacyQueueMigrationDropsMissingMetadataAndCancelsOrphanTasks`, `testUnavailableLibraryLookupPreservesPendingIDsUntilRecovery` |
| Expired links, foreground renewal, URL-free persistence | `testExpiredReattachedTaskWaitsForForegroundThenRenewsWithinAttemptBudget`, `testHTTP403InBackgroundWaitsForForegroundAndNeverPersistsURL`, `testForegroundReturnRenewsAnExpiredTaskWithoutAProcessRestart` |
| Persisted retry budget and progress | `testThreeAttemptsAreDurableAndManualRetryResetsBudget`, `testProgressClampsAndUnknownLengthNeverClaimsCompletion` |
| Cellular policy and OS cancellation acknowledgement | `testCellularSwitchCancelsOldTasksAndWaitsForCancellationAcknowledgement` |
| Noncooperative publication cancellation | `testCancellationFencesPublisherThatIgnoresTaskCancellation` |
| Failed publication retains bytes and needs explicit retry | `testFailedPublicationKeepsReceiptAndExplicitRetryUsesSameBytes`, `testFailedStagedPublicationDoesNotRetryItselfAtColdLaunch` |
| Corrupt/future/oversized queue; persistence errors | `testMalformedFutureAndOversizedQueueArePreservedAndBlockSubmission`, `testQueueWriteFailurePreventsSubmissionAndDoesNotAcknowledgeCancellation`, `testPlanBookkeepingMustSaveBeforeTheOSTaskIsCreated` |
| HTTP/body validation and corrupt native media | `testBadResponseTypesLengthAndTruncatedRangesNeverGetReceipts`, `testCacheRejectsFakeMP4AndCancelledFenceWithoutDownloadedBadge` |
| Remux contract and maintenance reader lifetime | `testBackgroundOpusPublicationUsesExistingRemuxAndNativeValidationContract`, `testCacheMaintenanceRetainsDeliveryReaderAndRejectsStalePublication` |
| Remove and in-use deletion | `testBackgroundManagerRemoveAndInUseDeleteKeepExistingTierSemantics`; existing `DownloadsTests` tier/readers coverage |
| UIKit handler ordering | `testApplicationCompletionWaitsForDrainAndAlsoHandlesEarlyDrain` |

The session, delivery store, planner, publication and queue writer are injectable. Opus local tests inject the existing preparation fixture; they verify the contract and fences, not the device decoder. WAV publication and invalid-MP4 tests use native local inspection.

Core-02 exposed publication waits after native reader errors (`FFR_Common`, `-12847`) on valid WAV bytes at opaque `.part` URLs. The parser-hint correction has direct native WAV/AAC publication tests and negative mislabeled-codec coverage. Core-03 passed after this correction; [VERIFICATION.md](VERIFICATION.md) owns counts and run boundaries.

Remaining device checks: real YouTube/JioSaavn transfers while locked with no audio playback; OS termination and reattachment; force-quit/reopen; Wi-Fi/cellular policy changes; UIKit wake before scene activation; protected-storage unavailability; full disk during staging/publication; and native AAC/Opus output across supported runtimes. Passing core/component tests do not establish these OS behaviors.
