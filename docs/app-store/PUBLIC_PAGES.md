# Breezy public-page integration

**Current publication: published and byte-verified on 24 September 2026 UTC.** Gist revision `e84b3f6fba4d81425f5609196dc12fd59506a4ef`, updated `2026-09-24T03:23:03Z`, adds R9 official recording-language/duration metadata to the existing R6/R7/R8 guidance. Publication copies under `artifacts/AppStore-1.0.0-5/public-pages/` omit internal acceptance/signing notes, credentials and the review contact phone, and qualify standard-build CarPlay availability. The source repository remains private and the submission holds remain open.

The build-4 publication remains frozen at revision `926426dd3e3ca87502433886335e75e0d5a729eb`. The build-3 publication remains at `099a6a8032fbe5d49343bde416c99d88f05947be`, updated `2026-09-23T01:04:26Z`. Historical files and receipts under their artifact directories were not overwritten. [Release status](RELEASE_STATUS.md) owns binary and screenshot delivery separately.

The published Gist copies predate the R12/R13 local-only feature rounds (downloads and export, Song details, JioSaavn and Gaana, SponsorBlock, MusicBrainz genres, the account import) and are not being updated under the local-only decision ([ROADMAP.md](../ROADMAP.md)); root `PRIVACY.md` describes the current build and carries a maintainer note to that effect.

## Publication sources and targets

| Purpose | Local source | Public target |
| --- | --- | --- |
| Support, App Store Support URL | [Published copy](../../artifacts/AppStore-1.0.0-5/public-pages/SUPPORT.md), derived from root `SUPPORT.md` | [Support Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) |
| Privacy Policy, App Store Privacy Policy URL | [Published copy](../../artifacts/AppStore-1.0.0-5/public-pages/PRIVACY.md), derived from root `PRIVACY.md` | [Privacy Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) |
| MusicBrainz developer contact | The published Support page | [Support Gist anchor](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md), configured in `project.yml` |
| FFmpeg library source and rebuild materials | [FFmpeg distribution record](../FFMPEG_DISTRIBUTION.md) | [Public 9.0.2-patch2 release](https://github.com/aagrawal207/Breezy-FFmpegBridge/releases/tag/9.0.2-patch2), anonymous download and hashes verified; recipient application relinking remains pending |

The public document is [Gist 95acc71ba167fb754c435de17d256e59](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59). The source repository is private [github.com/aagrawal207/Breezy](https://github.com/aagrawal207/Breezy) on `main`, with that `origin` confirmed. Its blob/raw links are not public support/privacy endpoints.

The public contact is `aagrawal207@gmail.com`, with copyright `2026 Abhishek`. Apple authentication and the private App Review contact belong outside these pages. Published-copy SHA-256 values:

- Support: `91e3a2193fed8d0cd41e00423fe3d217d9a3c019ab53c5ad4fa8a86efebc2b0a`.
- Privacy: `fdc22a3169272143f8541e495762fc9f9790c52fa6a1285362a804bbddc16be6`.

The current receipt is `artifacts/AppStore-1.0.0-5/public-pages.json`, with the pre-change Gist readback in `public-pages-before.json`. Build-4 hashes remain in its frozen receipt. Historical build-3 hashes remain Support `01679fc99ea05174820a2f646a0b765cb76809cf2f1bd149e34b7463dd00b9b8` and Privacy `746f39cbe09db0231ed974d580aba5a49c7b43c95322bc82a8172fcf51efdaa5`.

## Integration state

| Integration | State |
| --- | --- |
| Public page copies | September 24 UTC readback matched the build-5 publication copies byte-for-byte |
| Root development pages | R6/R7/R8/R9 refinements are published; internal publication/acceptance notes are omitted from the public copies |
| Cross-links | Root `SUPPORT.md` links to the absolute Privacy anchor; root `PRIVACY.md` links to the absolute Support anchor. Preserve these published-link edits |
| Settings links | `Sources/Views/SettingsView.swift` wires **Help & feedback** and **Privacy policy** in **About Breezy** to the public anchors |
| MusicBrainz | `project.yml` supplies the Support anchor as `MusicBrainzContactURL` for the app Info.plist; `ArtistSpotlightMusicBrainz` can initialize with that contact |
| Store metadata | Public URLs applied and readback-verified in app `6815025307`, iOS version `1.0.0` |
| Uploaded binary | [Release status](RELEASE_STATUS.md) and `ASC_STATE.json` own exact delivery and review state |

The owner created the App Store Connect record after the CLI web-login failure. API authentication supports metadata and upload work. Publishing these pages does not publish App Privacy answers in Apple's separate questionnaire.

## Historical build-3 published scope

- **iCloud and artwork:** Support and Privacy describe default-on iCloud Drive sync for an absent device configuration, retained opt-outs, shared library/preferences and merge metadata, device-only exclusions, account changes, and retained cloud versions/backups. The green cloud indicates enablement separately from delivery status. Player artist-choice lists can fetch IDs/names and pictures before selection. Support also covers the combined album/artist chooser, native AirPlay control, grouped no-overlap defaults, collection artwork, song durations, provider song-total semantics and animated Search reselection.

- **Companion and album guidance:** Support describes attributed album summaries, background progress, Watch controls and CarPlay. Normal schemes use ordinary signing; the separate CarPlay scheme requires capability approval. Privacy describes metadata/library exchange with the paired Watch, without audio, signed media URLs or cookies. Album prose uses the existing catalog response; external article/license links open only on user action.
- **Support:** explains how to open Languages before using per-song labels, and when the control reads Browse by language. It covers retained filters, context-menu corrections, and uncertainty. Player guidance covers Shuffle and Repeat in the Queue sheet, the lyric-timing row, Autoplay's Try more songs, and that returning from the background shows the previous screen. Radio guidance covers the 34 grouped stations and that any station starts in any chosen language. Appearance guidance describes the seven icons with the two rose choices, the one-time reset for a retired icon, the hidden App icon row on Mac, and the regrouped Settings sections. Device wording says iPhone or iPad, with the Mac running the iPad app, where it is not about the paired phone.
- **Privacy:** discloses the conditional `GET /ws/2/work/<exact-linked-work-ID>?fmt=json` on `musicbrainz.org` when a compatible linked work has missing/empty embedded language fields, and that opening an artist page sends bounded collaboration searches to the catalog provider. It clarifies checks while Languages is collapsed, on-device recognition, memory-only browser/filter state, and language diagnostics without lyric text. The Encrypted DNS paragraph states the user benefit alongside the resolver mechanism, and device wording is neutral where it is not about the paired iPhone. The numerical development inspection is test-only and excluded from Release. The lookup uses the existing host and does not send lyric text.

Publication and byte comparison are recorded in `artifacts/AppStore-1.0.0-3/store-public-pages-1790125524979628000/public-pages.json`. The receipt records the public Gist revision, raw URLs and immutable-copy hashes.

## Published R6/R7/R8 refinements

These refinements were published for build 4 at revision `926426dd3e3ca87502433886335e75e0d5a729eb` and remain in the current publication.

R8 adds widget setup, saved-list/mix actions, offline behavior and system-controlled refresh guidance. Privacy describes the bounded device-local shared projection and its credential/audio exclusions. [WIDGETS.md](../WIDGETS.md) owns implementation and test mapping.

R7 adds guidance for leftmost compact AirPlay, icon-labeled Settings, Fewer repeats and Discovery balance. Privacy describes independent synced choices, on-demand saved-history ranking without a separate counter, history-off random behavior, and device-local occurrence mappings.

- **Listening-led discovery:** qualified-count language shares, optional More/Automatic/Less adjustments, history-off/cache-read behavior and preserved explicit nudges on history clear. Privacy describes bounded metadata/lyrics requests after listening while app-active, history enabled and not known offline, without requiring an artist or lyrics page visit. The derived cache is local and separate from synced preferences. [LISTENING_DISCOVERY.md](../LISTENING_DISCOVERY.md) owns the bounds and metrics.
- **Search and library:** typed Recently opened destinations, stripped collection tracks, retained legacy queries until clear, independent sync floors and shared search reset. Search has live library shortcuts and a separate Radio page; liked/playlist search preserves recording identity. Home customization is reached from Settings, and radio follows the listening profile.
- **Cache and Queue:** inventory availability versus decoder validation, local metadata joins, all-variant removal, protected in-use files, no-TTL audio retention and known-offline continuity. Queue Save captures current/upcoming songs once and saves atomically without replacing playback. Storage clears both search-history namespaces, and Next captions follow the player's actual offline-skipping order. [ARCHITECTURE.md](../ARCHITECTURE.md) records the contracts.

The new publication receipt preserves the previous revision and verifies both new file bodies. [VERIFICATION.md](../VERIFICATION.md) owns test evidence; publishing these pages does not upload a binary or store screenshot.

## In-app copy alignment

R9 adds **YouTube audio language** provenance, metadata-first checks, missing-duration preparation and the `www.googleapis.com` request/credential disclosure. The published policy distinguishes the app credential from optional saved account cookies and describes expiring local evidence. [YOUTUBE_DATA_API.md](../YOUTUBE_DATA_API.md) owns the implementation and measured coverage.

**Aligned in source:** Settings qualifies normal backups, explains that optional sign-in cannot guarantee provider acceptance or prevent account association/logging, discloses remote exchange of provider response bodies/headers, and counts all cached versions plus preparation bytes with each song counted once.

Library-reload controls and **Sign-out pending** / **Retry sign-out** states retain their failure explanations, including retry before closing when intent cannot be saved. Real-account acceptance remains a separate open check.

The owner selected Breezy. [NAMING.md](NAMING.md) retains the historical alternatives. A future rename requires coordinated public-copy updates while preserving technical IDs and storage paths.

## After the content decision

The published policy covers network downloads, conditional recording/work metadata requests, local FFmpeg packet copy, cache variants, listening recovery, pending alerts, sign-out state and backups. A licensed-provider replacement may change these behaviors. Reconcile the pages and [App Privacy assessment](PRIVACY_REVIEW.md) with that implementation before submission. The separate FFmpeg library-source publication is complete; recipient application replacement/relinking remains pending.

Publishing a contact/policy page does not resolve the [content-rights hold](RELEASE_STATUS.md#submission-hold). URL publication status and App Store submission status are recorded separately.
