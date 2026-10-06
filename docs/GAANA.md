# Gaana catalog

R13 WP9b. Gaana joins YouTube Music and JioSaavn behind the `MusicSource` abstraction: search, albums, artists, playlists, artist radio and HLS streams up to 128 kbps, with the same recording on JioSaavn and then YouTube Music as playback fallbacks. YouTube Music stays the primary catalog and the fallback for every id without a prefix. Shared docs (`ARCHITECTURE`, `PROVIDERS`, `PRIVACY`, `VERIFICATION`) are integrated at round end; the "Docs delta" list in the WP9b report names the facts to carry over.

## Purpose

- Let the owner search and play Gaana's Hindi and regional catalog next to JioSaavn's, again without changing how saved YouTube songs work.
- Keep one set of models. Gaana rows become `Track`, `MusicCollection`, `CatalogPage` and `ArtistPage` values; the only difference is the id prefix.
- Reuse the WP9 seams unchanged: `CompositeCatalog` fans out to three sources, `CompositeStreamResolver` routes by prefix, and the shared `AudioCache` now stores prefixed songs (R12 follow-up shipped with this package).

## Behaviour

- Search (Search tab only) asks every enabled source at once. YouTube Music results lead; JioSaavn and Gaana each get their own section when more than one source answers. Filters (Songs, Albums, Artists, Playlists) map to Gaana's `include=track|album|artist|playlist`. Gaana returns its first page (about 50 rows) per filter; pagination stays with YouTube's continuation. A source that fails or exceeds the six-second secondary deadline is dropped from that search.
- Search rows carry title, artwork, language and performer names without ids (`sti` is "Mithoon,Arijit Singh"), so `openArtist` resolves them by name; album and artist pages and the details call carry `gaana:artist:<id>` credits. Search rows carry no duration; the details call and every page fill it.
- Rows from JioSaavn or Gaana show a caption2 badge with the source name after the byline (`track.source.<id>`), only in rows with the provider byline (search, albums, artists, library lists) and not at accessibility text sizes; rows with a custom byline (Recap, Recently played) stay unmarked. The row's accessibility value already says "Song, Gaana". The play-count sentence in the accessibility value names the row's source ("Gaana: 180,685,771 plays worldwide").
- Browse, artist and radio route by id prefix: `gaana:` ids go to `GaanaCatalogService`. Albums and playlists open through `CollectionDetailView` with header credits (albums) and the songs the provider chose to list (playlists list about 100 of a long playlist in one response). Artist pages carry top songs, albums as releases and similar artists.
- Radio: Gaana's recommendation endpoints answer empty without a signed-in token, so `radio(seed:)` is the seed's first credited artist's popular songs (at most 20, seed excluded). A seed whose credits have no Gaana artist id (a search row) is looked up once through the details call. Autoplay and Home mixes use it like any other radio.
- Playback resolves at play time: fresh `song_detail`, AES decryption of the `urls.high` / `urls.medium` messages, tier selection under the listener's Audio quality ceiling, then a GET of the master playlist to prove the token still opens the stream. Streams are HLS (`.m3u8` master, MPEG-TS segments, AAC-LC 44.1 kHz stereo) and report `SourceAudioQuality(codec: .aac, bitRate: 128_000 / 64_000, sampleRate: 44_100, channels: 2)`, `loudnessDb` from the provider's integrated LUFS relative to the -14 LUFS reference (-8.0 LUFS becomes 6 dB, so normalization attenuates it like a YouTube stream), `viewCount` from `popularity`, and `expiresAt` from the payload's `expiryTime` (about four hours). The in-memory URL cache holds 24 songs; nothing decrypted is written to disk or to the library.
- AVPlayer plays HLS natively. The segment tokens (`hdntl`) are bound to the User-Agent that fetched the master, and AVPlayer fetches master, media playlists and segments itself, so no header work is needed. The equalizer's `MTAudioProcessingTap` needs a track-based asset and is bypassed for HLS items (`event=equalizer_bypass reason=noAudioTrack`); the gain path (volume normalization) still applies.
- Cross-source fallback: when Gaana hands out no stream (removed song, `rest_lev`/`vendor_rest_lev` restriction, missing or expired `urls`, decryption or probe failure), `GaanaStreamResolver` asks JioSaavn and then YouTube Music for the same recording: a songs search for "<title> <first artist>", accepting the first result whose normalized title equals the song's, whose duration is within 3 s and whose credits include the first artist (when known). The fallback's own stream is played and shown: the More sheet's Audio quality row reads "Best available · 320 kbps AAC · 44.1 kHz · Stereo" for a JioSaavn copy. No "via JioSaavn" wording was added to `PlayerOptionsSheet` (WP11 edits that file; see the report).
- Caching and downloads (R12 follow-up): `CompositeStreamResolver.download(_:)` routes `saavn:` and `gaana:` songs through the shared `AudioCache` (`store(trackID:from:stream:permit:track:)`, stored as `saavn~<id>.m4a` / `gaana~<id>.m4a`) after resolving with the source resolver; `resolve` and `refreshQuality` prefer a complete local copy, so offline playback finds downloaded JioSaavn songs and the cache pipeline warms them like YouTube songs. A Gaana song that resolves to its own HLS stream cannot be stored as one file: the composite logs `event=cache_skipped source=gaana reason=hls` and the song streams without caching. A Gaana song that fell back to a JioSaavn file is cached under its `gaana:` id. Prefetch skips songs that already have a local copy.
- Settings > Discovery > Catalog sources lists JioSaavn and Gaana, both switchable ("Search, albums, artists and playlists, streams up to 128 kbps" for Gaana). Turning Gaana off hides its rows at once and stops asking it; already saved `gaana:` songs stay playable because playback routes by prefix. The choice syncs through `UserPreferences.enabledCatalogSources`.
- Share for a `gaana:` song links to `https://gaana.com/search/all?keyword=<title>`: song pages need the seokey slug, which the library does not keep. "Open in YouTube Music" stays gated on `track.source`.
- Lyrics: LRCLIB stays primary and matches on title, artist and duration. `GaanaCatalogService` is not a `LyricsProviding` (Gaana's lyrics endpoints need a signed-in token), so `CompositeCatalog.lyrics(for:)` answers unavailable for `gaana:` ids and the fallback never reaches YouTube Music.
- Skipped for Gaana ids without a crash: YouTube Data API recording metadata, MusicBrainz work evidence and Song details' YouTube fields (all gate on `CatalogText.videoID` or `track.source`), Home editorial discovery (`discovery(languages:)` returns `[]`), album descriptions (`nil`, successful absence).

## Endpoints

Two hosts, GET only, unofficial, reverse-read from the public web player bundle on 26 September 2026 and verified live from the Mac the same day. Every request carries the web player's identity headers `deviceType: GaanaWebsiteApp`, `appVersion: V6`, `gaanaAppVersion: gaanaAndroid-8.60.2`, `deviceId: website`, plus `Accept: application/json`, `Accept-Language` and the catalog's Chrome-like `User-Agent`; cookies off. Without `deviceType` and `appVersion` the details host answers `{"count":0,"tracks":null}`; without `gaanaAppVersion` the search host answers an empty body. Details calls add `st=hls&pkc=true&request_type=web`, the combination whose media messages the web player decrypts (without `pkc=true` the messages use another, unhandled format).

| Call | Parameters | Used for | Observed shape |
| --- | --- | --- | --- |
| `https://gsearch.gaana.com/vichitih/go/v2/` | `query`, `include=track\|album\|artist\|playlist` (`allItems` for a mixed page), `geoLocation=GLOBAL`, `content_filter=2`, `isRegSrch=0`, `webVersion=mix`, `rType=web`, `autocomplete=0`, `startIndex=0` | Search filters | `{"gr":[{"ty":"Track","gd":[row]}]}`; rows `iid`, `id`, `ti`, `aw` (200 px), `sti`, `seo`, `ty`, `language`, `isrc`; about 50 rows per filter, 33 for artists |
| `https://apiv2.gaana.com/?type=song&subtype=song_detail&track_id=<id>&limit=0,1` | numeric id (`seokey=<slug>` also works) | Play-time media fields, `browse(gaana:<id>)`, radio artist lookup | `{"count":1,"tracks":[track]}`; `urls.{medium,high,auto}.{message,bitRate,expiryTime}`, `preview_url`, `duration`, `artist[]`, `album_id`, `popularity`, `parental_warning`, `is_premium`, `rest_lev`, `loudness.integrated`; an unknown id answers `{"status":0,"msg":"This song is inactive","status_code":410}` |
| `apiv2.gaana.com/album/detail` | `album_id` (or `seokey`) | `browse(gaana:album:<id>)` | `album` header (`title`, `primaryartist`, `artist`, `year`), songs under `tracks`; unknown id `{"status":0,"msg":"Album is inactive"}` |
| `apiv2.gaana.com/playlist/detail` | `playlist_id` (or `seokey`) | `browse(gaana:playlist:<id>)` | `playlist` header, songs under `tracks` (98 of `trackcount` 130 observed, 408 KB), `count` |
| `apiv2.gaana.com/artist/entity/detail/v1` | `artist_id` (or `seokey`), `sortBy=popularity`, `sortOrder=0` | `artist(gaana:artist:<id>)` | `artist` header (`name`, `atw`, `favorite_count`, `songs`), `section_data[0]` "Top Songs" with 17 entities; unknown id `{"status":0,"error":"Artist not found"}` |
| `apiv2.gaana.com/home/artist/album/<id>` | `limit=0,20` | Artist releases | `{"count","entities":[{"entity_type":"AL","entity_id","name","artwork_medium","entity_info":[{key,value}]}]}` |
| `apiv2.gaana.com/player/similar-artists/<id>` | `limit=0,20` | Related artists | `entities` with `entity_type: "AR"` |
| `apiv2.gaana.com/home/artist/tracks/<id>` | `sortBy=popularity`, `sortOrder=0`, `song_type=new`, `limit=0,21` | `radio(seed:)` | `entities` with `entity_type: "TR"`, `entity_info` pairs `artist`, `album`, `duration`, `play_ct` |
| `apiv2.gaana.com/recommendation/recommendedTracks/<id>`, `rec.gaana.com/...` | Not used | Verified: 404 on apiv2; `rec.gaana.com` answers `{"tracks":[],"user_token_status":1}` without a login |
| `apiv2.gaana.com/lyrics/url`, `/lyrics/detail` | Not used | Verified: `{"user_token_status":"1"}` and metadata without text; lyrics need a signed-in token |

Other recipients: `vodhlsgaana-*.akamaized.net` (HLS master and media playlists, `segment-N.ts` files; the app's playlist probe is one GET of the master, the rest is AVPlayer's) and `a10.gaanacdn.com` (artwork). `ArtworkURL` passes both hosts through untouched; the parser rewrites `size_m`/`size_s` file names to `size_l` (400 px, verified for album, artist and playlist art; `size_xl` 800 px exists but is not offered in payloads). Legacy `crop_<n>x<n>` names keep their size and gain `https`.

Bounds (mirroring `JioSaavnTransport` and `docs/PROVIDERS.md`):

| Bound | Value |
| --- | --- |
| Request timeout | 8 s per request (`timeoutIntervalForRequest`), 16 s resource |
| Body cap | 4 MiB through `URLSession.boundedData`, checked while receiving |
| Connections | 4 per host, ephemeral session, no cookies, no URL cache |
| Soft rate | 8 requests per second in a sliding window; the actor sleeps, never drops |
| Retries | One retry after 350 ms for a timeout, connection loss or 5xx; `Retry-After` above 2 s blocks the host for that long |
| 429 | `MusicServiceError.rateLimited`; `Retry-After` (seconds or HTTP date) or 30 s default blocks further requests |
| 404 / 410 | "This music is no longer available on Gaana." |
| Response cache | Memory only, 32 entries or 6 MiB; search 60 s, details (song, album, playlist, artist, artist lists) 10 min, radio 5 min |
| Stream URL cache | 24 songs, until the payload's `expiryTime` (at most 4 h), cleared when the quality ceiling changes |
| Playlist probe | 8 s deadline, GET of the master, 64 KiB cap, requires 200 and an `#EXTM3U` prefix |
| Artist page | 3 requests (header with top songs, 20 albums, 20 similar artists); the two lists are optional |
| Secondary search deadline | 6 s inside the composite; YouTube's own 35 s transport bound is unchanged |
| Cross-source fallback | One songs search per fallback source (JioSaavn 20 rows, YouTube Music one page) plus that source's own resolution bounds |

## Identity scheme

`MusicSource` (Sources/Core/MusicSource.swift), symmetric with JioSaavn:

| Entity | Id | Helper |
| --- | --- | --- |
| Song | `gaana:<numeric track id>` | `MusicSource.gaana.trackID(forProviderID:)`, `Track.source`, `Track.providerID` |
| Album | `gaana:album:<numeric id>` | `collectionID(.album, providerID:)` |
| Playlist (and mix) | `gaana:playlist:<numeric id>` | `collectionID(.playlist, providerID:)` |
| Artist | `gaana:artist:<numeric id>` | `collectionID(.artist, providerID:)`, also `ArtistCredit.id` |

Numeric ids are the stable identity (details, albums, playlists and artists all accept them); seokeys (`tumhiho`, `aashiqui-2`) stay in the transient `GaanaSong.seokey`. `GaanaText.identifier` accepts decimal strings and URL slugs up to 128 characters. `AudioCache.isValidTrackID` already accepts `gaana:<id>` and stores it as `gaana~<id>`.

## Stream decryption

`urls.<tier>.message` is a string whose first character is a digit `p`; characters `1..<p` are filler, the 16 ASCII characters from `p` are the IV, and the rest is Base64 ciphertext. AES-128-CBC with PKCS7 padding under the 16-byte key `gy1t#b@jl(b$wtme` (the web bundle ships it as Base64 `Z3kxdCNiQGpsKGIkd3RtZQ==` in five fragments; the older community key `g@1n!(f1#r.0$)&%` / IV `asd!@#!@#@!12312` no longer decrypts these messages). The plaintext is `https://vodhlsgaana-<pop>.akamaized.net/hls/<n>/<album>/<track>/<128|64|f>.mp4.master.m3u8?hdnts=st=...~exp=...~acl=...~hmac=...`; `GaanaMediaURL.decrypt` refuses hosts outside `akamaized.net`, `gaana.com` and `gaanacdn.com`. `GaanaMediaURL.encrypt` exists for tests only. Decrypted URLs live in the resolver's memory cache and are never persisted; the library keeps `gaana:<id>` and metadata.

## Quality tiers

Gaana's web payload names `medium` (64 kbps), `high` (128 kbps) and `auto` (an adaptive ladder of 16, 64 and 128 kbps that the app does not select); `track_format.mp4_aac.extreme` is flagged but has no URL for a signed-out request, and the web player treats `extreme` as unavailable. The community claim of 320 kbps was not observed. Selection under `AudioQualityPreference.maximumBitRate`: Best (nil) and Balanced (160 000) try `high` then `medium`; Data saver (64 000) tries `medium`. The first tier whose master playlist answers wins. Observed for "Tum Hi Ho" (944286): the 128 master lists one variant `AVERAGE-BANDWIDTH=183195, CODECS="mp4a.40.2"`, 44 segments of 6 s (261 s), `segment-0.ts` 145 512 bytes `video/MP2T` with `Accept-Ranges: bytes`; `ffprobe` reports AAC-LC 44.1 kHz stereo at 133 kb/s inside a 193 kb/s transport stream. The 64 master lists `AVERAGE-BANDWIDTH=129733`. "Reload best available audio" re-resolves with a fresh details call. The player's More sheet shows the tier as source metadata; a fallback stream shows its own tier (320 kbps AAC for a JioSaavn copy).

## APIs

| Type | Contract |
| --- | --- |
| `GaanaTransport` (actor) | `get(_ url:ttl:forceRefresh:cacheIf:) -> GaanaResponse`; static `searchURL(query:include:startIndex:)`, `apiURL(path:parameters:streamFields:)`, `decode(_:)`, `failureMessage(_:)`, `clientHeaders`; `APIFailure(message)` for the provider's `status: 0` envelope |
| `GaanaParser` | `search(_:filter:)`, `searchTrack`, `searchCollection`, `song`, `songs`, `songDetails`, `albumPage`, `playlistPage`, `artistPage(_:albums:similar:id:)`, `entityTracks`, `entityTrack`, `entityAlbum`, `entityArtist`, `artistCredits`; `GaanaText.clean/identifier/artwork/language/flag/playCount/lufs/expiry` |
| `GaanaSong` | `track`, `seokey`, `urls: [Tier: EncryptedURL(message, expiresAt)]`, `isRestricted`, `isPremium`, `integratedLoudness` |
| `GaanaMediaURL` | `decrypt`, `encrypt(_:iv:filler:)`, `key`, `isMediaHost`, `Tier` (`high`, `medium`, `bitRate`, `quality`), `candidates(available:maximumBitRate:)` |
| `GaanaCatalogService` (actor) | `MusicCatalogProviding`, `AlbumDescriptionProviding` (nil); `songDetails(providerID:forceRefresh:) -> GaanaSong?`; `discovery` returns `[]`; foreign ids answer empty (`browse`, `radio`) or unavailable (`artist`) |
| `GaanaStreamResolver` (actor) | `StreamResolving`; `init(catalog:fallbacks:quality:probe:now:cacheCapacity:)`, `setAudioQualityPreference`, static `probePlaylist`, `maximumLifetime` 4 h, `loudnessReference` -14; joins concurrent resolutions of one song |
| `CrossSourceStreamFallback` (protocol) | `source`, `resolve(matching:forceRefresh:) -> ResolvedStream?`; `JioSaavnStreamFallback(catalog:resolver:)`, `YouTubeStreamFallback(catalog:resolver:)`; `CrossSourceMatch.query(for:)`, `best(_:for:)`, `durationTolerance` 3 s |
| `CompositeStreamResolver` (struct) | `init(youTube:saavn:gaana:audioCache:isOffline:)`; prefixed ids check the shared cache first, `download` stores single-file streams and refuses playlists (`isCacheable`), `discardCached` and `isCachedStream` cover prefixed keys, `setNetworkOffline` mirrors the player's flag for prefixed sources |
| `YouTubeStreamResolver` | `resolve` and `download` throw `invalidID` for any id whose `track.source` is not YouTube Music, even when the cache's shape check accepts it |
| `CompositeCatalog` | Unchanged; `MusicAppModel.ProductionSources` builds one `YouTubeMusicService`, `JioSaavnCatalogService` and `GaanaCatalogService` shared by `makeProductionCatalog` and `makeProductionResolver` |
| `TrackRow` | `track.source.<id>` caption2 badge; `showsSourceBadge` gate |
| `CatalogSourcesSettingsView` | `settings.sources.gaana` enabled; detail "Search, albums, artists and playlists, streams up to 128 kbps" |
| Debug | `--gaana-fixture` (with `--uitesting --seed-ui`) installs `DebugGaanaFixtureCatalog`: one song and one album for "tum", `gaana:944286`, `gaana:album:92317`; playback uses the existing fixture waveform through `DebugMusicFixtures.resolve`; combinable with `--saavn-fixture` |

## Metrics

All OSLog, subsystem `com.agraabhi.ganabajana`, category `Gaana` unless noted; values are counts or bounded enums, never queries, ids or URLs.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=request status=ok bytes=<n>` | A 2xx response is received | bytes count | Confirms the endpoints still answer and shows body sizes against the 4 MiB cap (playlists reach 400 KB) |
| `event=request status=rateLimited` | HTTP 429 | none | Detects provider throttling before users report empty sections |
| `event=request status=failed code=<n>` / `reason=network\|tooLarge` | 5xx after retry, 401/403, other status, transport error, oversized body | HTTP code, reason enum | Separates provider refusals from connectivity and cap hits |
| `event=api_failure path=<path> length=<n>` | The provider's `status: 0` envelope | request path (fixed set), message length | Removed songs are expected; a failing search or artist list means an API change |
| `event=search filter=<f> tracks=<n> collections=<n>` | A search page parsed | filter enum, counts | Shows whether a filter returns rows, without the query |
| `event=browse kind=album\|playlist tracks=<n>` | Album or playlist page parsed | kind, count | Detects the provider trimming playlists further |
| `event=artist topSongs=<n> releases=<n> related=<n>` | Artist page parsed | counts | Detects an empty artist payload for a valid id |
| `event=radio tracks=<n>` | Artist-tracks radio parsed (0 when no credit carries a Gaana artist id) | count | Zero over time means the artist tracks endpoint stopped answering |
| `event=resolve status=ok quality=high\|medium` | A master playlist probe succeeded | tier | Which tiers the CDN actually serves under each preference |
| `event=tier_unavailable quality=<tier> reason=expired\|decrypt\|probe` | A tier was skipped | tier, reason enum | Detects a key change (decrypt), stale details cache (expired) or CDN token failures (probe) |
| `event=resolve status=failed reason=missing\|restricted\|noMedia\|noTier` | Gaana itself gave up; the fallbacks are asked next | reason enum | Distinguishes a removed song from restrictions and from a URL scheme change |
| `event=fallback source=saavn\|youtube status=ok\|miss\|failed` | A cross-source lookup finished | source, outcome enum | Shows how often Gaana songs actually play from another catalog |
| `event=stream_cache_hit quality=<tier>\|fallback` | Cached URL reused | tier or fallback | Cache effectiveness within the expiry window |
| `event=prefetch_unavailable` | A prefetch resolution failed | none | Warm-up failures are expected to be rare |
| `event=composite_search sources=<n> ok=<n> failed=<n>` (category `Catalog`) | A fanned-out search finished | counts (sources now up to 3) | Shows how often a secondary source drops out of a search |
| `event=cache_skipped source=gaana reason=hls` (category `StreamResolver`) | A Gaana HLS stream reached `download` | source enum, reason | Confirms HLS songs are the ones streaming without a copy |
| `event=audio_cached source=saavn\|gaana bytes=<n>` (category `StreamResolver`) | A prefixed song was stored in the shared cache | source enum, bytes | Volume of cross-source copies entering the cache |
| `event=audio_cache_lookup source=<s> hit=0\|1` (category `StreamResolver`) | The composite checked the cache for a prefixed song | source, flag | Offline hit rate for prefixed songs |

## Test coverage

Unit: `Tests/GaanaTests.swift` (21 cases, 1 opt-in live) and `Tests/CompositeCatalogTests.swift` (15 cases, 4 new and 1 extended). Fixtures in `Tests/Fixtures/gaana-*.json` are trimmed live recordings (public catalog rows, no account data). UI: `UITests/GanaBajanaGaanaUITests.swift` (2 cases) on the fixture provider.

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `testAESRoundTripDecryptsAKnownURL` | encrypt then decrypt with the web player key, digit position and filler | Unit |
| `testRecordedMessageDecryptsToTheObservedHLSMaster` | live `urls.high` message to the observed Akamai master URL | Unit |
| `testDecryptionRejectsGarbageAndForeignHosts` | bad format, bad Base64, short block, non-media host, short IV | Unit |
| `testQualityCeilingSelectsTiers` | Best / Balanced / Data saver candidates, ceiling under every tier, `SourceAudioQuality` | Unit |
| `testTextHelpersResizeArtworkAndParseCounts` | `size_l` rewrite, https upgrade, identifier limits, `popularity`, LUFS, expiry, language, flags | Unit |
| `testSongSearchRowsMapOntoTracks` | track rows, name-only credits, no duration, share URL, mixed groups | Unit |
| `testAlbumArtistAndPlaylistSearchRowsMapOntoCollections` | album, artist and playlist rows | Unit |
| `testSongDetailsKeepEncryptedURLsCreditsAndLoudness` | `song_detail` media fields, credits with ids, restriction and premium flags, missing envelope | Unit |
| `testAlbumPageCarriesHeaderCreditsAndSongs` | `album/detail`, missing album | Unit |
| `testPlaylistPageListsTheProviderSelection` | `playlist/detail` | Unit |
| `testArtistPageCollectsTopSongsAlbumsAndSimilarArtists` | header, `entity_info` pairs, albums, similar artists, missing artist | Unit |
| `testArtistTrackEntitiesMapForRadio` | `/home/artist/tracks` entities | Unit |
| `testSearchSendsTheWebPlayerHeadersAndCachesForAMinute` | request URL, identity headers, 60 s cache, continuation pass-through, album filter | Integration (mock session) |
| `testBrowseArtistAndRadioRouteByPrefixedIdentity` | album and playlist by id, three artist calls and their cache, track browse, foreign ids, wrong kind, removed album, missing song, radio through the details lookup, language filter | Integration (mock session) |
| `testRateLimitingAndEmptyBodiesAreRefusedWithoutARetry` | 429 with `Retry-After`, empty search body | Integration (mock session) |
| `testResolverPicksTheTierUnderEachPreference` | tier per preference, stream fields (expiry, loudness, plays), one probe, URL cache | Integration (mock session, stub probe) |
| `testResolverFallsToTheLowerTierRefusesBareIdsAndDropsExpiredURLs` | probe failure, ceiling change, bare and `saavn:` ids, expired `expiryTime` | Integration (mock session, stub probe) |
| `testResolverFallsBackToJioSaavnThenYouTubeInOrder` | missing song, restricted song, failing source skipped, order, duration carried, nothing matches | Integration (mock session, stub fallbacks) |
| `testCrossSourceMatchRequiresTitleArtistAndDuration` | remix, long version, cover, video row, no duration, no artist | Unit |
| `testPrefixedIdentityHelpersForGaana` | collection ids, entity kinds, cache key, share URL escaping | Unit |
| `testLiveSearchResolvesAStreamOrFallback` | real search, resolve, GET of the stream (`GANABAJANA_GAANA_LIVE=1`) | Live, opt-in |
| `testThreeSourcesFanOutInMusicSourceOrderAndAFailingOneIsDropped` | merged order for three sources, a failing and a slow source dropped alone, enabled list | Unit (stubs) |
| `testGaanaIdsRouteToTheGaanaCatalog` | browse, artist, radio, recommendations, lyrics, description; real service answers lyrics unavailable | Unit (stubs) plus mock session |
| `testCompositeResolverRoutesByPrefixAndKeepsCacheWithYouTube` | saavn and gaana routing, `isCacheable`, quality forwarding, gaana refresh, no YouTube extraction | Integration (mock sessions) |
| `testJioSaavnDownloadsLandInTheSharedCacheAndPlayOffline` | R12 follow-up: `download(saavn:)` stores `saavn~<id>`, inventory lists it playable, second download reuses it, offline resolve and `PlayerController` play the file, uncached song fails offline, direct YouTube calls throw `invalidID` | Integration (fixture cache, mock sessions, player) |
| `testGaanaHLSStreamsSkipTheCacheWhileFallbackFilesAreStored` | HLS refused without a transfer; fallback file stored under the `gaana:` id | Integration (fixture cache) |
| `testSearchShowsAGaanaSectionWithBadgedRowsAndPlaysTheSong` | three-way sections, badge only on the Gaana row, per-source filters, Gaana album page, playback and player title | UI |
| `testCatalogSourcesSettingHidesTheGaanaSection` | Gaana switchable, off hides the section and leaves JioSaavn on, on restores it | UI |
| `GanaBajanaCatalogSourcesUITests` (JioSaavn, updated: Gaana switchable) and `GanaBajanaDownloadsUITests` | Regression on the shared surfaces | UI |
| Existing `JioSaavnTests`, `StreamResolverTests`, `OfflinePlaybackTests`, `DownloadsTests`, `TrackRowAccessibilityTests`, `CollectionPresentationTests` | YouTube and JioSaavn paths unchanged | Regression |

## Not verified

- Physical-device playback of a Gaana HLS stream, background audio and AirPlay with HLS; the live check fetched playlists and segments from the Mac and the simulator unit host only.
- Gapless and crossfade across an HLS item and a file item: AVQueuePlayer-style transitions were not exercised with mixed sources.
- The equalizer bypass on HLS items is expected from AVFoundation's documented limits (`AVAudioMix` is unsupported for HTTP Live Streaming) and the tap's `noAudioTrack` path; it was not captured on a device.
- Restricted or premium-only songs: every sampled song carried `rest_lev: "0"` and full `urls` despite `is_premium: 1`; the restriction and fallback paths are exercised with edited fixtures and stubbed fallbacks.
- Provider rate limits and `Retry-After` were not observed live; handling is tested with a mocked session. Whether Gaana blocks the identity headers for non-browser traffic over time is unknown.
- Loudness mapping assumes Gaana's `integrated` LUFS is comparable to YouTube's loudness reference; no side-by-side level measurement was made.
- Playlist paging: the provider returned 98 of 130 songs in one response without a documented page parameter; longer playlists are truncated at what it lists.
- Gaana's terms: the API is unofficial and undocumented; use is the owner's accepted local-only risk (`docs/ROADMAP.md`).
- Downloads of Gaana's own HLS streams (would need an HLS-to-file path or `AVAssetDownloadURLSession`); only fallback files are stored.
