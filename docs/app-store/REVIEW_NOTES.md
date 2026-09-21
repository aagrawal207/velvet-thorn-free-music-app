# Breezy review preparation

**Local draft, not submitted.** The [content-rights hold](RELEASE_STATUS.md#submission-hold) prevents submission of the current extraction/caching implementation. A walkthrough does not supply distribution permission. Reconcile these notes with the final licensed content implementation and release candidate before attaching them to App Review.

The current candidate is **1.0.0 (2)**, with a signed local Release archive and development IPA. Breezy remains provisional, with [name selection pending](NAMING.md). Leafnote is the default icon among 14 visible choices. [Release status](RELEASE_STATUS.md) records the local artifacts, multi-run test coverage, and remaining acceptance.

## Draft app walkthrough

```text
Breezy is an iPhone music player. Complete the welcome screen if it appears.

Home contains recently played music and discovery sections. Customize Home saves section order and visibility. Personal mixes and recap need listening history; their absence on a fresh installation is expected.

Open Search to browse suggestions, recent searches and genre/mood radio stations. The first Search-tab tap does not force the keyboard; reselection returns to the top and focuses the existing query. Radio setup requires at least one language. Artist hints are optional, with none selected by default; zero or one hint is valid. Era preference guides starting songs and searches, but related songs may span other years or lack language labels. Failed discovery has an explicit retry path.

Tap a song, then open the mini-player for full-screen Now Playing. More at the top opens the additional-actions sheet. Lyrics and Queue have separate sheets. Swipe down or use the top chevron to minimize. The mini-player grows with text size and has reserved space on pushed pages as well as tab roots. Lyrics may be synchronized, plain, unavailable or temporarily failed, depending on the matched response.

More > Audio quality shows source encoding metadata. Reload best available audio requests fresh selection and keeps a usable cached fallback. On iOS 26.5+, eligible Opus WebM is prepared locally as MP4 without re-encoding and checked through native PCM decoding before playback. Older systems use AAC. A prepared higher-quality variant can be reused on later plays; existing in-use files stay protected. Source availability and Premium bitrates are not guaranteed.

Artist pages include This is [artist], sorted by available provider play counts. Per-song language labels show evidence or uncertainty and allow a local correction. Monthly audience text is the provider's metric, when available.

Settings contains playback preferences, Storage, appearance choices, history controls and optional YouTube sign-in. Help & feedback and Privacy policy open the public pages. Audio usage counts all committed encodings and active preparation bytes; song count is by recording. Clearing unused audio protects files needed for playback. Cached audio is purgeable; saving a playlist does not create an offline library.

If a storage error offers Reload saved library, it validates the saved file and applies recovered preferences while preserving a current queue. An untouched failed-startup state can restore a recovered queue paused. Unsaved listening is buffered only during the app session; a full buffer pauses playback. Successful history clearing or disabling retires pending listening.

New release alerts require notification permission. Pending release-alert IDs survive relaunch and can retry before another catalog refresh is due. Turning alerts off or unfollowing removes the corresponding pending records when saved; notifications already submitted to iOS are separate. If YouTube sign-out cannot finish, Settings shows Sign-out pending and Retry sign-out. Follow the displayed error, including retrying before closing when the sign-out marker could not be saved.

For in-app purchases, open Settings > Support development in the About Breezy section. All five products use this one screen. They are optional, repeatable one-time consumable tips supporting development. They unlock no features or music and are not subscriptions. Names, descriptions and prices come from StoreKit. No Breezy account or YouTube sign-in is needed to open the tip screen.
```

## IAP configuration and review evidence

[IAP_MANIFEST.json](IAP_MANIFEST.json) records the five intended product IDs, display names, descriptions, and US base prices. It is a local manifest, not an Apple API payload. No App Store Connect app, products, or numeric IAP IDs have been created.

The manifest records build 2 and the public Support/Privacy URLs, whose updated pages were readback-verified on 21 September. App Store Connect API access works, but the web session is unauthenticated and app readback is `data: []`. The local development IPA is not an App Store upload.

- Apply `sharedReviewNotes` to each product. The route is **Settings > Support development**, in **About Breezy**.
- All five products use the same actual in-app screen. The review screenshot must show the optional-tip explanation and all five loaded names/prices. Capture remains pending; no screenshot path in the manifest is claimed to exist.
- The local `Resources/TipJar.storekit` remains attached to **Debug Run**. Release excludes it through `EXCLUDED_SOURCE_FILE_NAMES=TipJar.storekit`, and the archive audit checks that no StoreKit catalog is bundled. Local USA/en_US prices simulate purchases; production buttons use `Product.displayPrice`.
- Product IDs stay in the `com.agraabhi.ganabajana.tip.*` namespace across the rebrand. Apple product IDs are not editable after creation.
- Names fit Apple's 30-character limit. The existing descriptions are 28–39 characters, within both the requested 55-character ceiling and Apple's current, stricter **45-character** description limit.

Apple's [In-App Purchase information reference](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/) distinguishes a review-only screenshot from a promotional product image. Review screenshots must meet a supported screenshot specification. A 1024-square promotional image does not replace the required real in-app review screenshot. Limits checked on 20 September 2026.

## Purchase behavior and verification boundaries

`TipJarService` verifies an allowlisted consumable transaction and saves its ID/credit state atomically before finishing it. Repeated tips have distinct transaction IDs. Duplicate purchase/update/recovery delivery must not add another credit. Refund/revocation records prevent stale delivery from re-crediting a tip. A failed library write leaves the transaction unfinished for recovery rather than asking for another purchase.

The source includes these test groups; this is a coverage map, not a result claim:

| Coverage | Source | Cases |
| --- | --- | --- |
| Fake-backed unit policy | `Tests/TipJarServiceTests.swift` | Product allowlist; missing/failed load and retry; purchase gates; cancellation; pending approval; verified/unverified/revoked results; duplicate and concurrent delivery; persistence failures |
| Unit persistence | `Tests/TipJarPersistenceTests.swift` | Ledger reload; history-clear preservation; legacy decoding; corrupt/future stores; write failure; stale-writer/refund protection |
| Native StoreKit integration | `Tests/TipJarStoreKitTests.swift` | Five real local products/prices; partial load; repeat purchases; unfinished recovery; pending/refund updates; retry/cancel; verification and storage recovery |
| UI/review evidence | Actual in-app capture, pending | Find the tip screen, show all five products and localized prices, then record the tested purchase states |

The fixture UI results cover all 72 distinct workflows across the full run and targeted follow-up, not one green full run. Native StoreKit and live UI were excluded from fixtures. Native StoreKit remains blocked by Code 3 / `notEntitled`; fake-backed passes do not establish purchases.

Live provider failures passed their targeted LRCLIB retry. The complete live UI recording workflow subsequently passed playback, seek, synchronized lyrics and background/reactivation; the diagnostic found valid timing with the actual recording duration. The earlier plain fallback remains recorded as a failed synced-lyrics expectation. Native VoiceOver, real Google sign-in, and hardware acceptance remain open. Exact results and source-review closure are in [RELEASE_STATUS.md](RELEASE_STATUS.md#verification-snapshot).

## Bundled FFmpeg component

The app dynamically links FFmpegBridge for local packet-copy preparation only. Framework rebuilding, source repackaging, and verification are complete. [FFMPEG_DISTRIBUTION.md](../FFMPEG_DISTRIBUTION.md) identifies the matching bundle. Public recipient source/relink delivery and content authorization remain unresolved for review metadata.

## Account and review-contact fields

The app has no Breezy account requirement. Catalog browsing uses account-cookie-free requests. Optional Google sign-in is an implemented playback fallback, but a real-account end-to-end check remains pending. The final review path must describe any actual provider access restrictions; no demo credentials have been supplied.

| Field | State |
| --- | --- |
| App Review contact name | TBD from owner; public first name alone does not supply all required review fields |
| App Review contact phone | TBD from owner |
| App Review contact email | TBD from owner; do not silently treat the support address as an approved review-contact identity |
| Demo account | None supplied; reassess after the licensed-provider decision |
| Content-rights declaration | Blocked: authorization absent; no affirmative rights declaration prepared |
| Public Support URL | [Published Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) |
| Public Privacy Policy URL | [Published Privacy Policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |

For the content-rights field, the app does access third-party content. It cannot truthfully declare that no third-party content is accessed or that permission has been obtained. The selected content model must resolve this before submission.
