# YouTube recording metadata

Velvet Thorn uses the official YouTube Data API for recording audio-language tags and missing durations. `MusicAppModel` shares one `YouTubeDataAPI` actor between language checks, lyrics preparation and MusicBrainz lookup preparation. It does not use the API's search quota or request playback streams.

## Language precedence

Saved corrections and verified `Track.language` keep their existing precedence. On a language-cache miss, the service checks `snippet.defaultAudioLanguage` for the exact recording ID before requesting lyrics or running the classifier. A supported tag produces the **YouTube audio language** source. Explicit unsupported, undetermined, multilingual or nonlinguistic tags remain unclassified without being guessed as English.

Missing or failed metadata falls back to the existing lyrics/MusicBrainz path within the original six-second language deadline. Weak hints cannot take the metadata shortcut. Classification-cache hits skip both provider lookup and recognition. Identified results retain the existing 12-hour lifetime; unclassified results use five minutes. Listening-led results can round-trip through the existing bounded, backup-excluded derived cache, whose entries retain their original expiry. Manual corrections remain authoritative.

`snippet.defaultLanguage` describes titles/descriptions, not the audio. The parser never uses that field, the requested UI language, an artist's country or a chart region to assign a recording language. [Google's field definition](https://developers.google.com/youtube/v3/docs/videos#snippet.defaultAudioLanguage) owns that distinction.

## Duration preparation

`contentDetails.duration` is parsed as a bounded ISO 8601 day/time duration. A valid existing recording/player duration wins. Missing duration is supplied only to a temporary copy used for lyrics or MusicBrainz matching; this path does not rewrite the saved track, playback snapshot or library. Names, credits, artwork and song-play counts are not replaced with video metadata.

The composite lyrics provider gives optional preparation at most one second inside its existing total deadline. A preparation failure, foreign recording ID or timeout preserves the normal lyrics request. The API supplies no lyric text or timing; synchronized lyrics still require actual source timestamps and the existing recording-match checks.

## Requests and limits

| Item | Bound or behavior |
| --- | --- |
| Endpoint | `GET https://www.googleapis.com/youtube/v3/videos`, exact recording ID |
| Selected fields | `items(id,snippet(defaultAudioLanguage,description,channelTitle,publishedAt),contentDetails(duration),statistics(viewCount))`; parts `snippet,contentDetails,statistics` (one quota unit). The snippet/statistics additions feed Song details ([SONG_DETAILS.md](SONG_DETAILS.md)); `metadata(for:refresh:)` with `refresh` skips one cache read and recaches |
| Authentication | App-restricted project key in `X-Goog-Api-Key`; `X-Ios-Bundle-Identifier` identifies Velvet Thorn |
| Session | Ephemeral, no cookie/credential storage or URL cache; redirects refused before forwarding credentials |
| Request | Two seconds, 256 KiB enforced while receiving, no automatic retry |
| Memory cache | At most 256 recording entries; metadata 12 hours, missing recordings 15 minutes |
| Concurrency | Four active recording lookups, 16 waiters per recording; identical lookups coalesce |
| Cancellation | A caller retires its own waiter; the last waiter cancels the transfer; late completions cannot fill a replacement flight |
| Quota exhaustion | Defer uncached requests until the next midnight in `America/Los_Angeles`, including DST changes |
| Rate limits | Honor `Retry-After`, defaulting to 60 seconds |
| Rejected credentials | One-hour cooldown |
| Temporary failures | Short backoff; a successful missing result is distinct from a failure |
| Offline | Reusable cache entries remain available; uncached metadata makes no request |

Backoff and API cache state are process-local. Google enforces the project-wide quota across installations. Existing language/privacy cancellation gates control automatic listening-derived requests.

## Local configuration and release

The dedicated project is `breezy-509601`, number `321550855021`. Key resource `cbb4151d-55bf-4799-a592-4175cb736de6` is restricted to YouTube Data API v3 and iOS bundle `com.agraabhi.ganabajana`.

Run `python3 tools/configure-youtube-data-api.py` to enter a restricted key without placing it in shell arguments. `--from-clipboard` accepts the key copied from Google's console. The helper creates `Resources/YouTubeDataAPI.local.plist` with owner-only permissions and checks that Git ignores it. Regenerate with `xcodegen generate` after creating the file. The key is a recoverable client credential once bundled, not a secret authentication mechanism for private data; scope and application restrictions are required.

Normal fixture/unit hosts do not activate the bundled credential. Tests inject a fake key and transport. The opt-in `YouTubeDataAPILiveTests` reads the bundled configuration explicitly. Release verification checks that the phone contains the intended configuration and that widgets/Watch do not contain it. Input manifests record its hash, never its value. An unconfigured developer build keeps the existing fallback behavior.

## ytmusicapi comparison

The [ytmusicapi documentation](https://ytmusicapi.readthedocs.io/en/stable/) describes a Python client for YouTube Music's web requests. Version **1.12.3** is used by the development probe, not embedded into the iOS app or deployed as a new server. Its `language` option controls localization and cannot label a song. The existing native catalog remains the app's music-specific provider.

The 2026-09-24 probe compared six exact recording IDs. The official API supplied audio-language tags for two recordings and durations for all six. Four Hindi recordings had `defaultLanguage: en` but no audio-language tag. ytmusicapi returned matching IDs and durations, sometimes one second shorter, but no language fields or audio-track tags for those six responses. This is a sample, not a catalog-wide coverage estimate. Existing valid durations are therefore preserved.

`tools/probe-youtube-metadata.py` prints only selected metadata, never credentials or streaming URLs. The probe used one official batch request plus one deliberately rejected bundle-ID request; it does not make playback or account mutations. The allowed bundle returned HTTP 200 and a different bundle returned HTTP 403. Receipts are under `artifacts/YouTube-authorization/`.

## Metrics

These are local OSLog counters with existing app/category conventions and no identity dimensions. Success/failure and cache outcomes include zero counterparts. No remote telemetry is added.

| Metrics | Emitted when |
| --- | --- |
| `dataAPIConfigured` | Real-app bundled configuration is available or absent |
| `dataAPICacheHit`, `dataAPICacheMiss`, `dataAPICoalesced` | A metadata lookup selects cache, network or an existing flight |
| `dataAPIRejected`, `dataAPICooldown`, `dataAPIQuotaDeferred` | Admission or provider backoff prevents a new request |
| `dataAPIRequestSuccess`, `dataAPIRequestFailure`, `dataAPICancelled`, `dataAPITimedOut`, `dataAPILatencyMs` | HTTP operation completes or fails |
| `dataAPIQuotaExceeded`, `dataAPICredentialsRejected`, `dataAPIRateLimited`, `dataAPIMetadataMissing` | Provider failure category or successful absence |
| `dataAPIDurationAdded`, `dataAPIDurationKept`, `dataAPIDurationMissing` | Lookup-only duration preparation finishes |
| `providerLanguageUsed`, `classificationSkipped`, `providerLanguageFailure` | The language service selects explicit metadata or the existing fallback |

## Test coverage

| Cases | Suite / level |
| --- | --- |
| Request headers/field projection; exact identity; malformed/oversized responses; ISO durations; audio-vs-snippet language; supported/unsupported tags | `YouTubeDataAPITests`, unit |
| Cache expiry/capacity/clock rollback; coalescing; caller/last-waiter cancellation; deadline; admission limits; offline/missing key; quota/rate/auth backoff and DST reset | `YouTubeDataAPITests`, unit |
| Explicit metadata skips lyrics/work/classifier; cached repeat; missing/error/weak fallback; provider timeout/cancellation; persisted provenance/expiry; corrections | `YouTubeLanguageMetadataTests`, unit |
| Missing/known duration; foreign/error/timeout preparation; unchanged caller and metadata; cached repeat; cancellation | `CompositeLyricsMetadataTests`, unit |
| Real bundled credential, recording metadata and classification bypass inside the iOS test host | `YouTubeDataAPILiveTests`, live integration |
| Actual API restrictions and six-recording ytmusicapi comparison | `tools/probe-youtube-metadata.py`, live integration |

The focused regression run passed **174 tests**, including **29 new unit tests**. The native live integration test passed with the bundled credential and no lyrics lookup. [VERIFICATION.md](VERIFICATION.md) records build/release outcomes. Unit tests assert returned state, requests and cancellation rather than OSLog strings; the live request's success/latency counters were observed. Catalog-wide language coverage, physical-device networking and an induced cross-host redirect are not claimed by these checks.
