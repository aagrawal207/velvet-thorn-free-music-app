# Verification

## Current candidate

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
