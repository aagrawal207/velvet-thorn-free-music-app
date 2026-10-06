# Live Radio

## R18 WP22 Status

R18 implements and integrates Radio Browser discovery, device-local station favorites and a distinct live mode through `PlayerController`'s existing AVPlayer. Search, model selection, mini-player, full player and failure banners use that mode.

Verification is in progress. The coordinator reports passing Core-02, Live-Radio-03 and phone UI-01 scopes, including public KCRW playback and light/dark radio UI. [VERIFICATION.md](VERIFICATION.md) owns counts and run boundaries; its R18 record is being updated. Historical failures below retain their original evidence. Physical audio AirPlay remains the owner report in [AIRPLAY.md](AIRPLAY.md), not new radio device acceptance.

## Directory API and Research

The implementation follows the public [Radio Browser API reference](https://docs.radio-browser.info/), particularly [advanced station search](https://docs.radio-browser.info/#advanced-station-search), [station fields](https://docs.radio-browser.info/#station), and [server mirrors](https://docs.radio-browser.info/#server-mirrors).

Requests are HTTPS GETs with `User-Agent: Breezy/1.0` and `Accept: application/json`:

- `/json/servers` returns mirror hostnames. The URLSession transport uses this documented alternative to forward/reverse DNS discovery. Returned IP addresses are ignored. Hostnames must be a single label under `.api.radio-browser.info`.
- `/json/stations/search` accepts `name`, two-letter `countrycode`, `language` with `languageExact=true`, and comma-separated `tagList`. All supplied tags must match. Fixed parameters are `limit=100`, `hidebroken=true`, `is_https=true`, `order=votes`, and `reverse=true`.
- The parser uses `stationuuid`, `name`, `url_resolved`, optional `homepage`/`favicon`, `countrycode`, `language`, `tags`, `codec`, `hls`, and `lastcheckok`. `url_resolved` is the directory’s resolved public stream, including HLS playlists. A station’s votes or click counts are not song plays.
- “Find NPR Stations” searches the `npr` tag in `US`. This finds tagged affiliates even when NPR is absent from the station name. A call-sign/name search remains available for untagged affiliates. Directory tags do not certify affiliation or the language of each broadcast.

Read-only probes on 27 September 2026 established that `https://de1.api.radio-browser.info/json/servers` returned IPv4 and IPv6 rows for one distinct hostname, `de1.api.radio-browser.info`, and that `/json/stations/search?name=NPR&hidebroken=true&limit=3` returned three AZPM NPR entries with HTTPS AAC/AAC+ streams. These responses establish the directory schema, not audible playback. The generic `https://api.radio-browser.info/json/servers` returned 404 and is not a bootstrap endpoint. The documented `de1` and `nl1` hosts are bootstrap candidates; `nl1` availability was not established by this probe. If only one mirror is available, failover can still fail.

The API recommends reporting station clicks. This integration deliberately omits that write. It has no click-counter, vote, station-registration, or account endpoint.

## Source Contracts

| Source | Contract |
|---|---|
| `Sources/Core/LiveRadioStation.swift` | `LiveRadioStation` is immutable, Codable station metadata with UUID identity and a public `streamingURL`. It is not a `Track`, `MusicSource`, or `SearchSelection`. `LiveRadioURLPolicy` is independent of music-provider media validation. |
| `Sources/Radio/LiveRadioDirectory.swift` | `LiveRadioDirectoryProviding.search(_:) async throws -> [LiveRadioStation]`; `LiveRadioFilter(name:countryCode:language:tags:)` owns encoded filters and `.npr`. `LiveRadioDirectory(isEnabled:transport:)` supports injected read-only transport; disabling it makes no requests. |
| `Sources/Radio/LiveRadioHTTP.swift` | Isolated ephemeral HTTPS sessions, bounded probes, redirect rules, and `LiveRadioResolving.resolve(_:)`. `LiveRadioConnection(station:streamingURL:sourceProof:)` carries public station metadata, an ephemeral redirect target, and unverified/HLS/elementary evidence. Omitted evidence defaults to unverified. |
| `Sources/Radio/LiveRadioElementaryProof.swift` | URL-bound, non-Codable proof of two complete consecutive MP3 or ADTS frames. Its private initializer is reached only through byte/header validation. |
| `Sources/Radio/LiveRadioNativeValidation.swift` | Requires a permitted URL, native playability, and successful native video exclusion. Empty static audio tracks require matching elementary proof; HLS and unverified connections require native audio tracks. |
| `Sources/Radio/LiveRadioFavorites.swift` | `LiveRadioFavorites(url:)` loads immediately. `stations`, `contains(_:)`, `toggle(_:) -> Bool`, `reload()`, `errorMessage`, and `requiresReload` expose durable state and recovery. `url: nil` is explicitly memory-only. |
| `Sources/Radio/LiveRadioBrowser.swift` | `LiveRadioBrowser(directory:favorites:)` owns bounded results, loading/error state, and a search generation. `search(_:isOffline:)` rejects stale completion; SwiftUI’s task owns cancellation. `cancelSearch()` retires publication. |
| `Sources/Views/LiveRadioView.swift` | `LiveRadioView(browser:player:isOffline:onSelect:)` supplies discovery, filters, favorites, and NPR discovery. `LiveRadioMiniPlayer(player:onOpen:)` supplies a 64-point capsule with 44-point station symbol and 52-point play/stop controls. |
| `Sources/Playback/PlayerController.swift` | `playLiveRadio(_:) -> Bool`, `stopLiveRadio()`, `stopPlayback()`, `liveStation`, `isLiveRadio`, `hasPlaybackSelection`, and display projections. Existing pause/resume/retry, system interruptions, route detach, and sleep timers dispatch to the live mode. |
| `Sources/Playback/PlaybackSystemControls.swift` | Live Now Playing metadata and native play/pause/toggle/stop registration. `performTransport(_:owner:)` is the same dispatch used by the native command closures and tests. |
| `Sources/Views/NowPlayingView.swift` | `NowPlayingView(liveRadioFavorites:)`, with an optional store injection, shows a station title/status, station favorite, play/pause, native AirPlay, Sleep Timer, and Return to Music. |

Station artwork uses a radio symbol in this iteration. Valid directory artwork URLs can be retained as station metadata, but no station artwork fetch is issued. `displayArtworkURL` is nil in live mode, preventing an old song image from appearing. Song artwork behavior is unchanged.

## Playback and Persistence

An accepted station selection pauses the song first, flushes its listening checkpoint, and captures its exact queue occurrence and position. It then retires song extraction, prefetch, transition, and autoplay work, empties the standby item, and connects through the existing active AVPlayer. No second radio player is allocated. `PlaybackAudioRoute.makePlayer()` continues to set `allowsExternalPlayback=false`, including media-services resets; session configuration remains `.playback` with `.longFormAudio`.

While live:

- `currentTrack` is nil. `queue` and `currentIndex` expose the retained music queue, while `position` and `duration` are zero. The queue is preserved for restoration, not presented as a station playlist.
- Seek, Next, Previous, shuffle/repeat changes, queue edits, prefetch, and autoplay insertion do not change live playback. There is no station lyric, download, export, cache entry, play count, or song favorite.
- No `onTrackStarted`, station `ListeningEvent`, or station recent is created. Pending song deltas can still be delivered. Both synchronous snapshots and asynchronous checkpoint snapshots use the saved music queue and its original position; no station or redirect URL enters the library snapshot.
- Pause drops the native item and cancels connection/retry work. Resume reconnects to the current broadcast rather than seeking into buffered audio. Native Stop and Return to Music clear live selection and restore the music queue paused.
- Selecting a normal queue with `play`, `playShuffled`, or `restore` clears live selection and handles. Connection completion, asset loading, readiness callbacks, and retry delays all check the existing playback generation. A late result cannot replace a newer station or song.
- Interruptions cancel active live connection work and preserve the interruption’s resume decision. Explicit Pause cancels that decision. Route loss and the sleep timer pause the stream. Reconnection after a known-offline failure does not autoplay.

The lock screen receives a newly constructed dictionary with station title, “Live Radio”, audio media type, playback rate, and `MPNowPlayingInfoPropertyIsLiveStream=true`. Song artwork work is canceled; album, duration, elapsed position, queue indices, and recording identifiers are omitted. Native Next, Previous, and position commands are disabled. Returning to music replaces the dictionary with normal song metadata.

Favorites are stored at `Application Support/GanaBajana/live-radio-favorites.json`, version 1. Up to 200 validated stations are stored in a separate file, with no iCloud journal or account dependency. Redirect targets are not written: saving the currently playing station retains the public directory entry. Reads are capped at 2 MiB, including a one-byte overflow check. Writes validate the complete document, compare current disk bytes with the loaded baseline, and use atomic replacement with protection until first unlock. Observable favorites change only after a successful write. Missing files start empty; corrupt, oversized, future-version, duplicate-ID, or invalid-URL documents block writes and retain the file. Externally changed bytes require explicit Reload before another edit. A full store rejects a new favorite without evicting an existing one. Device backups may contain this file.

## Network and Codec Bounds

| Operation | Bound |
|---|---|
| Directory request | 8-second request timeout; 12-second absolute deadline; 1 MiB received-body cap; at most 100 response rows |
| Mirror discovery | At most two bootstrap calls per discovery; 32 KiB and 64 mirror rows; eight distinct valid names retained for one hour in memory |
| Directory failover | At most three distinct search hosts after discovery; two active searches; at least 250 ms between starts |
| Search UI | 350-ms cancellable debounce; no pagination or unbounded accumulated results |
| Filter text | Name 128 UTF-8 bytes, language 64, tags 256 with at most five tags, country ISO alpha-2 |
| Station metadata | Name 256 UTF-8 bytes, URL 2,048 bytes, 16 languages and 32 tags of at most 64 bytes each |
| Stream probe | 12-second deadline; at most three HTTPS redirects; up to 8 KiB for direct audio, checked every 512 bytes and stopped once frames are proved; at most 4 KiB for an optional ID3 prefix; sync-word search within the first 4 KiB; 64 KiB/1,024 lines for the initial HLS playlist; affected task canceled after inspection |
| Station health check | Every directory result is probed before it is listed, six at a time; a verdict is reused for 30 minutes; failed stations are hidden and counted in the list footer |
| Live connection | Resolver deadline 15 seconds, native asset/audio-track check 15 seconds, item readiness 20 seconds |
| Recovery | Two automatic retries after the first attempt, delayed one and two seconds; 20-second stalled-playhead threshold; 60 seconds of playback after a connection is ready refunds the retry budget; explicit Retry/Resume starts a fresh bounded attempt cycle |

URL validation requires HTTPS, a syntactically valid public-style DNS hostname, a valid port, and no embedded user/password or fragment. Literal IP addresses, local/private-name suffixes, file URLs, and other schemes are rejected. This is hostname validation, not DNS pinning. Directory redirects are refused. Stream probe redirects repeat validation and rebuild the request without inherited cookies, authorization, or referrer headers. Sessions have no cookie store, credential store, or URL cache; non-TLS authentication challenges are canceled. TLS trust uses system validation. No ATS exception is added.

Supported directory codecs are MP3, AAC, AAC+, HE-AAC, and HE-AACV2. The probe requires an HLS type, an MP3 type (`audio/mpeg`, `audio/mp3`, `audio/mpeg3`, `audio/x-mpeg`, `audio/x-mp3`, `audio/mpg`), an AAC type (`audio/aac`, `audio/aacp`, `audio/x-aac`, `audio/x-aacp`), or `application/octet-stream` for a station whose directory codec is MP3 or AAC. Direct audio additionally requires consecutive complete elementary frames whose headers agree on version/sample rate/channel configuration: two at the response boundary (optionally after one ID3 tag), or three from the first sync word within 4 KiB when the server joins mid-frame. The bytes decide MP3 versus ADTS, so a mislabelled AAC stream still passes on its frames. Responses that start as a container or web page (Ogg, RIFF, FLAC, MP4, MPEG-TS/PS, `<`) never pass. MIME alone is not proof. The initial HLS playlist validates referenced URLs, including key/media URIs, and rejects advertised video variants. AVFoundation must report a playable asset and no video tracks before installation. A nonempty native audio-track list supplies audio evidence. An empty list is accepted only with a proof bound to the exact native asset/probed URL: a direct elementary proof, or the validated audio-only HLS playlist, whose tracks AVFoundation exposes on the player item rather than the asset. Errors reading native tracks still propagate. Repeated `CODECS` attributes in an HLS variant (All India Radio publishes them) are merged and each list is checked for video codecs. Native HTTP Live Streaming (HLS) refreshes, nested playlists, and segments remain AVFoundation-owned and subject to normal platform transport policy; the app’s byte cap describes its probe, not the full broadcast. A five-second preferred forward buffer is a hint, not a hard byte limit. No broadcast file is downloaded or published by the app.

Directory requests contain explicit search/filter text and the fixed app User-Agent. Broadcasters receive the selected public URL and the listener’s network address. No music account cookies, library IDs, listening history, learned language/genre profiles, or favorite list is added to those requests. Station tags never become recording-language evidence. The existing hardcoded validation for normal song media is not broadened.

## Integrated App APIs

`MusicAppModel.liveRadio` retains one `LiveRadioBrowser`, with optional initializer injection. Production enables the directory and uses `LiveRadioFavorites.defaultURL()`; unit/UI hosts default to a disabled directory and memory-only favorites. Fixture playback injects `PlayerController(liveRadioResolver:)` because its default resolver contacts broadcasters.

`MusicAppModel.playLiveRadio(_:) -> Bool` rejects known-offline selection, cancels pending artist/widget work, ends experience radio, retires autoplay, dismisses the Search keyboard and cancels warmups before synchronous player selection. Acceptance clears `needsInitialPlaybackRestore`. It does not record a song Search selection or present the full player. Normal song selection retires live mode, and lyrics observation clears the phone/TV song selection when `currentTrack` becomes nil.

Search's `search.liveRadio.open` navigation link presents `LiveRadioView` with the shared browser/player and model selection action. Experience radio remains its own destination. Favorites are browsable offline with Play disabled. The browser attributes the directory through **Directory by Radio Browser**.

`RootView` passes `model.liveRadio.favorites` into `NowPlayingView`. `MiniPlayerNavigationLayout` selects `LiveRadioMiniPlayer` before the song branch and opens the full player only on a tap. `PlaybackFailureFeedback.message(for:)` returns live errors before its normal-song guard. No synthetic `Track` is needed for presentation.

The app and unit target include the source through their recursive directory membership. Watch/widget song projections see no current recording while live. Native media commands, including CarPlay's system Now Playing controls, use the shared live-aware player. Station-specific companion browsing is not implemented. Station favorites are independent of account sign-out, recording-history clearing and iCloud settings.

## Accessibility Selectors

| Area | Selectors |
|---|---|
| Search entry | `search.liveRadio.open` |
| Directory | `liveRadio.screen`, `.search`, `.favorites`, `.country`, `.language`, `.tags`, `.clearFilters`, `.npr`, `.loading`, `.retry`, `.empty`, `.favorites.reload` |
| Station rows | `liveRadio.station.<lowercase-UUID>`, `liveRadio.favorite.<lowercase-UUID>` |
| Full player | Existing `player.presentation`, `player.close`, `player.playPause`, `player.retry`, native `player.airplay.anchor`; new `player.live`, `.live.title`, `.live.status`, `.live.favorite`, `.live.sleep`, `.live.stop` |
| Mini-player | Existing `miniPlayer.container`, `.open`, `.playPause`; new `.live.status`, `.live.stop`; no `.next` or progress |

## Metrics

Metrics follow the app’s OSLog event convention. There is no new analytics endpoint.

| Event | Emitted When | Bounded Fields |
|---|---|---|
| `live_radio_directory` | A search-host attempt succeeds or fails | `outcome=success/failure`, attempt 1–3, result count 0–100 |
| `live_radio_discovery` | Mirror discovery succeeds or falls back | `outcome=success/fallback`, count 0–8 |
| `live_radio_connection` | Native item is ready, a retry is scheduled, or retries end | `outcome=ready/retry/exhausted`, attempt 1–3 |
| `live_radio_validation` | Probe response/MIME/body/playlist/elementary frames, resolved URL, or native playable/audio/video/elementary fallback checks | Fixed `stage` enum, including `probe_elementary` and `native_elementary`; `outcome=began/passed/rejected/failed/cancelled`; no station or error strings |
| `live_radio_mode` | Explicit station selection or Return to Music/Stop | `mode=live/music` |
| `live_radio_favorites` | Load preservation, durable edit, or failed edit | `operation=load/write`, `outcome=success/preserved`, count 0–200 |

Existing `playback_failed`, interruption, route, sleep-timer, and listening-checkpoint events cover shared control paths. None of these events includes station UUIDs, names, URLs, search strings, tags, language names, or account identifiers. Normal-song selection exits live through the shared selection path rather than emitting an additional `live_radio_mode` event.

## Test Coverage

| Suite | Cases | Level |
|---|---|---|
| `LiveRadioDirectoryTests` | Documented schema; station identity distinct from song statistics; metadata/row/body bounds; duplicate IDs; invalid/private/HTTP/credential URLs; audio-only codec filtering; query encoding; NPR tag filter; mirror validation; bounded failover and exhaustion; HLS attribute parsing, URI false positives, actual video declarations, malformed/duplicate attributes and attribute limits; cookie-free configuration; redirect privacy and limits | Unit |
| `LiveRadioFavoritesTests` | Durable save/remove/reload; missing file and missing parent; non-directory parent preservation; external deletion requiring reload; corrupt/future/missing-version preservation; external-change conflict; capacity without eviction; invalid stored URLs and oversize; saved song preferences unchanged | Unit with isolated file persistence |
| `LiveRadioBrowserTests` | Out-of-order and canceled search completion; offline search sends no request and retains favorites | Unit |
| `LiveRadioPlaybackTests` | Shared AVPlayer identity; nil recording in live mode; paused duplicate-queue restoration; snapshot privacy; no station listening/start callbacks; no song resolver calls for stations; canceled station/song resolution; native command dispatch and live metadata; retry exhaustion; interruption, route, reset, sleep and offline behavior | Unit/component with gated resolvers and native command-center metadata |
| `LiveRadioElementaryProofTests` | Complete consecutive MP3/ADTS headers, MPEG versions and VBR, CRC-header sizes, bounded ID3/footer, truncation/malformed fields, MIME mismatch, container/video masquerading, size bounds, exact URL binding | Unit; structural frame fixtures, not decoded audio |
| `LiveRadioNativeValidationTests` | Native positive/rejected predicates; proof-gated empty audio tracks; HLS/unverified/mismatched-URL rejection; actual video/non-playable rejection even with proof; preservation of native inspection failures; cancellation | Unit; not native decoding evidence |
| `LiveRadioIntegrationTests` | Production NPR discovery/KCRW playback with sustained playing, shared ownership, no song callbacks and pause teardown; fixed KCRW strict-asset versus elementary-proof native comparison | Opt-in public integration; `BREEZY_LIVE_RADIO_TESTS=1`; coordinator-reported Live-Radio-03 coverage |
| `R18IntegrationTests` | Model live selection retires pending generated radio; a new music selection rejects late live connection; durable station favorites remain separate from song likes | Local model/component integration with injected providers |
| `GanaBajanaR18UITests.testDirectoryNPRFavoritesLiveSurfacesAndPausedMusicRestorationInLightAndDark` | Search, NPR filter, favorites, mini/full-player and paused music restoration in both appearances | Fixture UI integration; coordinator-reported phone UI-01 coverage |

`BoundedURLSession` is reused for directory reception and already owns chunked/missing-length overflow behavior. OSLog emission itself is not asserted by the new tests. Native button delivery from lock screen/headset/CarPlay, audible HLS/direct MP3/AAC radio, prolonged background playback, physical AirPlay and interruption recovery remain device checks. Phone, SE and iPad light/dark workflows passed; broader Dynamic Type remains unverified. The public tests establish native KCRW playback in their recorded runs, not audible hardware output or continuing broadcaster availability, and are not run by default. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts.

### Historical First-Write Failure and Correction

The coordinator's `artifacts/R18/Core-01.log` shows `operation=load outcome=preserved` before the first favorite toggle in the three failing favorites cases and the NPR/favorites integration case. The original catch accepted only Cocoa's read-specific missing-file code 260. `FileHandle` can also report Cocoa 4 or POSIX `ENOENT` (2), leaving a genuinely new store incorrectly write-blocked. The later `Data(contentsOf:)` failure in the log reports 260; the initial FileHandle error code was not logged.

The source correction uses a private `LiveRadioFavorites.isMissingFile(_:)` classifier for file-open failures only. It accepts Cocoa 4/260 and POSIX ENOENT, and checks only a missing-file wrapper's immediate underlying error. Wrapped permission, non-directory, and I/O failures are rejected without recursively searching for a missing-file error. The radio store has no dependency on the Moments persistence class. Read failures after opening still propagate. A missing file supplies a nil baseline; an externally deleted previously loaded file therefore still fails the baseline comparison instead of being recreated. Directory creation remains after the baseline check, and atomic persistence and publication-after-durability are unchanged. Existing assertions were retained, with added cases for missing parents, external deletion, and a non-directory parent. The original worker did not run the correction; the coordinator's later Core-02 passing scope supersedes that pending execution status. Existing bounded favorites events cover these paths; no metric fields were added.

### Historical Native Positive-Path Investigation

The direct-audio probe does not wait for EOF: it stops on consecutive-frame proof or its 8 KiB limit and cancels the request. A live HLS broadcast normally returns a finite playlist response, which is read to EOF within the 64 KiB/12-second limits. The subsequent native asset open is a separate request with its own 15-second metadata deadline. Live-Radio-02 established that continuous KCRW MP3 has native item audio tracks but an empty static asset audio list. The proof-gated correction below addresses that case. Probe success alone cannot establish native playback.

`LiveRadioHTTP.swift` uses a quote-aware, single-pass attribute parser inside the existing 64 KiB/1,024-line playlist bounds. Each attribute list is limited to 64 unique names, each at most 64 ASCII characters. Video rejection checks actual RESOLUTION, TYPE=VIDEO, and CODECS values, plus the I-frame stream/only tags. Codec families are matched as comma-separated identifiers before their profile suffixes. Text inside key/media URIs, names, and group IDs cannot become a video declaration. URI and SERVER-URI attributes still require quoted, nonempty, public HTTPS references; malformed quoting and duplicate attributes fail closed. The added unit cases cover those boundaries and the audio URI false positives. The original worker did not run this parser correction, which did not change PlayerController guards. Later coordinator scopes are recorded above and in VERIFICATION. Existing bounded connection failure events cover rejected playlists; no metric fields were added.

The earlier investigation proposed an optional main-actor native-item preparation protocol for deterministic positive component coverage. It would accept an already validated public HTTPS URL and return a prepared AVPlayerItem, retaining native playable/audio-only checks, deadlines and cancellation in production. A test implementation could map that URL to a local audio fixture after validation, without permitting file URLs at selection or resolver boundaries. URLProtocol can mock the URLSession probe but should not be assumed to intercept AVFoundation's own requests. This proposal is not an unfinished R18 integration hook. Such a fake would establish component wiring only; the later Live-Radio-03 public tests supply the scoped native KCRW evidence below.

### Live-Radio-01 Investigation

The coordinator's `artifacts/R18/Live-Radio-01.log` shows directory success, live selection, then AVFoundation HTTPRequest `-12939` and URLAsset `-12174` messages before the unsupported-station failure. There is no readiness event or retry. The original test did not record its selected station, and the original native guard combined playable, nonempty audio tracks, and empty video tracks into one error. The log cannot identify which predicate failed or retrospectively prove the selected station identity. No public meaning for the two internal status codes was established.

A read-only repeat of the production NPR filter (`countrycode=US`, `tagList=npr`, HTTPS/nonbroken, votes descending) returned KCRW 88.9 FM – Live first, UUID `325a61dc-fe34-48c6-ae82-1467b710f07b`. Its public URL was `https://streams.kcrw.com/kcrw_mp3?aw_0_1st.playerid=radio-browser.info`. A bounded HEAD and 1,024-byte GET with the app User-Agent returned HTTP 200 and `Content-Type: audio/mpeg`; the GET began with bytes `ff fb b0 60` and the directory/header reported MP3 at 192 kbps. The response supplied no Content-Length, Content-Range, or Accept-Ranges, despite a `Range: bytes=0-1023` request. It did not redirect. This establishes accessible streaming bytes on the probing machine, not native iOS playback or an AVFoundation failure cause.

The diagnostic revision separated the original native checks into `native_playable`, `native_audio`, and `native_video` stages. The stream resolver recorded response, MIME, body, and playlist stages. The coordinator then ran that revision as Live-Radio-02, establishing the static-track issue below. The worker did not run those tests.

The diagnostic revision's `testPublicStreamKCRWNativeItemFirstVersusAssetFirst` compared two fresh native opens for the fixed KCRW UUID. Live-Radio-02 retained the failing asset-first result and the failing post-readiness static-asset check. Production logs contain only closed stage/outcome enums. Station names and public directory URLs appear only in the opt-in test diagnostics.

### Live-Radio-02 Root Cause and Elementary-Audio Correction

`artifacts/R18/Live-Radio-02.log` identifies the selected KCRW station and shows probe success, native playability success, and `native_audio=rejected`. The item-first comparison became ready and reported one audio item track, zero video tracks, and zero absent asset-track references, but `asset.loadTracks(withMediaType: .audio)` still returned an empty array. Requiring a static asset audio track incorrectly rejected the continuous MP3 stream. Earlier item installation did not repair that assumption.

The correction adds structural audio evidence to the existing public probe. MPEG Layer III frames require valid MPEG-1/2/2.5 version bits, Layer III, nonreserved bitrate/sample-rate fields, legal emphasis, and sufficient frame/side-information length. Length comes from the version's bitrate/sample-rate formula and padding bit; VBR is allowed between frames. ADTS requires its sync/layer fields, a nonreserved sample-rate index, known channel configuration, valid profile/version combination, one raw-data block, and a complete frame longer than its seven- or nine-byte header. Two complete adjacent frames must agree on format-defining fields. The parser starts at the response boundary or directly after one validated, bounded ID3v2 tag/footer. It does not scan arbitrary container or video payloads for embedded audio sync bytes. Free-format MP3, multi-block/PCE-only ADTS and oversized ID3 tags remain conservatively unsupported by this proof.

`LiveRadioConnection.sourceProof` defaults to `.unverified`; `.hls` records the playlist path, and `.elementary` carries an immutable proof bound to the final URL actually probed. Proofs and redirect targets remain memory-only. The native validator checks playability and video exclusion before the audio decision. An empty audio list is accepted only when the asset URL equals the connection URL and the elementary proof's probed URL, and the station is not HLS. Non-playable assets, actual video, and thrown native inspection failures still fail. No MIME-only or HLS fallback was added. PlayerController passes the resolved connection into this validator inside its existing live connection block; item ownership, loading order, and other playback/provider hooks are unchanged.

The public production-path test keeps the original first-result selection and adds a three-second sustained-playing assertion. The renamed fixed-station comparison, `testPublicStreamKCRWStrictAssetVersusProvenElementary`, records the strict legacy native result without supplying proof, then requires the proof-aware path to validate before item creation, become ready, and advance its native playhead. It retains prior failures explicitly and does not substitute a different station. Synthetic frame tests establish header/boundary behavior only; they do not establish decoded audio.

The coordinator reports that Live-Radio-03 passed after this correction, including the production NPR/KCRW path and fixed-station native comparison. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts. This supersedes the earlier pending KCRW rerun, without changing Live-Radio-01/02 failures. A validated audio-only HLS playlist is now accepted with empty static asset tracks; see Station Health below.

## Station Health

Stations that fail to connect are the broadcaster's problem in a minority of cases and the probe's in the rest, so both are handled. `LiveRadioBrowser` runs `LiveRadioStreamResolver.resolve` for each directory result before listing it (six probes in parallel, verdicts cached for 30 minutes in memory) and lists stations as they pass, in directory order. The list shows "Checking stations…" until the first passes, a progress row while more are checked, and a footer counting hidden stations. Favorites are never probed or hidden. Probing tells a broadcaster the listener's network address, as listening does; the directory footer says so. Unit and UI hosts construct the browser without a verifier.

The opt-in `LiveRadioIntegrationTests.testPublicDirectoryStationAudit` (`BREEZY_LIVE_RADIO_TESTS=1`) takes the landing list, NPR and India results through the probe, native validation and an `AVPlayerItem` until ready. On 29 September 2026 it reached ready for 256 of 275 distinct sampled stations. Seventeen failed the probe (redirects to HTTP, TLS failures, unavailable or timed-out responses, and a video-only HLS feed); two passed the probe but timed out during native validation. Browser health checks hide failed probes, not native-readiness failures. These results are a snapshot of the sampled directory and do not establish that every listed station plays. [VERIFICATION.md](VERIFICATION.md) owns the receipts.

| Event | Fields |
|---|---|
| `live_radio_verification` | `checked`, `failed` (counts, at most 100), `seconds` |
| `live_radio_connection outcome=retry_budget_refunded` | none |
