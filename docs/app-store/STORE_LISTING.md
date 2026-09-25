# Breezy store listing

**Metadata readback-verified for 1.0.0 (5) delivery on 24 September 2026 UTC.** The owner selected **Breezy - Stream Music & Chill**, app `6815025307`. The iOS draft remains the initial `1.0.0` version. The canonical metadata still matches the September 23 push, with an empty follow-up diff. [ASC_STATE.json](ASC_STATE.json) records binary upload and processing separately.

**Submission remains on hold.** YouTube/music-rights-holder authorization and a usable recipient application relinking path are not established. FFmpeg library source and rebuild materials are public and verified. [Release status](RELEASE_STATUS.md#submission-hold) and [FFmpeg distribution](../FFMPEG_DISTRIBUTION.md) own the remaining requirements. This copy describes the current implementation and needs reconciliation with the final licensed provider/content approach before use.

## App information

| Field | Local value or setup input |
| --- | --- |
| App Store app ID | `6815025307`, manually created by the owner |
| Bundle identifier | `com.agraabhi.ganabajana` |
| SKU | `BREEZY-IOS` |
| Primary locale | English (U.S.), `en-US` |
| Selected name | `Breezy - Stream Music & Chill` (29/30 characters) |
| Subtitle | `Radio, lyrics & daily mixes` (27/30 characters) |
| Primary category | Music, remote value verified |
| Platform | iOS, iPhone and iPad; minimum iOS 18. Mac availability through Designed for iPad on Apple silicon is an App Store Connect choice |
| Home Screen name | Breezy |
| Version | `1.0.0`, initial iOS release; remote version ID `2754a299-5b46-4e62-8f79-8bf80c6078d5` |
| Target build | `5`; archive and App Store export are audited; delivery status belongs to [ASC_STATE.json](ASC_STATE.json) |
| Default icon | Leafnote; 7 unique visible choices, including Thorn and Sonnet |
| Copyright | `2026 Abhishek` |
| Support URL | [Existing Support anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) |
| Privacy Policy URL | [Existing Privacy anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |
| Marketing URL | Not supplied; leave unset |
| App price and territories | Free in all 175 current territories, with new territories enabled; remote availability and USA free price verified |
| Optional tips | Five `READY_TO_SUBMIT` consumables, available in 175 territories; USA prices $3, $5, $10, $25 and $50 verified. The app displays localized StoreKit prices |
| Release date and mode | Existing draft uses `AFTER_APPROVAL`; no review submission or release date set |
| Age rating and App Privacy answers | Pending assessment of the final content/provider model |

`GanaBajana` remains the internal module/project/folder. The selected public name preserves the bundle, library path and product IDs. Current receipts are under `artifacts/AppStore-1.0.0-5/`; frozen build-3/build-4 receipts remain in their original directories. [Release status](RELEASE_STATUS.md) records upload, processing and submission.

## Canonical metadata files

| File | Flat JSON fields |
| --- | --- |
| [app-info/en-US.json](asc-metadata/app-info/en-US.json) | `name`, `subtitle`, `privacyPolicyUrl` |
| [version/1.0.0/en-US.json](asc-metadata/version/1.0.0/en-US.json) | `description`, `keywords`, `promotionalText`, `supportUrl` |

Unset optional fields are omitted rather than written as empty strings. `marketingUrl` is omitted. `whatsNew` is omitted for this first release; the launch note below stays local. Copyright belongs to the version resource, outside these localization files.

## Promotional text

Validated against Apple's 170-character limit.

```text
Keep favorites and mixes on your Home Screen. Explore radio shaped by your listening, search saved music and return to fully cached songs offline.
```

## Description

The exact App Store Connect description is the `description` field in [version/1.0.0/en-US.json](asc-metadata/version/1.0.0/en-US.json), validated against the 4,000-character limit. It covers listening-led radio/discovery, three widget types, saved Search and Queue actions, Fewer repeats and compatible complete-cache playback. It retains the iCloud/device-local boundary, unofficial-provider disclosure and optional-tip explanation.

## Keywords

Validated against the 100-character limit. Terms already in the name or subtitle are not repeated.

```text
playlists,hindi,english,bollywood,artists,albums,recap,crossfade,sleep timer,lofi,widgets,offline
```

## Initial release note

Local launch copy only. The canonical version JSON deliberately omits `whatsNew` for Apple's first-release workflow.

```text
- Use recording-language metadata when available, with cached checks for missing language tags.
- Improve lyrics matching when a recording's duration is missing.
- Add Recently played, Liked songs and Mix widgets to your Home Screen.
- Explore radio and personal mixes shaped by your listening.
- Choose Fewer repeats for new shuffles and adjust your Discovery balance.
- Search saved music, return through Recently opened and save your queue as a playlist.
- Resume fully cached songs offline and manage cached storage.
```

## Public-page publication copies

The existing Gist anchors contain these publication copies, published and byte-verified at revision `e84b3f6fba4d81425f5609196dc12fd59506a4ef`:

- [SUPPORT.md](../../artifacts/AppStore-1.0.0-5/public-pages/SUPPORT.md), for the existing `#file-support-md` anchor.
- [PRIVACY.md](../../artifacts/AppStore-1.0.0-5/public-pages/PRIVACY.md), for the existing `#file-privacy-md` anchor.

The copies retain the public email, absolute Support/Privacy cross-links and copyright. They omit the internal publication-status paragraphs, signing/build instructions and test-acceptance reports. User troubleshooting, provider/account data flows, backup scope, default-on iCloud behavior and retained cloud versions remain. The CarPlay help states the standard app's availability limit. Review contact details do not belong in these pages.

## Source alignment and open facts

| Topic | Copy decision and source |
| --- | --- |
| Radio and discovery | Languages follow qualified listening and explicit adjustments; setup has no required language picker. All 34 stations retain zero to four optional artist hints. Era and language evidence guide discovery rather than certify each song. [LISTENING_DISCOVERY.md](../LISTENING_DISCOVERY.md) |
| Recording metadata | Explicit audio-language tags can skip recognition; missing duration is confined to temporary lookup copies. Availability is recording-specific and title language is not audio evidence. [YOUTUBE_DATA_API.md](../YOUTUBE_DATA_API.md) |
| Widgets and offline playback | Three widget types use saved metadata and native actions. Offline playback requires complete, compatible retained audio; likes and playlists do not download music. [WIDGETS.md](../WIDGETS.md), [LISTENING_DISCOVERY.md](../LISTENING_DISCOVERY.md) |
| Original appearance assets | Seven visible icons: Leafnote, Drift, Moonleaf, Ripple, Tide, Thorn and Sonnet. The retained primary compatibility alias is not an eighth choice. Seven accent colors. Original icon artwork does not grant rights to provider music, lyrics or artwork. [AppIcons.swift](../../Sources/UI/AppIcons.swift), [AppAccent.swift](../../Sources/Core/AppAccent.swift) |
| Player and Settings | Crossfade is 0 seconds and Automix is off by default; saved choices survive. Support keeps the combined Album and artists chooser, native AirPlay button and all six Settings sections. [LibraryModels.swift](../../Sources/Core/LibraryModels.swift), [SettingsView.swift](../../Sources/Views/SettingsView.swift), [NowPlayingView.swift](../../Sources/Views/NowPlayingView.swift) |
| Collection artwork and counts | Artist headers use 90% of the responsive cover size. Song play totals remain separate from upload views and are provider snapshots. A screenshot or sample recording does not establish universal counts, lyrics, audio quality or offline availability. [CollectionDetailView.swift](../../Sources/Views/CollectionDetailView.swift), [PlayerController.swift](../../Sources/Playback/PlayerController.swift) |
| iCloud | An absent device configuration enables sync; saved Off choices and account-change pauses stay authoritative. The green cloud indicates enablement, not delivery. Shared preferences, device-only exclusions, restored-installation defaults and retained versions/backups remain in the public copies. [ICLOUD_SYNC.md](../ICLOUD_SYNC.md) |

The remaining owner facts are the licensed content/provider decision, recipient source/relink delivery, and provider retention/linkage/tracking plus support-correspondence and diagnostic practices needed for final App Privacy answers. The copy does not select a blanket “Data Not Collected” answer or an age rating.

Native two-device iCloud delivery, a real AirPlay receiver and native StoreKit/sandbox purchases remain unverified. [VERIFICATION.md](../VERIFICATION.md) records R9 and historical checks; metadata validation does not establish runtime behavior or review readiness.

## Local validation

Character counts above include spaces and decoded paragraph breaks. All localized store text uses plain copy without em dashes. Validate the flat scopes and Apple's field limits offline with:

```sh
asc metadata validate --dir docs/app-store/asc-metadata
```

Passed again on 24 September 2026 UTC: **2 files scanned, 0 errors, 0 warnings, `valid: true`, `issues: []`**. The September 23 push changed description, keywords and promotional text; the current read-only follow-up plan has no adds, updates or deletes. `artifacts/AppStore-1.0.0-5/final-record-audit.json` records the final validation and live readback.

## Supporting assets

- [IAP manifest](IAP_MANIFEST.json): all five intended consumable tips.
- [Review notes](REVIEW_NOTES.md): screen path, purchase behavior and private reviewer details, maintained by the coordinator.
- [Screenshot plan](SCREENSHOTS.md): real-app captures and separate IAP review evidence.
- [Privacy assessment](PRIVACY_REVIEW.md) and [public-page integration](PUBLIC_PAGES.md).
- [Naming research](NAMING.md): historical alternatives; the owner has selected the name above.
- [FFmpeg source and relink delivery](../FFMPEG_DISTRIBUTION.md).

Avoid claims of authorized YouTube access, paid music access, lossless/hi-fi quality, strict all-track radio filtering, universal lyrics coverage, or guaranteed offline playback. A tip is support for development, not ad removal or a music entitlement.
