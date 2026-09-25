# Verification

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
