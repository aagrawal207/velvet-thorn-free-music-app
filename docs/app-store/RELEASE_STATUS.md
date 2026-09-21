# Breezy initial release status

**Status: 21 September 2026.** Breezy **1.0.0 (2)** has a signed local Release archive and development IPA. All 72 distinct fixture UI workflows have passing coverage across the full run and targeted follow-up, not one green full run. Five independent source reviews have cleared the original P1/P2 findings and follow-ups. Both live UI workflows have passing coverage across the initial run and recording retry. Native StoreKit and other platform acceptance remain open.

## Submission hold

**ON HOLD: a licensed provider/content approach has not been selected.** The owner explicitly confirmed that authorization from YouTube and the music rights holders has not been obtained. The current implementation accesses undocumented endpoints, extracts audio streams, and caches complete songs. It cannot be represented as a provider-authorized service.

Submission requires a licensed content decision and matching implementation. Attribution, optional tips, private source, and a successful local export do not grant content rights. [PROVIDERS.md](../PROVIDERS.md#distribution-and-content-rights) links the relevant YouTube terms, including Developer Policies III.E.1.

## Identity and release anchor

| Item | Recorded state |
| --- | --- |
| Current provisional public name | `Breezy - Stream Music & Chill`, 29 characters; alternatives await owner selection |
| Home Screen name | `Breezy` |
| Bundle identifier | `com.agraabhi.ganabajana` |
| Internal project/module/scheme/folder | `GanaBajana` |
| Local version/build | `1.0.0 (2)` from `project.yml`; signed Release archive and local development export generated |
| Default icon | **Leafnote** (`Beat`, primary, nil alternate name); 14 unique visible choices |
| Release anchor | Initial app release; no previous published release or release tag |
| Git | `main` |
| GitHub | Private [aagrawal207/Breezy](https://github.com/aagrawal207/Breezy); `origin` confirmed |
| Public identity/copyright | Abhishek; draft copyright `2026 Abhishek` |
| Public support contact | `aagrawal207@gmail.com`, reused from the owner's existing public support contact |

The bundle, saved-library directory, URL scheme, Keychain identity, and all five IAP product IDs retain their technical identities. The primary `AppIcon.png` is Leafnote; 15 app-icon sets include its `AppIcon-Beat` compatibility alias and Breeze's `AppIcon-Dhol`. Only 14 choices appear in the picker. Breezy remains provisional.

## Preparation state

| Area | State | Detail |
| --- | --- | --- |
| Store listing | Local build-2 draft with published URL values | [STORE_LISTING.md](STORE_LISTING.md); final name/content model and remaining acceptance unresolved |
| Consumable products | Five intended products; **none created in App Store Connect** | [IAP_MANIFEST.json](IAP_MANIFEST.json); IDs/names/prices agree with the local StoreKit catalog |
| App Store Connect app | **Not created**; no App Store app ID | 21 September API readback returned `data: []` |
| API authentication | **Working** | API key access confirmed on 21 September |
| Apple web authentication | **Unauthenticated** | `authenticated: false`, `passwordStored: true`; stored credentials do not establish a web session |
| Public Support/Privacy URLs | **Updated and readback-verified on 21 September** | Published recovery/history-epoch, sign-out, and FFmpeg sections at the Gist anchors in [PUBLIC_PAGES.md](PUBLIC_PAGES.md) |
| Settings links and copy | **Aligned** | Backup, account/provider-logging, remote-response, and cache/preparation-byte qualifications are present |
| MusicBrainz contact | **Configured** to the published Support anchor in `project.yml` | Public contact URL is available |
| Playback/cache | Native Opus MP4 preparation, AAC fallback, and reusable immutable cache variants implemented | [Architecture](../ARCHITECTURE.md#opus-preparation-cache-variants-and-reload) owns the contract; completed evidence below |
| Reviewed contracts | Receive-time bounds, request/artwork cancellation, durable listening/recovery and alert delivery, navigation/radio intent, contrast, and row accessibility implemented | [Architecture](../ARCHITECTURE.md) and [providers](../PROVIDERS.md) describe source behavior; native acceptance remains distinct |
| FFmpeg LGPL delivery | Package rebuilt, repackaged, and verified; **recipient delivery unresolved** | Matching source is recorded in [FFmpeg distribution](../FFMPEG_DISTRIBUTION.md); public URL and usable relink path remain missing |
| App name | Breezy provisional; owner selection pending | [NAMING.md](NAMING.md): Driftune/Windchord shortlist; observed Leafnote/LeafWave collisions |
| App screenshots | Home changes screenshot-checked; final App Store capture set pending | [SCREENSHOTS.md](SCREENSHOTS.md); fixture coverage does not approve marketing assets |
| IAP review screenshot | Pending real-screen capture with all five products loaded | Same actual **Settings > Support development** screen for all five products |
| Review notes/contact | Walkthrough draft; review contact fields unresolved | [REVIEW_NOTES.md](REVIEW_NOTES.md) |
| App Privacy | Source inventory drafted; final answers unresolved | [PRIVACY_REVIEW.md](PRIVACY_REVIEW.md) |
| App price/territories/age rating | Not configured | Owner decisions and final content assessment |
| Independent reviews | **Complete at source:** five reviewers cleared all original P1/P2 findings and follow-ups | [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md); platform acceptance remains separate |
| Upload/TestFlight/App Review | **No upload or submission** | The generated IPA is a local development export; the content-rights hold remains firm |

## Local release artifacts

| Artifact | Current path / scope |
| --- | --- |
| Signed Release archive | `artifacts/Breezy-1.0.0-2.xcarchive` |
| Development IPA | `artifacts/Breezy-1.0.0-2-Development/GanaBajana.ipa`; local development export |
| Archive audit | `python3 tools/audit-release.py artifacts/Breezy-1.0.0-2.xcarchive --version 1.0.0 --build 2` |

The archive audit checks identity/version/build, iPhone-only arm64, iOS 18 minimum, portrait and both landscape orientations, code signatures, FFmpeg exports and licenses, dependency acknowledgements, privacy-manifest presence, and absence of DEBUG fixture markers, test media, and StoreKit catalogs. Release uses `EXCLUDED_SOURCE_FILE_NAMES=TipJar.storekit`; the Debug Run configuration retains the local catalog. The archive and IPA are local artifacts, not App Store/TestFlight delivery.

## Verification snapshot

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
| FFmpegBridge package | Device arm64 and simulator arm64/x86_64 rebuilt, repackaged, and verified; **2.16 MiB (2,262,408 bytes)** | [Provenance](../../Vendor/FFmpegBridge/BUILD-PROVENANCE.json) records patch policy 2 and the current corresponding-source bundle. Public recipient delivery remains unresolved |
| Independent source reviews | **Five reviewers cleared all original P1/P2 findings and follow-ups** | Completed source review, not Google sign-in, StoreKit, VoiceOver, hardware, or live-provider acceptance |
| Home corner changes | Latest appearance screenshot-checked | Does not establish a final App Store capture set or an aggregate UI pass |
| Native StoreKit / real sandbox | Still blocked by `AppleStoreKitTest` configuration Code 3 / `notEntitled` | Fake-backed purchase-policy tests passed, but do not establish native product discovery, sandbox purchases, or IAP review readiness |
| Native VoiceOver / real Google sign-in / hardware | Unverified; physical-device and smaller-screen work remain deferred | Source semantics, contrast checks, synthetic account tests, and simulator layouts do not close these cases |

**Fixture result: 72 distinct workflows have passing coverage across the two UI runs, not a single green full run.** Banner Retry/Dismiss hit regions meet the actual 44-point minimum. Geometry assertions use only a `1e-6` floating-point epsilon at that threshold; artist tests wait for observable readiness, and resume assertions allow for elapsed automation time.

Live checks passed for all ten radio stations, Opus/cache, native encrypted DNS/TLS and catalog. Both LRCLIB matching failures passed on retry, and the separate live UI recording retry passed the complete synchronized-lyrics/background workflow. Provider outages and latency can still produce a plain fallback. [VERIFICATION.md](../VERIFICATION.md#live-provider-observations) preserves the initial failures and diagnostic evidence.

Fixture rotation used the explicit headless scene-geometry opt-in, preserving the same running app process. This is layout/keyboard evidence, not physical autorotation. The DEBUG-only mechanism is in [architecture](../ARCHITECTURE.md#verification-ownership); the verification target remains **iPhone 17 Pro only**.

Homebrew `ffmpeg` is installed for fixture generation. Its libraries are not linked into the app; the app uses the pinned minimal LGPL framework.

[VERIFICATION.md](../VERIFICATION.md) records detailed evidence and reproduction; [REVIEW_FINDINGS.md](../REVIEW_FINDINGS.md) records source-review closure. `tools/verify.sh` keeps native StoreKit enabled by default; `SKIP_NATIVE_STOREKIT=1` is an explicit unit/UI exclusion. Its live mode includes `ExperienceRadioLiveTests` and `LyricsFallbackLiveTests`; live UI is a separate mode.

## Remaining release work

- Native StoreKit/sandbox, real Google sign-in, native VoiceOver, and deferred hardware/smaller-screen acceptance remain open. The native StoreKit block is still Code 3 / `notEntitled`.
- Establish public recipient delivery of the verified FFmpeg source bundle and a usable rebuild/relink path. Local repackaging is complete.
- Complete Apple web authentication, app/IAP creation, real IAP review captures, and final App Store screenshots and declarations after the required content decision.

### Open owner facts and decisions

1. Which licensed provider/content approach will replace or authorize the current extraction/caching model?
2. Which public location will deliver the exact FFmpeg corresponding-source bundle and rebuild/relink materials, and what recipient relinking path will be supported?
3. Will Breezy remain the app name, or which alternative in [NAMING.md](NAMING.md) does the owner select?
4. What are the actual App Review contact details, app price, territories, and regional IAP availability?
5. What provider retention/tracking facts and support-correspondence practices support the final App Privacy answers?

Public pages are updated and verified; the local archive, development export, and FFmpeg repackaging are complete. App creation, web authentication, recipient LGPL delivery, and the owner decisions above remain open. The content-rights hold limits the work to preparation.

## Local assets

- [Store listing and launch note](STORE_LISTING.md)
- [Five-product IAP manifest](IAP_MANIFEST.json)
- [App/IAP review notes](REVIEW_NOTES.md)
- [Screenshot plan](SCREENSHOTS.md)
- [App Privacy assessment](PRIVACY_REVIEW.md)
- [Public-page publication and integration](PUBLIC_PAGES.md)
- [Provisional naming and lookup scope](NAMING.md)
- [FFmpeg source, notices, and relink delivery](../FFMPEG_DISTRIBUTION.md)
- [Support page](../../SUPPORT.md) and [privacy policy](../../PRIVACY.md)
