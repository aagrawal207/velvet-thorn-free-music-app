# Independent review findings

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
| PLAY-2 | P2 | Late autoplay continuation does not advance an ended queue | **Closed.** Generation-bound end-of-queue waiting advances only while intent remains current. `PlaybackAutoplayContinuationTests` in Unit; live autoplay UI passed. |
| PLAY-3 | P2 | Standby becomes crossfade-eligible before preroll succeeds | **Closed.** Successful preroll plus generation/item identity required. `PlaybackPrerollTests` and transition tests in Unit. |
| AUTH-1 | P2 | Cancelled sign-in can accept a late cookie callback | **Closed.** Synchronous retirement and generation guards reject retained/delayed callbacks. `AccountSignInTests` in Unit. |
| UI-1 | P2 | Collapsed playback failures lack visible recovery feedback | **Closed.** Persistent collapsed Retry and browser banner recovery with measured native hit regions. `GanaBajanaFeedbackUITests` in UI. |
| NAV-1 | P2 | Delayed artist lookup can replace newer navigation | **Closed.** Explicit tab/path/sheet/search intents retire old work; lifecycle `loadSearch()` preserves valid requests. `AppModelNavigationTests`, `AppNavigationIntentTests` in Unit and all three navigation UI workflows. |
| UI-2 | P2 | White text lacks contrast on bright dark-mode accent fills | **Closed.** `onAccent` foregrounds for opaque fills. Seven palettes tested in both appearances in Unit; accent UI persistence/presentation passed. |
| UI-3 | P2 | Song-row accessibility omits rank and contextual statistics | **Closed.** Accessible values distinguish rank, personal statistics and provider-wide counts. `TrackRowAccessibilityTests` in Unit and recap/artist Feedback UI cases. |
| UI-4 | P2 | Transient action confirmations are not announced | **Closed.** Model posts once through ordered, VoiceOver-gated announcement boundary. `AppAccessibilityAnnouncementsTests` in Unit; physical speech timing unverified. |
| AUTH-2 | P2 | Web sign-in errors lack explanation and retry | **Closed.** Visible failure/Retry, preserved nonpersistent session and correct WebKit delegate signature. `AccountSignInTests` in Unit; real Google acceptance unverified. |
| DISC-1 | P2 | Slow speculative artist enrichment can discard successful seed search results | **Closed.** Independent two-second optional enrichment deadline. Gated actual-service cases in `CatalogServiceTests`, Unit. |
| RADIO-1 | P2 | Disjoint language selection can retag incompatible station defaults | **Closed.** Unsupported-only selection rejected without changing seed evidence; zero-artist defaults valid. Configuration/engine/model tests in Unit and radio setup UI. |
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
