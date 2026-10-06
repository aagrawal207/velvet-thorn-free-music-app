# iCloud library sync

**Current contract: R19 source (`1.0.0 (9)`).** Lifetime receipts and the super-like tier ([SUPER_LIKES.md](SUPER_LIKES.md)) extend the local and sync formats below. R17's Core-03, Regression-01 and Integration-03 passed in their targeted scope; [VERIFICATION.md](VERIFICATION.md) owns counts, skips and run boundaries. The original device popup remains unconfirmed without native evidence. Fake transport tests do not establish two-device delivery.

## User behavior

**Settings > Library & iCloud > iCloud sync** manages sync through the listener's iCloud Drive. Sync defaults on when this device has no saved configuration. A saved Off choice stays off. A restored library whose backup-excluded device configuration is absent receives the enabled default and a fresh replica identity. The app keeps a local library for offline use; turning sync off keeps both the local library and existing iCloud files. Offline edits, including removals, are merged when sync resumes.

Sync includes all Codable `UserPreferences` fields, likes, super likes and dislikes, playlists, followed artists and release metadata, listening history, recents, typed Search selections, retained legacy queries, generated mixes, saved song metadata, recording-language corrections and lyric timing. Preferences include app icon, Home layout, playback, DNS, remote-fallback, cache-size choices and five independent language nudges. The current queue/position, pending local notification deliveries, StoreKit ledger, credentials, cached audio/artwork and derived language-cache file remain device-local. Language shares and retention scores are recomputed locally, not transmitted as aggregate counters.

An empty `appIconID` preserves an older installation's system-selected icon. The first active launch captures an installed alternate; explicit choices use stable IDs. Remote choices apply through the model's serialized `AppIconController` while a phone/iPad scene is active. Unsupported platforms retain the preference without trying to change the system icon.

The green cloud and On label indicate the enabled preference. Status separately distinguishes missing iCloud access, pending downloads, active work and errors. **Sync now** retries explicitly. “Handed to iCloud” means the coordinated local ubiquity write succeeded; it does not confirm upload or delivery to another device. A different Apple Account disables sync until the user enables it for that account. Sign-out keeps local data, and reconnecting the same account keeps its binding.

## Storage and merging

`Sources/Sync/` owns the journal, merge rules, native transport and observable `ICloudLibrarySync`. `LibraryStore` remains the only owner of saved library state.

| Stored format | Current writes | Current reads |
| --- | --- | --- |
| `LibraryDocument` / `LibraryPersistence.currentVersion` | 5 | 1, 2, 3, 4, 5 |
| `LibrarySyncState` journal | 4 | 1, 2, 3, 4 |
| `LibrarySyncReplica` envelope | 4 | 1, 2, 3, 4 |

Validated older formats derive lifetime receipts before detail pruning, retaining original event revisions without restamping. A non-pruning read can preserve original bytes; a real edit, retention maintenance or necessary sync write saves current formats. Lifetime payloads cannot be hidden under older version numbers; v4 requires the lifetime field. v5 adds `LibraryDocument.superLikedIDs: [String]`, a subset of `favorites` in favorites order; a file below v5 that carries the key fails with `invalidData("super like format version")`, and a journal or replica below v4 that carries `superLiked` fails with `invalidData("super like journal version")` or `invalidData("super like replica version")`. Corrupt, inconsistent, unsupported and future files remain preserved. Older binaries, including delivered build 6, fail closed with `newerVersion` on a v5 file or v4 replica and keep their files.

Shared edits and their revisions are saved in the same atomic `library.json` commit, including while sync is off. Legacy seeding includes populated records and nondefault preferences. A new empty device therefore cannot erase an existing remote library or replace remote preferences with defaults. Incoming state is validated and prepared off the main actor. Application verifies the local revision again, preserves current device-only fields, saves durably, and then notifies the model.

| State | Merge rule |
| --- | --- |
| Preferences | Independent Codable leaf registers; Home order and hidden sections are separate. `languageNudges/bengali`, `/english`, `/hindi`, `/tamil`, `/telugu`, `shuffleStyle` and `discoveryFamiliarity` merge independently |
| Likes, super likes and dislikes | One `(.reaction, id)` last-writer-wins register per recording holding `LibrarySyncReaction.liked(Track)`, `disliked(DislikedSong)`, `superLiked(Track)` or removal. Materialization rebuilds `favorites`, `superLikedIDs` and `disliked` from the live registers ordered by revision, so a promotion or demotion is a new revision that moves the song to the top of Liked Songs on every device |
| Playlists | Independent creation/deletion, name, track membership, metadata and fractional order positions; deleted playlist UUIDs cannot be revived by an offline edit |
| Removed playlist tracks | Membership hides the track; its order position is retained so concurrent removal/re-addition remains materializable |
| Followed artists | Membership is separate from automatic release checks, which cannot undo an unfollow |
| Listening | Stable session UUIDs with matching recording/start; cumulative acknowledged time takes the maximum, never a sum of downloaded totals |
| Lifetime receipts | `.lifetimeSession` uses the same session UUID and history generation; matching recording fingerprint/start joins seconds by maximum and qualification by logical OR |
| Typed Search selections | `.searchSelection` registers keyed by case-sensitive provider ID and entity kind; newest revisions first, with at most 20 materialized destinations |
| Legacy query terms | Separate `.search` registers and `searchFloor`; preserved without converting text into entities |
| Clears | Durable history/search generations reject stale replicas, including late offline writes in an older generation |
| History disable | Keeps saved history and retires pending player time, including a disable/reenable sequence received together |
| Corrections and lyric timing | Per-recording registers; undo/reset carries a tombstone |

Hybrid logical revisions handle wall-clock rollback and use writer UUIDs to resolve ties. Removals retain tombstones. Existing `LibraryHistoryRetention` rules remove expired payloads. The legacy and typed Search namespaces compact separately: each targets 40 mutations only where its own floor cannot erase a retained live item. Newer tombstones can remain above that target; structural playlist/reaction tombstones are not part of Search compaction.

### Lifetime Totals and Device-Local R17 State

`LibraryDocument.lifetimeListening` and its `.lifetimeSession` journal entries commit atomically. Detail retention removes events but keeps exact identity receipts, so overlapping migrations and old replicas cannot double-count time. Migration recovers only surviving sessions. History Off retains totals and blocks new local credit; Clear History removes receipts and advances `historyReset`, preventing stale-generation resurrection.

This is an exact capacity-limited rollup, not indefinite fixed-size storage. It allows at most 200,000 receipts per generation; the shared 200,000-register journal includes events and other collections and can bind earlier. Local/replica byte limits can also bind first. Exhaustion rejects the candidate and preserves durable state. [LIFETIME_STATISTICS.md](LIFETIME_STATISTICS.md) owns validation, capacity and coverage.

Moments evidence/switches, download queue/staging, export files, lyric choices and TV display state do not enter replicas. Moments uses the library's persisted privacy epoch to recover a failed separate-file erasure. Saved language corrections still sync and take precedence over Data API lyric-language metadata on each device.

### Typed Search history and clear boundaries

[`SearchSelection`](../Sources/Core/SearchSelection.swift) reuses `Track` and `MusicCollection`. Keys are `track:<recordingID>` or `collection:<kind>:<providerID>`; equal titles and different collection kinds do not collapse. `LibraryStore.recordSearchSelection(_:)` strips collection tracks before storing the destination metadata. Explicit result, recent and result-menu destination choices record selections. Typing, submitting a query or ordinary Home/player navigation does not. Reopening the local first item still advances its selected register so it can sort ahead of an unseen remote selection.

`searchSelectionFloor` is independent of legacy `searchFloor`, and each floor belongs to the current `searchReset` generation. [`LibrarySyncMerge`](../Sources/Sync/LibrarySyncMerge.swift) joins floors only within that generation and discards older-generation registers. Removal writes a tombstone; a deliberate later reopen can add the item again. `clearRecentSearches()` clears both materialized histories, advances `searchReset` even if empty and resets both floors. A stale replica with a later wall clock but the old generation cannot undo the clear.

[`LibraryStore.prepareCloudMerge` / `applyCloudMerge`](../Sources/Library/LibraryStore.swift#L558) reject a prepared merge after any newer local selection insert, promotion, removal or clear. A failed merge write cannot publish remote selections or echo them as a new local choice. `MusicAppModel.openArtist(_:searchSource:)` also captures `searchHistoryResetRevision` for name-only lookup so a late artist response cannot recreate cleared Search history. Storage displays the typed count and any retained legacy count; clearing covers both namespaces.

### Language preferences and derived evidence

`shuffleStyle` and `discoveryFamiliarity` use Fewer repeats/Balanced only when the field is absent. Every stored shuffle value, including Random with an absent or false `shuffleDefaultMigrated` flag, is preserved. The flag cannot distinguish an old default from an explicit choice. `migrateShuffleDefault()` therefore makes no edit; the flag remains Codable so existing journals remain readable. Sparse journals need no newly stamped defaults. A v1/v2 shuffle tombstone retains its historical Random meaning through `LibrarySyncPreferences.resetFields()`. Ordinary preference edits store the chosen value explicitly, including Fewer repeats. Invalid/null/unknown present shuffle values remain errors. Playback's optional occurrence mapping stays device-local.

`LanguageRecommendationNudges` uses fixed scalar fields rather than a replace-as-one dictionary. More, Less and explicit Automatic resets merge per language, without overwriting another device's adjustment to a different language. Missing fields decode as Automatic; saved legacy Hindi/English discovery preferences are not converted into nudges. A failed preference write leaves the applied preferences, journal and callbacks unchanged.

Clearing listening history preserves nudges and per-recording corrections. History off stops new learning but can display existing saved statistics and valid local cached evidence. Neither the derived classification cache nor the audio-retention projection adds a sync register or aggregate counter. [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) owns the classification cache, qualified-count weighting and local retention contract.

The R12/R13 preferences sync as independent leaf registers through the same `LibrarySyncPreferences` flattening, one register per scalar and one per nested field: `trailingTimeStyle`, `playerSwipeUpAction`, `playerBackgroundMotion`, `audioQuality`, `downloadsOverCellular`, `autoDownloadLikedSongs`, `autoDownloadSuperLikedSongs` (the two Download Liked Songs leaves merge independently; `autoDownloadScope` derives from both and All Liked wins in effect), `sponsorBlockSkipping`; `equalizer/isEnabled`, `equalizer/preset`, `equalizer/gains` (the ten-band array is one leaf) and `equalizer/preamp`; one `genreNudges/<family>` register per `GenreFamily`, merging per family like `languageNudges/hindi`; and `enabledCatalogSources` as one ordered leaf in `MusicSource` order (an ordered array rather than a set, so the register has one canonical form; a source unknown to the decoding build is dropped, an empty list stays empty). All of them decode leniently to their defaults on an unreadable value, and the merge refuses a remote value the lenient decoder would rewrite (`invalidData`) so a clamp never silently changes another device's edit. Sparse journals need no new revisions for the defaults. The following stay device-local and never enter a replica: the download tier under `Application Support/GanaBajana/Downloads`, `downloads-queue.json`, the import ledger `youtube-import.json`, the genre evidence file `genres.json`, the Song details cache under `Caches/Details`, export copies under `tmp/Export`, TipKit's tip datastore (the Hold to Super Like tip's display state), SponsorBlock segments and decrypted JioSaavn/Gaana stream URLs. Content an import creates (likes, playlists, follows) is ordinary library state and syncs like any other edit. [GENRE_PROFILE.md](GENRE_PROFILE.md), [EQUALIZER.md](EQUALIZER.md), [DOWNLOADS.md](DOWNLOADS.md) and [JIOSAAVN.md](JIOSAAVN.md) own the semantics of each preference.

Listening checkpoints encode affected event, recent and lifetime receipt payloads. Async checkpoint and cloud preparation perform validation, retention, encoding and lifetime summary preparation off-main. Fenced disk-baseline checking and atomic publication remain main-actor work. Manual/compatibility commits remain synchronous; R16 measurements do not establish R17 performance. [VERIFICATION.md](VERIFICATION.md) owns benchmark evidence.

## Native transport

The container is `iCloud.com.agraabhi.ganabajana`. Each installation writes its own `Documents/LibrarySync/<installation-uuid>.json`, joining all downloaded replicas and unresolved conflict versions. No global snapshot is replaced blindly. `NSFileCoordinator` protects reads and publication; publication verifies the own-file bytes and conflict identities observed during the read. `NSMetadataQuery` observes remote changes and download completion. Ubiquity-container resolution and file work run on a worker actor.

The local `LibrarySyncDevice/device.json` stores enablement, installation identity, opaque account binding and last-success time. Its directory is excluded from device backups before publication so a restored device receives a different replica identity. Account tokens are compared semantically, not by archive-byte order. Only an absent configuration file gets fresh defaults; a missing or wrongly typed field in an existing file is malformed. Configuration corruption or external replacement remains visible and blocks native work.

Generations and cancellation leases fence asynchronous work across disable, account changes, timeout and deinitialization. Each attempt has a 45-second deadline. Ordinary requests have a trailing 750-ms debounce. Recognized transient failures get at most two timed retries, after 5 and 30 seconds measured from the preceding failure. There is no periodic sync timer. Conflict versions remain unresolved conservatively, so clearing history suppresses it in merged app state but does not physically purge historical iCloud versions.

### Why sync runs, and how often

Sync keeps saved preferences, library edits and listening history available to the other installations. Its cadence follows writes and iCloud events, rather than a fixed upload interval.

| Trigger | Exact scheduling path |
| --- | --- |
| Real launch | `activateDeviceServices()` calls `start()` then `refresh()`. `start()` installs observers once and requests a refresh. The two requests coalesce behind the 750-ms debounce. Debug fixture/unit hosts cannot start the native transport. |
| Foreground activation | `PhoneSceneLifecycle` calls `activateDeviceServices()` when the phone scene becomes active. `start()` is idempotent; `refresh()` permits a fresh attempt and resets the retry budget when idle. It does not authorize an account rebind. |
| Shared local commit or successful reload | `LibraryStore.onSyncChange` requests sync after durability. Likes, preferences, history, recent positions and other shared edits use this path. Closely spaced writes coalesce. Requests during work queue at most one follow-up after successful completion; a failed attempt uses the bounded failure policy instead. |
| Listening | `PlayerController.tick()` checks for a checkpoint after at least 5 seconds of uptime while playback or pending listening needs it. `flushListeningProgress()` invokes the durable listening callback; `MusicAppModel` also records the current recent position. Both writes can request sync, normally coalescing into one attempt. Uninterrupted playback can therefore request sync roughly every five seconds, with an idle attempt starting 750 ms after the latest commit. In-flight work and failure backoff change that cadence. This is code-derived, not a measured device rate. History off prevents these listening/recent writes. |
| Background/inactive transition | The phone scene flushes listening before deactivating device services. This can request a final sync. Deactivation does not stop the sync controller. There is no dedicated sync `BGAppRefreshTask`; the registered background tasks check releases and regenerate stale mixes, whose durable library edits may themselves request sync. OS suspension can defer tasks and timers; completion in the background is not guaranteed. |
| iCloud files/downloads | `NSMetadataQueryDidFinishGathering` and `NSMetadataQueryDidUpdate` request a refresh. The query batches notifications for 1 second; the controller then debounces 750 ms. The query covers ubiquitous Documents JSON files and does not filter notifications by changed replica, so a notification is not proof of a new library edit. The transport reads only its LibrarySync directory. Own-file notifications may cause another read, but byte-identical publication does not rewrite the replica. |
| Account change | The identity notification stops the old query and invalidates active work before requesting an account check. A different account still pauses sync until explicit enablement. |
| Sync now / Retry sync | Bypasses debounce and cooldown, resets the retry budget, and reports an actionable failure even if that reason was already shown. When an attempt is in flight, the request waits for it and marks its outcome as manual; it does not start overlapping work. |
| Transient retry | At most two delayed attempts, 5 s then 30 s, each with its own 45-s deadline. Checkpoints and metadata bursts cannot shorten or extend those waits. After exhaustion, metadata or a new local commit may start another bounded sequence once 300 s of monotonic uptime have elapsed since the last failure. This allows recovery during continued playback after a long outage. It is an event-triggered cooldown, not a five-minute poll. Action-required failures allow only metadata probes after cooldown, not checkpoint retries. Foreground and manual retry can recover sooner. |

Queue/position-only, tip and pending-notification writes do not normally request sync. If a write also prunes expired shared history, that shared change does request it. No successful write claims that iCloud finished uploading or that another device received it.

A successful read that is waiting on downloads retires the transient retry budget and returns to metadata-driven waiting. A download-completion event already queued during that read can trigger its follow-up without waiting for failure cooldown. This does not record a successful sync date.

### Failure notifications and evidence

The pre-change code had no sync-operation logger. A read-only search of `artifacts/**/*.log` for `Breezy couldn.t sync`, `Your library changed while sync`, `invalid preference` and `event=sync_failed` returned no matches. The WP26 test logs inspected contain fixture Settings interactions, not evidence of this device's native iCloud error. No device store, real-account token or real-device log was inspected. The user's reported popup is not attributed to a particular native failure without its text and timestamp.

The source establishes these reproducible cases:

1. **A listening checkpoint races merge preparation.** `prepareCloudMerge()` captures the library and prepares off the main actor. Another shared commit, including a five-second listening checkpoint, can make it stale. Previously the store rejected it through `cloudStorageFailed()`, setting `library.errorMessage` and allowing a non-modal banner to recur after a later local write cleared the error. Current `ICloudLibrarySync` captures `localChangeGeneration` before preparation and checks it after the final account confirmation, before `applyAndEncode()` calls `applyCloudMerge()`. A changed generation throws retryable `localChangedDuringSync` without first setting a storage-error banner. Sustained or manual sync failure may still notify through the bounded failure policy. The store's revision and disk guards run on every actual apply. The gated regression test inserts a real listening commit after preparation and before final account confirmation. This source-established race is not a confirmed explanation of the owner's device popup.
2. **WP26 shuffle migration rewrites saved intent.** The old helper changed Random to Fewer repeats whenever the marker was false. Saved defaults and explicit choices have identical bytes, so the marker did not justify that change. The helper is now a no-op, preserving the saved style and marker without creating journal edits.
3. **Changing the default reinterprets a legacy reset.** A v1/v2 `shuffleStyle` tombstone paired with saved Random was materialized as Fewer repeats after WP26. `validateLocal()` then rejects the otherwise valid file as `sync journal and saved library consistency`. The reset fallback now remains Random for those journal versions. Missing fields on a new library still use Fewer repeats. The regression test constructs both journal versions and checks local-file and replica decoding without changing revisions.

Native availability, timeout, quota and permission failures remain possible, but none was observed on hardware in this investigation. `LibrarySyncFailure` classifies cancellation separately; recognized availability/network failures, timeout and local/remote revision races are retryable. Quota, permission, local-storage, invalid/future/unsupported data, size-limit and unclassified failures remain action-required and do not get timed retries. Unknown errors are not assumed transient.

The controller retains one actionable `errorMessage` in Settings until success or explicit disable. An automatic transient attempt first updates status and retries; after its retry budget is exhausted it also supplies the actionable message. A non-modal notification is delivered once per bounded failure class during an unsuccessful episode. Foreground or metadata probes do not reset that deduplication; manual Retry deliberately reports the failure again. Success clears the sync notice if it is still the displayed toast, without clearing an unrelated message. Action-required failures are visible immediately. Existing local-library recovery banners, configuration errors and account-change pauses remain available. The policy neither turns iCloud off on ordinary failures nor deletes replicas.

### Schema compatibility audit

| Change | Current reader | Older reader / preservation |
| --- | --- | --- |
| Shuffle default and marker | Saved Random and both marker values round-trip exactly; a missing style takes Fewer repeats; historical tombstones take Random. `LibraryCloudMergePreparation` excludes only shuffle style/marker registers and clock from recommendation invalidation. Content/history changes still invalidate it. | A reader without `shuffleDefaultMigrated` rejects a replica containing that leaf as newer data. The compatibility flag remains readable; no guessed migration is performed. |
| R12/R13 scalar preferences and equalizer | Codable remains the leaf inventory. Valid values round-trip. Out-of-range preamp, wrong-length gains or unreadable scalar values that a lenient decoder would rewrite remain rejected by strict remote validation. | A build without a leaf rejects it as newer data. Retry cannot add schema support; install the compatible build on every syncing device. |
| `genreNudges` | Every known family encodes, including Automatic, so known leaf paths remain stable. Unknown families reject as newer data; unknown values reject the strict round trip. | A build without these leaves cannot consume those edits. Files remain preserved. |
| `enabledCatalogSources` | An empty array is deliberate and survives. Known ordered values survive. A remote unknown source would be dropped by the model decoder, so strict sync validation rejects it instead. | No source is silently removed from a remote edit. |
| `dailyMix2`, `dailyMix3`, optional `focus` | The enum accepts all four kinds; regression coverage includes decoding, materialization and persistence. | The earlier enum rejects new kinds even in the historical v2 envelope. Lifetime receipts need v3 and super likes v4, so those envelopes are also `newerVersion` to earlier readers. These are source-established boundaries, not an observed device error; preserve older replicas rather than skipping unknown data. |
| `superLikedIDs`, `LibrarySyncReaction.superLiked`, `autoDownloadSuperLikedSongs` | v5 file, v4 journal and replica. v1 to v4 files and v1 to v3 journals/replicas read without restamping; an older format that carries the key or case is `invalidData`. `LibrarySyncValidation.validateValue` checks `track.id == key.id` for the new case, and `LibraryValidation.validate` rejects a super like outside favorites, a duplicate id or a conflicting dislike. | A build before R19, delivered build 6 included, rejects a v5 file or v4 replica as `newerVersion` and keeps it. |

### Metrics

Diagnostics use the existing local `OSLog.Logger` convention, subsystem `com.agraabhi.ganabajana`, category `LibrarySync`. There is no remote telemetry. Reasons and triggers come from closed enums; logs contain no file paths, account tokens, recording IDs, request IDs, exception text or replica identifiers.

| Event | Emitted when | Bounded fields / purpose |
| --- | --- | --- |
| `sync_started` | An attempt starts | Trigger `activation/localChange/filesChanged/retry/manual`, retry index 0–2; establishes actual cadence. |
| `sync_failed` | Current attempt fails | Failure class, retry index, `will_retry` and `notified` booleans on both branches; distinguishes retryable failures from action-required or deduplicated outcomes. |
| `sync_retry_scheduled` | A timed retry is scheduled | Attempt 1–2 and delay in milliseconds; production delays 5,000/30,000. |
| `sync_succeeded` | Publication and the device configuration's success date are durable | Retry count, including zero; does not assert remote delivery. |
| `sync_finished` | A current attempt returns | Monotonic duration in milliseconds. Late completions invalidated by timeout/disable cannot report completion for a newer attempt. |
| `sync_timeout` | The deadline retires an attempt | Monotonic elapsed milliseconds; the same attempt also emits `sync_failed` with reason `timeout`. |
| `sync_waiting` | Missing account or pending downloads/gathering | Reason `account/downloads`; download count capped at the file bound. |
| `sync_cancelled`, `sync_paused` | Current cancellation, or account-change pause | No identifiers; pause reason `account_changed`. |

Tests assert failure classification, retry counts and user-notification decisions through the fake transport/callback. OSLog emission itself is not intercepted by unit tests; a real-account diagnostic capture is still required to validate recorded cadence and platform errors.

| Limit | Bound |
| --- | --- |
| Replica or conflict file | 64 MiB |
| One read batch | 256 MiB, at most 128 files/versions |
| Local materialized library plus journal | 128 MiB |
| Registers | 200,000 |
| Device configuration | 64 KiB |

Exceeding a limit preserves existing files and reports an error. Foundation file reads distinguish a missing new file from malformed storage and refresh URL resource values before checking replacements.

## App integration and verification

`MusicAppModel.cloudSync` owns one controller for the existing library. Real app launches call `activateDeviceServices()` and foreground activation refreshes sync. The app lifecycle and controller `start()` guard prevent native iCloud activation in fixture and unit hosts, including an explicitly injected native transport. Startup never calls `setEnabled(true)`, which belongs to an explicit user action and permits account rebinding. `onCloudSyncApplied(previousPreferences, recommendationsChanged)` reconciles playback/DNS/cache services after the durable merge. Preparation compares state without the shuffle-style register and clock: shuffle-only/clock-only updates preserve Home work, while mixed content/history or retention changes still refresh discovery. The callback does not navigate, replace the queue or open the player. Privacy-boundary callbacks retire captured listening first.

Phone Debug/Release use `Signing/iCloud.entitlements`; the opt-in CarPlay configurations request iCloud plus CarPlay. The Watch uses neither entitlement and continues to receive the phone's library through WatchConnectivity. Historical signed Debug/Release and build-3 checks passed with the exact iCloud container in the app entitlements and profile. Those receipts do not verify R6 formats or native two-device delivery. Account-token and platform conflict/download behavior still need account-enabled device acceptance.

Unit coverage includes merge algebra, simultaneous edits, removals, legacy migration, clears, retention, crash/write recovery, account and cancellation races, no echo writes, and actual-player continuity. Default-on tests cover fresh configuration, durable opt-out, unavailable iCloud/local preservation, and account-change pauses across restarts. `AppModelCloudSyncTests` covers model preference application and preserved navigation. `GanaBajanaICloudSettingsUITests` covers On/Off persistence and status semantics; `GanaBajanaSettingsOrganizationUITests` covers transition defaults and Settings navigation. Fixture UI never claims native cloud delivery. No new remote telemetry is emitted by sync or artist-photo lookup.

| R6 case | Contract | Type / state |
| --- | --- | --- |
| `LibrarySearchSelectionTests.`[`testV1AndV2ReadersPreserveQueriesPreferencesAndJournalRevisionsUntilARealEdit`](../Tests/LibrarySearchSelectionTests.swift#L256) | Legacy local-file migration without guessed entities or restamped revisions | Unit/local files |
| `LibrarySyncSearchSelectionTests.`[`testVersionOneReplicaAndJournalUpgradeWithoutRestampingRevisionsOrInventingSelections`](../Tests/LibrarySyncSearchSelectionTests.swift#L322) | Replica/journal read-upgrade | Unit/local merge |
| `LibrarySyncSearchSelectionTests.`[`testTypedFloorIsIndependentOfLegacyQueriesAndScopedToTheSearchReset`](../Tests/LibrarySyncSearchSelectionTests.swift#L142), [`testFortyNewerRemovalsCannotEvictAnOlderLiveDestinationAcrossRestartOrMerge`](../Tests/LibrarySyncSearchSelectionTests.swift#L214) | Independent floors and retained live destinations | Unit/local merge |
| `LibrarySyncSearchSelectionTests.`[`testPreparedMergeRejectsEveryNewSelectionMutationIncludingAnIdenticalPromotion`](../Tests/LibrarySyncSearchSelectionTests.swift#L265) | New local intent fences prepared cloud work | Unit/local merge |
| `ListeningLanguagePersistenceTests.`[`testConcurrentNudgeEditsMergePerLanguageWithoutChangingOtherPreferenceRegisters`](../Tests/ListeningLanguagePersistenceTests.swift#L116), [`testResetToAutomaticIsDurableAndCannotBeUndoneByAStaleReplica`](../Tests/ListeningLanguagePersistenceTests.swift#L148) | Independent adjustments and explicit Automatic reset | Unit/local merge |

R7 preference coverage lives in [LibraryPlaybackDiscoveryPreferencesTests](../Tests/LibraryPlaybackDiscoveryPreferencesTests.swift), [LibrarySyncPlaybackDiscoveryPreferencesTests](../Tests/LibrarySyncPlaybackDiscoveryPreferencesTests.swift) and [AppModelListeningControlsTests](../Tests/AppModelListeningControlsTests.swift). These include sparse-journal reads, independent edits/resets, failures, mixed-change invalidation and native audio continuity.

[LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md#test-coverage) links model, native-playback and UI cases, with actual local diagnostic fields in its Metrics section. Executed counts belong only in [VERIFICATION.md](VERIFICATION.md).

### Investigation regression coverage and coordinator selectors

The additions below were **authored, unexecuted by the original investigator**. Consult the coordinator's R15 [VERIFICATION.md](VERIFICATION.md) entry for subsequent execution. Fixtures use isolated local directories and fake cloud transport; they do not establish native iCloud delivery.

| Case / selector under `GanaBajanaTests/` | Branch covered | Type |
| --- | --- | --- |
| `LibrarySyncFailureRecoveryTests/testListeningCheckpointDuringPreparationDoesNotBecomeALibraryErrorOrPopup` | Durable listening commit between preparation and apply; no library error/banner, no stale publication, manual recovery includes the checkpoint | Unit, real LibraryStore plus fake transport |
| `LibrarySyncFailureRecoveryTests/testTransientRetriesAreBoundedAndCheckpointsRespectCooldown` | Two retries, exhaustion, ten checkpoint/metadata bursts, 300-s event cooldown, deduplication, manual retry and success reset | Unit |
| `LibrarySyncFailureRecoveryTests/testTransientRetryRecoversAutomaticallyWithoutANotification` | One transient conflict resolves on a timed retry without notifying | Unit |
| `LibrarySyncFailureRecoveryTests/testDownloadCompletionDuringARetryIsNotHeldBehindFailureCooldown` | A recovered transport's pending-download read keeps the queued metadata completion and finishes promptly | Unit |
| `LibrarySyncFailureRecoveryTests/testActionRequiredFailuresStayVisibleAndDistinctWithoutTimedRetries` | Newer schema and quota remain actionable; same-class probes deduplicate; manual attempts report again | Unit |
| `LibrarySyncFailureRecoveryTests/testDisableCancelsPendingRetryAndIdentityChangeStillPausesTheAccount` | Retry cancellation on disable; new identity cannot upload old account state | Unit |
| `LibrarySyncFailureRecoveryTests/testTimeoutRecoveryRejectsTheLateReadWithoutReportingASuccessForIt` | Timeout lease invalidation and recovery before an old read completes | Unit |
| `LibrarySyncFailureRecoveryTests/testCancellationDoesNotNotifyOrStartARetry` | Cancellation is not an actionable failure or timed retry | Unit |
| `LibrarySyncFailureRecoveryTests/testManualRequestJoiningAnAutomaticAttemptReportsItsFailure` | In-flight manual request receives actionable failure without overlapping work | Unit |
| `LibrarySyncFailureRecoveryTests/testFailureClassificationRetriesOnlyRecognizedTransientErrors` | Closed failure classes; quota/permissions/schema/storage/certificate errors are not guessed transient | Unit |
| `LibrarySyncSchemaCompatibilityTests/testLegacyRandomTombstoneDoesNotBecomeAnInvalidLocalJournalAfterDefaultChange` | v1/v2 reset meaning survives strict local and remote validation; missing field still defaults Fewer repeats | Unit, serialization |
| `LibrarySyncSchemaCompatibilityTests/testSavedRandomAndMigrationMarkerRoundTripWithoutInventingAnEdit` | Saved Random with false/true marker stays unchanged through decode, migration helper and cloud preparation | Unit, serialization |
| `LibrarySyncSchemaCompatibilityTests/testCurrentPreferenceLeavesAndAllDailyMixKindsSurviveReplicaAndLocalRoundTrips` | Current preferences, empty sources, equalizer and dailyMix2/3 survive replica and local persistence | Unit, local-file integration |
| `LibrarySyncSchemaCompatibilityTests/testUnknownAndLenientlyRewrittenRemotePreferencesStillBlockPublicationAndPreserveBytes` | Unknown leaves/families, rewritten genre/source/equalizer values and null shuffle block replacement | Unit, fake transport plus local files |
| `AppModelCloudSyncTests/testSyncNoticeClearsAfterRecoveryWithoutDismissingAnUnrelatedToastOrNavigating` | Callback wiring clears its own notice, preserves another toast and navigation | Unit, app-model integration |
| `ICloudLibrarySyncTests/testForegroundRefreshCanRecoverBeforeTheScheduledRetry` | Existing recovery case renamed to match the bounded retry policy | Unit |
| `LibrarySyncPlaybackDiscoveryPreferencesTests/testPreferenceTombstonesRestoreDefaultsAndRemainDurableWithoutSyntheticEdits` | Existing tombstone expectation corrected to historical Random | Unit |

Coordinator regression scope includes the two new suites in full plus `GanaBajanaTests/ICloudLibrarySyncTests`, `GanaBajanaTests/LibrarySyncPlaybackDiscoveryPreferencesTests` and `GanaBajanaTests/AppModelCloudSyncTests`. Existing `LibrarySyncPersistenceTests`, `LibrarySyncSearchSelectionTests`, `LibrarySyncHistoryTests`, `LibrarySyncTransportTests` and `LibrarySyncCheckpointTests` cover atomic/revision guards, clears, malformed-file preservation and checkpoint journaling. `SettingsShufflePreservationTests` and `AppModelListeningControlsTests` cover the corresponding preference/model paths.

Current `AppModelListeningControlsTests` replaces the obsolete overwrite expectations with saved-Random/bytes/revision preservation on launch, reload and relaunch, explicit Random selection, missing-field defaults without writes, and compatibility-marker round trips without inferred intent. `MusicAppModel.migrateShuffleDefaultIfNeeded()` remains a compatibility call to the no-op helper; it must not create preference or journal edits.

**Unresolved real-account integration checks:** capture the popup text and its timestamp/build on the affected installation; observe `LibrarySync` logs during at least a minute of listening and a foreground/background transition; confirm same-build two-device preference/history convergence; induce and recover from offline/download-pending and quota conditions; verify one sustained notice, explicit Retry feedback and recovery clearing; verify account-switch pause and late publication cancellation. Mixed-version replicas containing new preference leaves or dailyMix2/3 should remain preserved on the older build until that installation is updated. Native file-coordination/conflict versions, iCloud upload completion and background suspension cannot be established by the fake transport tests. No hardware reproduction or executed test count is claimed here.
