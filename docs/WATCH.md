# Velvet Thorn on Apple Watch

The watch app controls Velvet Thorn on the paired iPhone. Now Playing shows the song, artist, and elapsed time, with play/pause, previous, next, and favorite controls. Playback options contains shuffle and repeat. Library opens Favorites, Recently played, Playlists, individual playlists, and Queue. Choosing a song starts playback on iPhone.

The implementation targets watchOS 11+ and iOS 18+. Targets, source membership, entry points, and the Leafnote icon are configured in the project. Native Watch unit/UI checks and a real paired-simulator WatchConnectivity test have run. [VERIFICATION.md](VERIFICATION.md) owns the coordinator's full counts and run history; physical-device acceptance remains open.

## Interface

- The watch accent follows the phone's saved accent through an optional `CompanionSnapshot.accent` field (no wire-version change: snapshot decoders ignore unknown keys and requests are unchanged). A missing or unknown value keeps the last applied accent; a watch that never received one uses coral. The value is saved under `breezy.watch.accent`, and an accent change publishes immediately. `WatchAccentTests` cover the mapping and persistence.
- The compact record mark uses the accent with Leafnote's coral flag. Primary transport controls sit above progress. The paused fixture verifies that previous, play/pause, and next are fully visible and hittable in the first viewport on the Watch SE 3 (40 mm) simulator, before any Crown scrolling. Long metadata remains scrollable. Album art is omitted because the shared contract does not carry images.
- ScrollView and native List retain Digital Crown scrolling. Song titles and artist credits wrap; library rows grow with Dynamic Type. Primary transport buttons have 44-point minimum hit regions, with a 52-point play/pause button. Favorite, refresh, navigation, and browse actions place their minimum height inside the interactive label.
- VoiceOver labels describe the action and its iPhone destination. Progress has a combined spoken value. Favorite and repeat expose their current values; shuffle uses a native Toggle. The record mark is decorative. Reduce Motion removes explicit view animations, and reduced luminance stops the display timeline.
- A fresh empty player offers Library. Disconnected or unconfirmed cached playback is labeled **Last seen on iPhone**, with disabled playback actions and a frozen position. Missing companion installation, post-reboot unlock, activation, pending command, loading, rejected command, and transport failure have separate copy.
- Playback state changes only after phone data arrives. An unconfirmed tap does not flip play/pause, favorite, or shuffle optimistically.
- The heart (`watch.favorite`) is one three-state control in the same 44-point slot: `bolt.heart.fill` in petal when `isSuperLiked`, `heart.fill` in petal when a favorite, a white `heart` outline otherwise. A tap sends `setFavorite(!isFavorite)`, so a tap on a super liked song removes it from favorites fully. A 0.4-second hold (`LongPressGesture` as a simultaneous gesture, so the tap survives) sends `setSuperLiked(!isSuperLiked)`: not a favorite or a favorite becomes super liked, super liked steps back to a favorite. The hold sets a flag that turns the release's tap into a no-op; every press start clears it, so a stale flag cannot swallow the next tap. A promotion plays `WKInterfaceDevice.current().play(.success)` when the hold is recognized; a demotion, a rejected hold and a disabled heart stay silent. Confirmation still waits for the phone. VoiceOver keeps the label **Remove from favorites** / **Add to favorites**, reads the value **Super liked**, **Favorite** or **Not a favorite**, and offers the custom action **Super like** / **Change to favorite**. [SUPER_LIKES.md](SUPER_LIKES.md) owns the tier.
- Library failures have a separate **Library needs attention** panel with the phone's recovery guidance. They do not become playback errors or stop the playing clock. A failed library without a current song is not presented as an empty, healthy library.

## Connectivity and state

`Sources/Core/Companion/CompanionProtocol.swift` owns all wire models, request validation, and `CompanionWire`. The watch and phone transport use that codec directly. `CompanionWire.version` is **2**: `CompanionNowPlaying` carries `isFavorite` and `isSuperLiked` (always false unless `isFavorite` is true), and `CompanionAction` has `setSuperLiked(Bool)` beside `setFavorite(Bool)`. A version 1 peer is rejected with `unsupportedVersion`; both apps ship together. Each request, reply, and snapshot is JSON `Data`, limited to **60 KiB before decoding and after encoding**. Request and response IDs must match. Background application context contains one entry, `breezy.snapshot.v1: Data`, whose value is a `CompanionSnapshot`.

Playback and library mutations use `sendMessageData` with a reply handler. `WatchActionPolicy.isReadOnly` treats only `snapshot` and `browse` as reads; `setSuperLiked` is a leased mutation like `setFavorite`. There is no queued playback-intent transport. Session activation and incoming application context never execute playback actions. The phone passes valid interactive requests to `CompanionPlaybackController.handle(_:)`, which owns track guards, library revisions, and a 128-receipt duplicate-request window. Idempotency lasts only while a receipt remains in that controller's memory, not across eviction or process restart. A library selection carries the page's exact location, occurrence ID, and revision.

Every mutation first sends a new, read-only `.snapshot` request to obtain `CompanionResponse.executionLease`. `CompanionExecutionLease` contains an ID and the phone-process session ID. The controller keeps at most 128 issued leases and validates their **six-second lifetime on the phone's monotonic clock immediately before mutation**. `WatchPhoneSession` rejects every lease-less mutation; read-only requests need no lease. The client never reuses a lease from a cached response, application context, or its caller.

The phone's lease record also retains the repeat mode returned in the response snapshot. Before the first repeat cycle, a leased change must still match that mode, so it cannot overwrite a newer phone selection. Further cycles belong to the same command. An already-satisfied desired mode is a no-op with a valid lease; an expired lease still fails. Receipt replay preserves newer state, and a lease issued with an older cached snapshot remains tied to that older repeat value.

Views capture the displayed snapshot and any derived play/pause, favorite, shuffle, or repeat value synchronously before creating a Task. `WatchCompanionModel.command(_:displayed:)` requires that explicit snapshot. It checks the current track/session and the value relevant to the action before preflight. For `setFavorite` and `setSuperLiked`, `WatchActionPolicy.matches` compares both `isFavorite` and `isSuperLiked`, so a tap or hold made against a stale tier is rejected instead of reinterpreted. The client checks the preflight snapshot and lease session against the same captured context, then the model checks the newest local state again immediately before sending. Position ticks do not invalidate an action. A changed song, process, or relevant control value rejects the old action instead of applying it to the newer state. The mutation's request ID, action, and expected track ID stay unchanged across preflight; only its execution lease is supplied by the fresh response. Library selections also carry the captured current track ID when one exists.

The watch reserves one mutation slot across both preflight and dispatch and allows at most four wire requests in flight. Preflight has its own **8-second read deadline**. The mutation's separate **8-second deadline starts when the mutation is sent, after lease issuance**. Thus the phone's six-second lease expires before that mutation deadline even if first delivery is delayed before the delegate callback. No wall-clock comparison between devices is needed. A slow preflight can make the full interaction take longer than eight seconds. A lease that already expired in transit is rejected without an automatic mutation retry.

Each wire request supports cancellation and a local connection generation. Reply receipt checks the monotonic deadline even if the timeout task has not run yet. Reachability loss, deactivation, or leaving the foreground retires requests; late callbacks cannot complete a later operation. The phone also has an independent **6-second receiver/reply deadline**, with expiry checks before dispatching the controller. Malformed or receiver-expired requests receive empty data. Missing, unknown, wrong-session, or lease-expired mutations receive a correlated rejection. An already executed request may receive its cached receipt after lease expiry, but the receipt cannot execute it again.

A timeout, cancellation, malformed/mismatched reply, or delivery failure can leave a dispatched command's result unknown. The model retires earlier reads and disables mutations until a new read confirms the phone's state. It automatically requests a fresh snapshot when reachable. It never retries the mutation. The visible message asks the user to check the refreshed player before choosing the action again. A failed or cancelled preflight cannot execute a mutation and is not labeled as an ambiguous command. Cancellation after dispatch cannot recall a still-valid leased command; it may execute before its lease expires.

Snapshots are ordered by sequence within their phone-process `sessionID`. Old and duplicate sequences cannot rewind the display. A cached context cannot replace a known phone process; a correlated live reply confirms a new process. Retired process IDs remain rejected beyond the client's reply deadline, including out-of-order concurrent reads. Browsing caches clear when a new process is confirmed.

Progress uses the watch's monotonic receipt clock, not the phone's wall-clock timestamp. Local interpolation requires a confirmed, reachable, foreground snapshot with `isPlaying == true`, `isLoading == false`, and no playback error in `nowPlaying.errorMessage`. `snapshot.libraryError` does not affect interpolation. Progress clamps to duration and freezes on disconnection/backgrounding. A read-only heartbeat runs every **12 seconds** while foregrounded. Confirmation expires after **20 seconds**, so reachability alone cannot keep an old playing snapshot alive. Reconnection requires a new reply; offline time is never added to progress.

`WatchConnectivityDelegate` has nonisolated SDK callbacks. A single `AsyncStream` consumer preserves the delegate queue's order while delivering Sendable values to the main actor. No `WCSession`, `[String: Any]`, or raw framework error crosses an actor hop. SDK send/reply closures are created in a nonisolated helper so unannotated SDK 27 completion blocks do not inherit main-actor isolation. The SDK reply block is held by a lock-protected, single-use `WatchReply`.

The phone observes snapshots immediately at `start()` and publishes initial state after activation. Track identity/title/artist, duration, play/loading/error state, favorite/settings, and library failure or recovery trigger immediate publication attempts, including while unreachable. WatchConnectivity schedules actual delivery. Pure position changes publish at most once per **10 seconds** while reachable, with one retained trailing snapshot; none are sent while unreachable. Reconnection and the trailing timer use the latest retained state. Repeated failures retry at the same bounded cadence; a genuinely new semantic change can publish immediately. Injected-clock tests cover position coalescing, offline suppression, trailing delivery, and retries.

iOS deactivation reactivates the session for the selected watch. The watch background hook activates the same process-owned session, waits up to 8 seconds for activation and `hasContentPending == false`, and consumes retained context before returning. OS cancellation ends that wait. Retained context is also read on activation, so a later launch can recover delayed delivery.

The payload contains recording metadata and library rows. It contains no media URLs, account cookies, artwork requests, or audio bytes. The watch target has no catalog, authentication, audio-player, or extraction dependency.

## Project and runtime integration

`project.yml` defines one modern watchOS application, without a WatchKit extension. `GanaBajanaWatch` uses watchOS 11, device family 4, Swift 6 complete strict concurrency, and the iPhone's marketing/build versions. Its bundle ID is `com.agraabhi.ganabajana.watchkitapp`, display name is `Breezy`, `WKApplication` is true, `WKCompanionAppBundleIdentifier` is `com.agraabhi.ganabajana`, and `WKRunsIndependentlyOfCompanionApp` is false.

| Target | Configured membership |
| --- | --- |
| `GanaBajana` | `Sources/**`, `Resources/**`, and `WatchApp/Sources/Connectivity/**`; embeds `GanaBajanaWatch` |
| `GanaBajanaWatch` | `WatchApp/Sources/**`, `WatchApp/Resources/**`, and only the Foundation companion contract from `Sources/Core/Companion/` |
| `GanaBajanaTests` | Phone tests under `Tests/**`, with `Tests/Fixtures` bundled as resources |
| `GanaBajanaWatchTests` | `WatchTests/**`, `Tests/WatchTestSupport.swift`, and `Tests/CompanionProtocolTests.swift` |
| `GanaBajanaWatchUITests` | `WatchUITests/**`, including native fixture workflows and the opt-in paired transport test |

The `GanaBajanaWatch` scheme builds both apps and includes the native Watch unit/UI targets. Watch resources contain their own `AccentColor` and the copied 1024 × 1024 RGB, no-alpha Leafnote `AppIcon.png`. The phone's catalog, extraction dependencies, and resources are not linked into the Watch app.

Use `GanaBajanaWatch`, or `GanaBajana` for phone development, with normal automatic signing. The phone requests iCloud through `Signing/iCloud.entitlements`; the Watch requests neither iCloud nor CarPlay and receives library updates through the phone. The optional `GanaBajanaCarPlay` scheme is for an Apple-approved phone App ID and provisioning profile, as described in [CarPlay signing](CARPLAY.md#audio-entitlement).

`GanaBajanaApp.init()` installs one controller in `CompanionRuntime.playback`, then retains and starts `WatchPhoneSession` with that same controller. Ordinary test launches skip real WatchConnectivity; the explicit DEBUG paired fixture below enables it with isolated providers and storage. `stop()` removes observation and transport handlers only on deliberate teardown, not ordinary phone scene changes.

`WatchApp/Sources/GanaBajanaWatchApp.swift` presents `WatchRootView` and handles `.backgroundTask(.watchConnectivity)` through `WatchAppSession.shared.receiveBackgroundUpdates()`. The root handles Watch scene phases. Its default model and the background hook share the process-owned session, so view recreation does not replace the WCSession delegate.

### Running native checks

From the repository root, the coordinator can use the configured wrapper modes:

```sh
DESTINATION='platform=watchOS Simulator,id=271517F2-1471-426C-B2BD-B0E265AD1EFC' bash tools/verify.sh watch-unit
DESTINATION='platform=watchOS Simulator,id=271517F2-1471-426C-B2BD-B0E265AD1EFC' bash tools/verify.sh watch-ui
```

The wrapper regenerates the project and keeps outputs under `artifacts/`. The paired transport test skips without its separate opt-in. Phone-side adapter/controller suites remain in `GanaBajanaTests`. These commands describe repeatable entry points; named execution results are recorded below and in [VERIFICATION.md](VERIFICATION.md).

## Test coverage and results

`Breezy-Watch-Unit-02` passed **31/31 native Watch tests**. Phone-side WatchConnectivity, shared-controller, lease, and newer-repeat-intent cases passed in `Breezy-Companions-Unit-02`; that mixed phone run retains its unrelated album-license failure.

`Breezy-Watch-UI-01` passed four of six native fixture workflows and failed two. `Breezy-Watch-UI-Fixes-02` passed all three selected workflows: the two failures and the paused-player flow with its first-viewport assertion. All six distinct fixture workflows therefore have passing coverage across runs, not one green six-workflow run. A seventh workflow, `GanaBajanaWatchUITests/testFavoriteHoldPromotesToSuperLikeAndTapRemovesIt`, launches the `paused` fixture, taps the heart to **Favorite**, holds it (`press(forDuration: 0.8)`) to **Super liked**, then taps it to **Not a favorite**, checking that play/pause stays **Play on iPhone** throughout; [VERIFICATION.md](VERIFICATION.md) records its runs.

The UI reveal helper corrects clipped edges, calibrates Crown rotation from measured movement, and waits for both control and child geometry to settle. A native swipe handles a Crown movement that settles back on the same row. Full control visibility and the **44-point minimum with only a `1e-6` epsilon** remain required. The long-metadata workflow also requires observed Crown movement of native player controls.

| Suite | Cases represented in source |
| --- | --- |
| `WatchPhoneSessionTests` | Idempotent start and initial observation; background publication while unreachable; activation/watch-switch reactivation; inbound context cannot execute commands; correlated single reply; expired/retired request rejection; malformed/version/size rejection; context publication retry; concurrent reply-gate winner |
| `WatchRequestClientTests` | Offline refusal without queuing; activation/context without commands; correlation and malformed replies; concurrent out-of-order reads; one mutation in flight; deadlines and delayed timer scheduling; cancellation; session-generation retirement; oversized input; version validation |
| `WatchMutationLeaseTests` | Fresh lease per mutation; preserved request/action/track; missing or wrong-session lease; changed preflight track/control values; final local validation; preflight timeout/cancellation; separate mutation deadline |
| `WatchPhoneLeaseTests` | Lease required for every watch mutation; real controller rejection after delivery delay **before** delegate receipt; valid versus fabricated/wrong-session lease; expired duplicate receipt without repeated execution |
| `WatchPhonePublicationTests` | 100 half-second ticks with six total publications including initial state; zero pure-position sends offline; independent immediate semantic changes and library recovery; latest trailing state; bounded retry; cancellation on lost reachability |
| `WatchSnapshotStateTests` | Untrusted cached playback; monotonic interpolation and duration clamp; paused/loading/playback-error clocks; library failure/recovery without clock freeze; disconnect and background freeze; freshness expiry; duplicate/out-of-order sequences; new-process confirmation and old-process rejection; empty state; safe elapsed-time formatting |
| `WatchCompanionModelTests` | Foreground read-only refresh; no autoplay from paused/cache state; pending acknowledgement; rapid Next taps; page occurrence/revision and rejection; timeout ambiguity and fresh read; retirement of earlier reads; background cancellation; explicit selection from an empty player; mismatched browse location; rendered A action followed by B before Task execution; changed control values and preflight context; separate library failure with and without a track |
| `CompanionPlaybackControllerTests` | Phone-issued lease expiry at mutation, newer phone repeat-mode selection, valid no-op versus expired lease, and replay/cached-snapshot protection |

These unit tests use injected transport, handlers, clocks, and deadlines. `WatchPhoneLeaseTests` connects the phone adapter to the real `CompanionPlaybackController` with an isolated `AppModelTestContext` and its injected `monotonicNow` clock. The delayed-delivery regression uses the actual lease validator. The real WCSession run below is separate from these unit and in-memory fixture UI checks.

## Local UI fixtures

Debug builds recognize `--watch-fixture <mode>` when explicitly supplied to the watch launch. Modes are `playing`, `paused`, `empty`, `disconnected`, `loading`, `error`, `pending`, `long`, `library-error`, and `library-empty`. They use an in-memory transport and fictional songs, without contacting the phone. The fixture transport issues session-bound, six-second leases from snapshot preflights and checks its bounded lease ledger before mutation. `pending` answers read-only requests but withholds mutation replies to exercise the timeout flow. `long` includes Hindi and long artist/title text. The library modes exercise failure alongside a playing snapshot or without a current track. Playback, favorite, super like, shuffle/repeat, and browse selections mutate only fixture memory; the fixture's `setSuperLiked(true)` also marks the song a favorite and its `setFavorite(false)` clears the tier, matching the phone controller.

The fixture factory, strings, and transport are enclosed in `#if DEBUG`; the Release factory creates the real connectivity transport. Normal Debug launches also use real connectivity unless the fixture argument names a supported mode.

## Paired-simulator WatchConnectivity

[`WatchUITests/GanaBajanaWatchConnectivityUITests.swift`](../WatchUITests/GanaBajanaWatchConnectivityUITests.swift) runs the Watch app without an in-memory transport fixture. Its single test, `testPairedPhonePlaybackUsesRealWatchConnectivity`, requires `GANABAJANA_WATCH_INTEGRATION=1` in the test process, supplied to `xcodebuild` as `TEST_RUNNER_GANABAJANA_WATCH_INTEGRATION=1`. The selector is `GanaBajanaWatchUITests/GanaBajanaWatchConnectivityUITests/testPairedPhonePlaybackUsesRealWatchConnectivity`.

The recorded simulator pair is:

| Role | Device and runtime | Simulator ID |
| --- | --- | --- |
| Phone | GanaBajana QA iPhone 17 Pro, iOS 26.5 (`23F77`) | `B1EE1D9A-124A-4788-9760-5C5668E19078` |
| Watch | Watch SE 3 (40 mm), watchOS 26.5 (`23T570`) | `271517F2-1471-426C-B2BD-B0E265AD1EFC` |

Pair ID: `2BB16DED-737B-446D-AA12-09D3D29DB63D`.

The phone must run the isolated DEBUG fixture with all three opt-in flags: `--uitesting --seed-ui --ui-watch-connectivity`. `DebugBootstrap.usesPairedWatchFixture` allows real WCSession only with that explicit combination during testing. The additional `--skip-welcome --reset-ui --player` flags seed five fixture songs and restore the first song paused at 32 seconds.

**Launch the phone fixture after the Watch test app is running.** Xcode's Watch test installation can install or relaunch the phone app without fixture arguments. During the test's initial confirmation wait, launch or relaunch the phone with its named store:

```sh
SIMCTL_CHILD_GANABAJANA_TEST_STORE=breezy-watch-connectivity-qa \
  xcrun simctl launch --terminate-running-process B1EE1D9A-124A-4788-9760-5C5668E19078 com.agraabhi.ganabajana \
  --uitesting --seed-ui --ui-watch-connectivity --skip-welcome --reset-ui --player
```

The store is `Application Support/GanaBajanaUITests/breezy-watch-connectivity-qa`. Catalog responses and silent WAV audio are local fixtures, and the account uses an in-memory secret store. Test mutations affect that isolated store; production library and account state are not changed. The opt-in and fixture bootstrap are excluded from Release.

`Breezy-Watch-Connectivity-01` failed after Xcode launched the phone without fixture arguments. Starting the isolated phone fixture after the Watch test app launched resolved that setup failure. `Breezy-Watch-Connectivity-02` passed **1/1** using real WCSession: Play confirmed **Tum Hi Ho** on iPhone, Next confirmed **Kesariya**, then Pause was acknowledged. The first run retains its failure. This verifies paired-simulator request/reply integration, not physical hardware or audio fidelity.

## Remaining verification boundaries

Native fixture navigation, control states, long metadata, and hit geometry have passing coverage on the Watch SE 3 (40 mm). The paused flow checks first-viewport transport visibility before scrolling. This scope does not establish every watch size or Dynamic Type setting, native VoiceOver behavior, Reduce Motion, or reduced-luminance/Always On behavior.

Physical paired-device checks remain necessary for iPhone wake/locked/reboot behavior, watch switching, loss and restoration of reachability, background application-context budgets, watch suspension, and playback on the selected iPhone audio route. An acknowledged command means the phone accepted it, not that audio became audible. `Breezy-Companions-Release-02` passed with the embedded Watch arm64 and arm64_32 slices as an unsigned generic-iOS build. After the signing split, `Breezy-Standard-Signing-01` passed a standard signed Debug phone/Watch build and signature checks without the CarPlay entitlement. Signed physical-device installation and minimum-OS acceptance remain unverified.

### Apple API references

- [WCSessionDelegate and background callback ordering](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate)
- [Watch Connectivity background tasks and pending content](https://developer.apple.com/documentation/watchkit/wkwatchconnectivityrefreshbackgroundtask)
- [SwiftUI scene background-task completion and cancellation](https://developer.apple.com/documentation/swiftui/scene/backgroundtask(_:action:))

Initial API research used the local WatchOS 27/iPhoneOS 27 WatchConnectivity headers and WatchOS 27 SwiftUI interface. The later compiled and executed checks are recorded above, separately from that research.
