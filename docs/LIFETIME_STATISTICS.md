# Lifetime Statistics

Lifetime listening time and counted plays survive the 400-day detail-retention policy. The All Time hero and play count read these durable totals. Songs, artists, charts, genre shares and language shares still describe retained detail. Migration counts only sessions that survive in the local file or an incoming replica. It cannot reconstruct previously deleted listening.

R17 lifetime statistics are implemented and integrated. Core-03, Regression-01, Integration-03 and UI-03 Stats checks passed within their targeted scope. UI-03 covers the phone in light and dark appearance. [VERIFICATION.md](VERIFICATION.md) owns counts, skips and evidence. Native two-device convergence and hardware performance remain unverified.

## Design and Capacity

`LifetimeListeningRollup` holds compact receipts keyed by the existing listening-session UUID. Each receipt has cumulative seconds, a qualified-play flag, a millisecond-normalized start date and a SHA-256 recording-ID fingerprint. It has no song title, artist, artwork, duration or playable identifier. The fingerprint checks session identity; hashing does not make this listening data anonymous.

A receipt joins matching identities by maximum cumulative seconds and logical OR of the qualified flag. A play stays counted after it first qualifies. Equal-sized local checkpoint deltas are separate listening time, as required by the existing player acknowledgement contract. Re-delivering an already-applied immutable preparation fails its document-generation fence. Re-downloading a replica joins cumulative receipts and adds no duplicate time.

The permanent identity receipts are necessary for the existing multi-device semantics. `LibrarySyncHistoryTests.testTwoDevicesDeduplicateAnAcknowledgedSessionAndKeepTheMaximumCumulativeTime` allows both installations to extend a downloaded session. Independent migrations can also contain partially overlapping sets of sessions. Summing device totals would count shared history twice; taking the maximum of device totals would lose independent sessions. The implementation retains exact session identity instead of introducing an exclusive-device ownership rule.

**This is a capacity-bounded exact rollup, not an unlimited fixed-size counter.** The receipt map grows with distinct sessions until a hard bound. It does not grow with checkpoint frequency and never accumulates per-track lifetime rankings. Discarding receipt identities without a new compaction/coordination protocol would make a late overlapping replica impossible to deduplicate exactly.

| Bound | Behavior |
| --- | --- |
| Lifetime receipts | At most 200,000 per clear-history generation |
| Total listening seconds | Finite, nonnegative, at most 1,000,000,000,000 |
| Counted plays | At most one per receipt; total validation also caps at 10,000,000,000 |
| Shared journal | Existing 200,000-register limit includes receipts, live events and all other collections. This can be reached before 200,000 receipts |
| File sizes | Existing 128 MiB local / 64 MiB replica bounds still apply and may be reached first |
| Charts | Existing retained-history charts keep their 24-bucket All Time bound |

Exhaustion rejects the candidate write or merge and preserves the preceding document and published totals. There is no silent eviction, sampling or guessed total. At sufficient listening volume this limit will block further recording until a compatible capacity/compaction change or an explicit history clear. This limitation must remain visible in the integration record.

## Persistence and Migration

| Format | Writes | Reads |
| --- | --- | --- |
| Library document | 4 | 1, 2, 3, 4 |
| Sync journal | 3 | 1, 2, 3 |
| Replica envelope | 3 | 1, 2, 3 |

`LibraryDocument.lifetimeListening` stores the materialized receipt map in `library.json`. `.lifetimeSession` registers store the corresponding mergeable receipts in the same document's journal. There is no second lifetime file or installation-identity file.

Legacy migration derives receipts before startup retention can remove detail, including any older streak samples that still exist. Existing event revisions are copied to derived journal receipts without advancing the journal clock or restamping the original event. An old file can therefore remain byte-for-byte unchanged during a non-pruning read. A real edit, retention maintenance or necessary sync write saves the current formats. Existing valid event-only fixtures can also acquire derived receipts during decoding. The final materialized document and journal must agree before publication.

Version 4 requires the lifetime field. A lifetime field under an older local version, or lifetime registers under an older journal/envelope version, is rejected. Future versions, invalid counters/identities, malformed payloads and unknown fields inside lifetime payloads fail closed. The existing canonical-payload validator is shared with typed Search validation. Migration never uses a decode failure as permission to start empty or overwrite a file.

The start of coverage is the earliest included session's actual date, including sessions below the counted-play threshold. It is not an assertion that every day after that date is complete: migration may start from incomplete retained history, recording may have been disabled, and other devices may still be offline. Future-dated receipts remain stored but are excluded from the current UI total until their date. A retained history gap is not filled with estimated listening.

## Checkpoints, Retention and Privacy

Both `recordListening` and `LibraryListeningCheckpointPreparation.make` update the candidate receipt before detail retention. A retained event accumulates the incoming delta against the larger of its materialized cumulative time and its receipt. When detail has expired, a matching receipt supplies the cumulative baseline; a later delta cannot restart that UUID at zero or count its play twice. Recording/start conflicts reject the whole candidate.

Targeted checkpoint journaling encodes only the affected receipt keys alongside the changed event and recent-position payloads. The async worker retains full validation, retention and encoding off-main. It also prepares the changed lifetime summary and future-receipt flag in `LifetimeListeningPublication`. Cloud-merge preparation carries the same projection. Their existing document/shared-state fences protect the projection together with the candidate, so durable async apply assigns the summary without comparing or scanning the receipt map again. Main-actor apply retains the disk-baseline/atomic-write guard. Only a durable apply updates the cached lifetime summary and its observation revision. A rejected write or stale preparation publishes neither a rollup nor a revision. An unchanged lifetime slice carries no new projection; playback-only publication does not invalidate lifetime observers.

Detail pruning removes `.event` payloads using the existing policy but keeps `.lifetimeSession` receipts. Sync joins receipts before materializing/pruning event details. Repeated old replicas therefore cannot reduce totals or count a pruned session again.

`clearHistory()` removes receipts and advances the existing journal `historyReset` in the same atomic library write. `.lifetimeSession` is an `isHistory` collection, so late offline updates in an earlier generation cannot restore totals. A failed clear retains the old receipts, epoch and totals. Old iCloud conflict-file versions are not physically purged by this operation; the reset prevents their materialization through the existing merge protocol.

History Off keeps already-saved totals and prevents new local listening/receipt credit. Existing disabled-history acknowledgement and resume-snapshot behavior remains in the checkpoint path. A successful disable/reenable privacy boundary still retires pending player work through the existing generations; failed preference saves do not retire it. Previously recorded remote history can merge while the preference is off, matching the established saved-history sync behavior.

## UI and Coordinator APIs

| API | Use |
| --- | --- |
| `LibraryStore.lifetimeListeningSummary: LifetimeListeningSummary` | Read durable `seconds`, `plays`, and optional `coverageStartedAt` |
| `LibraryStore.lifetimeListeningRevision: UInt64` | Observation/cache key for receipt changes, including a receipt-only update after detail pruning |
| `LibraryStore.listeningHistoryEpoch: UUID?` | Read the existing persisted privacy token. It remains nil until an existing privacy operation establishes one |
| `ListeningAnalytics.lifetimeHero(_:) -> ListeningSummary` | Totals-only presentation adapter. Rankings, unique counts and days are deliberately empty |
| `RecapShareCardContent(..., lifetime:)` / `RecapText.share(..., lifetime:)` | Optional lifetime hero input while preserving retained-detail rankings |

`RecapView` is wired directly to the store API. All Time labels the hero Lifetime Listening, uses Lifetime Plays, identifies different-song/artist counts as retained, and discloses the chart/ranking scope. A library whose detail has entirely expired still shows and shares its lifetime total. The card labels its song ranking Retained History and carries the deletion caveat. No lifetime per-song, artist, genre or language statistic is inferred from the receipt map.

`RecapView` reads `library.lifetimeListeningSummary` directly. Lifetime caches key on `lifetimeListeningRevision`; history revision alone misses receipt-only changes. Rolling and retained-detail summary denominators stay separate, particularly for genre/language shares. Using lifetime plays there would dilute retained-history shares incorrectly.

[Moment Mixes](MOMENT_MIXES.md) uses `library.listeningHistoryEpoch`. It has its own observation revision, so an empty-history privacy change is visible without pretending detail changed. The model integrates before-capture and post-durability hooks, preference synchronization, lifecycle refresh and the existing clear callback.

## Exact File Changes

| Files | Change |
| --- | --- |
| `Sources/Core/LibraryModels.swift` | Add `LifetimeListeningSummary` |
| `Sources/Library/LibraryLifetimeListening.swift` (new) | Receipt identity, cumulative join, qualification, capacity checks and summary |
| `Sources/Library/LibraryPersistence.swift` | v4 field/read migration, canonical lifetime payload validation and reusable canonical-payload helper |
| `Sources/Library/LibraryStore.swift` | Synchronous receipt accumulation, clear behavior, cached summary/revision, optional epoch accessor and bounded log count |
| `Sources/Library/LibraryListeningCheckpointPreparation.swift` | Async candidate receipt update before retention and targeted journaling |
| `Sources/Library/ListeningAnalytics.swift` | Totals-only lifetime hero adapter |
| `Sources/Sync/LibraryLifetimeSync.swift` (new) | Receipt projection/materialization, migration from surviving event registers and targeted checkpoint recording |
| `Sources/Sync/LibrarySyncState.swift` | Journal/envelope v3 and reset-scoped `.lifetimeSession` collection |
| `Sources/Sync/LibrarySyncJournal.swift` | Seed before pruning, checkpoint receipt writes and aggregate restoration |
| `Sources/Sync/LibrarySyncMerge.swift` | Legacy receipt derivation and maximum/qualified-OR merge |
| `Sources/Sync/LibrarySyncProjection.swift` | Include receipts in the shared projection and materialize them independently of detail retention |
| `Sources/Sync/LibrarySyncValidation.swift` | Receipt key, generation, value and canonical-shape validation |
| `Sources/Sync/LibraryCloudMergePreparation.swift` | Prepare the lifetime publication alongside the candidate, protected by the existing shared-state fence |
| `Sources/Views/RecapView.swift`, `RecapShareCard.swift` | Lifetime hero/share totals and retained-detail wording |
| Four new test files listed below | Model, file/store, replica and sharing coverage |

## Metrics

Local OSLog stays in subsystem `com.agraabhi.ganabajana`, category `Library`. No remote telemetry is added.

| Event | Branches / Measurement |
| --- | --- |
| `listening_checkpoint` | Existing committed/no-change/history-disabled/zero-delta/rejected outcomes and duration; adds numeric `lifetime_sessions` bounded to 0–200,000 from published state |
| `listening_checkpoint_preparation` | Existing prepared/rejected/cancelled outcome and off-main preparation duration also cover receipt work |
| `listening_checkpoint_async` | Existing committed/no-change/stale/retired/rejected outcome and preparation/capture/apply durations; adds the same bounded published receipt count |
| Existing `LibrarySync` events | Receipt merge/schema/capacity failures pass through existing bounded failure classification; no new identifier dimension |

Recording IDs, session UUIDs, fingerprints, coverage dates and raw errors are not added to logs. Tests assert state/outcomes rather than intercepting OSLog. Receipt work increases validation and atomic-file encoding cost with library size; no checkpoint or scrolling latency measurement was made here.

## Tests and Integration Work

The suites below have executed coverage in the coordinator's R17 runs; [VERIFICATION.md](VERIFICATION.md) owns the results. Local-file/component integration cases run in the unit-test target, using isolated directory, clock and async gate helpers.

| Suite | Cases | Type |
| --- | --- | --- |
| `LifetimeListeningTests` | Repeated cumulative input and short-song qualification; join algebra; conflicting identity/start; numeric/key/capacity bounds; metadata-free receipt and totals-only hero; future-date filtering | Unit |
| `LibraryLifetimeListeningTests` | v1/v2/v3 migration and byte/revision preservation; sync/async repeated deltas and preparation replay; retention/relaunch/late delta; pre-retention migration; history-off/clear/coverage; failed atomic apply/identity rejection/retry; failed clear and retired preparation; playback-only revision stability; async rebase; prepared summary publication and no playback-only projection | Local-file and store component integration |
| `LibraryLifetimeSyncTests` | Overlapping independent migrations; concurrent shared-session maxima plus independent sessions; clear/stale-generation/new-history; pruned replay across two stores; v1/v2 replica migration/revision preservation; invalid/conflicting remote receipt; future/corrupt/smuggled/missing/unknown local payload preservation | Unit merge and local-file integration |
| `RecapLifetimeTests` | Lifetime hero with retained card rankings/coverage; fully expired detail with an honest share total | Unit presentation |

Coordinator selectors:

```text
-only-testing:GanaBajanaTests/LifetimeListeningTests
-only-testing:GanaBajanaTests/LibraryLifetimeListeningTests
-only-testing:GanaBajanaTests/LibraryLifetimeSyncTests
-only-testing:GanaBajanaTests/RecapLifetimeTests
```

Source and test membership are integrated. Core-03 and the regression/integration runs replace the earlier unexecuted-worker status.

Existing regression scope: `LibraryPersistenceTests`, `LibrarySyncPersistenceTests`, `LibrarySyncHistoryTests`, `LibrarySyncCheckpointTests`, `LibrarySyncSchemaCompatibilityTests`, `LibraryAsyncCheckpointTests`, `PlaybackAsyncPrivacyBoundaryTests`, `LibraryObservationTests`, `ListeningAvailableHistoryTests`, `RecapShareCardTests`, `ICloudLibrarySyncTests`, and the Moments integration selectors in its feature document.

The integration follow-up adjusted the existing regression fixtures for the intentional format change. `LibrarySyncTestData.legacyDocumentBytes` removes `lifetimeListening` and receipt registers from explicit old-version fixtures while preserving original clocks, non-lifetime registers and reset boundaries. Current sparse fixtures include their receipt explicitly. Assertions retain byte-for-byte no-op/read preservation and verify the derived receipt separately from unchanged original revisions. Future-version tests use current-version-plus-one, rather than numbers this reader now supports.

Adjusted suites: `LibraryPersistenceTests`, `LibrarySyncPersistenceTests`, `LibrarySyncHistoryTests`, `LibrarySyncCheckpointTests`, `LibrarySyncSchemaCompatibilityTests`, `LibraryPlaybackDiscoveryPreferencesTests`, `LibrarySyncPlaybackDiscoveryPreferencesTests`, `LibrarySearchSelectionTests`, `LibraryRecoveryTests`, `AudioCacheLimitStorageTests`, `AppModelCloudSyncTests`, `AppModelLibraryRecoveryTests`, `AppModelListeningControlsTests`, `ListeningLanguagePersistenceTests`, and `LibraryAsyncCheckpointTests`. `LibraryLifetimeListeningTests` adds the prepared-summary case. Execution scope is recorded in [VERIFICATION.md](VERIFICATION.md).

In `LibrarySyncCheckpointTests`, changed listening advances event and receipt revisions; changed listening plus recent position changes three registers. A second expired-session delta advances its receipt alone and performs another durable commit. The 10,000-session benchmark keeps the same workload and zero-full-projection requirement. Its unaffected-register comparison excludes exactly the changed event, receipt and recent keys. The corresponding two-session async test expects both receipts. Clear, stale replay and long-streak tests additionally assert lifetime totals without weakening retained-detail assertions.

**Remaining performance limits:** synchronous compatibility/manual commits still perform full lifetime validation, including a total scan, even when playback-only publication reuses its cached summary. Synchronous changed-history publication still builds a summary locally. A future-dated receipt also takes the existing time-filtered summary getter path, which scans on read. Atomic file baseline checks and writes remain main-actor work and grow with receipt storage. These paths were not rewritten because the follow-up does not relax validation or durability requirements. The scoped off-main projection change does not establish the R16 latency budget; rerun the existing 10,000-session checkpoint benchmark and the async projection/scrolling selectors before making a performance claim.

UI-03 passed targeted phone Stats and card-preview coverage in light/dark; Integration-03 covers the model boundaries recorded in [VERIFICATION.md](VERIFICATION.md). Remaining acceptance includes small-phone/iPad/accessibility layouts, recipient sharing and same-build native two-device convergence after offline listening and clear. Fake/store tests do not establish iCloud delivery, native conflict handling, OS suspension or hardware performance. Shared architecture, sync and privacy contracts describe the current formats.
