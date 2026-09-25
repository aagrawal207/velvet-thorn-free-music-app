# iCloud library sync

**R7 source, 23 September 2026 local time.** Typed Search selections, independent language nudges and the new Shuffle order/Discovery balance preferences describe the working tree, not uploaded build 3. [VERIFICATION.md](VERIFICATION.md) records current checks, preserves earlier sync evidence and identifies native two-device acceptance limits.

## User behavior

**Settings > Library & iCloud > iCloud sync** manages sync through the listener's iCloud Drive. Sync defaults on when this device has no saved configuration. A saved Off choice stays off. A restored library whose backup-excluded device configuration is absent receives the enabled default and a fresh replica identity. The app keeps a local library for offline use; turning sync off keeps both the local library and existing iCloud files. Offline edits, including removals, are merged when sync resumes.

Sync includes all Codable `UserPreferences` fields, likes/dislikes, playlists, followed artists and release metadata, listening history, recents, typed Search selections, retained legacy queries, generated mixes, saved song metadata, recording-language corrections and lyric timing. Preferences include app icon, Home layout, playback, DNS, remote-fallback, cache-size choices and five independent language nudges. The current queue/position, pending local notification deliveries, StoreKit ledger, credentials, cached audio/artwork and derived language-cache file remain device-local. Language shares and retention scores are recomputed locally, not transmitted as aggregate counters.

An empty `appIconID` preserves an older installation's system-selected icon. The first active launch captures an installed alternate; explicit choices use stable IDs. Remote choices apply through the model's serialized `AppIconController` while a phone/iPad scene is active. Unsupported platforms retain the preference without trying to change the system icon.

The green cloud and On label indicate the enabled preference. Status separately distinguishes missing iCloud access, pending downloads, active work and errors. **Sync now** retries explicitly. “Handed to iCloud” means the coordinated local ubiquity write succeeded; it does not confirm upload or delivery to another device. A different Apple Account disables sync until the user enables it for that account. Sign-out keeps local data, and reconnecting the same account keeps its binding.

## Storage and merging

`Sources/Sync/` owns the journal, merge rules, native transport and observable `ICloudLibrarySync`. `LibraryStore` remains the only owner of saved library state.

| Stored format | Current writes | Current reads |
| --- | --- | --- |
| `LibraryDocument` / `LibraryPersistence.currentVersion` | 3 | 1, 2, 3 |
| `LibrarySyncState` journal | 2 | 1, 2 |
| `LibrarySyncReplica` envelope | 2 | 1, 2 |

Validated older formats upgrade on a real write or sync preparation, not by replacing bytes during a read. Existing mutation revisions are retained. Legacy versions cannot carry typed selections/floors under their old version number. Corrupt, inconsistent, unsupported or future-version files are preserved and block replacement. This is read-upgrade compatibility; older binaries are not promised to accept R6 writes.

Shared edits and their revisions are saved in the same atomic `library.json` commit, including while sync is off. Legacy seeding includes populated records and nondefault preferences. A new empty device therefore cannot erase an existing remote library or replace remote preferences with defaults. Incoming state is validated and prepared off the main actor. Application verifies the local revision again, preserves current device-only fields, saves durably, and then notifies the model.

| State | Merge rule |
| --- | --- |
| Preferences | Independent Codable leaf registers; Home order and hidden sections are separate. `languageNudges/bengali`, `/english`, `/hindi`, `/tamil`, `/telugu`, `shuffleStyle` and `discoveryFamiliarity` merge independently |
| Likes/dislikes | One reaction register per recording, including removal |
| Playlists | Independent creation/deletion, name, track membership, metadata and fractional order positions; deleted playlist UUIDs cannot be revived by an offline edit |
| Removed playlist tracks | Membership hides the track; its order position is retained so concurrent removal/re-addition remains materializable |
| Followed artists | Membership is separate from automatic release checks, which cannot undo an unfollow |
| Listening | Stable session UUIDs with matching recording/start; cumulative acknowledged time takes the maximum, never a sum of downloaded totals |
| Typed Search selections | `.searchSelection` registers keyed by case-sensitive provider ID and entity kind; newest revisions first, with at most 20 materialized destinations |
| Legacy query terms | Separate `.search` registers and `searchFloor`; preserved without converting text into entities |
| Clears | Durable history/search generations reject stale replicas, including late offline writes in an older generation |
| History disable | Keeps saved history and retires pending player time, including a disable/reenable sequence received together |
| Corrections and lyric timing | Per-recording registers; undo/reset carries a tombstone |

Hybrid logical revisions handle wall-clock rollback and use writer UUIDs to resolve ties. Removals retain tombstones. Existing `LibraryHistoryRetention` rules remove expired payloads. The legacy and typed Search namespaces compact separately: each targets 40 mutations only where its own floor cannot erase a retained live item. Newer tombstones can remain above that target; structural playlist/reaction tombstones are not part of Search compaction.

### Typed Search history and clear boundaries

[`SearchSelection`](../Sources/Core/SearchSelection.swift) reuses `Track` and `MusicCollection`. Keys are `track:<recordingID>` or `collection:<kind>:<providerID>`; equal titles and different collection kinds do not collapse. `LibraryStore.recordSearchSelection(_:)` strips collection tracks before storing the destination metadata. Explicit result, recent and result-menu destination choices record selections. Typing, submitting a query or ordinary Home/player navigation does not. Reopening the local first item still advances its selected register so it can sort ahead of an unseen remote selection.

`searchSelectionFloor` is independent of legacy `searchFloor`, and each floor belongs to the current `searchReset` generation. [`LibrarySyncMerge`](../Sources/Sync/LibrarySyncMerge.swift) joins floors only within that generation and discards older-generation registers. Removal writes a tombstone; a deliberate later reopen can add the item again. `clearRecentSearches()` clears both materialized histories, advances `searchReset` even if empty and resets both floors. A stale replica with a later wall clock but the old generation cannot undo the clear.

[`LibraryStore.prepareCloudMerge` / `applyCloudMerge`](../Sources/Library/LibraryStore.swift#L558) reject a prepared merge after any newer local selection insert, promotion, removal or clear. A failed merge write cannot publish remote selections or echo them as a new local choice. `MusicAppModel.openArtist(_:searchSource:)` also captures `searchHistoryResetRevision` for name-only lookup so a late artist response cannot recreate cleared Search history. Storage displays the typed count and any retained legacy count; clearing covers both namespaces.

### Language preferences and derived evidence

`shuffleStyle` and `discoveryFamiliarity` use Random/Balanced only when the field is absent. Sparse current-version journals remain valid without newly stamped defaults; explicit choice/reset edits create their own registers. Invalid/null/unknown present values are preserved as errors, not replaced with defaults. Playback's optional occurrence mapping stays device-local and does not add a shared register.

`LanguageRecommendationNudges` uses fixed scalar fields rather than a replace-as-one dictionary. More, Less and explicit Automatic resets merge per language, without overwriting another device's adjustment to a different language. Missing fields decode as Automatic; saved legacy Hindi/English discovery preferences are not converted into nudges. A failed preference write leaves the applied preferences, journal and callbacks unchanged.

Clearing listening history preserves nudges and per-recording corrections. History off stops new learning but can display existing saved statistics and valid local cached evidence. Neither the derived classification cache nor the audio-retention projection adds a sync register or aggregate counter. [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) owns the classification cache, qualified-count weighting and local retention contract.

Listening/recent checkpoints encode only their changed journal payload. Playback, tip and notification-only writes do not construct shared projections. General edits reuse one before/after projection pair. Full local validation, retention and atomic file encoding remain synchronous; the benchmark evidence belongs in [VERIFICATION.md](VERIFICATION.md).

## Native transport

The container is `iCloud.com.agraabhi.ganabajana`. Each installation writes its own `Documents/LibrarySync/<installation-uuid>.json`, joining all downloaded replicas and unresolved conflict versions. No global snapshot is replaced blindly. `NSFileCoordinator` protects reads and publication; publication verifies the own-file bytes and conflict identities observed during the read. `NSMetadataQuery` observes remote changes and download completion. Ubiquity-container resolution and file work run on a worker actor.

The local `LibrarySyncDevice/device.json` stores enablement, installation identity, opaque account binding and last-success time. Its directory is excluded from device backups before publication so a restored device receives a different replica identity. Account tokens are compared semantically, not by archive-byte order. Only an absent configuration file gets fresh defaults; a missing or wrongly typed field in an existing file is malformed. Configuration corruption or external replacement remains visible and blocks native work.

Generations and cancellation leases fence asynchronous work across disable, account changes, timeout and deinitialization. A sync operation has a 45-second deadline and a 750-ms debounce. Retries come from user actions, foreground activation, local edits and metadata notifications; there is no timed retry loop. Conflict versions remain unresolved conservatively, so clearing history suppresses it in merged app state but does not physically purge historical iCloud versions.

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
