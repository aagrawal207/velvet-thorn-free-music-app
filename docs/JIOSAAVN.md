# JioSaavn catalog

R12 WP9. JioSaavn joins YouTube Music behind the `MusicSource` abstraction: search, albums, artists, playlists, radio, plain lyrics and streams up to 320 kbps. YouTube Music stays the primary catalog and the fallback for every id without a prefix. Shared docs (`ARCHITECTURE`, `PROVIDERS`, `PRIVACY`, `VERIFICATION`) are integrated at round end; the "Docs delta" list in the WP9 report names the facts to carry over.

## Purpose

- Let the owner search and play the Hindi and regional catalog that JioSaavn covers better than YouTube Music, at a stable AAC bitrate, without changing how saved YouTube songs work.
- Keep one set of models. JioSaavn rows become `Track`, `MusicCollection`, `CatalogPage` and `ArtistPage` values; the only difference is the id prefix.
- Prepare the seam that WP9b (Gaana) reuses: `CompositeCatalog` and `CompositeStreamResolver` route by prefix; Gaana joined in R13 (`docs/GAANA.md`).

## Behaviour

- Search (Search tab only) asks every enabled source at once. YouTube Music results lead; each further source gets its own section ("YouTube Music", "JioSaavn", "Gaana") when more than one source answers. Since WP9b, `TrackRow` shows a caption2 "JioSaavn" badge after the byline (`track.source.<id>`) in rows with the provider byline, not at accessibility sizes and not in rows with a custom byline; the accessibility value keeps "Song, JioSaavn" and its play-count sentence names the source. Filters (Songs, Albums, Artists, Playlists) apply per source. Pagination ("More songs") follows YouTube's continuation; JioSaavn returns its first 20 rows per filter. A source that fails or exceeds the six-second secondary deadline is dropped from that search; the healthy sources still show. Only when every source fails does the primary's error surface.
- Internal lookups (artist matching for name-only credits, radio seeds, spotlight song counts, artist artwork, release checks) keep one provider. `CompositeCatalog.search` fans out only inside `CompositeCatalog.searchingAllSources { }`, which `MusicAppModel.loadSearch` sets. Without it a search is a plain YouTube Music pass-through, so play-count units and duplicate recordings from two providers never enter a single-source page.
- Browse, artist, radio, lyrics and album descriptions route by id prefix: `saavn:` ids go to `JioSaavnCatalogService`, `gaana:` ids to `GaanaCatalogService`, bare ids to `YouTubeMusicService`. A prefix without an installed provider answers empty for search, radio and lyrics and "not available in this build" for browse and artist.
- JioSaavn albums, playlists and artists render through the existing `CollectionDetailView`, `MusicCollection` and `ArtistPage` types. Album pages carry header credits; artist pages carry top songs, albums plus singles and the latest release as releases, and similar artists when the provider lists them. Playlists page through the provider at 100 songs per page and at most 3 pages.
- Playback resolves at play time: fresh `song.getDetails`, DES decryption of `encrypted_media_url`, tier selection under the listener's Audio quality ceiling, then a leading Range probe of the chosen file. Streams report `SourceAudioQuality(codec: .aac, bitRate: 320_000 / 160_000 / 96_000 / 48_000, sampleRate: 44_100, channels: 2)`, `loudnessDb: nil` (JioSaavn publishes no loudness, so normalization leaves these songs at unity gain), `viewCount` from the song's `play_count`, and `expiresAt` six hours ahead. The in-memory URL cache holds 24 songs; nothing decrypted is written to disk or to the library.
- Caching, prefetch, storage inventory and limits stay with the YouTube resolver's `AudioCache`. Since WP9b (R13), `CompositeStreamResolver.download(_:)` stores `saavn:` songs in that same cache (`AudioCache.store(trackID:from:stream:permit:track:)`, file `saavn~<id>.m4a`): the cache pipeline warms the current and next JioSaavn song like a YouTube song, managed downloads promote the copy, and `resolve` / `refreshQuality` prefer a complete local copy so downloaded JioSaavn songs play offline. The composite mirrors the player's known-offline flag for prefixed ids and answers the usual "You're offline and this song isn't cached" for an uncached one. `YouTubeStreamResolver` itself refuses any prefixed id with `invalidID`. Search prefetch warms at most two JioSaavn results (details plus a Range probe), skipping songs that already have a local copy.
- Settings > Discovery > Catalog sources lists JioSaavn and, since WP9b, Gaana, both switchable (`docs/GAANA.md`). YouTube Music is not listed and cannot be turned off. Turning JioSaavn off hides its rows from the current results at once and stops asking it; already saved `saavn:` songs stay playable because playback routes by prefix, not by the enabled list. The choice syncs through `UserPreferences.enabledCatalogSources` in `MusicSource` order.
- Share for a `saavn:` song links to `https://www.jiosaavn.com/search/song/<title>`: the provider's `perma_url` token differs from the song id, so a guessed `/song/<slug>/<id>` form is not used. "Open in YouTube Music" appears only for YouTube ids (gated by `track.source`).
- Lyrics: LRCLIB stays primary and matches on title, artist and duration, so it works unchanged. The fallback goes through `CompositeCatalog.lyrics(for:)`, which sends `saavn:` ids to `lyrics.getLyrics` (plain text, attribution "JioSaavn", no link) and never to YouTube Music. A failure envelope for a song without lyrics is treated as absence, not an outage.
- Skipped for JioSaavn ids without a crash: YouTube Data API recording metadata, MusicBrainz work evidence and Song details' YouTube fields (all gate on `CatalogText.videoID` or `track.source`), Home editorial discovery (`discovery(languages:)` returns `[]`), album descriptions (`nil`, successful absence). Watch, widgets and the library treat ids opaquely; nothing outside `AudioCache` and `CatalogText.videoID` validates an 11-character id.

## Endpoints

Host `https://www.jiosaavn.com/api.php`, GET only, unofficial. Every call adds `_format=json&_marker=0&api_version=4&ctx=web6dot0`; `reco.getreco` uses `ctx=android` because the web context answers `[]`. Headers: Chrome-like `User-Agent` (the catalog's `CatalogTransport.browserUserAgent`), `Accept: application/json`, `Accept-Language: en-US,en;q=0.9`, cookies off. Responses arrive as `text/html; charset=UTF-8` but contain JSON; titles are HTML-escaped (`&quot;`, `&amp;`, `&#039;`) and are unescaped on parse. Quick calls may wrap JSON in a JSONP callback; the decoder strips it. Verified live from the Mac on 25 September 2026.

| Call | Parameters | Used for | Observed shape |
| --- | --- | --- | --- |
| `search.getResults` | `q`, `p=1`, `n=20` | Songs filter | `{"total","start","results":[song]}` |
| `search.getAlbumResults` | `q`, `p`, `n` | Albums filter | `results:[album]`, `more_info.artistMap.primary_artists`, `year` |
| `search.getArtistResults` | `q`, `p`, `n` | Artists filter | `results:[{"name","id","image","role","perma_url"}]`, 50 px images |
| `search.getPlaylistResults` | `q`, `p`, `n` | Playlists filter | `results:[playlist]`, `more_info.song_count`, `more_info.language` |
| `content.getAlbumDetails` | `albumid` | `browse(saavn:album:<id>)` | Album object, songs under `list`, header credits in `more_info.artistMap`; an unknown id returns an empty album with `id:""` |
| `playlist.getDetails` | `listid`, `p`, `n=100` | `browse(saavn:playlist:<id>)` | Playlist object, songs under `list`, `list_count` total; `p`/`n` page the list |
| `artist.getArtistPageDetails` | `artistId` | `artist(saavn:artist:<id>)` | `name`, `image`, `topSongs`, `topAlbums`, `singles`, `latest_release`, `similarArtists` (empty for the recorded artist), `subtitle` "Artist • N Listeners", `follower_count` |
| `song.getDetails` | `pids` (comma-separated, at most 20) | Play-time media fields, `browse(saavn:<id>)` | `{"songs":[song]}` with `more_info.encrypted_media_url`, `320kbps`, `duration`, `has_lyrics` |
| `reco.getreco` | `pid`, `ctx=android` | `radio(seed:)` | `{"<pid>":[song]}`; `[]` for the web context or an unknown id |
| `lyrics.getLyrics` | `lyrics_id` (equals the song id) | Lyrics fallback | `{"lyrics":"line<br>line","lyrics_copyright"}`; songs without lyrics answer `{"status":"failure","error":{"msg":...}}` with HTTP 200 |
| `webapi.get` | `token`, `type=song` | Not used; verified as an alternative details call | Same `{"songs":[...]}` shape |
| `autocomplete.get` | `query` | Not used (the four search calls cover the filters) | `albums/songs/playlists/artists/topquery/shows/episodes` each `{"data":[...]}` |

Other recipients: `aac.saavncdn.com` (media; leading `Range: bytes=0-1023` probe, then AVPlayer's own range requests) and `c.saavncdn.com` (artwork, 500 px). `ArtworkURL` passes both hosts through untouched; the parser rewrites `-150x150.`/`_150x150.`/`_50x50.` file names to `500x500`, which the CDN serves (verified for album, artist and editorial playlist names, jpg and webp).

Bounds (mirroring `CatalogTransport` and `docs/PROVIDERS.md`):

| Bound | Value |
| --- | --- |
| Request timeout | 8 s per request (`timeoutIntervalForRequest`), 16 s resource |
| Body cap | 4 MiB through `URLSession.boundedData`, checked while receiving |
| Connections | 4 per host, ephemeral session, no cookies, no URL cache |
| Soft rate | 8 requests per second in a sliding window; the actor sleeps, never drops |
| Retries | One retry after 350 ms for a timeout, connection loss or 5xx; `Retry-After` above 2 s blocks the host for that long |
| 429 | `MusicServiceError.rateLimited`; `Retry-After` (seconds or HTTP date) or 30 s default blocks further requests |
| Response cache | Memory only, 32 entries or 6 MiB; search 60 s, details (album, playlist, artist, song, lyrics) 10 min, radio 5 min |
| Stream URL cache | 24 songs, 6 h from resolution, cleared when the quality ceiling changes |
| Media probe | 8 s deadline, `Range: bytes=0-1023`, requires 200/206, `audio/mp4`-family content type and an `ftyp` prefix |
| Secondary search deadline | 6 s inside the composite; YouTube's own 35 s transport bound is unchanged |
| Playlist paging | 100 songs per page, at most 3 pages (300 songs) |

## Identity scheme

`MusicSource` (Sources/Core/MusicSource.swift):

| Entity | Id | Helper |
| --- | --- | --- |
| Song | `saavn:<song id>` | `MusicSource.jioSaavn.trackID(forProviderID:)`, `Track.source`, `Track.providerID` |
| Album | `saavn:album:<id>` | `collectionID(.album, providerID:)` |
| Playlist (and mix) | `saavn:playlist:<id>` | `collectionID(.playlist, providerID:)` |
| Artist | `saavn:artist:<id>` | `collectionID(.artist, providerID:)`, also `ArtistCredit.id` |
| YouTube Music | bare ids (11-character video ids, `UC…`, `MPRE…`, `VL…`) | `collectionID` returns the provider id unchanged |

`MusicSource.entityKind(of:)` answers `.track/.album/.playlist/.artist` for prefixed ids and `nil` for bare ids; `entityProviderID(of:)` strips both prefixes. `MusicCollection.source` and `Track.source` derive from the id. Provider ids are validated as short URL-safe tokens or decimals before they become an id. Bare 11-character ids keep every existing path.

## Stream decryption

`more_info.encrypted_media_url` is Base64 of DES-ECB with PKCS7 padding under the 8-byte ASCII key `38346591`, decrypted with CommonCrypto (`CCCrypt`, `kCCAlgorithmDES`, `kCCOptionECBMode | kCCOptionPKCS7Padding`). The plaintext is `https://aac.saavncdn.com/<dir>/<name>_96.mp4`; the decoder refuses hosts outside `saavncdn.com`. `JioSaavnMediaURL.encrypt` exists for tests only. Decrypted URLs live in the resolver's memory cache and are never persisted; the library keeps `saavn:<id>` and metadata.

## Quality tiers

The CDN publishes `<name>_320.mp4` (only when the row's `320kbps == "true"`), `_160`, `_96`, `_48` and `_12`; the app uses 320/160/96/48. Selection under `AudioQualityPreference.maximumBitRate`: Best (nil) tries 320 (when flagged), 160, 96, 48; Balanced (160 000) tries 160, 96, 48; Data saver (64 000) tries 48. The first tier whose Range probe succeeds wins; a probe failure falls to the next tier. Observed for "Tum Hi Ho" (aRZbUYD7): 320 = 10 527 454 bytes, 160 = 5 286 686, 96 = 3 190 357, 48 = 1 618 130, 12 = 439 411, all `audio/mp4` with `Accept-Ranges: bytes`; a missing tier answers 404. "Reload best available audio" re-resolves with a fresh details call. The player's More sheet shows the tier as source metadata.

## APIs

| Type | Contract |
| --- | --- |
| `JioSaavnTransport` (actor) | `get(call:parameters:context:ttl:forceRefresh:cacheIf:) -> JioSaavnResponse`; static `url(...)` and `decode(_:)`; `APIFailure` for the provider's failure envelope |
| `JioSaavnParser` | `song`, `songs`, `album`, `playlist`, `artist`, `search(_:filter:)`, `albumPage`, `playlistPage -> (page, total)`, `artistPage(_:id:)`, `songDetails`, `recommendations(_:seedProviderID:)`, `lyrics`; `JioSaavnText.unescape/clean/identifier/artwork/language/flag` |
| `JioSaavnMediaURL` | `decrypt`, `encrypt`, `Tier`, `tiers(has320:)`, `candidates(has320:maximumBitRate:)`, `url(_:tier:)`, `isMediaHost` |
| `JioSaavnCatalogService` (actor) | `MusicCatalogProviding`, `LyricsProviding`, `AlbumDescriptionProviding` (nil); `songDetails(providerIDs:forceRefresh:) -> [JioSaavnSong]`; `discovery` returns `[]`; foreign ids answer empty (`browse`, `radio`, `lyrics`) or unavailable (`artist`) |
| `JioSaavnStreamResolver` (actor) | `StreamResolving`; `setAudioQualityPreference`; joins concurrent resolutions of one song and cancels the shared lookup when the last waiter leaves |
| `CompositeCatalog` (actor) | Same three protocols; `setEnabledSources`, `activeSources`, `searchingAllSources { }`; `EmptyCatalog` for uninstalled prefixes |
| `CompositeStreamResolver` (struct) | `StreamCacheManaging` and `PlaybackConfigurableResolving` (`setNetworkOffline`, `setRemoteFallbackEnabled`, `refreshQuality`, `setAudioQualityPreference`); cache surface delegates to the YouTube resolver; since WP9b `download` stores `saavn:` (and `gaana:` fallback) files in the shared cache and prefixed `resolve` checks it first (`init(youTube:saavn:gaana:audioCache:isOffline:)`) |
| `PlayerController` | Uses `any PlaybackConfigurableResolving` instead of `YouTubeStreamResolver` for network, remote fallback, quality ceiling and "Reload best available audio" |
| `MusicAppModel` | `makeProductionCatalog`/`makeProductionResolver` build the composites with one shared `JioSaavnCatalogService`; `applyPreferenceServices` forwards `enabledCatalogSources` |
| `CatalogSourcesSettingsView` | Settings > Discovery > Catalog sources; ids `settings.sources`, `settings.sources.saavn`, `settings.sources.gaana`, `settings.sources.footer` |
| `SearchView` | Section headers `search.section.youtube` / `search.section.saavn` when more than one source contributes; rows carry "Song, JioSaavn" as accessibility metadata |
| Debug | `--saavn-fixture` (with `--uitesting --seed-ui`) installs `DebugSaavnFixtureCatalog`: two songs and one album for "tum", `saavn:fixtureTum01/02`, `saavn:album:fixtureJabWeMet`; playback uses the existing fixture waveform through `DebugMusicFixtures.resolve` |

## Metrics

All OSLog, subsystem `com.agraabhi.ganabajana`, category `JioSaavn` unless noted; values are counts or bounded enums, never queries, ids or URLs.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=request status=ok bytes=<n>` | A 2xx response is received | bytes count | Confirms the endpoint still answers and shows body sizes against the 4 MiB cap |
| `event=request status=rateLimited` | HTTP 429 | none | Detects provider throttling before users report empty sections |
| `event=request status=failed code=<n>` / `reason=network\|tooLarge` | 5xx after retry, 401/403, other status, transport error, oversized body | HTTP code, reason enum | Separates provider refusals from connectivity and cap hits |
| `event=api_failure call=<name> length=<n>` | The provider's `status=failure` envelope | call name (fixed set), message length | Lyrics absence is expected; other calls failing here mean an API change |
| `event=search filter=<f> tracks=<n> collections=<n>` | A search page parsed | filter enum, counts | Shows whether a filter returns rows, without the query |
| `event=browse kind=album\|playlist tracks=<n> [truncated=1]` | Album or playlist page parsed | kind, count, truncation flag | Playlist page budget visibility |
| `event=artist topSongs=<n> releases=<n> related=<n>` | Artist page parsed | counts | Detects an empty artist payload for a valid id |
| `event=radio tracks=<n>` | `reco.getreco` parsed | count | Zero over time means the Android context stopped answering |
| `event=lyrics available=0\|1` | Lyrics fallback answered | flag | Fallback usefulness |
| `event=resolve status=ok quality=320\|160\|96\|48` | A tier probe succeeded | tier | Which tiers the CDN actually serves under each preference |
| `event=tier_unavailable quality=<tier>` | A tier probe failed | tier | Detects the 320 flag lying or CDN changes |
| `event=resolve status=failed reason=missing\|noMedia\|decrypt\|noTier` | Resolution gave up | reason enum | Distinguishes a removed song from a key or URL scheme change |
| `event=stream_cache_hit quality=<tier>` | Cached URL reused | tier | Cache effectiveness within the 6 h lifetime |
| `event=prefetch_unavailable` | A prefetch resolution failed | none | Warm-up failures are expected to be rare |
| `event=composite_search sources=<n> ok=<n> failed=<n>` (category `Catalog`) | A fanned-out search finished | counts | Shows how often a secondary source drops out of a search |
| `event=cache_skipped source=gaana reason=hls` (category `StreamResolver`) | The pipeline asked to cache a Gaana HLS stream; `saavn:` songs no longer emit this since WP9b | source enum, reason | Confirms which songs stream without a copy |
| `event=audio_cached source=saavn\|gaana bytes=<n>`, `event=audio_cache_lookup source=<s> hit=0\|1` (category `StreamResolver`) | A prefixed song was stored in or looked up from the shared cache (WP9b) | source enum, bytes, flag | Cache volume and offline hit rate for prefixed songs |

## Test coverage

Unit: `Tests/JioSaavnTests.swift` (24 cases, 1 opt-in live) and `Tests/CompositeCatalogTests.swift` (11 cases). Fixtures in `Tests/Fixtures/saavn-*.json` are trimmed live recordings (public catalog rows, no account data). UI: `UITests/GanaBajanaCatalogSourcesUITests.swift` (2 cases) on the fixture provider.

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `testDESRoundTripDecryptsAKnownURL` | encrypt then decrypt with the provider key | Unit |
| `testRecordedCipherTextDecryptsToTheObservedCDNURL` | live ciphertext to the observed `_96.mp4` URL | Unit |
| `testDecryptionRejectsGarbageAndForeignHosts` | invalid Base64, short block, non-CDN host | Unit |
| `testTierURLsReplaceTheBitrateSuffix` | `url(_:tier:)` rewrite and nil for names without a tier | Unit |
| `testQualityCeilingSelectsTiers` | Best / Balanced / Data saver candidates, 320 flag, `SourceAudioQuality` | Unit |
| `testHTMLEntitiesAreUnescaped` | named, decimal and hex entities, artwork resizing, identifier validation | Unit |
| `testSongSearchRowsMapOntoTracks` | every mapped field of a song row, share URL | Unit |
| `testAlbumArtistAndPlaylistSearchRowsMapOntoCollections` | album, artist and playlist rows | Unit |
| `testAlbumPageCarriesHeaderCreditsAndSongs` | `content.getAlbumDetails` | Unit |
| `testPlaylistPageReportsTheProviderTotal` | `playlist.getDetails` total | Unit |
| `testArtistPageCollectsSongsReleasesAndUnescapesTitles` | `artist.getArtistPageDetails` | Unit |
| `testRecommendationsExcludeTheSeedAndAcceptTheAndroidShape` | keyed reco object and bare `[]` | Unit |
| `testSongDetailsKeepTheEncryptedMediaFields` | `song.getDetails` media fields | Unit |
| `testLyricsConvertLineBreaksAndDetectFailures` | `<br>` lines, failure envelope, JSONP unwrap, non-container rejection | Unit |
| `testSearchSendsTheDocumentedParametersAndCachesForAMinute` | request URL and headers, 60 s cache, continuation pass-through | Integration (mock session) |
| `testBrowseAndArtistRouteByPrefixedIdentity` | album, playlist paging stop, artist, artist-as-browse, foreign id, wrong kind, discovery | Integration (mock session) |
| `testRadioUsesTheAndroidContextAndLyricsTreatFailureAsAbsence` | `ctx=android`, foreign seed, lyrics plain/absent/foreign | Integration (mock session) |
| `testRateLimitingHonoursRetryAfterWithoutASecondRequest` | 429 with `Retry-After` blocks until the clock passes | Integration (mock session) |
| `testOversizedBodiesAreRejected` | declared 5 MiB body against the 4 MiB cap | Integration (mock session) |
| `testResolverPicksTheHighestProbedTierUnderEachPreference` | tier per preference, stream fields, one probe | Integration (mock session, stub probe) |
| `testResolverFallsToTheNextTierAndCachesTheResult` | 320 probe failure, cache hit, ceiling change, bare id refusal | Integration (mock session, stub probe) |
| `testPrefixedIdentityHelpers` | collection ids, entity kinds, provider ids, sources | Unit |
| `testShareURLsFollowTheSource` | YouTube, JioSaavn, Gaana share links | Unit |
| `testLiveSearchResolvesAPlayableStream` | real search, resolve and HEAD (`GANABAJANA_SAAVN_LIVE=1`) | Live, opt-in |
| `testSearchFansOutAndListsYouTubeFirst` | merged order, continuation, per-source filter | Unit (stubs) |
| `testUnscopedSearchesStayWithThePrimaryCatalog` | internal lookups without `searchingAllSources` | Unit (stubs) |
| `testAFailingSecondarySourceStillReturnsTheHealthyOne` | secondary throws | Unit (stubs) |
| `testAFailingPrimaryStillReturnsTheSecondarySource` | primary throws | Unit (stubs) |
| `testWhenEverySourceFailsThePrimaryErrorSurfaces` | both throw | Unit (stubs) |
| `testATimingOutSecondarySourceIsDroppedAtTheDeadline` | secondary sleeps past the deadline | Unit (stubs) |
| `testDisabledSourcesAreNotSearchedAndContinuationsStayWithYouTube` | enabled list, continuation, empty list keeps YouTube | Unit (stubs) |
| `testRoutingFollowsTheIdPrefix` | browse, artist, radio, recommendations, lyrics, description, discovery | Unit (stubs) |
| `testAnUninstalledSourceAnswersEmptyOrUnavailable` | `gaana:` without a provider, pass-through composite | Unit (stubs) |
| `testCompositeResolverRoutesByPrefixAndKeepsCacheWithYouTube` | resolve, refreshQuality, quality forwarding, gaana routing (WP9b) | Integration (mock session, injected YouTube resolver) |
| `testJioSaavnDownloadsLandInTheSharedCacheAndPlayOffline` (WP9b) | `download(saavn:)` into the shared cache, inventory, offline resolve and playback, direct YouTube refusal | Integration (fixture cache, player) |
| `testPreferenceChangesReachTheInstalledComposite` | `MusicAppModel.updatePreferences` to `setEnabledSources` | Integration (model) |
| `testSearchGroupsResultsBySourceAndPlaysAJioSaavnSong` | two sections, ordering, per-source filters, JioSaavn album page, playback and player title | UI |
| `testCatalogSourcesSettingHidesTheJioSaavnSection` | Settings row and page, Gaana disabled, toggle off hides the section, toggle on restores it | UI |
| Existing `CatalogServiceTests`, `CatalogParsingTests`, `CatalogRequestTests`, `CatalogPlayCountTests`, `YouTubeLyricsTests`, `AlbumDescription*Tests`, `ListeningLanguageRadioTests`, `ModelTests`, `LibraryPlaybackDiscoveryPreferencesTests` | YouTube paths unchanged | Regression |

## Not verified

- Physical-device playback of a JioSaavn stream and background audio; the live check ran a HEAD from the Mac and the simulator unit host only.
- 320 kbps availability across the catalog: every song sampled during recording carried `320kbps: "true"`; the fallback to 160 is exercised only through a stubbed probe.
- Provider rate limits and `Retry-After` behaviour were not observed live (no 429 during recording); handling is tested with a mocked session.
- JioSaavn's terms: the API is unofficial and undocumented; use is the owner's accepted local-only risk (`docs/ROADMAP.md`).
- Live JioSaavn downloads on a device: the shared-cache path (WP9b follow-up) is covered by `CompositeCatalogTests.testJioSaavnDownloadsLandInTheSharedCacheAndPlayOffline` with a mocked CDN; managed downloads and audio export of `saavn:` ids reuse the cache tier and were not run against the live CDN.
- Gaana: see `docs/GAANA.md`.
- `similarArtists` mapping: the recorded artist returned an empty list, so related artists are parsed but not verified with real rows.
- The full `GanaBajanaSearchDiscoveryUITests` suite (19 cases) ran with 15 passes; the 4 failures (3 radio-station ordering waits, 1 radio-page scroll precondition) reproduce on the current shared tree under heavy machine load and involve no file this package changed. They need a quiet rerun.
