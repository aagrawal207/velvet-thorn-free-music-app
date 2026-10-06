# Scrolling during playback

R16 moves checkpoint preparation off the main actor and avoids unrelated observation invalidations. The measured improvement is shorter main-actor occupancy, not less total persistence work or a frames-per-second guarantee. [VERIFICATION.md](VERIFICATION.md) owns run counts and receipts; [ROADMAP.md](ROADMAP.md) owns remaining work.

## Current architecture

- **Observation.** `LibraryStore.document` is `@ObservationIgnored`. Getters observe process-local slice revisions; `publish` installs the durable document and updates lookup indexes before notifying changed slices. A playback-only write does not invalidate preferences/history. Failed writes publish neither data nor slice revisions. Reload and cloud adoption use the same publication boundary; revisions are not persisted or synced.
- **Projections.** `MusicAppModel` caches rolling listening, language and genre summaries per window, plus language/genre profiles. Keys include history revision, history-enabled state, minute bucket and calendar (including time zone); language/genre evidence revisions, language overrides, nudges and fallback choices apply to their dependent projections. Cache population is observation-silent, and hits still observe their revision dependencies. All Time uses its selected surviving-history summary rather than borrowing the monthly profile's scope.
- **Player delivery.** Model-created production players use `onListeningCheckpoint(PlaybackListeningCheckpoint) async -> Bool`. Injected players opt in with `asynchronousListeningCheckpoints: true`; `onListeningProgress` and `onSnapshotChanged` remain the synchronous compatibility path. `onSnapshotIntentChanged` reports intent without saving it. The async batch combines captured listening deltas, an optional recent position and the newest resume snapshot; ordinary async track-start handling does not add a separate synchronous recent write.
- **Prepare and apply.** `prepareListeningCheckpoint` captures immutable state on the main actor. A detached utility task performs full validation, retention, targeted sync-journal updates and JSON encoding. `applyListeningCheckpoint` checks document/privacy/context generations and cancellation, then checks the disk baseline and atomically persists the document plus journal in one non-suspending main-actor turn. Publication and acknowledgement follow durability; disabled-history/no-change acknowledgements follow the applicable no-op checks. Manual library mutations remain synchronous.
- **Bounds and retries.** One player delivery and one library preparation run at a time. The buffer and each batch hold at most 128 session identities; each delivery makes at most three captures and each library call at most three preparation/rebase attempts. Exact-delta acknowledgement subtracts only captured seconds, preserving seconds appended during the await. Rejection retains pending time for a later flush; capacity exhaustion pauses playback. A durable acknowledgement still consumes its captured delta if cancellation arrives after commit. The memory-only buffer does not survive process termination.

The implementation boundaries are [`MusicAppModel`](../Sources/App/MusicAppModel.swift), [`PlayerController`](../Sources/Playback/PlayerController.swift) and [`LibraryListeningCheckpointPreparation`](../Sources/Library/LibraryListeningCheckpointPreparation.swift). [Architecture](ARCHITECTURE.md#librarystore-api-and-durability) owns the broader persistence API.

### Privacy and newer intent

Both enabled-to-disabled and disabled-to-enabled history changes retire the player delivery generation and reset the listening clock **only after the preference change is durable**. A failed preference write keeps pending time and resume intent retryable. Enabling starts a fresh recording session without backfilling disabled time; previously acknowledged history remains until cleared.

A successful clear retires pending events/recents and removes saved history, recents and derived mixes. It preserves the queue and any dirty paused resume snapshot. Recovery first submits that snapshot alone, with no events or recent position, even without another flush. New enabled listening can then drain separately. Failed snapshot recovery stops rather than looping. Privacy, reload/account context and newer playback/recent fences prevent stale history or stale resume state from being resurrected.

Lifecycle delivery requests a native background-task lease. Expiration cancels preparation and keeps unacknowledged deltas retryable. Injected expiration coverage does not establish behavior under actual iOS background suspension.

## Measured evidence

The coordinator actually ran these R16 measurements in a **Debug simulator** with the same 10,000-session benchmark history. This documentation pass did not run them.

| Stage | Measurement | Result |
| --- | --- | --- |
| Baseline | 30 language-profile reads | 2,246 ms total |
| Baseline | Synchronous progress callback, average of three | 2,191 ms; preference observer invalidated: `true` |
| Cached projections and slice observation | 30 profile reads, first miss included | 73 ms total |
| Cached projections and slice observation | Synchronous progress callback | About 1,971 ms; preference observer no longer invalidated |
| Async checkpoint | Enqueue plus flush submission | 0.53–0.63 ms |
| Async checkpoint | Library capture plus apply on the main actor | 5.1–9.0 ms |
| Async checkpoint | End-to-end wall time | 1,970–2,100 ms |

The async timing excludes detached preparation from the library's main-actor measurement. Submission, library occupancy and wall time are different measurements, not an application-wide frame budget. Validation/journal/encoding work still takes roughly two seconds in this fixture.

Coordinator-reported focused receipts: **Async-Core-02: 65 passes; Async-Privacy-01: 85 passes; UI-02: 13 passes.** Native UI coverage includes Home/Stats scrolling overlapping actual async commits, durable disk readback, and a Stats frame-clock watchdog requiring less than one second of starvation. XCTest's scrolling signpost produced **one missing-iteration-metric warning**; these results do not establish that every metric was valid or any particular FPS.

**UI-SE01** passed the three new UI cases but failed one scrolling case because the navigation gesture budget was too small. After raising the reveal cap to 20 swipes, **UI-SE02** passed that one case. The iPad run passed seven Stats/toggle/Settings cases. These are separate targeted runs, not a completed full suite. Physical-device scrolling and actual background suspension remain unverified. The coordinator's [verification record](VERIFICATION.md) is authoritative for evolving counts and rerun scope.

## Bounded diagnostics

| Event | Fields and scope |
| --- | --- |
| `library_persist` | `path`: checkpoint/manual/sync; `fence`: metadata/content/none; `outcome`: written/unchanged/changed_on_disk/failed; `wrote`, `bytes`, `duration_ms` |
| `listening_projection_cache_miss` | `kind`: summary/languageSummary/genreSummary/languageProfile/genreProfile; `window`: week/month/year; `elapsed_ms` |
| `listening_checkpoint_preparation` | Detached-task `duration_ms`; `outcome`: prepared/rejected/cancelled |
| `listening_checkpoint_async` | `preparation_ms`, `capture_ms`, `apply_ms`; `outcome`: committed/no_change/rejected/retired/stale |
| `listening_checkpoint_delivery` | `duration_ms`, `sessions` (0–128), `snapshot_only` (Bool); `outcome`: acknowledged/cancelled/rejected |
| `listening_checkpoint_expired` | Background-lease expiration event, no identity fields |

Timings and bounded session counts are numeric measurements. These events log no session/recording IDs, titles, artists, URLs or account identifiers. Keep dimensions limited to the existing kinds, windows and outcomes.

## Reproduction fixture and coverage

Use the existing `GanaBajanaScrollingPerformanceUITests` launch recipe: `--uitesting --seed-ui --reset-ui --skip-welcome --scroll-performance-fixture --cache-fixture --genre-fixture`, English/en_US, and a unique `GANABAJANA_TEST_STORE`. The scrolling flag requires `--uitesting`, selects isolated storage under `Application Support/GanaBajanaUITests/<name>`, seeds **2,000 three-minute sessions across five songs**, and uses local AAC. Seed/setup guards reject a real user-store path. `--reset-ui` affects only that isolated store. Fixtures use injected providers and no real account store; the UI checks zero audio-network requests.

Start playback from the mini-player, select Home or Stats, and toggle `scrollPerformance.probe` around a scroll round trip. The probe samples a display link without per-frame SwiftUI invalidation and flushes actual elapsed playback on gesture starts, at most once per second. It counts only acknowledged async commits and independently decodes the saved session, queue and recent position afterward. There is no synthetic checkpoint delay. The fixture is DEBUG-only, and `tools/audit-release.py` rejects its flag, types and probe marker in Release binaries; this is the audit contract, not a claim of a new archive audit in this documentation pass.

| Layer | Source tests and contract |
| --- | --- |
| Unit: observation | [`LibraryObservationTests`](../Tests/LibraryObservationTests.swift): `testPlaybackOnlyInvalidatesPlayback`, `testListeningInvalidatesHistoryAndApplicableRecentOnly`, `testFavoriteAndPreferenceObserversReadDurableData`, `testRejectedWritesPublishNoDataOrRevisions` |
| Unit: projection scope | [`ListeningProjectionCacheTests`](../Tests/ListeningProjectionCacheTests.swift): `testMinuteRolloverExpiresRollingWindowWithoutHistoryWrite`, `testMidnightTimeZoneAndCalendarChangesInvalidateWithoutExactDateKeys`, `testMonthlyProjectionReuseDoesNotBorrowAllTimeLanguageScope`, `testCachePopulationIsObservationSilentAndRevisionStillObservedOnHit` |
| Unit: durable async storage | [`LibraryAsyncCheckpointTests`](../Tests/LibraryAsyncCheckpointTests.swift): `testHeldPreparationLeavesMainActorResponsiveAndPublishesOnlyAfterDurability`, `testBatchCommitsMultipleSessionsRecentAndSnapshotWithOnlyTargetedRegisters`, `testStaleRebasesStopAfterThreePreparationsAndRemainRetryable`, `testForeignWriterIsPreservedAndReloadAllowsOneRetry` |
| Unit: player delivery | [`PlaybackAsyncCheckpointTests`](../Tests/PlaybackAsyncCheckpointTests.swift): `testProductionDrainAcknowledgesCapturedDeltaAndPreservesSecondsAppendedDuringAwait`, `testBackgroundLeaseExpirationBeforeApplyKeepsPendingDelta`, `testCancellationAfterDurabilityStillAcknowledgesCapturedDelta` |
| Unit/native playback: privacy | [`PlaybackAsyncPrivacyBoundaryTests`](../Tests/PlaybackAsyncPrivacyBoundaryTests.swift): `testPausedSnapshotOnlySaveSurvivesClearAndDisableWithoutAnotherFlush`, `testSuccessfulEnableRetiresHeldDisabledDeliveryButPreservesAcknowledgedAndNewEnabledTime`, `testFailedEnableKeepsPendingGenerationAndResumeIntent`, `testRealPlaybackEnableBetweenCheckpointsRecordsOnlyPostEnableSeconds` |
| Unit-target benchmark | [`ScrollingWorkBenchmarkTests`](../Tests/ScrollingWorkBenchmarkTests.swift): `testLargeHistoryProfileReadsAndListeningCheckpoint`, `testLargeHistoryAsyncCheckpointMainActorOccupancy`; fixed 10,000-session input and reopened-store checks |
| Native UI: scrolling | [`GanaBajanaScrollingPerformanceUITests`](../UITests/GanaBajanaScrollingPerformanceUITests.swift): `testHomeScrollingMetricsWhileLocalPlaybackCheckpointsCommit`, `testStatsScrollingMetricsWhileLocalPlaybackCheckpointsCommit`, `testStatsScrollingFrameClockAndIndependentSeedSnapshot`; actual scrolling, advancing local playback, overlapping durable commits and the 6,000-minute/2,000-play seed oracle |
| Native UI: visible contracts | [`GanaBajanaMainStatsUITests`](../UITests/GanaBajanaMainStatsUITests.swift): `testStatsKeepsRecapSelectorsAndTitleCasedSections`; [`GanaBajanaDownloadsUITests`](../UITests/GanaBajanaDownloadsUITests.swift): `testLikedSongsDownloadConfirmationResetsFiltersAndKeepsPendingLikesVisible`, `testLikedSongsDownloadPreferencePersistsAndStaysSynchronizedWithSettings` |

Remaining acceptance is a current full suite, physical-device scrolling during playback, and real background suspension/expiration. Manual synchronous mutations and cold projection misses still deserve profiling if device traces show stalls.

## Responsiveness on a large library

`GanaBajanaResponsivenessUITests` measures scrolling and navigation on a realistic library: `--large-library-fixture` seeds 805 liked songs (40 super liked), 25 playlists and 12,000 sessions over a year, with artwork served by `--artwork-fixture`. The DEBUG probe (`--responsiveness-probe`) drives each scroll itself at 2,400 pt/s for up to 10,000 pt down and back, and arms push/pop and tab windows on the next touch, so XCUITest's element queries fall outside every measured window. Hitch time follows Apple's definition (time a frame arrived after its expected interval, counting gaps over 1.5 frames). Each window emits `probe_window_start`/`stop` Points of Interest for Instruments. A no-op tap measures the harness itself at 0 to 1 hitches.

Time Profiler traces of an optimized simulator build found these main-thread costs, all fixed:

| Cause | Fix |
|---|---|
| Every 5-second listening checkpoint rebuilt `LyricsRequestKey` (regex title cleanup and Unicode folding) for every session in the last 30 days, about 500 ms with 12,000 sessions | `LyricsRequestKey` memoizes normalization per recording field set (8,192 entries, cleared when full) |
| `ListeningAnalytics.summary` called `Calendar.startOfDay` and normalized artist names per session | `DayBuckets` reuses the current day's bounds; artist keys are computed once per distinct credit list |
| Stats' comparison line ran a full uncached summary of the previous window in its body | `MusicAppModel.previousWindowListeningSeconds` sums seconds only and caches per history revision and minute |
| Every navigation link observed the selected tab, so a tab switch re-evaluated every card and row in the app | `AppNavigationLink` reads the model only while its destination is active |
| Returning to Home rebuilt `TasteProfile` over the whole history | Cached per taste-input revisions and minute |
| Album and mix pages built every row inside the push animation | The first 12 rows build with the page; the rest join after 350 ms, six per frame |
| Returning screens cross-faded every artwork tile, which SwiftUI rasterized on the CPU | A decoded bitmap already in memory is shown without animation; `ArtworkLoader.memoryImage` reads the cache synchronously |
| `ArtworkLoader` pruned its key set on every insert and wrote actor state after a suspension | Pruning happens past 2,048 keys; the image is cached in `finish` before waiters resume |

The body of `ArtworkView` deliberately performs no cache lookup: doing so per row cost Liked Songs about 80 hitches per fling.

Results on iPhone 17 Pro simulator, optimized Debug build, with local playback (hitches / hitch ms in the window; baseline `Perf-Base-02`, final `Perf-Final-01`):

| Step | Baseline | Final |
| --- | --- | --- |
| Library scroll | 1 / 526 | 1 / 16 |
| Mix page scroll | 1 / 550 | 0 / 0 |
| Liked Songs fling (8.3 s) | 6 / 683 | 5 / 162 |
| Pop from mix to Home | 5 / 997 | 5 / 293 |
| Stats tab switch | 1 / 795 | 2 / 316 |
| Home tab switch | 8 / 1,043 | 10 / 450 |
| Player open | 6 / 367 | 4 / 286 |
| Push mix page | 9 / 683 | 10 / 618 |

The longest single stall per step fell from 500–810 ms to 140–320 ms. Pushing a page and tab switches still cost several hundred milliseconds in SwiftUI's own view-graph and Core Animation commit work; the remaining app-side time there is the first `loadHome` language refresh on return to Home. These are simulator numbers on a loaded Mac, for comparing builds; physical-device frame rates are not established.

