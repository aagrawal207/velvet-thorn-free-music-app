# Breezy providers and data handling

Breezy contacts external providers directly. There is no Breezy-operated catalog, account, analytics, or music server. The current integration can browse without a provider account or developer API key, but providers can restrict requests. Account-cookie-free requests still disclose network addresses and requested content.

## Distribution and content rights

**App Review submission is on hold.** The owner has confirmed that authorization from YouTube and music rights holders has not been obtained. The current app uses undocumented web endpoints, stream extraction, and complete-song caching; it is not a provider-approved playback integration. A licensed provider/content approach must be selected and reflected in the binary and release assets before submission.

Relevant provider terms are the [YouTube Terms of Service](https://www.youtube.com/static?template=terms) and [YouTube API Services Developer Policies, section III.E.1](https://developers.google.com/youtube/terms/developer-policies#e.-handling-youtube-data-and-content), which restrict downloading/caching audiovisual content without prior written approval and making it available offline. The developer policies also address undocumented APIs and scraping. A public endpoint, successful extraction, a sign-in session, or a software license does not establish content-distribution rights. Calling complete downloads a “temporary cache” does not supply permission.

[RELEASE_STATUS.md](app-store/RELEASE_STATUS.md) owns the release hold. No authorization or content-rights declaration has been prepared as if it were granted.

## Network requests

All recipients see the connection's source IP address and ordinary request metadata. A VPN, relay, or network proxy may affect the address they see. This is the source-level inventory, not a claim about provider retention or tracking practices.

| Recipient | When and what is sent |
| --- | --- |
| `music.youtube.com` | Catalog bootstrap and `/youtubei/v1/search`, `browse`, `next`, and `music/get_queue`: search text/filter, collection or artist IDs, recording IDs, radio seeds, continuation/visitor data when supplied, and client/version/language/region context |
| `charts.youtube.com` | Weekly chart browse requests with chart type, selected region, and provider client context |
| `youtube.com`, `www.youtube.com` | Recording watch/player/embed and extraction resources, including player JavaScript when needed; recording ID, client headers/context, and provider visitor data. The direct path uses VISIONOS client metadata, not the listener's actual device model |
| `*.googlevideo.com` | Signed media requests, including validation/range requests and complete-file cache transfers for the selected recording |
| Provider-supplied artwork URLs | Image requests, commonly `*.ytimg.com`, `*.googleusercontent.com`, and `*.ggpht.com`; paths identify the artwork and may include a recording ID. The loader can also use other URLs returned by the provider |
| `lrclib.net` | `/api/get` and `/api/search` with song title, artist, optional album, and duration for exact matching. Includes the current app-client User-Agent |
| `music.youtube.com` for lyrics | The selected recording ID on `next`, then its linked `MPLY…` lyrics browse ID. LyricFind/Musixmatch attribution comes through this response, with no direct requests to those publishers |
| `musicbrainz.org`, when configured | Official `/ws/2/recording` search with cleaned title, up to three artist names, and a duration range; a matched recording-ID lookup with artist-credit/work relationships. User-Agent includes the configured public contact URL |
| `accounts.google.com` and Google/YouTube sign-in resources, optionally | The Google sign-in web page receives information entered there, cookies, and normal browser request data. Only YouTube-domain session cookies are retained by Breezy after the sheet closes |
| `remote-production.youtubekit.dev`, optionally | Recording ID, app identity when available, and response data from service-directed extraction requests; details below |
| System encrypted DNS or `cloudflare-dns.com/dns-query` | Provider hostname lookups; details below |
| Apple StoreKit services | App/product identification, storefront/product requests, and purchase/transaction processing. Apple manages its service endpoints, account authentication, and payment data |
| `gist.github.com` | User-opened Support and Privacy pages receive ordinary browser request data. Including the Support URL in the MusicBrainz User-Agent does not itself fetch the Gist |

Search requests are debounced while typing. Saving only deliberate searches locally does not mean that partial queries stay on the phone. Home/search prefetch can request music before a play tap. Radio adds genre/mood search text, optional artist hints, and provider-playlist lookups. Artist language checks, release polling, and recommendation seeds also reveal the requested artists or recordings.

FFmpegBridge adds no network recipient. The app downloads Opus through the existing media provider and prepares its container locally; the bridge has network support and nested opens disabled.

### Response limits and cancellation

Catalog, MusicBrainz, fast-path playback lookup, and artwork use [`URLSession.boundedData(for:maximumBytes:)`](../Sources/Networking/BoundedURLSession.swift). It checks both declared length and bytes received, including chunked responses without a known length. An oversized response or cancelled caller stops that request's task without invalidating unrelated requests. HTTP status and payload validation remain caller-owned. Declared length is an upper bound, not an EOF equality check, because the networking stack may decode the response body.

| Receiver | Maximum received body | Production resource budget per request |
| --- | ---: | ---: |
| Catalog/chart transport, including bootstrap | 8 MiB | 35 seconds |
| MusicBrainz metadata | 2 MiB | 6 seconds |
| Direct playback fast path | 4,000,000 bytes | 6 seconds |
| Artwork | 12 MiB | At most 30 seconds |
| LRCLIB's dedicated transport | 2 MiB | 20 seconds |
| Vendored extraction HTML/player | 4,000,000 bytes | 30 seconds |
| Vendored extraction JavaScript | 12,000,000 bytes | 45 seconds |
| Vendored remote extraction responses | 8,000,000 bytes | 45 seconds |

These bounds apply to individual responses; higher-level operations can make several requests within their own budgets. Complete media downloads use separate file-length and native-media validation.

[`ExtractionTransport`](../Vendor/YouTubeKit/Sources/YouTubeKit/ExtractionTransport.swift) uses an ephemeral session without automatic cookies, stored credentials, or a URL cache. It enforces receive-time byte limits and deadlines. Full player extraction uses structured concurrent work; cancellation retires its requests rather than cancelling a shared session.

`ArtworkLoader` coalesces work by URL and requested pixel size. Each consumer has its own cancellation: a remaining consumer keeps the transfer alive, while the last cancellation retires and cancels it. Cache clearing waits for retired transfers before removing cached responses. Its non-renewing deadline prevents a trickle response from continually extending the resource budget.

## Catalog, charts, and personal discovery

[`YouTubeMusicService`](../Sources/Catalog/YouTubeMusicService.swift) uses an ephemeral, account-cookie-free [`CatalogTransport`](../Sources/Catalog/CatalogTransport.swift), without credential storage or a disk response cache. Catalog requests use `WEB_REMIX`, English UI context, and `gl: IN`; chart requests select their own region. Provider visitor/continuation values can still associate requests. Audio rows are preferred and batch-validated; explicit video and podcast rows are excluded.

Home discovery uses Hindi/English preferences and heuristics in [`CatalogDiscovery`](../Sources/Catalog/CatalogDiscovery.swift). The model excludes `editorial-hindi` and `editorial-english` from Home even though the catalog service can fetch those sources. Reordering or hiding Home sections changes presentation, not a provider permission or a guarantee that associated requests stop.

[`YouTubeChartsService`](../Sources/Catalog/YouTubeChartsService.swift) selects weekly `TRACKS` entries from India and the US, with a Global fallback. These are regional chart picks, not certified language-only rankings. The displayed dates are the provider's reporting period, and selected rows retain original ranks. Breezy does not manufacture global monthly/yearly rankings.

Personal recap uses local rolling **7/30/365-day** listening windows. [`ListeningAnalytics`](../Sources/Library/ListeningAnalytics.swift) excludes paused time and seek jumps. `RecommendationEngine` ranks candidates on device using library taste signals; daily/weekly period keys keep generated mixes stable. Candidate fetching still sends artist and seed-recording requests to the provider. Follows and dislikes are local choices, not writes to a YouTube account.

### Release alerts

[`ReleaseWatcher`](../Sources/Recommendations/ReleaseWatcher.swift) checks at most eight due artists per run, with a six-hour catalog-check interval. A successful first read establishes the release baseline, including an empty result; a failed read does not invent a baseline. New-release state and pending notification IDs are saved together before delivery. Pending IDs are bounded by the 60 retained releases and can retry during later checks even when no catalog refresh is due.

Alerts use local iOS notifications after permission. Delivery verifies the current saved library, follow, and alert preference, checks stable identifiers against pending/delivered system notifications, and rechecks eligibility immediately before submission. Accepted notifications are durably acknowledged; failed submission or acknowledgement leaves eligible work for retry. Disabling alerts or unfollowing retires the corresponding pending records when that change saves. Already submitted system notifications are separate from that local pending state. Permission, background scheduling, and retained release bounds prevent any guarantee of eventual delivery.

## Radio and language evidence

[`RadioExperience`](../Sources/Core/RadioExperience.swift) defines ten genre/mood stations, including classics. Discovery-language variants provide style queries and recording cues. [`RadioSetupView`](../Sources/Views/RadioSetupView.swift) shows **Era preference**, **Languages**, and **Artists (optional)**. No artists are selected initially; zero or one hint is valid, with at most four hints and at least one language. Its copy states: “The station sets the mood. Artist hints nudge the mix; other artists can play too.”

[`ExperienceRadioEngine`](../Sources/Recommendations/ExperienceRadioEngine.swift) first resolves station cues, gives optional hints a small budget, and expands provider radio. If those results are insufficient, it searches genre/mood songs and playlists, browses selected playlists, tries alternative anchors, and retries a bounded number of radio lanes. A starting queue needs at least four songs, an anchor, and a discovered song beyond the fixed cues. A station can start without any chosen artist; provider outages or insufficient matching songs still produce explicit retry/change-era errors.

| Startup bound | Value |
| --- | --- |
| Concurrent requests / individual request timeout | 3 / 6 seconds |
| Whole start / each optional artist-hint lookup | 30 seconds / 2 seconds |
| Cue searches / starting radio seeds / hint-derived seeds | Up to 6 / 4 / 2 |
| Style queries / provider playlists / date-lookup artists | Up to 2 of each |
| Radio requests, including fallback/retry / queue length | Up to 10 / 24 songs |

YouTube Music radio responses have a five-minute in-memory lifetime; empty or unusable radio responses are not cached. Bounded final startup retries and manual continuation use `radio(seed:forceRefresh:)` to request fresh results. This bypasses cached radio data while preserving provider cooldowns and the request limits above. Automatic continuation may reuse a valid cached response.

**Older** prefers starting releases before 2000; **Newer** prefers 2015 onward. Dated starting anchors use known recording or matching-album evidence. Year words in a style query do not verify the returned songs, and related radio/playlist results can span other years. Continuation can fall back to station-style discovery with no era restriction. Languages likewise guide discovery; unlabeled songs may appear. These preferences are not strict whole-queue filters or availability guarantees.

“This is [artist]” expands available provider recordings and sorts known play counts descending, unknowns last. Alternate recording IDs retain separate counts. An artist's monthly audience is displayed only when provided, retaining its unit and raw wording; monthly listeners must not be relabelled as monthly plays.

Recording-language filters support Bengali, English, Hindi, Tamil, and Telugu. Evidence can be recording metadata, inference from matched/linked lyrics, or MusicBrainz work metadata. Artist nationality and provider region do not establish song language. Weak title labels or script hints are shown as “Likely …”; uncertain/conflicting recordings remain in All/Unclassified. Manual corrections, including “Keep unclassified,” persist per recording and can be cleared.

[`ArtistSpotlightMusicBrainz`](../Sources/Catalog/ArtistSpotlightMusicBrainz.swift) uses the official metadata API, not an audio service. It requires an unambiguous title/artist/duration match and a compatible linked Song work with one supported language. This is source evidence, not guaranteed ground truth. Requests share a **one-request-per-second** limiter and a **128-entry in-memory cache** (positive results up to 24 hours, unmatched results 15 minutes).

`MusicBrainzContactURL` uses the published [Support page](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md). Configuration and public-page revision status are recorded in [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md).

## Lyrics

[`CompositeLyricsProvider`](../Sources/Lyrics/CompositeLyricsProvider.swift) first tries [`LRCLyricsService`](../Sources/Lyrics/LRCLyricsService.swift). LRCLIB exact/search queries compare title, artists, album, duration, and recording-version compatibility. Synchronized lyrics require real provider timestamps and a duration-supported match; a usable text match without verified timing remains plain text. Instrumental, unavailable, and failed lookups stay distinct.

When the primary source is missing or fails, the catalog's lyrics provider follows the selected recording's Lyrics tab. [`YouTubeLyricsParser`](../Sources/Lyrics/YouTubeLyricsParser.swift) validates the recording identity and accepts that linked text only as **plain lyrics**. It does not create timestamps. Attribution is `YouTube Music`, `LyricFind via YouTube Music`, or `Musixmatch via YouTube Music` when the response supplies those credits. Breezy has no direct LyricFind or Musixmatch client.

The lyrics screen links to the LRCLIB record or YouTube Music recording. Per-recording timing offsets are saved in the library. Lyrics text and lookup caches are memory-only; the composite cache is bounded to 64 recordings and 4 MiB. Missing responses have a short lifetime, while failures stay retryable.

## Playback and optional account

[`YouTubeStreamResolver`](../Sources/Playback/YouTubeStreamResolver.swift) ordinarily chooses a compatible cached encoding before its expiring 24-entry in-memory URL cache or provider extraction. The direct VISIONOS path and vendored [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) supply AAC and eligible Opus candidates. AAC can stream directly; Opus WebM is downloaded and packet-copied locally into MP4 for AVPlayer. No video player is rendered.

YouTube can require sign-in or deny a request. The optional Settings sign-in may help some account-gated playback lookups, but it is not a guarantee of availability or permission. Real-account end-to-end verification remains pending; synthetic-cookie tests do not establish that Google will accept the web sign-in flow.

- [`YouTubeAccountStore`](../Sources/Account/YouTubeAccountStore.swift) saves YouTube-domain cookie names/values, scope, expiry, and sign-in time in a separate Keychain session using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The session is usable after the first unlock and does not migrate to another device. The app does not save a separate account name, email field, or password. Cookies are authentication credentials.
- The sign-in web view uses a non-persistent store. Google-domain cookies are not copied to the saved session. [`YouTubeKitAuthBridge`](../Sources/Playback/YouTubeKitAuthBridge.swift) adds account cookies and a `SAPISIDHASH` signature only to TVHTML5 player lookups. Direct source lookup, media downloads, catalog, chart, artwork, and lyrics requests do not receive that saved session.
- Breezy does not deliberately submit YouTube watch-history or playback-tracking updates. This does not prevent Google from logging requests or associating a signed-in lookup with an account.
- Sign out removes the in-process session and legacy shared YouTube cookies, then saves a credential-free marker at `Application Support/GanaBajana/Account/pending-sign-out` before attempting Keychain deletion. A saved marker, or an unreadable sign-out status, prevents session restoration on relaunch. The marker is removed only after successful deletion.
- Settings shows **Sign-out pending** and **Retry sign-out** when marker persistence, Keychain deletion, or marker cleanup fails. If the initial marker cannot be saved, deletion is not attempted and the error explicitly requires retry before closing the app. Pending status does not claim credentials were deleted. Keychain items can survive app removal, so app deletion is not a substitute for successful sign-out.

## Audio cache and quality

[`AudioCache`](../Sources/Playback/AudioCache.swift) stores immutable media encodings and sidecars under `Caches/Audio`, grouped by logical recording ID. Prepared Opus MP4 variants can coexist with an original cached encoding. Sidecars retain duration, loudness, view count, bytes, storage time, extension, optional source quality, and the Opus preparation version, **not signed stream URLs**. Legacy AAC entries without quality metadata remain usable.

[`AudioCacheLimit`](../Sources/Core/AudioCacheLimit.swift) owns the policy. Settings uses MB/GB labels with binary byte counts:

| Size choice | Actual limit | Logical-song limit |
| --- | ---: | ---: |
| 250 MB | 250 MiB | 50 |
| 500 MB | 500 MiB | 100 |
| 1 GB, default | 1 GiB (1,073,741,824 bytes) | 200 |
| 2 GB | 2 GiB | 400 |
| 5 GB | 5 GiB | 1,000 |

Prefetch warms up to two likely songs and can fully download the first; playback also prepares upcoming/current audio. Media usage includes **all committed encodings plus active preparation files**, while song count includes distinct logical IDs. Sidecars and abandoned partial files are excluded from that media-byte total. Clearing and limit changes cancel stale writers and protect all in-use variants. Artwork has its own 256 MiB disk response-cache budget and bounded image memory.

AAC cache files preserve the downloaded bytes. Opus preparation changes the container from WebM to MP4 while copying encoded packets without re-encoding; the two container files are not byte-identical. FFmpegBridge performs local packet copy only, and AVFoundation validates native PCM output before the prepared file is committed. The original download used for preparation is temporary; existing committed fallback encodings remain protected. Runtime gates, deadlines, and variant-publication rules are in [ARCHITECTURE.md](ARCHITECTURE.md#opus-preparation-cache-variants-and-reload).

### Source quality and limits

**More > Audio quality** shows available source encoding metadata. Selection uses the highest valid average bitrate, falls back to advertised bitrate when necessary, and prefers AAC on ties. On iOS 26.5+, eligible Opus can be prepared for native playback; older systems use AAC. Unsupported, unavailable, or failed Opus preparation keeps the AAC fallback path. Source bitrate is not a perceptual equivalence between codecs or a measurement of speaker/headphone output.

**Reload best available audio** requests fresh selection while keeping a usable cached fallback. A successful Opus preparation can add a higher-quality immutable variant that later cache-first plays reuse. The app does not overwrite a file AVPlayer is reading or automatically rescan the entire library. Cached media remains purgeable, and uncached songs need a connection.

YouTube documents Premium High quality at **up to 256 kbps** in its own [settings](https://support.google.com/youtubemusic/answer/9076559). Breezy can select only encodings actually returned to it and guarantees neither Premium access nor a bitrate. Playback is not lossless. Normalization attenuates using provider loudness metadata; it does not boost quiet tracks or improve source encoding. Current native-playback evidence and its runtime scope are recorded in [release status](app-store/RELEASE_STATUS.md#verification-snapshot).

## Optional remote extraction

**Remote playback fallback is off by default.** If enabled and local extraction fails, YouTubeKit connects to `remote-production.youtubekit.dev/v1` with the recording ID. `X-AppID-v1`, when available, identifies the signed app using its signing-prefix/bundle identity, not a newly generated listener ID.

[`RemoteYouTubeClient`](../Vendor/YouTubeKit/Sources/YouTubeKit/Remote/RemoteYouTubeClient.swift) can execute URLs, methods, headers, and bodies supplied by that service. It sends back response URLs, status codes, headers, bodies, and requested intermediate responses. Those additional destinations are service-directed rather than a fixed Breezy domain list. The account bridge does not add the saved YouTube session, and extraction transport disables automatic cookie/credential storage; service-directed headers and returned provider headers can nevertheless contain cookies. Responses use the receive-time limits above. Remote-service retention and use have not been verified.

## Encrypted DNS

**Encrypted DNS defaults on.** [`LyricsDNSConfiguration`](../Sources/Lyrics/LyricsDNSConfiguration.swift) sets Apple's default networking privacy context for the app, preferring system encrypted DNS or Private Relay with [Cloudflare DNS over HTTPS](https://cloudflare-dns.com/dns-query) as fallback. Despite the type name, connections beyond lyrics can use this context. The selected resolver receives hostname queries and connection metadata.

The setting affects new app connections, not device-wide DNS. It does not hide music requests from their providers. `dns.google` is an explicit live-test resolver option, not a second production fallback.

## Local data and backups

[`LibraryStore`](../Sources/Library/LibraryStore.swift) saves preferences/Home layout, likes, playlists, dislikes, follows/release state and pending alert IDs, generated mixes, queue/resume state, recent searches, lyrics offsets, recording-language corrections, listening events/privacy epoch, and tip transaction credit/revocation records in `Application Support/GanaBajana/library.json`. Writes are versioned and atomic, with protection after the first device unlock. Corrupt, unsupported/future, and externally changed files are preserved and reported rather than overwritten.

Listening checkpoints receive a Bool acknowledgement only after a durable save or an intentional no-op. Failed writes retain deltas for their original sessions in a memory-only buffer of up to 128 session identities. Exhausting that capacity pauses playback rather than dropping pending time; terminating the process can lose unsaved deltas. **Reload saved library** validates and rereads the saved file, reconciles preferences, and preserves a current queue/newer playback intent. An untouched failed-startup placeholder can receive a recovered queue, restored paused, without overwriting the repaired snapshot through lifecycle callbacks. A failed reload keeps the previous established document and writes blocked. [ARCHITECTURE.md](ARCHITECTURE.md#librarystore-api-and-durability) owns the recovery API.

- **Save listening history** defaults on. Turning it off stops new listening events and recent-listen entries; existing history and resume state remain. A successful disable or clear advances the persisted privacy epoch and retires pending listening. **Clear listening history** removes events, recents, and generated mixes, including retained streak records. Reload also recognizes removed/reduced legacy history so pending time cannot restore erased records. Explicit library choices, search history, and tip IDs are preserved.
- Detailed history and recents are retained for **400 days**. A current streak extending farther back keeps one actual session per older streak day. Retention runs when the library loads or commits.
- Recent searches hold at most **20** distinct deliberately committed queries, with individual removal and clear controls. They are separate from listening history. Radio setup drafts are not stored as preferences.
- Library data and the separate credential-free sign-out marker are not excluded from normal device backups. Depending on iOS settings, preferences, history/privacy epoch, corrections, pending alert IDs, tip IDs, and that marker may be backed up to iCloud or a computer. Device-only Keychain credentials do not migrate with them. There is no app-provided cross-device library sync. Audio/artwork caches use purgeable Caches storage.
- StoreKit handles payment/account details. Breezy's durable purchase record is a transaction-ID-to-credit/revocation map used to avoid double-counting; it is not a purchased feature entitlement or a guaranteed cross-device purchase history.

Diagnostics use local OSLog, including outcomes, timings, and some provider identifiers/error details. Opus preparation records bounded failure reasons and AAC fallback; the C bridge does not log media paths, URLs, metadata, or FFmpeg message text. There is no custom remote analytics/crash endpoint. Apple/system sharing follows device settings. [PRIVACY.md](../PRIVACY.md) matches the public revision updated and readback-verified on 21 September 2026; [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md) records publication and aligned Settings copy.

## Attribution

[`Resources/Acknowledgements.txt`](../Resources/Acknowledgements.txt) contains provider credits, YouTubeKit's verbatim MIT notice, and an FFmpeg/FFmpegBridge LGPL notice. The FFmpeg package owns its [license](../Vendor/FFmpegBridge/LICENSE.md), [notice](../Vendor/FFmpegBridge/NOTICE.md), and [rebuild/relink instructions](../Vendor/FFmpegBridge/README.md#build-provenance-and-lgpl-rebuilds). [FFmpeg distribution](FFMPEG_DISTRIBUTION.md) records the exact local source bundle and pending public delivery. Software licenses do not grant music, lyrics, or cover-art rights. Breezy's bundled icons and brand mark are original artwork.

**Settings > About Breezy > Acknowledgements** displays the bundled notice. Chart, lyrics, and language-evidence views retain relevant source labels and links. MusicBrainz's public contact prerequisite is configured; lookup success and source confidence remain separate from attribution.
