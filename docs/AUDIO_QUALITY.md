# Audio quality preference

R12 WP6. Settings > Playback > **Audio quality** keeps a persistent ceiling for source selection (Best available, Balanced, Data saver) and lets a signed-in account's higher tiers win under Best available.

## Purpose

- Let the listener trade bitrate for data and storage without touching cached music: Balanced caps at 160 kbps, Data saver at 64 kbps, Best available keeps today's highest-first ranking.
- Accept and prefer the 256 kbps AAC (itag 141) and Opus (itag 774) tiers when YouTube returns them to a signed-in TVHTML5 lookup. Nothing in the app requires a Premium account; the app only ranks what the provider actually returns.
- Give WP9 (JioSaavn) one shared selection helper so every source applies the same ceiling rules.

## Behaviour

- `UserPreferences.audioQuality` (`AudioQualityPreference`, default `.best`) syncs like other scalar preferences. `MusicAppModel` fans it to the player at start and on every change through `updatePreferences` / `applyPreferenceServices`; `PlayerController.setAudioQualityPreference` forwards it on the serialized settings task to whatever `PlaybackConfigurableResolving` resolver it holds. In production that is WP9's `CompositeStreamResolver`, which passes the preference to both `YouTubeStreamResolver` and `JioSaavnStreamResolver`.
- A change applies to the next resolution. The current song keeps its stream; a song the standby deck already prepared keeps its selection too. Settings says "Applies to the next song."
- Complete cached copies (audio cache, downloads) always play whatever their bitrate. The bytes are already on this device, so the ceiling never forces a network fetch or a lower copy.
- The in-memory signed-URL cache records the ceiling each entry was chosen under. A preference change drops entries that exceed the new ceiling and entries chosen under a tighter ceiling (a better format may have been hidden). Entries chosen under Best that fit the new ceiling stay. Speculative warmups and the speculative prefetch download are cancelled on a change; a foreground resolution that outlives the change still plays but is not reused.
- **More > Audio quality** shows "<preference title> · <source summary>", for example "Balanced · 128 kbps AAC · 44.1 kHz · Stereo". **Reload best available audio** describes the ceiling when one is active ("Checks the source for this play, up to 160 kbps. Keeps cached audio for fallback.").
- `refreshQuality` (Reload best available audio) resolves fresh under the ceiling and keeps its rule of never replacing a saved copy with a lower bitrate; a saved 128 kbps copy under Data saver stays, a saved 48 kbps copy under Balanced is replaced by the best format under 160 kbps.
- Settings > Playback > Sound owns `settings.audioQuality`, choices `settings.audioQuality.choice.<best|balanced|dataSaver>`, and its next-song description. There is no Right Time Label setting; the player's trailing-time tap owns that choice.

## Selection rules

`SourceAudioQuality.ranked(_:maximumBitRate:quality:)` orders candidates for playback:

1. Without a ceiling (`.best`): existing `SourceAudioQuality.prefers` order. Higher valid average bitrate wins, advertised bitrate fills a missing average, AAC beats Opus on ties, unknown bitrates last.
2. With a ceiling: formats whose bitrate fits come first in `prefers` order, so the pick is the highest format under the ceiling.
3. If nothing fits, the lowest offered format plays first; the remaining higher formats follow in ascending order (AAC before Opus on ties). The same tail applies when every fitting URL fails validation, so a broken low tier does not fail the song.
4. Unknown bitrates cannot prove they fit and stay last.

Where it applies:

- `YouTubeStreamResolver.validated` ranks every candidate list (fast path streams plus AAC fallbacks, full YouTubeKit extraction, AAC fallbacks after a failed extraction) with the ceiling captured when the flight started. The existing three-per-codec limit and Opus gate (iOS 26.5+, local preparation, AAC fallback) are unchanged.
- `YouTubeAudioFastPath.audioResult(in:videoID:allowOpus:maximumBitRate:)` computes the "best" tier from the ranked list, so the direct VISIONOS lookup returns up to three URLs of the best fitting format and up to three of the best fitting AAC format. A challenged fitting format still sends the song to full extraction instead of an over-ceiling clear URL.
- `YouTubeExtractionWorker` (full extraction) accepts every AAC and Opus format YouTubeKit returns, including 256 kbps tiers; `SourceAudioQuality.validBitRate` already accepts 8 kbps to 1,536 kbps.
- Injected test fast paths are prebuilt without a ceiling; the resolver applies it during validation.

Higher tiers when signed in:

- The optional YouTube sign-in adds cookies and `SAPISIDHASH` only to TVHTML5 `/youtubei/v1/player` (unchanged, `YouTubeKitAuthBridge`). yt-dlp uses the same `tv` and `web` clients for authenticated extraction, and its users report itag 141 (AAC 256 kbps) and itag 774 (Opus about 256 kbps, `audioQuality: AUDIO_QUALITY_HIGH`) on Premium accounts.
- The vendored YouTubeKit dropped itag 774 because `Stream(format:)` rejects unknown itags; `Vendor/YouTubeKit/Sources/YouTubeKit/Models/ITag.swift` now lists `774: (nil, 256)`. Itag 141 was already listed. No new client was added and the cookie scope rule is not weakened.
- Under `.best` any 256 kbps format returned is ranked first (AAC ahead of Opus on ties, Opus 256 ahead of Opus 160 and AAC 128). Under Balanced or Data saver these tiers sit above the ceiling and are only used when nothing fits.

## APIs

| API | Owner | Notes |
| --- | --- | --- |
| `SourceAudioQuality.ranked(_:maximumBitRate:quality:)` | `Sources/Core/ProviderProtocols.swift` | Generic ordering helper for any candidate type; WP9 can call `ranked(streams, maximumBitRate: preference.maximumBitRate) { $0.quality }` |
| `SourceAudioQuality.fits(_:maximumBitRate:)` | same | Ceiling check; absent ceiling or unknown bitrate never blocks |
| `YouTubeStreamResolver.setAudioQualityPreference(_:)`, `audioQualityPreference` | `Sources/Playback/YouTubeStreamResolver.swift` | Actor method; retires URL entries, cancels speculative work |
| `YouTubeStreamResolver.CappedFastExtraction` | same | Production fast path receives the ceiling; the test `FastExtraction` shape is unchanged |
| `YouTubeAudioFastPath.extract(videoID:maximumBitRate:)`, `audioResult(in:videoID:allowOpus:maximumBitRate:)` | `Sources/Playback/YouTubeAudioFastPath.swift` | `maximumBitRate` defaults to nil |
| `PlayerController.setAudioQualityPreference(_:)` | `Sources/Playback/PlayerController.swift` | No re-resolution of the current song; reaches the resolver through WP9's `PlaybackConfigurableResolving` |
| `AudioQualityPreference` (`title`, `detail`, `maximumBitRate`) | `Sources/Core/PlayerPreferences.swift` (WP0) | Unchanged; `JioSaavnStreamResolver` (WP9) reads `maximumBitRate` for its own tier table |

## R18 playback provider provenance

`ResolvedStream.playbackSource: MusicSource?` records which provider supplied the media. It defaults to nil. `Track.source` still derives from the catalog ID: a Gaana recording playing JioSaavn audio remains `gaana:<id>` in the library, queue and cache. Acquisition provenance contains no alternate recording ID and never enters library sync.

The successful native Gaana and JioSaavn branches stamp `.gaana` and `.jioSaavn`. YouTube stamps `.youTubeMusic` on network candidates before validation, including fast extraction, full/remote extraction, AAC fallback, Opus upgrades and background plans. Cache hits keep their stored value. `GaanaStreamResolver` preserves the fallback stream's known value; when a remote fallback has no value, it records the answering `CrossSourceStreamFallback.source`. An unknown file-backed fallback stays unknown. The concrete adapters are `JioSaavnStreamFallback` and `YouTubeStreamFallback` in `Sources/Catalog/Gaana/CrossSourceStreamFallback.swift`.

`AudioCache.Sidecar.playbackSource` is optional and decodes absent, null, unrecognised or wrong-typed values as unknown without rejecting playable audio. `CachedAudio.stream`, missing-duration inspection copies, foreground AAC publication and Opus preparation carry the value. Promotion, demotion and downloaded-encoding replacement retain the selected file's metadata. Keeping an existing copy never copies provenance or diagnostics from the rejected replacement.

`BackgroundDownloadPlan.metadata` carries the same field into the URL-free v2 queue. Relaunch restores it through `BackgroundPendingDownload.metadata`; `BackgroundDownloadEngine` supplies that plan metadata to `publishBackgroundDownload`. The transport staging receipt records byte count and container only. It does not identify the media provider, and must not replace the restored plan metadata during publication. No signed URL host is used to infer a provider.

### Integrated display

`SourceAudioQuality.playbackSummary(quality:catalogSource:playbackSource:)` keeps the encoding summary and appends the known native provider, `via <provider>` for a different provider, or `Playback source unknown`. Examples for Gaana catalog tracks:

- `128 kbps AAC · Gaana`
- `320 kbps AAC · via JioSaavn`
- `128 kbps AAC · via YouTube Music`
- `128 kbps AAC · Playback source unknown` for an older unlabelled cached copy.

The preference prefix remains separate. Bitrate and codec describe source metadata; neither provenance nor the selected ceiling guarantees output fidelity, losslessness or a Premium tier.

`PlayerController.playbackSource` is assigned from the accepted stream during active installation and standby activation. Selection, pipeline invalidation and live-radio entry clear it alongside source quality. `StandbyDeck.Prepared.stream`, adoption and missing-duration loading retain the complete stream. Nil remains unknown; it never falls back to catalog identity.

`PlayerOptionsSheet` keeps `qualityPreference.settingsTitle` and uses `SourceAudioQuality.playbackSummary` with the player's quality, current catalog source and actual `playbackSource`. The R18 model and UI hooks are applied.

### Metrics

| Event | Emitted when | Bounded values | Purpose |
| --- | --- | --- | --- |
| `audio_cache_lookup source=<catalog> playback_source=<actual> hit=<0,1>` | Composite prefixed-track cache lookup | catalog=saavn,gaana; actual=youtube,saavn,gaana,unknown | Distinguishes the cached media provider from the catalog route; misses and unlabelled copies use unknown |
| Existing Gaana `fallback source=<provider> status=<status>` | A fallback adapter answers, misses or fails | provider from `MusicSource`; status=ok,miss,failed | Records the attempted fallback branch; a cache hit's actual provenance remains in the stream |

No new network calls or dimensions containing IDs or URLs. OSLog emission has no assertion seam in this suite and remains unasserted.

### Test coverage

`Tests/PlaybackProviderProvenanceTests.swift` covers the following paths. The coordinator reports passing Core-02/Regression-01 and phone UI-01 scopes; [VERIFICATION.md](VERIFICATION.md) owns counts and receipts.

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Native Gaana HLS and URL reuse; Saavn direct and URL reuse; YouTube fast/full/remote resolution and background planning | Resolver acquisition branches | Unit, mocked providers |
| Gaana uses JioSaavn first; a miss/error advances to YouTube; a misleading URL host cannot set provenance | Fallback selection and reuse | Unit |
| Production fallback adapters preserve known and unknown local provenance | Cross-source matching and cache answer | Unit with disk fixtures |
| Native, fallback and unknown summary text retains codec/bitrate wording | `playbackSummary` | Unit |
| Missing/null/future/wrong-typed sidecar values remain playable with other metadata intact | Sidecar decoder | Unit |
| Gaana fallback file keeps its ID and provider through relaunch, promotion, in-use deletion/demotion and offline resolve/refresh/download | Composite and two-tier cache | Unit with disk fixtures |
| Missing-duration copies preserve known/unknown source; mismatched Track metadata cannot supply counts or provider identity | Cache readers | Unit with disk fixtures |
| URL-free background queue survives relaunch; restored engine uses plan provenance rather than the transport receipt; published file retains it after demotion | Queue, staging, engine and native WAV validation | Local integration, OS session replaced |
| YouTube Opus-only resolution and deferred AAC-to-Opus upgrade, downloaded-encoding adoption and background Opus publication retain each encoding's provider | Resolver and cache copy/publication paths | Unit, remux/native inspection replaced |
| A quality refresh or duplicate background delivery that keeps a saved copy cannot leak incoming provider/count/loudness | Saved-copy preference and promotion | Unit with native WAV validation |

`R18IntegrationTests` covers active/standby provenance and normalization, plus fallback-cache reopen with nil extraction evidence. The phone R18 UI workflow checks the rendered fallback source after cached relaunch in light/dark. Live provider availability and physical background suspension are not established by these fixtures.

## Network changes

Quality selection and source provenance add no hosts, headers or account requests. Playback's account bridge decorates only TVHTML5 player lookups; separate opt-in import and explicit account changes are described in [ACCOUNT_IMPORT.md](ACCOUNT_IMPORT.md) and [ACCOUNT_WRITEBACK.md](ACCOUNT_WRITEBACK.md). A ceiling changes URL selection, but fallback above the ceiling and complete local copies prevent a guaranteed data-usage reduction.

## Metrics

OSLog subsystem `com.agraabhi.ganabajana`, category `StreamResolver`.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=audio_quality_preference preference=<p> dropped=<n>` | The resolver receives a different preference | preference=best,balanced,dataSaver; dropped=count of retired URL entries (0 to 24) | Confirms fan-out and shows how many signed URLs a change invalidates |
| `event=audio_quality_selected preference=<p> codec=<c> bitRate=<n> capped=<0,1> fits=<0,1>` | `validated` picks a stream (AAC validated or Opus prepared) | preference as above; codec=aac,opus; bitRate in bps; capped=1 when the ceiling passed over a higher offered format; fits=1 when the pick is within the ceiling (always 1 without one) | Separates "the ceiling changed the outcome" from "nothing fit, played the lowest" |
| `event=audio_quality_refresh outcome=<o> preference=<p> [bitrate=<n>]` | Reload best available audio finishes | outcome=cached_not_lower,fresh,cached_after_failure | Shows whether a reload replaced the saved copy under the active ceiling |
| `event=direct_audio_resolved bitrate=<n>`, `event=resolved remote=<0,1> bitrate=<n>` | Existing | unchanged | Bitrate of the final pick per path |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Ranked order: fitting first, closest higher next, unknown last, AAC before Opus on ties, Best unchanged | `SourceAudioQuality.ranked` | Unit (`AudioQualityPreferenceTests.testRankedKeeps...`) |
| `fits` with absent ceiling and unknown bitrate | `SourceAudioQuality.fits` | Unit |
| 256 kbps AAC and Opus valid, preferred under Best, AAC first on tie, Opus 256 wins without equal AAC | `validBitRate`, `prefers`, fast path | Unit (`test256Kilobit...`) |
| Fast path best tier under Balanced (Opus and AAC-only) and Data saver, AAC fallback follows the ceiling | `YouTubeAudioFastPath.audioResult` | Unit |
| Fast path with nothing under the ceiling takes the lowest offered; AAC fallback is the lowest AAC | same | Unit |
| Fast path keeps a challenged fitting format for full extraction instead of an over-ceiling clear URL | same | Unit |
| Resolver picks highest under ceiling for each preference; Best unchanged; only the pick is validated | `validated` | Unit |
| Resolver with nothing under the ceiling plays the lowest and climbs when it fails validation | `validated` fallback tail | Unit |
| Resolver applies the ceiling to a prebuilt fast-path result and keeps fast-path metadata | `performExtraction` + `validated` | Unit |
| Complete cached 320 kbps copy plays under Data saver for resolve, forced resolve and download, no network | `cachedAudio` | Unit with disk cache fixture |
| Reload honours the ceiling: 128 kbps saved copy stays under Data saver (48 kbps validated only); Best reloads to 256 | `refreshQuality` | Unit with disk cache fixture |
| Reload replaces a 48 kbps saved copy with the best format under Balanced without rewriting the file | `refreshQuality` | Unit with disk cache fixture |
| Preference change retires URL entries above the new ceiling or chosen under a tighter one; same preference keeps the cache | `setAudioQualityPreference`, `entryFits`, `finish` | Unit |
| Preference change keeps a Best entry that fits the new ceiling | same | Unit |
| `updatePreferences` and `reloadSavedLibrary` reach the resolver | `MusicAppModel.applyPreferenceServices` → `PlayerController` → resolver | Unit (model harness) |
| Startup applies the saved preference before the first resolution | `MusicAppModel.init` | Unit |
| Settings shows Audio quality with Best available, Data saver persists across relaunch, description follows the choice, More row shows the Data saver prefix and the reload text | SettingsView, PlayerOptionsSheet | UI (`GanaBajanaAudioQualityUITests`) |
| Settings inventory keeps the Audio quality row as a native 44-point menu | Settings identifier inventory | UI (`GanaBajanaListeningControlsUITests.testIconLabeledSettingsKeepSixSections...`) |
| Existing resolver, fast path, Opus, cache and offline suites stay green | regression | Unit |

## Not verified

- Availability of itag 141 / 774 for a signed-in Premium account was not exercised: no account is available to this worker, and the fast path (cookie-free VISIONOS) never sees Premium tiers. The vendored ITag table change is verified by source inspection and the app build only; selection logic for 256 kbps formats is covered by fixtures.
- Whether YouTube's TVHTML5 client returns the 256 kbps tiers for every Premium account or only for YouTube Music Premium; yt-dlp reports vary by client and account.
- A song already prepared by the standby deck before a preference change keeps its earlier selection; the ceiling takes effect from the following resolution.
- Cancellation of speculative warmups on a preference change is implemented but not covered by a deterministic test.
- Physical-device data usage under Data saver was not measured.
