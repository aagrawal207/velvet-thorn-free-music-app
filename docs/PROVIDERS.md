# Breezy providers and data handling

Breezy contacts external providers directly from the device. There is no Breezy-operated catalog, account, analytics, or music server. Watch and CarPlay controls use that same phone player and its configured providers. Music-specific browsing can operate without an account; the official recording-metadata path uses an app-restricted developer key. Providers can restrict requests. Account-cookie-free requests still disclose network addresses and requested content.

**R9 source inventory.** [VERIFICATION.md](VERIFICATION.md) records completed checks and release delivery. [YOUTUBE_DATA_API.md](YOUTUBE_DATA_API.md) owns official recording metadata, [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) owns listening-derived lookup/retention limits, and [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md) preserves publication versions.

## Distribution and content rights

**App Review submission is on hold.** The owner has confirmed that authorization from YouTube and music rights holders has not been obtained. The current app uses undocumented web endpoints, stream extraction, and complete-song caching; it is not a provider-approved playback integration. A licensed provider/content approach must be selected and reflected in the binary and release assets before submission.

Relevant provider terms are the [YouTube Terms of Service](https://www.youtube.com/static?template=terms) and [YouTube API Services Developer Policies, section III.E.1](https://developers.google.com/youtube/terms/developer-policies#e.-handling-youtube-data-and-content), which restrict downloading/caching audiovisual content without prior written approval and making it available offline. The developer policies also address undocumented APIs and scraping. A public endpoint, successful extraction, a sign-in session, or a software license does not establish content-distribution rights. Calling complete downloads a “temporary cache” does not supply permission.

[RELEASE_STATUS.md](app-store/RELEASE_STATUS.md) owns the release hold. No authorization or content-rights declaration has been prepared as if it were granted.

## Network requests

All recipients see the connection's source IP address and ordinary request metadata. A VPN, relay, or network proxy may affect the address they see. This is the source-level inventory, not a claim about provider retention or tracking practices.

| Recipient | When and what is sent |
| --- | --- |
| `music.youtube.com` | Catalog bootstrap and `/youtubei/v1/search`, `browse`, `next`, and `music/get_queue`: search text/filter, collection or artist IDs, recording IDs, radio seeds, continuation/visitor data when supplied, and client/version/language/region context |
| `www.googleapis.com` | Official YouTube Data API `videos.list`: exact recording ID, selected metadata fields, app API credential and iOS bundle identifier. Reads default audio language before classification and missing duration for lyrics/MusicBrainz matching. No saved account cookies are added |
| `charts.youtube.com` | Weekly chart browse requests with chart type, selected region, and provider client context |
| `youtube.com`, `www.youtube.com` | Recording watch/player/embed and extraction resources, including player JavaScript when needed; recording ID, client headers/context, and provider visitor data. The direct path uses VISIONOS client metadata, not the listener's actual device model |
| `*.googlevideo.com` | Signed media requests, including validation/range requests and complete-file cache transfers for the selected recording |
| Provider-supplied artwork URLs | Image requests, commonly `*.ytimg.com`, `*.googleusercontent.com`, and `*.ggpht.com`; paths identify the artwork and may include a recording ID. The loader can also use other URLs returned by the provider |
| `lrclib.net` | `/api/get` and `/api/search` with song title, artist, optional album, and duration for exact matching. Includes the current app-client User-Agent |
| `music.youtube.com` for lyrics | The selected recording ID on `next`, then its linked `MPLY…` lyrics browse ID. LyricFind/Musixmatch attribution comes through this response, with no direct requests to those publishers |
| `music.youtube.com` for album descriptions | The selected album browse ID and existing WEB_REMIX context; catalog bootstrap when needed. The Wikipedia text is supplied in that header response, without saved account cookies |
| `musicbrainz.org`, when configured | Official `/ws/2/recording` search with cleaned title, up to three artist names, and a duration range; a matched recording-ID lookup with artist-credit/work relationships. If the compatible linked work's embedded language fields are missing or empty, `GET /ws/2/work/<exact-linked-work-ID>?fmt=json` sends that work ID. User-Agent includes the configured public contact URL |

MetaBrainz answered the hosted-API inquiry on 2026-09-25 (`artifacts/Authorization-20260925/metabrainz-reply.md`): a free, tips-supported app may use the data at no charge after registering as a Stealth Start-Up supporter, provided requests follow the [API rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting) (about one request per second per IP with a contactable User-Agent). Attribution is required in the app's help/about area, and optionally in the store listing. Non-CC0 supplementary data such as genres is allowed under that arrangement; Breezy currently reads none. MetaBrainz asked to be contacted again at roughly $500/year of income. The shared one-request-per-second limiter and the `Breezy/1.0 (contact URL)` User-Agent already satisfy the technical conditions; the supporter registration is an owner account action that has not been completed. MetaBrainz keeps request data (IP, User-Agent) only for internal traffic analysis until logs rotate, typically a few days, and does not sell or share it.
| `accounts.google.com` and Google/YouTube sign-in resources, optionally | The Google sign-in web page receives information entered there, cookies, and normal browser request data. Only YouTube-domain session cookies are retained by Breezy after the sheet closes |
| `remote-production.youtubekit.dev`, optionally | Recording ID, app identity when available, and response data from service-directed extraction requests; details below |
| System encrypted DNS or `cloudflare-dns.com/dns-query` | Provider hostname lookups; details below |
| Apple StoreKit services | App/product identification, storefront/product requests, and purchase/transaction processing. Apple manages its service endpoints, account authentication, and payment data |
| Apple iCloud Drive, when enabled/available | Shared library records, typed Search selections, retained legacy queries, preferences and merge revisions through the listener's Apple Account; [ICLOUD_SYNC.md](ICLOUD_SYNC.md) owns the payload |
| `gist.github.com` | User-opened Support and Privacy pages receive ordinary browser request data. Including the Support URL in the MusicBrainz User-Agent does not itself fetch the Gist |
| `en.wikipedia.org`, `creativecommons.org` | User-opened album-description article/license links receive ordinary browser request data. Rendering or expanding a description does not fetch these sites |

Online Search requests are debounced while typing, so partial queries leave the phone even though Recently opened stores selected entities rather than query text. Local liked-song/playlist filtering and known-offline Search use saved metadata. Home/search prefetch can request music before a play tap. Radio adds genre/mood search text, optional artist hints and provider-playlist lookups. Opening an artist page adds bounded collaboration searches. Release polling and recommendation seeds also reveal requested artists or recordings.

After qualified listening, automatic language checks can request matched lyrics and configured MusicBrainz recording/work metadata while the real app is active, history saving is on and the path is not known offline. No artist-page or lyrics-sheet visit is required. Home/page refresh, recovery and applied cloud changes can refresh the same bounded coordinator. History off may read existing derived evidence for preserved history but authorizes no new listening-derived provider checks. Manual browsing/playback has its own request paths. [Automatic checks and derived cache](LISTENING_DISCOVERY.md#automatic-checks-and-derived-cache) records the lifecycle, identity keys and cooldowns.

FFmpegBridge adds no network recipient. The app downloads Opus through the existing media provider and prepares its container locally; the bridge has network support and nested opens disabled.

### Response limits and cancellation

Catalog, recording metadata, MusicBrainz, fast-path playback lookup, and artwork use [`URLSession.boundedData(for:maximumBytes:delegate:)`](../Sources/Networking/BoundedURLSession.swift). It checks both declared length and bytes received, including chunked responses without a known length. The optional task delegate lets the Data API refuse redirects. An oversized response or cancelled caller stops that request's task without invalidating unrelated requests. HTTP status and payload validation remain caller-owned. Declared length is an upper bound, not an EOF equality check, because the networking stack may decode the response body.

| Receiver | Maximum received body | Production per-request bound |
| --- | ---: | ---: |
| Catalog/chart transport, including bootstrap | 8 MiB | 35 seconds |
| MusicBrainz metadata | 2 MiB | At most 3 seconds within the shared 6-second provider lookup deadline |
| YouTube Data API metadata | 256 KiB | Two seconds, within the caller's existing lookup deadline |
| Direct playback fast path | 4,000,000 bytes | 6 seconds |
| Artwork | 12 MiB | At most 30 seconds |
| LRCLIB's dedicated transport | 2 MiB | 20 seconds |
| Vendored extraction HTML/player | 4,000,000 bytes | 30 seconds |
| Vendored extraction JavaScript | 12,000,000 bytes | 45 seconds |
| Vendored remote extraction responses | 8,000,000 bytes | 45 seconds |

These bounds apply to individual responses; higher-level operations can make several requests within their own budgets. Complete media downloads use separate file-length and native-media validation.

[`ExtractionTransport`](../Vendor/YouTubeKit/Sources/YouTubeKit/ExtractionTransport.swift) uses an ephemeral session without automatic cookies, stored credentials, or a URL cache. It enforces receive-time byte limits and deadlines. Full player extraction uses structured concurrent work; cancellation retires its requests rather than cancelling a shared session.

`ArtworkLoader` coalesces work by URL and requested pixel size. Each consumer has its own cancellation: a remaining consumer keeps the transfer alive, while the last cancellation retires and cancels it. Cache clearing waits for retired transfers before removing cached responses. Its non-renewing deadline prevents a trickle response from continually extending the resource budget.

Opening a player's artist-choice list can fetch artist-page metadata for linked IDs, or one exact-name artist search for a name-only credit, followed by the provider's picture URL. `ArtistArtworkResolver` allows two concurrent lookups and a five-second total budget, including queue and image time. Its 128-entry URL/miss cache retries failures after 30 seconds. Names remain immediately selectable; no album/song fallback or extra search page is requested for a picture.

## Catalog, charts, and personal discovery

The official `YouTubeDataAPI` path is recording metadata, not a replacement music catalog or playback provider. It selects only `defaultAudioLanguage` and duration, reuses bounded cached results, and respects quota/rate/auth backoff. Explicit audio-language tags can skip lyrics and recognition. Missing metadata retains the existing fallback; valid durations and song-play counts are preserved. [YOUTUBE_DATA_API.md](YOUTUBE_DATA_API.md) records configuration, scope, metrics and tests.

[`YouTubeMusicService`](../Sources/Catalog/YouTubeMusicService.swift) uses an ephemeral, account-cookie-free [`CatalogTransport`](../Sources/Catalog/CatalogTransport.swift), without credential storage or a disk response cache. Catalog requests use `WEB_REMIX`, English UI context, and `gl: IN`; chart requests select their own region. Provider visitor/continuation values can still associate requests. Audio rows are preferred and batch-validated; explicit video and podcast rows are excluded.

Home uses [`RecommendationEngine.languageDiscovery`](../Sources/Recommendations/LanguageDiscoveryRecommendations.swift) with the local listening-language profile. Identified counted plays and independent nudges choose bounded recording-radio/search targets across five supported languages; cold start uses the preserved Hindi/English defaults. Candidate language is not certified by the query. The older [`CatalogDiscovery`](../Sources/Catalog/CatalogDiscovery.swift) provider helper remains available, and the model still excludes `editorial-hindi` and `editorial-english`. Reordering or hiding Home sections changes presentation, not a guarantee that associated requests stop.

[`YouTubeChartsService`](../Sources/Catalog/YouTubeChartsService.swift) selects weekly `TRACKS` entries from India and the US, with a Global fallback. These are regional chart picks, not certified language-only rankings. The displayed dates are the provider's reporting period, and selected rows retain original ranks. Breezy does not manufacture global monthly/yearly rankings.

Personal recap uses local rolling **7/30/365-day** listening windows. [`ListeningAnalytics`](../Sources/Library/ListeningAnalytics.swift) excludes paused time and seek jumps. Language shares use qualified play counts, including Unclassified in the denominator, rather than seconds or provider popularity. `RecommendationEngine` ranks candidates on device; soft language weights retain unknown/outside-language eligibility, and daily/weekly period keys keep saved mixes stable. Automatic profile-based mix seeds use recording radio; legacy explicit-language callers can use `recommendations(seed:language:)`. Candidate fetching still sends artist and recording requests. Follows and dislikes are local choices, not writes to a YouTube account.

### Release alerts

[`ReleaseWatcher`](../Sources/Recommendations/ReleaseWatcher.swift) checks at most eight due artists per run, with a six-hour catalog-check interval. A successful first read establishes the release baseline, including an empty result; a failed read does not invent a baseline. New-release state and pending notification IDs are saved together before delivery. Pending IDs are bounded by the 60 retained releases and can retry during later checks even when no catalog refresh is due.

Alerts use local iOS notifications after permission. Delivery verifies the current saved library, follow, and alert preference, checks stable identifiers against pending/delivered system notifications, and rechecks eligibility immediately before submission. Accepted notifications are durably acknowledged; failed submission or acknowledgement leaves eligible work for retry. Disabling alerts or unfollowing retires the corresponding pending records when that change saves. Already submitted system notifications are separate from that local pending state. Permission, background scheduling, and retained release bounds prevent any guarantee of eventual delivery.

## Radio and language evidence

[`RadioExperience`](../Sources/Core/RadioExperience.swift) defines 34 stations in two groups (12 moods, 22 genres), reached through the separate **Search > Radio** page. Stations supply genre/mood templates; ten also keep hand-picked language-tagged cues. Automatic radio follows the listening profile across five recording languages and shares the existing request budget among them. [`RadioSetupView`](../Sources/Views/RadioSetupView.swift) shows **Languages follow your listening**, **Era preference** and **Artists (optional)**, with no required language-picker step. No artists are selected initially; zero or one hint is valid, with at most four. Its copy states: “The station sets the mood. Artist hints nudge the mix; other artists can play too.”

| Group | Stations |
| --- | --- |
| Moods (12) | Melancholy, Workout, Late night, Easy morning, Feel good, Focus, Party, Romance, Heartbreak, Road trip, Rainy day, Devotional |
| Genres (22) | Rap and hip hop, Rock, Alt rock, Indie, Pop, R&B and soul, Dance and EDM, Lo-fi, Acoustic, Jazz, Classical and instrumental, Folk, Sufi, Ghazal, Qawwali, Punjabi hits, Bollywood classics, Golden oldies, Metal, Country, Reggae, 90s |

Bollywood classics and Golden oldies default to the Older era. Templates are synthesized from the station and target language where curated wording is absent. The listening profile allocates the existing style-query slots; More can target an unheard language without claiming that previous plays or returned songs use it. Explicit legacy language-set callers remain supported separately from the automatic UI path.

[`ExperienceRadioEngine`](../Sources/Recommendations/ExperienceRadioEngine.swift) first resolves station cues, gives optional hints a small budget, and expands provider radio. If those results are insufficient, it searches genre/mood songs and playlists, browses selected playlists, tries alternative anchors, and retries a bounded number of radio lanes. A starting queue needs at least four songs, an anchor, and a discovered song beyond the fixed cues. A station can start without any chosen artist; provider outages or insufficient matching songs still produce explicit retry/change-era errors. A station with no cues for the chosen languages starts from its wording alone; when no discovery can be dated, undated style songs anchor its lanes.

| Startup bound | Value |
| --- | --- |
| Concurrent requests / individual request timeout | 3 / 6 seconds |
| Whole start / each optional artist-hint lookup | 30 seconds / 2 seconds |
| Cue searches / starting radio seeds / hint-derived seeds | Up to 6 / 4 / 2 |
| Style queries / provider playlists / date-lookup artists | Up to 3 / 2 / 2 |
| Radio requests, including fallback/retry / queue length | Up to 10 / 24 songs |

YouTube Music radio responses have a five-minute in-memory lifetime; empty or unusable radio responses are not cached. Bounded final startup retries and manual continuation use `radio(seed:forceRefresh:)` to request fresh results. This bypasses cached radio data while preserving provider cooldowns and the request limits above. Automatic continuation may reuse a valid cached response. Ordinary Autoplay makes at most three radio requests per exhaustion event (ending song, one borrowed queue seed, one fresh retry after a transient failure) plus one more event when the queue actually ends; the fresh retry and the queue sheet's Autoplay retry use `radio(seed:forceRefresh: true)`. A station whose automatic continuation added nothing likewise gets one more continuation round when its queue ends. Cooldowns are never bypassed.

**Older** prefers starting releases before 2000; **Newer** prefers 2015 onward. Dated starting anchors use known recording or matching-album evidence. Year words in a style query do not verify the returned songs, although a wording-only start without dated evidence may still anchor on undated songs, and related radio/playlist results can span other years. Continuation can fall back to station-style discovery with no era restriction. Languages likewise guide discovery; unlabeled songs may appear. These preferences are not strict whole-queue filters or availability guarantees.

“This is [artist]” sorts available provider-labelled song totals descending, unknowns last. Alternate releases can carry different totals: the R10 live Radiohead check returned 2.3B for the Pablo Honey recording of Creep and 2.2B for its single. A display representative keeps its own total; counts are neither added nor used as recording identity.

`ArtistSpotlight.displaySongs` groups matching releases for display. It removes only recognized cosmetic annotations, preserving named live performances, remixes, parts, clean edits and language labels, including unsupported languages. Complete credited performer names and compatible linked IDs must agree. Every pair in a group needs valid durations within ten seconds and compatible recording-language evidence. Unknown metadata cannot bridge conflicting groups. Missing duration or ambiguous identity leaves separate rows.

Saved language corrections retain their recording ID as representative. Otherwise the ranking prefers a known album/EP, avoids known compilations and remasters, then considers explicit status, an available count, the provider listing, artwork, title length and a stable ID tie-break. Unknown release types receive no invented album classification. The winner retains its own explicit flag, artwork, duration and language metadata.

The catalog service retains source candidates across search and album updates, rather than feeding display representatives back into matching. With `N` initial recording IDs, `A` additional-song allowance and `R` configured search/album requests, retained candidates are capped at `N + (N + A) × R`; displayed additional groups remain capped at `A` (100 by default). Existing request and deadline limits still apply. The loader caches the display projection until candidates, evidence or saved corrections change. Top songs uses representatives for provider-listed groups in listing order; Featuring excludes every group with a listed member and sorts search-only collaborations by count. Role is positional: the first-named credit is primary.

Opening an artist page runs up to two songs-search pages, up to 20 exact-ID count searches, and up to three album browses when the listing is sparse. Automatic language checks wait for catalog selection to settle, then spend the existing bounded lookup budget on displayed recordings. Results remain keyed to the checked recording and its metadata. An artist's monthly audience retains the provider's unit and raw wording; monthly listeners are never relabelled as monthly plays.

The popular-song list opens with a compact, collapsed **Languages** control. At least two identified recording languages change its title to **Browse by language**; suggestions and unknowns do not count. Opening the browser shows filters, check/retry actions, and per-song evidence/corrections. Background checks do not open the browser or change its selected filter. Collapsing it retains the filter, including an empty filter; manual corrections also remain available from a song's context menu. Automatic bounded lyrics/MusicBrainz checks can run when the spotlight opens, even while the browser is collapsed.

Recording-language filters support Bengali, English, Hindi, Tamil, and Telugu. Evidence can be recording metadata, inference from matched/linked lyrics, or MusicBrainz work metadata. Artist nationality and provider region do not establish song language. Weak title labels or script hints are shown as “Likely …”; uncertain/conflicting recordings remain in All/Unclassified. Manual corrections, including “Keep unclassified,” persist per recording and can be cleared. Browser/filter state is in memory rather than saved with those corrections.

[`ArtistSpotlightLanguageClassifier`](../Sources/Catalog/ArtistSpotlightLanguageClassifier.swift) validates recording identity before unconstrained on-device recognition. Whole text and 40-original-word cores at a 20-word stride retain punctuation, contractions, and line breaks; lexical checks use normalized expansions. An ambiguous core may receive one context retry up to 80 original words only after its own lexical/script checks pass and no confident alternative code exists. A sparse English line still needs a non-ambiguous anchor and high confidence with a clear margin. Foreign-segment vetoes run independently before positive classification. Mixed, short, or transliterated text can remain uncertain. Recognition uses no song/artist priors. [SONG_LANGUAGES.md](SONG_LANGUAGES.md) owns the thresholds and measured scope; catalog-wide accuracy is not established.

[`ArtistSpotlightMusicBrainz`](../Sources/Catalog/ArtistSpotlightMusicBrainz.swift) uses the official metadata API, not an audio service. It requires an unambiguous title/artist/duration match and a compatible exact performance link to one Song work. Missing or empty embedded language fields allow a conditional lookup of that exact work ID. An absent/ambiguous link does not trigger a work-title search, and explicit unsupported or conflicting language values are not treated as missing metadata. Results retain recording/work provenance; the correction sheet links to both entities. This is source evidence, not guaranteed ground truth.

| Language lookup layer | Bound |
| --- | --- |
| Spotlight loader | 12 automatic checks, 12 per manual batch, two concurrent classifications, 36-second batch deadline |
| Language service | Six-second classification deadline; lyrics and metadata each have an independent 5.5-second source deadline; two active lookups and 12 waiters per lookup |
| Shared language-service cache | 256 recording-and-metadata keys in memory; identified results 12 hours, unclassified/suggestions five minutes |
| MusicBrainz provider | At most three requests: search, recording, and optional exact work. One shared six-second lookup deadline, at most three seconds per request, a shared one-request-per-second limiter, and a 2 MiB receive-time response cap |
| MusicBrainz cache | 128 recording-and-metadata keys in memory; identified results 24 hours, missing/uncertain/conflicting results 15 minutes |

The outer classification deadline bounds both sources together. An individual source timeout can still leave useful evidence from the other source; explicit conflicts take precedence. Transport failures remain retryable rather than cached misses. Last-waiter cancellation retires the classification flight and both source branches; cancelled MusicBrainz lookups do not insert negative results.

Those bounds describe the shared classifier and artist spotlight. The listening-derived coordinator has its own bounded snapshot, pending queue and local disk cache, including a negative cooldown for a failed automatic check. [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md#automatic-checks-and-derived-cache) owns those separate limits. Corrections and verified recording metadata stay authoritative outside the derived cache.

The conditional work lookup uses the existing ephemeral MusicBrainz session without cookie storage, saved credentials, or a URL cache. It adds no host or server-side lyrics analysis. All four live cases passed in `Breezy-Refinements-Language-08`: Kanye West's **All Falls Down (feat. Syleena Johnson)**, Radiohead's **No Surprises**, Hindi/transliteration not certified English, and the exact MusicBrainz recording/work contract. The observed work relations already carried language fields, so that contract check does not measure incremental recovery from the conditional extra fetch.

`MusicBrainzContactURL` uses the published [Support page](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md). Configuration and public-page revision status are recorded in [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md).

## Song play counts

`Track.playCount` holds a provider-labelled song-play total for the selected recording. Parsing requires a complete plays label, including compact or written scales such as `1.2B plays` and `1.2 billion plays`. Linked artist/album names, upload views, audience figures and period-qualified counts cannot supply that field. Literal integer counts retain Int64 precision; malformed or overflowing values remain unknown. Displayed compact totals are rounded snapshots.

Search and album browsing can validate an audio counterpart through the existing `music/get_queue` batch. The source page's total survives that substitution only for an exact recording ID, or one explicit `MPTC` track-credits link with compatible title and artist credits. Title similarity alone is insufficient. The rescue reuses the source response and validation batch, adding no per-song request. Alternate recording counts are never summed. Weekly charts keep their separate dated `ChartEntry.views` values.

The 22 September metadata comparison found `1.2B plays` for **Tum Hi Ho** on the Aashiqui 2 song row, while its audio upload reported `200,574,245 views` and a compilation upload reported `330,833 views`. The prior album-audio rescue dropped the song total, allowing Now Playing to substitute those upload values. `PlayerController.currentPlayCount` retains the catalog scope; `resolvedViewCount` is diagnostics only, including when media comes from an older audio sidecar.

Existing cache lifetimes remain two minutes for search, ten minutes for browse and one hour for queue metadata. Saved legacy counts have no unit or fetch-time provenance and are preserved, so an old library snapshot cannot be reliably repaired without fresh matching metadata. Missing totals stay hidden. Coverage includes strict label parsing, linked-identity rejection, album/search service wiring, cache expiry and prepared-player handoff in `PlayCountTests`, `CatalogPlayCountTests`, `CatalogPlayCountServiceTests` and `PlaybackPlayCountTests`.

`YouTubeMusicService` emits `providerPlayCountUpdated` and `providerPlayCountMissing` as numeric counts in one OSLog debug record per parsed search/browse page, including zero outcomes. These records have no track IDs, titles or new dimensions, and add no remote telemetry.

## Lyrics

[`CompositeLyricsProvider`](../Sources/Lyrics/CompositeLyricsProvider.swift) first tries [`LRCLyricsService`](../Sources/Lyrics/LRCLyricsService.swift). LRCLIB exact/search queries compare title, artists, album, duration, and recording-version compatibility. Synchronized lyrics require real provider timestamps and a duration-supported match; a usable text match without verified timing remains plain text. Instrumental, unavailable, and failed lookups stay distinct.

When the primary source is missing or fails, the catalog's lyrics provider follows the selected recording's Lyrics tab. [`YouTubeLyricsParser`](../Sources/Lyrics/YouTubeLyricsParser.swift) validates the recording identity and accepts that linked text only as **plain lyrics**. It does not create timestamps. Attribution is `YouTube Music`, `LyricFind via YouTube Music`, or `Musixmatch via YouTube Music` when the response supplies those credits. Breezy has no direct LyricFind or Musixmatch client.

The lyrics screen links to the LRCLIB record or YouTube Music recording. Per-recording timing offsets are saved in the library. Lyrics text and lookup caches are memory-only; the composite cache is bounded to 64 recordings and 4 MiB. Missing responses have a short lifetime, while failures stay retryable.

## Album descriptions

[`CatalogAlbumDescriptionParser`](../Sources/Catalog/CatalogAlbumDescriptionParser.swift) uses the Wikipedia prose already supplied in the selected YouTube Music album header, normally under `musicResponsiveHeaderRenderer.description.musicDescriptionShelfRenderer.description.runs`. Catalog subtitles and microformat labels are not biographies. The prose, title, release kind, and linked credits must belong to the same direct or selected-tab header; related shelves and unselected tabs cannot supply missing identity.

[`AlbumDescriptionIdentity`](../Sources/Catalog/AlbumDescriptionIdentity.swift) requires a matching album title and article title, an album/soundtrack/EP definition, and an album-artist or soundtrack-composer relationship for every header credit. Guest, producer, and comparison mentions cannot repair conflicting or missing album credits. The parser recognizes a bounded set of English definitions and credit clauses; unsupported wording, conflicting metadata, and edition mismatches can leave valid descriptions absent. This conservative matching is not independent fact-checking or a catalog-wide availability guarantee.

Full source and license URLs come from the footer's navigation endpoints, not its shortened visible labels. Only HTTPS `en.wikipedia.org/wiki/…` article links and supported `creativecommons.org` CC BY-SA 3.0/4.0 license links are accepted, with agreement between the license version and footer. License paths must match the exact `/licenses/by-sa/{version}` base, with or without a trailing slash, or its recognized `/legalcode` or `/deed.en` path. The recorded **Graduation** and **Aashiqui 2** headers supplied **CC BY-SA 3.0**, which is retained for that copy; the app does not silently replace it with Wikipedia's current license version.

The initial public-response research is separate from the executed `AlbumDescriptionLiveTests` case in `Breezy-Album-Verification-01`, which fetched both reference albums successfully. That rerun also verified the canonical license-base fix and parser/catalog regressions. [ALBUM_DESCRIPTIONS.md](ALBUM_DESCRIPTIONS.md) records the source and matching limits; [VERIFICATION.md](VERIFICATION.md) owns the full run counts. This evidence does not establish broader catalog availability.

Ordinary album browsing carries a valid description without another request. The optional `albumDescription(id:)` lookup reads the first header only, through the existing account-cookie-free catalog session, and normally reuses a just-fetched browse response. It adds no automatic Wikipedia, Wikidata, or MusicBrainz lookup and no account/authentication flow. The article and license websites are contacted only when the user follows their links.

| Description operation or retained value | Bound |
| --- | --- |
| Description-only provider lookup | Five seconds total, including bootstrap and transport retries; one header, without continuation or recording enrichment |
| UI loader | Six seconds, including injected providers; retired work cannot publish a late result |
| Response / raw prose field | Existing 8 MiB receive-time cap / 32 KiB and at most 64 runs |
| Displayed prose | At most 2,400 characters plus an ellipsis, cut at a word boundary and marked **Excerpt** when shortened |
| Response cache | Existing 24-response, 12 MiB catalog memory cache; album browse responses live for ten minutes |

Successful absence uses the same browse-response cache. Transport errors, malformed JSON, and invalid response envelopes remain retryable failures rather than cached absence. There is no persistent description store. Songs and their actions remain usable during optional loading. **About this album** begins at three lines with **Read more** / **Show less**; attribution and license links stay visible. Missing text hides the section, while a failed lookup offers explicit local Retry.

## Playback and optional account

[`YouTubeStreamResolver`](../Sources/Playback/YouTubeStreamResolver.swift) chooses a compatible complete cached encoding before its expiring 24-entry in-memory URL cache or provider extraction, for normal and forced resolution. Known offline permits the local file path only; even an unexpired in-memory media URL is not an offline cache hit. The direct VISIONOS path and vendored [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) supply AAC and eligible Opus candidates. AAC can stream directly; Opus WebM is downloaded and packet-copied locally into MP4 for AVPlayer. No video player is rendered.

YouTube can require sign-in or deny a request. The optional Settings sign-in may help some account-gated playback lookups, but it is not a guarantee of availability or permission. Real-account end-to-end verification remains pending; synthetic-cookie tests do not establish that Google will accept the web sign-in flow.

- [`YouTubeAccountStore`](../Sources/Account/YouTubeAccountStore.swift) saves YouTube-domain cookie names/values, scope, expiry, and sign-in time in a separate Keychain session using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The session is usable after the first unlock and does not migrate to another device. The app does not save a separate account name, email field, or password. Cookies are authentication credentials.
- The sign-in web view uses a non-persistent store. Google-domain cookies are not copied to the saved session. [`YouTubeKitAuthBridge`](../Sources/Playback/YouTubeKitAuthBridge.swift) adds account cookies and a `SAPISIDHASH` signature only to TVHTML5 player lookups. Direct source lookup, media downloads, catalog, chart, artwork, and lyrics requests do not receive that saved session.
- Breezy does not deliberately submit YouTube watch-history or playback-tracking updates. This does not prevent Google from logging requests or associating a signed-in lookup with an account.
- Sign out removes the in-process session and legacy shared YouTube cookies, then saves a credential-free marker at `Application Support/GanaBajana/Account/pending-sign-out` before attempting Keychain deletion. A saved marker, or an unreadable sign-out status, prevents session restoration on relaunch. The marker is removed only after successful deletion.
- Settings shows **Sign-out pending** and **Retry sign-out** when marker persistence, Keychain deletion, or marker cleanup fails. If the initial marker cannot be saved, deletion is not attempted and the error explicitly requires retry before closing the app. Pending status does not claim credentials were deleted. Keychain items can survive app removal, so app deletion is not a substitute for successful sign-out.

## Apple Watch and CarPlay data

The watchOS 11+ companion exchanges playback snapshots and requested library pages with its paired iPhone through Apple's WatchConnectivity. Snapshots include recording ID/title/artist, position/duration, play/loading state, favorite/shuffle/repeat settings, and fixed error copy. Pages contain bounded rows from Favorites, Recently played, Playlists, individual playlists, and Queue, including playlist names and song counts. Control requests return choices and item identifiers to the phone. The shared codec's **60 KiB** bound applies before decoding and after encoding; [architecture](ARCHITECTURE.md#shared-controller-and-wire-contract) describes page bounds and request idempotency.

Watch payloads exclude audio bytes, signed media URLs, account cookies, and artwork/media assets. The Watch has no catalog, sign-in, extraction, or standalone audio player. Browsed pages are held in Watch app memory; WatchConnectivity can retain the latest background snapshot for later delivery. That cached snapshot is display data, never a queued playback command or a second saved library. [WATCH.md](WATCH.md) owns phone-issued mutation leases, separate client deadlines, position coalescing, and freshness rules.

The paired-simulator integration run exercised real `WCSession` messages while the phone used an isolated DEBUG catalog and local silent-audio fixture. Production library and account state were outside that test. Its play/next/pause confirmations establish transport integration, not live provider playback, audio fidelity, or physical background delivery.

CarPlay uses native lists and the phone's existing system Now Playing metadata. Its in-process bridge calls share the iPhone player and saved library; Watch transport leases/deadlines do not apply to them. CarPlay list artwork uses system symbols without image downloads. Companion selections can trigger the phone's ordinary stream resolution and caching, using the existing third parties and optional account settings. These features add no external music service or app backend. CarPlay entitlement approval/signing and physical-device acceptance remain unverified in [CARPLAY.md](CARPLAY.md).

## Audio cache and quality

[`AudioCache`](../Sources/Playback/AudioCache.swift) stores immutable media encodings and sidecars under `Caches/Audio`, grouped by logical recording ID. Prepared Opus MP4 variants can coexist with an original cached encoding. Sidecars retain duration, loudness, view count, bytes, storage time, extension, optional source quality, Opus preparation version and optional validated `Track` display metadata, **not signed stream URLs**. Legacy AAC entries without quality/display metadata remain eligible.

[`AudioCacheLimit`](../Sources/Core/AudioCacheLimit.swift) owns the policy. Settings uses MB/GB labels with binary byte counts:

| Size choice | Actual limit | Logical-song limit |
| --- | ---: | ---: |
| 250 MB | 250 MiB | 50 |
| 500 MB | 500 MiB | 100 |
| 1 GB, default | 1 GiB (1,073,741,824 bytes) | 200 |
| 2 GB | 2 GiB | 400 |
| 5 GB | 5 GiB | 1,000 |

While not known offline, prefetch warms up to two likely songs and can fully download the first; playback also prepares upcoming/current audio. Media usage includes **all committed encodings plus active preparation files**, while song count includes distinct logical IDs. Sidecars and abandoned partial files are excluded from that media-byte total. Clearing, removal and limit changes cancel stale writers and protect all in-use variants. Artwork has its own 256 MiB disk response-cache budget and bounded image memory.

Complete audio has no TTL. [`AudioCacheRetentionPolicy`](../Sources/Playback/AudioCacheRetentionPolicy.swift) ranks unused recordings from durable listening recency and qualified-session frequency, with deterministic cache-access ties. Speculative caching cannot evict higher-scored recordings; foreground playback can admit a new choice. Both byte and logical-song limits apply, with current/upcoming/outgoing and native-reader protection allowed to leave an honest overage. The score, time windows and privacy boundary are owned by [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md#cache-retention-from-listening).

AAC cache files preserve the downloaded bytes. Opus preparation changes the container from WebM to MP4 while copying encoded packets without re-encoding; the two container files are not byte-identical. FFmpegBridge performs local packet copy only, and AVFoundation validates native PCM output before the prepared file is committed. The original download used for preparation is temporary; existing committed fallback encodings remain protected. Runtime gates, deadlines, and variant-publication rules are in [ARCHITECTURE.md](ARCHITECTURE.md#opus-preparation-cache-variants-and-reload).

### Inventory, removal and offline continuity

**Cached songs** opens from Search or Storage through the existing resolver's optional inventory capability. `AudioCache.snapshot(allowOpus:)` groups complete size-checked sidecar/media pairs. Available-locally counts require a valid provider ID and eligible encoding; incompatible stored variants can remain visible for removal, while incomplete files are excluded. Inventory is a completeness/compatibility check, **not full native AAC decoder validation**. Playback can reject a damaged file, and missing sidecar duration uses a leased native duration read rather than a guessed catalog duration.

New sidecar metadata is preferred; older files join matching metadata already in the queue/library. A playable file without metadata has a **Cached song** fallback rather than a fabricated title. Inventory browsing performs no catalog/extraction lookup. Per-song removal drains preparation/writers, rechecks live pins and removes all variants. In-use, not-found, failed and unsupported outcomes remain distinct from successful removal or an empty inventory.

Known offline keeps Home's local routes and saved-metadata Search available while retiring automatic provider discovery. The resolver rejects misses before extraction, URL validation or download. Cached queue traversal skips missing entries within a bounded pass, preserves duplicate occurrences and respects Repeat one/all. It neither rewrites the queue nor requests Autoplay. Connectivity returning can resume interrupted preparation for existing playing intent; paused or exhausted playback does not restart by itself. Unknown network status does not prove that a provider is reachable. [Architecture](ARCHITECTURE.md#cached-inventory-and-offline-playback) records generations, inventory failures and player ownership.

### Source quality and limits

**More > Audio quality** shows available source encoding metadata. Selection uses the highest valid average bitrate, falls back to advertised bitrate when necessary, and prefers AAC on ties. On iOS 26.5+, eligible Opus can be prepared for native playback; older systems use AAC. Unsupported, unavailable, or failed Opus preparation keeps the AAC fallback path. Source bitrate is not a perceptual equivalence between codecs or a measurement of speaker/headphone output.

**Reload best available audio** requests fresh selection while keeping a usable cached fallback. Unlike a normal forced retry, `refreshQuality(track:)` can bypass audio-cache selection when not known offline; offline it falls back to ordinary cached resolution and its UI control is disabled. A successful Opus preparation can add a higher-quality immutable variant that later cache-first plays reuse. The app does not overwrite a file AVPlayer is reading or automatically rescan the entire library. Cached media remains purgeable, and uncached songs need a connection.

YouTube documents Premium High quality at **up to 256 kbps** in its own [settings](https://support.google.com/youtubemusic/answer/9076559). Breezy can select only encodings actually returned to it and guarantees neither Premium access nor a bitrate. Playback is not lossless. Normalization attenuates using provider loudness metadata; it does not boost quiet tracks or improve source encoding. Historical native-playback evidence and its runtime scope are recorded in [release status](app-store/RELEASE_STATUS.md#verification-snapshot).

## Optional remote extraction

**Remote playback fallback is off by default.** If enabled and local extraction fails, YouTubeKit connects to `remote-production.youtubekit.dev/v1` with the recording ID. `X-AppID-v1`, when available, identifies the signed app using its signing-prefix/bundle identity, not a newly generated listener ID.

[`RemoteYouTubeClient`](../Vendor/YouTubeKit/Sources/YouTubeKit/Remote/RemoteYouTubeClient.swift) can execute URLs, methods, headers, and bodies supplied by that service. It sends back response URLs, status codes, headers, bodies, and requested intermediate responses. Those additional destinations are service-directed rather than a fixed Breezy domain list. The account bridge does not add the saved YouTube session, and extraction transport disables automatic cookie/credential storage; service-directed headers and returned provider headers can nevertheless contain cookies. Responses use the receive-time limits above. Remote-service retention and use have not been verified.

## Encrypted DNS

**Encrypted DNS defaults on.** [`LyricsDNSConfiguration`](../Sources/Lyrics/LyricsDNSConfiguration.swift) sets Apple's default networking privacy context for the app, preferring system encrypted DNS or Private Relay with [Cloudflare DNS over HTTPS](https://cloudflare-dns.com/dns-query) as fallback. The Settings description states the user benefit (private hostname lookups on the current network); the mechanism stays as documented here. Despite the type name, connections beyond lyrics can use this context. The selected resolver receives hostname queries and connection metadata.

The setting affects new app connections, not device-wide DNS. It does not hide music requests from their providers. `dns.google` is an explicit live-test resolver option, not a second production fallback.

## Local data and backups

[`LibraryStore`](../Sources/Library/LibraryStore.swift) saves preferences/Home layout and independent language nudges, likes, playlists, dislikes, follows/release state and pending alert IDs, generated mixes, queue/resume state, typed Search selections and retained legacy queries, lyrics offsets, recording-language corrections, listening events/privacy epoch, and tip transaction credit/revocation records in `Application Support/GanaBajana/library.json`. Local document v3 reads v1/v2; journal/replica v2 read v1. Writes are atomic, with protection after the first device unlock. Corrupt, unsupported/future and externally changed files are preserved and reported rather than overwritten. [ICLOUD_SYNC.md](ICLOUD_SYNC.md) owns migration and merge boundaries.

Listening checkpoints receive a Bool acknowledgement only after a durable save or an intentional no-op. Failed writes retain deltas for their original sessions in a memory-only buffer of up to 128 session identities. Exhausting that capacity pauses playback rather than dropping pending time; terminating the process can lose unsaved deltas. **Reload saved library** validates and rereads the saved file, reconciles preferences, and preserves a current queue/newer playback intent. An untouched failed-startup placeholder can receive a recovered queue, restored paused, without overwriting the repaired snapshot through lifecycle callbacks. A failed reload keeps the previous established document and writes blocked. [ARCHITECTURE.md](ARCHITECTURE.md#librarystore-api-and-durability) owns the recovery API.

- **Save listening history** defaults on. Turning it off stops new listening events, recent-listen entries and listening-derived language checks; existing history and resume state remain. A successful disable or clear advances the persisted privacy epoch and retires pending listening. **Clear listening history** removes events, recents and generated mixes, including retained streak records, and resets derived language/cache-retention evidence. Explicit language nudges and corrections remain. Reload also recognizes removed/reduced legacy history so pending time cannot restore erased records. Explicit library choices, search history and tip IDs are preserved.
- Detailed history and recents are retained for **400 days**. A current streak extending farther back keeps one actual session per older streak day. Retention runs when the library loads or commits.
- Recently opened holds at most **20** typed destinations selected from Search. Collection tracks are stripped, and legacy query text is preserved separately until removed/cleared without guessed entity migration. `clearRecentSearches()` clears both fields and advances their shared reset generation; independent compaction floors protect their ordering. Search has individual removal and Clear all. Storage shows the typed count and any legacy count, with clearing enabled for either. Listening-history settings do not gate this history. Radio setup drafts are not stored as preferences.
- Library data, its sync journal and the separate credential-free sign-out marker can enter normal device backups. iCloud sync defaults on for an absent device configuration and preserves saved opt-outs. It shares typed Search selections and per-language preferences alongside other library records, excluding playback snapshots, credentials, pending alert deliveries, StoreKit records, cached media and the derived language-cache file. Device configuration is excluded from backups. [ICLOUD_SYNC.md](ICLOUD_SYNC.md) owns the payload and retention rules. Device-only Keychain credentials do not migrate; audio/artwork and derived language caches use purgeable Caches storage.
- StoreKit handles payment/account details. Breezy's durable purchase record is a transaction-ID-to-credit/revocation map used to avoid double-counting; it is not a purchased feature entitlement or a guaranteed cross-device purchase history.

Diagnostics use local OSLog, including outcomes, timings, and some provider identifiers/error details. Song-language diagnostics use fixed outcome counters and latency without lyric text, song titles, artist names, or entity IDs; [SONG_LANGUAGES.md](SONG_LANGUAGES.md#metrics) records the counters. [LISTENING_DISCOVERY.md#metrics](LISTENING_DISCOVERY.md#metrics) records the R6 discovery, Search, connectivity, inventory and retention counters with bounded categories/outcomes and no identity dimensions. Album-description diagnostics record local outcomes/timings without prose, album IDs, artist names, or URLs; [ALBUM_DESCRIPTIONS.md](ALBUM_DESCRIPTIONS.md#metrics) records those counters. CarPlay logs local template/navigation failures. Opus preparation records bounded failure reasons and AAC fallback; the C bridge does not log media paths, URLs, metadata, or FFmpeg message text. There is no custom remote analytics/crash endpoint. Apple/system sharing follows device settings.

Support/Privacy were updated and byte-verified on 23 September 2026 local time for build-4 preparation. [PRIVACY.md](../PRIVACY.md) covers automatic listening-derived requests, typed Search history, derived local caches and widget sharing. [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md) preserves the current revision and immutable historical build-3 copies.

The English lexical inspection used during testing shares production cleanup, returns only numeric/Boolean evidence, and inspects at most 128 retained lines. It is DEBUG-only, called only by tests, and excluded from Release. It neither logs lyric text nor adds a production request or telemetry path.

## Attribution

[`Resources/Acknowledgements.txt`](../Resources/Acknowledgements.txt) contains provider credits, YouTubeKit's verbatim MIT notice, and an FFmpeg/FFmpegBridge LGPL notice. The FFmpeg package owns its [license](../Vendor/FFmpegBridge/LICENSE.md), [notice](../Vendor/FFmpegBridge/NOTICE.md), and [rebuild/relink instructions](../Vendor/FFmpegBridge/README.md#build-provenance-and-lgpl-rebuilds). [FFmpeg distribution](FFMPEG_DISTRIBUTION.md) records the public library-source release and pending recipient application relinking. Software licenses do not grant music, lyrics, or cover-art rights. Breezy's bundled icons and brand mark are original artwork.

MusicBrainz core data is CC0, while supplementary data has separate licensing; its [API documentation](https://musicbrainz.org/doc/MusicBrainz_API#General_FAQ) separately directs commercial users to contact MetaBrainz. The current lookup consumes recording/work metadata and relationships, with no user tags or ratings, and enforces the documented per-client one-request-per-second limit. A private inquiry asks which hosted-service arrangement applies to the planned free app with optional tips. LRCLIB was separately asked about lyric-data reuse, attribution and deployed data retention. [Authorization records](app-store/AUTHORIZATION_REQUEST.md#other-provider-inquiries) own those pending responses.

**Settings > About Breezy > Acknowledgements** displays the bundled notice. Chart, lyrics, and language-evidence views retain relevant source labels and links. Album descriptions display **Wikipedia via YouTube Music**, the original article link, and the license supplied for that text, with an excerpt notice when shortened. That text license does not grant music or artwork rights. MusicBrainz's public contact prerequisite is configured; lookup success and source confidence remain separate from attribution.
