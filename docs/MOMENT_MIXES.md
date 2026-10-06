# Moment Mixes

R17 Moment Mixes is implemented and integrated with the model, privacy epoch, Home, Settings and motion usage copy. Core and model integration checks passed, followed by light/dark UI workflows on phone, SE and iPad. [VERIFICATION.md](VERIFICATION.md) owns counts and corrected failures. Native motion and device context acceptance remain unverified.

## Behavior

Home shows **Your Moments** inside the existing Made for You section. A context needs at least three listening sessions across three distinct local days, plus at least three eligible songs. The shelf shows up to six cards, prioritizing the current weekday/weekend group and time bucket. Settings lists learned contexts and retained hidden-mix choices.

| Signal | Rule |
| --- | --- |
| Time | Morning 05:00–10:59, Afternoon 11:00–16:59, Evening 17:00–21:59, Night 22:00–04:59, in the supplied calendar/time zone |
| Day | Weekday or weekend according to `Calendar.isDateInWeekend`; midnight starts a new recurrence day |
| Car | An explicit `AVAudioSession.Port.carAudio` output |
| Headphones | An explicit `.headphones` output |
| General | Built-in audio, AirPlay, unclassified outputs and generic Bluetooth A2DP/HFP |
| Active | Optional Core Motion evidence: high-confidence walking, running or cycling, no automotive flag, and an activity start within 120 seconds. An explicit car route takes priority |

Names describe evidence, for example Morning Mix, Evening Headphones or Weekend Morning Car Mix. Generic Bluetooth does not distinguish a car from a speaker or headphones. Neither headphones nor activity proves a gym visit, and a car route does not prove a commute. No location framework or location permission is used.

**Learn Moment Mixes** defaults on. Turning it off clears learned evidence and daily selections, retires pending captures and disables motion learning. Turning it back on starts from that point. Per-mix switches hide cards without changing playback or the other mixes. Explicit switches survive Clear Listening History; inferred evidence and selected recording IDs do not.

**Use Motion Activity** defaults off. Only `MomentMixController.setMotionEnabled(true)`, called from the explicit Settings toggle, can pass `allowPrompt: true`. Startup and refresh accept an existing authorization but never request one. Denied/restricted authorization falls back to time and route. The control is unavailable without activity support and `NSMotionUsageDescription`. Turning it off retires callbacks and removes active-context evidence. Core Motion is never instantiated by the default test/fixture controller.

## Evidence and Generation

`LibraryStore.recordListening` and `recordListeningCheckpoint` accumulate seconds under `ListeningEvent.id`, the playback session UUID. Checkpoint arrays contain deltas; `library.events` contains the durable cumulative totals. WP28 reads the latter and uses `ListeningAnalytics.qualifyingSeconds(for:)`: 30 seconds, or half a shorter song.

Each qualified UUID contributes one `MomentEvidence`, keyed by that UUID. Later fragments do not add plays, grow the stored span or rewrite context. An event's fixed qualified span joins neighboring events using `TasteProfile.sessionGap` (30 minutes). Each recording gets at most one vote within an inferred session. Separate sessions on one day cannot satisfy the three-day threshold. An overnight replay with the same UUID cannot become multiple daily recurrences.

Time evidence starts at the store's learning floor. It does not backfill listening that predates feature activation or the latest enable/reset boundary. Newly received remote history after that floor may contribute time-only evidence. Route/activity attribution requires an explicitly local checkpoint captured within 30 seconds of the event's start. The pre-await staging API retains only context, with no listening credit; an existing stored event must qualify before that context becomes durable. This also prevents an observation task from assigning a fallback route before the checkpoint callback resumes. Older/retried checkpoints and missing captures use time-only context.

The generator reuses `Track`, `TasteProfile`, `MusicCollection(kind: .mix)` and `RecommendationEngine.jitter`. It does not add a `GeneratedPlaylistKind` or a synced library record. IDs are `moment.<weekday|weekend>.<time>.<route>`.

Candidate songs come from retained qualified events, likes and saved playlists. Context-session votes lead ranking, with a bounded taste-affinity contribution and deterministic daily tie-breaking. Songs explicitly marked non-audio and disliked recordings are excluded. Matching artists can fill a thin context from existing library songs. The first eligible selection is saved as recording IDs for the local day, preserving order across new checkpoints, library growth and relaunch. A dislike or unavailable song removes it immediately; a frozen mix with fewer than three remaining songs hides until a future eligible selection. Mixes may overlap each other.

Generation has no catalog or network dependency. Existing `MixTile` and `CollectionDetailView` open the embedded songs without a catalog fetch for the mix. Cached/downloaded playback uses the existing player path; generation does not establish that every chosen song has audio on this device. Artwork and uncached playback retain their existing network behavior.

## Storage and Privacy

| Item | Bound / Contract |
| --- | --- |
| File | `Application Support/GanaBajana/Moments/moments.json`, version 1 |
| Evidence | Latest 2,048 qualified event references within 60 calendar days; retention is applied on observations and foreground/time refresh |
| Context space | 32 combinations: four time buckets × two day groups × four route/activity classes |
| Pending captures | At most 128 UUID/context pairs, in memory only; retired at one hour on observation and immediately at a privacy boundary |
| Daily selections | At most 32 context keys with at most 25 recording IDs each |
| Candidate/output limits | At most 5,000 distinct eligible candidates per generation; 3–25 songs per mix; six Home cards |
| Bytes | 1 MiB read/write limit; IDs at most 512 UTF-8 bytes |
| Persistence | Baseline read check, version/shape validation, atomic replacement and complete protection until first user authentication |
| Backup/sync | Dedicated Moments directory excluded from backup; no library, journal, replica, widget or companion payload additions |

The file contains event/recording IDs, start and fixed qualification-end timestamps, local day keys, coarse context enums, switches and frozen recording selections. It contains no route name, hardware identifier, coordinate, raw motion sample, signed URL or copied track metadata.

Ordinary writes publish after durability. A failed preference write keeps the old choice and displays an error. Corrupt, unsupported, oversized and observed externally changed files are kept and writes are blocked. **Try Again** explicitly reloads a repaired file; it does not replace a corrupt file with defaults.

History off prevents context capture, evidence consumption and motion updates. Enabling history starts a new learning floor, including after relaunch, so the disabled interval cannot be backfilled. Clear History immediately empties published evidence/cards, clears pending captures and advances their generation. If the local erasure fails, `resetPending` blocks learning and the Settings error remains retryable.

The persisted library privacy epoch is required for crash recovery. If the library clear succeeds but the separate moments write fails, the next launch compares the existing library epoch with the moments epoch before learning or showing cards. A mismatch hides the old evidence and retries erasure. This is not a transaction across two files; the epoch check closes the stale-data publication path. A corrupt moments file remains preserved and blocked even during a clear.

The store performs bounded synchronous I/O on the main actor, only for changed evidence/preferences/selections. Repeated fragments for an already-qualified event do not write the moment file or rebuild a successful collection projection. No latency or scrolling measurement has been made for this implementation.

### Core-02 Startup Failure

The old `MomentMixFilePersistence.read()` recognized only Cocoa `fileReadNoSuchFile` (260). Native file opening can report absence as Cocoa `fileNoSuchFile` (4) or POSIX `ENOENT` (2), including when the dedicated parent directory does not yet exist. An unrecognized absence went through the store's corrupt/unreadable-file path and set `blocked`. Both subsequent assertions failed because a blocked store cannot write, so `write()` never reached its directory-creation step. The later missing-directory removal diagnostic was a consequence. The original opening error was swallowed by initialization and was not recorded in Core-02, so that log does not identify which missing-path representation triggered the initial block.

The reader now accepts those narrowly defined missing-path forms. Wrapped non-missing POSIX errors such as `EACCES`, `ENOTDIR` and `EIO` still throw, as do unrelated domains/codes. Reads remain side-effect-free; only the first successful atomic write creates the directory. The existing round-trip, backup-exclusion, size-limit and external-byte-conflict assertions remain intact. Added native tests exercise a missing nested parent and a non-directory parent; a separate classification test covers the positive and negative error forms.

### History Preparation and Revision Memo

Before this follow-up, every five-second durable history revision ran `events.filter(...).sorted(...)` on the main actor before applying the 2,048-event cap. The cap therefore bounded storage, not preparation cost. Building the mix profile could scan full history again.

`MomentHistorySelection` now prepares an immutable library snapshot in a detached utility task, returning at most 2,048 qualified events. Main-actor evidence reconciliation and profile joins use that bounded result. The memo is keyed by library object identity and the actual `historyRevision`; it also checks the learning floor, calendar, clock direction and the next future-event eligibility boundary. It does not use event count or the latest session as a revision substitute. Forward retention prunes the bounded result at the exact cutoff, including within one time bucket; a backward cutoff or clock change forces preparation again.

Only one preparation runs at a time. Later revisions coalesce while it runs; a superseded result is discarded and the latest snapshot is prepared. Completion checks source identity/revision, library availability, history opt-in, privacy epoch and a reset generation before publication. Clear, opt-out, recovery and unavailable-library paths invalidate the memo. Pending route captures remain bounded and generation-fenced while preparation is in flight.

`synchronize(...)` keeps its synchronous signature and applies privacy immediately, but a cache miss schedules history preparation and returns. Existing cards can remain visible while refreshed history is prepared, with dislikes and disabled-mix choices filtered; clear/history-off hides them immediately. Playback acknowledgment does not await the projection. Explicit test consumers use `await controller.waitForPendingPreparation()` before asserting newly learned collections. A changed revision still requires an off-main history scan/sort; this is not a claim of zero per-checkpoint CPU cost.

## Integrated Call Sites

`MusicAppModel`, `GanaBajanaApp`, `HomeView`, `SettingsDiscoveryPage` and `project.yml` contain the hooks below. The integrated build includes detached `MomentHistorySelection` preparation. These snippets describe the existing contract.

### 1. Expose the Existing Privacy Epoch Read-Only

The integrated `LibraryStore` exposes the already-persisted value read-only. No new library field or format change is needed.

```swift
var listeningHistoryEpoch: UUID? {
    _ = historyRevision
    return document.listeningHistoryEpoch
}
```

`historyRevision` is an observation trigger, not a durable privacy token. Do not substitute it, event count or the last session ID for `listeningHistoryEpoch`.

### 2. Own One Controller in MusicAppModel

`MusicAppModel` owns `let momentMixes: MomentMixController` with optional initializer injection. The existing real-launch/test-host check chooses disk or memory storage before callbacks capture the model:

```swift
let momentDisk: (any MomentMixPersistence)? = observingPurchases
    ? MomentMixFilePersistence.defaultURL().map { MomentMixFilePersistence(url: $0) }
    : nil
self.momentMixes = momentMixes ?? MomentMixController(
    store: MomentMixStore(persistence: momentDisk),
    usesDeviceSignals: observingPurchases
)
```

At the end of model initialization, after installing the existing callbacks:

```swift
self.momentMixes.startObserving(library: library) { $0.listeningHistoryEpoch }
```

The controller observes durable history, privacy/preferences, likes, playlists, dislikes and library availability through `withObservationTracking`. It neither replaces library callbacks nor consumes playback position revisions. Fixture tests can inject `MomentMixController(store: MomentMixStore(), usesDeviceSignals: false)` or a store with an isolated file URL.

### 3. Stage Local Context Before Existing Persistence

Inside the existing asynchronous `player.onListeningCheckpoint` closure, immediately after its `guard let self, let library, let player` and before the call that awaits `recordListeningCheckpoint`:

```swift
let momentCapture = self.momentMixes.capture(for: checkpoint.events)
```

Immediately after `recordListeningCheckpoint` returns, before the existing language/cache refresh block:

```swift
if acknowledged {
    self.momentMixes.synchronize(
        library: library,
        historyEpoch: library.listeningHistoryEpoch,
        localEventIDs: Set(checkpoint.events.map(\.id)),
        capture: momentCapture
    )
}
```

Keep the original checkpoint return/acknowledgment unchanged. A moments write failure must not reject a library checkpoint that is already durable.

Inside the synchronous `onListeningProgress` compatibility closure, before `library.recordListening`:

```swift
let localMomentEvent = ListeningEvent(
    id: session, track: track, startedAt: started, listenedSeconds: seconds
)
let momentCapture = self?.momentMixes.capture(for: [localMomentEvent])
```

After that existing call succeeds, before its `historyRevision` early return:

```swift
self?.momentMixes.synchronize(
    library: library,
    historyEpoch: library.listeningHistoryEpoch,
    localEventIDs: [session],
    capture: momentCapture
)
```

The observation path also refreshes remote/library-choice changes. Only these explicit local callback captures can attribute a device route. No player callback is replaced by a new subsystem.

### 4. Apply Privacy Boundaries Synchronously

At the start of the existing `library.onHistoryCleared` body, after unwrapping `self`:

```swift
self.momentMixes.reset(historyEpoch: self.library.listeningHistoryEpoch)
```

Keep the existing pending-listening, genre, recommendation and playback handling. This callback already covers durable local clear, remote history boundary and recovery reload.

`applyPreferenceServices` uses the already-applied library value, so history-disable stops motion in the same main-actor turn. The remote preference path uses the same method:

```swift
momentMixes.synchronize(library: library, historyEpoch: library.listeningHistoryEpoch)
```

`activateDeviceServices()` and the app's significant-time-change observer also synchronize the controller. There is no polling timer. Failed preference values never become controller input.

### 5. Connect Home and Settings

At the same root as `.environment(model)`:

```swift
.environment(\.momentMixController, model.momentMixes)
```

`GanaBajanaApp` supplies this environment value. Home follows Made for You visibility and uses the existing 44-point `MixTile` Play control.

In `SettingsDiscoveryPage`'s Home and Mixes section:

```swift
AppNavigationLink {
    MomentMixesSettingsView(controller: model.momentMixes)
} label: {
    SettingsRowLabel(title: "Moment Mixes", systemImage: "clock.arrow.circlepath")
        .settingsRowTarget()
}
.accessibilityIdentifier("settings.moments.open")
```

Settings switches call the controller's device-local preference methods. They intentionally do not extend `UserPreferences` or its sync registers.

### 6. Target Membership and Motion Usage Copy

`Sources/Moments/*` and `Sources/Views/MomentMixesSettingsView.swift` belong to the phone/CarPlay app target. The Moment test files belong to `GanaBajanaTests`. Watch and widgets do not include these implementations.

`project.yml` supplies the Info.plist entry:

```yaml
NSMotionUsageDescription: "Velvet Thorn can use motion activity to recognize active listening for moment mixes. This is optional and stays on this device."
```

No location usage entry is required. Shared privacy and Settings documentation describe the integrated feature.

## APIs

| API | Contract |
| --- | --- |
| `MomentMixController.startObserving(library:historyEpoch:)` | Install a revision-driven observer and perform initial privacy synchronization |
| `capture(for:)` | Return/stage a bounded generation-fenced native context for local checkpoint UUIDs; no listening credit |
| `synchronize(library:historyEpoch:localEventIDs:capture:)` | Apply privacy immediately; schedule or reuse revision-keyed preparation, then learn and publish local collections |
| `waitForPendingPreparation()` | Await scheduled projection work in tests/explicit consumers, never in playback acknowledgment |
| `reset(historyEpoch:)` | Hide cards, retire pending context and attempt durable erasure |
| `setLearningEnabled`, `setMixEnabled`, `setMotionEnabled` | Persist local choices, then apply their effects |
| `retryStorage()` | Explicit reload/recovery; a pending reset wins over recovered evidence |
| `collections`, `summaries`, `settingsContexts` | Observable UI projections; collections are existing `MusicCollection` values |
| `MomentMixStore` | Injectable durable/isolated memory store; `resetPending`, `errorMessage`, `revision` expose failure/publication state |
| `MomentMixPersistence` | Main-actor `read() throws -> Data?`, `write(Data) throws`; production implementation checks byte limits and writes atomically |

## Metrics

Local OSLog uses subsystem `com.agraabhi.ganabajana`, category `Moments`.

| Metric | Emitted When | Dimensions / Bounds | Why |
| --- | --- | --- | --- |
| `event=moment_learning` | A changed evidence projection saves successfully | `outcome=saved`, `evidence` 0–2,048 | Observe accepted evidence/retirement writes |
| `event=moment_mixes` | A changed collection projection and its daily selections finish successfully | `mixes` 0–32, `tracks` 0–800, including zero results | Distinguish empty learning from useful selections |
| `event=moment_storage` | A caught write/baseline/validation failure | `outcome=failed` | Diagnose local persistence failure without recording its private payload |
| `event=moment_reset` | Pending erasure saves successfully | `outcome=saved` | Observe completion of a privacy retry |
| `event=moment_history_preparation` | A detached history preparation finishes | `outcome=applied` or `superseded` | Identify accepted results versus fenced/coalesced work without source identifiers |

No identifiers, route names, times, context keys, motion samples, titles or error descriptions are logged. Startup read failures and preserved-blocked no-ops are surfaced through `errorMessage`; they do not currently emit a separate counter. OSLog emission is not asserted by the authored tests.

## Test Coverage

Core-02 exposed the native-file startup failure described above. The corrected core suites passed in Core-03; [VERIFICATION.md](VERIFICATION.md) owns executed counts and Integration-03 scope. File-backed/component integration checks are hosted in the unit-test target and do not establish native-device acceptance.

| Test Class / Cases | Branch or Path | Unit or Integration |
| --- | --- | --- |
| `MomentMixLearningTests`: three-day threshold, duplicate UUIDs, session grouping, three sessions on one day | Qualified evidence cannot inflate recurrence | Unit |
| Time edges, weekend boundary, local midnight, repeated daylight-saving hour | Calendar context and distinct-day identity | Unit |
| Generic Bluetooth, explicit headphones/car, conservative names | Route classification without inferred gym/commute | Unit |
| Local generation, dislikes, non-audio, minimum size, deterministic order, 25-song bound, global/per-mix exclusion, unknown artists | Candidate and eligibility rules | Unit |
| `MomentMixStoreTests`: repeated cumulative checkpoints and relaunch; short-song half-duration qualification | One durable summary per UUID | Unit with injected persistence |
| Staged context without credit, 128-pending bound, fresh local capture, late/remote fallback | Capture attribution and qualification boundary | Unit |
| Motion preference required; disabling removes active evidence | Core privacy gate, without calling native authorization | Unit |
| Invalid/future/unqualified events, 2,048-event cap, 60-day boundary, event removal | Validation and retention | Unit |
| History off, enable without backfill, history-off relaunch, global opt-out/per-mix retention | Privacy and explicit preference semantics | Unit |
| Failed ordinary/preferences writes; failed reset; old captured generation; epoch mismatch after relaunch | Publication after durability and privacy erasure retry | Unit |
| Corrupt/future/external/unreadable files; explicit repaired-file recovery | Fail-closed storage preservation | Unit |
| `MomentMixControllerTests`: real `LibraryStore` events unlock a card; switches/dislikes remove it | Library-to-collection integration and native signals disabled in tests | Component integration |
| Clear callback, history preference, failed moment-store reset | Immediate Home projection retirement | Component integration |
| Unavailable library with a placeholder epoch | Suspend learning without erasing an established moments file | Component integration |
| Daily IDs survive added favorites and controller/store relaunch | Frozen recording selection | Component integration |
| `MomentMixPersistenceTests`: atomic file round trip, backup exclusion, external conflict, oversized file | Actual Foundation file operations in isolated temporary directories | Local-file integration |
| Missing nested parent creates on first write; non-directory parent stays intact; native missing/error classification | Startup absence versus genuine read failure, without weakening conflict/corruption checks | Local-file integration and unit |
| `MomentMixHistoryPreparationTests`: same-revision reuse, same-count qualification change, concurrent revision coalescing, clear during suspended preparation | Memo validity and generation-fenced asynchronous publication | Component integration with an injected preparation gate |
| Future eligibility, clock/calendar/floor changes, exact retention, newest-2,048 bound | Time-safe memo reuse and bounded preparation output | Unit and component integration |

Coordinator selectors:

```text
-only-testing:GanaBajanaTests/MomentMixLearningTests
-only-testing:GanaBajanaTests/MomentMixStoreTests
-only-testing:GanaBajanaTests/MomentMixControllerTests
-only-testing:GanaBajanaTests/MomentMixPersistenceTests
-only-testing:GanaBajanaTests/MomentMixHistoryPreparationTests
```

Integration-03 covers the model paths listed in [VERIFICATION.md](VERIFICATION.md). UI-Moments-04, UI-SE-01 and UI-IPad-01 passed after the Done fix. Remaining checks include failed clear followed by process termination, extreme accessibility geometry and native motion authorization/activity states. Home identifiers include `home.moments` and `home.moment.<context>`; Settings identifiers start with `settings.moments`. The mix Play overlay is a separate native button outside the browse link.

## Design Limits

- Existing history before the learning floor cannot instantly unlock a moment. Default learning needs future qualified activity on three days.
- The fixed qualification span deliberately ignores later checkpoint duration growth. Long songs or long pauses may split inferred sessions differently from the full-duration taste profile. The distinct-day requirement remains conservative.
- Local day/time is recorded in the calendar used when the event first qualifies. Remote historical events have no original device time-zone/route evidence. A later time-zone change does not rewrite learned context.
- Generic Bluetooth car stereos and wireless headphones without a distinguishing public port type receive time-only names. Native Core Motion and physical audio routes remain unverified.
- Mixes use only available library metadata. They do not discover new catalog songs, prefetch audio or guarantee offline availability of an uncached selection. Already-open collection pages and active playback retain their existing value snapshots.
- A damaged moments file cannot be erased automatically while also preserving its original bytes. Learning stays blocked and Settings reports the error until the file is repaired/recovered explicitly.
- No full playback, native permission, background activity, CarPlay head-unit, accessibility or performance result is claimed. Shared integration and verification records remain coordinator-owned.
