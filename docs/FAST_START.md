# Fast start

R13 item 11 (WP20): songs often load slowly. This file owns the start-latency measurement, the progressive-first start policy, the playback warmer and the quick-skip preloader.

## Quick skips and browsing (October 2026)

A listener who skips twice in a row used to wait for a full network start on the second skip: only the next queue song was prepared, and selecting a song retired other background work. The follow-up prepares several likely songs ahead and keeps each preparation until it is evicted, replaced by a newer signed URL or close to expiry.

- **Preloaded assets, not byte prefixes.** `PlaybackPreloader` resolves a signed URL through the speculative path (`PlaybackPreloadResolving.preloadStream(for:)`) and loads the native `AVURLAsset`'s playability, duration and tracks. `PlaybackPreloadStore` (main actor, 8 entries, least recently used) keeps the loaded asset. `PlaybackStreamLoading.makeItem(stream:trackID:duration:preloads:)` builds the item from that asset when the track ID and exact signed URL match; the active player and the gapless deck both use it. Nothing is written to disk or counted as cache or offline availability.
- **Queue window.** `PlayerController.upcomingTracks(limit:)` lists the next five unique songs in play order, so shuffle and Repeat All are followed and Next still moves on under Repeat One. Preparation runs two at a time, nearest first. Queue preparation needs playing intent, so a paused or restored queue starts none. While the selected song is starting, both lanes wait, so a skip never competes with the song just chosen. `update(queue:queueAllowed:holding:)` applies all three together before planning. A shifted window keeps earlier preparations and requests only the new songs. Quality-ceiling and extractor-rule changes clear prepared assets, and a lookup that finds a different signed URL drops the stale one.
- **Browsing surfaces.** `PlaybackWarmer` hands Search (top 3 songs), album and playlist pages (first 3), artist pages (first 3 listed songs) and Home when nothing is playing (first 2) to the preloader's browse lane, after the queue. Gaana keeps a URL-only warm because its HLS fallbacks are too costly to resolve speculatively; without a preloader the warmer keeps its earlier URL-plus-download behaviour.
- **Manual Next uses the gapless deck.** When the prerolled standby holds the next entry, Next swaps to it as a gapless track end does (`event=manual_next path=standby`), instead of building and buffering a new item. With crossfade on, Next keeps its existing blend of at most 3 s.
- **Complete downloads wait for listening.** `PlaybackCachePipeline` downloads the current song first and adds the next song only after the playback position settles: `PlayerController.nextDownloadSettleSeconds` (30 s) or half of a shorter song. Seeking past that point counts. A next target set during the current transfer joins the running task; a different target replaces an obsolete next transfer, and a current copy that already landed is not requested again. Quick skips therefore cost a preparation, not a full file. Neither the queue nor a warm starts a speculative complete download for AAC songs. An Opus-only offer still prepares its local file during resolution, as warms already did; such offers are uncommon.
- **Gates.** Offline and Low Data Mode prepare nothing and cancel running preparation. On an expensive path the queue window still runs; browsing surfaces need **Download over cellular**. Connectivity changes and that preference call `refreshNetwork()`, which re-plans when the gate changed. The warmer's 12-per-minute budget now counts only its own URL warms.

### Rejected first approach: saved byte prefixes

The first build downloaded about 20 seconds of each upcoming file and served those bytes through an `AVAssetResourceLoaderDelegate`, continuing from the signed URL. Live checks showed it was slower for YouTube's fragmented M4A files. AVFoundation read the whole fragment index before the first audio: about 25 to 47 range requests and 1.4 to 1.6 MB per asset. A prefixed start took 3.0 to 3.8 s against 0.5 to 1.7 s for the plain URL (`Prefix-Live-01/02/04`). With an unreachable continuation host no audio started within 10 s (`Prefix-Live-03`). Neither the content type nor `isEntireLengthAvailableOnDemand` helped. A native asset whose metadata had loaded first started in about 0.3 s (`Prefix-Live-05`), which led to the preloaded-asset design. The spike's sources are kept in `artifacts/R21/prefix-spike/` as evidence and are not compiled.

### Search

- **Progressive fan-out.** `CompositeCatalog.progressiveSearch(query:filter:)` yields YouTube Music's page as soon as it arrives, then each enabled extra source on its existing 6 s deadline; secondaries finishing first are delivered right after the primary in source order. A primary failure still shows extra sources behind an empty primary. `MusicAppModel.loadSearch` publishes and warms the first update, clears `isSearching`, then appends secondaries without duplicates; Search's source sections keep their order.
- **No wait for an unused artist page.** A song search runs the artist search beside the songs page. The artist page now starts once the artist matches, and a search whose songs do not feature that artist cancels it instead of waiting. A featured artist waits only until the original 2 s budget; a page that already arrived is used even if the songs request ran past it, and a page still loading at the deadline drops the feature as before. The featured songs come from `YouTubeMusicService.artistTopSongs(id:)`, the first artist page plus duration enrichment, instead of the full multi-page artist browse.

### Bounds

| Bound | Value |
| --- | --- |
| Queue window | Next 5 unique audio songs in play order |
| Browse lane | 3 songs after the queue (Home 2) |
| Concurrent preparations | 2 |
| Prepared assets in memory | 8, least recently used; dropped on a memory warning |
| Asset metadata load | 10 s |
| Usable signed URL | More than 90 s from expiry |
| Retry after failure / busy resolver / song with no remote progressive stream (local copy, HLS, Opus-only) | 60 s / 1.6 s / 10 min |
| Complete next-song download | After 30 s of the current song, or half of a shorter one |

### Metrics

| Event (category) | When | Dimensions |
| --- | --- | --- |
| `event=playback_start ... preload=<0,1>` (Playback) | Existing start event | Whether the item reused a preloaded asset |
| `event=playback_preload outcome=<prepared,skipped,expired,busy,failed,cancelled> lane=<queue,browse> ms=<n> resolve_ms=<n>` (Playback) | A preparation finished | Bounded outcome and lane |
| `event=playback_preload_skipped reason=<offline,low_data>` (Playback, debug) | Running preparation stopped | |
| `event=manual_next path=standby` (Playback, debug) | Next used the prerolled deck | |
| `event=next_download_settled` (Playback, debug) | The next song's complete download was released | |
| `event=warm_routed surface=<s> preloads=<n> urls=<n>` (Playback, debug) | A warm event was split | Counts bounded by the surface limit |
| `event=search_loaded first_results_ms=<n> complete_ms=<n> progressive=1` (Discovery) | Progressive search finished | |
| `event=progressive_search sources=<n> primary_failed=<0,1>` (Catalog, debug) | Stream finished | |

No event carries a recording ID, query or URL.

### Measured

Live, iPhone 17 Pro simulator on the Mac's network; timing lines only, never assertions.

| Check | Result |
| --- | --- |
| `Preload-Live-02`: queue of 5 public recordings | Prepared 5/5 in 5.1 s (each about 1.2 s resolution plus 0.3 to 0.6 s metadata) |
| First audio, preloaded asset vs warm URL alone | 321 to 492 ms vs 387 to 1,298 ms. The warm URL ran after preloading had opened connections to the same hosts, which favours it; the earlier cold item measured 0.5 to 1.96 s (`Prefix-Live-05`) |
| `Search-Live-01` (before) and `Search-Live-03` (after) | Non-featured queries no longer wait for the artist page. A featured query ("Arijit Singh") fetches 0.9 s of top songs instead of a 1.5 s full artist browse. Results vary run to run; JioSaavn answered in about 0.5 to 0.8 s and Gaana in about 0.9 to 1.2 s |
| `Search-Live-02`, progressive composite | First results 0.72 to 0.82 s for four queries and 2.0 s for the featured query, with later sources following |

### Coverage

| Case | Kind | Where |
| --- | --- | --- |
| Next 5 eligible songs, nearest first, two at a time; holding; window shift; queue before browse; overlap; network gates; owner cancel; skip, cooldown and busy retry; near-expiry rejection | Unit | `PlaybackPreloaderTests` |
| Store exact-URL match, eviction, expiry, memory warning; `makeItem` reuse only for the exact remote URL | Unit | `PlaybackPreloaderTests` |
| Warmer routes progressive songs to the preloader and URL-warms only Gaana | Unit | `PlaybackPreloaderTests` |
| Preloading waits for first audio then follows play order; shuffle, Repeat All, Repeat One | Integration (native audio) | `PlaybackPreloadIntegrationTests` |
| Manual Next takes the ready gapless deck without another resolution | Integration (native audio) | `PlaybackPreloadIntegrationTests` |
| Next download only after settling; a quick skip never downloads the old next song | Integration (native audio) | `PlaybackPreloadIntegrationTests` |
| Current-first download order and no repeated current download | Integration | `PlaybackCacheTests`, `PlaybackCacheManagementTests`, `OfflinePlaybackTests` (updated expectations) |
| Progressive search ordering, failures, deadline, cancellation; model publish/append and stale generations; skipped and first-page-only artist page | Unit | `ProgressiveSearchTests` |
| Live preloaded start and search stage timings | Live | `PlaybackPreloadLiveTests`, `SearchLatencyLiveTests` |

### Not verified

- Physical-device tap-to-audio for rapid skips, cellular and poor networks, and background playback.
- Whether prepared assets keep their connections across long pauses on device; an idle connection may reopen.
- JioSaavn preloading was not timed live; Gaana is not preloaded.

## Purpose

A tap on a song that has no complete local copy used to wait for the whole Opus WebM to download, be packet-copied into MP4 and pass native validation before AVPlayer saw anything. The work package measures time to first audio per path, starts on the progressive AAC stream while Opus is prepared in the background for later plays, and resolves the songs a listener is most likely to tap before the tap.

## Behaviour

- **Measurement.** `PlayerController` keeps the original monotonic startup timestamp across automatic retries and logs `event=playback_start` in category `Playback` at the first playing sample (`timeControlStatus == .playing`, `rate > 0`, observed through KVO and the 500 ms tick). A new selection or explicit Retry starts a new measurement; pause, interruption and terminal failure drop it. The path is captured from `PlaybackStartTrace` when resolution returns, before local-duration loading and item installation, so later cache/download trace writes cannot relabel that start.
- **Progressive first.** In `YouTubeStreamResolver.validated`, when the ranked best candidate is Opus, Opus is enabled and at least one AAC candidate exists, a resolution that is not complete-only (the listener's tap, standby, queue prefetch, a warm) validates the best AAC under the same `SourceAudioQuality.ranked` ceiling and returns it at once; the Opus becomes the signed-URL entry's `upgrade`. Opus candidates stay behind every AAC, so when every AAC URL fails the song still plays through a foreground Opus preparation.
- **Opus for later plays.** `PlaybackCachePipeline` downloads the playing song as before; `download(_:)` joins or reuses the resolution, finds the `upgrade` and runs `storeOpus` (full download, FFmpegBridge packet copy, native PCM validation, then publication) within `upgradeTimeout` (35 s). A failed or deferred upgrade stores the AAC instead and records the usual 60 s Opus cooldown. The next play of the song picks the complete Opus copy (`path=local`).
- **No mid-play switch.** Nothing replaces the current item when its Opus copy appears; the flag `isCurrentTrackCached` only updates captions. The existing known-offline handoff to a complete local copy still applies, and after an expiry-driven re-resolution (resume past the signed-URL lifetime) the local Opus copy is used.
- **Unchanged.** A complete local copy (either tier) always wins. With no AAC candidate the Opus is prepared before play as before. Complete-only flights (downloads, `refreshQuality`, "Reload best available audio") still wait for the prepared Opus.
- **Hedged extraction.** Foreground flights start YouTubeKit alongside the fast path once the fast path has been silent for `productionHedgeDelay` (2 s, above the slowest fast path in the baseline); the first validated stream wins and the loser is cancelled. A fast-path failure starts extraction at once. Background flights retain the elapsed hedge state without entering YouTubeKit: a later foreground join signals extraction immediately; an earlier join keeps the original timer. Events and cleanup are flight-token-fenced, with one coalesced eligibility event and a three-element result/event buffer per flight. Completion or cancellation closes the feed. Injected test resolvers keep the hedge off unless explicitly enabled.
- **Warming.** `PlaybackWarmer` (main actor, owned by `MusicAppModel`) runs one job at a time.
  - Search: `MusicAppModel.loadSearch` (the Search screen's debounced load, not every keystroke) warms the top 3 audio song results of the first published page.
  - Albums, playlists and artist pages: `CollectionDetailView` warms the first 3 songs when they arrive.
  - With the preloader (production), progressive songs go to its browse lane and only Gaana songs are URL-warmed, without a download. Without it, each job resolves signed URLs and starts one speculative complete download of the first song through the resolver's prefetch slot; prefixed songs warm URLs only (`CompositeStreamResolver.warm`).
  - Cancellation: a newer query or warm event replaces the job; leaving Search or the collection page cancels that page's job (`cancel(owner:)`), including its speculative download (`cancelWarm(token:)`, fenced by the job's token so a late cancel never stops a newer job's download). A listener's tap retires every background flight and a different song's prefetch download, as before.
  - Gating: skipped when known offline, on Low Data Mode (`ConnectivityMonitor.isConstrained`), and on an expensive path unless `downloadsOverCellular` is on. YouTube warms are skipped while a recent bot check without an account would fail them (the sign-in cooldown). Under `--uitesting` warming is off unless `--fast-start-fixture` is passed, and unit hosts never warm through a model's default warmer.
  - Reuse: a tap on a warmed song hits the signed-URL cache (or the speculative copy) and reports `path=warmed` once; later plays report `urlCache` or `local`.
- **Queue preparation.** The preloader's queue window replaces the player's own next-song prefetch. `resolver.prefetch` keeps its limit of 2 and speculative download for callers without a preloader.

Code audit identified a missed-hedge timeline: warm starts at 0 s, the 2 s timer finds no foreground waiter, and a tap joins at 2.1 s. Without a promotion signal, extraction waited for the fast path's 6 s deadline, adding a possible 3.9 s after the tap before extraction even began. The elapsed-state signal closes that gap. This is a code-audit finding, not verification of the reported physical-device incident; current device logs are unavailable and this patch makes no new timing claim.

## Bounds

| Bound | Value |
| --- | --- |
| Songs resolved per search warm | 3 |
| Songs resolved per album or playlist warm | 2 |
| Speculative downloads per warm event | 1 (the first song; shares the resolver's single prefetch slot) |
| Warm resolutions per sliding minute | 12 across all events; skipped songs (live URL or local copy) are refunded |
| Background resolution flights | 2 at once (existing resolver cap); a warm beyond it stops early |
| Opus upgrade budget | `min(timeout, 3 * opusTimeout)` = 35 s, off the listener's path |
| Hedge delay | 2 s (production only) |
| Startup attempts | Existing maximum two automatic recovery retries (three attempts); diagnostic attempt count saturates at 255 for repeated configuration-driven restarts, with constant-space cumulative timings |
| `PlaybackStartTrace` | 32 paths and 32 warm marks in memory, never persisted or logged with ids |

## APIs

| API | Notes |
| --- | --- |
| `protocol StreamWarming: StreamResolving` | `warm(_:download:token:) async -> StreamWarmOutcome`, `cancelWarm(token:)` (default no-op) |
| `StreamWarmOutcome` | `resolved`, `skipped`, `failed`, `downloadScheduled` |
| `PlaybackStartTrace` | `record(_:for:)`, `path(for:)`, `markWarmed(_:)`, `startPath(for:)` (consumes the warm mark); paths `local`, `urlCache`, `fastPath`, `extraction`, `remote`, `saavn`, `gaana`, `warmed` |
| `PlaybackWarmer` | `init(resolver:network:enabled:now:)`, `warm(_:surface:owner:)`, `cancel(owner:)`, `Surface.search/.collection`, `resolutionsPerMinute`, `searchOwner`, `isEnabledByDefault` |
| `PlaybackWarmer.Network` | `isOffline`, `isExpensive`, `isConstrained`, `allowsExpensive` closures |
| `MusicAppModel` | `playbackWarmer`, `warmPlayback(_:surface:owner:)`, `cancelWarmPlayback(owner:)` |
| `YouTubeStreamResolver` | conforms to `StreamWarming`; `Selection`/`URLEntry.upgrade`; `productionHedgeDelay`; `init(... hedgeDelay:hedgeSleep:)` for gated tests |
| `JioSaavnStreamResolver`, `GaanaStreamResolver` | `warm(_:) -> StreamWarmOutcome`, `hasLiveStream(for:)` |
| `ConnectivityMonitor.isConstrained` | Low Data Mode alone; `isExpensive` still includes it |
| `PlayerController.lastPlaybackStart` | "path=<p> ms=<n>" of the latest start, read by the fixture UI |
| `DebugFastStartAudioResolver` | DEBUG, `--fast-start-fixture`: cold resolutions sleep 2 s, warmed ones are immediate; rejected in Release by `tools/audit-release.py` |

## Metrics

| Event (category) | When | Dimensions |
| --- | --- | --- |
| `event=playback_start path=<p> codec=<aac,opus> ms=<n> attempts=<n> setup_ms=<n> resolution_ms=<n> ready_buffer_ms=<n> cached=<0,1> firstPlay=<0,1>` (Playback) | First playing sample after a selection or re-resolution | path as above or `unknown`; `firstPlay=1` once per process |
| `event=playback_start_attempt outcome=<retry,failed> path=<p> ms=<n> attempts=<n> setup_ms=<n> resolution_ms=<n> ready_buffer_ms=<n>` (Playback) | Automatic recovery or terminal failure while startup is pending | Same cumulative accounting; no event after the start measurement has ended |
| `event=warm_up surface=<search,collection> resolved=<n> downloaded=<0,1> skipped=<n> failed=<n>` (Playback) | A warm job finished and is still current | counts bounded by the surface limit |
| `event=warm_skipped surface=<s> reason=<offline,low_data,expensive,budget>` (Playback, debug) | A warm event did nothing | |
| `event=fast_start codec=aac upgrade=opus` (StreamResolver) | Progressive first chose AAC over a better Opus | |
| `event=opus_upgrade outcome=<prepared,deferred,failed> [bytes ms reason] fallback=aac` (StreamResolver) | A complete download prepared, deferred or failed the upgrade | reason from `OpusPreparationError.diagnosticReason` |
| `event=extraction_hedge started=1` / `outcome=extraction_won` (StreamResolver) | The hedge started YouTubeKit / YouTubeKit answered first | |

No metric carries a recording id, query or URL.

`ms` is the total since the original startup request, including failed automatic attempts. Stage times accumulate across those attempts: `setup_ms` includes synchronous setup, pending configuration/network configuration, file retention and any rejected-file discard; `resolution_ms` includes resolver work and missing local duration; `ready_buffer_ms` runs from resolution completion through item installation, readiness, resume seek and buffering to the first playing sample (or retry/failure). A 25 s readiness timeout stays in the total when a retry succeeds. `path` labels the successful attempt, not every earlier attempt. Stage milliseconds are independently truncated. Unit tests assert the accounting and captured label; OSLog emission and real-provider/device startup remain integration checks.

## Measured time to first audio

Live runs on the Mac's network (`GanaBajanaLive`, `PlaybackStartLiveTests`), iPhone 17 Pro simulator, iOS 26.5. "Resolve" is the production-shaped resolver from an empty cache to a validated stream; "ready" is AVPlayer `readyToPlay` for that URL. Before: `WP20-LiveBefore-01/02` (10 samples, 5 recordings twice). After: `WP20-LiveAfter-10/11`.

| Path | Before | After |
| --- | --- | --- |
| YouTube, Opus best, no local copy (5 recordings x 2) | resolve 1703 to 2334 ms (mean 1901), Opus file ready 21 to 458 ms (mean 71); resolve + ready mean 1972, median 1880 | AAC 129 kbps: resolve 940 to 1915 ms (mean 1309), remote ready 611 to 1648 ms (mean 846); resolve + ready mean 2155, median 2086 |
| Opus download + remux + validate (stage alone) | 728 to 1092 ms, one 403 | 820 to 1213 ms, now off the listener's path |
| YouTube fast path (stage alone) | 920 to 1568 ms | 882 to 1491 ms |
| YouTubeKit local extraction (stage alone) | 1851 to 2687 ms | 1822 to 2800 ms |
| YouTube AAC best (Data saver, no Opus upgrade) | not recorded separately (policy unchanged) | resolve 1427 to 1682 ms, ready 1458 to 2022 ms |
| Warmed YouTube tap (URL cache) | n/a | resolve 0 ms, ready 656 to 678 ms |
| Complete local copy | ready 21 to 63 ms (Opus file) | unchanged |
| JioSaavn | cold: resolve 522 to 619 ms, ready 380 to 442 ms | warmed: resolve 0 ms, ready 464 to 466 ms |
| Gaana HLS | cold: resolve 1226 to 1281 ms, ready 334 to 463 ms | warmed: resolve 0 ms, ready 342 ms and one 4953 ms HLS outlier |

The fixture UI run (`WP20-UI-11`) measures the player's own `playback_start`: a warmed search result started in 274 ms (`path=warmed`) and an unwarmed one in 2134 ms (`path=fastPath`, 2 s fixture lookup).

### Trade-off

On this fast connection the Opus WebM (4.2 to 4.7 MB) downloads and remuxes in under a second and a local file is ready in about 20 ms, while a remote AAC item needs 0.6 to 1.6 s to become ready. Progressive first therefore shortens resolution by about 0.6 s but leaves first audio roughly even (mean +0.18 s, median +0.2 s here). The gain is on slower or lossy links, where the before path's full download grows with file size and the 12 s Opus budget could time out before falling back to AAC, while the progressive start needs only the first range. The first play of a song may be the AAC tier (129 kbps instead of Opus 135 to 147 kbps); later plays use the prepared Opus copy once the background download finishes. Cellular timings were not measured.

## Test coverage

| Case | Kind | Where |
| --- | --- | --- |
| Opus best + AAC: AAC now, Opus prepared by the complete download, next play local | Unit | `StreamResolverFastStartTests.testFirstPlayStartsWithTheAAC...` |
| Opus only: prepared before play | Unit | `testOpusOnlyOfferKeepsTheOpusPreparationBeforePlayback` |
| AAC ranked above Opus: nothing to upgrade | Unit | `testAACRankedAboveOpusLeavesNothingToUpgrade` |
| Failed upgrade stores AAC, no WebM or partial variant | Unit | `testFailedUpgradeStoresTheAACAndCoolsOpusDown` |
| Ceiling governs the start pick and its upgrade (Best, Balanced, Data saver) | Unit | `testQualityCeilingGovernsTheFastStartPickAndItsUpgrade` |
| Reload still waits for the prepared Opus | Unit | `testReloadBestAvailableAudioStillWaitsForThePreparedOpus` |
| Download joining a warm flight prepares the upgrade from one lookup | Unit | `testDownloadJoiningAFastStartFlight...` |
| Hedge: slow fast path, fast path first, failure starts at once, both fail, warms never hedge | Unit | `StreamResolverFastStartTests` hedge cases |
| Late promotion wakes extraction while fast remains held; cache and warm mark survive | Unit | `StreamResolverFastStartTests.testLateWarmPromotionStartsExtractionWithoutWaitingForTheFastTimeout` |
| Early promotion retains the original timer; warm cancellation spares foreground | Unit | `StreamResolverFastStartTests.testEarlyPromotionKeepsTheOriginalHedgeBudgetAndWarmCancellationSparesForeground` |
| Retired timer/result cannot affect a same-key replacement; feeds close | Unit | `StreamResolverFastStartTests.testCancelledFlightLateTimerAndResultCannotWakeOrClearItsReplacement` |
| Foreground leaves before the timer; the surviving warm stays speculative | Unit | `StreamResolverFastStartTests.testForegroundLeavingBeforeHedgeKeepsTheRemainingWarmSpeculative` |
| Elapsed speculative failure never enters extraction | Unit | `StreamResolverFastStartTests.testElapsedSpeculativeFailureNeverEntersExtractionAndCleansEvents` |
| Foreground joins before warm fast success; warmed URL remains reusable | Unit | `StreamResolverFastStartTests.testForegroundJoiningBeforeWarmFastSuccessKeepsTheWarmedURL` |
| Queue adopts the same-song warm download; old warm cancellation cannot cancel it | Unit | `StreamResolverFastStartTests.testQueueAdoptsSameSongWarmDownloadBeforeTheWarmOwnerCancels` |
| Retry retains original total and all stage times; explicit request resets; trace label stays captured | Unit | `StreamResolverFastStartTests.testAutomaticRetryPreservesTotalElapsedAndAccumulatesEveryStage`, `testNewSelectionOrExplicitRetryResetsStartupAccounting`, `testStartupPathIsCapturedBeforeLaterTraceWrites` |
| Diagnostic attempt count saturates without dropping elapsed time | Unit | `StreamResolverFastStartTests.testStartupAttemptCounterSaturatesWithoutResettingElapsedTime` |
| Search 3 and collection 2 with a first-song download; video and duplicates excluded | Unit | `PlaybackWarmerTests.testSearchWarmsThreeResults...` |
| Offline, Low Data Mode, expensive without consent skip; consent warms | Unit | `testOfflineLowDataAndUnconsentedExpensivePathsSkipEverything` |
| 12 per minute across events, refunds, renewal after a minute | Unit | `testTwelveResolutionsPerMinute...` |
| Newer query cancels, only the newest outcome publishes, token-fenced download cancel | Unit | `testANewQueryCancelsTheRunningWarm...` |
| Leaving a page cancels only its own job | Unit | `testLeavingAPageCancelsOnlyThatPagesJob` |
| Inert without `StreamWarming`, disabled switch, unit host default off | Unit | `testResolversWithoutWarmingSupport...` |
| YouTube warm skips local copies and live URLs, downloads only the first | Unit | `testYouTubeWarmSkipsLocalCopies...` |
| Tap reuses the warmed URL and reports `warmed` once | Unit | `testTappingAWarmedSongReusesItsURLAndReportsWarmed`, composite case |
| Warm never displaces the queue prefetch download; stale cancel spares a newer download | Unit | `testAWarmNeverDisplacesTheQueuePrefetchDownload...` |
| Composite routes prefixed songs to their resolvers without downloads | Unit | `testCompositeWarmRoutesPrefixedIDs...` |
| Warmed search result starts well before an unwarmed one; a new query rewarms | UI (fixture) | `GanaBajanaFastStartUITests` |
| Per-path live timings | Live | `PlaybackStartLiveTests` (two tests) |

## Not verified

- This startup bugfix's added tests and Release build are pending coordinator execution. Focused suite selectors: `GanaBajanaTests/StreamResolverFastStartTests`, `GanaBajanaTests/StreamPrefetchTests`, `GanaBajanaTests/PlaybackWarmerTests`, `GanaBajanaTests/StreamCacheTests`; include the existing ownership tests before Release validation.
- Cellular, Low Data Mode and lossy-network timings on a device; the live numbers are one fast Mac connection.
- `playback_start` in the production app against live providers (the live tests time resolver plus AVPlayer readiness; the fixture UI test times the player's own event).
- The speculative download's cache admission under a full cache is covered by the existing speculative admission tests, not by a warm-specific test.
