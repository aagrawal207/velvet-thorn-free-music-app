# Song details

## Purpose

A "Song details" page under the player's More sheet answers "who made this and where did it come from": performers, composer, lyricist, producer and other credits, album and release facts, playback and cache state, provider counters and the identifiers behind the recording. It reads YouTube's own release notes first and asks MusicBrainz only for gaps, so ordinary uploads and non-YouTube recordings still get credits when a unique recording exists.

## Behaviour

- Route: `PlayerOptionsSheet` row `player.options.details` ("Song details", `info.circle`), placed right after "Go to artist". It pushes `PlayerOptionsRoute.details` inside the sheet's existing NavigationStack (title "Song details") and expands the sheet to the large detent. Back returns to Song options; Done closes the sheet.
- Sources, in order:
  1. YouTube's auto-generated art-track description ("Provided to YouTube by ...") through the shared `YouTubeDataAPI` `videos.list` call (same one-unit request, new snippet/statistics fields). When the Data API is unavailable (no key, quota, cooldown, error) the cookie-free InnerTube `player` request in `YouTubePlayerDetailsClient` supplies `shortDescription`, `author`, `viewCount` and the publish date. `ProvidedToYouTubeDescriptionParser` recognises the header, the title line (middle dots), the album line, the ℗/© lines, "Released on:", DDEX role lines ("Composer  Lyricist: X" is one role covering both; "Associated  Performer, Producer: Y" is two roles; names split on ", " and " & "), the footer, CRLF line endings and extra blank lines. Ordinary descriptions return nil and are shown as plain text only.
  2. MusicBrainz, when the description supplied no credits or the recording is not an art track: recording search (title, credits, duration within 2 s), `recording/<id>?inc=artist-credits+artist-rels+work-rels+work-level-rels+releases+isrcs`, then one follow-up: `work/<id>?inc=artist-rels` when the embedded work carries no relations, otherwise `release/<id>?inc=labels` for the label. Composer, lyricist, writer, arranger come from work relations; producer, mix, mastering, recording, engineer, vocal, programming from recording relations. Ambiguous searches (several matching recordings) give up quietly. The UI footer reads "Credits from MusicBrainz" when they are used.
  3. Only `MusicSource.youTubeMusic` recordings get YouTube requests; `saavn:`/`gaana:` ids go to MusicBrainz alone.
- Merging: description facts win; MusicBrainz fills missing roles, album, release date, ISRC and the MusicBrainz recording id (`TrackDetails.fillMissing`). Performers are always `track.allCredits`.
- Store: `TrackDetailsStore` keeps 64 entries in memory (LRU), JSON files in `Caches/Details/<sanitised id>.json` bounded to 500 files (oldest modification date removed first), and remembers recordings without any facts for 15 minutes in memory only. Refresh bypasses the caches; a refresh that finds nothing keeps the facts already shown. Offline lookups return cached JSON or nothing, without any request.
- Screen (`PlayerSongDetailsView`, ids `player.details.*`): 88-point artwork header (title up to 3 lines, artists, album); Performers rows (44-point artwork circle, name, chevron) that close the sheet and the player and open the artist through the options sheet's deferred-dismiss callbacks; Credits rows with a source footer; Release (Album, opens the album when the track has an album id; Released on as a medium date in UTC; Label from the ℗ line or MusicBrainz labels; Copyright); Playback (Duration, Audio quality for the current song, On this device, Plays, Your plays from saved listening history, YouTube views, Language, Explicit); Identifiers (Recording ID with a 44-point Copy button that writes to `UIPasteboard.general`, ISRC, MusicBrainz link, Channel, Published, Open in YouTube Music); Description collapsed to 4 lines with Show more/Show less; states `player.details.loading`, unavailable with Retry (`player.details.retry`), and "Details need a connection." when offline without cache. The toolbar refresh button (`player.details.refresh`) passes `refresh: true`.
- Fixtures: under `--uitesting --seed-ui`, `DebugTrackDetailsFixture` (DEBUG only, audited out of Release through `tools/audit-release.py`) feeds the real `TrackDetailsStore` with a canned art-track description for "Tum Hi Ho" and nil for every other fixture song, with no network.

## APIs

| Symbol | Role |
| --- | --- |
| `TrackDetails` (`Sources/Core/TrackDetails.swift`) | Codable model: recording id, title, performers, credits (`Credit { role: CreditRole, names }`), album, release date and text, ℗/© lines, channel, published date, description, view count, ISRC, MusicBrainz id, sources, fetched date. `displayCredits`, `labelNames`, `creditSource`, `hasContent`, `fillMissing(from:)`, `addCredit`, `trimmedDescription`, `date(from:)`. |
| `TrackDetails.CreditRole` | `composer, lyricist, producer, arranger, musicPublisher, label, mixingEngineer, masteringEngineer, recordingEngineer, vocals, other(String)`; `title`, `sortRank`, `from(providerRole:)`. |
| `ProvidedToYouTubeDescriptionParser.parse(_:)` | Pure parser returning `ProvidedToYouTubeDescription?` (provider, title, artists, album, ℗/© lines, releasedOn, releaseDate, credits, `label`). |
| `YouTubeDataAPI.metadata(for:refresh:)` | Existing lookup; `Metadata` gains `description`, `channelTitle`, `publishedAt`, `viewCount`. `requestedParts` and `requestedFields` name the projection. |
| `YouTubePlayerDetailsClient` | Actor: `details(for:refresh:)`, `parse(_:videoID:)`, `request(videoID:clientVersion:timeout:)`. |
| `ArtistSpotlightMusicBrainz.recordingDetails(for:)` | Actor method returning `MusicBrainzRecordingDetails?`; static `recordingDetails(in:recordingID:)`, `followUp(for:parsed:)`, `addWorkCredits`, `preferredRelease`, `partialDate`. |
| `TrackDetailsProviding` / `TrackDetailsFetching` | Provider protocol used by the view (`MusicAppModel.songDetails`) and the fetcher protocol the store wraps. |
| `TrackDetailsService` | Actor combining the sources. |
| `TrackDetailsStore` | Actor cache: `details(for:refresh:)`, `fileName(for:)`, `fileURL(for:in:)`, `enforceFileLimit`, `defaultDirectory()`. |
| `PlayerSongDetailsView` | The page; `PlayerOptionsRoute.details`. |

## Network recipients and bounds

| Recipient | Endpoint | Sent | Bounds |
| --- | --- | --- | --- |
| Google (YouTube Data API) | `GET https://www.googleapis.com/youtube/v3/videos` | Recording id, restricted key, bundle id | Unchanged: 2 s, 256 KiB, 256-entry cache (12 h, missing 15 min), 4 lookups, quota/rate/credential backoff. Parts `snippet,contentDetails,statistics`; fields add `snippet(description,channelTitle,publishedAt)` and `statistics(viewCount)`. `refresh: true` spends one unit and recaches. |
| YouTube (InnerTube) | `POST https://www.youtube.com/youtubei/v1/player?prettyPrint=false` | `videoId`, WEB client context (`clientName WEB`, `clientVersion 2.20250925.01.00`, `hl en`, `gl US`), browser User-Agent | Ephemeral cookie-free session, no credentials, 8 s deadline, 1 MiB body cap enforced while receiving, 2 concurrent requests, identical lookups coalesce, 32-entry 15-minute memory cache, 429 honours `Retry-After` (default 60 s), other failures back off 15 to 60 s. Only used when the Data API cannot answer. |
| MetaBrainz (MusicBrainz) | `GET https://musicbrainz.org/ws/2/recording?query=...`, `/recording/<id>`, `/work/<id>`, `/release/<id>` | Cleaned title, up to 3 artist names, duration window, `User-Agent Breezy/1.0 (<contact URL>)` | Shared 1 request/second limiter and cooldowns, 3 s per request, 2 MiB cap, at most 3 requests per details fetch within a 12 s deadline, 128-entry details cache (24 h found, 15 min none). Data is CC0 / CC BY-NC-SA; the UI attributes it. |
| Device only | `Caches/Details/*.json` | Fetched `TrackDetails` | 500 files, oldest removed; entries above 256 KiB or describing another recording are discarded on read. Descriptions are clipped to 16 KiB of UTF-8. |

The description is provider text about a public upload; it is shown as received (trimmed) and never sent anywhere. No new identifiers, account data or listening history leave the device.

## Metrics

All OSLog, subsystem `com.agraabhi.ganabajana`, category `SongDetails`, format `event=<name> key=value`; no titles, ids or URLs.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=detailsLookup source hit refresh offline missingCached keptPrevious` | Every store lookup resolves | source `memory|disk|network|cache|none`, flags 0/1 | Cache effectiveness and offline behaviour |
| `event=detailsFetched outcome sources credits creditSource` | The service finishes a fetch | outcome `found|none`, counts, creditSource `youTubeDescription|musicBrainz|none` | Coverage of the feature per fetch |
| `event=detailsDescription artTrack credits source` | A YouTube description was read | artTrack 0/1, count, source `dataapi|player` | Art-track recognition rate |
| `event=detailsVideoLookup source outcome reason` | Each YouTube source is tried | source `dataapi|player`, outcome `success|missing|failed`, reason = `RequestError` case | Fallback frequency and failure classes |
| `event=detailsMusicBrainz matched credits failed` | MusicBrainz enrichment ends | 0/1, counts | Enrichment hit rate |
| `event=musicBrainzDetails matched requests credits isrc releaseDate` and `event=musicBrainzDetailsCache hit` | The MusicBrainz client completes or serves a details lookup | counts 0..3, flags | Request budget compliance |
| `event=playerDetailsRequest success status latencyMs descriptionFound cancelled rateLimited invalid` and `event=playerDetailsCache hit` | InnerTube player request completes or a cache decision is made | flags, status 200, milliseconds | Fallback health |
| `event=detailsDiskWrite ok evicted`, `event=detailsDiskRead ok` | Disk cache writes/reads | 0/1, eviction count | Disk bound enforcement |
| Existing `dataAPI*` counters | Unchanged Data API behaviour | see `docs/YOUTUBE_DATA_API.md` | Quota safety |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Full art track, missing album, missing release date with © and publisher, roles reordered with "&", compound DDEX roles and unknown roles, CRLF with blank lines, ordinary description and empty input return nil, Devanagari names, a real Radiohead sample | `ProvidedToYouTubeDescriptionParser.parse` | Unit (`SongDetailsParserTests`) |
| Role wording mapping, display sort, duplicate names, label separation | `CreditRole.from`, `displayCredits`, `addCredit` | Unit |
| Description wins, MusicBrainz fills gaps, sources union, credit source, JSON round trip, description clipping on scalar boundaries, date parsing | `TrackDetails.fillMissing`, Codable, `trimmedDescription`, `date(from:)` | Unit (`SongDetailsMergingTests`) |
| Memory hit, disk hit across instances, refresh recaches, failed refresh keeps facts, disk bound with oldest-first eviction, missing cached 15 min in memory only, offline uses files and never fetches, sanitised file names and foreign records discarded | `TrackDetailsStore` | Unit (`SongDetailsStoreTests`) |
| Recording/work relations, preferred release, ISRC, follow-up choice, work credit parsing, partial dates; end-to-end 3 rate-limited requests with headers and caching; ambiguity gives up after one request; non-YouTube ids still search | `ArtistSpotlightMusicBrainz.recordingDetails` | Unit with mock transport (`SongDetailsMusicBrainzTests`) |
| Player response parsing (description, author, views, publish date, foreign id, malformed), cookie-free WEB POST shape, cache and refresh, 429 backoff, oversized body, offline | `YouTubePlayerDetailsClient` | Unit with mock transport (`SongDetailsPlayerClientTests`) |
| Description credits skip MusicBrainz; quota failure falls back to the player and MusicBrainz fills credits, label, ISRC, id; JioSaavn id uses MusicBrainz only and empty results are nil | `TrackDetailsService.fetch` | Unit with mock transports (`SongDetailsServiceTests`) |
| Data API field projection, new snippet/statistics parsing, negative and blank values, refresh bypass | `YouTubeDataAPI` | Unit (`YouTubeDataAPITests`, extended) |
| Mini player to player to More to Song details; title, performer 44-point row, Composer/Lyricist/Producer values, Album, Released on (locale date), ℗ line, footer, Your plays, views, duration, language, Copy button size and label change, Open in YouTube Music, Show more, refresh, Back to Song options, Done | `PlayerSongDetailsView` | UI (`GanaBajanaSongDetailsUITests`) |
| Unavailable state and Retry for the second fixture song | `PlayerSongDetailsView` states | UI |
| Performer row closes sheet and player and lands on the artist page | Deferred-dismiss callbacks | UI |
| One live InnerTube request for `7374CZQoS2Y` recognised as an art track | `YouTubePlayerDetailsClient` | Live integration, `GANABAJANA_LIVE_TESTS=1` |

## Not verified

- Real Data API responses with the extended field projection (the restricted key is not present in test hosts); the projection was confirmed only against the documented API shape.
- Live MusicBrainz responses beyond one manual curl sample of the Tum Hi Ho recording (which confirmed the `artist-rels` requirement for work-level credits and that `labels` is not a valid recording inc).
- The offline "Details need a connection." state on device; unit tests cover the store's offline path only.
- iPad and Dynamic Type layouts of the page were designed (stacked rows at accessibility sizes) but not captured in this round's UI runs.
- Pasteboard contents after Copy: the UI test asserts the button's size and label change, not `UIPasteboard` (reading it from the runner can trigger the paste permission prompt).
