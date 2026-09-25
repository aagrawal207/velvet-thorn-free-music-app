# Breezy review preparation

**Draft review details updated, not submitted.** [review-notes.txt](review-notes.txt) is the exact, readback-verified text on review detail `d4b2f115-ac13-46c4-8c98-848b3fdefce0`. Its **3,914 characters** describe reviewer navigation, screenshot provenance and the public FFmpeg library-source link. The images use post-build-5 source and require a matching binary before review. Contact fields were preserved and no demo account is required. Current receipt: `artifacts/AppStore-1.0.0-5/review-1790309749262953000/summary.json`; the 3,887-character screenshot-refresh receipt remains historical. Provider authorization and recipient application relinking remain unresolved.

**1.0.0 (5)** is uploaded, valid and attached to the iOS draft for app `6815025307`. The owner selected Breezy. Leafnote is the default among 7 icons. The app targets iPhone/iPad and supports Designed for iPad on Apple silicon. [Release status](RELEASE_STATUS.md) and [ASC_STATE.json](ASC_STATE.json) record the binary and remote state.

The Watch companion controls iPhone playback and browses its saved library. CarPlay browsing requires the dedicated signing configuration and Apple's approved entitlement; the uploaded standard build omits it. An uploaded binary is separate from App Review submission, which remains on hold.

## Detailed local walkthrough

The longer reference below describes the current implementation. The shorter `review-notes.txt` is the actual remote notes field.

```text
Breezy is an iPhone and iPad music player. Complete the welcome screen if it appears.

Home contains recently played music and discovery sections. Customize Home saves section order and visibility. Personal mixes and recap need listening history; their absence on a fresh installation is expected.

Blank Search has Liked songs, Cached songs, library shortcuts and Recently opened. Radio opens a separate page with 34 stations grouped as Moods and Genres. The first Search-tab tap does not force the keyboard; reselection returns to the top and focuses the existing query. Languages follow listening history and saved adjustments, with no required language selection. Zero to four artist hints are optional. Era preference guides starting songs and searches, but related songs may span other years or lack language labels. Failed discovery has an explicit retry path.

Tap a song, then open the mini-player for full-screen Now Playing. The fixed controls are previous, play and next. More at the top opens additional actions. The bottom row has AirPlay, Lyrics, Album and artists, and Queue. Album and artists opens an available album destination and directly selectable artists while pictures load. AirPlay uses Apple's native audio-output control. Shuffle, Repeat and Save remaining songs are in Queue; lyric timing controls are at the bottom of Lyrics. If Autoplay cannot find more songs, Queue explains why and offers Try more songs. Swipe down or use the top chevron to minimize. Returning from the background shows the previous screen. Lyrics availability and timing depend on the matched provider response.

Add Recently played, Liked songs or Mix from the native Home Screen widget gallery. All support small, medium and large sizes. Edit Mix to choose Daily Mix or Discover Weekly. Widgets use the saved library and can be empty on first launch. Song and Play mix actions open Breezy; headings and the small Mix widget browse without replacing playback. Compatible complete cached audio can play offline. An uncached widget selection is refused without replacing current playback.

More > Audio quality shows source encoding metadata. Reload best available audio requests fresh selection and keeps a usable cached fallback. On iOS 26.5+, eligible Opus WebM is prepared locally as MP4 without re-encoding and checked through native PCM decoding before playback. Older systems use AAC. A prepared higher-quality variant can be reused on later plays; existing in-use files stay protected. Source availability and Premium bitrates are not guaranteed.

Artist pages include This is [artist], sorted by available provider play counts. Open Languages or Browse by language for filters and per-song evidence or corrections. The song list starts without those annotations. A Featuring [artist] section lists collaborations found through search, where the artist is a later credit or named in a feat. clause. Monthly audience text is the provider's metric, when available.

Explicit recording audio-language tags from the official YouTube Data API can avoid lyrics classification. Missing metadata keeps the existing fallback; saved corrections win. The API can fill a missing duration in a temporary lyrics/MusicBrainz lookup copy without changing the saved track. Title language is not used as audio-language evidence.

Settings has Playback, Library & iCloud, Appearance, Discovery, Account & connection, and About Breezy sections. Storage and recovery controls are under Library & iCloud; Home customization, languages and alerts are under Discovery. The App icon row appears only where iOS allows alternate icons, so it is absent on a Mac running the iPad app. Help & feedback and Privacy policy open the public pages. Audio usage counts all committed encodings and active preparation bytes; song count is by recording. Clearing unused audio protects files needed for playback. Cached audio is purgeable; saving a playlist does not create an offline library.

iCloud sync starts enabled when the device has no saved sync configuration. A saved Off choice remains off. Library & iCloud > iCloud sync has the toggle, status and manual retry. The green cloud means the preference is enabled; a local save for iCloud does not confirm delivery to another device. Sync uses iCloud Drive on the same Apple Account. An account change pauses sync until explicitly enabled for that account. Playback position, sign-in credentials, tip records and media files are device-local.

If a storage error offers Reload saved library, it validates the saved file and applies recovered preferences while preserving a current queue. An untouched failed-startup state can restore a recovered queue paused. Unsaved listening is buffered only during the app session; a full buffer pauses playback. Successful history clearing or disabling retires pending listening.

New release alerts require notification permission. Pending release-alert IDs survive relaunch and can retry before another catalog refresh is due. Turning alerts off or unfollowing removes the corresponding pending records when saved; notifications already submitted to iOS are separate. If YouTube sign-out cannot finish, Settings shows Sign-out pending and Retry sign-out. Follow the displayed error, including retrying before closing when the sign-out marker could not be saved.

For in-app purchases, open Settings > Support development in the About Breezy section. All five products use this one screen. They are optional, repeatable one-time consumable tips supporting development. They unlock no features or music and are not subscriptions. Names, descriptions and prices come from StoreKit. No Breezy account or YouTube sign-in is needed to open the tip screen.
```

## IAP configuration and review evidence

[IAP_MANIFEST.json](IAP_MANIFEST.json) records all five created products and their editable review-version IDs, en-US localizations, USA prices and review-screenshot IDs. All five parent products report `READY_TO_SUBMIT`; they have not been submitted. The manifest is a local record, not an Apple API payload.

The manifest identifies build 5 as the current candidate and preserves build-3 IAP screenshot provenance. Support/Privacy publication copies are current and byte-verified. The signed App Store IPA passed Apple validation, upload and processing. Apple's add-item response confirms missing App Privacy publication; the cached web session remains expired for questionnaire and agreement work.

- The app's remote review notes explain the shared route: **Settings > Support development**, in **About Breezy**. `sharedReviewNotes` remains available for a product-specific notes field when supported.
- All five products have the same actual in-app review screenshot, showing the optional-tip explanation and all five loaded names/prices. Their delivery states and checksums were verified; the manifest records the file and attachment IDs.
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
| UI/review evidence | `iap-shots-ios27-02.xcresult`, 1 passed | Actual native StoreKit screen with all five names, descriptions and USA prices; no purchase was attempted |

Historical fixture UI results cover 72 distinct workflows across runs, with native StoreKit/live UI excluded. The build-3 product-display capture passed on iOS 27 despite logged StoreKit configuration/override diagnostics. The earlier iOS 26.5 transaction-suite Code 3 / `notEntitled` failure remains in its original results. Neither product display nor fake-backed policy tests establish sandbox purchases, refunds or transaction recovery.

Live provider failures passed their targeted LRCLIB retry. The complete live UI recording workflow subsequently passed playback, seek, synchronized lyrics and background/reactivation; the diagnostic found valid timing with the actual recording duration. The earlier plain fallback remains recorded as a failed synced-lyrics expectation. Native VoiceOver, real Google sign-in, and hardware acceptance remain open. Exact results and source-review closure are in [RELEASE_STATUS.md](RELEASE_STATUS.md#verification-snapshot).

## Bundled FFmpeg component

The app dynamically links FFmpegBridge for local packet-copy preparation only. [FFMPEG_DISTRIBUTION.md](../FFMPEG_DISTRIBUTION.md) identifies the published library source, notices and rebuild instructions, with anonymous download and checksum verification. The reviewer-note link points to that release. Recipient application relinking and content authorization remain unresolved.

## Account and review-contact fields

The app has no Breezy account requirement. Catalog browsing uses account-cookie-free requests. Optional Google sign-in is an implemented playback fallback, but a real-account end-to-end check remains pending. The final review path must describe any actual provider access restrictions; no demo credentials have been supplied.

| Field | State |
| --- | --- |
| App Review contact name | Abhishek Agrawal; owner approved reuse of the existing review contact |
| App Review contact phone | Copied and verified privately in App Store Connect; omitted from repository/public-page records |
| App Review contact email | `aagrawal207@gmail.com`, explicitly approved with the reused contact |
| Demo account | None supplied; reassess after the licensed-provider decision |
| Content-rights declaration | Blocked: authorization absent; no affirmative rights declaration prepared |
| Public Support URL | [Published Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) |
| Public Privacy Policy URL | [Published Privacy Policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |

For the content-rights field, the app does access third-party content. It cannot truthfully declare that no third-party content is accessed or that permission has been obtained. The selected content model must resolve this before submission.
