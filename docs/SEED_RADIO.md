# Song and Artist Radio

Search > Radio starts a recommendation queue from one chosen song or artist. The original seed stays fixed as playback advances. Tune Radio changes future additions, and Listen Again keeps up to 20 recent seeds with their tuning on this device. Availability depends on the provider and eligible recordings: a session can exhaust its results or fail, and does not promise endless playback.

This document describes the implemented seed-radio path. `ExperienceRadioEngine`, the experience-radio model APIs and `RadioSetupView` remain for compatibility; the new Radio page has no mood-station grid or setup step. Public Live Radio is a separate destination and playback mode, documented in [LIVE_RADIO.md](LIVE_RADIO.md).

Build, test and device receipts are recorded in [VERIFICATION.md](VERIFICATION.md). The coverage below maps source tests to behavior; each receipt specifies which cases ran.

## User Behavior

### Choosing a Seed

- **Search > Radio:** search Songs or Artists, then tap a result to start. Search defaults to Songs. Its native search field reads “Songs or artists.” Opening the page does not start playback or present setup.
- **Start with a Song:** up to eight distinct audio recordings, drawn in order from Super Likes, recently played songs when history is enabled, then Likes. Disliked songs are excluded.
- **Song menus and Player More:** Start Radio uses that exact `Track`. Player More dismisses Song Options after submitting the start.
- **Artist pages:** Start Radio uses the displayed artist's `ArtistCredit`, including the provider ID when available.
- **Listen Again:** tapping an entry starts its saved original seed and tuning. Removing an entry changes the recent-radio list, not playback.

Starting radio leaves the listener on the browsing surface. It does not automatically open the full player. The Radio page and Queue sheet show the original `<seed title> Radio`, current tuning, startup cancellation/retry, and continuation progress/retry.

A song seed needs no recommendation request before acceptance. The engine validates the exact recording and uses it as the anchor. An artist seed first resolves up to three eligible credited recordings. Until that lookup succeeds and passes the start guards, the existing queue stays installed.

**Current-song attachment:** if the selected starting recording is already current, radio attaches to its exact selected occurrence. It preserves position, installed player item, queue order, manual duplicates and playing/paused intent. It does not seek, restart, resolve the song again or increment `controlRevision`. Attachment resets Repeat to Off and starts a fresh radio session and retention provenance. Existing queue entries are not retroactively tagged as generated.

**Different starting recording:** the model calls `player.play([first], isRadio: true, shuffle: false)`, replacing the queue with the starting recording and requesting playback from its beginning. Stream resolution can still fail through the normal player path; accepted radio startup is not proof of audible playback.

A restored queue is paused and is not an active seed-radio session. Listen Again can explicitly attach radio to its already-current recording without resuming it. Ordinary playback, a replacement shuffled queue, and Live Radio retire radio context. Returning from Live Radio restores the music queue paused, not the old radio session.

### Tuning

`RadioTuning()` defaults to **Balanced · Automatic Language**. It is session tuning, not a write to the global discovery preferences.

| Control | Implemented Selection |
| --- | --- |
| Familiar (`familiar`) | Heard recordings first, then unheard recordings if available. |
| Balanced (`balanced`) | Interleaves heard and unheard recordings in proportion to the available pools through `RecommendationEngine.interleave(familiar:fresh:)`. |
| Discover (`newMusic`) | Unheard recordings first, then heard recordings if available. |
| Automatic Language (`nil`) | Soft ranking from the current `ListeningLanguageProfile`; unknown and minority languages remain eligible. |
| Bengali / English / Hindi / Tamil / Telugu (`bn` / `en` / `hi` / `ta` / `te`) | Requires matching recording-language evidence or a saved correction. Unknown and merely likely language results are excluded. |

The heard set comes from `tasteProfile().heardTrackIDs` when listening history is enabled; with history off, it is the set of favorite recording IDs. Familiar and Discover prioritize pools rather than guarantee a percentage or an all-known/all-new batch.

Done applies the draft to **future radio additions**. Already queued songs retain their places, including songs outside the new language choice. The original explicit seed can also differ from the chosen language: an English song can start a saved Hindi-tuned radio, with Hindi filtering applied to recommendations after that seed. Startup chooses its first anchor with default tuning rather than filtering away the listener's explicit selection.

Automatic language evidence is not frozen for the session. Each refill reads the current profile, and the model reads it again after the provider await before accepting additions. Saved recording corrections therefore affect later additions. The engine uses existing evidence; it does not launch language recognition for every candidate. [SONG_LANGUAGES.md](SONG_LANGUAGES.md) and [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) own evidence and profile rules.

Cancel dismisses Tune without applying the draft. The sheet captures the session UUID and seed ID. If a new session starts, or another start is pending, its controls become disabled and Done cannot apply that stale draft. Applying a changed tuning retires in-flight recommendations without replacing the queue. If continuation was pending or had failed, the model retains an explicit recovery action with “Radio updated. Choose Try More Songs to continue with these settings.”

## API and Ownership

Paths below are relative to the repository root.

| Owner | API / State | Contract |
| --- | --- | --- |
| `Sources/Core/RadioSeed.swift` | `RadioSeed.song(Track)`, `.artist(ArtistCredit)` | Codable, Hashable, Sendable seed. Song identity is `song:<track.id>`; artist identity is `artist:<artist.id>`, falling back to the normalized name only when the ID is absent. Provider-prefixed IDs remain intact. |
| Same | `RadioTuning(familiarity:language:)`; `RadioHistoryEntry(seed:tuning:startedAt:)` | Tuning uses `DiscoveryFamiliarity` and optional `ArtistSongLanguage`. Entry identity is `seed.id`. |
| `Sources/Recommendations/SeedRadioEngine.swift` | `anchors(for:disliked:) async throws -> [Track]` | Validates a song without network access, or resolves a bounded artist anchor set. |
| Same | `refill(anchors:round:excluding:disliked:tuning:heardTrackIDs:languageProfile:forceRefresh:) async throws -> [Track]` | Stateless bounded recommendation fetch; `forceRefresh` defaults to false. Caller owns the original anchors and round. |
| Same | `select(_:excluding:disliked:tuning:heardTrackIDs:languageProfile:limit:) -> [Track]` | Local eligibility, deduplication and ranking; default limit eight. |
| `Sources/App/MusicAppModel.swift` | `startRadio(seed:tuning:) -> Task<Void, Never>`; `cancelSeedRadioStart()`; `retrySeedRadioStart()` | Owns acceptance and pending-start/error state. Startup retry retains the pending seed and tuning. |
| Same | `tuneRadio(_:)`; `retryRadioContinuation()` | Changes future selection or requests a fresh continuation. Private `continueSeedRadio(forceRefresh:)` supplies additions to player callbacks. |
| Same | `activeRadioSeed`, `seedRadioSessionID`, `radioTuning`, `radioSuggestions`, `seedRadioHistory` | UI-facing session/history state. Session exposure requires `player.isRadioSession`. |
| `Sources/Playback/PlayerController.swift` | `configureSeedRadio(keeping:) -> Bool`; `refreshSeedRadioRequests()` | Attaches only to the matching current music recording; refresh cancels recommendation work without queue replacement. |
| Same | `appendAutoplay(_:)`; `selectQueueTrack(at:) -> Bool` | Appends eligible distinct IDs or selects an existing occurrence while retaining radio provenance. |
| `Sources/Radio/RadioHistoryStore.swift` | `init(url:historyEpoch:deferLoading:)`; `synchronize(historyEpoch:enabled:)`; `record(seed:tuning:historyEpoch:enabled:now:)`; `remove(id:)`; `reload(historyEpoch:enabled:)` | Main-actor observable local store with failure-preserving writes. A nil URL is memory-only. |
| `Sources/Views/RadioSearchModel.swift` | `request(isOffline:)`; `load(_:catalog:isOffline:) async`; `retry()`; `cancel()` | Independently owns trimmed query, filter, attempt and request generation for the Radio page. |

`MusicAppModel` installs `player.onQueueExhausted` and `onQueueEnded`. `autoplayTracks(after:final:)` routes an active seeded session to `continueSeedRadio`; the callback's ending track never replaces the original seed. Production uses the existing catalog. The optional `seedRadioCatalog` initializer injection is used by deterministic fixtures.

### Anchors, Filtering and Provider Calls

A usable song must pass `RadioSeed.isValid`, have `isAudioRecording == true`, a nonempty normalized core title, and pass `RecommendationEngine.isRecommendable(track, languages: [])`. Seed validation reuses `LibraryValidation.validateTrack`, with song ID/title limits of 512/2,048 UTF-8 bytes. An artist requires a nonblank name of at most 512 bytes and an absent or nonempty ID of at most 512 bytes.

A linked artist requires one `catalog.artist(id:)` call. A name-only artist first performs one `catalog.search(query:filter:continuation:)` with `.artists` and `nil` continuation, inspecting only the first 100 collections for a normalized exact name. The returned artist page must match the requested ID. Only the first 100 top songs are considered; credit checks and `ArtistSpotlight.displaySongs` produce at most three anchors. Unrelated popular songs and conflicting linked artist IDs do not establish credit. No artist-search continuation is followed.

For refill, eligible original anchors rotate by `max(0, round) % eligible.count`. A successful nonempty model selection increments the round. Newly queued or played songs never become anchors. A newly disliked anchor is skipped; if none remain, the request fails rather than borrowing a queue song.

| Refill Mode | Sequential Attempts, Stopping at the First Nonempty Eligible Batch |
| --- | --- |
| Normal, one eligible anchor | First anchor normally; the same anchor once with `forceRefresh: true`. |
| Normal, multiple eligible anchors | Rotated first anchor normally; one alternate anchor normally; first anchor once fresh. |
| Explicit continuation retry | First anchor fresh; one alternate normally if available. No additional fresh retry. |

Attempts after the first occur only when a successful response has no eligible songs. A provider error, rate limit/cooldown, invalid response, timeout or cancellation exits immediately. Fresh requests bypass stale cached responses, not provider cooldowns. `CompositeCatalog` routes radio by the seed ID's provider prefix, including saved seeds from a source disabled for Search.

Selection inspects the first 100 candidates. It excludes queued IDs, the recent exclusion buffer, original anchors during engine refill, dislikes and recognized aliases. Dislike aliases require both matching version titles and the same normalized performer set, not title alone. Recording deduplication reuses artist-spotlight identity rules: known language conflicts, linked-credit conflicts, meaningful versions and uncertain durations stay distinct.

Candidates are ranked by `languageProfile.multiplier(for:) / (1 + providerOffset * 0.01)`, then ordered by the familiarity pools. Distinct selection caps each primary artist at two recordings and prefers a different adjacent artist, including against the existing queue tail, when a candidate permits it. These constraints can return fewer than eight songs. The model repeats selection against the current queue, dislikes and language evidence after awaiting the provider, so intervening edits are respected.

## Refill, Queue Retention and Bounds

Seed radio continues independently of the global Autoplay preference. `configureSeedRadio` sets the preemptive refill threshold to **three upcoming occurrences**. `requestAutoplayIfNeeded()` requests when upcoming count is at most three, provided playback is wanted, the player is online and standby-eligible, Repeat is Off, no interruption is active, and that selected occurrence has not already requested a batch. Attachment alone does not force a paused player to play or request recommendations.

If the song ends while its request is pending, the player can wait for that request and advance into accepted additions. With no additions it remains stopped. Seed radio does not receive ordinary Autoplay's extra final-exhaustion retry; Try More Songs owns explicit recovery. A manual successful append grows a paused queue without restarting it unless it is truly ended at the last occurrence with Repeat Off and no pending wait. In that ended case, append selects the first new song and resumes, except during an interruption.

| Bound | Scope |
| --- | --- |
| 8 songs | Default maximum returned per refill batch; not a minimum. |
| 8 seconds | `PlaybackDeadline` budget around each anchor lookup/search and each radio request. |
| 23 seconds | Outer deadline around one refill sequence. This is not the artist-start deadline. |
| At most 3 radio calls | One normal multi-anchor refill; one-anchor and explicitly fresh calls have the smaller bounds above. |
| 3 anchors / 100 candidates | Frozen artist anchor maximum and each engine candidate-prefix limit. |
| 320 milliseconds / 30 results | Radio Search debounce and maximum displayed distinct songs or artists from one result page; no pagination. |
| 8 suggestions / 20 recent seeds | Radio page suggestions and Listen Again capacity. |
| 40 previous generated selections | Retention limit for generated occurrences that have actually been selected and currently precede the selected occurrence. |
| 128 recordings | Memory-only exclusion buffer of pruned generated tracks, unique by recording ID. |
| 1 MiB | Radio-history read and encoded-write limit. |

The time values are configured budgets, not measured startup, refill, playback or end-to-end latency. `PlaybackDeadline` races work against a timer and cancellation, completes once and cancels the losing tasks. Provider result acceptance still requires the generation guards below.

### Occurrence-Safe Retention

Retention uses queue-entry UUIDs, not track IDs or array position as a substitute for listening history. Only appends made after seed-radio attachment enter `generatedRadioEntryIDs`. `startListeningSession` records selection recency for those occurrences, including selections made while paused. This is not a qualified-listen threshold.

Pruning keeps the 40 most recently selected generated occurrences among those now before the current occurrence. An unselected occurrence is never pruned just because shuffle, reorder or a jump placed it earlier in the array. The current occurrence and all upcoming occurrences are protected, even when they were previously selected. Manually enqueued occurrences and entries present at attachment are never removed by this retention policy. A manual duplicate survives removal of its generated twin.

`PlaybackQueue.removePreviousEntries(withIDs:)` removes only eligible previous UUIDs from both active and original order. Surviving occurrences keep their identity and valid `PlaybackSnapshot.originalQueueIndices` mapping for restore/unshuffle. Housekeeping does not seek, reinstall audio, change paused intent or add a transport revision. Explicit user queue removal remains available.

Pruned tracks enter `radioRecentTracks` in selection-recency order, deduplicated by ID and trimmed to the last 128. Both engine exclusion and player insertion consult it. This is bounded repeat protection, not lifetime no-repeat history: after eviction, a recording can become eligible again. Forty is not a total queue cap; manual, upcoming and never-selected entries can make the queue larger. Tuning preserves retention state. A new attachment or replacement play/shuffle/restore/live session resets provenance and exclusion memory without retroactively tagging surviving entries.

## Failure, Recovery and Races

| Condition | Implemented Outcome |
| --- | --- |
| Library has never loaded successfully | Start is refused with “Reload your saved library before starting radio. Your radio history has been kept.” The pending choice can be retried after recovery. |
| Known offline | Search shows offline guidance without fetching; start controls are disabled. The model refuses starts and refills without provider requests. Existing queue/cache playback remains available through normal player behavior. |
| Invalid or disliked song seed | Startup error; no recommendation request or accepted Listen Again entry. |
| Missing eligible artist recordings or failed artist lookup | Startup error; old queue stays installed. Try Again retries the pending seed and tuning. |
| Empty/fully filtered refill | Bounded fallback attempts, then `SeedRadioError.exhausted(language:)`. Explicit-language text names the language, explains unknown-language exclusion and suggests Automatic Language. |
| Refill provider failure | `radioContinuationError`, separate from `seedRadioError`; seed, tuning and installed queue remain. Try More Songs uses `forceRefresh: true`. |
| History read/write failure | Separate `seedRadioHistory.errorMessage` and Reload Radio History action. Failure to save Listen Again does not roll back accepted radio playback or tuning. |

Startup captures `seedRadioStartGeneration`, `player.controlRevision` and the library history epoch. After anchor lookup it checks cancellation, all three values and connectivity before accepting. A newer seed, Cancel, a privacy reset or intervening transport action prevents the old lookup from replacing playback. Catch/defer paths are generation-guarded so a retired start cannot clear a newer start's loading/error state.

Refill captures `radioContinuationGeneration`, session UUID and `playbackIntentGeneration`. It checks cancellation and current radio mode before publication, and connectivity on success. Tuning, privacy changes and session replacement retire continuation generations. A late response cannot append into a replacement session or end a newer refill's progress state. Manual retry also captures `controlRevision`, so an intervening player control prevents that retry's append.

The player separately checks playback generation, selected occurrence UUID, request marker, cancellation, Repeat Off, interruption state and radio/Autoplay eligibility before inserting automatic results. Pause cancels the player's pending automatic request. Search synchronously changes its generation and clears visible results on a meaningful query/filter edit, before SwiftUI schedules the replacement task. Its `.task(id: request)` includes query, filter, offline state and retry attempt; cancellation and generation checks reject old responses. Search fans out through `CompositeCatalog.searchingAllSources`, unlike internal name-only anchor resolution.

## Storage and Privacy

`RadioHistoryStore` writes **`Application Support/GanaBajana/radio-history.json`**, beside the active library. `MusicAppModel` derives this location from `library.syncDeviceConfigurationURL`, so isolated library directories get isolated radio history. A library without a storage URL gets a memory-only store.

The version-1 JSON document has `version`, optional `historyEpoch`, and `entries`. Each entry has exactly `seed`, `tuning` and `startedAt`; the timestamp uses milliseconds since 1970, and writes use sorted keys. Seed and tuning use their canonical Codable representations. Recording IDs and display metadata, including validated artwork URLs, may be retained; signed media URLs, opaque provider payloads, response bodies and account credentials are not part of this schema. No active-session UUID, queue, anchor set, round or exclusion buffer is stored here.

Accepted starts and changed tuning call `record`. The newest entry moves to the front, replaces matching seed identity's metadata/tuning/time, and evicts entries beyond 20. Tuning therefore updates `startedAt` as well as tuning. The store is a recent-choice list, not a listening-event ledger or resume queue. It is device-local and outside iCloud library replicas, widgets and companion projections. Device-local does not imply backup exclusion: this store does not set an excluded-from-backup flag.

Writes are atomic with `completeFileProtectionUntilFirstUserAuthentication`. Before writing, the store re-reads disk and requires byte equality with its loaded baseline. It publishes the new entries only after a successful write. This detects a changed baseline; it is not a cross-process lock or an atomic compare-and-swap with an external writer. Reads accept only regular, nonsymlink files, check reported size and enforce the 1 MiB cap while reading in chunks of at most 65,536 bytes. Only a genuine missing file is treated as an empty store; permission and non-directory failures remain errors.

Decode rejects unsupported versions, too many or duplicate entries, invalid seeds/dates, unexpected document/entry keys and noncanonical seed/tuning payloads. Corrupt, oversized, future-version or externally changed data is preserved and mutations become blocked. A failed ordinary write retains the prior published entries. Invalid input to `record` reports an error without blocking later valid records. Repair alone does not unblock a failed store: **Reload Radio History** establishes a fresh validated baseline before mutations resume.

### History Off, Clear and Failed-Library Recovery

The store's optional epoch follows `LibraryStore.listeningHistoryEpoch`. An epoch change, or transition from history on to off, immediately empties the visible entries and sets `clearPending`. With writable storage it saves an empty version-1 document under the current epoch. Recording/removal is gated while disabled, blocked or awaiting clear. Loading a valid document with a different epoch, or nonempty entries while history is off, also clears it.

If the privacy-clear write fails, the disk file is preserved, entries stay hidden, and `clearPending` survives re-enable and reload in that store instance. After a valid reload, the pending empty write completes before new records are allowed. A corrupt file is never overwritten merely to clear it; it remains blocked until repair and reload. A durable library epoch mismatch also prevents an older valid radio-history file from reappearing on a later launch.

Failed library startup uses `deferLoading: true`. An unavailable library epoch is not treated as a real history reset: the radio file is neither read nor rewritten during that deferred initialization, and startup is refused. The first successful library reload supplies the authoritative epoch and history-enabled preference to `synchronize`, which performs the deferred load. If those values still match the saved file, Listen Again is recovered without rewriting it. A genuine later epoch change still clears it.

Privacy synchronization uses the successfully applied library preference, so a failed attempt to disable history does not erase Listen Again. History Off and Clear History retire pending starts and refill learning without interrupting the active song or replacing the queue. The active seed/tuning and transient queue exclusion memory are not a durable recent-choice history and remain with the session. Radio still works with history disabled but does not write Listen Again entries; re-enabling does not recreate cleared choices.

Provider requests use the existing catalog/search/radio clients and their cooldown, transport and cache policies. The provider receives the requested query, artist or seed recording as applicable; local tuning/history is not uploaded as a new history payload. Saved YouTube account cookies are not supplied to catalog or radio requests. Playback uses the existing separately governed stream-resolution path. See [PROVIDERS.md](PROVIDERS.md) and [PRIVACY.md](../PRIVACY.md).

## Metrics and Logs

These are the event names and fields emitted by the current source, not observed receipts or a new telemetry service. All use OSLog subsystem `com.agraabhi.ganabajana`. No seed ID, title, artist name, query, URL, epoch or session UUID is added by these feature events.

| Category / Level | Exact Event Fields | Meaning |
| --- | --- | --- |
| Discovery / info | `event=seed_radio_start outcome=accepted kind=<song\|artist> elapsed_ms=<duration>` | Accepted attachment/start after anchor work and history-record attempt. Does not measure first audible audio or wait for refill. |
| Discovery / notice | `event=seed_radio_start outcome=failed kind=<song\|artist>` | Current asynchronous start failure. No `elapsed_ms` field. |
| Discovery / info | `event=seed_radio_refill outcome=ready count=<selected.count> elapsed_ms=<duration>` | Model selection ready to return. Player guards can still reject insertion. |
| Discovery / notice | `event=seed_radio_refill outcome=failed` | Current refill failure. No count, kind, reason or elapsed field. |
| Discovery / info | `event=seed_radio_tune familiarity=<familiar\|balanced\|newMusic> language=<automatic\|bn\|en\|hi\|ta\|te>` | Applied changed tuning. |
| Playback / info | `event=seed_radio_pruned count=<removed.count> recent_count=<radioRecentTracks.count>` | Generated previous occurrences removed and current exclusion-buffer count. |
| RadioHistory / info | `event=radio_history operation=load outcome=success` | Successful ordinary disk load; a required privacy clear instead goes through write. |
| RadioHistory / error | `event=radio_history operation=load outcome=preserved` | Read/decode failure; original file retained. |
| RadioHistory / info | `event=radio_history operation=write outcome=success count=<next.count>` | Successful publication, including memory-only stores and empty clears. |
| RadioHistory / error | `event=radio_history operation=write outcome=preserved` | Failed write/baseline check; mutations blocked. |
| RadioHistory / error | `event=radio_history operation=record outcome=invalid` | Invalid attempted entry; existing state retained. |

Both `elapsed_ms` values use `ContinuousClock` duration divided by `.milliseconds(1)`. Kind and tuning enum strings are explicitly public log values. Early missing-library/offline start returns, cancelled or stale work, disabled history no-ops and deduplicated no-op tuning do not emit matching success/failure events. There is no separate seed-radio search, stale-result or provider-attempt metric here. Generic player events such as `autoplay_requested`, `autoplay_appended` and `autoplay_resumed_after_end` still apply; they are not seed-radio-exclusive counters.

## UI Selectors

| Surface | Accessibility Identifiers |
| --- | --- |
| Entry points | `search.radio.open`, `search.radio.content`, `track.radio.<trackID>`, `player.options.radio`, `collection.radio` |
| Search type | `radio.search.type`, `radio.search.type.songs`, `radio.search.type.artists` |
| Search states | `radio.search.guidance`, `radio.search.offline`, `radio.search.loading`, `radio.search.error`, `radio.search.retry`, `radio.search.empty` |
| Results / suggestions | `radio.search.song.<trackID>`, `radio.search.artist.<artistID>`, `radio.suggestion.<trackID>` |
| Listen Again | `radio.listenAgain.<seedID>`, `radio.listenAgain.remove.<seedID>`, `radio.listenAgain.error`, `radio.listenAgain.reload` |
| Session title | `radio.session` on Radio, `queue.radio` in Queue |
| Session states/actions | For either session prefix: `.loading`, `.cancel`, `.error`, `.retry`, `.tuning`, `.tune`, `.continuing`, `.continuationError`, `.retryContinuation` |
| Tune sheet | `radio.tune.sheet`, `radio.tune.familiarity`, `radio.tune.language`, `radio.tune.done`, `radio.tune.cancel`, `radio.tune.stale` |
| Tune menu options | `radio.tune.familiarity.familiar`, `.balanced`, `.newMusic`; `radio.tune.language.automatic`, `.bn`, `.en`, `.hi`, `.ta`, `.te` |

`<seedID>` includes the kind prefix, for example `radio.listenAgain.song:saavn:123` or `radio.listenAgain.artist:saavn:artist:42`. The search field is selected by its native “Songs or artists” placeholder, not an invented `radio.search.query` identifier. Seed rows have a 52-point minimum height; session actions and history reload have a 44-point minimum. Tune Cancel has a 70-by-46-point minimum to keep its label on one line in a nested sheet, and Done uses the shared sheet control. Accessibility-size Tune uses a large detent; other sizes offer medium and large.

## Test Mapping and Verification Boundary

### Unit Coverage

- **`Tests/SeedRadioEngineTests.swift`:** exact song anchors without catalog work; invalid/disliked seeds; linked/name-only artist resolution and credit checks; wrong-page rejection; three-anchor/100-candidate bounds; fixed-anchor rotation; alternate/fresh retry order; explicit-language scarcity; immediate provider/cooldown/timeout error propagation; cancellation; Familiar/Discover/Balanced pools; automatic soft language ranking; identified evidence and corrections versus likely/unknown language; aliases, meaningful versions, uncertain identity, artist caps and adjacency.
- **`Tests/RadioHistoryStoreTests.swift`:** twenty-entry ordering and metadata/tuning replacement, version-1 disk round trip and removal; invalid/future/corrupt/oversized payload preservation; foreign-write fencing; deferred loading; epoch mismatch; history-off clearing and isolated memory stores; failed privacy-clear recovery; invalid seeds/dates and signed-media artwork rejection. Disk tests use temporary directories.
- **`Tests/SeedRadioQueueRetentionTests.swift`:** repeated eight-song appends with 200 generated selections; forty-previous/128-exclusion bounds; manual duplicates versus generated twins; current UUID, position, player identity and transport revision preservation; unselected predecessors after jumps/reordering/shuffle; already-selected upcoming protection; most-recent selection ordering; valid snapshot permutations and restored unshuffle; replacement-path resets; ordinary Autoplay and failed attachment isolation.

### Functional / Integration Coverage

**`Tests/SeedRadioModelTests.swift`** exercises the model, real queue/controller and isolated library with controllable providers. It maps the following workflows:

- `testSongStartsImmediatelyThenRefillsFromOriginalSeedAndTunesWithoutLosingManualDuplicates`: seed acceptance before recommendations, original-anchor callbacks, stale tuning response rejection, manual duplicate preservation and durable queue/tuning history.
- `testPendingArtistKeepsOldQueueAndPauseExplicitPlayOrCancelRejectsLateStart` and `testReselectingCurrentSongPreservesSelectedDuplicatePositionAndQueue`: pending-start fencing and same-song attachment without extraction/restart.
- `testHistoryOffAndClearRemoveListenAgainAndFenceLateArtistAndRefillResults` and `testUnreadableLibraryPreservesRadioHistoryUntilSuccessfulReload`: privacy boundaries and deferred startup recovery.
- `testFailedRefillReportsContinuationErrorAndExplicitRetryAppendsWithoutRestart`: separate continuation errors, retained Tune recovery action and fresh retry while paused.
- `testAutoplayOffStillInvokesInstalledQueueExhaustedCallbackForSeedRadio`: the installed player callback with a generated local audio file, seed radio despite Autoplay Off, and no ordinary final-exhaustion callback.
- Ordinary-play/Live-Radio replacement tests reject late refills; `testTunedHistoryRestartsItsOriginalSeedAndUsesCurrentLanguageCorrectionsForAdditions` covers an explicit seed outside the chosen language and later corrections.

These tests live in the unit-test target but their model/player/store workflows are functional integration coverage. Fake providers and generated local audio do not establish live provider availability or physical-device behavior.

### UI Coverage

**`UITests/GanaBajanaSeedRadioUITests.swift`** uses `--cache-fixture` and `--seed-radio-fixture`, with deterministic `DebugSeedRadioCatalog` responses and cached audio:

| Test | Workflow Assertions |
| --- | --- |
| `testSongSearchTuneAndListenAgainSurviveRelaunchInLightAndDark` | No setup; song search/start; browse remains open; Tune Cancel/Done; already queued songs and paused seek position preserved; saved tuning/Listen Again after relaunch; restored queue has no active radio; later refill adds beyond the base queue. |
| `testExactArtistSearchAndPlayerMoreKeepTheCurrentSongPositionAndQueue` | Exact artist selection, seed title in Queue, Player More attachment to the current song, retained queue and paused position. |
| `testContinuationFailureRetriesWithoutLosingSeedAndHistoryPrivacyClearsListenAgain` | `--seed-radio-fail-once`; separate continuation error and Try More Songs; history off/on and Clear History without interrupting current playback; erased recents stay absent after relaunch. |
| `testCancellingAndSupersedingSlowArtistStartsKeepsOnlyTheLatestSelection` | `--seed-radio-slow-artist`; Cancel preserves old playback; latest artist wins; superseded/cancelled seeds do not enter Listen Again. |

The UI suite asserts selected control labels, queue identities, minimum touch targets and fixture workflow state. It does not by itself cover live multi-provider radio, VoiceOver acceptance, background suspension, deadline performance, every offline/search-error path, or every Tune-stale/history-error selector. Simulator/device matrix, observed timings and any remaining acceptance work must be read from the coordinator's [VERIFICATION.md](VERIFICATION.md), not inferred from this source coverage map or historical experience-radio receipts.
