# Breezy initial release status

**Status: 24 September 2026 UTC. Breezy 1.0.0 (5) is uploaded, processed `VALID`, App Store eligible and attached to the iOS draft.** Apple blocked adding the app to review because required declarations are missing. The review container is empty and unsubmitted. The owner-selected app is [6815025307](https://appstoreconnect.apple.com/apps/6815025307). Changes remain **uncommitted after `ebb5d5c`**. [ASC_STATE.json](ASC_STATE.json) records exact IDs and verified state; [VERIFICATION.md](../VERIFICATION.md) owns test evidence.

**Build 5 includes R6/R7/R8/R9.** R9 adds [official recording-language and duration metadata](../YOUTUBE_DATA_API.md), with 174 focused unit cases and one native live API test passed. [Home Screen widgets](../WIDGETS.md), [listening-led discovery](../LISTENING_DISCOVERY.md) and earlier player/Search/cache features remain included. [Support/Privacy refinements are published](PUBLIC_PAGES.md). The refreshed phone/iPad galleries show the six main listening screens from post-build-5 source, including R10 visuals, and need a matching new binary before review. Watch/IAP evidence retains build 3. Previous release directories remain frozen.

## September 25 authorization follow-up

The owner completed Google's CAPTCHA and renewed the Apple browser sign-in. The generic YouTube intake question [posted as issue 565837697](https://issuetracker.google.com/issues/565837697) was answered on 2026-09-25: use the existing Audit and Quota Extension Form with the re-audit option, default quota and a proactive-review note; the issue was closed as Won't Fix (Infeasible). MetaBrainz answered the same day: free use as a registered Stealth Start-Up supporter with rate limiting and attribution, revisiting at about $500/year of income. The owner confirmed the individual legal name Abhishek Agrawal and an initial forecast below 1,000 Data API requests/day. The app-specific form answers are prepared with the unresolved intake, address and review-access fields left open.

Free/Paid Apps agreements, the W-9 and Digital Services Act records were verified as Active. The owner-approved [FFmpeg library source release](https://github.com/aagrawal207/Breezy-FFmpegBridge/releases/tag/9.0.2-patch2) is public and passed anonymous download/hash verification. Recipient application relinking remains unverified. Private MusicBrainz and LRCLIB inquiries were sent and verified in Gmail Sent; they request API/data terms and deployed log-retention details. No paid commitment was made.

`artifacts/Authorization-20260925/summary.json` owns the receipts. Exact Apple submission/item reads still show an empty `READY_FOR_REVIEW` container, zero items and version state `PREPARE_FOR_SUBMISSION`. CLI readiness remains **25 errors / 6 warnings**. Its generic status dashboard incorrectly treats that empty container as in-flight; do not interpret its “Wait for App Store review outcome” suggestion as submission proof. The separate CLI web session is still expired despite the verified browser session.

## App Store Connect preparation

**Local source is 1.0.0 (6).** R10 adds guarded artist-song deduplication, artwork-derived backgrounds and continuous album/artist navigation; R11 removes the container behind the player's transport buttons and draws the progress bar and like heart as one continuous trail. Focused unit/UI checks and unsigned Release builds passed; [R10](../VERIFICATION.md#r10-artist-song-identity-and-artwork-backed-pages) and [R11](../VERIFICATION.md#r11-container-free-transport-and-the-progress-to-heart-trail) verification record the runs. Build 6 has not been archived or delivered to Apple. The attached build and refreshed gallery records below retain their own provenance.

| Item | Verified state |
| --- | --- |
| iOS version | `1.0.0`, ID `2754a299-5b46-4e62-8f79-8bf80c6078d5`, `PREPARE_FOR_SUBMISSION`; existing release type `AFTER_APPROVAL` |
| Attached build | `5`, ID `42a08cec-1e27-4ec2-afad-4e3e88af27e3`, `VALID`, `APP_STORE_ELIGIBLE` |
| Metadata | Name, subtitle, description, keywords, promotional text, Music category and public URLs applied/readback-verified; canonical metadata follow-up diff empty |
| Price and availability | Free, USA base territory, all 175 current territories enabled and new territories included |
| Tips | Five `READY_TO_SUBMIT` consumables with en-US localizations, 175-territory availability and verified USA prices $3/$5/$10/$25/$50 |
| Screenshots | 6 new iPhone and 6 new iPad images: Home, Player, Album, Artist, Recap and Liked songs. All `COMPLETE` with matching ordered MD5s; 2 build-3 Watch images retained |
| IAP review evidence | One actual native StoreKit product screen reused for all five tips; every attachment `COMPLETE` with the expected checksum |
| Public pages | Current Support/Privacy publication copies published and byte-verified; [publication record](PUBLIC_PAGES.md) |
| Review details | Owner-approved contact preserved; exact 3,914-character [review-notes.txt](review-notes.txt) verified, including screenshot provenance, matching-binary requirement and the public FFmpeg source link; no demo account required |
| Submission | Empty review draft `43569019-e4a2-4875-9fa1-c79b72716763` exists; Apple blocked adding the app version. No item is queued for review |

The 15,358,007-byte IPA is `artifacts/AppStore-1.0.0-5/Breezy-1.0.0-5.ipa`, SHA-256 `8593026f58d070a74df1cf93e48a54b9678e270e796baa48c0ca79de7746b4a0`. Apple validation succeeded with no errors. Uploaded file `6a72d07e-cd2b-48e4-98b0-123a5f495543` matches the local MD5 `7017f372367b022a009116c7b56320b0`. Phone and widget share the exact App Group; only the phone uses Production iCloud and the restricted metadata API configuration. All three bundles are App Store-signed with no CarPlay or debug signing entitlement. Release fixtures and the local StoreKit catalog are absent.

Delivery receipts are under `artifacts/AppStore-1.0.0-5/readback-1790220802087226000/`. CLI readiness reports **25 errors**: 24 unanswered age-rating fields and the missing content-rights declaration. Its six warnings are the five unsubmitted IAPs and an expired cached Apple web session. The actual review API separately reports **22 age-rating attributes**, missing App Privacy publication and missing content rights. The later browser check verified active Free/Paid Apps agreements; CLI deep checks still cannot reuse that browser session. This app uses consumable tips. Availability and required review fields passed.

The generic CLI suggestion `DOES_NOT_USE_THIRD_PARTY_CONTENT` is false for this app and must not be applied. Final age-rating/privacy answers depend on the licensed content model. A separate MAC_OS draft also exists; pin the iOS version ID or `--platform IOS` rather than accepting a default diagnosis of the Mac draft.

### September 24 screenshot and submission-detail refresh

The owner requested the screens used for listening rather than setup. Phone and iPad now each show Home, Player, Album, Artist, Recap and Liked songs. The captures use live catalog results and real listening in isolated app stores. [SCREENSHOTS.md](SCREENSHOTS.md) owns the assets and source provenance; [verification](../VERIFICATION.md#september-24-core-listening-screenshots) records the successful capture runs and earlier iPad interruptions/failures.

`artifacts/StoreScreenshots-20260924/readback-1790286580768511000/summary.json` confirms all twelve replacement images' order and checksums, the retained Watch pair, an empty metadata diff, the updated reviewer-note body and the same attached build and empty review draft. Required review contact fields remain present. The source used for the screenshots includes changes newer than the uploaded binary.

Readiness remains **25 errors / 6 warnings**. Fourteen source-supported age answers are prepared, but the ten unassessed content descriptors prevent Apple's initial questionnaire from saving. App Privacy remains the previously recorded incomplete draft. Two `asc web auth login` attempts returned HTTP 503, and fresh CLI status remains unauthenticated. Content-rights authorization and FFmpeg recipient delivery remain unresolved. No declaration or review-submission state was changed in this refresh.

### Actual review attempt

The owner authorized upload and submission after the metadata work. The build-5 attempt reused review draft `43569019-e4a2-4875-9fa1-c79b72716763`. Apple's `review items add` command failed with exit code 5: 22 missing age-rating attributes, unpublished App Privacy answers and the missing content-rights declaration. Readback confirms zero review items, draft state `READY_FOR_REVIEW`, and app version state `PREPARE_FOR_SUBMISSION` with build 5 attached. This is a submission-gate failure, not an App Review rejection. The five IAPs were not added to an app-less submission.

`artifacts/AppStore-1.0.0-5/submit-1790220849624895000/add-app-result.json` preserves the complete error; `summary.json` and before/after readbacks preserve the resulting state. No rights claim or other declaration was changed. Reuse this draft after its requirements are genuinely resolved. The earlier build-4 attempt remains in `artifacts/AppStore-1.0.0-4/review-attempt-01.json`; its successful `wouldSubmit=true` dry-run did not establish review eligibility.

The final record audit passed at **2026-09-24 04:00 UTC**. `artifacts/AppStore-1.0.0-5/final-record-audit.json` verifies frozen inputs, IPA/upload hashes, retained assets, live reviewer-note/public-page bodies, API configuration and signing cleanup. Its fresh `readback-1790222433002759000/` confirms the same attached build and empty, unsubmitted review container. Metadata validation scanned two files with zero errors/warnings; documentation JSON and `git diff --check` passed.

## September 24 review-question follow-up

The owner requested using Osho and Bruce as references. [REVIEW_QUESTIONS.md](REVIEW_QUESTIONS.md) records their published age/privacy answers and each supported Breezy capability answer. Both reference apps are rated 4+ and declare third-party content; Osho's public privacy label is Data Not Collected, while Bruce's is unlinked Health/Fitness for App Functionality.

Fourteen Breezy age answers were prepared and a guarded partial save attempted. Apple rejected the initial update because the content descriptors were missing; before/after readback confirms no saved changes. Ten content descriptors still need assessment, and all 24 store fields remain unanswered. The API profile works, but web-session renewal returned 503 and the browser requires sign-in. Privacy publication and content rights remain unresolved. Comparison and rejection receipts are linked from `ASC_STATE.json`.

`artifacts/AppStore-1.0.0-5/review-questions-20260924.json` records the final follow-up. Its fresh `readback-1790252822001748000/` confirms the VALID attached build, matching IPA/metadata and zero review items. Readiness remains 25 errors / 6 warnings, and frozen source inputs remain unchanged. The earlier final-record audit and submission-gate response remain historical evidence.

## Historical R5 Settings, player and play-count update

R5 enables iCloud by default when no device configuration exists, preserves saved opt-outs and account-change pauses, shows a green enabled cloud, and reorganizes Settings into Playback, Library & iCloud, Appearance, Discovery, Account & connection, and About Breezy. Album and artists share one player chooser alongside native AirPlay. Artist headers are 10% smaller. Provider song totals survive validated album-audio metadata recovery and are never replaced by upload views. The full unit run passed 1,285 tests with 35 live skips, excluding native StoreKit. All 19 non-skipped targeted iPhone workflows passed across runs; two iPad checks and a signed Release build passed. Native AirPlay route-chooser checks skipped on both simulators. [VERIFICATION.md](../VERIFICATION.md) records the exact evidence.

The owner approved the free/worldwide setup and five tip prices, then manually created the app record after the CLI's Apple web-login HTTP 503. API-based preparation resumed after that creation. The current remote state is recorded above; a cached web session is still unavailable for the remaining website-only checks.

## Previous iCloud and collection update

R4 added [iCloud library sync](../ICLOUD_SYNC.md), asynchronous artist pictures, grouped Automix/Crossfade defaults, animated Search reselection and artwork-led collection pages with song durations. Standard signed Debug and Release builds contain the exact iCloud container and their profile covers it. Native two-device iCloud delivery remains unverified. [VERIFICATION.md](../VERIFICATION.md) records the R4 unit and UI evidence; the historical archive/IPA predates that update.

## Submission hold

**ON HOLD: a licensed provider/content approach has not been selected.** The owner explicitly confirmed that authorization from YouTube and the music rights holders has not been obtained. The current implementation accesses undocumented endpoints, extracts audio streams, and caches complete songs. It cannot be represented as a provider-authorized service.

Submission requires a licensed content decision and matching implementation. Attribution, optional tips, private source, and a successful local export do not grant content rights. [PROVIDERS.md](../PROVIDERS.md#distribution-and-content-rights) links the relevant YouTube terms, including Developer Policies III.E.1.

The Google account the owner named (`aagrawal207@gmail.com`) is the developer account, not an external contact. The generic routing question is [posted as YouTube issue 565837697](https://issuetracker.google.com/issues/565837697). The owner completed its CAPTCHA; authenticated readback verified the exact title/body, reporter and New status. `artifacts/YouTube-authorization/intake-routing-20260924/posted.json` owns the receipt. A confirmed private recipient and product permission remain pending; [AUTHORIZATION_REQUEST.md](AUTHORIZATION_REQUEST.md) contains the app-specific draft. Project `breezy-509601` has an enabled Data API and a verified app/API-restricted key. Included metadata quota does not authorize extraction/caching. Apple [5.2.2–5.2.3](https://developer.apple.com/app-store/review/guidelines/#intellectual-property), YouTube's [terms](https://www.youtube.com/t/terms) and [developer policies](https://developers.google.com/youtube/terms/developer-policies) remain relevant to that permission request.

## Identity and release anchor

| Item | Recorded state |
| --- | --- |
| Selected public name | `Breezy - Stream Music & Chill`, 29 characters; owner-created app `6815025307` |
| Home Screen name | `Breezy` |
| Bundle identifier | `com.agraabhi.ganabajana` |
| Internal project/module/scheme/folder | `GanaBajana` |
| Local version/build | `1.0.0 (6)` in `project.yml`; local Debug/unsigned Release verification only. The verified archive/export and attached App Store Connect build remain `1.0.0 (5)` |
| Default icon | **Leafnote** (`Beat`, primary, nil alternate name); 7 unique visible choices in current source |
| Release anchor | Initial app release; no previous published release or release tag |
| Git | `main` |
| GitHub | Private [aagrawal207/Breezy](https://github.com/aagrawal207/Breezy); `origin` confirmed |
| Public identity/copyright | Abhishek; draft copyright `2026 Abhishek` |
| Public support contact | `aagrawal207@gmail.com`, reused from the owner's existing public support contact |

The bundle, saved-library directory, URL scheme, Keychain identity and five IAP product IDs retain their technical identities. The primary icon is Leafnote; 8 sets include its compatibility alias, while the picker has 7 choices including Thorn and Sonnet. A retired icon resets to Leafnote once. The app targets iPhone/iPad and supports Designed for iPad on Apple silicon Macs; separate Mac runtime acceptance remains open.

## Historical companion and player round

- **iPhone:** the rose icons point their pens toward the lower-left (the later round retired Copper and rebuilt Sonnet on Thorn's rose). Album pages have bounded, attributed Wikipedia descriptions from their actual catalog headers. Mini-player progress fills the capsule background.
- **Apple Watch:** a native watchOS 11+ companion browses favorites, recent songs, playlists and queue, and controls the existing iPhone player. Six fixture UI workflows and 31 native model/wire tests have passing coverage. A separate real Watch Connectivity test passed Play, Next and Pause between paired simulators using isolated phone fixture audio.
- **CarPlay:** native library lists, shared Now Playing, queue, shuffle/repeat and favorites are implemented. Template/navigation/playback tests passed. The custom car interface requires Apple's audio capability approval and an eligible profile.
- **Signing:** ordinary `GanaBajana` and `GanaBajanaWatch` schemes use Debug/Release without the managed entitlement. `GanaBajanaCarPlay` selects Debug-CarPlay/Release-CarPlay and `Signing/CarPlay.entitlements`. The Watch target has no CarPlay entitlement in any configuration.

`Breezy-Standard-Signing-01.xcresult` records that round's successful **signed Debug device build** including Watch. Deep/strict signature checks passed without the CarPlay entitlement. Its unsigned Release source build was `Breezy-Companions-Release-02.xcresult`, before the signing split. Both Release configurations retained the StoreKit-resource exclusion. That round produced no archive, IPA, upload or publication; later delivery is recorded above.

All 12 targeted phone UI workflows and six Watch fixture workflows had passing coverage across their initial and correction runs; six of the phone workflows exercised the automatic player presentation that has since been removed, so only the album and mini-player results still describe current behavior. The selected 202-test phone run had one license-URL failure, corrected in the subsequent 71-pass parser/catalog/live run. [VERIFICATION.md](../VERIFICATION.md#current-companion-and-player-changes) preserves exact counts, original failures, screenshot paths and limits. [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md#companion-and-player-experience-review) records the independent source corrections.

## Earlier refinement round

This historical working-tree round followed `ebb5d5c` and preceded the later archives. The following closeout uses coordinator-reported results. Detailed run accounting remains in [VERIFICATION.md](../VERIFICATION.md); source review remains in [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md). Results are recorded per run without an aggregate test-total claim.

| Area | Current implementation | Verification result |
| --- | --- | --- |
| Two icon choices | Thorn and Sonnet use one original pen-piercing-rose composition in two palettes, inspired by the user's reference, not copied branding. The generated icon/preview pairs are 1024 × 1024 / 240 × 240 RGB PNGs without alpha; [contact sheet](../../artifacts/rose-pen-sonnet-contact-sheet.png) | Historical: one icon-selection workflow passed in `Breezy-Refinements-UI-01` with the earlier three-rose set (Thorn, Sonnet, Copper), covering all three selections, persistence, and restoring Leafnote. The rerun with the current two-rose set is pending |
| Compact switches | Native visual 20% smaller at 0.8 scale, full-row button at least 44 points high, and native Toggle accessibility representation; explicit at all four Toggle call sites, not global on RootView | **4/4 compact-switch workflows passed** in `Breezy-Compact-Switch-03`, including radio setup. Row taps, native state/persistence, disabled final-language selection, and Home reordering remain asserted |
| Language browser | Popular-song list by default; manual compact disclosure, **Browse by language** only after at least two identified languages, retained filter through collapse/results/corrections, and a context-menu correction path | **Two spotlight UI workflows plus one separate language-correction workflow passed** in `Breezy-Refinements-UI-01` |
| Lyrics classifier | Original-text 40-word cores at a 20-word stride; one context retry up to 80 words only for a lexically/script-valid ambiguous core without a confident foreign code; independent segment veto and sparse-line anchor/confidence gates | **36/36 focused unit cases passed** in `Breezy-Refinements-Language-Final-04`, including the corrected native-confidence fixtures and strict injected thresholds |
| Live language / MusicBrainz | Conditional exact linked-work lookup with the existing host/cache policies; [PROVIDERS.md](../PROVIDERS.md#radio-and-language-evidence) owns the bounds | **4/4 live cases passed** in `Breezy-Refinements-Language-08`: Kanye West's All Falls Down (feat. Syleena Johnson), Radiohead's No Surprises, Hindi/transliteration not English, and the exact MusicBrainz work contract. No catalog-wide accuracy or incremental live work-fetch recovery rate is claimed |
| Independent source review | Language foreign-segment veto and raw-context logic; compact switches | P2 language finding cleared; context logic and switches approved |
| Current Release build | Final production source | **Passed:** `Breezy-Refinements-Release-02`, unsigned generic-device Release build; not an archive, export, or upload |

### Full-run records and focused resolutions

| Run | Recorded result | Resolution / scope |
| --- | --- | --- |
| Initial full refinement unit run | **909 passed, 1 failed, 33 skipped** | The existing playback-controller CancellationError case was transient and passed its targeted rerun |
| `Breezy-Refinements-Unit-Final-02` | **929 passed, 1 failed, 33 skipped** | Sole failure: a new native English fixture incorrectly assumed high recognizer confidence for an ambiguous repetitive-pronoun phrase |
| `Breezy-Refinements-Language-08`, entire bundle | **38 passed, 1 failed** | Includes all four passing live cases; the sole failure was the same native unit-fixture assumption |

The native fixture was split into explicit low-confidence/unclassified behavior and separate sparse-English high-confidence acceptance. Strict injected threshold checks were retained. The correction passed in `Breezy-Refinements-Language-Final-04`; it did not require a production change. **This is passing coverage across runs, not one green full unit suite.**

[SONG_LANGUAGES.md](../SONG_LANGUAGES.md) records the observed English confidence scores and bounded context rules. The switch helper uses a native child only when reachable, otherwise the visible parent row, because the accessibility representation can expose a zero-bounds virtual child. Native VoiceOver remains unverified.

That refinement round produced no archive/export or upload. The later build-3 preparation and publication are recorded above; changes remain uncommitted.

## Preparation state

| Area | State | Detail |
| --- | --- | --- |
| Store listing | Applied; canonical follow-up diff empty | [STORE_LISTING.md](STORE_LISTING.md); licensed-content decision still open |
| Consumable products | Five created, `READY_TO_SUBMIT` | [IAP_MANIFEST.json](IAP_MANIFEST.json) records product/version/localization and review-image IDs |
| App Store Connect app | `6815025307`, selected name verified | iOS draft and current attached build aligned to 1.0.0 (5) |
| API authentication | Working | Metadata, signing profiles, assets and build upload completed through `asc` |
| Apple web authentication | Cached session expired | Required for questionnaire work and agreement verification; missing App Privacy publication is confirmed by the review API |
| Public Support/Privacy URLs | Current publication copies published and byte-verified | [PUBLIC_PAGES.md](PUBLIC_PAGES.md) records revision, sources and hashes |
| Settings links and copy | Existing qualifications aligned in source; compact-switch UI passed | Backup, account/provider-logging, remote-response, and cache/preparation-byte qualifications are present |
| MusicBrainz contact | **Configured** to the published Support anchor in `project.yml` | Public contact URL is available |
| Official recording metadata | Restricted key configured and live-tested in the phone app | [YouTube metadata](../YOUTUBE_DATA_API.md) owns language precedence, temporary duration copies, quota/backoff and test coverage |
| Playback/cache | Native Opus MP4 preparation, AAC fallback, and reusable immutable cache variants implemented | [Architecture](../ARCHITECTURE.md#opus-preparation-cache-variants-and-reload) owns the contract; historical verification evidence below |
| Reviewed contracts | Receive-time bounds, request/artwork cancellation, durable listening/recovery and alert delivery, navigation/radio intent, contrast, and row accessibility implemented | [Architecture](../ARCHITECTURE.md) and [providers](../PROVIDERS.md) describe source behavior; native acceptance remains distinct |
| FFmpeg LGPL delivery | Library source/rebuild materials **published and verified**; application relinking unresolved | [FFmpeg distribution](../FFMPEG_DISTRIBUTION.md) owns the public archive, source-to-binary mapping and remaining recipient path |
| App name | Breezy selected by the owner | [NAMING.md](NAMING.md) retains historical alternatives |
| App screenshots | 12 live listening-screen images plus 2 retained Watch images; checksum/order verified | [SCREENSHOTS.md](SCREENSHOTS.md); post-build-5 visuals need a matching binary |
| IAP review screenshot | Captured on iOS 27 and attached to all five products | Native names/prices and optional-tip explanation, no purchase |
| Review notes/contact | Configured and readback-verified | [REVIEW_NOTES.md](REVIEW_NOTES.md); phone kept out of repository/public pages |
| App Privacy | Source inventory updated; questionnaire publication missing | [PRIVACY_REVIEW.md](PRIVACY_REVIEW.md); final answers require the content/provider assessment |
| App price/territories/age rating | Free and 175 territories verified; age rating unanswered | Final content assessment required for the questionnaire |
| Independent reviews | R8 source review and native acceptance corrections complete; earlier reviews remain historical evidence | [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md); source approval does not establish hardware, VoiceOver, StoreKit, or real-account acceptance |
| Upload/TestFlight/App Review | Build 5 uploaded, valid and attached; review add-item attempt blocked, zero items and no tester distribution | Required declarations, content-rights and FFmpeg delivery holds remain |

## Local release artifacts

Current artifacts are under `artifacts/AppStore-1.0.0-5/`: `Breezy-1.0.0-5.xcarchive`, `Breezy-1.0.0-5.ipa`, `ExportOptions.plist`, `inputs.json`, `archive-audit.json`, `ipa-inspection.json`, `apple-validation.json` and `upload.json`. Distribution profiles are reused `BKV567TA2S` (phone), `MPDS5C96JT` (widget) and `PNPWW4U8LL` (Watch), using existing certificate `YBW79S2M2T`. The temporary export keychain was removed, and the prior search list/default were verified restored. The phone's client API key is bundled; receipts store only its configuration checks and source-file hash. Signing credentials are excluded. Build-3/build-4 artifacts remain historical.

Apple validation created reservation `205accea-418d-42b6-912c-e3f3eea04895`, containing only analyzer/description assets. `validation-reservation-1790220500273605000/` records inspection and removal of that exact reservation. The unchanged validated IPA was then uploaded and its checksum verified against the completed remote file.

The following table records the earlier **1.0.0 (2)** reference baseline. Those artifacts predate the current refinements.

| Artifact | Recorded path / scope |
| --- | --- |
| Signed Release archive | `artifacts/Breezy-1.0.0-2.xcarchive` |
| Development IPA | `artifacts/Breezy-1.0.0-2-Development/GanaBajana.ipa`; local development export |
| Archive audit | `python3 tools/audit-release.py artifacts/Breezy-1.0.0-2.xcarchive --version 1.0.0 --build 2` |

The audit checks identity/version/build, iPhone/iPad families and orientations, iOS 18 minimum, multitasking, signatures, FFmpeg exports/notices, privacy-manifest presence and absent test resources. The old build-2 archive was audited as iPhone-only under its earlier rule. Build 5 passed the expanded audit, including required phone-only API configuration, and its App Store IPA passed Apple validation and processing. Debug Run retains the local StoreKit catalog; Release excludes it.

## Verification snapshot

**Historical reference baseline, before the current post-`ebb5d5c` work.** Preserve these run results and exclusions. They are not replacement totals for the refinement round above.

| Run or scope | Result | Boundary |
| --- | --- | --- |
| `Breezy-Unit-Review-04` | **869 passed, 0 failed, 28 skipped** | Native `TipJarStoreKitTests` explicitly excluded |
| `Breezy-UI-Review-01` | **65 passed, 7 failed of 72** | Full fixture run; native StoreKit and live UI excluded |
| `Breezy-UI-Review-Fixes-01` | **12/12 passed** | All seven prior failures plus five related workflows |
| `Breezy-Live-Review-01` | **22 passed, 2 failed, 2 skipped** | Both failures were LRCLIB matching cases with transient service errors. Skips: opt-in media probe and one anonymous whole-song extraction returning HTTP 403 |
| `Breezy-Lyrics-Live-Retry-01` | **2/2 passed** | Both failed LRCLIB matching cases passed on retry; the original live run retains its failures/skips |
| `Breezy-LiveUI-Review-01` | **1 passed, 1 failed** | Artist search/autoplay-crossfade passed. Tum Hi Ho played and sought successfully, then the synced-lyrics expectation failed because plain lyrics appeared |
| `Breezy-Lyrics-Metadata-01` | **1 passed** | Actual native duration 261.97458 seconds rounds to 262; both 261/262 inputs returned synced LRCLIB lyrics through the production Composite. No duration-boundary bug reproduced |
| `Breezy-LiveUI-Review-Retry-02` | **1 passed** | The complete recording workflow passed real playback, seek, synchronized lyrics/tap-to-seek and background/reactivation. The preceding retry was interrupted and is not counted |
| `Focused01` | **14/14 passed** | Nine artwork cancellation, two library pause, one manual radio, one model radio, and one Home UI case; not a full UI-suite result |
| Vendored native XCTest | **38 passed**, using `--disable-swift-testing` | Native XCTest only; no xUnit artifact |
| Python `test-build-ffmpeg` | **4 passed** | Build-recipe test evidence, separate from framework rebuilding and playback |
| Adversarial FFmpeg metadata | **Five passed in both UnitReview03 and UnitReview04** | The 300,000 Tags case took **3.18 seconds including fixture generation**; this is an observed test duration, not a general remux-time guarantee |
| `artifacts/Breezy-Opus-Integration-05.xcresult` | Earlier targeted evidence: **4 OpusPlaybackIntegrationTests passed** | AVPlayer decoded, played, and sought through 160/256 kbps Opus MP4 fixtures on QA iOS 26.5. The original WebM fixtures with the same encoded packets were not natively playable there |
| FFmpegBridge package | Device arm64 and simulator arm64/x86_64 rebuilt, repackaged, and verified; **2.16 MiB (2,262,408 bytes)** | [Provenance](../../Vendor/FFmpegBridge/BUILD-PROVENANCE.json) records patch policy 2 and the original corresponding-source bundle. Public delivery was unresolved at this historical baseline; the September 25 publication is recorded above |
| Independent source reviews | **Five reviewers cleared all original P1/P2 findings and follow-ups** | Completed source review, not Google sign-in, StoreKit, VoiceOver, hardware, or live-provider acceptance |
| Home corner changes | Reference-baseline appearance screenshot-checked | Does not establish a final App Store capture set or an aggregate UI pass |
| Native StoreKit / real sandbox | Still blocked by `AppleStoreKitTest` configuration Code 3 / `notEntitled` | Fake-backed purchase-policy tests passed, but do not establish native product discovery, sandbox purchases, or IAP review readiness |
| Native VoiceOver / real Google sign-in / hardware | Unverified in this historical baseline; physical acceptance and smaller-screen work were deferred | Current simulator coverage is recorded in [VERIFICATION.md](../VERIFICATION.md). Source semantics and synthetic account tests do not establish physical-device acceptance |

**Historical fixture result: 72 distinct workflows have passing coverage across the two UI runs, not a single green full run.** Banner Retry/Dismiss hit regions meet the actual 44-point minimum. Geometry assertions use only a `1e-6` floating-point epsilon at that threshold; artist tests wait for observable readiness, and resume assertions allow for elapsed automation time. Current compact-switch evidence is recorded in the refinement round above.

In the historical baseline, live checks passed for all ten radio stations of the catalog at that time (the current catalog has 34), Opus/cache, native encrypted DNS/TLS and catalog. Both LRCLIB matching failures passed on retry, and the separate live UI recording retry passed the complete synchronized-lyrics/background workflow. Those checks predate the new language classifier/work lookup and the grouped radio catalog. Provider outages and latency can still produce a plain fallback. [VERIFICATION.md](../VERIFICATION.md#live-provider-observations) preserves the initial failures and diagnostic evidence.

Fixture rotation used the explicit headless scene-geometry opt-in, preserving the same running app process. This is layout/keyboard evidence, not physical autorotation. The DEBUG-only mechanism is in [architecture](../ARCHITECTURE.md#verification-ownership); the historical verification target was **iPhone 17 Pro only**. Later iPad and small-phone coverage is recorded in [VERIFICATION.md](../VERIFICATION.md); a Mac (Designed for iPad) run remains pending.

Homebrew `ffmpeg` is installed for fixture generation. Its libraries are not linked into the app; the app uses the pinned minimal LGPL framework.

[VERIFICATION.md](../VERIFICATION.md) records detailed evidence and reproduction; [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md) records source-review findings and their scope. The coordinator owns current-round updates to both. `tools/verify.sh` keeps native StoreKit enabled by default; `SKIP_NATIVE_STOREKIT=1` is an explicit unit/UI exclusion. Its live mode includes `ExperienceRadioLiveTests` and `LyricsFallbackLiveTests`; live UI is a separate mode.

## Remaining release work

- Native VoiceOver and physical iPhone/iPad/Watch/Mac acceptance remain open, as do two-device iCloud delivery, an actual AirPlay receiver and real Google sign-in. Small-phone simulator accessibility checks are recorded in verification. Native product display passed on iOS 27; native transaction-suite and sandbox-purchase acceptance remain open.
- Verify a usable recipient application replacement/relinking path. The library's source and rebuild instructions are already public.
- Complete the age-rating and App Privacy assessments against the permitted content/provider model and responses. The verified Free/Paid agreements, W-9 and Digital Services Act records are Active. Refresh affected binary/copy before submission, and include all five intended IAP version IDs when submission is authorized and the holds are resolved.

### Open owner facts and decisions

1. Which licensed provider/content approach will replace or authorize the current extraction/caching model?
2. What usable recipient application replacement/relinking path will be supported for the LGPL component?
3. What provider retention, linkage and tracking facts support final App Privacy answers? Support-correspondence handling is already confirmed as reply-only; ten content-frequency descriptors also remain unassessed.
4. What private demo/review access and terms evidence will be supplied for the formal YouTube request? The owner enters the legal address directly and reviews final acknowledgements after the intake is confirmed.
5. Submit the Audit and Quota Extension Form with the answers from [issue 565837697](https://issuetracker.google.com/issues/565837697) (re-audit option, default quota, proactive-review note) once the owner supplies the legal address, review access/evidence uploads and acknowledgements; `artifacts/Authorization-20260925/google-application-draft.json` holds the prepared answers.
6. Register Breezy as a MetaBrainz Stealth Start-Up supporter (owner account) and keep the MusicBrainz attribution in the acknowledgements; consider a short attribution line in the store description.

Build-5 upload, attachment and Support/Privacy publication are complete. The refreshed gallery retains its recorded source provenance and needs a matching binary. Reviewer notes now include the public library-source link, with contact fields preserved (`artifacts/AppStore-1.0.0-5/review-1790309749262953000/summary.json`). The review container remains empty. Content authorization, recipient application relinking and required declarations remain unresolved. CarPlay approval and device acceptance remain separate.

## What stands between now and Submit for Review

Status on 2026-09-25 UTC, after the R11 player change and the MetaBrainz/YouTube replies.

| Gate | State | Who closes it |
| --- | --- | --- |
| Age rating (24 fields) | Fourteen capability answers prepared; ten content descriptors proposed at 12+ in [AGE_RATING_ANSWERS.json](AGE_RATING_ANSWERS.json) | Owner confirms the ten values; one helper write follows |
| App Privacy | Three types saved but not set up; a complete proposal is in [PRIVACY_REVIEW.md](PRIVACY_REVIEW.md#proposed-declaration-for-owner-confirmation) | Owner confirms linkage choices; publish in the browser session |
| Content rights ("does your app access third-party content, and do you have the rights") | Open. The app streams YouTube Music audio through an unofficial extraction/caching path; no rights holder or YouTube permission exists | Owner decision: obtain explicit written authorization, or change the playback model to a permitted one, or accept a probable rejection. An affirmative rights answer is not available today |
| YouTube API compliance audit | Intake settled by [issue 565837697](https://issuetracker.google.com/issues/565837697); answers prepared; evidence pack drafted under `artifacts/Authorization-20260925/google-form-evidence/` | Owner supplies address, review access and acknowledgements; browser submission. Note: this audit covers Data API use and does not license audio extraction, background or offline playback, which the Developer Policies prohibit for API clients |
| MusicBrainz terms | Answered: free use as a Stealth Start-Up supporter with rate limiting and attribution; attribution added to the acknowledgements | Owner registers the MetaBrainz account and tier |
| Privacy policy publication | The YouTube API Services section is written and the publication copy is prepared under `artifacts/PublicPages-20260925/` | Owner go-ahead; one `publication.py publish` run, then live-page evidence capture |
| Binary | Source is 1.0.0 (6) with R10/R11; unsigned Release builds pass; only build 5 is uploaded | Owner authorizes archive, signing and upload; the guarded release stages exist |
| Screenshots | Current-source set captured locally on both store simulators (`StoreScreenshots-20260925/`); remote galleries still show the September 24 set | Upload with the matching binary, after the content decision |
| LGPL recipient relink | Library source public; application replacement path unverified | Owner decision on delivering relinkable objects or an equivalent path |

Everything in the owner column except the content-rights row is administrative and can be finished in one sitting. [REVIEW_QUESTIONS.md](REVIEW_QUESTIONS.md#peer-model-check-demus-2026-09-25) records how a listed peer (Demus) fits through the gate: YouTube's own embedded player with video, ads and no caching. The content-rights row is the release decision: without authorization or a permitted playback model, submission would require a rights claim the app cannot support, and Apple's guideline 5.2.3 names downloading or saving media from YouTube without authorization as grounds for rejection.

## Local assets

- [Store listing and launch note](STORE_LISTING.md)
- [Five-product IAP manifest](IAP_MANIFEST.json)
- [App/IAP review notes](REVIEW_NOTES.md)
- [Screenshot plan](SCREENSHOTS.md)
- [App Privacy assessment](PRIVACY_REVIEW.md)
- [Public-page publication and integration](PUBLIC_PAGES.md)
- [Selected name and historical lookup scope](NAMING.md)
- [FFmpeg source, notices, and relink delivery](../FFMPEG_DISTRIBUTION.md)
- [Support page](../../SUPPORT.md) and [privacy policy](../../PRIVACY.md)
