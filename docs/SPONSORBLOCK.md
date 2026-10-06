# SponsorBlock non-music skipping

R12 WP11. Off by default. Jumps the live player over community-marked non-music stretches of YouTube uploads: talk, intros, outros, sponsor reads, self-promotion, interaction reminders and previews.

## Purpose

Album-audio uploads are mostly clean, but many YouTube recordings carry a spoken intro, a long outro or a sponsor read. SponsorBlock's community marks those stretches per video. Velvet Thorn reads the markers for the song that is playing and seeks past them, so the listener hears the music and nothing else changes: the queue, the cache, the standby deck and listening history keep their contracts.

## Behaviour

- Settings > Playback > **Skip non-music sections** (`settings.sponsorBlock`) writes `UserPreferences.sponsorBlockSkipping` through `MusicAppModel.updatePreferences`; `applyPreferenceServices` fans it out to `PlayerController.setSponsorBlockSkipping(_:)`. Turning it off cancels a pending lookup and forgets the current song's segments and skip count.
- Only `track.source == .youTubeMusic` with a valid 11-character video id is looked up. JioSaavn, Gaana, fixture and local ids never leave the device.
- A lookup starts when a YouTube song becomes current and actually plays (`selectCurrent`, gapless or crossfade `activateStandby`). A paused restore or a browsed queue sends nothing until playback starts; known-offline playback never asks. Playback never waits for the lookup; a slow or failed answer means the song plays unskipped. A track change cancels the pending lookup and a late answer is rejected by token and queue-entry checks.
- Each 500 ms position tick asks `SegmentSkipper` whether the position lies inside `[start, end - 0.25]` of an unconsumed segment. The jump goes through the ordinary `performSeek` path, so the listening clock treats it as a seek (the jumped stretch is not credited), `lastSeekUptime` keeps the crossfade boundary observer honest, and playback generation checks still guard the completion. A segment ending at the recording's end finishes the item like any exact-end seek.
- Each segment skips once per play. A manual `seek(to:)` (player, Watch, CarPlay, previous-to-restart) opens a 10 s grace during which nothing skips, so a listener who seeks into a section hears it. A fresh play (new selection, standby swap, replay after the end through seek or retry) resets consumed segments and the grace.
- No skip during a crossfade blend or while an offline advance is pending; the standby deck is never pre-skipped. Only the live item is affected.
- The More sheet shows **Skipped n non-music sections** (`player.options.sponsorBlock`) for the current song while `sponsorBlockSkipCount > 0`. No toast, no timeline markers.

## Endpoint and privacy (hash-prefix lookup)

- `GET https://sponsor.ajay.app/api/skipSegments/<prefix>?categories=["music_offtopic","sponsor","selfpromo","intro","outro","interaction","preview"]&actionTypes=["skip"]`
- `<prefix>` is the first four hex characters of SHA-256 over the video id (k-anonymity). The service answers for every video sharing the prefix; Velvet Thorn picks the entry whose `videoID` matches and never reads the others. The service receives the prefix, the request headers, and the requester's IP address. It does not receive the video id, the account, cookies or any library data.
- Headers: `Accept: application/json`, `User-Agent: Breezy/1.0 (<MusicBrainzContactURL from project.yml>)`. The session is ephemeral: no cookies, no credential store, no URL cache.
- Response: `[{ videoID, segments: [{ category, actionType, segment: [start, end], UUID, votes, locked, videoDuration }] }]`. 404 means no video with that prefix has segments and is cached as an absence.
- Eligibility (`SponsorBlockSegments.usable`): `actionType == "skip"`, `votes >= 0` or `locked`, duration >= 1 s, category in the requested set, and no more than 80% of the recording (player duration first, the submission's `videoDuration` as fallback; unknown length skips the coverage rule). Overlapping and touching segments merge and keep the earliest category; at most 32 segments per video.
- Nothing is written to disk. The cache is in memory and dies with the process. No SponsorBlock data enters the library, iCloud replicas, widgets or companions.

## Bounds and caches

| Bound | Value |
| --- | --- |
| Request timeout | 6 s (`timeoutIntervalForRequest`, `PlaybackDeadline.run`), resource 12 s |
| Body cap | 256 KiB through `URLSession.boundedData`, enforced while receiving |
| Concurrent requests | 2 in flight; a third caller gets `RequestError.busy` |
| Positive cache | 24 h per video id, raw submissions; filtering runs per call so a later duration applies |
| Negative cache | 1 h per video id (404, or the video absent from its prefix batch) |
| Cache capacity | 256 video ids, least recently used evicted |
| Retry-After | 429 defers every request until the header's date or 60 s and throws `rateLimited`; other non-200/404 statuses defer 15 s (5xx) or 60 s (4xx); transport failures defer 15 s |
| Submissions read per video | 256 before filtering |
| Skipper end guard | 0.25 s |
| Manual seek grace | 10 s |

## APIs

- `Sources/SponsorBlock/SponsorBlockModels.swift`: `SponsorBlockCategory` (requested categories; `logValue` folds intro/outro/interaction/preview into `other`), `SponsorBlockSegment(start:end:category:)`, `SponsorBlockSubmission` (raw API row), `SponsorBlockSegments.usable(_:duration:)`.
- `Sources/SponsorBlock/SponsorBlockClient.swift`: `protocol SponsorBlockSegmentProviding { func segments(forVideoID:duration:) async throws -> [SponsorBlockSegment] }`; `actor SponsorBlockClient` with `init(session:configuration:contactURL:now:)`, `Configuration` (timeout, maximumBytes, maximumConcurrentRequests, cacheCapacity, positiveLifetime, negativeLifetime, categories), `RequestError` (`invalidVideoID`, `invalidResponse`, `unavailable`, `rateLimited`, `busy`), static `hashPrefix(for:)`, `request(videoID:categories:userAgent:timeout:)`, `parse(_:videoID:)`, `userAgent(contactURL:)`, `bundledContactURL`.
- `Sources/SponsorBlock/SegmentSkipper.swift`: pure `struct SegmentSkipper` with `install(_:)`, `restart()`, `noteManualSeek(uptime:)`, `skipTarget(at:uptime:) -> SponsorBlockSegment?`, `segments`, `skippedCount`.
- `PlayerController`: `setSponsorBlockSkipping(_:)`, observable `sponsorBlockSkipCount`, `sponsorBlockSegments`, replaceable `sponsorBlockProvider` (lazy live client; fixtures and tests inject their own). Private: `beginSponsorBlockPlay()`, `refreshSponsorBlockSegments()`, `applySegmentSkip(uptime:)` at the end of `tick()`.
- `MusicAppModel`: init applies the saved preference; `applyPreferenceServices` forwards changes.
- Fixtures: `--uitesting --seed-ui --sponsorblock-fixture` installs `DebugSponsorBlockFixture` (segment 3 to 8 s for the first fixture song) on the player before the model is created. `tools/audit-release.py` rejects `--sponsorblock-fixture` and `DebugSponsorBlockFixture` in Release binaries.

## Metrics

OSLog only, subsystem `com.agraabhi.ganabajana`. No identifiers, prefixes or positions are logged.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=sponsorblock_lookup status=ok\|none segments=<n> latencyMs=<ms>` (category `SponsorBlock`) | A network answer arrives: 200 with submissions (`ok`), 200 without this video or 404 (`none`) | status in {ok, none}; segments is the raw submission count (0 to 256) | Hit rate and service latency |
| `event=sponsorblock_lookup status=failed\|rateLimited cancelled=0/1 invalid=0/1 latencyMs=<ms>` (category `SponsorBlock`) | Transport failure, non-200/404 status, body cap, invalid JSON, cancellation | status in {failed, rateLimited}; flags 0/1 | Distinguish backoff from broken responses |
| `event=sponsorblock_cache hit=0/1` (debug, category `SponsorBlock`) | Every `segments(forVideoID:)` call | hit 0/1 | Cache effectiveness |
| `event=sponsorblock_setting enabled=0/1` (category `Playback`) | The preference changes on the player | 0/1 | Adoption |
| `event=sponsorblock_segments status=ok\|failed segments=<n>` (category `Playback`) | A lookup for the current song completes and installs its usable segments | status in {ok, failed}; segments 0 to 32 | How often a playing song has anything to skip |
| `event=sponsorblock_skip category=music_offtopic\|sponsor\|selfpromo\|other skipped=1` (category `Playback`) | The tick jumps past a segment | category folded to four values; skipped always 1 | Which categories the skipper acts on |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| SHA-256 prefix known vectors (`dQw4w9WgXcQ` -> `5f6b`, `fsiPzT50ZiM` -> `5192`) | `SponsorBlockClient.hashPrefix` | Unit (`SponsorBlockTests`) |
| Request path, categories, actionTypes, cookie-free, contact User-Agent, fallback User-Agent | `SponsorBlockClient.request`, `userAgent` | Unit |
| Parse picks the matching video, ignores the other prefix entries, rejects non-array JSON | `SponsorBlockClient.parse` | Unit |
| Filtering: mute dropped, downvoted dropped, locked negative kept, sub-second dropped, >80% dropped, unknown category dropped, overlaps merged, fallback `videoDuration`, shorter recording drops the merge | `SponsorBlockSegments.usable` | Unit |
| Merge order and 32-segment cap | `SponsorBlockSegments.usable` | Unit |
| 404 cached 1 h, segments cached 24 h, LRU count | `segments(forVideoID:)` cache | Unit with `CatalogMockSession` and `CatalogTestClock` |
| Video absent from its prefix batch is an absence; invalid id throws without a request | `segments(forVideoID:)` | Unit |
| 429 with Retry-After defers, oversized body defers, no repeat request | `fetch`, `deferRequests`, `boundedData` | Unit |
| Skipper inside/outside, end guard, NaN | `SegmentSkipper.skipTarget` | Unit |
| Once per play, `restart`, `install` clears consumed | `SegmentSkipper` | Unit |
| Manual seek grace 10 s, survives `install`, cleared by `restart` | `SegmentSkipper.noteManualSeek` | Unit |
| Injected segment [2, 5] on a 10 s file: position jumps, middle never observed, skip count 1, listening excludes the jump, no second skip | `PlayerController.applySegmentSkip`, `performSeek`, `PlaybackListeningClock` | Integration (native AVPlayer, local file) |
| Preference off: no lookup, no skip | `refreshSponsorBlockSegments` guard | Integration |
| JioSaavn id and dotted fixture id make no lookup; a valid YouTube id does | `refreshSponsorBlockSegments` source/id guard | Integration |
| Setting off cancels a held lookup; the late answer installs nothing | `clearSponsorBlockSegments`, task token | Integration |
| Paused restore sends nothing; playing starts the lookup; a manual seek into a segment is not skipped | `sponsorBlockPending`, `startPlayer`, grace | Integration |
| Settings row inventory (`settings.sponsorBlock`, switch, 44 pt, title) | `SettingsView` Playback | UI (`GanaBajanaListeningControlsUITests` inventory) |
| Fixture flow: enable, play Tum Hi Ho, pause and restart from 0 through Previous (a fresh play, so the grace does not apply), elapsed jumps from <=3 to >=8 within 12 s, the 4 to 7 s middle never shows, More sheet "Skipped 1 non-music section", choice survives relaunch | `DebugSponsorBlockFixture`, `previous()` restart, `PlayerOptionsSheet` row | UI (`GanaBajanaSponsorBlockUITests`) |

## Not verified

- No request to the live `sponsor.ajay.app` service was made in this round; the response shape follows the public API documentation and the parser is fixture-tested only. Real-world category quality for music uploads is unmeasured.
- Crossfade and gapless swaps with segments at the very start of the incoming song were reasoned about (no skip while `transition != nil`), not exercised end to end.
- Watch and CarPlay seeks reuse `seek(to:)` and so open the same grace; no companion test covers it.
- The Release audit markers were added; no Release archive was built to run `tools/audit-release.py` in this package.
- Runs: iPhone 17 Pro / iOS 26.5 simulator only (`artifacts/R13/WP11-PlaybackUnit-02.xcresult`, `artifacts/R13/WP11-UI-03.xcresult`). SE 3 and iPad were not run.
