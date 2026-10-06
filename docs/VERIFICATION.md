# Verification

## Mac App and Handoff

Local uncommitted source, still labelled **1.0.0 (11)**; not in TestFlight build 11. Receipts are under `artifacts/R22/` (runner `artifacts/R22/run.py`, which adds `R22_SCHEME`, `R22_DERIVED` and `R22_SIGN=adhoc`). Mac runs used `artifacts/MacDerivedData` on this Mac (macOS 26.6.2) with ad hoc signing and no entitlements; the screen was locked throughout.

| Receipt | Executed Result and Scope |
| --- | --- |
| `ffmpeg-build-2.log`, `build-ffmpeg.py --component verify` | Five slices built and packaged; verification passed. iPhone device binary byte-identical (`14e66860…`); simulator binary identical once signatures are removed (`6355bcd2…` both); Catalyst slice `MACCATALYST` minos 18.0, arm64 and x86_64. New corresponding source `…7611a216….tar.xz` (unpublished) |
| `Mac-Build-01`…`16` | Mac Catalyst Debug builds. The first launch crashed opening the player and then any sheet ("No Observable object of type MusicAppModel"); fixed with `appPresentationEnvironment`. In-process window captures (`shots/mac-05`, `mac-08`, `mac-09`) show the sidebar, Home, Search, the player, Song Options, Devices and Settings |
| `Mac-Catalyst-Unit-02`, `Recheck-01`…`04`, `Unit-03` | Full unit target on Mac Catalyst. First run 29 failed: CarPlay template suites (compiled out on the Mac), alternate icons and the route-sharing policy (skipped on the Mac), the accent sheet render (fixed by page sizing), and cache maintenance deleting an in-flight Opus input because macOS lists `/var` as `/private/var` (fixed: `AudioCache.comparablePath`). Final: **2,933 passed, 0 failed, 49 skipped** |
| `Mac-Tests-01`…`04` | Handoff, link and companion classes on iPhone. Loopback found a real defect: TLS session resumption let a wrong key reconnect after a good one; resumption and tickets are now off. After the review fixes: **74 passed** (codec, publisher, protocol, controller, loopback TLS, two-controller socket integration) |
| `Mac-iOS-Unit-01`, `Unit-02`, `Recheck-01` | Full iPhone unit target: **2,972 passed, 8 failed, 47 skipped** of 3,027. Six are the recorded native `TipJarStoreKitTests` environment gap; the view-count test is the known intermittent; the CarPlay cold-launch test failed once and **both passed** alone (30 passed) |
| `Mac-UI-01`…`03` | iPhone UI: **50 of 52**, then **2 of 2**: Player More (with the Devices row), Settings pages, organization, search, layout, Sheet Done, accent, player shell, mini-player progress, delights, browse, Search. Fixed: the layout inventory now lists `settings.devices`; Sheet Done centres against the title row because the bar includes the Search Settings drawer |
| `Link-Live-01`…`11` | Not established: Bonjour discovery between the Mac app and simulators. The apps' listeners and browsers reached ready, yet no browse results arrived in-process, even for a shell-registered service, while a command-line `NWBrowser` saw both; Local Network permission could not be granted with the screen locked |
| `Mac-Release-iOS-02`, `mac-round-ios-release-inspection.json` | Unsigned iPhone Release build; inspection clean, new fixture markers absent. Executable SHA256 `fa9b5ffd2552fd3077a4552235d77a4dbe3fd6601c0ff4b9eb6d3c740507ca7c` |
| `Mac-Release-Mac-02`, `mac-release-inspection.json` | Unsigned Mac Catalyst Release build, universal (arm64, x86_64); family 6, macOS 15.0 minimum, Handoff and Bonjour keys present, no Watch app, Catalyst FFmpeg slice, fixtures absent. Executable SHA256 `d95303ad18c9f7e6438c3aca6e3eb03a89729ca062e2dba7e31c70d362c17446` |

Review: a fresh-context review blocked the first link draft. The 6-digit pairing code was the only TLS secret and could be cracked offline; it is now 80 bits. Further fixes: a Find Nearby Devices switch and Reset Device Key, per-launch Bonjour names, receiver restore on a failed transfer, the release race, one 1,024-song cap, a release-time track check, and a Keychain read cache. Handoff pausing a sender whose payload the receiver declines is documented as a limitation.

Not verified: Handoff between real devices; discovery, control and transfers on a real network; iCloud Keychain key sync; the Space shortcut beside text fields on the Mac; Mac UI tests; signed or provisioned Mac builds.

## Velvet Thorn, Skip and Repeat Signals, Hidden Delights and Readable Mixes

Local uncommitted source, still labelled **1.0.0 (11)**; not in TestFlight build 11. Receipts are under `artifacts/R21/`.

| Receipt | Executed Result and Scope |
| --- | --- |
| `Round4-Build-01`…`05` | Debug build-for-testing passed after the rename, the mix tiles, the three work packages and the autoplay and Seed Radio wiring (one test expression split for the type checker) |
| `Round4-Tests-01`, `-02` | **334 passed, 3 failed** across 27 classes: new `DelightsTests`, `ListeningSignalCaptureTests`, `ListeningSignalStoreTests`, `SkipSignalRecommendationTests`, `DiscoverWeeklyDiscoveryTests`, plus taste profile, super like, recommendation, familiarity, language, clustering, seed radio, autoplay, mix, listening controls, playback, layout, widget, CarPlay, companion and share-card suites. One About-tap test miscounted its own taps (corrected); the CarPlay library-write test and the view-count test are known intermittent: the next run passed **32 of 33**, and the view-count test then **passed 2 of 3** alone (`Round4-ViewCount-01`…`03`) |
| `Round4-Regress-01`, `Round4-Recheck-01` | **514 passed, 2 failed** across 46 playback, cache, download, radio, companion, widget, accent, library, sync, checkpoint, history and search classes; both failures (CarPlay library write, Live Radio transport) are known intermittent and passed with their classes (**13 passed**) |
| `Round4-UI-01`, `Round4-Mix-01` | **22 passed, 1 failed**, then **2 passed**: Delights (About taps), Settings pages and search (renamed About page), widget previews (renamed copy), accent, player background, scroll ends for tab roots and pushed pages; Made for You first measured unequal card heights (238 vs 223 points) because the stretch was inside the link; with the frame on the link both grid tests pass and the capture shows art with full titles and focus lines below |
| `Round4-Release-01`, `round4-release-inspection.json` | Unsigned device Release build passed; inspection clean; app and widget `CFBundleDisplayName` are Velvet Thorn. Executable SHA256 `b9f6de967172fd93ad89b4fb4ebe27eb85caf8f9e032eec50d99411c8067bc84` |

Not verified: the tabla sound and haptic, the heart burst and the late-night line on a device; skip signals over real listening; the App Store Connect record, which still carries the previous name.

## Icons, Visible Player Motion, Made for You Grid, Glass Chrome and Discover Weekly

Local uncommitted source, still labelled **1.0.0 (11)**; not in TestFlight build 11. Receipts are under `artifacts/R21/`. The Mac lost power during this round; bundles from before the restart (`Mix-UI-01`, `Round2-UI-01`, `Round3-UI-04` before its process finished) are not cited as evidence unless read from a completed result.

| Receipt | Executed Result and Scope |
| --- | --- |
| Icon generation | `swift tools/generate-artwork.swift --icons` for the 13 new ids, then a re-render of Leafnote, Thorn and Sonnet through the shared helpers: all 15 earlier icon and preview PNGs are byte-identical to the backup (SHA-1 per file); every new icon is 1024 by 1024 and every preview 240 by 240 RGB without alpha |
| `Round2-Tests-01`…`04` | Icons, picker and background: **105 passed, 2 failed** (the Drift frame interval assertion and a pale light-mode mesh, both changed deliberately), then **22 passed** after the light tones got their own saturation bands: policy, preference, meter math, metering tap, 4.5:1 contrast for every mesh tone and neighbour blend, visible colour travel, no mesh fold, and `PlaybackLevelMeterIntegrationTests` reading a playing AVPlayer item |
| `Round2-Background-UI-01` | **1 passed**: each style chosen in Settings and the player shown in dark and light. Frame-to-frame pixel change over 4 s: Drift mean 9.4 (max 69), light Drift 10.5 (max 67), Pulse 4.7, React to Music 1.3 on the constant fixture tone |
| `Round3-Tests-01`, `-02` | **131 passed, 1 failed**, then **25 passed**: `DiscoverWeeklyDiscoveryTests` (8, new) with the existing recommendation, familiarity, language, super-like, mix, genre and refresh suites. The failure was deliberate: a model test's artist page listed the neighbour song as a familiar artist's first top song, now a likely-known hit; the fixture puts five hits ahead of it and asserts they stay out |
| `Mix-UI-02` | **1 failed**: Made for You Play controls were exposed as "Other" because `accessibilityElement(children: .ignore)` dropped the button trait (also on the existing Mix tiles); `.isButton` restored |
| `Round3-UI-02` | **20 passed, 12 failed** with the glass agent's `safeAreaInset` version: pushed pages ignored the inset, so their last rows stayed under the capsule. Replaced by `miniPlayerClearanceProbe()` |
| `Round3-UI-03`…`06` | Final layout: tab roots (`testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabs`) and pushed ScrollView and List pages (`…PushedScrollAndListEnds…`, default and largest text) **passed**; Made for You grid (default and accessibility sizes), mini-player progress (both), collection presentation (4), navigation intent (5), keyboard growth and player background **passed**. Two stale UI-test strings were updated to the app's title-case copy ("Recently Played", "An Open Queue") |
| Remaining failures | `testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabsAtLargestTextSize` fails on the Home discovery-carousel card, recorded as failing since R19. Three `GanaBajanaQueueSaveUITests` cases in the player's More and Save Remaining sheets (a 42.2-point Reload target, unreachable rows) and two `GanaBajanaFeedbackUITests` accessibility values failed identically in every run, before and after the layout fix; this round did not change those sheets or rows, but no older baseline run confirms them |
| `Round3-IPad-01` | **2 passed**: `GanaBajanaIPadLayoutUITests` on iPad Pro 13 |
| `Round3-Release-01`, `round3-release-inspection.json` | Unsigned device Release build passed; inspection clean. Executable SHA256 `e188fe5b5061582cd674843a5ffcffc986c867cbb7d58df1ef967a256a78792c` |

Not verified: physical-device look of the glass chrome and the animated background, iOS 18 material fallback (all simulators run iOS 26.5), alternate icon switching for the new icons on a device, and Discover Weekly quality against live catalogs.

## Heat, Player Motion, Accent Reach and Settings Captions

Local uncommitted source, still labelled **1.0.0 (11)**; not in TestFlight build 11. Receipts are under `artifacts/R21/`.

| Receipt | Executed Result and Scope |
| --- | --- |
| `Settings-UI-01`…`03` | Root captions. First run: 13 passed, 3 failed (row-height assertion assumed 44-point page rows; accessibility-size reveal could not aim at an off-screen row). Assertions updated for the captioned page-row shape, captions shortened, reveal tries both directions: **14 passed** (SettingsPages, SettingsLayout including AX XXXL dark/light, SettingsSearch) |
| `Batch-Build-01`, `-02` | Debug build-for-testing of all five work packages together passed on the first build |
| `Batch-Tests-01` | **115 passed**: `LibraryWriteFenceTests`, `ChunkedBodyTests`, `CompanionProtocolTests`, `CompanionPlaybackControllerTests`, `WatchPhonePublicationTests`, `BoundedURLSessionTests`. The `PlayerBackgroundMotionTests` selector matched no class; those classes ran in `Background-Tests-02` |
| `Solver-Unit-01` (`swift test`, Vendor/YouTubeKit) | **9 passed** `SignatureSolverReuseTests`; network-backed `SignatureTests` and `NSigTests` passed over 155 real player cases through the shared cache |
| `Batch-Regress-01` | **617 passed, 1 failed, 2 skipped** across 55 playback, cache, download, catalog, provider, equalizer, widget and library classes. The failure is the known intermittent `LiveRadioPlaybackTests.testNativeTransportDispatchAndLiveNowPlayingClearAllSongMetadata`, which passed with its class in `Batch-Library-01` |
| `Batch-Library-01` | **732 passed, 6 failed** across 82 library, sync, lifetime, history, checkpoint, recap, widget, tip and search classes. All six failures are native `TipJarStoreKitTests` (`notEntitled`, StoreKit dialog timeouts), the recorded StoreKit environment gap, unrelated to these changes |
| `Watch-Unit-01` | **41 passed**: `GanaBajanaWatchTests` on Watch SE 3 including the new `WatchAccentTests` |
| `Batch-UI-01` | **29 passed**: SettingsPages, SettingsLayout, SettingsSearch, ListeningControls, Accent, PlayerMore, PlayerProgressBar, FastStart, PlayerDownload |
| `Background-Tests-02` | **19 passed**: policy, preference decode/sync, level meter math, metering tap, mesh bounds and a new 4.5:1 text-contrast check at both luminance bounds |
| `Background-UI-02`, `-04` | **1 passed**: each style chosen in Settings and the player shown. Frame-to-frame pixel change over 4 s (fixture without artwork, gold fallback): Pulse mean 4.9, max 24; Drift mean 0.4 (30 s cycles); React to Music mean 0.15 on the constant fixture tone. `Background-UI-03` could not launch the runner (SpringBoard busy) |
| `Batch-Release-01`, `batch-release-inspection.json` | Unsigned device Release build passed; inspection clean. Executable SHA256 `49e3fa2a1625992154bb1b810d3e669bb30cad3d06ba2fb8cc0b19597123a328`. Superseded by `Batch-Release-02` |
| `Batch-Release-02`, `batch-release-inspection-02.json` | Final unsigned device Release build passed; inspection clean. Executable SHA256 `d6f6ed052908b6d744b117c07a3ed055fbaac2230cb796f4cc02472ee80df55b` |

Not verified: device heat, battery and frame time; React to Music on real music; Watch accent over a real phone connection; lyric accent readability (owner judgement).

## Lock Screen Widgets, Controls and Accent Follow-Up

Local uncommitted source, still labelled **1.0.0 (11)**; not in TestFlight build 11. Receipts are under `artifacts/R21/`. [WIDGETS.md](WIDGETS.md#lock-screen-widgets-and-controls) owns the contract.

| Receipt | Executed Result and Scope |
| --- | --- |
| `Widgets-Build-01`…`05` | Debug build-for-testing passed after each edit; no new compiler warnings in the changed files |
| `Widgets-Tests-01`, `-02` | One failure in the new sheet-accent render test: it assumed `ImageRenderer` falls back to the coral asset, which it does not. That assumption was dropped; the mint assertions stand. Then **181 passed** across `PlaybackWidgetTests` (7, new), `AppAccentTests` (new sheet-chrome render), widget snapshot/publisher/route/presentation, widget navigation/playback/mix/offline/supersession, companion, release-notification and `PlaybackControllerTests` |
| `Widgets-Regress-01` | **280 passed, 1 failed** across 26 playback, cache, offline, radio, companion, widget and share-card classes. `LiveRadioPlaybackTests.testNativeTransportDispatchAndLiveNowPlayingClearAllSongMetadata`, a known intermittent test, passed with its class in `Widgets-Recheck-01` |
| `Accent-UI-02` | **2 passed** (`Accent-UI-01` could not launch the runner: SpringBoard busy). Captures show the Settings tile icons and the picker checkmark in mint, where they had stayed coral |
| `Widgets-UI-01`, `-02` | **14 passed, 2 failed**, then **15 passed, 1 failed**. Both native widget failures came from the unsigned runner (`CODE_SIGNING_ALLOWED=NO`): there is no App Group container, so the fixture read `unavailable`. The other failure was a stale UI-test string; see `Widgets-Recheck-04` |
| `Widgets-Native-01` | **2 passed**: `GanaBajanaNativeWidgetsUITests` with simulator signing (a separate derived-data folder, since removed); the existing Home Screen widgets are unaffected |
| `Widgets-Recheck-02`…`04` | Two UI-test strings predated the title-case empty-state copy (`Save a Song You Love`, `The First Song Sets the Mood`). Updated to match the app; **7 passed** (`GanaBajanaLibrarySearchUITests` and the empty Liked preview) |
| `Widgets-Release-01`, `widgets-release-inspection.json` | Unsigned device Release build passed and inspection is clean. Executable SHA256 `7705ca496f43276bcf0b48f30e8f0a8010bc9ce02833807910235ebcc73a88ba`. App Intents metadata in both the app and the extension lists `TogglePlaybackIntent` and `SetBreezyPlaybackIntent` as audio-starting intents, and `OpenBreezyPlayerIntent` with `openAppWhenRun` |

Not verified: Lock Screen and Control Center placement, interactive taps, cold background launch from a Control, Action button, accessory tinting and VoiceOver on a physical device. The simulator Lock Screen was not exercised.

## Quick-Skip Preparation and Faster Search

Local uncommitted source, still labelled **1.0.0 (11)**; the delivered TestFlight build 11 predates it. Receipts are under `artifacts/R21/`. [FAST_START.md](FAST_START.md#quick-skips-and-browsing-october-2026) owns behaviour, bounds and test mapping.

| Receipt | Executed Result and Scope |
| --- | --- |
| `Prefix-Live-01`…`05` | Rejected byte-prefix spike, live YouTube. Prefixed starts 3.0 to 3.8 s vs 0.5 to 1.7 s plain; 25 to 47 range requests before audio; unreachable continuation gave no audio in 10 s; content type and on-demand flag variants did not help; a metadata-preloaded native asset started in about 0.3 s. Spike sources archived in `artifacts/R21/prefix-spike/` |
| `Search-Live-01`…`03` | Live stage timings before and after the search changes; numbers in FAST_START. Network variance is large and nothing asserts on time |
| `Preload-Live-02` | Live preloader: 5/5 prepared in 5.1 s; preloaded first audio 321 to 492 ms vs 387 to 1,298 ms for the warm URL alone, which ran on connections the preloader had opened |
| `Preload-Tests-01` | **112 passed**: new `PlaybackPreloaderTests` (13), `PlaybackPreloadIntegrationTests` (4), `ProgressiveSearchTests` (13), plus the cache, offline, catalog, warmer and transition suites touched by the change |
| `Preload-Regress-04` | **561 passed, 2 failed** across 48 playback, cache, download, offline, search, radio, companion and integration classes. `PlaybackWarmerTests.testAWarmNeverDisplacesTheQueuePrefetchDownload…` (timeout) and `LiveRadioPlaybackTests.testNativeTransportDispatchAndLiveNowPlayingClearAllSongMetadata` both passed in `Preload-Recheck-02` (**20 passed**, the two whole classes) |
| `Preload-UI-01` | **12 passed**: FastStart, CatalogSources, Gaana, SeedRadio workflows and the search/play workflow on iPhone 17 Pro |
| `Preload-Release-01` | Unsigned Release build before the review fixes; superseded by `Preload-Release-02` |
| Review fixes | An independent read-only review found no high-severity defects. It found seven medium issues, all fixed: a stale hold let queue work start beside a new selection and from a paused restored queue; the hold blocked browsing; warm re-routing restarted preparations and spent the URL budget; evicted assets were cancelled while possibly in use; stale signed URLs looked prepared; an obsolete next download ran to completion; and a finished artist page could be dropped by a slow songs request. Low findings fixed: network/preference re-planning and `isSearching` during pagination. Documented, not changed: Opus-only offers still prepare during resolution; the settle rule uses playback position |
| `Preload-Tests-02`, `-03` | **146 passed, 1 failed**, then **20 passed** after one store assertion was updated for the intended stale-URL drop. Covers the new suites plus cache, offline, catalog, warmer, transition and audio-quality classes, with new tests for paused restore, stale URLs, obsolete next transfers and a page that arrives before a slow songs request |
| `Preload-Regress-06` | **447 passed, 1 failed** across 40 remaining regression classes; `CarPlayPlaybackIntegrationTests` passed alone in `Preload-Recheck-03` (**3 passed**). `Preload-Regress-05` was interrupted by the owner and is not evidence |
| `Preload-UI-02` | **12 passed** on the final source: FastStart, CatalogSources, Gaana, SeedRadio and the search/play workflow |
| `Preload-Release-02`, `preload-release-inspection.json` | Final unsigned device Release build passed; DEBUG fixtures and test resources absent, credential excluded from companions, no broad ATS. Executable SHA256 `6b4cce0034eed9e873fd92676ce5018444ce8bd56f222fa73a3f14fc80ee30a9`; no signature audit |

Six existing expectations changed deliberately: three described the old next-before-current download order, two ran a reconnect or late-download scenario that now needs `nextDownloadSettleSeconds = 0`, and one counted collection warms at 2 instead of 3. One new preloader assertion was corrected to check requests rather than the stored candidate list. The settle rule, current-first order and three-song collection warm are owner-requested behaviour. `CatalogServiceTests.testSuccessfulSongsReturnWhileOptionalArtistSearchOrPageRemainsGated` initially failed on an unintended change (a slow artist page produced a featured card); the code was corrected so a late page still drops the feature, and the original expectation passes unchanged.

Not verified: physical-device timing, cellular or poor networks, background playback and long-idle connection reuse. No full unit-target or full UI run is claimed.

## September 30: Build 11 TestFlight Delivery

Explicitly authorized delivery of the tested R17–R21 working tree and release-notification fix, **1.0.0 (11)**. `artifacts/AppStore-1.0.0-11/summary.json` records build `eed48919-97be-46a8-a3ca-b742f502d782`, VALID processing, matching remote IPA size/MD5 and unchanged frozen source hashes. Signed archive/resource audit, nested phone/Watch/widget signature/profile inspection and Apple validation passed. The 20,713,556-byte IPA has SHA256 `ed078358584f0e3561e72bd4041fb4bad2f5a780e1128ab41f24df8a61c67573`.

Internal state is `READY_FOR_BETA_TESTING`, with existing Friends group access and en-US test notes verified by readback. Expiration is December 29, 2026 at 21:34:58 UTC. Temporary export keychain cleanup preserved the original search list/default. The public iOS draft retains build 6; no App Review/Beta App Review submission or Git write occurred. These delivery checks do not close the physical-device acceptance items below. Earlier “no upload” statements describe the implementation checkpoints before this authorized delivery.

## Release Notification Navigation Follow-Up

Local **1.0.0 (11)** adds the missing notification-response handler. Tapping an alert opens its album/single on Library, dismisses Settings or the player, and leaves playback untouched. Cold-launch intent waits for RootView navigation, including Welcome completion. Older alerts use their existing `release.<browseID>` identifier; saved metadata is optional. Missing catalog content uses the collection page's existing loading/error behavior.

Receipts under `artifacts/R21/`:

| Receipt | Executed Result and Scope |
| --- | --- |
| `Notification-Build-04` | Build-for-testing passed. Earlier compile attempts caught initialization order, a C callback capture and a Swift 6 actor-boundary error; all were corrected before testing |
| `Notification-Tests-01` | **51 passed, zero skipped** on iPhone 17 Pro: 49 unit/model tests across ReleaseNotificationRouting, ReleaseWatcher, ReleaseWatcherRegression and LibraryReleaseDeliveryPersistence, plus two new UI workflows |
| `Notification-IPad-01` | **2 passed** on iPad Pro 13: the same cold-launch and warm-navigation workflows |
| `Notification-Release-01`, `notification-release-inspection.json` | Unsigned device Release passed. DEBUG fixtures and test resources absent, credential excluded from companions, no broad ATS exception. Executable SHA256 `a08134d25f228a01826697265c9affe3c1c0967d8f56e963d8535451a7e44201`; no signature audit |

`ReleaseNotificationRoutingTests` covers exact IDs (including prefixed providers), old alerts, missing saved releases, latest pending tap, one-time consumption, ignored dismiss/custom actions and invalid IDs, duplicate taps, modal flags and unchanged paused queue/index/position/control revision. Native UI tests verify the actual album page, Back/foreground without route replay, player/Settings dismissal and replacing a pushed Liked Songs destination. The cold workflow uses dark appearance; the warm workflow uses light and local audio fixtures.

### Release notification tap crash (post-build-11)

The R21 fixtures called `handle(request:actionIdentifier:)` directly and never entered the system delegate. Tapping a real banner crashed: the async `didReceive` finished on the cooperative pool and UIKit's response completion (`-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]`) asserted the main thread. The delegate now uses the completion-handler forms and runs the completion on the main actor. `--release-notification-system` schedules a real banner for `testTappingSystemBannerFromBackgroundOpensAlbumWithoutCrashing`.

| Receipt (`artifacts/R22/`) | Executed Result and Scope |
| --- | --- |
| `R22-releaseTap-original-*` | Before the fix, iPhone 17 Pro: the new system-banner test failed and the simulator wrote a `GanaBajana` SIGABRT report with the stack above |
| `R22-releaseTap-fixed-*b` | After the fix: cold-launch and system-banner tests **passed**, no crash report. The warm fixture test failed at launch waiting for `tab.home` behind the `--player` cover; it fails identically when run alone and does not reach the delegate |
| `R22-releaseUnit-*` | `ReleaseNotificationRoutingTests` **5 passed** |

The UI fixture injects a parsed launch intent or calls the production request handler through a DEBUG-only signal. It does not schedule or tap a genuine system notification. Physical-device delivery, lock-screen taps and terminated-app OS handoff remain acceptance checks. TestFlight stays build 6; no commit or upload was performed. Earlier R21 release receipts remain historical evidence for the radio work.

## R21: Song and Artist Radio

Local source **1.0.0 (11)** replaces the non-live mood/setup UI with song/artist starts, Tune Radio, Listen Again and anchored continuation. [SEED_RADIO.md](SEED_RADIO.md) owns the implemented contract and test mapping. Receipts are in `artifacts/R21/`. TestFlight remains build 6; no commit, signing, archive or upload was performed.

| Receipt | Executed Result and Scope |
| --- | --- |
| `Build-01`…`Build-09` | Incremental build-for-testing checkpoints passed. `Build-09` includes the final Tune toolbar sizing fix and targeted test; these builds reused app-owned derived data |
| `Core-01.xcresult` | **66 passed** across seed engine/store/model, legacy model compatibility, setup playback and native autoplay continuation |
| `Core-02.xcresult` | **90 passed** after the review fixes, adding occurrence-safe retention, PlaybackQueue and failed-library/tuned-restart/current-evidence regressions. Overlaps Core-01 |
| `UI-06.xcresult` | **27 passed**: all four initial seed-radio functional UI workflows, SearchDiscovery and SearchRedesign. The external shell timeout fired at the end; the finalized xcresult reports Passed, 27 tests, 0 failures. The runner completion JSON was not written |
| `UI-Entries-01.xcresult` | **1 passed**: song-menu and artist-page Start Radio, no setup or automatic full-player presentation, correct session labels and native cached playback |
| `UI-SE-01.xcresult`, `UI-IPad-01.xcresult` | **1 passed each**, the song-search/Tune/Listen Again/relaunch/refill workflow in light and dark on SE3 and iPad Pro 13 |
| `UI-Navigation-01.xcresult` | **2 passed**: Radio pop/reselect/focus and welcome-to-radio without mandatory language selection |
| `UI-IPad-Layout-01.xcresult` | **1 passed**: native portrait/landscape layout workflow, including the replacement Radio page and existing player/queue controls |
| `UI-SE-Toolbar-01.xcresult`, `UI-IPad-Toolbar-01.xcresult` | **1 passed each**, checking the final Tune toolbar and Cancel dismissal in light/dark. Screenshots in `SE-toolbar-captures` and `IPad-toolbar-captures` were visually inspected: Cancel stays on one line, both pickers and footer copy fit |
| `Release-02.xcresult`, `release-inspection.json` | Final unsigned `generic/platform=iOS` Release build **1.0.0 (11)** passed. DEBUG fixture markers (including `DebugSeedRadioCatalog`) and test resources absent; API credential excluded from companions; no broad ATS exception. Executable SHA256 `f5fe1e9381daeba55bf3fe6bc7687bf3cd20b75f9d753ec124c0e74fbd5a1aa9`. Not a signature audit |

### Failures Investigated

- UI-01/02 exposed a native menu picker's sub-44-point target and shared-fixture interference: Home recommendation requests consumed the scripted radio failures/results. Pickers use the existing SettingsMenuRow, and seed-radio requests use a separate injected fixture provider. No production provider behavior was changed to satisfy the fixture.
- UI-03 had three passes and one Tune failure. A sheet attached to a lazy section lost its presenter during layout. Tune presentation moved to the owning screen/Queue root. UI-04 then exposed the native Cancel target shrinking below 44 points in the nested sheet; the plain 46-point label and hidden automatic toolbar background fixed it. UI-05 passed the light/dark workflow, and UI-06 passed it again after the remaining integration fixes.
- Visual inspection of SE/iPad captures caught Cancel wrapping even though its hit target passed. A fixed-size text label inside a 70-point minimum width corrected it; both targeted toolbar reruns passed and their screenshots were inspected.
- Static review found five correctness issues: unavailable library epochs erasing valid radio history; saved tuning filtering away the explicit seed on restart; Tune clearing the stopped-session retry action; stale recording-language evidence; unbounded accumulation of past generated entries. Each was corrected and covered by the Core-02 tests. Manual queue duplicates are protected by occurrence identity, not song ID.
- Thirteen obsolete mood/setup UI cases were retired with the removed product path. Their applicable cancellation, retry, continuity and tuning scenarios are covered by the seed-radio workflows; era/mood-grid assertions have no current equivalent. Legacy engine/model tests remain. Other Search tests were retained and exercised in UI-06.

### Remaining Acceptance

Native UI/audio workflows use isolated libraries, fake catalog responses and local audio. They establish interaction, queue, persistence and recovery behavior, not real-provider musical relevance, physical-device sound or first-audio latency. Long-session recommendation quality, poor-network/background playback and physical VoiceOver remain open in ROADMAP. The generated-history cap protects manually queued, current, upcoming and never-selected entries; it is not a total queue-size cap. No full-app green suite is claimed for this round.

## R20 Follow-Up: Responsiveness, Live Radio, Settings Search and Instant Downloads

Same source build **1.0.0 (10)**, local and uncommitted; nothing uploaded. Receipts are under `artifacts/R20/`. Design and measurements live in [SCROLLING_PERFORMANCE.md](SCROLLING_PERFORMANCE.md), [LIVE_RADIO.md](LIVE_RADIO.md), [SETTINGS.md](SETTINGS.md) and [BACKGROUND_DOWNLOADS.md](BACKGROUND_DOWNLOADS.md).

| Receipt | Result and scope |
| --- | --- |
| `Perf-Base-02`, `Perf-Final-01` | `GanaBajanaResponsivenessUITests` idle and during playback on an optimized (`-O`, whole-module) Debug build; before/after table in SCROLLING_PERFORMANCE. Simulator evidence only. Raw profiling traces and exported profile XML were pruned with owner approval; logs, test bundles and documented summaries remain |
| `Perf-Focus-02`…`06` | Liked Songs fling A/B: 1–2 hitches per 8.3 s pass with the artwork body lookup removed, 74–79 with it |
| `Radio-Audit-02` | Opt-in public audit: 256 of 275 sampled landing, NPR and India stations reach `readyToPlay`; 17 fail the stream probe and 2 time out during native validation. Browser health checks hide failed probes; stations that pass the probe but fail native validation can still be listed |
| `Fix-Unit-04` | Whole unit target except native StoreKit: **2,672 passed, 1 failed, 45 skipped**. The failure (`PlaybackControllerTests.testResolvedViewCountFollowsTheInstalledStreamAndResetsOnTrackChange`, `CancellationError`) passed alone in `Fix-Flake-01` (one executed test) |
| `Fix-Unit-02`, `Fix-Unit-03` | Radio, downloads, Settings search and recovery classes; `BackgroundDownloadsTests` **39 passed** including the new transient-retry, permanent-failure, join-the-playing-copy and reuse-the-player-link cases |
| `Fix-UI-02` | **9 passed**: Settings search (every result opens its row; keywords, empty state, clearing, light and dark), R18 workflows (including Live Radio), R20 workflow, the disabled download button |
| `Fix-UI-01` (runner timeout at 3,500 s under load) | 29 of 30 completed cases passed across Downloads, PlayerDownload, SettingsLayout, SettingsOrganization and SettingsPages; the failure was a stale lowercase expectation for "Download Unavailable", corrected and passed in `Fix-UI-02` |
| `Fix-UI-SE-02`, `Fix-UI-IPad-02` | Settings search everyday-word workflow on iPhone SE and iPad Pro 13, light and dark |
| `Fix-Build-06`, `Fix-UI-03` | Build-for-testing passed; **1 UI test passed**, exercising the YouTube Changes workflow in light and dark. Player More has exactly one Done button, supplied by its parent sheet; Settings retains its own Done and dismissal behavior. Uses the fake account client |
| `Release-02`, `release-inspection.json` | Unsigned device Release build: build 10, no DEBUG fixture markers or test resources, SHA256 `c390e3e3431fc20a6ec89be691fd616d276af08f169d476bc8fec892790ec385`. Not a signature audit |

Corrections found on the way:

- An optimized build crashed in `ArtworkLoader.image` (`swift_task_checkIsolated`, then heap corruption in `Set.insert`): actor state was written after resuming from a continuation. The image is now cached in `finish` before waiters resume. Debug builds never showed it.
- `AppModelLibraryRecoveryTests` left a player callback asserting against its deleted file; later timer checkpoints reported failures inside unrelated tests. The callback is restored before the test's assertions.
- `TipJarStoreKitTests` could wait forever on the real Apple Account sheet when `SKTestSession` failed to take over (`SKInternalErrorDomain Code=3` for every session setter after the simulator reboot). Purchases now have a 30-second deadline, so the run reports `timedOut` instead of hanging. The session failure itself is environmental and not fixed; native StoreKit remains excluded from the unit-target receipt, as in earlier rounds.

Not verified: physical-device frame timing, live background downloads against real googlevideo after an immediate Play, and the radio health check on cellular.

`Release-02` predates the duplicate-Done fix; `Fix-Build-06` and `Fix-UI-03` cover that final UI change.

## R20: Super Likes on Companions, Extras and Overnight Mixes

Source **1.0.0 (10)** carries the three follow-ups the owner asked to track after R19: companion wire version 2 (`isSuperLiked`, `setSuperLiked`) with the Watch three-state heart and the fourth CarPlay Now Playing button, the Super Liked Home shelf, Storage row and row badge, and `MixRefreshRegistration` for overnight mix regeneration. No commit, push, archive, signing, Apple validation or upload was performed; build 6 remains the delivered build. Receipts are under `artifacts/R20/`; `run.py` there is the R19 runner with the R20 directory and `R20_*` overrides. Counts describe separate runs with overlapping coverage, not an additive total.

### Executed Checks

| Receipt | Result and Scope |
| --- | --- |
| `Build-02.xcresult`, `Build-04.xcresult` | Debug app build and build-for-testing passed; `Build-04` is the final source |
| `Core-01.xcresult` | **226 passed, 1 failed**: companion protocol and controller, CarPlay template/session/integration/navigation/scene, Watch phone session, publication, lease, mutation, snapshot and request client, mix and release refresh registration, Home customization, `SuperLikeExtrasTests`, model mixes, super-like library, R19 integration, TrackRow accessibility and widget navigation. The failure was an audio timing flake (below) |
| `Flake-01.xcresult` | `CarPlayPlaybackIntegrationTests` rerun **3 passed** |
| `Watch-Unit-01/watch-unit.xcresult` | `tools/verify.sh watch-unit` on Watch SE 3 40 mm: **34 passed** including the new super-like model case |
| `Watch-UI-01/watch-ui.xcresult` | `tools/verify.sh watch-ui`: **7 passed, 2 skipped** (the opt-in real-connectivity and screenshot suites), including `testFavoriteHoldPromotesToSuperLikeAndTapRemovesIt` |
| `UI-01.xcresult` | **10 passed**: `GanaBajanaR20UITests` (shelf, see all onto the Super Liked chip, row badge, Storage count, hide and show in Customize Home, light and dark) plus the Home customization and Settings organization suites with the seventh section |
| `UI-03.xcresult`, `UI-04.xcresult` | **2 passed** and **11 passed**: the five R19 workflows and the whole Library organisation suite on the R20 source |
| `UI-SE-01.xcresult`, `UI-IPad-01.xcresult` | **1 passed** each: the R20 workflow on iPhone SE (3rd generation) and iPad Pro 13, light and dark |
| `Release-01.xcresult`, `release-inspection.json` | Unsigned `generic/platform=iOS` Release build passed; build 10, both device families, no DEBUG fixture markers, no test resources, API credential excluded from companions, no broad ATS exception. Executable SHA256 `42099476b441dc55b739145eb0c26c210ae9debe29395fa4b062b084f6f65dcd`. Not a signature or archive audit |

### Failures and Corrections

- `Core-01`: `CarPlayPlaybackIntegrationTests.testLibraryWriteFailureDuringPlaybackNeverOffersAPlaybackRetryOrRestartsAudio` read `MPNowPlayingInfoPropertyPlaybackRate` as 0 once while real audio was still settling; the class rerun passed. No code changed.
- `UI-02` (log kept as `UI-02-interrupted.log`, bundle discarded) ran straight after the Watch suites and hit a degraded simulator: accessibility queries stalled for about 1,000 seconds, one Downloads test passed in 1,905 seconds instead of 69, two Library organisation tests failed on ordinary 10-second waits, and app termination took 973 seconds. The shell timeout ended the run. Both failed tests passed in `UI-03` in 59 and 15 seconds, and the whole class passed again in `UI-04`; the earlier run is not evidence of a defect.
- Two existing UI tests hid the six original Home sections by name and expected the customized-empty state; they now include `superLiked` (`GanaBajanaHomeCustomizationUITests`, `GanaBajanaSettingsOrganizationUITests`). `WatchRequestClientTests.testInvalidVersionNeverReachesTransport` used version 2 as its invalid version; it now uses version 1.
- Worker review found two R20 gaps before the runs: `WatchPhoneSession.sameSemantics` ignored `isSuperLiked`, so a promotion alone would have been throttled as a position-only update, and `CompanionPlaybackController.perform` skipped the no-track and identifier checks for `setSuperLiked`. Both were corrected and are covered by the controller and publication tests.
- Policy note, not a defect: CarPlay's Remove favorite recheck compares `isFavorite` only, so it removes both tiers when the phone promoted the song between the snapshot and the tap; the Watch's `WatchActionPolicy` rejects any tier change for both heart actions. Both behaviours are documented in [CARPLAY.md](CARPLAY.md) and [WATCH.md](WATCH.md).

### Limits

Not verified: a physical Watch and CarPlay head unit (the Watch fixture and the phone-side CarPlay template tests stand in), the BGAppRefreshTask actually running overnight on a device (iOS decides; the handler, expiration and rescheduling are unit tested with an injected registrar and submitter), audible haptics, and VoiceOver with the new Watch custom actions. The two pre-existing `GanaBajanaRefinementUITests` Home-carousel failures recorded under R19 remain open.

## R19: Super Likes and Motion Polish

Source **1.0.0 (9)** contains Super Likes ([SUPER_LIKES.md](SUPER_LIKES.md)) and the motion polish for the play button, heart, current-song badge and filter chips. No commit, push, archive, signing, Apple validation or upload was performed; build 6 remains the delivered TestFlight/App Store Connect build. Receipts are under `artifacts/R19/`; `run.py` there is the R18 runner with the R19 directory and `R19_*` overrides. Counts describe separate runs with overlapping coverage, not an additive unique-test total.

### Executed Checks

| Receipt | Result and Scope |
| --- | --- |
| `Build-04` to `Build-11.xcresult` | Debug build-for-testing passed after each integration and test correction; `Build-11` is the final polished source |
| `Core-01.xcresult` | **169 passed, 0 failed/skipped**: the new `SuperLikeLibraryTests`, `SuperLikeSyncTests`, `SuperLikeRecommendationTests`, `SuperLikeDownloadsTests` and `R19IntegrationTests` with the closest existing persistence, sync, playlist, taste, mix, downloads, import, lifetime and recovery suites |
| `Regression-A.xcresult` | **1,377 passed, 1 failed, 2 skipped** over the first 123 of 247 unit classes (every class except Live, Benchmark and StoreKit). The failure was pre-existing and unrelated (below) |
| `Regression-B.xcresult` | **1,163 passed, 1 failed, 1 skipped** over the remaining 124 classes. The failure was pre-existing and unrelated (below) |
| `Flake-02.xcresult`, `Flake-03.xcresult` | The two corrected classes rerun green: `DailyMixClusteringTests` (all) and `ListeningProjectionCacheTests` (11) |
| `UI-01.xcresult` | **5 passed**: the five R19 phone workflows in light and dark on the pre-polish source |
| `UI-Existing-01.xcresult` | **19 passed, 3 failed** (Downloads, Library organisation, Settings layout, Player More). Two failures were stale R18-era expectations, one a lazy-row assertion after the taller chip block (below) |
| `UI-Existing-03.xcresult` | **19 passed, 1 failed**: the same suites plus two R19 workflows after the first corrections; the remaining failure was a stale R17-era Settings inventory (below) |
| `UI-02.xcresult` | **15 passed, 0 failed** on the polished source: the five R19 workflows, the Settings rhythm test, `GanaBajanaPlayerShellUITests`, `GanaBajanaPlayerGesturesUITests` and `GanaBajanaPlayerProgressBarUITests` |
| `UI-SE-01.xcresult` | **5 passed**: the five R19 workflows on iPhone SE (3rd generation), light and dark |
| `UI-IPad-01.xcresult` | **5 passed**: the five R19 workflows on iPad Pro 13, light and dark |
| `UI-Existing-04.xcresult` | **26 passed, 8 failed**: Downloads, Library organisation and Player More suites green on the polished source; all eight failures were pre-existing `GanaBajanaRefinementUITests` expectations (below) |
| `UI-Existing-05.xcresult`, `UI-Existing-06.xcresult` | Refinement suite after corrections: **15 passed, 4 failed**, then the two Recently Played tests **2 passed**. Two Home-carousel expectations remain failing and unrelated (below) |
| `UI-Existing-08.xcresult` | **6 passed**: the full `GanaBajanaR17UITests` (downloads filters, Not Liked, Moment Mixes, TV lyrics, lifetime) and the R18 account workflow that drives Player More |
| `Release-01.xcresult`, `release-inspection.json` | Unsigned `generic/platform=iOS` Release build passed; build 9, both device families, no DEBUG fixture markers (including `--r19-fixture`, `DebugR19Fixture`), no test resources, API credential excluded from companions, no broad ATS exception. Executable SHA256 `bbdfddb3a78ed0ac3aef5e092d2c5c47ba84749915908bf9d5a6e58ae460054c`. Not a signature or archive audit |

The five R19 workflows (heart tap/hold, menu and More rows, Liked Songs chip/swipe/empty state, download scope and Downloads filter, tip after the first like) therefore have passing phone, SE and iPad coverage in both appearances. The fixture (`--uitesting --seed-ui --r19-fixture`, optional `--player`, `--show-tips`) uses isolated storage, staged local AAC and a local resolver; no network, real account or real TipKit datastore is touched.

### Failures and Corrections

- Regression-A: `DailyMixClusteringTests.testWidgetSnapshotCarriesDiscoverWeeklyAndThreeDailyMixes` compared a snapshot stamped with a live `Date()` against its millisecond round trip through `WidgetSnapshotStore`; the test now passes `Fixtures.now`. Pre-existing, unrelated to R19.
- Regression-B: `ListeningProjectionCacheTests.testReloadSameCountSameTotalAndSameLastSessionInvalidatesBothProfiles` replaced a saved session's track on disk without rebuilding its lifetime receipt, which the R17 receipt identity rule rejects; the helper now rebuilds `lifetimeListening` from the edited events beside the reseeded journal. Pre-existing since R17.
- `GanaBajanaDownloadsUITests`: the three Download Liked Songs tests drive the new menu row (`expectLikedDownloads`/`chooseLikedDownloads` helpers, All Liked keeps the All and Super Liked chips), and the export detail expectation moved from the R12 "tags included" copy to R18's "Song details included". `GanaBajanaSettingsLayoutUITests`: the inventory gained the R18 YouTube Changes and Extractor Updates rows, the R17 Moment Mixes row and the menu type for the downloads row. `GanaBajanaLibraryOrganisationUITests`: chips read All, Super Liked, Downloaded, On This Device and lazy rows are revealed before assertion.
- The four Liked Songs chips no longer fit one row on a phone; `ViewThatFits` had stacked them one per row (176 points) and pushed the third row below the fold. `ChipFlowLayout` now wraps chips onto as few rows as needed; accessibility sizes still stack.
- `GanaBajanaRefinementUITests`: the fourth tab has read Stats since R13 (`tab.recap` identity retained), the sleep-timer cancel row is `player.sleepTimer.cancel` ("Cancel Sleep Timer"), and the Home heading is "Recently Played"; six of eight failures were these labels. `testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabs` and its largest-text twin still fail on the Home discovery carousel card (`track.card.<id>` lower edge above the mini player); they predate R19, touch no R19 surface and remain open.
- Interrupted runs (`UI-Existing-02`, `UI-Existing-07`) were restarted as `UI-Existing-03` and `UI-Existing-08`; their partial bundles were removed and are not evidence.
- Independent worker review of each scope reported no production defect; one note records that promoting an already liked song keeps the saved Track metadata (consistent with `toggleFavorite`).

### Metrics, Visual Evidence and Limits

Bounded OSLog only: `super_like action=promote/demote/remove surface=player/menu/more/library`, `download_auto_super_like count=N`, `mix_super_like scope=seeds/daily reserved=0/1 eligible=N`. Emission is not asserted by tests; the library, download and mix effects they gate on are. `phone-captures/manifest.json` holds the UI-02 screenshots: heart outline/liked/super liked in both appearances, the anchored "Hold to Super Like" tip and its dismissal, Liked Songs chips with the wrapped fourth chip, the Super Liked filter and empty state, the Download Liked Songs menu and confirmation, and the Downloads Super Liked filter.

Not verified: audible haptics, the loading arc and morph on a physical device (simulator captures cannot show the transient loading state), the spark burst frame pacing on the slowest supported phone, VoiceOver with the new custom actions, TipKit persistence across reinstall, real Watch/CarPlay behaviour (unchanged Bool wire), live YouTube import against a super liked song, and two-device iCloud convergence of the new register on real hardware. The pre-existing Refinement Home-carousel failures above remain open.

## R18: Public Radio, Gain-Up, Account Changes, Extractor Updates and Export Fixes

Source **1.0.0 (8)** contains the integrated R18 changes. The documentation task was restarted after interruption, with partial edits preserved. No commit, push, build upload or real YouTube account mutation was performed. Build 6 remains the delivered TestFlight/App Store Connect build.

### Executed Checks

Receipts are under `artifacts/R18/` unless noted. Counts describe separate runs with overlapping coverage, not an additive unique-test total.

| Receipt | Result and Scope |
| --- | --- |
| `Build-15.xcresult` | Final Debug build-for-testing passed, including app/companion and test targets |
| `Core-02.xcresult` | **182 passed, 0 failed/skipped**. Export/native cover/share callbacks, gain-up and limiting, directory/favorites/live mode, account permission/transport/receipts, updater integrity/recovery/generation fences, persisted playback provenance and model integration |
| `Regression-01.xcresult` | **243 passed, 0 failed/skipped**. Existing playback, asynchronous listening/privacy, queue/standby/cache, resolver/fast-start, EQ, background downloads, R17 integration, AirPlay routing and YouTube import |
| `Live-Radio-03.xcresult` | **41 passed, 0 failed/skipped**, including two explicitly enabled public-network KCRW tests. Directory-to-shared-player and fixed-station checks reached native playback and advancing playhead; elementary-frame/native-validation regressions also passed |
| Vendor `ExtractorCompatibilityTests` | **6 passed** with `swift test --package-path Vendor/YouTubeKit --scratch-path artifacts/YouTubeKitReview --filter ExtractorCompatibilityTests`. Tests exercise actual signature/visitor/timestamp rule consumers and stale-generation behavior; no live player repair is claimed |
| `UI-01.xcresult` | **2 passed, 3 failed**. Radio and cached fallback-provider workflows passed in light/dark; account playback/cancel, Back target and extractor lookup issues were corrected later |
| `UI-02.xcresult` | **2 passed, 1 failed**. Export with verified cover/system sharing and extractor activation/rollback passed in both appearances; account cancellation test still assumed a Cancel button |
| `UI-Account-05.xcresult` | **1 passed**. Phone light/dark opt-in, cancel-before-submit, fake confirmed Like and unchanged local heart |
| `UI-SE-01.xcresult` | **4 passed, 2 failed**. Account, export, provenance and R17 Not Liked regression passed in both appearances; directory/candidate rows needed explicit small-screen scrolling |
| `UI-SE-02.xcresult` | **2 passed**. Directory/live surfaces/favorites/restoration and normalization/extractor workflows in both appearances |
| `UI-IPad-01.xcresult` | **4 passed, 1 failed**. All workflows except account cancellation passed in both appearances; iPad exposed multiple dismissal regions |
| `UI-IPad-Account-02.xcresult` | **1 passed**. Account workflow in both appearances after scoping the popup dismissal checks |
| `Release-01.xcresult` | Unsigned Release device build passed for `generic/platform=iOS` |
| `release-inspection.json` | Build/version/device-family checks passed; R18 and other DEBUG markers/test resources absent, API credentials absent from companions, no broad ATS exception. Signature validation was not performed |

The five R18 UI workflows therefore have passing phone, SE and iPad coverage across these receipts. This is not one all-green full-app run. New fixture providers use isolated data, synthetic cookies and a fake account-write client. The radio fixture deliberately exercises rejection of a local file as a public station stream; positive public playback evidence comes from Live-Radio-03 instead.

### Failures and Corrections

- Initial builds found UIKit protocol actor isolation, Core Media attachment constants and optional closure Sendable inference issues. The export activity source now has immutable Sendable state and supports UIKit callbacks on background queues. Core-01 recorded **165 passes and 9 failures**, including those callback crashes, favorite first-write failure and a standby-test path mismatch; Core-02 supersedes that run.
- Native export verification separates media-bearing intervals from the asset timeline, handles nonzero timestamps and valid empty/trim markers, and retains payload/duration/tag/cover checks. A synthetic two-cut AAC composition could not be generated by AVFoundation on this runtime; supported native writer fixtures plus independent interval/marker assertions replace that generator. It was not treated as a production-file failure.
- Known artwork URLs must resolve to valid image bytes or export reports the artwork stage. Native tests read the actual JPEG back from M4A and compare the share preview with those bytes. The source remains leased through native work and sharing. The owner's exact failing song assets and receiving app were not supplied; universal recipient cover rendering is not established.
- Radio favorites now distinguish precise missing-file errors from corruption/permissions and retain atomic baseline checks. HLS validation parses relevant attributes rather than rejecting video-codec text embedded in a key URI.
- Live-Radio-01 and Live-Radio-02 rejected KCRW despite successful MP3 probing/native playability because a continuous stream's static asset audio-track list was empty, including after item readiness. The validated elementary-stream path requires two complete consecutive MP3/ADTS frames and URL-bound proof; native playability and video exclusion still apply. Live-Radio-03 passed. HLS with empty native audio tracks remains outside this exception.
- The normalization/standby test initially used manual Next from Crossfade zero, which requests fresh resolution. It now exercises the intended gapless handoff, checking the exact adopted player/item and two resolver requests. No timeout was increased.
- The More Back control now owns a 46-point target outside automatic toolbar glass. UI assertions correctly preserve paused Next intent, address merged LabeledContent labels and reveal lazy rows before asserting their content.
- Account confirmation cancellation uses a stable inert point outside the native popover when UIKit omits Cancel. The account action had already succeeded in UI-Account-04; its visible receipt was misclassified by a helper that used the scroll indicator's inset as a clipping boundary. The helper now retains actual viewport/navigation/keyboard/overlay bounds. The iPad test scopes dismissal to the confirmation instead of assuming one application-wide dismissal region. Native mutation guards were not weakened.
- Vendor test compilation encountered obsolete enclosing-suite availability annotations rejected by Swift Testing. Test-only annotations were removed without dropping cases or assertions; the filtered compatibility suite then passed.
- Independent static integration review reported no actionable issue. This is source review, not additional executed coverage.

### Metrics, Visual Evidence and Limits

Feature contracts own bounded metrics and unit-versus-integration mappings: [radio](LIVE_RADIO.md), [normalization](VOLUME_NORMALISATION.md), [account writes](ACCOUNT_WRITEBACK.md), [extractor updates](EXTRACTOR_UPDATES.md), [provenance](AUDIO_QUALITY.md) and [exports](AUDIO_EXPORT.md). No remote telemetry was added. Export failures identify a bounded stage/reason; account transport reports confirmation or uncertainty without retrying mutations; radio and updater diagnostics omit private identifiers. Test-only public station diagnostics identify the tested broadcaster.

`phone-captures/manifest.json` and `ipad-captures/manifest.json` retain workflow screenshots. Visual inspection covered phone/iPad export details with cover evidence, cached `via JioSaavn` provenance and the extractor provisional/rollback controls. Earlier failure images retain their original provenance.

Real-account write acceptance, hardware gain/listening and prolonged radio/AirPlay behavior, broader broadcasters/HLS, actual Files-picker interaction, extreme accessibility sizes and the user's receiving-app cover display remain unverified. Updater Files staging/validation/trust/rollback is exercised; no publisher key/feed is configured, so no automatic upstream service exists. Supported declarative repairs do not cover every future extractor change. No R18 signing/archive/export/upload was performed. App-owned simulator runs finished with approximately 81 GiB free; signed historical deliveries remain intact.

## R17: Moments, Downloads, Lifetime Stats and Lyric Choices

Local source is **1.0.0 (7)** over the existing uncommitted work. The requested features and the additional Not Liked download filter are integrated. No build-7 upload or Git write was performed; delivered build-6 inputs and receipts remain frozen.

The owner reports constant physical-device testing and actual TV AirPlay audio working great. This is owner-reported acceptance of the existing audio route, not evidence for the new TV lyrics display, motion permission or OS background-download behavior.

### Executed Checks

All bundles and command logs below are under `artifacts/R17/`. Counts are per attempt, not additive unique coverage.

| Receipt | Result and Scope |
| --- | --- |
| `Build-11.xcresult` | Final Debug build-for-testing passed, including app, companions and test targets |
| `Core-03.xcresult` | **216 passed, 0 failed, 0 skipped**. Moment learning/storage/detached preparation, lifetime migration and replica deduplication, AAC export, background transfer boundaries/readers, lyric variants/metadata, TV timeline/lifecycle and initial model integration |
| `Regression-01.xcresult` | **371 passed, 0 failed, 1 skipped**. Library/schema/journal/privacy/recovery, lyrics/provider regressions, audio routing and 10,000-session benchmark. The existing live JioSaavn test requires `GANABAJANA_SAAVN_LIVE=1` and was not enabled |
| `Integration-03.xcresult` | **10 passed**. Final model lyric/TV selection, stale results, saved language corrections including Unclassified, privacy/sign-out, durable moment learning, lifetime retained-detail split and valid fixture audio/relaunch |
| `UI-01.xcresult` | **3 passed, 4 failed**. All three optional-onboarding scenarios passed. Initial R17 UI failures were corrected in later receipts |
| `UI-02.xcresult` | **3 passed, 2 failed**. Lyrics/TV script switching, real AAC export/system sharing and live Not Liked membership passed in both appearances; Stats/Moment navigation issues corrected below |
| `UI-03.xcresult` | **1 passed, 1 failed**. Lifetime totals, retained rankings and Stats Card/system sharing passed in both appearances; Moment flow exposed a missing shared Done control |
| `UI-Moments-04.xcresult` | **1 passed**. Learned card, per-mix persistence through relaunch, playback, learning reset and settings dismissal in both appearances |
| `UI-SE-01.xcresult` | **5 passed** on SE 3. All five R17 workflows, each in light and dark appearance, including 44-point controls |
| `UI-IPad-01.xcresult` | **5 passed** on iPad Pro 13. The same five workflows in both appearances; scene-geometry opt-in enabled |
| `Release-01.xcresult` | Unsigned Release device build passed for `generic/platform=iOS` |
| `release-inspection.json` | Version/build, phone/iPad families, motion usage string, external-display and retained CarPlay roles checked. Release fixture markers/test resources absent; API configuration absent from companion bundles. This is not a signature/archive audit |

### Corrections Established During Execution

- Initial builds caught explicit-self logging, an async test thread check, callback arity and app-delegate initialization ordering. `Core-01` inadvertently executed the older pre-R17 test binary after the first failed build; its 28 passes are **not R17 evidence**. The guarded runner chains successful compilation before tests.
- `Core-02` had 185 passes and 11 failures. Native inspection could reject valid WAV/AAC stored under `.part` or a misleading extension. Format hints now come from validated delivery/header evidence; codec, duration and decoded-audio checks remain. AAC packet assertions skip only zero-sample markers and still compare bytes, packet samples and digest.
- Moment startup accepts precise missing-file errors while preserving permission/corruption failures. Large history selection moved off-main; revision/privacy fences protect its bounded result.
- A fixture compared equivalent directory URLs with different trailing-slash representations. Path identity fixes retained actual codec/metadata/tier checks. `Integration-01` and `Fixture-01` failures are superseded by `Integration-02` and `Integration-03`.
- UI corrections retained assertions: localized pixel counts, native accessibility wrappers, scoped Stats-sheet scrolling and fixture preparation. The mix Play control moved outside the navigation-link label to expose its real 44-point target. Moment settings reuse the existing page chrome and Done action.
- Independent static integration review found saved language corrections were bypassed by lyric script preference. Overrides now precede provider metadata, including `und`, and edits during lookup retire stale results. Two regression cases passed in `Integration-03`.

### Metrics and Coverage

Feature documents own event names and bounded dimensions: [Moments](MOMENT_MIXES.md#metrics), [background downloads](BACKGROUND_DOWNLOADS.md#metrics-and-coverage), [lifetime totals](LIFETIME_STATISTICS.md#metrics), [lyric choices](LYRICS_VARIANTS.md#metrics), [TV lyrics](TV_LYRICS.md#bounds-and-metrics) and [export](AUDIO_EXPORT.md). No remote telemetry was added. Unit/component tests cover persistence, retry/cancellation, privacy and native local files; UI tests cover displayed state, navigation and system-share presentation. They do not intercept every OSLog emission or replace physical lifecycle acceptance.

The 10,000-session benchmark measured async submission at **0.54–0.73 ms**, main-actor capture/apply at **5.9–13.1 ms**, and total wall time at **2.82–3.47 s**. Thirty profile reads took **84.2 ms** including the cache miss; preferences were not invalidated. Synchronous compatibility callbacks took **2.41–2.95 s**. These are simulator measurements, not device frame rates. Lifetime validation and file encoding grow with receipt count; manual synchronous writes remain a limitation.

### Visual Evidence and Limits

`SE-captures/manifest.json` and `IPad-captures/manifest.json` map 14 retained PNGs per device to the five workflows. Visual inspection covered Not Liked, Gurmukhi picker/lyrics, Latin TV on SE/iPad, the Moment card, lifetime Stats Card and AAC export details. Fixture lyrics are original test verse, with attribution, and establish no live provider coverage.

Physical background-session suspension/wake, native motion prompts, mirrored/separate-screen TV lyrics and delay, same-build two-device lifetime convergence, extreme Dynamic Type/VoiceOver and share-recipient decoding remain unverified. Gurmukhi is offered only when a strictly matched published version exists; no transliteration is generated. Direct Genius/Musixmatch integration remains gated on supported credentials/display access. Lifetime receipts cap at 200,000, with shared journal/file limits potentially reached sooner; exhaustion rejects writes rather than inventing totals. No full-app all-green matrix or new signed delivery is claimed.

## Build 1.0.0 (6): signed delivery, 27 September 2026

The owner authorized uploading the latest build. The current source was fingerprinted before archiving; all delivery inputs still matched after upload. The coordinator reused the successful R16 targeted checks recorded below rather than claiming a new full suite or physical-device run.

| Gate | Result / evidence in `artifacts/AppStore-1.0.0-6/` |
| --- | --- |
| Preflight | Apple had processed build 5; next build 6. Exact bundle/profile UUIDs and certificate binding verified. `preflight.json`, `inputs.json` |
| Archive | Signed Release archive succeeded for the phone, widget and Watch. `Archive.xcresult`, `archive.log` |
| Release audit | Identities, device families, orientations, signatures, FFmpeg notices/exports, fixture exclusions and restricted API configuration checks passed. Added the missing `--daily-mixes-fixture` audit marker before freezing inputs. `archive-audit.json` |
| Export | App Store Connect export, pinned profiles/certificate, build number preserved. Temporary keychain removed; search list and default restored exactly. `export.log`, `signing-cleanup.json` |
| IPA inspection | 18,796,986 bytes; nested signatures, profile/entitlement identities and archive/export UUIDs match; iCloud environment Production; companion bundles exclude the API configuration. `ipa-inspection.json` |
| Apple validation | Passed. Xcode's compiled API plist is compared semantically to the source, not byte-for-byte across XML/binary representations. `apple-validation.log`, `apple-validation.json` |
| Upload and processing | `publish appstore --wait` uploaded and attached without submission. Build `e36b7e87-31d1-4ad6-b0bc-1ca428043353` is VALID / APP_STORE_ELIGIBLE. `publish.json`, `build-readback.json`, `version-readback.json` |
| Remote checksum | IPA MD5 and size match the uploaded file; SHA-256 is `084aa881949887c906eecb6469a5e6625797e02e74a71ddeb4835c32b159c5d0`. `summary.json` |
| TestFlight state | Internal READY_FOR_BETA_TESTING, external READY_FOR_BETA_SUBMISSION. Existing internal Friends group has all-build access. No group, invitation or beta submission created. `beta-detail.json`, `beta-groups.json` |

Two tooling details were checked rather than bypassed: `signing fetch` matched the Watch bundle when asked for the phone identifier prefix, so the phone profile was selected by the exact bundle resource/profile ID; Apple validation reserved a build-6 upload containing analyzer assets only, so upload proceeded only after verifying that no IPA occupied that reservation. No completed build-3/4/5 release stage or receipt was overwritten. The App Store draft remains PREPARE_FOR_SUBMISSION; external beta contact/What to Test validation and existing store review declarations remain separate from this successful delivery.

## R16: scrolling, startup promotion, Stats and compact library controls

The coordinator ran the following on the shared app simulators with one `artifacts/DerivedData` working set. Source remains `1.0.0 (6)`, uncommitted over `6c34c9e`. App Store draft description, promotional text and keywords were updated separately; no matching build has been uploaded. [APPSTORE_TESTFLIGHT.md](APPSTORE_TESTFLIGHT.md) records that distinction.

### Measurements

The Debug simulator benchmark seeds 10,000 sessions and 100 recordings. Before the fixes, 30 language-profile reads took **2,246 ms** and three synchronous listening callbacks averaged **2,192 ms each**. Those callbacks invalidated preference observers. Cached profile reads took **73 ms total for 30 reads**, including the first miss, and no longer invalidated preferences. Batching alone still left roughly two seconds of synchronous work, so it was not treated as a complete fix.

The production async checkpoint path measured **0.53–0.63 ms** to enqueue/flush and **5.1–9.0 ms** of measured main-actor capture/apply work. Total wall time remained **1,970–2,100 ms**, with preparation off-main. These are persistence/profile measurements, not device frame-rate or full end-to-end UI timing claims. [SCROLLING_PERFORMANCE.md](SCROLLING_PERFORMANCE.md) owns the implementation and remaining synchronous paths.

| Evidence under `artifacts/R16/` | Result and scope |
| --- | --- |
| `Scroll-Baseline-01.xcresult` | 1 passed; records the original synthetic work cost |
| `Scroll-Core-01.xcresult` | Compile failed on missing `try` in two new observation tests; corrected without product changes |
| `Scroll-Core-02.xcresult`, `Scroll-Core-03.xcresult` | 43 passed / 2 failed, then 12 passed. External-mutation fixtures initially changed history without updating their sync journals; fixtures were repaired, production validation retained |
| `Async-Core-01.xcresult`, `Async-Core-02.xcresult` | Initial test compilation rejected async `Thread.isMainThread` calls; synchronous diagnostic helper added. Then 65 passed: async persistence/drain, observation isolation, targeted journal, projection-cache and acknowledgement coverage |
| `Scroll-After-01.xcresult` | 8 passed; records async benchmark and presentation checks |
| `Async-Privacy-01.xcresult` | 85 passed. Includes independent-review fixes: disabled-period seconds cannot cross history enablement, and clearing history cannot falsely acknowledge a dirty paused playback snapshot |
| `Startup-01.xcresult` | 64 passed. Late foreground joins wake an expired warm-up hedge; early joins preserve its delay; cancellation respects foreground ownership. Startup timing retains automatic retries and records cumulative stages |
| `UI-01.xcresult`, `UI-02.xcresult` | 11 passed / 7 failed, then 13 passed. Corrections were scoped alert-parent queries for duplicate native AX nodes, More-sheet expansion before scrolling, one title-case expectation, and manual-stop measurement configuration. One scrolling signpost iteration returned no metric; no complete FPS/hitch claim is made |
| `UI-SE-01.xcresult`, `UI-SE-02.xcresult` | 3 passed / 1 failed, then 1 passed. Small-phone scroll test needed the existing 20-swipe navigation budget to reach collapsed history. The measured round-trip and frame-clock assertions were unchanged |
| `UI-IPad-01.xcresult` | 7 passed: Stats, Liked Songs auto-download and Settings pages |
| `UI-Visual-01.xcresult`, `UI-Liked-Final-01.xcresult` | 2 passed each. Visual inspection removed the redundant lone All chip when auto-download is enabled; confirmed pending likes stay visible and disabling restores All |
| `UI-Compact-01.xcresult`, `UI-Compact-02.xcresult` | 4 passed / 1 failed, then 4 passed. Playlist test waited for keyboard focus/draft editing before Cancel. Covers compact 44-point Play/Shuffle rows, Liked Songs durations, image-only Stats sharing with optional text, relocated playlist creation, and mix covers without duplicate titles |
| `UI-Compact-SE-01.xcresult`, `UI-Compact-IPad-01.xcresult`, `UI-Compact-IPad-02.xcresult` | SE 3 passed; iPad 2 passed / 1 failed, then 1 passed after waiting for the list destination before scrolling. Product geometry unchanged |
| `release-build-final.log` | Final unsigned generic-iOS Release build succeeded. Not an archive, release audit, device install or upload |

### Metrics and coverage

| Metric / case | Branch / scope | Placement |
| --- | --- | --- |
| `listening_projection_cache_miss` | Revision-keyed profile/summary misses, bounded kind/window and elapsed milliseconds | Unit: `ListeningProjectionCacheTests`; no hot getter-hit logging |
| `listening_checkpoint_preparation`, `listening_checkpoint_async`, `listening_checkpoint_delivery`, `listening_checkpoint_expired` | Preparation, fenced durability, bounded drains, snapshot-only recovery and expiration | Unit/native playback: `LibraryAsyncCheckpointTests`, `PlaybackAsyncCheckpointTests`, `PlaybackAsyncPrivacyBoundaryTests` |
| Slice observation and checkpoint journals | Post-durability notifications, equal-count replacements, rejected writes, one combined listening/recent mutation | `LibraryObservationTests`, `LibrarySyncCheckpointTests` |
| `playback_start` stages/attempts and hedge promotion | Retain total user-start time across automatic retries; foreground promotion after timer expiration | `StreamResolverFastStartTests`, `StreamPrefetchTests`, `PlaybackWarmerTests`, `StreamCacheTests` |
| Real scrolling with local audio | Isolated 2,000-session fixture, up/down gestures during async commits, disk readback, advancing playback, display-link starvation watchdog | `GanaBajanaScrollingPerformanceUITests`; simulator measurements only |
| Latest UI requests | Stats/title case, recommendation exclusion/undo, auto-download confirmation/persistence, filters, durations, smaller controls, sharing options, playlist heading and mix cover cleanup | MainStats, Downloads, PlayerMore, SettingsPages, CompactPlaybackSharing and DailyMixes UI suites |

All fixtures remain DEBUG-only; `--scroll-performance-fixture` and `DebugScrollPerformanceFixture` are included in the Release audit's marker inventory. New metrics use bounded categories with no recording identifiers. Successful and failed run counts above are separate attempts, not additive unique coverage. Physical-device scrolling/startup, actual TV playback, external TestFlight review, system share-destination payload rendering and the full app regression matrix remain unverified. Public radio and export-format enhancements remain queued rather than advertised as implemented.

## R15: Listening, sharing, Settings recovery and sync failures

Source remains `1.0.0 (6)`, uncommitted over `6c34c9e`. The coordinator regenerated once after parallel code-only work and ran builds/tests serially against one shared `artifacts/DerivedData`. No additional worker simulators or derived-data roots were created. These are targeted integration checks, not a full green app suite.

| Evidence under `artifacts/R15/` | Device | Result and scope |
| --- | --- | --- |
| `build-01.log` | Simulator | Interrupted at the shell timeout; no compiler error. Resumed incrementally |
| `build-02.log` through `build-04.log` | Simulator | Build-for-testing succeeded, including recovered WP26 and previously uncompiled `AirPlayRoutingTests` |
| `Core-01.xcresult` | iPhone 17 Pro / iOS 26.5 | 111 passed, 4 failed. Sync recovery/schema, settings layout/preservation, retained-history totals/charts and share cards, plus AirPlay route/session/deck checks. Failures were new model-test fixtures comparing bytes before an unrelated empty playback queue normalized on reload |
| `Core-02.xcresult` | iPhone 17 Pro | 32 passed. Fixtures seed a stable empty playback snapshot before byte baselines; byte/revision assertions remain. Stored Random survives launch/reload/remote merges; new/missing fields use Fewer repeats |
| `Sync-Regression-01.xcresult` | iPhone 17 Pro | 70 passed. Persistence, transport, typed search, checkpoints, playback, history reset and merge regression suites |
| `UI-Pro-01.xcresult` | iPhone 17 Pro | 16 passed, 1 failed. Settings pages/Following, status stability, Listening periods/All Time, compact Library, collapsed history and preview-first sharing. Failed check assumed AX container spacing equals the VStack padding; replaced with explicit ordering/non-overlap and a gap smaller than a section row |
| `UI-Pro-02.xcresult` | iPhone 17 Pro | 12 passed, 1 failed. Collapsed-history correction passed; Settings rhythm, player timer persistence, artist navigation and download-tier storage navigation passed. Player Download test exposed a medium-detent test-helper scroll problem |
| `UI-Pro-03.xcresult` | iPhone 17 Pro | 9 passed. Download helper explicitly expands More before scrolling; includes Settings organization and listening-control regressions |
| `UI-SE-01.xcresult` | iPhone SE 3 / iOS 26.5 | 9 passed. Settings pages/Following, footer rhythm/status stability, All Time preview and unified song sharing |
| `UI-IPad-01.xcresult` | iPad Pro 13 / iOS 26.5 | 8 passed. Same Settings checks and All Time. The WP26 Following test uses `tab.library` rather than requiring a phone TabBar |
| `release-build-01.log` | Generic iOS | Unsigned Release build succeeded. This was a build, not an archive, install, upload or release audit |

The UI commands enable `TEST_RUNNER_GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1`. Screenshots exported under `captures-pro/` were visually inspected: Listening title and four period choices, stat tile, single-preview sharing for Listening and songs, and retained artwork placeholders in network-free fixtures. The repeated tests above are not added together as unique coverage.

### Metrics

| Metric / event | Emitted when | Bounded dimensions | Why |
| --- | --- | --- | --- |
| `LibrarySync` `sync_started`, `sync_failed`, `sync_retry_scheduled`, `sync_succeeded`, `sync_finished`, `sync_timeout` | Automatic/manual attempts, retry scheduling and completion | Trigger/failure enums; retries, durations and notification flags are values | Separate expected stale preparation, transient outages and sustained actionable errors |
| Existing sharing and Library navigation events | Card render and navigation | Existing result/appearance values | No new telemetry or identifying fields for the UI revisions |

### Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Local checkpoint during remote preparation | Reject stale preparation before a library-error popup; retry from fresh state | Unit, `LibrarySyncFailureRecoveryTests` |
| Transient/sustained failure, success, manual retry and account cancellation | Bounded retries, cooldown, notification deduplication and recovery | Unit, sync recovery/controller suites |
| Historical shuffle tombstones and explicit Random | Preserve old journal meaning and explicit saved choices across merge/reload | Unit, schema compatibility, model and Settings preservation suites |
| All Time | Includes valid surviving sessions outside the year window; bounded calendar buckets and truthful coverage text | Unit, `ListeningAvailableHistoryTests`; UI, RecapReview |
| Settings recovery | Six pages, nested Back, Following, Done, footer rhythm and stable sync status | UI integration on phone, SE and iPad |
| Preview-first sharing and collapsed history | One main Share action; preview owns system sharing; Recent last/expandable with playback controls | UI integration plus card-rendering unit tests |
| Cached audio management | Library management row absent; Settings storage path still reaches playable cached songs | UI integration, LibraryEntries/DownloadTier/PlayerDownload |

Remaining limits: actual device sync-error text/logs were unavailable, so the user's exact incident is not confirmed. No real iCloud account outage/convergence test, TV receiver test, external-display lyric prototype, Messages preview acceptance, full unit/UI run, or physical-device run was performed here. Existing unrelated R14 Home scrolling failures remain in the broader verification backlog. Standard audio-AirPlay offers no documented lyric/color control; see [Apple's Now Playing documentation](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter.md).

## R12 and R13: local-only feature rounds

Source is **1.0.0 (6)**, uncommitted over checkpoint `6c34c9e` (R3 to R11). The owner chose local-only distribution on 25 September 2026 ([ROADMAP.md](ROADMAP.md)), so this section records feature evidence, not a release candidate. Each work package ran on its own dedicated iPhone 17 Pro / iOS 26.5 simulator with package-owned derived data; WP1 and WP13 also used the iPhone SE 3 and iPad Pro 13 simulators. Result bundles live under `artifacts/R12/` and `artifacts/R13/` with `WP<n>-<label>-<nn>` names. The per-feature documents own the case-by-case Metrics and Test coverage tables and the counts quoted below; a bundle whose counts the documents do not state is listed with a pointer only. WP12b performs the full unit and UI matrix on all three simulators after integration; nothing here is a full green suite.

| Package and bundles | Device | Result and scope |
| --- | --- | --- |
| `R12/WP0-Unit-01`, `WP0-UnitRegression-02`, `WP0-UI-01` | iPhone 17 Pro | Player files split into `Sources/Views/Player/`; R12 preferences and `MusicSource` pre-declared. Counts are not recorded in a feature document; see [ROADMAP.md](ROADMAP.md) (R12 WP0) |
| `R12/WP1-Unit-01`, `WP1-Shell-01`, `WP1-Shell-02`, `WP1-Pro-A-01` to `WP1-Pro-D-01`, `WP1-Pro-Final-01`, `WP1-SE-01`, `WP1-iPad-01` | iPhone 17 Pro, iPhone SE 3, iPad Pro 13 | R12 player shell: larger artwork, heading one line lower, artist line opens the chooser, AirPlay leading and Lyrics/Queue trailing, right time label with tap-to-switch (`GanaBajanaPlayerShellUITests`). The R13 revision below supersedes the heading and bar geometry; see [PLAYER_SHELL.md](PLAYER_SHELL.md) for the measured frames and cases |
| `R12/WP2-Unit-01`, `WP2-UnitVariantB-02`, `WP2-Unit-04`, `WP2-TrailPro-03`, `WP2-TrailPro-05`, `WP2-TrailSE-06`, `WP2-HeartTaps-07` | iPhone 17 Pro, iPhone SE 3 | R12 liked heart on the progress-to-heart trail (solid fill, accent trace). Superseded by R13 item 6: the trail, `PlayerProgressTrailTests` and `GanaBajanaPlayerProgressTrailUITests` were removed, so these bundles record retired behaviour; see [PLAYER_HEART.md](PLAYER_HEART.md) |
| `R12/WP4-Unit-01`, `WP4-UI-01` to `WP4-UI-05`, `WP4-UI-07` | iPhone 17 Pro | Song details: `SongDetailsParserTests`, `SongDetailsMergingTests`, `SongDetailsStoreTests`, `SongDetailsMusicBrainzTests`, `SongDetailsPlayerClientTests`, `SongDetailsServiceTests`, extended `YouTubeDataAPITests`; `GanaBajanaSongDetailsUITests` (More sheet to Song details, unavailable state and Retry, performer row navigation); one opt-in live InnerTube request for `7374CZQoS2Y`. Counts: see [SONG_DETAILS.md](SONG_DETAILS.md) |
| `R12/WP5-Unit-01` to `WP5-Unit-03`, `WP5-UI-01` to `WP5-UI-05`, `WP5-CheckpointBaseline-01` | iPhone 17 Pro | Downloads and export: `DownloadsTests` (12 cases), `AudioExporterTests` (6), `GanaBajanaDownloadsUITests` (3, offline cache fixture), plus the existing cache suites as regression, **214 cases, all passing**. `CheckpointBaseline-01` reproduces the checkpoint's failing `GanaBajanaCachedSongsUITests` `.slow`/`.readError` scenarios and `GanaBajanaStorageUITests.testClearingRecentSearchesPersists…`, fixed in WP14 Extra A; see [DOWNLOADS.md](DOWNLOADS.md) |
| `R12/WP6-Unit-01`, `WP6-UnitRegression-02`, `WP6-Unit-03`, `WP6-UI-01`, `WP6-UI-02` | iPhone 17 Pro | Audio quality ceiling: `AudioQualityPreferenceTests` (ranking, fast path, resolver, cache fixture, preference fan-out), `GanaBajanaAudioQualityUITests`, Settings inventory; vendored `ITagsTests.testPremiumAudioTiersAreKnownDashAudio` on the macOS host. Counts: see [AUDIO_QUALITY.md](AUDIO_QUALITY.md) |
| `R12/WP9-Unit-01` to `WP9-Unit-05`, `WP9-UI-01` to `WP9-UI-06`, `WP9-Live-01`, `WP9-Live-02` | iPhone 17 Pro | JioSaavn: `JioSaavnTests` (24 cases, 1 opt-in live `GANABAJANA_SAAVN_LIVE=1`), `CompositeCatalogTests` (11 at the time), `GanaBajanaCatalogSourcesUITests` (2); the full `GanaBajanaSearchDiscoveryUITests` class ran 19 cases with 15 passes and 4 failures later shown pre-existing (WP15 below). Live search, resolve and HEAD verified from the Mac on 25 September 2026; see [JIOSAAVN.md](JIOSAAVN.md) |
| `R13/WP7-EqualizerUnit-01` to `-03`, `WP7-EqualizerUI-01`, `-02`, `WP7-EqualizerFinal-01`, `-02`, `WP7-GaplessBaseline-01` to `-03`, `WP7-GaplessDebug-01`, `-02`, `WP7-GaplessRerun-01` to `-03`, `WP7-PlaybackRegression-01` | iPhone 17 Pro | Equalizer: `WP7-EqualizerFinal-01` **14 unit, 1 UI**; `WP7-EqualizerUI-02` the drag UI test and the Settings inventory at accessibility XXXL; `WP7-EqualizerUnit-03` `EqualizerTests` plus `PlaybackTransitionTests`, `PlaybackControllerTests` and `PlaybackAudioIntegrationTests`, **49 tests, 0 failures**. The gapless bundles measure the 0.20 to 0.40 s swap with taps on both decks (untapped under 0.15 s); see [EQUALIZER.md](EQUALIZER.md) |
| `R13/WP8-ImportUnit-02`, `WP8-ImportUnit-03`, `WP8-ImportUI-01`, `-04`, `-05`, `-06`, `WP8-ImportUIInventory-07`, `WP8-ImportUI-08` | iPhone 17 Pro | Account import: `WP8-ImportUnit-03` **63 tests, 0 failures** (21 new `YouTubeImportClientTests`/`YouTubeImporterTests` plus the existing account and playlist classes); `WP8-ImportUIInventory-07` both import UI tests and the Settings inventory at accessibility XXXL, **3 tests, 0 failures**; `WP8-ImportUI-08` the import flow with a light-appearance relaunch, **1 test, 0 failures**. `ImportUI-01/04/05` are failing iterations (lazy rows outside the accessibility tree) and `ImportUnit-02` one stub bug, both fixed before the final runs; `ImportUI-06` is not named in the feature document. No signed-in account was available; see [ACCOUNT_IMPORT.md](ACCOUNT_IMPORT.md) |
| `R13/WP9b-Unit-01` to `-03`, `WP9b-UI-01`, `-02`, `WP9b-Live-01` | iPhone 17 Pro | Gaana and the shared-cache follow-up: `GaanaTests` (21 cases, 1 opt-in live `GANABAJANA_GAANA_LIVE=1`), `CompositeCatalogTests` (15 cases, 4 new including `testJioSaavnDownloadsLandInTheSharedCacheAndPlayOffline` and `testGaanaHLSStreamsSkipTheCacheWhileFallbackFilesAreStored`), `GanaBajanaGaanaUITests` (2), `GanaBajanaCatalogSourcesUITests` updated, `TrackRowAccessibilityTests`. Live playlists and segments fetched from the Mac on 26 September 2026. Counts per bundle: see [GAANA.md](GAANA.md) |
| `R13/WP11-SponsorBlockUnit-01`, `WP11-PlaybackUnit-02`, `WP11-UI-03` | iPhone 17 Pro only | SponsorBlock: `SponsorBlockTests` (hash prefix vectors, request shape, parse, filtering, caches, backoff, skipper), native-player integration for the injected [2, 5] segment, source/id guards, cancellation and grace, `GanaBajanaSponsorBlockUITests` fixture flow, Settings inventory row. No live request to `sponsor.ajay.app`; SE 3 and iPad not run; see [SPONSORBLOCK.md](SPONSORBLOCK.md) |
| `R13/WP13-Unit-01`, `WP13-BarPro-01`, `WP13-GesturesAirPlayPro-02`, `WP13-GesturesPro-03`, `WP13-Pro-04`, `WP13-ProExtra-05`, `WP13-Final-06`, `WP13-SE-01`, `WP13-iPad-01` | iPhone 17 Pro, iPhone SE 3, iPad Pro 13 | R13 items 6 to 8: heart back in the heading, full-width bar, AirPlay glyph at Lyrics/Queue weight, swipe up. `PlayerProgressBarTests` (4), `PlayerSwipeUpPreferenceTests`; `GanaBajanaPlayerProgressBarUITests` (bar and heart geometry on 17 Pro and SE; dark and light direct-launch captures on 17 Pro, SE and iPad including landscape), `GanaBajanaPlayerGesturesUITests` (3), plus the retained `GanaBajanaPlayerShellUITests`, `GanaBajanaRefinementUITests`, `GanaBajanaWorkflowUITests`, `GanaBajanaPlayerAirPlayUITests`, `GanaBajanaIPadLayoutUITests` and Settings inventory cases listed in [PLAYER_SHELL.md](PLAYER_SHELL.md) and [PLAYER_HEART.md](PLAYER_HEART.md). Glyph boxes measured on captures in `WP13-captures/`; counts per bundle: see those documents |
| `R13/WP14-FirstPass-01`, `WP14-DoneVariants-02`, `WP14-Unit-03`, `WP14-UI-04`, `WP14-Done-05`, `WP14-Done-06`, `WP14-Verify-A-07`, `WP14-Verify-A-08`, `WP14-Verify-B-09` | iPhone 17 Pro | R13 items 1 to 4 plus Extras A and B: `RecapListeningBucketsTests` (5), `ListeningAnalyticsTests` regression (10), `GanaBajanaRecapReviewUITests` (3), `GanaBajanaLibraryEntriesUITests` (4), `GanaBajanaSheetDoneUITests` (1), `GanaBajanaQueueSaveUITests` nested-sheet Done, `GanaBajanaCachedSongsUITests` (15, `.slow`/`.readError` fixed), `GanaBajanaStorageUITests` (5, stale expectation fixed), rewritten `GanaBajanaSearchRedesignUITests` and edited `GanaBajanaNavigationIntentUITests` cases, `GanaBajanaLibrarySearchUITests` (6). Counts per bundle: see [RECAP_AND_LIBRARY_REVIEW.md](RECAP_AND_LIBRARY_REVIEW.md) |
| `R13/WP15-CatalogParsing-01` | iPhone 17 Pro | **33 passed**: parser class with the ATV recording before the fix (the two-column playlist layout parses) |
| `R13/WP15-LivePlaylist-01` | iPhone 17 Pro | **1 failed** (the reproduction): live `VLPLVet2…` opened with 0 tracks; raw page captured as the UGC fixture |
| `R13/WP15-CatalogUnit-02` | iPhone 17 Pro | **88 passed**: `CatalogParsingTests` 36, `CatalogPlayCountTests` 6, `CatalogRequestTests` 18, `CatalogServiceTests` 17, `CompositeCatalogTests` 11, after the fix |
| `R13/WP15-LivePlaylist-02` | iPhone 17 Pro | 3 run, 3 failed on stale audio-only assertions while the live browse already returned 24 / 31 / 68 tracks; assertions rewritten |
| `R13/WP15-CatalogUnit-03` | iPhone 17 Pro | **118 passed**: the five catalog classes plus `ExperienceRadioEngineTests` 11 and `ListeningLanguageRadioTests` 19 on the final source |
| `R13/WP15-LivePlaylist-03` | iPhone 17 Pro | **4 passed**: `testLivePlaylistSearchResultsOpenWithTheirSongs` (24 audio / 31 video / 45 audio plus 23 video entries), `testLiveSearchAllFiltersPaginationAndCollectionBrowse` (editorial browse 129 entries, 124 video; Home selection stays audio), album credits and artist page |
| `R13/WP15-BaselineUI-01` | iPhone 17 Pro | **4 failed**: the four triaged `GanaBajanaSearchDiscoveryUITests` cases on the untouched checkpoint tree `6c34c9e`, proving they predate R12 |
| `R13/WP15-DiscoveryUI-01`, `WP15-DiscoveryUI-02` | iPhone 17 Pro | 3 passed, 2 failed; then 1 passed, 1 failed: intermediate runs while the fixture leak, scroll precondition and Norah expectation were corrected |
| `R13/WP15-DiscoveryUI-03` | iPhone 17 Pro | **20 passed, 0 failed** (2,938 s): the complete `GanaBajanaSearchDiscoveryUITests` class including the new `testPlaylistSearchResultOpensWithItsSongs`; see [PLAYLIST_BROWSE_FIX.md](PLAYLIST_BROWSE_FIX.md) |
| `R13/WP17-GenreUnit-01`, `WP17-GenreUnit-02`, `WP17-GenreUnit-03`, `WP17-Regression-01`, `WP17-GenreUI-01`, `WP17-GenreUI-02` | iPhone 17 Pro | Genre taste profile: `WP17-GenreUnit-02` **23 passed** (`GenreTaxonomyTests`, `GenreEvidenceTests`, `ListeningGenreProfileTests`, `GenreEvidenceLoaderTests`); `WP17-Regression-01` **292 passed** across the language, recommendation, taste, familiarity, radio, sync and persistence classes; `WP17-GenreUI-01` 3 run, 2 passed (the recap case failed on a stale scroll position and was corrected); `WP17-GenreUI-02` **5 passed** (corrected recap case, Settings inventory, `GanaBajanaRecapReviewUITests`). `GenreUnit-01` and `-03` are not named in the feature document; see [GENRE_PROFILE.md](GENRE_PROFILE.md) |

R13 item 5 (Settings redesign, WP16) is in progress by another package and has no bundles here. `Vendor/YouTubeKit/GANABAJANA-PATCH.md` records the itag 774 vendor test on the macOS host. No Release archive, `tools/audit-release.py` run, signing, upload or store action happened in either round; the new fixture markers were added to the audit's list by their packages without an archive to audit.

### Metrics

No remote analytics were added. Every new metric is a local OSLog record with counts, bytes, latencies and bounded enums, and each feature document owns its table: [PLAYER_SHELL.md](PLAYER_SHELL.md#metrics) (`trailing_time_toggled`, `swipe_up`; category `Player`), [PLAYER_HEART.md](PLAYER_HEART.md#metrics) (none), [SONG_DETAILS.md](SONG_DETAILS.md#metrics) (`SongDetails`), [DOWNLOADS.md](DOWNLOADS.md#metrics) (`Downloads`, `AudioCache`, `Connectivity`), [AUDIO_QUALITY.md](AUDIO_QUALITY.md#metrics) (`StreamResolver`), [EQUALIZER.md](EQUALIZER.md#metrics) (`Equalizer`), [ACCOUNT_IMPORT.md](ACCOUNT_IMPORT.md#metrics) (`Account`), [JIOSAAVN.md](JIOSAAVN.md#metrics) (`JioSaavn`, `Catalog`, `StreamResolver`), [GAANA.md](GAANA.md#metrics) (`Gaana`), [SPONSORBLOCK.md](SPONSORBLOCK.md#metrics) (`SponsorBlock`, `Playback`), [GENRE_PROFILE.md](GENRE_PROFILE.md#metrics) (`Genres`), [RECAP_AND_LIBRARY_REVIEW.md](RECAP_AND_LIBRARY_REVIEW.md#metrics) (none), [PLAYLIST_BROWSE_FIX.md](PLAYLIST_BROWSE_FIX.md#metrics) (`browseTracks`, `browseVideoEntries`, `browseCandidatesChecked`; category `Catalog`). Tests assert behaviour; OSLog text is not asserted.

### Test coverage

New unit classes: `PlayerProgressBarTests`, `PlayerSwipeUpPreferenceTests`, `SongDetailsParserTests`, `SongDetailsMergingTests`, `SongDetailsStoreTests`, `SongDetailsMusicBrainzTests`, `SongDetailsPlayerClientTests`, `SongDetailsServiceTests`, `DownloadsTests`, `AudioExporterTests`, `AudioQualityPreferenceTests`, `EqualizerTests`, `YouTubeImportClientTests`, `YouTubeImporterTests`, `JioSaavnTests`, `GaanaTests`, `CompositeCatalogTests`, `SponsorBlockTests`, `GenreTaxonomyTests`, `GenreEvidenceTests`, `GenreEvidenceLoaderTests`, `ListeningGenreProfileTests`, `RecapListeningBucketsTests`; extended `YouTubeDataAPITests`, `CatalogParsingTests`, `CatalogRequestTests`, `CatalogLiveTests`, `LibraryPersistenceTests`, `LibraryPlaybackDiscoveryPreferencesTests`, `LibrarySyncPersistenceTests`, `ModelTests`. Removed: `PlayerProgressTrailTests`.

New UI classes: `GanaBajanaPlayerShellUITests`, `GanaBajanaPlayerProgressBarUITests`, `GanaBajanaPlayerGesturesUITests`, `GanaBajanaSongDetailsUITests`, `GanaBajanaDownloadsUITests`, `GanaBajanaAudioQualityUITests`, `GanaBajanaEqualizerUITests`, `GanaBajanaYouTubeImportUITests`, `GanaBajanaCatalogSourcesUITests`, `GanaBajanaGaanaUITests`, `GanaBajanaSponsorBlockUITests`, `GanaBajanaGenreProfileUITests`, `GanaBajanaRecapReviewUITests`, `GanaBajanaLibraryEntriesUITests`, `GanaBajanaSheetDoneUITests`; edited `GanaBajanaRefinementUITests`, `GanaBajanaWorkflowUITests`, `GanaBajanaPlayerAirPlayUITests`, `GanaBajanaIPadLayoutUITests`, `GanaBajanaListeningControlsUITests` (Settings inventory), `GanaBajanaSearchDiscoveryUITests`, `GanaBajanaSearchRedesignUITests`, `GanaBajanaNavigationIntentUITests`, `GanaBajanaQueueSaveUITests`, `GanaBajanaStorageUITests`, `GanaBajanaStoreScreenshotsUITests`; `UITests/PlayerSeekGeometry.swift` is the identity mapping. Removed: `GanaBajanaPlayerProgressTrailUITests`. New DEBUG fixtures: `--saavn-fixture`, `--gaana-fixture`, `--sponsorblock-fixture`, `--youtube-import-fixture`, `--genre-fixture`, `--recap-history-fixture`, `DebugTrackDetailsFixture`; `DebugCachedAudioFixture.requireInventoryPresentation()` replaces `waitForInventoryPresentation()`.

### Known failures and their status

- Pre-existing failures fixed: `GanaBajanaCachedSongsUITests` `.slow` and `.readError` scenarios (fixture blocked the first inventory read past the 5 s deadline; WP14 Extra A) and `GanaBajanaStorageUITests.testClearingRecentSearchesPersists…` (stale expectation that a typed query counts as Recently opened; WP14 Extra A). The four `GanaBajanaSearchDiscoveryUITests` failures from the WP9 run fail identically at the checkpoint (`WP15-BaselineUI-01`): two fixture leaks in `DebugMusicFixtures.search(filter: .playlists)`, one stale R6 expectation (Carry On leads before Apocalypse) and one stale scroll precondition; all four pass in `WP15-DiscoveryUI-03`.
- `GanaBajanaNavigationIntentUITests.testNameOnlyPlayerArtistOpensAfterEmptySearchDiscoveryReappears` still expects the label "Go to artist, Norah Jones" on `player.artistName`; a fixture song with an album id now reads "Album and artists, …". To be updated in WP12b.
- Gapless playback with the equalizer on has a 0.20 to 0.40 s gap at the swap (AVFoundation primes the tap at play); recorded in ROADMAP backlog item 13, not a test failure.
- The iPad trail heart test and the rest of `GanaBajanaPlayerProgressTrailUITests` were removed with the trail; `GanaBajanaPlayerProgressBarUITests.testBarSpansTheColumnAndTheHeartInTheHeadingStillLikes` cannot run on the iPad because the shared driver waits for the bottom tab bar (pre-existing iPad limitation); the two direct-launch appearance tests cover the iPad including landscape.
- `GanaBajanaSearchDiscoveryUITests.expectSearchAtTop` anchored on `search.library.likes`, removed by WP14; WP15 moved the anchor to `search.radio.open`.
- One load-only flake: `GanaBajanaCachedSongsUITests.testFilteredLegacySongPlaysFromItsFileWithoutNetworkAccess` recorded "Loading audio took too long" once with two simulators running UI suites at the same time and passed on rerun (WP14).

### Not run

The full phone unit and UI suites, a Mac (Designed for iPad) run, physical devices, VoiceOver, Watch connectivity and CarPlay, native StoreKit, signed builds and archives, and every live-account path: no signed-in YouTube account was available, so the four import browse ids, Premium 256 kbps tiers (itags 141 and 774) and real Data API responses with the extended field projection are unverified; no live request reached `sponsor.ajay.app`; JioSaavn and Gaana were verified live only from the Mac and the simulator unit hosts, not on a device; live MusicBrainz genre responses were not probed. SE 3 and iPad coverage exists only for WP1 and WP13. WP12b performs the full matrix on the three dedicated simulators and records it in its own section above this one.

## September 25 authorization and source delivery

After the R10 changes, the owner asked to continue authorization and approved publishing library-only FFmpeg source. `artifacts/Authorization-20260925/summary.json` records the actions, readbacks and external requirements still open.

| Evidence | Verified result | Scope |
| --- | --- | --- |
| `artifacts/YouTube-authorization/intake-routing-20260924/posted.json` | YouTube [issue 565837697](https://issuetracker.google.com/issues/565837697) created once | The owner completed CAPTCHA. Exact title/body, reporter and New status were verified, then persisted on fresh navigation. The later response check still showed the description only and no routing answer |
| `agreements.json` | Free/Paid Apps agreements, W-9 and Digital Services Act records Active | Authenticated Apple browser; no agreement, bank/tax detail or regional declaration changed. The CLI web session remained separate and expired |
| `google-application-draft.json` | Prepared with owner-confirmed legal name and under-1,000/day forecast | No formal application submitted. Intake, address/review access, accepted evidence and legal acknowledgements remain open |
| `ffmpeg-publication.json` | Public repository and six release assets verified | All 10,413 retained source files match the original bundle; one non-build Xcode user file omitted. Anonymous download matched the 11,788,692-byte public archive and SHA-256 `ad454b1bc22d2b462619a393e9598a2553d0df01465569f9631438ca290588a1` |
| `python3 tools/build-ffmpeg.py --component verify` | Existing three-slice package passed | Hashes, linkage, exports, architectures, platforms, headers, licenses and minimum targets. Original framework/provenance were preserved |
| Public checkout `--component source` | Prepared tree matched `0106cdb70aa8d5788503239fc4357661c9f55217d4c0f9911d54c52517bbde67` | Independent public-checkout source preparation, not a new full three-slice binary rebuild or an application-relink demonstration |
| `provider-inquiries.json` | MusicBrainz and LRCLIB inquiries sent once each | Correct sender/recipients and full bodies checked; Message sent observed for each; a scoped Gmail Sent search returned exactly two matching messages. No credentials, attachments, purchase or agreement acceptance |
| `Release-Build.xcresult` | **Incremental unsigned Release build passed, 0 errors / 0 warnings** | Public source links added to app acknowledgements; bundled text matched the source byte-for-byte. No app archive/upload |
| `artifacts/AppStore-1.0.0-5/review-1790309749262953000/summary.json` | **3,914 reviewer-note characters verified; contact unchanged** | Updated public library-source link while retaining provider/application-relink holds and screenshot provenance; no submission |
| `asc-readiness.json`, `review-submission.json`, `review-items.json` | **25 errors / 6 warnings; zero review items** | The empty container remains `READY_FOR_REVIEW`, version remains `PREPARE_FOR_SUBMISSION`. The generic dashboard's in-flight/wait-for-review suggestion is not supported by exact submission/item reads |

Paths in the table are under `artifacts/Authorization-20260925/` unless specified. The library repository is public at commit `9cdd317110a5e4ce18c60e62f215b3229647882f`; no app source or credentials were published. The app working tree remains uncommitted. These are documentation/resource and external-system actions, with no new service metrics or unit tests. Earlier R10 test coverage remains scoped below. Privacy/age declarations were not changed in this follow-up, and no content permission or complete LGPL distribution compliance is claimed.

## R11: container-free transport and the progress-to-heart trail

Local source stays **1.0.0 (6)**. The full player's previous/play/next buttons sit straight on the artwork backdrop; the glass capsule behind them is gone. The progress bar and the like heart now share one row as a single continuous stroke: the bar fills first, then the last stretch of the song traces the heart's outline, so a finished song shows a complete heart the listener can tap. [ARCHITECTURE.md](ARCHITECTURE.md#ui-and-account-integration) records the geometry contract; `Sources/UI/PlayerProgressTrail.swift` is the shared implementation, also compiled into the UI test target.

All result bundles below are under `artifacts/R11/`. Intermediate bundles from the same day were removed after the final runs passed; `cleanup-20260925.log` lists every removal.

| Run | Result | Scope and follow-up |
| --- | --- | --- |
| `R11-Trail-Unit-0925-01` | **9 passed** | `PlayerProgressTrailTests`: bar/outline partition and junction fraction, heart centering inside the like slot and the bar meeting its leftmost point, exact junction/closure points, clockwise tracing order (lobe, notch at 22.6% of the outline, tip at 72.6%), even arc-length advance, monotonic invertible touch mapping that reaches both ends, bar/heart piece consistency with the whole trail, and degenerate row widths |
| `R11-Player-UI-0925-05` | **3 passed** | iPhone 17 Pro: `GanaBajanaPlayerProgressTrailUITests`. Same-line geometry (heart on the bar's line, after the bar, ending the row, below the heading, at least 52 points; seek at least 44 tall), seeks to 40%, the junction, mid-outline, 99.5% and back to 20% through the trail mapping, like/unlike by plain tap without moving the position, plus artwork-backdrop captures in dark and light appearance at bar-filling, mid-outline, complete and liked stages |
| `R11-Player-SE-0925-02` | **14 passed** | iPhone SE 3: the 9 trail unit cases, the three trail UI cases, `testHorizontalSeekAndShortDragsDoNotDismissTheFullScreenPlayer` with the trail-derived expectation, and `testMiniPlayerOpensFullScreenWithThumbSizedControlsAndBottomOptions`. The first SE run failed the title-below-midline check by 4.5 points because the row grew from 44 to 52 points; the heart is now centered in the row and the time labels overlap its empty lower edge, restoring the previous vertical budget |
| `R11-Player-IPad-0925-01` | **2 passed** | iPad Pro 13 with scene-geometry requests: dark and light trail/transport checks in portrait, then the side-by-side landscape player with the same row alignment. Landscape captures are rotated in the framebuffer, as in R10 |
| Earlier same-day runs (removed) | 1 failure fixed, all else passed | `R11-Player-UI-0925-01` passed the seek-drag, fixed-controls, seek/transport/repeat, likes-relaunch and AirPlay bottom-row suites; its one failure was `assertThumbTargets` requiring 52 points from AVKit's 44-point AirPlay button, a pre-existing mismatch with the R7 native-picker decision, now asserted at 44 with the anchor check left to the AirPlay suite. `UI-0925-02` found the fixture song starts liked (test order fixed); `UI-0925-04` captured a liked fill mid-fade, so like-state changes now switch without animation |
| `StoreScreenshots-20260925/R11-CoreScreens-{iphone17promax,ipadpro13}-0925-01` | **2 passed** | Live-session resume captures of the six store screens on both store simulators from current source; twelve images inspected, none uploaded. [Screenshots](app-store/SCREENSHOTS.md#september-25-recapture-from-current-source-local-only) records provenance |
| `R11-Player-UI-0925-06`, `R11-Player-UI-0925-07` | **12 passed, then 2 passed** | Owner feedback after the first review: the junction moved 2.5 points down the heart's left edge so the heart sits higher on the line, and the liked state became a 45% accent tint under an always-visible outline trace. Nine unit cases (updated landmarks: notch at 26%, tip at 76% of the outline) and the three trail UI cases passed; `-07` adds a liked-mid-trace capture in both appearances, inspected at 3× zoom |
| `StoreScreenshots-20260925/R11-CoreScreens-{iphone17promax,ipadpro13}-0925-02` | **2 passed** | Same live sessions recaptured after the adjustments; `capture-02` supersedes `capture-01`, none uploaded |
| `R11-Release-Build-0925-01` | **Passed: 0 errors** | Unsigned generic-iOS Release build. Warnings are the pre-existing vendor deprecation set; none come from the changed files. Not an archive, signing, upload or App Store acceptance result |

Test-side seek expectations changed from `fraction × width` to the trail mapping (`UITests/PlayerSeekGeometry.swift`): the bar alone covers about 81% of the recording on a 354-point row and 88% at 572 points, and a drag past the bar covers the remaining stretch. `AppUITestDriver.seek(to:)` and the two tests that hard-coded 131 s / 65.5 s now derive their targets from the same geometry; the assertions keep their previous tolerances.

Inspected captures: `R11/player-ui-05-attachments/` (17 Pro, both appearances, plus row crops), `R11/player-se-02-attachments/`, `R11/player-ipad-01-attachments/` (portrait and rotated landscape). The liked fill was pixel-compared with the bar colour after the animation fix.

### Metrics

No new metric. The change is local rendering and gesture mapping; playback seeks still go through `PlayerController.seek(to:)`, whose existing control-revision and position diagnostics are unchanged. No remote analytics were added.

### Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Partition, junction fraction by row width, heart placement, closure, tracing order, even advance | `PlayerProgressTrailTests` | Unit |
| Touch mapping: bar linear, slot spread, both ends, inverse, degenerate widths | `PlayerProgressTrailTests` | Unit |
| Bar/heart pieces equal the whole trail at every progress | `PlayerProgressTrailTests` | Unit |
| Same-line layout, seeks into and out of the heart's stretch, like tap keeps position, appearance captures, iPad landscape | `GanaBajanaPlayerProgressTrailUITests` | Native UI integration |
| Existing seek drag, fixed controls under loading, repeat via 99% seek, likes relaunch, AirPlay bottom row, thumb targets | Selected `GanaBajanaRefinementUITests`, `GanaBajanaWorkflowUITests`, `GanaBajanaPlayerAirPlayUITests` | Native UI integration |

Not run in R11: the full unit or UI suites, physical devices, VoiceOver, Watch connectivity, StoreKit or any signed delivery. The store Player capture predates this change and needs recapture with the new binary.

## R10: artist-song identity and artwork-backed pages

Local source is **1.0.0 (6)**. Artist lists collapse matching release aliases while retaining distinct performances and recording-specific metadata. Player and collection pages use artwork-derived backgrounds; album/artist navigation extends through the status bar with native floating controls. [Provider matching](PROVIDERS.md#radio-and-language-evidence) and [background rendering](ARCHITECTURE.md#ui-and-account-integration) describe the implementation.

All result bundles below are under `artifacts/`. The final focused coverage is **291 unit cases and 9 UI device/workflow combinations passing across follow-ups**, not one full green suite.

| Run | Result | Scope and follow-up |
| --- | --- | --- |
| `R10-Full-Unit-0924-01` | Interrupted during native StoreKit | The log records 1,664 passing cases before a `notEntitled` error and a stalled native purchase. No completed full-run result is claimed |
| `R10-Full-Unit-0924-02` | 1,780 passed, 22 failed, 36 skipped of 1,838 | Pre-review source; native StoreKit excluded. Playback/provider waits timed out during the interrupted session. All 22 failed cases subsequently passed in the focused run after restarting the dedicated simulator |
| `R10-Review-Unit-0924-01` | Compile failed, no tests ran | Accessibility environment properties are read-only. Rendering tests now pass the same values through the production surface configuration |
| `R10-Review-Unit-0924-02` | **290 passed, 1 failed** | Final song matching, raw-candidate service integration, loader/correction behavior, backdrop state/rendering, catalog/model regressions and the previously failing native playback classes. The sole failure was ImageRenderer's inability to flatten a native navigation-link button |
| `R10-Rendering-Unit-0924-01` | 5 passed, 1 failed | The native collection-link rendering harness still needed an attached window/navigation host; contrast and artwork tests passed |
| `R10-Seamless-UI-0924-01` | **3 passed** | The corrected native-rendering unit case plus iPhone 17 Pro player/artist navigation and album durations/footer workflows. Header and scrolled captures show a continuous background |
| `R10-Seamless-SE-0924-01` | **3 passed, 2 timed out** | SE3 player/artist artwork, saved language correction and largest-text light-mode album rows passed. Two longer spotlight workflows exceeded the initial 180-second allowance while the driver enumerated covered collection controls |
| `R10-Seamless-SE-0924-02` | **2 passed** | Count-sorted language-filtered playback and Featuring queue workflows. The driver recognizes hittable fixed player controls without inspecting the covered scroller; unchanged assertions passed under a 600-second allowance |
| `R10-Seamless-IPad-0924-01` | **2 passed** | iPad Pro 13 album header/durations plus player/navigation workflows in portrait and wide orientation. Scene-geometry requests were explicitly enabled; orientation and 44-point action geometry were asserted |
| `R10-Release-Build-0924-01` | **Passed: 0 errors, 15 warnings** | Unsigned generic-iOS Release build, including companion products. This is not an archive, signing, upload or App Store acceptance result |

The earlier `R10-Dedupe-Backdrop-Unit-*` and `R10/scratch-live-*` artifacts remain development evidence. The temporary live capture test was removed after it captured Kamikaze and The College Dropout in both appearances, plus Radiohead's artist/list pages. Those images predate the final matching, contrast and navigation refinements. Final fixture images were inspected under `R10/seamless-ui-01-attachments/`, `R10/seamless-se-01-attachments/` and `R10/seamless-ipad-01-attachments/`.

### Metrics

| Metric | Emitted when | Dimensions | Why |
| --- | --- | --- | --- |
| `displayAliases` | Every completed catalog load, including zero | Existing local ArtistSpotlight OSLog category; no recording identifiers | Count release aliases folded into displayed groups |
| Existing catalog/request success, failure, cancellation, timeout and latency fields | Existing provider paths | Existing bounded operation values | Preserve request/deadline diagnostics |

Artwork processing is local. The change adds no remote analytics. Tests assert grouping, limits and observable outcomes; OSLog text is not mocked or asserted.

### Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Album/single/reissue selection, explicit versus missing badge, differing totals | `ArtistSpotlightTests`; representative retains its own metadata | Unit |
| Named performances, clean edits, unsupported language labels, different guests/linked identities, missing durations, duration/language bridges | `ArtistSpotlightTests`; conservative grouping and permutations | Unit |
| Progressive search/album results, candidate/display bounds, exact-ID count enrichment | `ArtistSpotlightCatalogTests` | Unit with controlled providers |
| Saved corrections, cleared corrections, Featuring exclusion and replacement classifications | `ArtistSpotlightLoaderTests` | Unit with controlled providers/library |
| Palette families, neutrality and accessibility styles | `ArtworkPaletteTests` | Unit |
| Delayed/out-of-order artwork, cancellation, nil/failure and retry | `ArtworkBackdropStateTests` | Unit |
| Real SwiftUI blend/blur output across mixed-brightness crops; scoped/default foregrounds | `ArtworkBackdropRenderingTests`; secondary contrast at least 4.5:1 on tested surfaces, native-hosted collection caption | Unit with native rendering |
| Navigation, scrolling, queue scope, language corrections, large text and iPad geometry | Selected UI suites in the table | Native UI integration |

No final full UI suite, physical VoiceOver/autorotation, Watch connectivity, live StoreKit purchase or new signed delivery is claimed. The separately refreshed App Store screenshots below retain their recorded source provenance and have not been replaced by these fixture images.

## September 24 core listening screenshots

The owner requested Home, Player, Album, Artist, Recap and Liked songs for both store galleries, using `asc` only. `asc xcode test` 5.3.4 ran the capture workflows on the dedicated iPhone 17 Pro Max (`6D63F232-9C13-4929-9D4D-EA0965DB7C94`) and iPad Pro 13 (`EED2BCA0-6755-4DA8-82B5-A997CE61561A`), both iOS 26.5. The Debug bundle reports `1.0.0 (5)` but includes post-build-5 R10 source. These captures require a matching new binary before review.

Artifacts in this table are under `artifacts/StoreScreenshots-20260924/`:

| Run | Result | Scope |
| --- | --- | --- |
| `R3-CoreScreens-iPhone-0924-01.xcresult` | **1 passed** | `test10CoreListeningScreens` searches and plays six live recordings, saves each through Like, then captures all six screens. Recap shows 11 actual minutes and six counted plays |
| `R3-CoreScreens-iPad-0924-01.xcresult` | Interrupted by the 900-second harness timeout | Six songs had played and the first two images were saved. The incomplete bundle has no final result; it is not a passing test |
| `R3-CoreScreens-iPad-0924-02.xcresult` | **1 failed** | Resume retained the six favorites and paused playback; the combined chooser's artist row was not hittable. Later captures use the real artist-name button; this did not verify or fix that chooser path |
| `R3-CoreScreens-iPad-0924-03.xcresult` | **1 failed** | Capture navigation returned to Library's retained artist destination rather than the liked-song list. Reselecting Library restores its root before opening Liked songs |
| `R3-CoreScreens-iPad-0924-04.xcresult` | **1 failed** | Album and artist title elements overlapped during navigation. The wait now selects the exact artist label and requires it to be hittable |
| `R3-CoreScreens-iPad-0924-05.xcresult` | **1 passed** | `test11ResumeCoreListeningScreens` captures all six pages from the original isolated library, retaining six favorites and 13 real listening minutes |
| `readback-1790286580768511000/summary.json` | **12 replacements verified** | Native opaque RGB images, raw/final RGB samples and ICC profiles identical, remote filename order and MD5s matched, all delivery states `COMPLETE`; retained Watch pair also matched |

All twelve delivered images were visually inspected. [SCREENSHOTS.md](app-store/SCREENSHOTS.md) records the final directories and manifests. No seeded media/history or altered app controls were used. The source changes in this task are confined to capture automation; no new service metrics were added. Two initial `asc xcode test` boot probes selected an opt-in capture without enabling it, yielding one skip each; they are not capture coverage. Direct `asc screenshots capture` could not use the unrelated `axe` on PATH, so captures used the native XCTest route through `asc`.

The result is passing coverage for one phone capture workflow and one iPad resume workflow, not a full green UI suite. Unit suites, native StoreKit, Watch connectivity and physical-device acceptance were excluded. Reviewer notes were updated and verified at 3,887 characters, with the approved contact and `demoAccountRequired=false` preserved. Readiness remains 25 errors / 6 warnings for the existing declaration and authentication blockers; the review draft remains empty and unsubmitted.

## R9: official recording metadata and build 5

The owner requested official YouTube Data API integration, suggested ytmusicapi, and prioritized provider-supplied recording languages over repeated classification. They subsequently authorized upload and an App Review submission attempt after verification. The source candidate is **1.0.0 (5)**; build-4 artifacts remain frozen. [YOUTUBE_DATA_API.md](YOUTUBE_DATA_API.md) owns behavior, metrics and configuration.

| Run / artifact | Result | Scope |
| --- | --- | --- |
| `R9-API-Build-0924-01.xcresult` | Build for testing passed | Native metadata client, optional request delegate, language shortcut, duration preparation and existing targets; an unnecessary `await` warning was corrected before unit verification |
| `R9-API-Unit-0924-01.xcresult` | **174 passed, 0 failed/skipped** | 29 new unit cases plus classification, derived-cache persistence, lyrics, catalog and bounded-networking regressions |
| `R9-API-Live-0924-01.xcresult` | **1 passed, 0 failed/skipped** | Real bundled app-restricted credential, exact recording duration/audio-language tag and classification bypass in the iOS test host |
| `artifacts/YouTube-authorization/metadata-probe-20260924-01.json` | Six recording responses compared | Official metadata supplied duration for all six and audio-language tags for two. Four Hindi recordings had English snippet language but no audio tag. ytmusicapi 1.12.3 supplied no language fields/audio-track tags in those six responses |
| `artifacts/YouTube-authorization/api-key-20260924.json` | Restrictions verified | Correct bundle HTTP 200; different bundle HTTP 403; console readback confirms the single YouTube Data API restriction |
| `artifacts/AppStore-1.0.0-5/Archive.xcresult` | Passed, **0 errors / 14 warnings** | Final build-5 production source with phone, widget and Watch targets |
| `archive-audit.json`, `ipa-inspection.json` in the build-5 directory | Passed | Signatures, support, notices, fixture/catalog exclusion, exact profile/entitlement coverage, Production iCloud and required phone-only API configuration |
| `apple-validation.log`, `apple-validation.json` | `VERIFY SUCCEEDED with no errors` | Exported App Store IPA; validated hash retained through upload |
| `validation-reservation-1790220500273605000/` | Exact validation-only reservation removed | Only analyzer/description assets, no IPA; no processed build deleted |
| `readback-1790220802087226000/summary.json` | **VALID, App Store eligible and attached** | Build `42a08cec-1e27-4ec2-afad-4e3e88af27e3`; remote IPA size/MD5 match, retained screenshots remain complete/ordered, metadata matches and five tips remain configured |
| `public-pages.json`, `review-1790220323838038000/summary.json` | Published/readback-verified | Support/Privacy bytes and exact 3,950-character build-5 reviewer notes; contact preserved |
| `submit-1790220849624895000/summary.json` | **Blocked before review** | Apple refused the add-item request: 22 age-rating attributes, unpublished App Privacy and missing content rights. Existing review container has zero items and remains unsubmitted |
| `final-record-audit.json`, `readback-1790222433002759000/summary.json` | **Passed, 2026-09-24 04:00 UTC** | Frozen source/credential hash, IPA/upload checksum, retained assets, live notes/public-page bodies, companion exclusion and signing cleanup. Two metadata files validated with zero errors/warnings; JSON/whitespace checks passed; review remains empty and unsubmitted |

The xcresult summaries confirm counts on the dedicated iPhone 17 Pro/iOS 26.5 simulator. New unit coverage is `YouTubeDataAPITests` (17), `YouTubeLanguageMetadataTests` (7) and `CompositeLyricsMetadataTests` (5). Tests preserve input metadata, distinguish audio and snippet language, bound responses/deadlines/cache/concurrency, exercise quota/rate/auth/offline paths and cancellation, and verify cached/persisted language provenance with correction precedence. The native live request's success/latency counters were observed at 488 ms. OSLog text is not asserted by unit tests.

The six-recording comparison is not a catalog-wide availability estimate. No new full UI run, physical-device networking or induced cross-host redirect is claimed. The release audit passed the required phone API-configuration and Watch/widget exclusion checks; input hashing includes the ignored credential file without copying its value into receipts.

Release receipts in the table are under `artifacts/AppStore-1.0.0-5/` unless another directory is specified. The IPA is **15,358,007 bytes**, SHA-256 `8593026f58d070a74df1cf93e48a54b9678e270e796baa48c0ca79de7746b4a0`, MD5 `7017f372367b022a009116c7b56320b0`. Export preserves all three executable UUIDs. Temporary signing-keychain removal and exact search-list/default restoration passed. Phone/iPad marketing images retain build-4 provenance; Watch/IAP images retain build 3.

The actual add-item error and post-attempt readbacks preserve the blocked state without changing declarations. CLI deep validation separately counts 24 unanswered age fields plus content rights, **25 errors / 6 warnings**. Its count is distinct from the server's 22-field add-item response. [ASC_STATE.json](app-store/ASC_STATE.json) and [release status](app-store/RELEASE_STATUS.md) own current delivery and remaining requirements.

The later [Osho/Bruce review-question comparison](app-store/REVIEW_QUESTIONS.md) read their released age declarations and public privacy labels. A partial save of 14 code-supported Breezy age answers was rejected because the initial questionnaire also requires content descriptors. `age-rating-confirmed-1790252246811509000/summary.json` records the error and unchanged before/after declaration. No age or rights values were saved. CLI web renewal returned 503; the owner then completed the browser sign-in (account verified) and App Privacy was saved as an incomplete, unpublished draft with three data types still awaiting purpose/linkage/tracking setup (`privacy-draft-20260924.json`, `Privacy-Draft-20260924-0[12].png`, latest `readback-1790264794571141000/`). These metadata checks added no app-code changes or new test execution.

## Historical App Store preparation: 1.0.0 (4)

The user authorized updating App Store Connect and submitting the latest build after R8. Build 4 preserves the initial marketing version and includes R6/R7/R8. Source remains uncommitted after `ebb5d5c`. Artifacts in this section are under `artifacts/AppStore-1.0.0-4/`; build-3 files remain frozen.

| Run / artifact | Result | Scope |
| --- | --- | --- |
| `BuildForTesting.xcresult`, `BuildForTesting-02.xcresult`, `BuildForTesting-03.xcresult` | Passed | Build-4 app, widget and test targets; subsequent builds contain capture-helper corrections |
| `iphone-shots.xcresult` | Six captures failed | The old unseeded launcher expected `--search-results` to open Search. That test-only argument now requires seeded UI; the capture helper instead taps the real Search tab |
| `ipad-shots.xcresult` | Cancelled | Owned job stopped after the common launcher defect was identified; not acceptance evidence |
| `iphone-shots-02.xcresult` | **6 passed** | Real unseeded Search/library shortcuts, language-free radio setup, icons, Home customization, iCloud waiting and empty Library |
| `ipad-shots-02.xcresult` | **5 passed, 1 failed** | Same iPad workflows; Customize Home queried Reset before its virtualized row was visible |
| `ipad-customize.xcresult` | **1 passed** | The helper reveals Reset before checking it, then restores the top section for the capture. All required controls remain asserted |
| `Archive.xcresult` | Passed, **0 errors / 14 warnings** | Final production source, including the native Mix string-options correction, with app, widget and Watch |
| `archive-audit.json`, `ipa-inspection.json` | Passed | Identity, arm64 iPhone/iPad support, signatures, notices, fixture/catalog exclusion, exact App Group/profile coverage and Production iCloud |
| `apple-validation.log` | `VERIFY SUCCEEDED with no errors` | Apple altool validation of the exported App Store IPA |
| `validation-reservation-1790209269050386000/summary.json` | Exact validation-only reservation removed | The guarded uploader stopped before sending the IPA because Apple's validator reserved build4. Readback confirmed only analyzer/description assets, no IPA or processed build; the validated IPA remained unchanged |
| `upload.json`, `final-readback-1790209733641079000/summary.json` | **VALID, App Store eligible and attached** | Current build `0e257a65-ec5d-47ac-ba00-d39e470caab6`; remote IPA bytes/MD5 match, all14 screenshots are complete and ordered, metadata matches, five tips remain ready and no review submission exists |
| `public-pages.json` | Byte-verified | Current Support/Privacy publication, with previous revision preserved |
| `review-1790208423874983000/summary.json` | Notes verified, contact unchanged | 3,912-character build-4 reviewer instructions; no review submission |
| `review-attempt-01.json` | **Blocked before review** | Apple refused to add the app to the newly created review draft, citing missing age-rating, App Privacy and content-rights declarations. Readback confirms zero items and no queued app review; no rights claim was made |

All **12 selected phone/iPad capture workflows have passing coverage across the runs**, not one green first run. The native 1320×2868 phone and 2064×2752 iPad images were inspected. Conversion retains dimensions, RGB pixels and ICC profiles; manifests retain raw checksums and source build. The Watch and IAP review images remain their separately recorded build-3 evidence. These real, empty-library store captures are distinct from seeded R8 widget acceptance media.

The IPA is **15,302,696 bytes**, SHA-256 `6cd3f42705c9db52d69d9c06e06ebedc91e26dfd2c21e71d0da321ec56a30ddc`, MD5 `2319fed09c14b82312aa7c585a18597a`. App Store profiles are `BKV567TA2S` for the phone, `MPDS5C96JT` for the widget and reused `PNPWW4U8LL` for Watch, with existing certificate `YBW79S2M2T`. All three signed bundles have `get-task-allow=false`; only phone/widget have the exact App Group, and only the phone has Production iCloud. None requests CarPlay. Executable UUIDs match archive and export. Temporary signing-keychain removal and the original search-list/default restoration were verified.

The canonical metadata update has an empty follow-up plan. [ASC_STATE.json](app-store/ASC_STATE.json) and [release status](app-store/RELEASE_STATUS.md) record verified delivery. Readiness retains25 errors for the missing content-rights declaration and24 age-rating fields, plus five IAP warnings and expired web authentication. Provider authorization, recipient FFmpeg delivery and required declarations remain submission requirements.

## R8: Home Screen widgets

Uncommitted source after R7. R8 checks used development version/build 1.0.0 (3); the user subsequently authorized build-4 preparation and App Store upload. Recently played, Liked songs and Mix widgets use a bounded local App Group snapshot and validated app routes. [WIDGETS.md](WIDGETS.md) owns behavior, metrics and test mapping.

| Run | Result | Scope and correction |
| --- | --- | --- |
| `R8-Build-0923-01` | Passed | Native WidgetKit extension, app/Watch and phone test targets compile |
| `R8-Unit-0923-01` | Compile failed; no tests ran | DEBUG observable nested state needed file-scoped access, and the fixture called the existing history-clear method by the wrong name. Corrected |
| `R8-Unit-0923-02` | **1757 passed, 1 failed, 35 skipped** of 1793 | Full unit target excluding native `TipJarStoreKitTests`. All 124 R8 cases passed. An existing native recovery test observed 0.477 seconds of counted listening after its position-based wait, short of its retained 0.5-second assertion; the fixture now waits for the actual counted delta |
| `R8-Workflows-0923-01` | **46 passed, 1 failed, 0 skipped** | All 44 selected unit cases passed, including the recovery test and one added uncached-current widget regression. Small-recent resume and medium-mix cached playback UI passed, including exact queue and zero network checks. Native gallery search found Breezy, but the first-use keyboard tutorial blocked its result-row tap |
| `R8-UI-0923-01` | **4 passed, 5 failed** | Live liked-list/URI, empty likes, history off/re-enable and small-mix browsing passed. The native blank-edge long press did not enter editing and was reverted. Large preview cases stopped at one-pixel outer-canvas rounding; their canvas-only tolerance now uses one device pixel. The URI helper replayed fixture reset on XCTest's URL launcher; reset is removed before every URL launch |
| `R8-UI-0923-02` | **4 passed, 2 failed** | Updated liked-list and refused-offline URI launches, large weekly mix playback/browse and unavailable-state browsing passed. The native gallery's Add Widget label has a leading space from its system symbol; selection now matches the actual button. A large standard-text row exposed 43.667-point bounds from a nominal 44-point frame |
| `R8-SmallPhone-0923-01` | **2 passed** | SE3 largest-text previews across all families and actual cached recent resume, before the later 46-point action-frame correction |
| `R8-IPad-0923-01` | **2 passed, 1 failed** | iPad liked-list/URI persistence and largest-text previews passed. Native setup selected the recent-app Dock icon, whose menu offers window actions; the helper now chooses the upper visible Home icon |
| `R8-UI-0923-03` | **18 passed, 1 failed** | All 16 presentation/rendering tests and largest-text/medium-mix UI passed with 46-point frames and explicit accessibility hit shapes, retaining the 44-point assertions. WidgetKit placed the recent widget and rendered its saved song/artwork, but archived its accessible link at the decorative 28-point badge's bounds |
| `R8-Native-0923-04` through `06` | Native small-card target failed | Outer framing and accessibility grouping did not repair the archived Link; combining children could also change its role. The final view supplies an explicit card-sized accessibility representation |
| `R8-Native-0923-07` | **18 passed** | All 16 presentation tests, small shared preview and actual phone Home Screen tap passed. One current native Link, real minimum bounds, an off-badge tap, saved 12-second resume, exact cached queue and zero network requests |
| `R8-IPad-0923-02` | **3 passed, 1 failed** | Final largest-text previews, medium Mix cached playback and small recent resume passed. Native setup still targeted the Dock/window menu |
| `R8-IPad-0923-03` | Native setup timed out | The Options-menu route found Home editing, but repeated SpringBoard quiescence waits exhausted the unchanged 240-second allowance |
| `R8-IPad-0923-04` | **1 passed** | Native Small widget action, actual WidgetKit rendering, card-sized Link, saved recent resume and exact cached queue with zero network requests on iPad |
| `R8-SmallPhone-0923-02` | **1 passed, 1 failed** | Largest-text previews across all families passed with final action/accessibility frames. Cached recent playback timed out after a delayed automation launch; no production change followed |
| `R8-SmallPhone-0923-03` | **1 passed** | The same SE3 cached-resume workflow passed in 16.8 seconds, retaining saved position, exact queue and zero-network assertions |
| `R8-Native-Mix-0923-01` through `03` | Native setup failed | Gallery page eight placed the medium Mix; early helpers queried hidden editing descendants, dismissed only the configuration overlay, or retained a stale Home icon identity |
| `R8-Native-Mix-0923-04`, `05` | Native Mix selection failed | The system editor saved Discover Weekly, but the rendered widget remained Daily Mix. System logs confirmed the saved raw value and an AppEnum case-resolution runtime error; this was not just a dismissal problem |
| `R8-Native-Mix-0923-06`, `07` | Compile/metadata export failed; no tests ran | The string-options adapter initially used a default-value initializer requiring iOS 26. Removing it exposed the WidgetConfigurationIntent requirement for an optional parameter. The provider supplies the default on iOS 18+ |
| `R8-Native-Mix-0923-08` | Native setup failed | An existing prototype widget had no new string selection, so its native value button was labelled Mix. The helper now supports that actual unset entry point |
| `R8-Native-Mix-0923-09` | **1 passed** | Native options provider loaded Discover Weekly; the configured Home widget rendered it and its real 46-point Play action started the exact three-song cached queue with zero network requests |
| `R8-Release-0923-01`, `02` | Archives and audits passed | Local signed Release evidence, including the final small-card accessibility representation in the second archive. Both predate the Mix runtime adapter and are not the final upload candidate |

All **1759 eligible unit cases have passing coverage across the full and focused runs**, including 125 new R8 cases. This is not one all-green full-suite bundle. The 35 live skips and native StoreKit exclusion remain explicit.

All **19 selected device/workflow combinations have passing coverage across these runs**: 12 on iPhone 17 Pro, two on iPhone SE3 and five on iPad Pro13. The full UI suite was not run. Final native recent widgets on phone/iPad, configured Weekly Mix, small-phone cached-resume and large-text captures were inspected. These are QA fixtures, not marketing images. Physical VoiceOver, actual tinted Home Screen rendering, device refresh scheduling and Mac/Continuity placement remain separate acceptance boundaries.

Independent source review found and verified corrections for route-time privacy invalidation, cold offline cache-inventory races, older radio results replacing a recent-song resume, and reload loss after a post-write metadata failure. Additional current-recording offline coverage verifies that a paused uncached selection remains intact rather than attempting resolution. Native testing also verified the card-sized accessible Link and the corrected system Mix-selection serialization. Local widget diagnostics use bounded outcomes/counts; tests assert behavior rather than OSLog text.

`XCUIApplication.open(URL)` can replace the app process even when it was already in the background. Those UI cases verify actual URI launch/restoration; they are not evidence of uninterrupted warm delivery. The native Home Screen workflow owns widget-to-running-app delivery. Preview screenshots use the exact shared view on a DEBUG canvas, separately from native WidgetKit gallery/placement captures.

## R7: AirPlay, Settings icons and listening controls

Unreleased source after R6, still uncommitted after `ebb5d5c` and using development version/build 1.0.0 (3). AirPlay is first in the player's bottom row with a compact native glyph, Settings has icon-labeled rows, and Shuffle order/Discovery balance use durable independent preferences. [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) owns policy, metrics and case mapping. Completed coordinator results follow.

| Run | Result | Scope and correction |
| --- | --- | --- |
| `R7-Build-0923-01` | Failed | Swift could not type-check the chained generic random-sampling expression. Explicit UInt64/Double intermediates and a typed priority tuple preserve the sampling calculation |
| `R7-Build-0923-02` | Passed, **0 errors / 21 warnings** | App, embedded Watch and phone test targets; existing test/deprecation warnings plus a new test's captured mutable flag warning |
| `R7-Core-0923-01` | **166 passed, 1 failed, 0 skipped** | New shuffle/familiarity/persistence/model suites and related regressions. The native recovery fixture disabled history but expected `.reloaded`; the correct privacy-boundary result is now asserted while all audio/order checks remain |
| `R7-Unit-0923-01` | **1627 passed, 1 failed, 35 skipped** of 1663 | Full unit target, native `TipJarStoreKitTests` excluded. The repaired-startup test caught an immediate legacy-snapshot rewrite from the new occurrence mapping. Restore now preserves a missing mapping until an actual order/selection mutation; strict byte-preservation assertions remain |
| `R7-Workflows-0923-01` | **53 passed, 2 failed, 1 skipped** | All 49 selected unit cases passed, including the unchanged recovery-byte test and six new legacy/no-op cases. Four UI workflows passed: preference/relaunch/reset, history off/on, largest-text landscape player and Settings spacing. Crossfade exposed a 31-point native slider inside its frame; interaction/accessibility shapes now use 44 points. Custom AirPlay foreground imagery overlapped AVKit's glyph and overflowed its anchor; it was removed in favor of a visible 44-point native picker |
| `R7-UI-Fixes-0923-01` | **1 passed, 1 failed** | Leftmost native AirPlay passed its actual target/anchor, reopening and layout assertions; the inspected glyph is single and compact. Crossfade's target passed. Settings stopped on a test assuming native Menu buttons expose no UIImage metadata |
| `R7-UI-Fixes-0923-02` | **1 failed** | An attempted accessibility grouping removed the Menu's native button role. Reverted; the helper instead checks one labeled native action with no additional icon buttons, while retaining native menu choices and geometry assertions |
| `R7-UI-Fixes-0923-03` through `05` | One Settings failure per run | Native Menu wrappers may contain an unlabeled native button and content insets; helper checks now retain real minimum targets/containment rather than requiring an empty or identically sized subtree. Following's identifier exposed only its count; Following and Version now explicitly group their labels and values |
| `R7-SmallPhone-0923-01` | **1 passed, 1 failed** | iPhone SE 3: native AirPlay order/size/anchor/reopening passed. Settings retained the earlier inset-comparison assumption |
| `R7-IPad-0923-01` | **1 passed, 2 failed** | iPad Pro 13: native AirPlay passed. Settings controls near the viewport edge stopped moving under repeated 14-point drags; the helper uses a 44-point minimum motion while preserving full-visibility assertions |
| `R7-Release-0923-01`, `R7-Release-Audit-01.log` | Archive and audit passed, **0 errors / 14 warnings** | Signed local Release with final native AirPlay sizing, Settings labels and backend controls. Arm64 phone/iPad identity, deep signature, fixture/catalog exclusion and dependency notices passed |
| `R7-SmallPhone-0923-02`, `R7-Settings-Final-0923-01` | Settings follow-ups failed | The first used the pre-grouping Following label. The three-device follow-up exposed UIImage metadata under combined informational rows. The final helper checks their exact label and absence of actions instead of treating metadata as separate accessibility controls |
| `R7-IPad-0923-02` | **1 passed, 0 failed/skipped** | Native preference choices, history-off preservation, both discovery extremes, relaunch and defaults on iPad after the bounded-drag correction |
| `R7-Settings-Final-0923-02` | **One case passed on all three devices**, 0 failed/skipped | iPhone 17 Pro, iPhone SE 3 and iPad Pro 13, largest accessibility text: all six sections, native menu choices, real minimum targets, informational labels/values and Acknowledgements navigation. The summary counts one unique test; device configurations record three passing runs |

All **1634 eligible unit cases have passing coverage across the full run and the 49-case focused correction**, including six additional regression cases. This is not one all-green full-suite bundle. The 35 opt-in live checks were skipped and native StoreKit excluded.

All **11 selected device/workflow combinations have passing coverage across these runs**: six on iPhone 17 Pro, two on iPhone SE 3 and three on iPad. One additional native AirPlay-chooser case skipped before launch because route-UI capability was not declared. The full UI suite was not run. Final captures in `R7-Settings-Final-02-attachments/`, `R7-IPad-02-attachments/`, `R7-SmallPhone-AirPlay-attachments/` and `R7-IPad-AirPlay-attachments/` were inspected, alongside the main-phone AirPlay and light Settings captures. These are QA fixtures, not marketing media.

The R7 archive is development-signed with `get-task-allow=true`; it is local evidence, not an App Store export/upload. Separately inspected phone entitlements contain `iCloud.com.agraabhi.ganabajana` for CloudDocuments/ubiquity; the Watch requests neither iCloud nor CarPlay, and neither standard app requests CarPlay. AirPlay's single native glyph and actual target/anchor passed on both phone sizes and iPad. Receiver connectivity is unverified.

Whitespace, shell syntax, ASC/IAP JSON and privacy/entitlement-plist checks passed. Local `shuffle_order` and `discovery_balance` diagnostics use bounded mode/outcome fields; tests assert state, saved data, native playback and UI behavior rather than OSLog text. Physical VoiceOver speech, receiver connections, two-device native iCloud and StoreKit transactions retain their separate acceptance limits.

Independent source review found and verified fixes for ambiguous identical-duplicate restoration, reversed familiarity composition when providers return heard songs, and unnecessary Home invalidation after shuffle-only cloud edits. A native AirPlay presentation timeout is a failure only on an explicitly declared route-UI-capable runner; the conditional test skips before launch otherwise. Native receiver selection and physical VoiceOver remain separate acceptance boundaries.

## R6: listening-led discovery, Search, cache and offline playback

This is unreleased source after uploaded **1.0.0 (3)**. Xcode 27 targets dedicated iPhone 17 Pro, iPhone SE 3 and iPad Pro 13 simulators on iOS 26.5. The coordinator ran the checks below; subagents implemented and reviewed scoped changes without running builds. The signed build-3 IPA, store screenshots and public-page copies remain the historical distribution baseline.

| Run | Result | Scope and correction |
| --- | --- | --- |
| `R6-Build-0923-01` | Build failed | An observable nested DEBUG probe required file-scoped access for the generated conformance |
| `R6-Build-0923-02` | Build failed | Reduce Motion is a read-only environment value; the Search fixture uses a DEBUG-only effective value. The offline sheet Done control needed its existing identifier/action initializer |
| `R6-Build-0923-03` | Passed, 0 errors / 2 warnings | App, embedded Watch and phone unit/UI targets; existing navigation deprecation and test compiler warning |
| `R6-Core-0923-01` | **164 passed, 1 failed** | New language/statistics, inference/cache, weighting, radio, typed search persistence/sync, retention, local filtering and queue snapshot tests. The failure expected an ordinary forced resolution to upgrade a valid AAC cache; the fixture now separately tests cache-first reuse, cooldown behavior and explicit quality refresh |
| `R6-Integration-0923-01` | **132 passed, 0 failed/skipped** | App models, recovery/cloud, Search selection, cached inventory and native offline AAC/Opus playback, including forbidden-network dependencies |
| `R6-Unit-0923-01` | **1488 passed, 18 failed, 35 skipped** | Full phone unit target excluding native StoreKit and the pending cache-fixture correction. Cached accessibility metadata read an uninstalled SwiftUI environment in pure tests; moved that decoration into the rendered body. Radio failures exposed legacy language assumptions and unserved style requests; a cold cue-only fallback also received bounded recovery |
| `R6-Build-0923-04`, `R6-Build-0923-05` | Passed | Integrated continuity corrections, offline occurrence traversal, typed Search navigation and native cache-search dismissal |
| `R6-Unit-0923-02` | **1531 passed, 1 failed, 35 skipped** of 1567 | Full phone unit target excluding native `TipJarStoreKitTests`. The failure compared a constructed mix date with its serialized value; the fixture now captures the durably saved baseline before testing stale publication |
| `R6-Mix-Date-0923-01` | **8 passed, 0 failed/skipped** | Entire `AppModelMixTests` suite with the persisted-date baseline, retaining exact mix equality, stale-generation, dislike and period-stability assertions |
| `R6-UI-Initial-0923-01` | **1 passed, 2 failed** | Library-led blank Search passed. Cached filtered playback reached a local file with zero network requests, but active native Search hid Back/Done; playback now dismisses Search after capturing the queue. All six Settings description-gap checks completed before whole-app query/scroll overhead exhausted the allowance; the test now scopes lookup and bounded scrolling to `settings.form` |
| `R6-UI-Workflows-0923-01` | **5 passed, 3 failed** | Settings spacing, complete-cache removal/relaunch, filtered offline playback, all four typed recent kinds/removal/relaunch, and root Search reselection passed. A local search field exposed a 19.7-point editor inside its 48-point frame; the frame now has matching interaction/accessibility shapes. Language-menu verification hit its time allowance through repeated global queries. Queue Save's test queried duplicate menus in the visible Queue and underlying playlist; selectors are scoped, and its label's actual 44-point frame is enforced |
| `R6-IPad-0923-01` | **3 passed, 0 failed/skipped** | iPad Pro 13, iOS 26.5: centered language statistics/native adjustments in light appearance, library-led blank Search in dark appearance, and actual cached playback without network access |
| `R6-Build-0923-06`, `R6-Build-0923-07` | Passed | Integrated native local-search hit regions, Queue Save's 48-point plain toolbar image and scoped UI helpers |
| `R6-UI-Finish-0923-01` | **7 passed, 2 failed** | Language adjustments/reset/relaunch, language-free Welcome/radio, Find music and Search all music navigation, local autofocus from Search, and largest-text Search/library controls passed. Playlist playback's helper tried to pause already paused audio; it now distinguishes paused from playing state. Queue Save exposed a 41.33-point toolbar target; its image has an explicit 48-point interaction/accessibility shape |
| `R6-UI-Last-0923-01` | **1 passed, 1 failed** | Filtered playlist Play/Shuffle/clear passed. Queue Save verified its restored queue/modes before global accessibility traversal exhausted 240 seconds while closing the player; the test now reads scoped snapshots and uses direct dismissal controls |
| `R6-QueueFinal-0923-01` | **1 passed, 0 failed/skipped** | Queue Save completed in 68.8 seconds with the same time allowance. Verifies captured current/upcoming order, deduplication only in the new playlist, unchanged queue occurrences/repeat/shuffle/nonzero paused position, and exactly one additional playlist after relaunch |
| `R6-Release-0923-01`, `R6-Release-0923-02` | Passed, **0 errors / 14 warnings** each | Signed local Release archives with embedded Watch; vendor/navigation and release-eliminated test-branch warnings. The second archive includes the final production toolbar change |
| `R6-Release-Audit-Final-01.log` | Passed | Audit of `R6-Release-0923-02.xcarchive`: identity/version, arm64 phone/iPad support, deep signature, dependency notices and absent DEBUG fixtures/StoreKit catalog |
| `R6-SmallPhone-0923-01` | **3 passed, 0 failed/skipped** | iPhone SE 3, largest accessibility text: local library search, all five native language menus with a real adjustment, and Search/recent controls. Screenshot inspection caught a heading defect outside the hit-target assertions: Recently opened split mid-word beside Clear all. Accessibility sizes now stack the full-width heading above its action |
| `R6-SmallPhone-0923-02` | **1 passed, 0 failed/skipped** | Rebuilt the adaptive heading and reran the small-phone Search workflow. The inspected capture shows natural word wrapping and a separate Clear all action; native search, recent-item and 44-point control assertions still pass |
| `R6-Release-0923-03`, `R6-Release-Audit-Final-02.log` | Archive and audit passed, **0 errors / 14 warnings** | Final production source, including the accessible recents heading. Signed local archive with embedded Watch; deep signature, fixture/catalog exclusion and dependency-notice checks passed. Phone/Watch entitlements were inspected separately |

The full unit run covers all 28 `OfflinePlaybackTests`, including missing-middle-song skipping, occurrence/repeat preservation, native reader retention, failed/unknown inventory, and reconnect preparation without autoplaying paused or failed intent. The nine `AppModelOfflineContinuityTests` cover accepted versus rejected offline selection, initial path notification, stale responses, cached queue filtering and removal/snapshot races. Language statistics are derived from qualified sessions; nudges and typed Search selections are exercised through actual local serialization and isolated replica merges.

All **1532 eligible phone unit cases have passing coverage across the full run and focused test-fixture correction**. This is not one all-green full-suite bundle. The 35 skips are opt-in live checks; native StoreKit remains excluded.

All **15 selected iPhone 17 Pro workflows, three iPhone SE 3 checks and three iPad workflows have passing coverage across these runs**. The full UI suite was not run. Dark/light Search, typed recents, Settings and language-menu captures were inspected, including the iPad's centered layout and largest-text small-phone captures. The offline workflow checks a real local playback source and zero network attempts. These are DEBUG QA fixtures, not replacement marketing screenshots.

The final production source is archived at `artifacts/R6-Release-0923-03.xcarchive`. R6 archives are development-signed with `get-task-allow=true`. The phone entitlements contain the exact `iCloud.com.agraabhi.ganabajana` CloudDocuments/ubiquity containers and no CarPlay entitlement. Separately inspected embedded Watch identity is `com.agraabhi.ganabajana.watchkitapp`, version/build 1.0.0/3, minimum watchOS 11; its entitlements request neither iCloud nor CarPlay. These are local Release checks, not an App Store export or upload. Physical airplane-mode transitions, VoiceOver speech, receivers, accounts and StoreKit transactions remain separate acceptance boundaries.

Whitespace, shell syntax, ASC/IAP JSON and privacy/entitlement-plist checks passed. Completed run bundles and capture manifests remain under `artifacts/`; the final small-phone Search capture is in `R6-SmallPhone-02-attachments/`.

## App Store preparation: 1.0.0 (3)

The working-tree build after R5 is archived, App Store-signed, Apple-validated and uploaded. Build `567a0b14-bbc9-43d1-92a8-4ba99764f8de` is `VALID` / `APP_STORE_ELIGIBLE` and attached to iOS version `2754a299-5b46-4e62-8f79-8bf80c6078d5`. Source remains uncommitted after `ebb5d5c`. All paths in this section are under `artifacts/AppStore-1.0.0-3/`.

| Run / artifact | Result | Scope |
| --- | --- | --- |
| `BuildForTesting.xcresult` | Passed, 0 errors/warnings | Version/build confirmed as 1.0.0 (3); DEBUG-only native iCloud host guard and Home masthead hit shapes |
| `unit.xcresult` | **35 passed, 0 failed/skipped** | `ICloudLibrarySyncTests`, `LibrarySyncTransportTests`, `AppModelCloudSyncTests` |
| `iphone-shots.xcresult` | **6 passed** | Real, unseeded radio/setup, icons, Home choices, iCloud waiting and empty Library on iPhone 17 Pro Max / iOS 26.5 |
| `ipad-shots.xcresult` | **6 passed** | Same workflows on iPad Pro 13 / iOS 26.5 |
| `FramingBuild.xcresult`, `ipad-radio.xcresult` | Build passed; **2 captures passed** | Keep the iPad Search at its top so a suggestion row is not clipped; only the first two delivered iPad images are replaced |
| `WatchBuildForTesting.xcresult` | Passed, 0 errors, 14 warnings | Separate Watch build-for-testing; vendor/deprecation, asset-trait and existing test-clock warnings |
| `watch-shots.xcresult` | **1 passed** | Real paired-simulator WatchConnectivity confirms empty playback and actual Library folders on Watch SE 3 44 mm; no seeded transport or media |
| `iap-shots-ios27-02.xcresult` | **1 passed, 0 skipped** | Native StoreKit returned all five product rows with $3/$5/$10/$25/$50 USA prices; no purchase |
| `Archive.xcresult` | Passed, **0 errors, 13 warnings** | Signed Release with embedded Watch; existing vendor/deprecation and release-eliminated debug-branch warnings |
| `archive-audit.json`, `ipa-inspection.json` | Passed | Identity/build, iPhone/iPad support/orientations, signatures, notices, absent fixtures/StoreKit catalog, exact distribution profiles and Production iCloud container |
| `apple-validation.log` | `VERIFY SUCCEEDED with no errors` | Apple altool validation of the exported App Store IPA |
| `store-final-readback-1790128322101863000/summary.json` | Valid build attached; remote IPA MD5 matches | 14 store images complete and ordered, five IAPs ready, no review submission |

The IPA is **13,772,173 bytes**, SHA-256 `d30e6eff1adc4d0264d68dbbe98129a1f9d7064e7876bf057e7c4dfc35c8d0c1`. Its remote file MD5 is `a7f59de079e8490eeb8cad3f3a0aff90`, matching the local artifact. The phone's signed entitlements contain `iCloud.com.agraabhi.ganabajana`, `CloudDocuments` and `Production`; phone/Watch both have `get-task-allow=false` and no CarPlay entitlement. Manual export used existing certificate `YBW79S2M2T` and new app-specific profiles. The temporary signing keychain was removed, with the original search list/default verified restored.

Capture manifests link raw attachments to final RGB PNGs and device/test metadata. RGB pixels, dimensions and ICC profiles were preserved. Final phone/iPad images were inspected, as were both Watch images and the IAP screen. The Watch helper's raw filename prefix retained a historical 40 mm label; its device ID, native 368 × 448 pixels and provenance identify the actual 44 mm simulator. The helper is corrected for subsequent runs. [SCREENSHOTS.md](app-store/SCREENSHOTS.md) records the delivered set and IDs.

Execution corrections were limited to capture/release tooling: a `#if DEBUG` guard keeps native test-host switches out of Release; the initial IAP background launch rejected a dash-prefixed suffix before running tests; argument forwarding was corrected. StoreKit on iOS 27 logged `SKServiceErrorDomain Code=2` with underlying configuration/override errors, but all actual product rows loaded and the capture passed. The native transaction suite and sandbox purchase/refund flows were not rerun or established by that result.

Apple validation left an `AWAITING_UPLOAD` reservation containing only analysis/description files. The upload guard stopped on its build number. After verifying the exact reservation, timestamp, file IDs/types and absence of an IPA, that owned validation reservation was removed; the unchanged IPA was uploaded through `asc`. The upload-time checksum option had no initial API checksum, so integrity was verified afterward against the completed remote file. The first review-details read omitted a false boolean in CLI JSON; an authenticated raw API read verified `demoAccountRequired=false` without recreating the details.

Readiness is not all-green: **25 blockers** are 24 missing age-rating answers and missing content rights. Six warnings cover five intentionally unsubmitted products and the expired Apple web session. Deep availability/review-field checks passed; App Privacy and agreements remain unverified, along with the tool's generic subscription probe. Provider authorization and public FFmpeg source/relink delivery remain submission holds. Native two-device iCloud, real AirPlay receivers, transaction acceptance, physical hardware and VoiceOver remain outside these checks.

## Previous round: default-on sync, Settings, player navigation and play counts

R5 enables iCloud by default for an absent device configuration, preserves saved opt-outs, adds a green enabled icon and reorganizes Settings into six sections. The player combines album/artist navigation and exposes native AirPlay in the bottom row. Artist headers use 90% of their prior responsive artwork size. Song totals retain provider plays instead of substituting upload views. Xcode 27, iPhone 17 Pro and iPad Pro 13 on iOS 26.5; changes remain uncommitted.

| Run | Recorded result | Scope / resolution |
| --- | --- | --- |
| `R5-Build-0922-174247` | Build failed | AVKit's imported route delegate needed an explicitly main-actor-isolated conformance |
| `R5-Build-0922-174411` | Build-for-testing passed, 0 errors | Corrected conformance; phone app and unit/UI targets |
| `R5-Unit-0922-174533` | **1285 passed, 0 failed, 35 skipped** of 1320 | Full phone unit target, native `TipJarStoreKitTests` excluded; skips are opt-in live suites |
| `R5-iPad-0922-174742` | **2 UI tests passed, 1 skipped** | Portrait/landscape screens, combined chooser, visible native AirPlay target and ordered controls. System route chooser was not exposed by this simulator |
| `R5-iPhone-0922-175146` | **18 UI tests passed, 1 failed, 1 skipped** | Default-on/opt-out persistence, Settings navigation, compact switches/icons, immediate artist choices/photos, combined navigation and AirPlay geometry. One largest-text landscape test used a scroll-indicator inset as a content boundary; actual sheet rows were fully visible. Native route chooser check skipped |
| `R5-BrowseBuild-0922-181843` | Build-for-testing passed | The landscape assertion uses actual sheet/navigation/window bounds and tests artist selection; row-size and full-visibility requirements remain |
| `R5-BrowseRetry-0922-181913` | **4 UI tests passed** | All combined-chooser workflows, including largest-text landscape, album navigation, six-credit scrolling and playback continuity |
| `R5-Release-0922-182633` | **Signed Release build passed, 0 errors, 4 warnings** | Phone with embedded Watch; deep/strict signature verification passed. Signed iCloud container and CloudDocuments entitlements inspected. Development-signed local build, not an archive/export |

All 19 non-skipped targeted iPhone workflows have passing coverage across the initial run and the focused correction. The iPad run passed two checks and skipped its native route-chooser check. iPhone captures are in `artifacts/R5-iPhone-Captures/` and `artifacts/R5-BrowseRetry-Captures/`; iPad captures are in `artifacts/R5-iPad-Captures/`. The green/disabled cloud states, Settings grouping, smaller artist header, combined chooser and final largest-text landscape capture were inspected. These are QA fixtures, including original bundled artwork in place of provider pictures, not a cleared App Store marketing set. Whitespace, shell syntax and entitlement-plist checks passed.

The play-count investigation compared the provider's `1.2B plays` for Tum Hi Ho with `200,574,245` views on its audio upload and `330,833` on a compilation upload. Strict complete-label parsing and validated track-credits recovery are covered by the new parser/service/controller cases in the full unit run. A separate real-catalog Search launch displayed `1.2B plays` on both returned Arijit Singh recordings; `artifacts/R5-Live-Search-PlayCounts.png` records that inspected UI state without seeded catalog data. No extra per-song requests were introduced. [PROVIDERS.md](PROVIDERS.md#song-play-counts) records scope, approximation and legacy-snapshot limits.

At R5 closeout, native two-device iCloud delivery, an actual AirPlay receiver, StoreKit/sandbox and physical-device acceptance remained unverified. The later build-3 preparation above adds native product-display and store-delivery evidence without claiming transaction or hardware acceptance.

## Previous round: iCloud sync and collection presentation

R4 adds opt-in iCloud Drive library sync, asynchronous player artist pictures, grouped Automix/Crossfade defaults, animated Search reselection, larger collection covers, artwork backdrops and song durations. Xcode 27, iPhone 17 Pro / iOS 26.5; changes remain uncommitted. [ICLOUD_SYNC.md](ICLOUD_SYNC.md) owns the sync contract and native-device limits.

| Run | Recorded result | Scope / resolution |
| --- | --- | --- |
| `R4-Build-0922-153920` | Build-for-testing succeeded | Swift 6 app and test targets |
| `R4-Core-0922-153941` | 71 passed, 92 failed | Initial 163-case focused run. The bounded file reader handled only one Foundation missing-file error, preventing new stores; subsequent failures followed from that |
| `R4-SyncFix-0922-154219` | 111 passed, 3 failed | Missing-file handling fixed. Remaining failures covered recovery after replacing a library file with a directory |
| `R4-SyncIO-0922-154325` | 13 passed, 4 failed | File-type validation exposed cached URL metadata on retry |
| `R4-SyncRecovery-0922-154455` | 17 passed | Refresh resource metadata and reject non-files; all selected recovery cases passed |
| `R4-Unit-0922-154635` | Build failed before tests | A DEBUG artwork fixture used the wrong Swift initializer argument order; corrected |
| `R4-Unit-0922-154659` | **1258 passed, 1 failed, 35 skipped** of 1294 | Full phone unit target excluding native `TipJarStoreKitTests`. Only failure: an old-library cache-limit fixture removed a preference while retaining the new-format journal |
| `R4-FinalFocused-0922-155352` | **74 passed** | Correctly versioned v1 fixture plus cache settings, model integration, sync journal/merge/history/checkpoints and controller lifecycle tests |
| `R4-iCloud-Signing-0922-155235` | **Signed Debug device build passed** | Phone with embedded Watch. Deep/strict signature verification passed; both signed phone entitlements and its profile contain `iCloud.com.agraabhi.ganabajana` with CloudDocuments support |
| `R4-iPhone-0922-155422` | **16 UI tests passed** | Collection album/mix/playlist lengths and footer layout, largest text, immediate/delayed/absent/loaded artist pictures, iCloud toggle persistence, transition defaults/grouping, icon selection and compact switches, Search reselection/query preservation |
| `R4-iPad-0922-160920` | **1 UI test passed** | iPad Pro 13 album header, known song durations and bottom summary, using deterministic artwork |
| `R4-ArtistMix-0922-160920` | **4 UI tests passed** | Featuring playback, artist popular-song mixes, language filtering and correction/undo after enabling durations in artist-mix rows |
| `R4-Release-0922-162005` | **Signed Release build passed, 0 errors** | Final phone source with embedded Watch and iCloud entitlements; deep/strict signature verification passed. Development-signed build only, no archive/export |
| `R4-Chrome-0922-162200`, `R4-iPadChrome-0922-162200` | **1 UI test passed in each** | Light-mode mix and iPad album after adding a material navigation background for readable status/navigation text over dark covers |

Every non-skipped phone unit case has passing coverage across the full run and focused correction. The 35 skips are opt-in live suites. This is coverage across runs, not one entirely green full-suite bundle. The new sync tests use isolated stores and fake transports; they do not establish native upload or two-device delivery. The signed Debug/Release products are local builds, not new archives/exports.

The 20 distinct targeted iPhone workflows and the iPad album workflow passed. Captures are in `artifacts/R4-iPhone-Captures/`, `artifacts/R4-iPad-Captures/`, `artifacts/R4-Chrome-Captures/` and `artifacts/R4-iPadChrome-Captures/`, with manifests identifying each workflow. Artwork, artist rows, duration/footer placement, large-text rows, Settings and final navigation contrast were inspected. Deterministic artwork uses bundled original icon art through a DEBUG-only URL protocol for `breezy-artwork.invalid`; it tests rendering without requesting real provider pictures. Delayed artist fixtures keep metadata pending to test immediate row selection. These hooks require explicit fixture flags and are excluded from Release. Native cross-device iCloud propagation, physical devices, and actual VoiceOver speech remain outside these checks. `git diff --check`, shell syntax and entitlement-plist checks passed.

## Previous round: player redesign, radio, autoplay, artist collaborations, icons, iPad and Mac

This round removed the automatic foreground player presentation (it never existed at `ebb5d5c`), moved Shuffle and Repeat into the Queue sheet, compacted lyric timing, made the artist picker content-sized, unified sheet chrome, rebuilt the radio catalog as 34 search-driven stations startable in any language, made Autoplay retry with bounded fallbacks and a queue-sheet retry, added a Featuring section to artist pages, cut the icon catalog to seven visible choices with a redesigned Sonnet, compressed Settings, and enabled iPad (device family 1,2, all four orientations) plus Mac through Designed for iPad. Changes remain uncommitted after `ebb5d5c`. Xcode 27.0, iPhone 17 Pro on iOS 26.5 (`B1EE1D9A-124A-4788-9760-5C5668E19078`), a new **GanaBajana QA iPad Pro 13** on iOS 26.5 (`EED2BCA0-6755-4DA8-82B5-A997CE61561A`), and Watch SE 3 40 mm on watchOS 26.5. Result bundles are `artifacts/R3-*.xcresult`; earlier-round bundles remain for history. Across `R3-UI-iPhone-0922-0254`, `R3-UI-Rerun`, `R3-UI-Artist5`, `R3-UI-Final`, and `R3-UI-Radio2`, every phone UI test outside live and native StoreKit scope has a passing run on the final source; this is coverage across reruns, not one green full run.

| Run | Recorded result | Scope / resolution |
| --- | --- | --- |
| `R3-Unit-0922-0047` | **1131 passed, 9 failed, 35 skipped** of 1175 phone unit tests | Full unit target minus nothing. Eight failures are the known native StoreKit environment cases in `TipJarStoreKitTests` (`SKInternalErrorDomain`/`notEntitled`, excluded scope). One real failure: `RadioSetupModelTests` still expected the old language narrowing; the expectation was corrected to the new default (all discovery languages) |
| `R3-UnitRadioFix-0922-*` | **26 passed** | `RadioSetupModelTests` and `ExperienceRadioModelTests` after the correction |
| `R3-UnitFollowups-0922-*` | **188 passed, 1 failed** of 189 | Autoplay, playback, app model, artist spotlight, companion and radio setup suites after the review follow-ups. The failure was a new test's timing assumption: after a manual retry appends a song, that song asks for its own continuation, so `isContinuingAutoplay` is legitimately true until that request is answered |
| `R3-UnitRetry2-0922-*` | **43 passed** | `AppModelTests` with the corrected expectation |
| `R3-WatchUnit-0922-*` | **31 passed** | Native watchOS model and shared wire tests, unchanged by this round |
| `R3-UI-iPhone-0922-0254` | **79 passed, 10 failed** of 89 UI tests | Full phone UI target except live and native StoreKit UI. Four failures were `GanaBajanaTipJarUITests` (native StoreKit environment). Three landscape failures came from running without `TEST_RUNNER_GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1`. Three real failures below |
| `R3-UI-Rerun-0922-0521` | **5 passed, 1 failed** | With the geometry opt-in: the three landscape workflows and the Accent workflow passed; the radio discovery test passed after its copy expectation matched the grouped station description; the artist Featuring workflow still hung |
| `R3-Diag-*` | investigation | A throwaway diagnostic UI test measured accessibility snapshots per step and `sample` captured the main thread. The artist page pinned the main thread in `LazyVStackLayout.sizeThatFits` re-measurement after the player was dismissed and the page scrolled while playing. Bisecting showed the loop required the new Featuring section inside the page's lazy stack |
| `R3-UI-Artist5-0922-0742` | **10 passed** | Artist spotlight, album description, language correction, and mini-player progress suites after `CollectionDetailView` switched to plain stacks (row counts are capped, so laziness was not needed) |
| `R3-iPad-Layout-0922-*` | **1 passed** | New `GanaBajanaIPadLayoutUITests` on the iPad Pro 13 simulator: Home, Search grid (3 columns), Library, Recap, mini-player column cap (640 pt), player, Queue sheet and artist picker in portrait, then player, Home and Search in landscape. Captures under `artifacts/R3-iPad-Layout-Captures/`. The first iPad player capture showed a bottom-aligned side-by-side layout in portrait; regular-width portrait now keeps the stacked layout, centered, with a 620-point column |
| `R3-MacDesignedForIPad-Unsigned-0922-*` | **Build succeeded** | Debug build for `platform=macOS,variant=Designed for iPad` with `CODE_SIGNING_ALLOWED=NO`. The signed variant failed only because the owner's development profile does not include this Mac; no Mac run was performed |
| `R3-UI-Final-0922-0757` | **74 passed, 1 failed** of 75 | Remaining phone UI suites (Workflow, Refinement, SearchDiscovery, CompactControls, Accent, Feedback, HomeCustomization, NavigationIntent, Storage, UITests) with the geometry opt-in after all fixes. The failure was the new Hindi-only Melancholy workflow exceeding its 8-minute allowance while iPad builds and tests were running on the same Mac |
| `R3-UI-Radio1-0922-0946` | **1 passed** | The Hindi-only Melancholy workflow alone |
| `R3-UI-Radio2-0922-1029` | **19 passed** | The complete `GanaBajanaSearchDiscoveryUITests` suite without concurrent builds |
| `R3-UnitFinal-0922-*` | **1139 passed, 0 failed, 35 skipped** of 1174 | Full phone unit target on the final source, excluding `TipJarStoreKitTests` (native StoreKit environment). Skips are the opt-in live suites |

### Corrections made during this round

- Result bundle names must be unique per run: `xcodebuild` silently keeps an existing bundle, and an early read of a stale `Round3-Unit-01` bundle showed 398 tests from a two-day-old run. All current evidence uses `R3-<label>-<MMDD-HHMM>` names.
- Full phone UI runs exceed two hours; they are launched detached with `-test-timeouts-enabled YES -default-test-execution-time-allowance 480`.
- The artist page's Featuring section, as a `LazyVStack` nested in the page's `LazyVStack`, made SwiftUI re-measure the page endlessly once the player had been dismissed and the page scrolled during playback. Both nested stacks and the page stack are plain `VStack`s now; visible rows stay capped at 30 (songs) and 15 (collaborations) with Show more.
- The Queue sheet's "Try more songs" retry carries its 44-point minimum on the label and content shape, not the outer button frame.
- Settings rows use 6-point vertical insets so descriptions are not padded twice by the inset-grouped list; toggles keep their own 44-point frames.
- Search's title and field share the content column so regular widths do not stretch the header alone.
- The iPad tab bar renders as plain `tab.*` buttons at the top, not a `TabBar`; the shared iPhone driver's launch readiness (`tabBars.buttons["Home"]`) and bottom-tab-bar viewport helpers do not apply on iPad, so the iPad suite launches and taps directly.

## Earlier companion and player changes (historical)

That round added reversed pen artwork, attributed album descriptions, mini-player background progress, an automatic foreground presentation (since removed), a watchOS companion, and native CarPlay browsing. These changes remain uncommitted after `ebb5d5c`. Verification used Xcode 27, iPhone 17 Pro on iOS 26.5, and a paired Watch SE 3 40 mm on watchOS 26.5. Result bundles and captures are under `artifacts/`.

| Run | Recorded result | Scope / resolution |
| --- | --- | --- |
| `Breezy-Companions-Unit-02` | **201 passed, 1 failed**, 202 selected phone tests | Album parsing/loading, 20 tests for the since-removed automatic presentation (deleted with the feature), shared bridge/codec, Watch transport, CarPlay templates/navigation/native playback. The only failure was a trailing-slash license URL parsed by Foundation into its canonical base path |
| `Breezy-Album-Verification-01` | **71 passed** | Corrected license path recognition, all album parser cases, existing catalog parsing/service regressions, and a live case verifying Graduation and Aashiqui 2 with genuine Wikipedia links and supplied licenses |
| `Breezy-Watch-Unit-02` | **31 passed** | Native watchOS model and shared wire-contract tests |
| `Breezy-Phone-Experience-UI-01` | **9 passed, 3 failed** | Four album, two mini-player, and six activation workflows (the activation feature and its tests were later removed). Retry accessibility and two foreground-geometry checks were corrected below |
| `Breezy-Phone-Experience-UI-Fixes-02` | **3 passed** | All three failed phone workflows; Retry retains a native 44-point target, and immediate player-readiness checks precede system-animation geometry settling |
| `Breezy-Watch-UI-01` | **4 passed, 2 failed** | Six native fixture workflows. The two failures were scroll-driver reachability checks for a library-error panel and long song row |
| `Breezy-Watch-UI-Fixes-02` | **3 passed** | Both failed workflows plus transport/favorite flow. Main controls are now before progress and asserted fully visible before scrolling on the 40 mm screen |
| `Breezy-Watch-Connectivity-01` | **1 failed** | Test installation restarted the phone without its isolated fixture launch arguments; the expected paused fixture queue was absent |
| `Breezy-Watch-Connectivity-02` | **1 passed** | Real `WCSession` request/reply between paired simulators: Play on iPhone, Next from Tum Hi Ho to Kesariya, then Pause. The phone used isolated fixture audio/catalog; the Watch used its real transport |
| `Breezy-Companions-Release-02` | **Build succeeded** | Unsigned generic-iOS Release including embedded Watch arm64/arm64_32, before CarPlay entitlement opt-in was separated |
| `Breezy-Standard-Signing-01` | **Signed build succeeded** | Standard Debug device build after the signing fix, including embedded Watch. Deep/strict code-signature validation passed; neither signed app contains the managed CarPlay entitlement |

All **12 selected phone UI workflows (six of them for the later-removed activation feature) and six Watch fixture workflows had passing coverage across these runs**, plus the separate real-connectivity case. This is not a new full unit/UI suite run. Native StoreKit, unrelated live suites, and physical-device acceptance were outside this selected scope.

### Integration corrections

- CarPlay's imported audio callback is `templateApplicationScene(_:didDisconnectInterfaceController:)`; a native Objective-C selector regression verifies connect/disconnect exposure. List callbacks keep their non-Sendable completion on the original stack while entering the main actor synchronously.
- The album Retry button inherited its containing HStack's identifier. Giving the row a containing accessibility element restores the distinct error group and exact native Retry identifier.
- (Historical; feature removed.) Foreground player existence, uniqueness and hittability were checked immediately, with width comparisons on one atomic accessibility snapshot.
- Watch scrolling uses clipped edges and observed frame movement, settles native List scaling, and falls back to a native swipe if Crown rotation stalls. Full visibility, hittability and 44-point target assertions remain.
- Real Watch Connectivity setup starts the isolated phone fixture after the Watch test app launches because Xcode installation can replace the earlier phone process. No production library is used for the fixture test.
- Putting the managed CarPlay entitlement in the default configurations blocked the owner's automatic provisioning. Debug/Release now have no custom entitlement file; only Debug-CarPlay/Release-CarPlay select `Signing/CarPlay.entitlements`. All four configurations were inspected for both app targets. The standard signed build then passed without provisioning-update flags. The opt-in CarPlay scheme still requires Apple's App ID/profile approval.

### Current captures and limits

- `rose-pen-reversed-contact-sheet.png`: the three accepted rose designs with nibs pointing lower-left; icon/preview sizes and RGB/no-alpha format verified.
- `Breezy-Phone-Experience-UI-01-Captures/`: full-height mini-player progress at 0/50/90%, backwards seek and track reset, in dark and largest-text light appearances; album preview/attribution.
- `Breezy-Phone-Experience-UI-Fixes-02-Captures/`: foreground playing/paused sessions, swipe minimization and paused cold restoration.
- `Breezy-Watch-UI-Fixes-02-Captures/`: first-screen transport, Crown/long-row selection, playback options, and distinct loading/library/empty states.
- `Breezy-Watch-Connectivity-02-Captures/`: acknowledgements from the actual paired iPhone process using local fixture audio.

The paired simulators are `B1EE1D9A-124A-4788-9760-5C5668E19078` and `271517F2-1471-426C-B2BD-B0E265AD1EFC`, pair `2BB16DED-737B-446D-AA12-09D3D29DB63D`. Physical Watch suspension/wake, audible fidelity, Lock Screen first-visible-frame timing, and native CarPlay head-unit behavior remain unverified. The signed Debug product is a local build, not a new archive, IPA, or upload. Prior signed release artifacts below are historical.

## Current refinements after `ebb5d5c`

This earlier refinement round added compact switches, optional artist-language browsing, stronger recording-language inference and exact linked-work lookup, foreground player presentation, and the Thorn/Sonnet/Copper icon choices. Its evidence predates the companion changes above. These changes are **not in the historical signed archive/IPA below**. Verification used iPhone 17 Pro / iOS 26.5; no commit, upload or new distribution export was performed for this round.

| Scope | Completed evidence | Result |
| --- | --- | --- |
| Full unit target | `Breezy-Refinements-Unit-Final-02.xcresult` | **929 passed, 1 failed, 33 skipped**; native StoreKit excluded. The only failure was a new native-recognizer fixture that incorrectly assumed high English confidence |
| Final classifier regression suite | `Breezy-Refinements-Language-Final-04.xcresult` | **36 passed**. Sparse English acceptance and low-confidence repetitive text are separate cases; uncertainty is not forced to English |
| Initial focused UI and playback regression | `Breezy-Refinements-UI-01.xcresult` | **10 passed, 4 failed**, comprising 13 UI cases and one existing playback unit. The failures were corrected in the runs below |
| Classifier correction and Search URL return | `Breezy-Refinements-Fixes-01.xcresult` | **20 passed, 4 failed**. All 19 classifier cases and Search URL precedence passed; four switch workflows still failed on virtual-child targeting at this point |
| Final compact controls | `Breezy-Compact-Switch-03.xcresult` | **4 passed**: Settings persistence, discovery-language minimum selection and Home reordering, largest Dynamic Type, radio language validation/cancellation |
| Final artist UI and visual inspection | `Breezy-Refinements-Artist-Visual-02.xcresult` | **3 passed**: popularity/filtered playback, opt-in correction, and correction persistence/clear; default and expanded browser screenshots inspected |
| Live recording-language evidence | `Breezy-Refinements-Language-08.xcresult` | **All 4 live cases passed**: Kanye West's All Falls Down (feat. Syleena Johnson), Radiohead's No Surprises, Hindi/transliteration not classified English, and an exact MusicBrainz recording/work contract. The combined unit/live bundle was 38 passes and the native fixture failure resolved above |
| Release compilation | `Breezy-Refinements-Release-02.xcresult` | **Passed**, unsigned generic-iPhone build with the final production code and all 18 app-icon sets |

All **13 targeted UI workflows** have passing coverage across the focused runs: four compact-control/icon cases, two artist-browser cases, one persistent correction case, five playback-activation cases, and one radio setup case. This is not a new full fixture-suite run. The first broader unit attempt had one existing playback cancellation failure; that unchanged playback case passed its focused rerun and the later full unit run.

### Corrections established by execution

- A root-level Toggle style did not reach the Settings sheet. The shared 0.8-scale native visual is applied at all four Toggle call sites instead. The 44-point row remains actionable, including disabled rules and native accessibility values. The UI driver selects a nested native switch only when reachable; virtual zero-sized children use the visible switch row and retain post-tap value checks.
- `XCUIApplication.open` relaunched the test app with `--reset-ui`, erasing its isolated playback store. The Search-priority test now uses `XCUIDevice.shared.system.open`, which delivers the real URL through the system to the running application. All five activation UI workflows passed.
- A capture rerun exposed the existing destination-layout race in the artist test: its owning scroll viewport was temporarily infinite/empty. `reveal` now waits for that actual viewport to become finite before its normal reachability checks and scrolling. All three artist/correction UI cases passed the follow-up.
- Live Kanye lyrics revealed two false-negative mechanisms: an eight-word line with one lexical anchor despite English confidence **0.984767**, and an arbitrary normalized 40-word span with English confidence **0.4747** while original nearby text was strongly English. The final classifier preserves original punctuation/line context, uses overlapping 40-word windows, and permits one bounded 80-word context retry only when the core already has lexical/script evidence and no confident foreign signal. Independent foreign-segment vetoes remain ahead of these fallbacks.
- The initial rap fixture omitted the provider's featured-artist title clause; it now requests the actual **All Falls Down (feat. Syleena Johnson)** metadata. The strict live English assertion remains. A separate synthetic repetitive-pronoun example did not meet native confidence requirements; the final tests explicitly verify its unclassified outcome rather than changing production thresholds to force a result.

The changes received independent source review. The discovered single-foreign-segment conflict-veto issue was fixed and re-reviewed. Physical Lock Screen/Notification Center taps, native VoiceOver speech and deferred smaller/physical devices remain outside this simulator evidence. Recording-language results do not establish whole-catalog accuracy or a measured coverage gain from the conditional full-work fetch.

### Current visual evidence

- `artifacts/rose-pen-contact-sheet.png`: three original pen/rose options; 17 visible icon choices total. New 1024-pixel icons and 240-pixel previews passed RGB/no-alpha validation. UI selected all three, persisted Copper, and restored Leafnote.
- `artifacts/Breezy-Compact-Switch-03-Screenshots/`: inspected compact Settings, discovery-language, Home and radio switches; largest-text capture included.
- `artifacts/Breezy-Player-Activation-Screenshots/`: historical captures of the removed automatic presentation.
- `artifacts/Breezy-Refinements-Artist-Visual-02-Screenshots/`: the clean default song list, expanded language browser and correction workflow.

Use `ArtistSpotlightLanguageTests`, `ArtistSpotlightLanguageServiceTests`, `ArtistSpotlightMultiSignalTests`, `ArtistSpotlightMusicBrainzWorkTests`, `ArtistSpotlightLanguagePresentationTests`, `AppIconsTests`, `AdaptiveLayoutTests`, `PlaybackAutoplayContinuationTests`, `RadioConfigurationTests`, `ExperienceRadioEngineTests` and `ArtistSpotlightLoaderTests` for focused unit runs. The opt-in `GanaBajanaLive` selector is `GanaBajanaTests/ArtistSpotlightLanguageLiveTests`. UI selectors are `GanaBajanaCompactControlsUITests`, `GanaBajanaArtistSpotlightUITests`, `GanaBajanaLanguageCorrectionUITests`, `GanaBajanaSearchDiscoveryUITests`, and, on an iPad simulator, `GanaBajanaIPadLayoutUITests`.

## Historical signed candidate before these refinements

**Breezy 1.0.0 (2)**, verified on 21 September 2026 using Xcode 27 and the **GanaBajana QA iPhone 17 Pro**, iOS **26.5 (23F77)**, simulator `B1EE1D9A-124A-4788-9760-5C5668E19078`. Smaller-screen and physical-device acceptance remain deferred by the owner.

All result bundles below are under `artifacts/`. Counts describe completed runs, including their exclusions. Five independent source reviewers cleared the original findings and follow-ups; [REVIEW_FINDINGS.md](REVIEW_FINDINGS.md) maps fixes to coverage.

| Check | Completed result | Evidence |
| --- | --- | --- |
| App unit target, including local native audio, persistence, account, networking and recommendations | **869 passed, 0 failed, 28 skipped**; native `TipJarStoreKitTests` excluded | `Breezy-Unit-Review-04.xcresult` |
| Fixture UI | **65 passed, 7 failed** in the full 72-case run; all seven failures and five related cases passed in the **12/12** follow-up | `Breezy-UI-Review-01.xcresult`, `Breezy-UI-Review-Fixes-01.xcresult` |
| Focused integration and Home | **14 passed**: nine artwork cancellation cases, two library recovery/playback cases, two radio retry cases, one Home workflow | `Breezy-Review-Focused-01.xcresult` |
| Vendored YouTubeKit transport/security | **38 XCTest cases passed** on macOS: 15 bounded reception, 12 extraction integration, two cookie isolation, four chunk arithmetic, five solver diagnostics | Native `swift test` console result; SwiftPM did not produce an XCTest xUnit file |
| FFmpeg build recipe | **4 passed**: fresh patches, older patched source, repeat application, conflict rejection | `python3 -B tools/test-build-ffmpeg.py` |
| FFmpeg binary and adversarial media | All slices rebuilt and package audit passed; all five metadata-limit cases and native Opus integration passed in the unit run | `Vendor/FFmpegBridge/BUILD-PROVENANCE.json`, `FFmpegMetadataLimitTests`, `OpusPlaybackIntegrationTests` |
| Live catalog, radio, lyrics and media | **22 passed, 2 failed, 2 skipped**; both LRCLIB service failures passed on the **2/2** targeted retry | `Breezy-Live-Review-01.xcresult`, `Breezy-Lyrics-Live-Retry-01.xcresult` |
| Live lyrics metadata diagnostic | **1 passed**; actual native duration and both 261/262-second inputs returned synced LRCLIB lyrics through the production Composite provider | `Breezy-Lyrics-Metadata-01.xcresult` |
| Live UI | Artist search/autoplay/crossfade passed initially; the recording/lyrics/background workflow passed on its targeted retry | `Breezy-LiveUI-Review-01.xcresult`, `Breezy-LiveUI-Review-Retry-02.xcresult` |
| Signed Release archive and local export | **Passed** archive, development export, signature and resource audits | `Breezy-Release-Review-02.xcresult`, `Breezy-1.0.0-2.xcarchive`, `Breezy-1.0.0-2-Development/GanaBajana.ipa` |

The **72 distinct fixture workflows have passing coverage across two runs**, not one entirely green full-suite bundle. Native StoreKit UI and live UI were excluded from the fixture run. The unit result predates the subsequently added opt-in lyrics diagnostic; that diagnostic was executed separately. Later banner hit-region, copy and Release-resource changes were checked through the affected UI run, live builds and Release audit.

## UI verification

The fixture suite covers native tabs; Search discovery, reselection, keyboard dismissal and query preservation; optional-artist radio and retries; playlists, queue and restored playback; Home layout and customization; icon/accent persistence; artist popularity/language corrections; player gestures, sheets and sleep; recap; cache controls; library recovery; and large-text layouts.

The final UI corrections were:

- Banner Retry and Dismiss put their **44-point interaction and accessibility regions on the labels**. Previously a dismiss tap could reach the Settings control behind the banner.
- Artist-page tests wait for loaded provenance and a finite owning scroll viewport before scrolling. The underlying pages were present; their transition geometry was not yet ready.
- Touch-target assertions accept only `1e-6` points of floating-point noise. Saved-resume checks account for elapsed automation time while requiring advancement from the recorded position.

The mini-player has a real **64-point minimum**, **44-point artwork** and **52-point controls**. Its reserved NavigationStack viewport lets final rows clear it on tab roots and pushed pages, including large text. Home uses 4-point track/album corners, 6-point mix corners and 10-point compact containers. Current captures were inspected.

### Rotation and accessibility boundaries

Headless tests explicitly used `TEST_RUNNER_GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1`. This adds a DEBUG-only launch argument enabling public `UIWindowScene.requestGeometryUpdate` in response to test notifications. Synthetic device-orientation events did not reach this runtime. These tests establish portrait/landscape layout and keyboard behavior in one process, **not physical autorotation**.

Contrast tests cover all seven accent palettes in both appearances. Row accessibility-tree checks distinguish provider-wide counts from personal listening statistics. Announcement tests use an injected VoiceOver boundary; real speech timing and physical VoiceOver operation remain unverified. Real Google WKWebView sign-in and AirPlay/headset routes also remain unverified.

## Live-provider observations

All ten genre/mood stations constructed queues; continuation, catalog filters/pagination, linked credits, reporting-period charts, actual monthly-audience labels, recording-linked lyrics, MusicBrainz and native encrypted-DNS/TLS checks passed. Direct AAC-cache and original-codec Opus preparation tests passed.

The two live skips were the opt-in media transport diagnostic and a whole-song extraction test where YouTube returned **HTTP 403** for the anonymous recording lookup. Other live cache checks and the later metadata diagnostic downloaded complete audio successfully. These observations do not promise availability for every recording or request.

LRCLIB returned temporary service failures during the initial matching checks; both failed cases passed on retry. The first live UI run displayed plain lyrics, so its synchronized-lyrics assertion failed before the background section. A diagnostic then measured **261.9745833333333 seconds** for the actual Tum Hi Ho media, rounded to **262** by the lyrics input. Both 261 and 262 inputs returned synchronized LRCLIB record **9910251**, whose last nonempty timestamp was **239.69 seconds**. This rules out the suspected one-second timing-boundary mismatch for that response. The production Composite returned in about **0.29 seconds** in one diagnostic request while an independent direct LRCLIB request took **5.12 seconds**; a slow/erroring primary can exceed the Composite's 2.5-second budget and produce a truthful plain fallback.

`Breezy-LiveUI-Review-Retry-02.xcresult` subsequently passed real playback, seek, synchronized lyric following/tap-to-seek and background/reactivation for recording `fsiPzT50ZiM`. The immediately preceding retry was user-interrupted and is not counted as verification. The separate autoplay workflow passed real continuation and crossfade. Simulator playback advancement does not establish audible fidelity, physical lock-screen controls or device suspension behavior.

## Release artifacts

- Archive: `artifacts/Breezy-1.0.0-2.xcarchive`.
- Development-signed local IPA: `artifacts/Breezy-1.0.0-2-Development/GanaBajana.ipa`.
- IPA SHA-256: `6ba93ee8bb6de9fdcd88bd6fb474fc9b1af703c24c34dbe9a97579128b1a09cd`.
- `tools/audit-release.py` checks bundle/display/version identity, iPhone arm64, minimum iOS 18, supported orientations, deep/strict signing, dependency exports/notices, and absence of DEBUG fixture markers/media and the local StoreKit catalog.
- `Resources/TipJar.storekit` remains available in Debug and is excluded from Release by `project.yml`.
- The 2.16 MiB FFmpeg XCFramework contains device arm64 and simulator arm64/x86_64 dynamic slices, required Mach-O UUIDs, two exported C symbols and only libSystem external linkage. Package provenance owns exact corresponding-source and binary hashes.
- Public Support and Privacy Gist revisions were updated and read back on 21 September 2026.

The older `GanaBajana-1.0.0.xcarchive` and `Breezy-1.0.0-2-Review.xcarchive` are not the final audited candidate. The latter exposed the local StoreKit catalog during the first audit; the final archive excludes it.

No build was uploaded, distributed through TestFlight, or submitted to App Review. The private repository does not fulfill FFmpeg recipient source/relink delivery. The content-rights, Apple web-authentication and native StoreKit holds remain in [release status](app-store/RELEASE_STATUS.md).

## Reproduce

From the repository root:

```sh
python3 -B tools/test-build-ffmpeg.py
python3 -B tools/build-ffmpeg.py --component verify
export DESTINATION='platform=iOS Simulator,id=B1EE1D9A-124A-4788-9760-5C5668E19078'
SKIP_NATIVE_STOREKIT=1 bash tools/verify.sh unit
SKIP_NATIVE_STOREKIT=1 TEST_RUNNER_GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1 bash tools/verify.sh ui
bash tools/verify.sh live
bash tools/verify.sh live-ui
```

`SKIP_NATIVE_STOREKIT=1` is an explicit local exclusion for the recorded platform failure, not the script default. A fixture UI run takes roughly 90 minutes here. The scripts keep derived data, package caches and unique result directories under `artifacts/`, use four build jobs and disable parallel testing.

Vendored regression scope:

```sh
swift test --package-path Vendor/YouTubeKit \
  --scratch-path "$PWD/artifacts/YouTubeKitReview" \
  --cache-path "$PWD/artifacts/SwiftPMCache" --manifest-cache local \
  -j 4 --no-parallel --disable-swift-testing \
  --filter '(ExtractionTransportTests|RemoteChunkingTests|SignatureSolverDiagnosticTests|BoundedExtractionTransportTests|ExtractionBudgetIntegrationTests)'
```

`GanaBajanaLive` supplies `GANABAJANA_LIVE_TESTS=1`; `GanaBajanaLiveUI` supplies its live UI flag. The metadata diagnostic additionally requires `TEST_RUNNER_GANABAJANA_LYRICS_DIAGNOSTICS=1` and selector `GanaBajanaTests/LyricsPlaybackMetadataLiveTests/testLiveLyricsComparePlaybackMetadataAndDurationBoundaries`. It records metadata only, not lyrics text, signed URLs or credentials.

Audit the final local archive with:

```sh
python3 -B tools/audit-release.py artifacts/Breezy-1.0.0-2.xcarchive --version 1.0.0 --build 2
```

Native StoreKitTest remains blocked before product discovery by configuration Code 3 and `notEntitled`. No fake-backed purchase result is presented as native StoreKit or sandbox evidence.
