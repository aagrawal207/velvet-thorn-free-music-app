# Breezy

**Breezy - Stream Music & Chill** is a native iPhone music app for iOS 18+, built with Swift 6, SwiftUI, and AVPlayer. It has audio-only playback, personal mixes, radio, and recording-matched lyrics. Native Liquid Glass is used on iOS 26+ with older-system fallbacks.

**App Review submission is on hold for content rights.** The current implementation uses unofficial YouTube extraction and complete-song caching. The owner has confirmed that authorization from YouTube and the rights holders has not been obtained. A licensed provider/content approach must be selected before submission. See [release status](docs/app-store/RELEASE_STATUS.md) and [provider limitations](docs/PROVIDERS.md#distribution-and-content-rights).

## Identity

| Use | Value |
| --- | --- |
| Current provisional App Store name | `Breezy - Stream Music & Chill` (29 characters); alternatives await owner selection |
| Home Screen name | `Breezy` |
| Bundle identifier | `com.agraabhi.ganabajana` |
| Project, module, scheme, and repository folder | `GanaBajana` |
| Saved library | `Application Support/GanaBajana/library.json` |
| Source repository | [aagrawal207/Breezy](https://github.com/aagrawal207/Breezy), private by the owner's choice |

The first release candidate is **1.0.0 (2)**, with a signed local Release archive and development IPA. All 72 distinct fixture UI workflows have passing coverage across the full run and follow-up, not one green full run. Five independent source reviews are complete. Live playback, synchronized lyrics, background continuation and autoplay passed across the live UI run and retry. Native StoreKit and other platform acceptance remain open. [Release status](docs/app-store/RELEASE_STATUS.md) records the artifacts, results, and limits. Breezy remains provisional; technical identities preserve the installed library.

## Current features

- **Home that you arrange.** Recently played comes first by default. Customize Home saves section order and visibility. Daily Mix, Discover Weekly, followed-artist releases, and dated weekly chart picks appear when data is available. Compact artwork corners and mix titles below the art keep the layout simple.
- **Search and recent queries.** Search songs, artists, albums, and playlists in any language. The first Search-tab tap opens Search without forcing the keyboard. Reselecting it returns to the top and focuses the existing query. Up to 20 deliberately committed searches are saved locally.
- **Ten genre and mood radios.** Choose at least one discovery language and an era preference. Artist hints are optional, with none selected by default. Station cues, style searches, provider playlists, and related-song radio build the queue. Preferences guide discovery rather than certify every track; unavailable results have an error and retry path.
- **Artist pages with sources.** “This is [artist]” sorts available songs by provider play count, with unknown counts last. Recording-level language evidence and local corrections support filtering. Inferences are labelled, and uncertain songs remain in All/Unclassified. Monthly audience figures retain the provider's metric and wording.
- **A one-handed player.** Full-screen Now Playing keeps its main controls fixed, with scrollable More, Lyrics, and Queue sheets. The mini-player has a 64-point minimum height and grows with Dynamic Type. Its reserved space covers pushed pages as well as tab roots; volume uses system controls.
- **Listening controls.** Crossfade, gapless playback, Automix, Autoplay, attenuation-only volume normalization, and a sleep timer. Artist navigation includes linked credits and artists named in feature clauses. Autoplay filters disliked songs and duplicate song versions.
- **Source audio details.** More shows available encoding metadata and offers **Reload best available audio**. On iOS 26.5+, eligible Opus audio is prepared locally for native playback, with AAC fallback. A successfully prepared higher-bitrate cache variant can be reused on later plays while existing in-use files remain protected.
- **Lyrics when available.** LRCLIB is primary; a recording-linked YouTube Music lookup supplies plain-text fallback. Timed lyrics require matched source timestamps. Source credits include LyricFind or Musixmatch when YouTube Music supplies that attribution.
- **A saved library and personal recap.** Likes, playlists, follows, queue position, and history persist locally. Failed listening saves remain buffered during the session, with a protective pause at capacity. **Reload saved library** validates recovered disk state while keeping current playback. Recap uses rolling week/month/year windows; pending local release alerts survive relaunch and can retry.
- **Appearance choices.** Fourteen original icons, with **Leafnote** selected as the default, seven accent palettes, and dark, light, or system appearance. Leafnote is the icon name, not an app rename. Shared fonts respond to Dynamic Type, with compact cards and controls.
- **Storage controls and optional tips.** Settings shows actual cache and library usage, lets the listener clear unused audio/artwork and recent searches, and offers five one-time consumable tips that unlock no features or music.

The audio cache defaults to **1 GiB or 200 logical songs**, with five size choices. Usage includes every committed encoding and active preparation bytes. Ordinary playback uses the best compatible cached variant; iOS can purge it, and uncached music needs a connection. There is no managed offline-download library or guaranteed source bitrate. See [cache policy and audio quality](docs/PROVIDERS.md#audio-cache-and-quality).

Provider requests go directly from the phone; there is no Breezy app backend. Optional YouTube account cookies are held separately in the Keychain and used only for a specific playback lookup. Remote extraction is off by default. Library data may be included in device backups, and providers receive request data and network addresses. [Privacy](PRIVACY.md) describes those distinctions.

## Development

Developed with **Xcode 27**, **Swift 6**, and **XcodeGen**. From the repository root:

```sh
xcodegen generate
open GanaBajana.xcodeproj
```

Select `GanaBajana` and the dedicated **GanaBajana QA iPhone 17 Pro** simulator. `project.yml` is the configuration source of truth. Verification is limited to iPhone 17 Pro; smaller-screen and physical-device checks are deferred.

| Scheme | Purpose |
| --- | --- |
| `GanaBajana` | Debug development, unit tests, and fixture UI tests; Debug Run uses `Resources/TipJar.storekit` |
| `GanaBajanaLive` | Opt-in live provider checks, including experience radio, lyrics fallback, and encrypted DNS/TLS |
| `GanaBajanaLiveUI` | Opt-in live playback UI workflow |

`tools/verify.sh` supports `unit`, `ui`, `live`, `live-ui`, and `release`, regenerating the project and keeping outputs under `artifacts/`. `SKIP_NATIVE_STOREKIT=1` explicitly excludes native StoreKit from unit/UI runs; the default is 0. Fixture UI excludes live UI. Headless rotation uses the explicit scene-geometry opt-in described in [architecture](docs/ARCHITECTURE.md#verification-ownership).

Release mode creates a local archive, unsigned by default or signed with `RELEASE_SIGNING=automatic`. `python3 tools/audit-release.py <archive> --version 1.0.0 --build 2` checks the archived app's identity, platform, signatures, dependency notices/exports, and absence of test resources. Release excludes `TipJar.storekit` while Debug retains it. The current development IPA is a separate local export, not an App Store upload. [Verification](docs/VERIFICATION.md) records execution details.

The app dynamically links the minimal [FFmpegBridge](Vendor/FFmpegBridge/README.md) XCFramework for local WebM-to-MP4 packet copy, with no re-encoding or network/decoder stack. Homebrew `ffmpeg` only generates fixtures. Framework rebuilding, source repackaging, and package verification are complete; public recipient-source/relink delivery remains unresolved in [FFmpeg distribution](docs/FFMPEG_DISTRIBUTION.md).

If Xcode reports a missing local YouTubeKit package after project regeneration, close and reopen the project to refresh its package graph before investigating package configuration.

## Documentation

- [Architecture and API contracts](docs/ARCHITECTURE.md)
- [Providers, data handling, and attribution](docs/PROVIDERS.md)
- [Initial release status and local artifacts](docs/app-store/RELEASE_STATUS.md)
- [Provisional name and candidate lookup record](docs/app-store/NAMING.md)
- [Store listing](docs/app-store/STORE_LISTING.md), [IAP manifest](docs/app-store/IAP_MANIFEST.json), and [review notes](docs/app-store/REVIEW_NOTES.md)
- [Screenshot plan](docs/app-store/SCREENSHOTS.md) and [App Privacy assessment](docs/app-store/PRIVACY_REVIEW.md)
- [Support](SUPPORT.md), [privacy policy](PRIVACY.md), and [public-page integration](docs/app-store/PUBLIC_PAGES.md)
- [Acknowledgements](Resources/Acknowledgements.txt): YouTubeKit's MIT notice and FFmpeg/FFmpegBridge's LGPL notice; [FFmpeg source and relinking record](docs/FFMPEG_DISTRIBUTION.md)

[Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) and [Privacy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) were updated on **21 September 2026** and verified by readback. Settings and `MusicBrainzContactURL` use those public targets, and Settings copy includes the backup/provider/cache qualifications. [PUBLIC_PAGES.md](docs/app-store/PUBLIC_PAGES.md) records integration. App Store setup and the content-rights hold remain open.
