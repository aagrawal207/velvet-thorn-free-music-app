# Breezy

Native iPhone app using Swift 6, SwiftUI, AVPlayer, and iOS 18+. Current provisional App Store name: `Breezy - Stream Music & Chill`; Home Screen name: `Breezy`. Naming alternatives in `docs/app-store/NAMING.md` await owner selection. Keep `GanaBajana` as the project/module/folder, `com.agraabhi.ganabajana` as the bundle ID, and the existing library path and product IDs. Branding must preserve installed data.

## Code and persistence contracts

- `project.yml` is the XcodeGen source of truth. Build outputs belong in `artifacts/`. The coordinator owns regeneration and builds during coordinated work.
- Reuse shared models and provider protocols in `Sources/Core/`. [ARCHITECTURE.md](docs/ARCHITECTURE.md) records the concrete APIs; do not introduce parallel track, playlist, artist-credit, or lyrics models.
- `MusicAppModel` coordinates views, `PlayerController` owns playback, and `LibraryStore` owns saved state. Mutable UI services are main-actor isolated; network providers are actors.
- Preference changes go through `MusicAppModel.updatePreferences(_:)` so persistence failures and dependent playback/DNS/cache settings stay consistent.
- Library writes are versioned and atomic. Preserve corrupt, unsupported, future-version, or externally changed stores and surface the error. Fixtures use isolated storage and remain excluded from Release.
- `recordListening` and `onListeningProgress` return a durable Bool acknowledgement. Keep rejected deltas in the bounded session buffer and pause before dropping them. Clear/history-disable boundaries retire pending time; `reloadSavedLibrary()` validates disk state, reconciles preferences, and preserves newer playback intent.
- A failed-startup empty placeholder must not overwrite a repaired saved queue through lifecycle or restore callbacks. Restore recovered startup state paused only while that placeholder remains untouched.
- Persist recording IDs and metadata, never signed media URLs. Playback generations reject stale extraction, seek, transition, and radio callbacks. Restored playback stays paused; listening time excludes pauses and seek jumps.
- Recent search history holds at most 20 deliberate commits. Debounced network searches while typing must not themselves add history entries. Home layout and recording-language corrections persist in the library.
- `TipJarService` accepts only its five consumable product IDs. Verify and durably record a transaction before finishing it; preserve deduplication and refund records. Tips grant no entitlement, features, or music. Purchase labels use StoreKit's `Product.displayPrice`.

## Provider and data contracts

- All playback is audio-only. Prefer album-audio recordings and song charts. The current extraction/caching integration is unofficial; successful playback is not distribution permission.
- Discovery preferences target Hindi and English; search is unrestricted. Provider region, artist nationality, station audience tags, and an artist's other songs do not prove a recording's language.
- `Track.credits` is the artist source of truth; `artists`/`artistID` are derived. Parse linked artist runs, album `straplineTextOne`, and feature clauses. `MusicAppModel.openArtist(_:)` resolves title-only credits by name.
- “This is [artist]” sorts recording IDs by available provider play counts, unknowns last. Do not sum alternate versions or invent missing counts. Keep `ArtistPage.monthlyAudience` with its provider value, unit, and raw wording; never turn listeners into monthly plays.
- Recording-language evidence may come from metadata, matched lyrics, or MusicBrainz work metadata. Label inference and weak title/script hints. Uncertain or conflicting results stay in All/Unclassified; a persisted user correction takes priority.
- `ArtistSpotlightMusicBrainz` requires a real HTTPS `MusicBrainzContactURL`; `project.yml` supplies the published Support Gist anchor recorded in `docs/app-store/PUBLIC_PAGES.md`. Keep its shared one-request-per-second limiter and bounded cache.
- LRCLIB is the primary lyrics source; `CompositeLyricsProvider` can use recording-linked YouTube Music plain lyrics as fallback. Preserve LyricFind/Musixmatch credits when supplied through YouTube Music. Never invent timestamps or contact those publishers as if a direct integration existed.
- Provider weekly charts retain reporting dates, region, and original ranks. Personal recap uses local rolling 7/30/365-day history; never synthesize global monthly/yearly charts.
- Personal mix ranking runs on device. Dislikes are excluded from generated mixes and autoplay; explicit user selections remain playable. Mixes are stable within their period key.
- Ordinary autoplay uses `catalog.radio(seed:)` without a Home language filter. `recommendations(seed:language:)` serves Home mixes. Experience radio is genre/mood-led, with cue, style-search, playlist, and radio fallbacks. Era and language preferences do not certify every queued track.
- Bounded startup radio retries and manual continuation use `radio(seed:forceRefresh:)`. Fresh requests bypass stale cached radio responses, not provider cooldowns; keep the existing request budgets.
- Apply body-size limits while receiving, including missing/chunked lengths, and cancel only the affected request. Artwork coalescing tracks each waiter and cancels/drains the transfer after the last waiter leaves. Provider response/deadline limits belong in `docs/PROVIDERS.md`.
- Release alerts use durable pending IDs. Recheck eligibility after asynchronous identifier lookup and initiate submission in the same main-actor turn. Retire pending alerts on disable/unfollow, and acknowledge platform acceptance without duplicate submission.
- `AudioCacheLimit` owns the five size choices and associated logical-song limits. Cache maintenance must cancel stale writers, retain in-use files, and report actual bytes. The cache is purgeable; do not promise offline downloads or lossless playback.
- Reuse `SourceAudioQuality` in `ProviderProtocols.swift`. Rank eligible AAC/Opus by valid average bitrate, then advertised bitrate when needed; prefer AAC on ties. Keep AAC fallback and the iOS 26.5+ gate for native Opus. More displays source metadata, not measured output fidelity or a guaranteed Premium tier.
- Opus WebM must be fully downloaded, packet-copied locally into MP4 through FFmpegBridge, and validated by native PCM output before publication. FFmpeg supplies no network, encoder, or decoder. Playback remains AVPlayer-owned; operation budgets and APIs are in `docs/ARCHITECTURE.md`.
- Cache encodings are immutable variants of one logical song. Preserve in-use originals, publish prepared variants only after validation, and let later plays reuse the best compatible copy. Usage includes all committed encodings and active preparation bytes; the song limit counts logical IDs. Failed/cancelled preparation must not publish a variant.
- Optional YouTube cookies are stored separately in the device-only, after-first-unlock Keychain and added only to TVHTML5 player requests. Catalog transport stays account-cookie-free. Avoid claims that provider requests are unidentifiable or that backups never leave the device.
- Persist sign-out intent before Keychain deletion. A successfully saved credential-free marker blocks session restoration after a failed deletion; failed intent persistence must remain a visible retry-before-closing error.
- Remote extraction stays opt-in. [PROVIDERS.md](docs/PROVIDERS.md) owns payloads and retention; keep it and [PRIVACY.md](PRIVACY.md) aligned with network behavior.
- YouTubeKit is vendored under `Vendor/YouTubeKit`; keep its patch minimal and preserve the MIT license verbatim. Provider credits do not grant rights to music, lyrics, or cover art.
- `Vendor/FFmpegBridge` owns the LGPL wrapper, pinned source, recipe, and provenance. Preserve its bundled notices and exact corresponding-source materials. A private repository or local source archive does not complete recipient source/relink delivery; `docs/FFMPEG_DISTRIBUTION.md` records that release dependency.
- FFmpeg patch policy checks every required patch forward or reverse and rejects conflicts, including source overrides. Verification checks current recipe/patch hashes. Preserve the verified package/provenance and its matching source bundle; local repackaging is complete, while recipient source/relink delivery remains open.

## Interface contracts

- Use availability-gated Liquid Glass. Full-screen Now Playing has fixed main controls and a scrollable More bottom sheet. Keep a single in-place loading indicator; avoid adding a volume row or bottom Done button to the main player.
- The mini-player has a real 64-point minimum, 44-point artwork, and 52-point controls; Dynamic Type may increase its height. Reserve its intrinsic height outside each NavigationStack viewport so pushed pages also clear it. Retain native Liquid Glass tab navigation, compact empty-playlist cards, and shared typography.
- Banner Retry and Dismiss actions have real 44-point hit regions. Keep the minimum in the button label/hit shape rather than relying on an outer layout frame.
- Home customization persists order and visibility, with Recently played first by default. Exclude only `editorial-hindi` and `editorial-english`, not the entire discovery category.
- A first Search-tab tap opens Search without forcing the keyboard; reselecting Search scrolls to the top and focuses the existing query. Presenting a sheet or navigating away retires pending focus requests.
- Explicit `search()` supersedes pending artist navigation; lifecycle/debounce uses `loadSearch()` without creating a newer intent. Use native navigation/presentation bindings so touch, keyboard, Back, and accessibility actions participate. A stale dismissal must not consume a newer Search focus request.
- Radio setup requires at least one language and permits zero to four optional artist hints, with none selected initially. Do not restore a minimum-artist requirement or promise availability through an outage. Keep bounded fallbacks, explicit errors/retry, and generation checks for newer playback intent.
- `AppIcons.all` has 14 unique visible choices; Leafnote (`Beat`, primary, nil alternate name) is the default. The 15 app-icon sets include the primary Leafnote plus its retained `AppIcon-Beat` compatibility alias. Breeze uses `AppIcon-Dhol`. Keep recipes, primary `AppIcon.png`, and compatibility mapping aligned. `AppAccent` owns the seven palettes.
- Settings descriptions sit under the relevant row. Use short, plain copy without em dashes.
- Retain Settings' backup qualification, optional sign-in's provider-acceptance/logging limits, remote response/header disclosure, and storage accounting for all cached versions plus preparation bytes.
- Opaque accent fills use the paired foreground with at least 4.5:1 contrast. Preserve actionable row semantics and queued VoiceOver confirmations; native assistive-technology acceptance is a separate check. Home track/album corners are 4 points, mix corners 6, and compact containers 10.

## Verification and release

- Use dedicated GanaBajana simulators and app-owned derived data. Only the coordinator runs builds/UI suites and updates `docs/VERIFICATION.md` and `docs/REVIEW_FINDINGS.md` during coordinated work.
- Active verification is iPhone 17 Pro only. Smaller-screen and physical-device testing are deferred by the owner. Do not report planned checks or another contributor's results as runs you performed.
- Headless scene-geometry requests exercise rotation layout in the same app process. They require the documented test-runner opt-in and DEBUG guards; they do not establish physical autorotation. Keep fixture controls out of Release and report suite exclusions explicitly.
- UI assertions use a `1e-6` floating-point epsilon at the 44-point geometry threshold, wait for observable artist readiness, and allow elapsed automation time in playback-resume checks. Record coverage across reruns without relabelling it as one green full run.
- `tools/verify.sh` keeps native StoreKit enabled by default. `SKIP_NATIVE_STOREKIT=1` explicitly excludes its unit/UI suites; fixture UI excludes live UI. Live provider mode includes `ExperienceRadioLiveTests` and `LyricsFallbackLiveTests`.
- `Resources/TipJar.storekit` remains in Debug Run configuration. Release uses `EXCLUDED_SOURCE_FILE_NAMES=TipJar.storekit`; preserve that configuration-specific exclusion. Native StoreKit, sandbox, and App Store Connect evidence are separate from fake-backed coverage.
- `python3 tools/audit-release.py <archive> --version <version> --build <build>` checks the archived app's identity, iPhone platform/architecture, orientations, signatures, FFmpeg exports/licenses, and absent test resources. A signed local archive or development IPA is not App Store/TestFlight delivery.
- [Release status](docs/app-store/RELEASE_STATUS.md) owns the initial-release hold. The owner has confirmed no YouTube/rights-holder authorization; preparation may continue, but submission must wait for a licensed provider/content decision and matching implementation.
- The GitHub source repository is private on `main`; use the initial-release anchor without assuming an empty commit history. Public `SUPPORT.md` and `PRIVACY.md` revisions are published and readback-verified at the Gist anchors in `docs/app-store/PUBLIC_PAGES.md`. Preserve their absolute cross-links.
- Do not modify sibling apps. Commit, remote publication, uploads, and App Store writes require authorization for the active task.
