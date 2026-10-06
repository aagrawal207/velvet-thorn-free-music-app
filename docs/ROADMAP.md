# Roadmap

The single living list for Breezy. Session notes and handoff files are retired; add here, prune here.

## Mac App and Handoff

Owner request (3 October 2026): build the Mac app, fully with Handoff. The owner chose Mac Catalyst over a native AppKit target, and both Handoff layers. Local source remains **1.0.0 (11)**. No commit, push, upload or App Store Connect change. [MAC_AND_HANDOFF.md](MAC_AND_HANDOFF.md) owns the contracts.

- [x] FFmpegBridge Mac Catalyst slices (arm64, x86_64) in the versioned Mac framework layout; the iPhone device binary is byte-identical.
- [x] Mac Catalyst target with the Mac idiom and the same bundle ID: sandbox entitlements, sidebar, menu bar and shortcuts, window minimum and sheet sizing; Watch filtered to iOS; `GanaBajanaMac` test scheme.
- [x] Catalyst presentation fix: every sheet and cover re-supplies the model (`appPresentationEnvironment`).
- [x] Handoff layer 1: `NSUserActivity` publishing on semantic changes, bounded LZFSE payload, continuation that plays when the sender was playing, sender pauses on continuation.
- [x] Handoff layer 2: Devices over Bonjour and TLS-PSK with an iCloud Keychain link key and an 80-bit pairing code; remote control with leases; Play Here and Play on with readiness-gated release, receiver restore on failure and late-cancel resume; Find Nearby Devices switch and Reset Device Key.
- [x] Review fixes: TLS session resumption disabled (a wrong key reconnected through a cached session), pairing code raised from 6 digits to 80 bits, per-launch Bonjour names, queue caps unified at 1,024, receiver restore, release race, Mac cache path comparison (`/var` against `/private/var`).
- [ ] Owner decisions: Mac App Store distribution replaces the Designed for iPad listing on the same record; publish the new FFmpeg corresponding-source archive before any Mac upload; signed Mac builds (local runs used ad hoc signing without entitlements; a provisioned build is untested).
- [ ] Device checks: Handoff between real devices, Bonjour discovery and transfers on a real network, iCloud Keychain key sync, the Space shortcut beside text fields, Mac UI tests in an unlocked session.

## Velvet Thorn, Skip and Repeat Signals, Hidden Delights and Readable Mixes

Owner requests: rename the app Velvet Thorn; build the skip and repeat signals; add seven hidden delights (equalizer, late night, 100th like, tenth repeat, About x7, sleep timer, one-year card), cheeky allowed; make the Made for You art bigger with readable text below. Local source remains **1.0.0 (11)**. No commit, push, upload or App Store Connect change.

- [x] Rename: Home Screen, in-app copy, widgets and Controls, intents, Watch, CarPlay, share cards, notices and local docs say Velvet Thorn. Technical identities keep their names (bundle ID, widget and Control kinds, intent types, `BreezyWidgets`, `Breezy/1.0` User-Agent, extractor signing domain, cache paths).
- [x] Skip and completion capture (`ListeningSignal`, device-local `ListeningSignalStore`, History Off and Clear History erase it).
- [x] Skips, completions and replays in Discover Weekly, Daily Mixes, Home shelves, Seed Radio and autoplay.
- [x] Seven hidden delights ([DELIGHTS.md](DELIGHTS.md)); `UserDefaults` required-reason declaration added to the privacy manifest.
- [x] Made for You: shared `MixTile` cards with the art on top and two lines of text below, 2 by 2 on phones.
- [ ] Owner authorization: rename the App Store Connect record, IAP localizations and public Support/Privacy pages; check Velvet Thorn's App Store name availability. Optionally switch the default icon to a Thorn design to match the name.
- [ ] Device checks: tabla sound and haptic, heart burst, late-night line on a real clock, skip signals over a week of real listening.

## Icons, Visible Player Motion, Made for You Grid, Glass Chrome and Discover Weekly

Owner requests: add every Thorn and Leafnote colourway; the player background animation was not visible; smaller Home tiles with Discover Weekly and the Daily Mixes in a grid that never scrolls sideways; real Liquid Glass behind the tab bar and mini-player while every screen still ends above the mini-player; Discover Weekly must not repeat heard songs and should include less popular songs. Discussed, not built: skip and repeat listening signals, hidden delights, a Thorn-based app name. Local source remains **1.0.0 (11)**. No commit, push or upload.

- [x] 13 new icons (Leafnote: Paper, Sky, Blossom, Midnight, Violet, Sunset, Mono; Thorn: Edge, Frost, Noir, Venom, Dusk, Blush) in three picker sections; the 15 earlier icon files are byte-identical.
- [x] Player background: a 4 by 4 artwork-colour mesh with no scrim, visible motion, 4.5:1 text contrast tested for every tone; Settings explains a held-still background.
- [x] Made for You as a 2 by 2 grid of compact cards (one column at accessibility sizes, four across on iPad); smaller cards and tiles on the other shelves; Play controls announce as buttons.
- [x] Glass chrome: content scrolls beneath the tab bar and mini-player; `miniPlayerClearanceProbe()` sets the navigation controller's bottom safe area to the mini-player's height for every root and pushed page.
- [x] Discover Weekly: same-song matching across uploads, providers and versions; a familiar artist's top five hits skipped; deep-cut share 20/35/50 percent by Discovery balance.
- [ ] Owner decisions: build the skip and repeat signals (device-local store, privacy text); which hidden delights to add; whether to rename the app.
- [ ] Pre-existing UI failures to triage: three `GanaBajanaQueueSaveUITests` cases in the player sheets and two `GanaBajanaFeedbackUITests` accessibility-value cases; the Home discovery-carousel card at the largest text size (known since R19).

## Heat, Player Motion, Accent Reach and Settings Captions

Owner requests: find and fix why Breezy heats the phone (library writes, YouTube decoding, byte-at-a-time downloads); an animated player background with selectable styles including a music-reactive one; accent on the active lyric line and on the Watch; captions under the Settings root pages; Thorn and Leafnote colour variants; record the Handoff plan. Local source remains **1.0.0 (11)**. No commit, push or upload.

- [x] Library: metadata (`lstat`) fence replaces the full-file read before every write; a no-change checkpoint does no disk read or write; one JSON parse at load instead of up to four; lookup-table hex for lifetime receipts. Disk I/O deliberately stays on the main actor (AGENTS contract and lost-update risk); the remaining cost is the whole-file atomic write per real checkpoint.
- [x] YouTube signature solver: two process-wide prepared JavaScriptCore contexts keyed by player, with yt-ejs preprocessed players; later solves about 10 ms instead of about 1 s (macOS `jsc`, JIT off). Evicted on failure and on memory pressure.
- [x] Chunked network bodies (`URLSession.chunkedBody`) for song downloads, `boundedData`, probes, artwork, LRCLIB and Live Radio; same limits, errors and cancellation; bounded buffering with task suspension.
- [x] Player Background (Settings > Appearance > Player): Off, Drift, Pulse, React to Music; static under Reduce Motion, Reduce Transparency, Increase Contrast, Low Power and thermal pressure; React to Music falls back to Pulse without a tap (HLS, live).
- [x] Active lyric line in the accent (primary text under Increase Contrast). Owner to judge readability.
- [x] Watch follows the phone accent through an optional companion snapshot field (no wire-version change), saved on the watch.
- [x] Settings root page captions.
- [x] Icon variant sheets: `artifacts/R21/icon-variants/` (Thorn: Edge, Frost, Noir, Venom, Dusk, Blush; Leafnote: Paper, Sky, Blossom, Midnight, Violet, Sunset, Mono). Not added to the app until the owner picks.
- [ ] Owner: pick icon variants to ship; judge lyric accent readability; physical-device heat and battery comparison before and after; React to Music on real music on a device.

## Lock Screen Widgets, Controls and Accent

Owner request: Lock Screen and Notification Center widgets or Controls to reach the app and play or pause the last song; the accent colour must apply everywhere, including Settings icons; review where else the accent belongs. Local source remains **1.0.0 (11)**. No commit, push or upload.

- [x] Play or Pause widget (Lock Screen circular, rectangular and inline; small for Home Screen and Today View), Open Breezy Lock Screen widget, Play or Pause and Open Breezy Controls.
- [x] App Group playback state, app-process playback intents, the `ganabajana://player` route and reloads only on selection, play-state, history or accent changes.
- [x] Accent in sheets and Settings (`appAccentChrome`), and the window tint for UIKit alerts, dialogs, menus and share sheets.
- [x] Accent on the live-radio saved heart and the active sleep timer.
- [x] Unit, model-integration, render, UI, native widget and Release checks; WIDGETS, PRIVACY and VERIFICATION updated.
- [ ] Physical device: Lock Screen and Control Center placement, interactive taps, a cold background launch from a Control, the Action button, accessory tinting and VoiceOver.
- [ ] Owner decision: accent for the active lyric line and Watch accent sync (needs a companion protocol field).

## Quick-Skip Preparation and Faster Search

Owner request: rapid Next taps should start the following songs quickly, likely songs on Search, album and artist pages should be prepared, the rest of a song should download only once it is actually being listened to, and Search should be faster. Local source remains **1.0.0 (11)**; TestFlight build 11 does not contain this work. No commit, push or upload.

- [x] Map playback items, the cache pipeline, warming paths and search latency.
- [x] Spike ~20 s byte prefixes through a resource loader; live checks showed slower starts (AVFoundation reads the whole fragment index), so the approach was rejected and archived.
- [x] Preload native assets for the queue's next five songs (play order, nearest first, two at a time, waiting for the selected song's first audio) and three browsing candidates; reuse them for the active player and gapless deck.
- [x] Manual Next takes the ready gapless deck.
- [x] Download the current song first and the next only after 30 s (or half a shorter song); remove speculative complete downloads from queue and warms.
- [x] Apply preparation to Search, album/playlist, artist and Home surfaces with the existing network gates.
- [x] Measure Search; publish YouTube Music results progressively, cancel unused artist-page fetches and use a first-page artist lookup for featured songs.
- [x] Add metrics, unit/integration/live coverage; run focused regression, UI and Release checks; update FAST_START, ARCHITECTURE, PROVIDERS, PRIVACY and VERIFICATION.
- [ ] Physical-device rapid-skip and search timing on Wi-Fi, cellular and a poor network, including background playback.

[FAST_START.md](FAST_START.md#quick-skips-and-browsing-october-2026) owns the contract and [VERIFICATION.md](VERIFICATION.md#quick-skip-preparation-and-faster-search) the receipts.

## September 30 TestFlight Delivery

- [x] Verify build-number availability, signing profiles and targeted release evidence for 1.0.0 (11).
- [x] Freeze source hashes, archive, export, audit signatures/resources and pass Apple validation.
- [x] Upload build 11, verify VALID processing and existing internal Friends access, save en-US What to Test notes.
- [x] Verify remote IPA checksum, preserve receipts and update release records.

Delivered build `eed48919-97be-46a8-a3ca-b742f502d782` is `READY_FOR_BETA_TESTING` and expires December 29, 2026. The public draft retains build 6. This explicit delivery authorization followed the local R21 work below; no Git commit/push or review submission occurred. [APPSTORE_TESTFLIGHT.md](APPSTORE_TESTFLIGHT.md) owns remote state. Preserve `artifacts/AppStore-1.0.0-11/inputs.json` after future edits.

## Release Notification Follow-Up

- [x] Trace notification creation and navigation: alerts carry `release.<browseID>`, but the delegate handled foreground presentation only.
- [x] Route default notification taps to the exact album/single page, retaining cold-launch intent until navigation is ready and accepting older alerts without metadata.
- [x] Verify cold/warm routing, malformed/dismissed alerts, modal dismissal and playback preservation; record automated evidence and remaining native-delivery acceptance.
- [ ] Confirm a genuine delivered notification tap on a physical device, both with Breezy running and terminated.

Local build remains **1.0.0 (11)**. `Notification-Tests-01` passed 49 unit/model tests and two phone UI workflows; `Notification-IPad-01` passed both UI workflows. The unsigned `Notification-Release-01` build and fixture-exclusion inspection passed. [VERIFICATION.md](VERIFICATION.md) records the scope; [ARCHITECTURE.md](ARCHITECTURE.md#durable-release-alert-delivery) owns routing behavior. Diagnostics use bounded `release_notification_tap` accepted/ignored outcomes without release IDs or names.

## R21: Song and Artist Radio Rebuild

Owner-approved scope: replace the non-live mood/setup flow with one-tap song and artist radio, reliable continuation rooted in the original recording/artist, device-local Listen Again, and optional session tuning. Live Radio stays separate. No commit, push or upload is authorized. Preserve existing saved queues, playback positions and R17–R20 work.

Current source is **1.0.0 (11)**. Implementation and targeted automated verification are complete; the remaining acceptance is real-device listening quality and startup/refill latency. [SEED_RADIO.md](SEED_RADIO.md) owns the contract and [VERIFICATION.md](VERIFICATION.md) owns the receipts.

### Durable Task Ledger

- [x] Map current engine, playback callbacks, UI entry points and persistence contracts.
- [x] Implement shared seed/tuning types, bounded original-anchor engine and selection tests.
- [x] Implement versioned Listen Again storage (20 entries, history-off/clear handling, corruption preservation).
- [x] Wire start/refill/retry/tuning into MusicAppModel; preserve current-song position and manually queued songs.
- [x] Replace the Radio browse/setup user path; add song-menu, artist-page and Player More entry points.
- [x] Add Listen Again, suggestions, isolated song/artist search and Tune Radio.
- [x] Add deterministic mock-backed functional coverage plus targeted native playback/UI coverage.
- [x] Run focused builds/tests, phone/SE/iPad checks and Release inspection; record actual evidence.
- [x] Reconcile AGENTS, README, feature docs, VERIFICATION and local build status.

### Agreed Contracts and Ownership

- Coordinator owns `MusicAppModel.swift`, `PlayerController.swift`, shared `RadioSeed.swift`, DebugBootstrap fixtures, project/build configuration and integration docs. Only coordinator builds or uses simulators.
- Engine worker owns new `SeedRadioEngine.swift` and its tests. Store worker owns new `RadioHistoryStore.swift` and its tests. UI worker owns Radio browse/search/tune views and song/artist/player entry-point edits. No overlapping edits outside those boundaries.
- Reuse Track, ArtistCredit, DiscoveryFamiliarity, ArtistSongLanguage, catalog radio/artist APIs, language evidence and existing playback. Song starts need one recording, not a full queue. Artist starts resolve a credited recording first. Late work cannot override newer playback or privacy intent.
- First version tunes future radio additions; current audio and queued songs (including manual duplicates) remain intact. UI states this explicitly. Explicit language accepts only identified matches, excludes unknowns, and reports scarcity without silently broadening.
- Listen Again records only accepted starts when Save Listening History is on; it is device-local, bounded and keyed to the library history epoch. Restored music remains paused; restarting a recent seed creates a fresh radio session.
- Metrics: bounded start/refill outcomes, seed kind, familiarity, language, accepted counts and preparation latency; no track IDs, artist names or search text. These timings do not measure first audible audio. Unit tests cover selection and storage boundaries; functional tests cover start/refill/tune/failure/privacy; UI/audio tests cover native actions and continuing playback.
- Mood presets and multi-artist blending are deferred until the seed-based experience passes listening acceptance. Remaining physical-device and recommendation-quality checks must not be marked complete from simulator evidence.

Research references: integration agent `ses_f0cc546adffeRTKu9HrTxIZmTC`; UI agent `ses_f0cc54690ffeKqY3bTrDt5Qo06`.

Implementation checkpoints:
- Engine `ses_f0cc0770dffeDtFzWpyamGUL3Y`, store `ses_f0cc076c1ffefH20LTqmx9MXeh`, UI `ses_f0cc07637ffel4sO4ySERh5ywN`, functional tests `ses_f0cb8ad34ffecqIYD4gfgvMt4Q`, UI tests `ses_f0cb3808cffeFapdGEAtq1gYr8` have delivered their owned files.
- Coordinator integrated seed starts/refill/tune/privacy and a three-song radio refill threshold. Queue selection preserves occurrences and that threshold; ordinary autoplay remains last-song-only.
- `artifacts/R21/Build-01.xcresult`: build-for-testing passed (69 s), local build **1.0.0 (11)**.
- `artifacts/R21/Core-01.xcresult`: **66 passed**, covering engine, Listen Again store, new model workflows, legacy model compatibility and native autoplay continuation.
- Review `ses_f0c8da2c9ffecdIhmB2yznJbP2` found failed-library history erasure, cross-language seed restart, exhausted-session recovery, stale language evidence and unbounded generated history. All five were addressed; retention worker `ses_f0c7d075fffeHn4vQ9tPDdNr9S` added occurrence-safe pruning and nine tests. The last 40 selected previous generated entries are retained, plus 128 pruned-recording exclusions; manual/unselected/upcoming entries are protected.
- `Core-02`: **90 passed**. `UI-06`: **27 passed**, including all four seed-radio workflows and Search regression suites. The shell reached its timeout as the run finished; the finalized xcresult reports success, although the runner completion JSON is absent.
- `UI-Entries-01`: song menu and artist-page entry points passed. `UI-SE-01` and `UI-IPad-01`: Tune/Listen Again workflow passed in both appearances. `UI-Navigation-01`: two migrated navigation/onboarding checks passed. `UI-IPad-Layout-01`: portrait/landscape layout workflow passed.
- `Build-09`, `UI-SE-Toolbar-01` and `UI-IPad-Toolbar-01` verify the final one-line Cancel label in light/dark. Final `Release-02` and fixture/resource inspection passed for build 11. No signing, archive, upload or real account changes.
- `artifacts/R21/run.py` runs one bounded process group. Set the shell timeout longer than its `R21_TIMEOUT` plus shutdown grace; inspect the completion JSON or finalized xcresult rather than an unbounded `pgrep` loop.

### Remaining R21 Acceptance

- [ ] Listen on a physical device across song/artist seeds and assess relevance, repetition and gaps over a long session.
- [ ] Measure tap-to-audio and refill latency with real providers, including poor connectivity and background playback.
- [ ] Check VoiceOver and Tune Radio at the largest accessibility text size on-device.
- [ ] Reconsider a small set of mood presets only after seed-radio listening acceptance; multi-artist blending remains deferred.

## R20 Super Like Follow-Ups

R20 source was **1.0.0 (10)**, local and uncommitted. R20 closed the three follow-ups from R19: Super Likes on Watch and CarPlay (companion wire v2), the Super Liked Home shelf, Storage count and row badge, and background regeneration of Discover Weekly and Daily Mixes. Follow-up work addressed measured scrolling stalls, radio stream validation, Settings search and immediate Play-to-Download coordination. Verification and remaining native limits are recorded in [VERIFICATION.md](VERIFICATION.md). No R20 commit, push or upload was performed. Mix captions crediting super likes and a Stats count remain in the backlog.

## Completed R19 Super Likes and Motion Polish

R19 source was **1.0.0 (9)**. R19 adds Super Likes ([contract](SUPER_LIKES.md)): a stronger like tier stored as a third value of the per-song reaction register (library v5, journal/replica v4), three times the like weight in `TasteProfile`, one reserved rotating seed and one reserved Daily Mix pick, a Download Liked Songs scope (Off, Super Liked Only, All Liked), Super Liked filters in Liked Songs and Downloads, the heart hold gesture with menu, More and swipe rows, and a one-time TipKit hint. The same round polishes motion under the iOS skill's interface-craft defaults: the play button morphs between play and pause and pulses behind one turning arc while loading instead of a spinner, the heart bounces on a like and bursts on a super like with haptics, the current-song waveform badge animates while playing, and filter chips wrap and animate their selection; everything drops scale and translation under Reduce Motion. Both halves of the unit target, the five R19 workflows on phone, SE and iPad in light and dark, the touched player, downloads, library, settings, R17 and R18 suites and the unsigned device Release build passed on the polished source; [VERIFICATION.md](VERIFICATION.md) owns counts, the stale-test corrections and the two open pre-existing Refinement Home-carousel failures. No R19 commit, push or upload was performed. Decisions taken with the owner: Discover Weekly stays unheard-only; older builds (including delivered build 6) refuse the new files; unliking a super liked song removes it fully; Watch/CarPlay show super likes as likes until backlog item 14.

Two pre-existing test failures found while running the whole unit target were corrected without weakening assertions: `DailyMixClusteringTests.testWidgetSnapshotCarriesDiscoverWeeklyAndThreeDailyMixes` used a live `Date()` that lost sub-millisecond bits through the widget store, and `ListeningProjectionCacheTests.testReloadSameCountSameTotalAndSameLastSessionInvalidatesBothProfiles` replaced a saved session's track without rebuilding its lifetime receipt (a rule introduced in R17). Two R18-era UI expectations were also stale: the export detail copy ("Song details included") and the Account page inventory (YouTube Changes, Extractor Updates rows).

## Completed R18 Local Feature Round

R18 source was **1.0.0 (8)**. R18 implements five features and the export corrections below; targeted verification passed. No R18 commit, push or upload was performed. **1.0.0 (6)** remains the latest delivered build, uploaded on 27 September 2026, processed VALID and attached to the iOS draft. Its receipts and input hashes are frozen. [APPSTORE_TESTFLIGHT.md](APPSTORE_TESTFLIGHT.md) owns remote state.

Core/regression, vendor compatibility and public KCRW playback checks passed. All five workflows have passing phone, SE and iPad coverage in light/dark, including account cancellation and fake confirmation. The unsigned device Release build passed. [VERIFICATION.md](VERIFICATION.md) owns counts, corrected failures and run boundaries. No full green app/device matrix is claimed.

Independent static review found no actionable bugs; it provides source-review evidence only. Native account acceptance and receiving-app cover support remain distinct from the completed automated checks.

| R18 Item | Implemented Scope | Remaining Verification |
| --- | --- | --- |
| WP22 Live Radio | Radio Browser search and country/language/tag filters, NPR discovery, local favorites, distinct live AVPlayer mode, paused music restoration | Public KCRW checks passed in the reported scope; broader stations/HLS and hardware acceptance remain. [Contract](LIVE_RADIO.md) |
| Gain-Up Normalisation | Existing preference raises quiet sources by at most 6 dB through the shared EQ tap, 20 ms ramp and linked sample limiter | Hardware listening, route behavior and final crossfade peaks remain; not true-peak or final-mix limiting. [Contract](VOLUME_NORMALISATION.md) |
| YouTube Account Write-Back | Default-off device/sign-in permission, separate confirmed remote actions, strict receipts and zero mutation retries | Phone/SE/iPad UI passed; real provider acceptance remains. Tests sent no real account activity. [Contract](ACCOUNT_WRITEBACK.md) |
| Extractor Hot-Updates | Manual Files import of bounded field aliases/hash-bound transforms, checksum and explicit trust, generation fences and rollback | No feed/publisher key configured; genuine user package acceptance remains. No arbitrary or automatically generated repair rules. [Contract](EXTRACTOR_UPDATES.md) |
| Playback Source Display | Actual `playbackSource` through resolution, cache/background persistence, active/standby state and More | Phone/SE/iPad cached/relaunch workflows passed; unknown legacy provenance is explicit. [Contract](AUDIO_QUALITY.md) |
| Export Bug Corrections | Timeline/marker-aware verification, reasoned failures, native cover-byte readback and immutable Sendable share callbacks | Exact failing user songs, genuine user assets and destination cover support remain unknown. [Contract](AUDIO_EXPORT.md) |

## Completed R17 Source Round

R17 source was **1.0.0 (7)**. Its eight items were implemented and integrated, with targeted core/component, phone/SE/iPad UI and unsigned Release checks passed. The feature workflows and optional onboarding retain their recorded scope in [VERIFICATION.md](VERIFICATION.md); those earlier checks do not verify build 8.

The owner reports constant physical testing and actual TV audio AirPlay working great. This closes the existing audio acceptance item as an owner report. New TV lyrics/mirroring, native motion and background OS-suspension checks remain separate and unverified.

| R17 Item | Implemented Scope | Verification Status |
| --- | --- | --- |
| Moment Mixes | Device-local time/route contexts recurring across three days; optional motion; Home and Settings integration; detached history preparation | Core and phone/SE/iPad UI checks passed; native motion unverified. [Contract](MOMENT_MIXES.md) |
| Background Downloads | OS-owned file transfers, durable URL-free queue, reattachment and foreground validation | Core/component checks passed; physical OS suspension unverified. [Contract](BACKGROUND_DOWNLOADS.md) |
| Lifetime Statistics | Exact session receipts, v4 local/v3 sync, lifetime time/plays with retained-detail rankings | Core/regression and phone Stats light/dark checks passed; native two-device convergence unverified. [Contract](LIFETIME_STATISTICS.md) |
| Lyric Sources and Script Choices | Bounded LRCLIB/catalog/JioSaavn variants; raw audio-language metadata with saved correction priority; shared phone/TV selection | Core/integration and phone light/dark checks passed; published Gurmukhi availability is recording-specific. [Contract](LYRICS_VARIANTS.md) |
| TV Lyrics | Opt-in phone/mirrored and separate noninteractive display presentation with source credit | Core/integration and phone light/dark checks passed; actual TV lyrics and latency unverified. [Contract](TV_LYRICS.md) |
| Compatible Audio Export | Verified tagged AAC-LC M4A, real encoding when needed, larger artwork and leased local input | Native local-media/integration and phone light/dark checks passed; recipient/device interruption checks remain. [Contract](AUDIO_EXPORT.md) |
| Discovery and Onboarding | Optional one-time post-Welcome YouTube connection; no automatic import; truthful Home language provenance | UI-01 onboarding passed; broader device/account checks remain. [Contract](DISCOVERY_ONBOARDING.md) |
| Not Liked Downloads | All/Liked/Not Liked filters using favorite membership, including live heart changes without file deletion | Phone/SE/iPad light/dark passed. [Contract](DOWNLOADS.md) |

## Prior R16 Work and Other Active Items

| Current item | Scope | Status |
| --- | --- | --- |
| Scrolling performance | Narrow library observation, cache analytics, batch and prepare durable playback checkpoints off the main actor | Verified R16; benchmark main-actor checkpoint capture/apply 5–9 ms, physical-device acceptance pending |
| Stats and title case | Rename visible Listening to Stats and capitalize headings/options without changing routes, stored IDs or song metadata | Done; R16 verified |
| Recommendation exclusion | Use Don't Recommend This Song / Allow Recommendations; keep the existing recommendation exclusion semantics | Done; R16 verified |
| Download Liked Songs | Same global preference exposed in Liked Songs; hide the filter row while enabled, reset to All and show truthful progress | Done; R16 verified |
| Store listing / TestFlight | Listing updated; build 6 signed, Apple-validated, uploaded and attached. Existing internal Friends group has access; external beta setup/review remains pending | Upload and checksum readback verified |
| Public radio | Radio Browser discovery and distinct live mode | Implemented in R18 under WP22; targeted and public playback checks passed |
| Slow song starts | Fix late foreground promotion of a warm-up after its hedge timer fired; retain startup timing across automatic retries | Done; 64 focused tests passed; no new physical-device latency claim |
| Compact Play/Shuffle | Shared list and cached-song controls plus collection Play/Shuffle use smaller visuals with at least 44-point targets | Done; phone, SE and iPad verified |
| Liked Songs durations | Show known song durations using existing TrackRow formatting | Done; phone, SE and iPad verified |
| Stats share payload | Image-only default, optional Include Summary Text inside the preview | Done; phone, SE and iPad verified |
| Playlist creation position | Move the plus action beside the Playlists heading | Done; phone, SE and iPad verified |
| Mix cover titles | Remove duplicate title overlay; retain title and focus caption below Daily Mix / Discover Weekly cards | Done; UI capture inspected |

## Historical Decision: Local-Only (25 September 2026)

This records the decision at that time. The later authorized build-6 upload is recorded above; it does not authorize an R17 or R18 upload.

- Breezy is installed from Xcode on the owner's devices with the paid team's development signing. It is not submitted to the App Store. The playback model (unofficial extraction, audio-only, background, cached and downloaded audio) cannot satisfy App Store guideline 5.2.3 or YouTube's API Services Developer Policies, and authorization is not expected.
- Nothing is removed. The Tip Jar, `docs/app-store/`, `artifacts/AppStore-*`, the public Support/Privacy pages and the App Store Connect record stay dormant so a policy change can revive submission later. The pending owner steps (privacy publication, MetaBrainz registration, age rating, App Privacy, Google audit form, build 6 upload) are closed as not needed.
- Features the store would reject are in scope. Personal use under YouTube's terms is the owner's accepted risk; account-based features stay opt-in with plain warnings.

## Install

- Xcode: run the `GanaBajana` scheme on the device with the Release build configuration (Edit Scheme > Run > Build Configuration) so fixtures and the StoreKit file stay out and Debug speed does not apply.
- IPA: export with a development method like `artifacts/Breezy-1.0.0-2-Development/ExportOptions.plist` (`method: debugging`, automatic signing, team `W2NS9DM63G`) and install through the Xcode Devices window or Apple Configurator. Development profiles last 12 months and cover up to 100 registered devices.
- Watch app, widgets, iCloud sync and App Groups work on development profiles. CarPlay still needs Apple's capability approval and its opt-in scheme.

## R12: local-only feature round (in progress)

| WP | Feature | Status |
| --- | --- | --- |
| 0 | Player file split into `Sources/Views/Player/`; R12 preferences and `MusicSource` pre-declared | Done |
| 1 | Player shell: larger artwork, heading one line lower, artist line opens the album/artists chooser (direct when one destination), Album and artists button removed, AirPlay bottom-left, Lyrics and Queue bottom-right, right time label shows song length by default with a Settings choice and tap-to-switch | Done |
| 2 | Liked heart: solid `primaryText` fill (play-button material), accent trace stays on top | Done (superseded by R13 item 6) |
| 4 | Song details under More: performers, composer/lyricist/producer/label/release date from YouTube's "Provided to YouTube" description, MusicBrainz work/release enrichment, plays, views, quality, cache state, recording ID | Done |
| 5 | Managed downloads (song/album/playlist, pinned non-purgeable store, Wi-Fi-only default, auto-download liked songs, Downloaded filter) and audio export to Files/Share as tagged m4a | Done |
| 6 | Persistent audio quality preference (Best / Balanced / Data saver), higher tiers when the signed-in account offers them | Done |
| 7 | 10-band equalizer with presets and custom gains | Done |
| 8 | YouTube account library import (liked songs, playlists, subscriptions, history), read-only, opt-in | Done |
| 9 | JioSaavn catalog (search, albums, artists, playlists, streams up to 320 kbps) behind the `MusicSource` abstraction | Done |
| 9b | Gaana catalog on the same abstraction (search, albums, playlists, artists, own HLS streams at 128 kbps, JioSaavn then YouTube fallback for missing streams) | Done |
| 11 | SponsorBlock non-music segment skipping (off by default) | Done |
| 12 | Docs integration and verification matrix (17 Pro, SE 3, iPad Pro 13) | In progress |

## R13: owner review items (26 September 2026)

Feedback after using the R12 build. Small items run alongside the remaining R12 packages; the two large ones follow.

| # | Item | Notes | Status |
| --- | --- | --- | --- |
| 1 | Recap: move Listening languages to the bottom | Layout only | Done |
| 2 | Recap: minutes listened must not sit on one album cover | Reads as if that single song produced the total. Replace with a stat tile or a daily/weekly bar, artwork only where it means that song | Done |
| 3 | Search start screen: drop the Liked songs and Your library shortcuts; move Cached songs into Library | Library gets a Cached songs entry next to Downloads | Done |
| 4 | Cached songs screen: no "Cached songs" action in the offline banner while that screen is open, and no second "You're offline" line | Screenshot 26 Sep 10:42 | Done |
| 5 | Settings redesign | Uneven row lengths, uneven spacing between rows and sections, and the section flickers when iCloud sync status changes. Fixed-height status, no whole-form re-render | Done (`docs/SETTINGS.md`) |
| 6 | Player: heart back in the track heading, full-width progress bar | The progress-to-heart trail reduced seek range and did not look good. Liked = filled heart in accent, unliked = outline | Done |
| 7 | Player: bottom icons share one visual weight | AirPlay glyph renders smaller than Lyrics and Queue | Done |
| 8 | Player: swipe up opens Lyrics by default | Settings > Playback choice: Lyrics, Queue, More options, Off | Done |
| 9 | Bug: playlist search results open with no songs | Root cause: playlist pages made of music-video rows were dropped by the audio-only row filter; video rows now list on playlist pages as `isAudioRecording == false` | Done |
| 10 | Genre taste profile | Track listening by genre (and other song facts) like the language tuner: MusicBrainz genres per recording and artist, bounded background classification, `TasteProfile` genre weights feeding Home shelves, Daily Mix, Discover Weekly and radio; Recap "Top genres"; Settings nudges | Done |
| 11 | Fast start: songs often load slowly | Measure time to first audio per path (local copy, URL cache, fast path, YouTubeKit, Opus download-before-play). Play the best progressive stream at once and prepare higher-bitrate Opus in the background for later plays. Warm the top search results (stream URLs, then the first result's audio) as results arrive and the first songs of an opened album or playlist, bounded and cancellable | Done (`docs/FAST_START.md`; warmed starts 0.3 to 0.7 s, cold starts unchanged on fast links) |
| 12 | Downloaded songs leave the cache | A downloaded song appears only under Downloads; promotion removes its other cache-tier variants (respecting in-use readers); Cached songs and the temporary cache totals exclude downloads | Done |
| 13 | Player: Download button beside AirPlay | Bottom row: AirPlay, Download (states: download, progress ring, downloaded with remove confirmation), then Lyrics and Queue at the trailing edge | Done |

## R14: owner review, second pass (26 September 2026)

Design decisions taken while the owner was away are marked "Decision"; revisit any of them.

| # | Item | Decision and notes | WP | Status |
| --- | --- | --- | --- | --- |
| 1 | AirPlay to a TV is stuck loading | Phone-rendered audio route (`allowsExternalPlayback = false`, long-form sharing); the original root cause was a source diagnosis | 21 | Done; local routing checks passed and R17 owner report closes actual TV audio acceptance |
| 2 | Free live radio under Search | Radio Browser directory, country/language/tag search and local favorites. Live stations have no seek, cache, download or lyrics | 22 | Implemented and integrated in R18; verification in progress |
| 3 | Smaller Downloaded and Cached entries in Library | Compact rows implemented; R15 moved cache management to Settings | 23 | Done; R15 targeted verification |
| 4 | Liked vs downloaded vs cached navigation | Likes has All/Downloaded/On This Device; offline banner opens the combined list. Downloads adds Not Liked in R17 | 23 | Done; subsequent R16 toggle and R17 filter recorded above |
| 5 | Recent listens in Library and Recap | Recents live in Stats with See All; Home keeps Recently Played | 23 | Done; R15 targeted verification |
| 6 | Share Recap as a picture | Preview-first card; R16 defaults to image-only sharing | 23 | Done; R15/R16 targeted verification |
| 7 | Share songs with cover and metadata | R15 settled on one Share Song preview with Share and Share Link Only inside | 25 | Done; R15 targeted verification |
| 8 | Download symbol missing in More once downloaded | Downloaded state keeps its filled glyph and offers Remove Download | 25 | Done; integrated |
| 9 | Dislike | Don't Recommend This Song stays in More, hidden while liked. Generated recommendations exclude it; explicit selections remain playable. Reaction state syncs | 25 | Done; R16 wording verified |
| 10 | Rename "Share song" to "Share song link" | Superseded by the single Share Song preview and its internal link-only choice | 25 | Done; superseded decision |
| 11 | Remove the Right time label setting | The player tap already persists the choice | 26 | Done, verified R15 |
| 12 | Fewer repeats as the default shuffle order | New and missing-field defaults use Fewer repeats. Preserve a stored Random choice because old stores do not distinguish explicit choices from defaults | 26 | Done, verified R15 |
| 13 | Equalizer easier to understand | Plain band/preset descriptions, Simple Bass/Mids/Treble and Advanced ten-band modes | 25 | Done; WP25 targeted checks recorded in EQUALIZER and VERIFICATION |
| 14 | Equalizer from the player's More | Compact equalizer sheet in More | 25 | Done; integrated |
| 15 | Equalizer per song | Use for This Song and saved named presets, device-local | 25 | Done; WP25 targeted checks recorded in EQUALIZER and VERIFICATION |
| 16 | Following in Settings opens Library at the list | | 23 + 26 | Done, verified R15 on phone, SE and iPad |
| 17 | More space between setting rows and their explanations | | 26 | Done, verified R15 |
| 18 | Settings subsections | Decision: the six sections become pages from a short top list, each page grouped by topic | 26 | Done, verified R15 |
| 19 | Home: Daily Mix beside Discover Weekly, three Daily Mixes | Daily Mix 1 to 3 use distinct taste clusters; titles sit below the covers | 27 | Done; integrated, targeted evidence in VERIFICATION |
| 20 | More options order: Dislike and Share song link near the top | Recommendation exclusion and one Share Song preview lead More | 25 | Done; R15/R16 targeted verification |
| 21 | Moment mixes (original gym/commute request) | Implemented as descriptive time/route contexts, not automatic gym or commute names. Requires three distinct local days | 28 | Done in R17; targeted checks passed, native motion unverified |

## Latest review: Listening, sharing and sync

This table preserves the R15 review decisions. R16 renamed Listening to Stats; R17 implemented the lifetime, lyrics and discovery follow-ups. Public radio is implemented in R18 above.

| Item | Decision / scope | Status |
| --- | --- | --- |
| Finish interrupted WP26 | Settings pages, Following navigation, footer spacing and defaults; fix iPad tab lookup and preserve explicit shuffle choices | Done; R15 targeted checks passed |
| Rename Recap | Use Listening in visible copy, preserve internal routes and stored identifiers | Done; R15 verified |
| All Time | Count all surviving saved history with an explicit coverage note. Deleted history cannot be recovered; current retention is not a lifetime archive | Done; R15 verified |
| Listening section order | On repeat immediately above Day by day; Recently played last and collapsed with See all inside | Done; R15 verified |
| One Listening Share action | Higher on the page; opens a preview, which owns the share action | Done; R15 verified |
| Repeated iCloud sync failure popups | Investigate actual triggers, stale merges and schema compatibility. Preserve local/remote data; bounded retry and notification deduplication | Regression fixes verified; exact device error remains unconfirmed |
| One song-sharing action | Open one preview with cover and metadata, then share. Preserve a link-only option inside the preview instead of duplicating More rows | Done; R15 verified |
| Cached audio management in Settings | Remove cached-management entry from Library; retain Settings > Library & iCloud > Storage & cached songs. Liked, Downloads and On this device remain playback entry points | Done; R15 verified |
| English/Hindi discovery shelves | Dynamic listening profile retained; subtitle distinguishes starting defaults, saved settings and learned listening | Implemented and integrated in R17 |
| TV timed lyrics and contrast | Opt-in app-owned phone/external presentation; receiver-owned audio card remains separate | Implemented and integrated in R17; hardware lyrics checks pending |
| True lifetime statistics | Exact receipts preserve time/plays beyond detail retention; shared journal/file capacity can bind before the receipt cap | Done in R17; targeted checks passed, native two-device acceptance unverified |

## Backlog

Ordered by owner interest; move an item into a round table when it starts.

1. Personalised Home from the signed-in account (`FEmusic_home`).
2. Direct licensed lyric sources such as Musixmatch richsync or Genius remain unimplemented without keys/access. R17 integrates bounded JioSaavn and LRCLIB variants with attribution.
3. Opus export (needs an FFmpeg rebuild with muxers) and ringtone clips (.m4r).
4. Scrobbling to ListenBrainz and Last.fm: sending listening records to those services for an external listening history. Explanation only; no client, account connection or submission is implemented.
5. Spotify and Apple Music playlist import.
6. Skip silence.
7. Cross-device playback handoff (transfer a session, not only its queue). Built in Mac App and Handoff (Mac Catalyst instead of a native target, by owner choice); the original plan:
   - **Layer 1, Handoff (`NSUserActivity`).** `PlayerController` publishes one activity (`com.agraabhi.ganabajana.playback`) on selection, play/pause and seek, not on ticks. Payload is the existing Foundation-only `PlaybackSnapshot` (queue IDs and metadata, index, position, shuffle/repeat, `originalQueueIndices`) plus a timestamp; never signed URLs, credentials or history. The receiver accepts it with `onContinueUserActivity`, applies it through `MusicAppModel` paused at the adjusted position, and starts only on the listener's tap. The sender pauses once the receiver reports acceptance.
   - **Layer 2, local companion link.** `CompanionProtocol` (snapshot, now playing, actions, bounded codec) is transport-independent. Run it over Network.framework with Bonjour so an iPhone and a Mac or iPad can control each other with exact handover timing, as the Watch does today; reuse the six-second execution lease and keep offline mutations unqueued.
   - **Prerequisite.** A native Mac target needs FFmpegBridge `macos-arm64` slices, platform checks around `AVAudioSession`/`UIApplication` background tasks in `PlaybackSystemControls`, and AppKit stand-ins for share sheets, the sign-in web view and alternate icons. CarPlay, WatchConnectivity, CoreMotion and `BGTaskScheduler` stay out of it. Designed for iPad already runs on Apple silicon today.
   - **Order.** Handoff on iPhone and iPad first, then the companion link, then the native Mac target. Queue and position stay device-local and move only through these two layers.
8. iPad landscape capture fidelity in the headless geometry harness (known limitation).
9. Caption video entries in `TrackRow` (playlist pages list music videos; Home editorial playlist shelves are thin because most rows are videos).
10. Tap-related gapless delay: historical EQ measurements were 0.2 to 0.4 s; normalization-only timing still needs measurement.
11. Remove the "Your playlists" shortcuts from Search if the owner wants Search fully catalog-only.
12. Gaana's own HLS streams cannot be downloaded or equalized; only fallback files are cached. Hide Download for such songs or add an HLS-to-file path.
13. Live-account verification of the YouTube library import browse ids (needs the owner's signed-in device).
14. Super Like mix captions and a Stats count (owner: later). The Home shelf, Storage row and row badge shipped in R20; captions on Daily Mix covers that credit a super like and a super-like count in Stats remain.

## R20 Follow-Up Acceptance Still Open

- Measure remaining page-push and tab-switch latency on a physical device; simulator improvements do not establish device frame timing.
- Verify immediate Play followed by Download against real YouTube media on a device.
- Verify live-radio health checks on cellular and investigate stations that pass the probe but fail native readiness. The directory audit covers 275 sampled stations, not the entire changing directory.
- Restore a functioning native StoreKit test session. The purchase timeout prevents hangs, but `SKInternalErrorDomain Code=3` and `notEntitled` remain unresolved.
- Fix the two pre-existing Refinement Home-carousel layout failures recorded in VERIFICATION.

Completed locally: profiling and measured fixes, radio validation improvements and failed-probe filtering, Settings search, download coordination, test-hang guards, and the duplicate Done in Player > YouTube Changes. The toolbar fix has passing light/dark UI coverage in `Fix-UI-03`.

## Declined for now

- Video mode and Picture in Picture (owner: not now).
- Speed and pitch controls (owner: not needed).
- Removing the Tip Jar or any store record.

## Conventions for this journey

- Add, do not remove. Existing contracts in `AGENTS.md` still apply unless a round table says otherwise.
- Each feature ships with `docs/<FEATURE>.md` (behaviour, APIs, network recipients and bounds, metrics table, coverage table). Shared docs (`ARCHITECTURE`, `PROVIDERS`, `PRIVACY`, `VERIFICATION`, `AGENTS`) are integrated at round end.
- Evidence for round N lives under `artifacts/R<N>/` with unique result bundle names.
