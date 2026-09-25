# Independent review findings

## Store-capture observations, September 24

The coordinator refreshed the phone/iPad galleries with six actual listening screens and verified every delivered image. Capture-only changes avoid scanning hidden underlying scroll containers when opening the fixed player, wait for the exact visible artist title during navigation, and reselect Library before opening its liked-song page. [Verification](VERIFICATION.md#september-24-core-listening-screenshots) preserves the initial timeout and failed reruns alongside the passing captures.

The iPad combined chooser's artist row failed a hittability check in the first resume run. The successful gallery uses the player's existing direct artist-name action. No production correction or acceptance of the failed chooser path is claimed. The new screenshots include post-build-5 visuals; a matching binary and the existing declaration/content-rights requirements remain necessary before review.

## R8 widgets

Read-only reviews covered the shared snapshot, durability/privacy callbacks, cache-only artwork and widget route handling. The corrections below are integrated and have passing unit/native playback coverage. [WIDGETS.md](WIDGETS.md) owns contracts; [VERIFICATION.md](VERIFICATION.md#r8-home-screen-widgets) owns execution records.

| Finding | Correction and coverage |
| --- | --- |
| A route could discover an externally changed library without invalidating the widget's private content | Source validation emits one availability-transition callback; publisher-owned validation coalesces its own callback. Direct-route and reentrant tests verify immediate redaction without a lifecycle refresh |
| Cold offline widget taps could replace playback before cache inventory was ready | Offline actions await inventory, revalidate source membership/period and honor navigation/privacy cancellation and native control revisions. Gated tests cover rejected recent selections, a cached song later in a mix, failed inventory and ABA controls |
| Opening the current recent song could be superseded by an older station response | Cancel pending radio before the same-current resume shortcut. Native audio and suspended-provider tests preserve the current queue occurrence, file and position |
| An atomic snapshot replacement followed by metadata failure could lose its reload request | Retain a reload obligation through failed publication, then consume it once after successful retry, including identical bytes. Injected post-write and reentrant tests cover this recovery |

Coordinator checks also found an uncached-current shortcut that bypassed the single-song guard. It now refuses before attempting resolution; an isolated native regression retains the prior paused queue and position with zero network requests.

Native UI exposed two geometry issues. Nominal 44-point row frames could round down on a device pixel boundary; 46-point layout frames and explicit accessibility shapes retain the real 44-point minimum. More significantly, WidgetKit archived the small card's accessibility element at the decorative play image's 28-point frame. Grouping and an outer frame did not correct it. A nonvisual card-sized accessibility representation supplies one native Link. The native test requires its actual dimensions and taps away from the former badge before checking local playback, saved resume position and queue order.

The native Mix editor saved Discover Weekly, but AppEnum resolution on the checked runtime still produced Daily Mix. An options provider now carries the existing kind's raw value as an optional string with its native display title. The complete native configuration, Weekly rendering and cached-playback workflow passed, including the exact queue and zero network requests.

## R7 listening controls and native UI

Independent read-only reviews covered shuffle occurrence identity, preference persistence, familiarity ranking, model publication fences and native AirPlay/Settings controls. The following corrections are integrated; [VERIFICATION.md](VERIFICATION.md#r7-airplay-settings-icons-and-listening-controls) owns execution results.

| Finding | Correction and coverage |
| --- | --- |
| Track-only restoration assigned a selected identical duplicate to the wrong original slot | Optional validated `originalQueueIndices` preserves occurrence identity. Exact `[A, B, A, C]` round trips and mapping-only local saves are covered in `PlaybackShuffleQueueTests` |
| Balanced could contain more familiar songs than More familiar despite ample unheard candidates | All Daily Mix modes partition heard/unheard recordings consistently, reserve achievable artist capacity and target 18/10/4 familiar songs. Exact repeated-provider-echo and shared-cap regressions are in `DiscoveryFamiliarityMixTests` |
| Shuffle-only cloud changes cleared Home and triggered catalog work | Merge preparation compares state excluding only the clock and shuffle-style register. Its post-durability callback carries the refresh decision; mixed content/history edits still invalidate discovery. Library and app-model tests cover this distinction |
| Any AirPlay presentation timeout became an unsupported-runtime skip | The native flow requires an explicit capable-runner opt-in before launch; once enabled, presentation timeout fails. Order, anchor and hit-target checks remain unconditional |

Full-unit execution also exposed metadata being added during untouched legacy playback restoration. `PlaybackQueue` retains the absent mapping through passive snapshots and opts in only when order or selected occurrence changes. Existing strict recovery-byte assertions and six new legacy/no-op regressions cover that boundary. Receiver connectivity, active-route tint and physical accessibility speech require native acceptance beyond source inspection.

Runtime UI inspection rejected custom AirPlay button imagery because it overlaid AVKit's existing glyph. A visible, unmodified 44-point picker inside the 56-point slot gives a single compact icon and retains native state/action ownership; actual target and anchor checks pass on phone and iPad. Crossfade's native slider needed explicit interaction/accessibility shapes to expose its 44-point frame. Native Menu image/button metadata is checked as a labeled control hierarchy, and informational Following/Version rows explicitly group title and value.

## R6 source review and integration

Independent read-only reviews covered the new cache/offline runtime and typed Search/sync/navigation changes. The following concrete findings were corrected in source. Completed unit, targeted UI and local Release evidence is recorded in [VERIFICATION.md](VERIFICATION.md#r6-listening-led-discovery-search-cache-and-offline-playback).

| Finding | Correction and regression coverage |
| --- | --- |
| A rejected offline Resume request could seek the song already playing | Single-song `MusicAppModel.play` returns acceptance; Resume callers seek only after acceptance. `AppModelOfflineContinuityTests` covers rejected and accepted native playback |
| Initial unknown-to-online path notification invalidated Home without scheduling replacement | Preserve valid initial work; Home's request identity includes offline state so reconnection refreshes visible content. Controlled Home/Search response tests passed |
| Connectivity cancellation retained a completed-looking cache pair and failed standby identity | Track interrupted work separately; reconnect resynchronizes the live pair after network configuration and rearms failed standby without starting paused audio. Native reconnect tests passed |
| An offline mixed queue stopped at an uncached entry before a later cached recording | Bounded occurrence-aware traversal skips unavailable entries without rewriting the queue, preserving repeat and manual paused intent. Native AAC/Opus and queue traversal tests passed |
| Search reselection recreated its scroller and discarded loaded pages | Keep the NavigationStack/root identity; per-tab reset generations close native links, while one focus/scroll request uses the existing Search view. Model pagination retention and native root/nested reselection checks passed |
| Find music did not pop local destinations opened from Search | Explicit Search opening advances the native-link reset generation. Local liked/playlist search also captures its presenting tab for autofocus |
| Storage could not clear typed-only Search history | Count typed destinations, retain the separate legacy count, and enable atomic clearing when either namespace contains records |
| Next cache copy described the adjacent array entry instead of the offline-playable successor | Use the player's `nextAutomaticTrack`, sharing the same occurrence-aware selection as playback preparation |

Integration also corrected the cached row's native search dismissal and kept cached accessibility decoration out of pure `TrackRow.accessibilityValue` tests. A cold cue-only radio can use another active fallback language only after empty style discovery, within the existing cue budget; learned targeting retains its dominant-language checks. No automatic classification, cache score or nudge creates a synthetic listening event. Library v3 and journal/replica v2 migrations, clear generations, identity-safe filtered edits and failure preservation have passing unit coverage.

Native UI checks exposed smaller accessibility bounds inside the local search field and Queue Save toolbar label. Explicit interaction/accessibility shapes preserve their 48-point frames, with minimum-target assertions passing. The final Queue Save workflow verifies the captured playlist through relaunch while retaining queue duplicates, modes and nonzero paused position. Scoping state reads and dismissals to the visible containers removed a 240-second test-helper timeout without increasing its allowance or dropping the persistence assertions.

The iPhone SE 3 screenshot exposed a separate largest-text defect despite passing control geometry: Recently opened split mid-word beside Clear all. The existing adaptive layout pattern stacks the full-width heading and action at accessibility sizes. The rebuilt Search workflow passed, and its capture confirms natural word wrapping.

## Build-3 release integration

Coordinator verification, separate from the independent source reviews below, placed the native iCloud test-host guard inside `#if DEBUG` and made the Home masthead's existing 46-point circles explicit hit shapes. Thirty-five focused sync tests and the store-capture workflows passed. Release auditing confirms test switches/resources are absent. [VERIFICATION.md](VERIFICATION.md#app-store-preparation-100-3) records the archive, export, upload and capture evidence, including tooling corrections and native StoreKit diagnostics.

The App Store build is valid and attached, with 14 delivered screenshots and five prepared IAPs. This does not clear the provider-authorization or FFmpeg recipient-delivery holds, unanswered age rating, unverified App Privacy/agreements, or native transaction/hardware checks.

## R5 play-count investigation and integration

The play-count investigation and coordinator integration corrected these observed failures. The four new count suites passed within `R5-Unit-0922-174533`; [VERIFICATION.md](VERIFICATION.md) owns the complete unit/UI results.

| Finding | Correction |
| --- | --- |
| Validating an album's audio counterpart discarded the original row's song-play total | Preserve a source-page total through an exact recording ID or a single validated track-credits link, requiring compatible title and artist metadata |
| Now Playing used individual upload views as a missing song total | Use `PlayerController.currentPlayCount`; unknown catalog totals remain hidden and upload views stay diagnostic |
| Written scale labels such as `1.2 billion plays` could parse as `1`; partial and period-qualified labels could become totals | Parse the complete numeric label and unit with exact integer/decimal arithmetic; exclude weekly/monthly counts, audiences, linked names and upload-view labels |
| The AVKit route delegate's nonisolated imported protocol conflicted with Swift 6 isolation | Isolate its conformance to the main actor; build-for-testing passed |

The metadata sample establishes a song-total/upload-view mismatch, not provider-wide count accuracy. Saved legacy counts lack unit and fetch-time provenance. The native AirPlay chooser is not exposed in the checked simulators, so visible-button geometry does not establish receiver connectivity.

## iCloud sync review

The restarted read-only sync review found three P2 defects. Their fixes have passing regression coverage in `R4-FinalFocused-0922-155352`:

| Finding | Correction |
| --- | --- |
| Concurrent track removal/re-addition could leave live playlist membership without an order position and block the whole merge | Retain positions when membership is removed; skewed-clock joins in both directions remain materializable |
| Search tombstone compaction could remove an unrelated retained query | The compaction floor cannot advance through a retained live query; the 40-mutation target yields to correct retention |
| Listening checkpoints encoded the complete shared projection four times on the main actor | Targeted listening/recent payload updates and reused general diffs; tests assert zero full projections for steady-state checkpoints |

Execution also exposed Foundation's two missing-file error codes and cached URL resource metadata after a file/directory replacement. Reads accept only genuine absence as a new store, refresh metadata and reject non-files, preserving retry after transient storage failure. Existing recovery and new sync recovery tests passed after the fix. Native iCloud token/archive handling, account-enabled propagation and OS conflict/download behavior remain device-verification boundaries.

## Companion and player experience review

Parallel source reviews covered album identity, foreground presentation, mini-player progress, the shared playback bridge, Watch Connectivity and CarPlay. The following findings were corrected and re-reviewed; no remaining concrete P1/P2 was identified in that source scope. Runtime verification and physical-device limits remain in [VERIFICATION.md](VERIFICATION.md#current-companion-and-player-changes).

| Finding | Correction |
| --- | --- |
| Album descriptions could borrow another header's artist credits | Title, type, prose and credits now come from the same selected header; competing-header fixtures cover equal and different album titles |
| A guest or producer mention could certify the album's artist | Require a matching album byline or actual soundtrack-composer relationship; reject conflicting leads and incidental contributor mentions |
| A Watch command could first execute after the sender timed out | Fresh phone-issued execution leases expire on the phone's monotonic clock before the client's mutation deadline; delayed first delivery is tested |
| An older displayed Watch action could be retargeted to a newer song | Capture rendered track/session and derived action state before creating a Task; revalidate through preflight and dispatch |
| Library failures could freeze the Watch playing clock or trigger CarPlay playback retry loops | Separate snapshot library errors from playback errors and preserve active audio while showing library recovery guidance |
| Position ticks could submit about 120 background contexts per minute | Semantic changes publish immediately; coalesce position-only updates and suppress them while unreachable, retaining trailing state |
| A newer phone Repeat choice could be overwritten after Watch preflight | Bind the expected Repeat value to the phone-issued lease and validate before the first mutation; keep expiry and replay receipts independent |

Integration also corrected the imported CarPlay disconnect method name, native album Retry accessibility, and UI-test sampling during foreground zoom and Watch List scrolling. The owner-reported signing failure exposed an unconditional managed entitlement in the normal build. CarPlay now has separate opt-in configurations; the normal signed phone/Watch build and signature validation passed. CarPlay entitlement approval and real head-unit acceptance remain open.

## Post-baseline refinement review

The uncommitted changes after `ebb5d5c` received independent reviews of recording-language evidence, compact-switch semantics and playback activation. A P2 in the new language logic allowed a single credible foreign guest segment to escape the veto when English lines were short; comparison now includes the confident whole-text language. Exact, native and lower-confidence regression cases cover the correction. Further review accepted the bounded original-text window/context logic and narrow single-anchor English fallback.

The switch review also accepted explicit call-site styling, the native accessibility representation, and the driver's reachable-child-or-visible-row targeting. Runtime checks retain value changes, persistence, disabled language constraints, reordering, and the 44-point row minimum. Search URL test delivery uses the system URL opener after evidence showed the app-specific opener was relaunching the test process. No remaining concrete P1/P2 was identified in these scoped reviews. Current results and physical-device limits are recorded separately in [VERIFICATION.md](VERIFICATION.md#current-refinements-after-ebb5d5c).

## Original implementation review

Five fresh, read-only reviews covered playback, interface workflows, discovery/lyrics, security, and persistence/release behavior. The initial findings were source-derived; the fix and verification columns record subsequent work separately.

**All 30 original findings and the concrete follow-ups are closed at source.** Follow-up reviews verified the integrated fixes. Automated evidence below covers the relevant code and UI paths; real-account sign-in, native VoiceOver, StoreKit and physical-device acceptance retain their separate limits.

In the table, **Unit** means `Breezy-Unit-Review-04.xcresult` (**869 passed, 28 skipped**, native StoreKit excluded); **UI** means the 72-case fixture run plus its 12/12 correction run; **Vendor** means the 38 passing native YouTubeKit XCTest cases. [VERIFICATION.md](VERIFICATION.md) records exact run boundaries and commands.

## Baseline evidence

- `Breezy-Unit-Final-02.xcresult`: 617 passes, 24 skips; native StoreKit tests excluded because of the recorded platform failure.
- `Breezy-UI-Final-01.xcresult`: 60 passes, one failure. The remaining case and three affected sheet workflows passed in `Breezy-UI-Large-Sheets-02.xcresult` after correcting the test scroll gesture.
- `Breezy-Live-Final-02.xcresult`: 22 passes, two media transport failures. All ten station queues, continuation, catalog, lyrics, MusicBrainz, and audience checks passed.
- `Breezy-Ranged-Audio-Unit-01.xcresult`: 63 passes. `Breezy-Ranged-Audio-Live-01.xcresult`: four passes and one skipped diagnostic probe. These cover the media transport fix and live Opus preparation.

## Findings and disposition

| ID | Priority | Finding | Fix / verification |
| --- | --- | --- | --- |
| SEC-1 | P1 | Unused Matroska metadata can consume work outside interrupt checks | **Closed.** Skip unused metadata before allocation, poll buffered parsing and SeekHead interruption. Rebuilt all slices; five `FFmpegMetadataLimitTests` passed in Unit, including 300,000 tags and cancellation/drain. |
| SEC-2 | P1 | Automatic shared cookies can escape the TV-only authentication boundary | **Closed.** Cookie-free ephemeral extraction and legacy-jar purge; manual authentication remains TV-only. `AccountAuthBridgeTests` in Unit and `ExtractionTransportTests` in Vendor. |
| REL-1 | P1 | Background-refresh callback can enter main-actor code on a background queue | **Closed.** Main-queue registration and sendable expiration cancellation. `ReleaseRefreshRegistrationTests` in Unit exercise the scheduler boundary, not actual iOS scheduling. |
| PLAY-1 | P2 | Cache maintenance can turn foreground preparation cancellation into playback failure | **Closed.** Current intent may use AAC/retained-cache fallback; actual playback cancellation still propagates. `OpusMaintenanceTests` in Unit. |
| PLAY-2 | P2 | Late autoplay continuation does not advance an ended queue | **Closed.** Generation-bound end-of-queue waiting advances only while intent remains current. An early answer that adds nothing earns the entry one forced request at the queue end; a second empty answer pauses with `autoplayContinuationError` set, and the manual retry continues into the appended song. `PlaybackAutoplayContinuationTests` in Unit; live autoplay UI passed. |
| PLAY-3 | P2 | Standby becomes crossfade-eligible before preroll succeeds | **Closed.** Successful preroll plus generation/item identity required. `PlaybackPrerollTests` and transition tests in Unit. |
| AUTH-1 | P2 | Cancelled sign-in can accept a late cookie callback | **Closed.** Synchronous retirement and generation guards reject retained/delayed callbacks. `AccountSignInTests` in Unit. |
| UI-1 | P2 | Collapsed playback failures lack visible recovery feedback | **Closed.** Persistent collapsed Retry and browser banner recovery with measured native hit regions. `GanaBajanaFeedbackUITests` in UI. |
| NAV-1 | P2 | Delayed artist lookup can replace newer navigation | **Closed.** Explicit tab/path/sheet/search intents retire old work; lifecycle `loadSearch()` preserves valid requests. `AppModelNavigationTests`, `AppNavigationIntentTests` in Unit and all three navigation UI workflows. |
| UI-2 | P2 | White text lacks contrast on bright dark-mode accent fills | **Closed.** `onAccent` foregrounds for opaque fills. Seven palettes tested in both appearances in Unit; accent UI persistence/presentation passed. |
| UI-3 | P2 | Song-row accessibility omits rank and contextual statistics | **Closed.** Accessible values distinguish rank, personal statistics and provider-wide counts. `TrackRowAccessibilityTests` in Unit and recap/artist Feedback UI cases. |
| UI-4 | P2 | Transient action confirmations are not announced | **Closed.** Model posts once through ordered, VoiceOver-gated announcement boundary. `AppAccessibilityAnnouncementsTests` in Unit; physical speech timing unverified. |
| AUTH-2 | P2 | Web sign-in errors lack explanation and retry | **Closed.** Visible failure/Retry, preserved nonpersistent session and correct WebKit delegate signature. `AccountSignInTests` in Unit; real Google acceptance unverified. |
| DISC-1 | P2 | Slow speculative artist enrichment can discard successful seed search results | **Closed.** Independent two-second optional enrichment deadline. Gated actual-service cases in `CatalogServiceTests`, Unit. |
| RADIO-1 | P2 | Disjoint language selection can retag incompatible station defaults | **Reversed by design.** Any non-empty language set is valid for every station. Stations without cues for a language start from language-specific search wording; cues tagged for other languages never enter the session, so recordings are not retagged. Configuration/engine/model tests in Unit and radio setup UI. |
| RADIO-2 | P2 | Empty radio responses are reused from cache on retry | **Closed.** Unusable responses not cached; bounded startup and explicit continuation retries request fresh data while preserving cooldowns. Actual-service and model tests in Unit/Focused; live station queues and continuation passed. |
| MIX-1 | P2 | Pending mix generation can publish obsolete languages or newly disliked songs | **Closed.** Generation retirement plus current-state checks at model and durable publication. `AppModelMixTests`, `LibraryMixPublicationTests` in Unit. |
| MIX-2 | P2 | Familiar Daily Mix candidates bypass content/language filtering | **Closed.** Familiar and fresh candidates use the same eligibility pool. `RecommendationEngineTests` in Unit. |
| CREDIT-1 | P2 | Taste/chart projections can assign a collaborator's ID to the primary artist | **Closed.** Each projection retains its own `ArtistCredit` ID. Taste/chart tests in Unit and live linked-credit checks. |
| CATALOG-1 | P2 | Headerless album continuation loses inherited metadata | **Closed.** Album context survives continuation and enrichment; explicit row values win. `CatalogServiceTests` in Unit. |
| CHART-1 | P2 | Weekly refresh retains obsolete date-specific chart snapshots | **Closed.** Replace the per-language slot while preserving reporting metadata and other languages. `HomeDiscoveryShelfTests` in Unit; dated chart UI/live checks. |
| SEC-3 | P2 | Remote chunk-size arithmetic can trap on invalid sizes | **Closed.** Bounded positive chunk sizes and overflow-safe count/offset arithmetic. `RemoteChunkingTests` in Vendor. |
| SEC-4 | P2 | Network body limits occur after complete buffering | **Closed.** App and full/remote extraction enforce receipt-time bounds, per-task cancellation and resource deadlines. `BoundedURLSessionTests`, artwork limits in Unit; 27 bounded/extraction integration cases in Vendor. |
| AUTH-3 | P2 | Failed sign-out can reactivate credentials after relaunch | **Closed.** Credential-free durable pending intent gates restoration before Keychain read; errors retain Retry. `AccountSignOutTests` in Unit. |
| SEC-5 | P2 | Solver errors can log media-signature material | **Closed.** Fixed-category diagnostics and payload-free solver errors. `SignatureSolverDiagnosticTests` in Vendor. |
| DATA-1 | P2 | Failed listening-history writes lose drained checkpoints | **Closed.** Durable acknowledgement retains identity-bearing deltas; bounded backlog pauses instead of dropping. Validated in-process reload preserves external edits and live playback, with explicit privacy boundaries. Listening/recovery tests in Unit and Storage UI. |
| DATA-2 | P2 | Clock correction can make valid stored dates reject the library | **Closed.** Finite UTC-year date bounds and monotonic playlist timestamps. `LibraryClockRollbackTests` in Unit. |
| REL-2 | P2 | Release notifications can be sent after persistence fails | **Closed.** Only durable discovery and pending-delivery state can submit notifications. `LibraryReleasePersistenceTests`, delivery persistence and watcher regressions in Unit. |
| REL-3 | P2 | Alert disable/unfollow can race authorization and notification delivery | **Closed.** Revalidate after authorization and identifier lookup; eligibility check and submission initiation share one main-actor turn. Gated `ReleaseWatcherRegressionTests` in Unit. |
| REL-4 | P2 | An empty successful baseline hides an artist's first release | **Closed.** Explicit successful-empty baseline and conservative legacy migration. Library release, model follow and watcher tests in Unit. |

## Follow-up closure

- **FFmpeg source-cache bypass:** per-patch forward/reverse checks replace the old configure marker; policy-2 cache identity and verification reject stale recipe/patch hashes. Four Python regressions and the full binary audit passed.
- **Artwork cancellation:** per-waiter continuations preserve shared callers; last-waiter cancellation stops the reader and drains retired flights. All nine `ArtworkCancellationTests` passed in Unit and the focused rerun.
- **Radio retry layers:** fresh startup and manual continuation requests cover ten-second recordings filtered by the station engine, including its frontier fallback. Both actual transport and model continuation regressions passed.
- **Library conflict/cold-start recovery:** in-process reload replays acknowledged deltas exactly once, applies external preferences and preserves live playback. A failed-startup placeholder cannot erase a repaired queue; recovery restores it paused only without newer playback intent. Unit and all three recovery UI cases passed.
- **Cancelled alert batches:** durable pending IDs retry independently of discovery throttling, acknowledge accepted submissions and avoid stable-ID duplicates. Identifier lookup cannot reopen disabled/unfollowed delivery. Unit regression coverage passed.
- **Native banner controls:** UI execution exposed small accessible glyph/text bounds and tap-through. Label-level interaction/accessibility shapes fixed the measured Retry/Dismiss targets; the 12-case follow-up passed.

The known content-rights, native StoreKit, Apple web-authentication, and FFmpeg source-distribution holds are tracked in [release status](app-store/RELEASE_STATUS.md). They are not new code findings from these reviews.


## R3 independent review (player, radio, autoplay, artist, layout)

An independent read-only review of the round's new code found no P1. Resolved: manual "Try more songs" at the end of a queue now continues into the appended song instead of leaving the finished track to replay (P2); the artist song list's Try again no longer forces a reload on every later appearance (P2); the Queue sheet's autoplay retry has a real 44-point hit region (P2); radio sessions are excluded from the end-of-queue re-request (P3); the final end-of-queue attempt uses `forceRefresh` so a cached radio that already came up empty is not re-filtered (P3); a spontaneous `CancellationError` finishes the artist song load as a failure instead of leaving waiters hanging (P3); a cancelled first language pass runs again on the next visit (P3). Found by the coordinator afterwards: a nested lazy stack on the artist page pinned the main thread during playback (fixed with plain stacks, verified by `R3-UI-Artist5`).
