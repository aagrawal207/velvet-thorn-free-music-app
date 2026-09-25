# Music-app product research

**Public research checked 22 September 2026; Breezy source mapping updated 23 September 2026.** The ten sources below identify concrete complaints and existing competitor responses. They are qualitative evidence, not a survey, a ranking of the most common complaints or comparative bug rates. Breezy's R6/R7 implementation is unreleased; [VERIFICATION.md](VERIFICATION.md) records execution and remaining acceptance boundaries.

## Findings and current Breezy coverage

| Need | Public evidence | Breezy source now | Remaining choice |
| --- | --- | --- | --- |
| Less repetitive listening | YouTube Music users report narrow shuffle rotation [1]; Spotify already offers history-aware Fewer Repeats [2] | R7 adds optional seven-day Fewer repeats for new shuffle orders and a separate More familiar/Balanced/More new discovery control. Language adjustments remain independent | Repeats remain possible; eligible candidate pools and artist caps limit discovery targets |
| Find saved music quickly | Playlist-search demand led to a limited YouTube Music iOS test [3]; Apple Music users describe typo-sensitive search [4] | R6 searches liked songs/playlists locally by title, credited artists and album. Blank Search has live library shortcuts and typed Recently opened items | Provider search correction remains provider-dependent. This local filter is not a new fuzzy-search service |
| Preserve the queue deliberately | Apple Music queue management remains a concern in individual reports [4, 5]. YouTube Music queue sync exists but can replace another device's queue with the latest session [10] | R6 Queue Save captures current and upcoming songs once into an atomic playlist without replacing playback | Explicit device handoff is still a separate design decision; iCloud library sync excludes the active queue/position |
| Know what will work offline | Spotify documents download eligibility and reconnection rules [7]; user reports describe download/data-use confusion [4] | R6 exposes cached songs, local availability, removal and cache-first offline playback. Mixed queues can skip missing files while preserving occurrence order | A purgeable cache is not a managed, durable offline collection. Managed offline listening depends on the licensed-content decision |
| Control Home clutter | Spotify Community reports unwanted podcast recommendations [6] | Home already supports hidden/reordered sections, with Customize Home in Settings. Breezy's discovery is music-focused | No new Home-control feature is justified by treating this existing capability as missing |
| Understand feature gates | Editorial comparisons discuss pricing and service tradeoffs [8]; the reported YouTube Music lyrics restriction was a limited experiment [9] | Optional tips unlock no features or music. Lyrics matching, timing controls and available fallback text are not tip-gated | Missing source lyrics are availability/matching failures, not an app payment gate |

R6 implements saved-library search, typed reopen history, cache visibility/offline behavior and saving the remaining queue, with passing targeted workflows recorded in [VERIFICATION.md](VERIFICATION.md). [ARCHITECTURE.md](ARCHITECTURE.md) records those APIs; [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) records language weighting and its tests. Uploaded build 3 predates this work.

## Implemented listening controls

**R7 adds optional Fewer repeats.** [PlaybackShufflePolicy](../Sources/Playback/PlaybackShufflePolicy.swift) softly deprioritizes qualified listening from the last seven days when a new shuffle starts. A list Shuffle samples its first song and remainder together; toggling Shuffle during playback pins the selected occurrence. Ordinary Random remains available. Spotify's existing implementation [2] makes this an established expectation, not a novel feature claim.

The control reuses saved listening history and supplies no evidence while history is off. It keeps every occurrence, explicit choices and Repeat one; it does not promise a no-repeat guarantee. The saved choice and independently synced discovery preference grant no paid entitlement. [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md) owns the exact weights, persistence and tests.

**Discovery balance is separate from shuffle.** R7 offers More familiar, Balanced and More new for future mixes and new Home recommendations. Daily Mix targets 70%, 40% or 15% familiar songs when pools and artist caps permit; all modes classify provider-returned heard recordings consistently. Discover Weekly still excludes heard recording IDs while adjusting familiar-artist ranking. Saved period-stable mixes and active playback retain their selection.

## Larger product decisions

| Larger choice | Concrete question before implementation |
| --- | --- |
| Managed licensed offline listening | Which authorized catalog supports durable downloads, and what retention, removal and availability promises can Breezy make? Current cache visibility does not answer this |
| Explicit device handoff | Should a user transfer one playback session, or only copy its queue? Define confirmation and conflicts before allowing another device to replace active playback |

The existing [content-rights and FFmpeg release dependencies](app-store/RELEASE_STATUS.md#submission-hold) remain recorded in release documentation. Product research supplies no new authorization or delivery evidence.

## Sources

Dates below identify the article, post or inspected replies. A report about a test or rollout is not proof of current availability for every account, platform or country.

| # | Source and date | What it supports | Limit |
| --- | --- | --- | --- |
| 1 | [YouTube Music: “Shuffle plays the same songs”](https://www.reddit.com/r/YoutubeMusic/comments/1suisw9/shuffle_plays_the_same_songs/), 24 April 2026; replies through 26 April. Public RSS inspected | One listener reports hearing roughly 10–20 songs from a 400-song playlist; replies describe similar experiences and workarounds | Self-selected anecdotes, with differing results. No prevalence estimate or verified algorithm diagnosis |
| 2 | [Spotify Engineering: “Shuffle: Making Random Feel More Human”](https://engineering.atspotify.com/2025/11/shuffle-making-random-feel-more-human), 13 November 2025 | Official explanation of Fewer Repeats, using listening history to favor fresher orders | A documented competitor response, not evidence that every user prefers it or that ordinary shuffle is broken |
| 3 | [Android Authority: YouTube Music playlist search](https://www.androidauthority.com/youtube-music-playlist-search-3616240/), 16 November 2025 | Reporting on a limited iOS playlist-search test and the need to find songs inside playlists | Does not establish today's global rollout, Android coverage or universal absence |
| 4 | [Apple Music: “What are your biggest complaints with the mobile app?”](https://www.reddit.com/r/AppleMusic/comments/1ie0jd9/what_are_your_biggest_complaints_with_the_mobile/), 30–31 January 2025. Public RSS inspected | Specific search, queue and download/data-use complaints; some users prefer its interface over Spotify | Opinions differ, including reports that queue behavior improved. No representative sample or verified failure rate |
| 5 | [MacRumors: 2026 wishes, post #26](https://forums.macrumors.com/threads/what-do-you-want-to-see-from-apple-in-2026.2475468/page-2#post-34359478), 1 January 2026 | One account of confusing Apple Music queue sections and replacement behavior | Individual workflow feedback, not a platform-wide reliability finding |
| 6 | [Spotify Community: removing past podcast recommendations](https://community.spotify.com/t5/Your-Library/How-to-remove-and-stop-past-podcasts-from-being-recommended/td-p/5515197/page/7), thread started 4 March 2023; inspected replies October 2025–May 2026 | Continued requests to remove unwanted podcast recommendations | Long-running thread, not a count of unique affected users. Some replies report successful workarounds |
| 7 | [Spotify Support: Listen offline](https://support.spotify.com/us/article/listen-offline/), undated; checked 22 September 2026 | Official music-download eligibility and the requirement to connect at least every 30 days to retain downloads | Describes product mechanics, not the frequency of download failures |
| 8 | [CNET: Best music streaming service](https://www.cnet.com/tech/services-and-software/best-music-streaming-service/), updated 28 July 2026 | Editorial comparison of subscription pricing, catalog and feature tradeoffs | Reviewer judgment, not complaint research. Prices and offers vary by market and date |
| 9 | [PCMag: YouTube Music lyrics restriction](https://www.pcmag.com/news/cant-see-lyrics-on-youtube-music-youll-need-premium-now), updated 10 February 2026 | A reported lyrics gate and Google's clarification that it was an experiment with a small percentage of users | Must not be described as a universal lyrics paywall |
| 10 | [9to5Google: YouTube Music queue sync](https://9to5google.com/2026/01/25/youtube-music-queue-sync/), 25 January 2026 | Queue sync already exists; reported latest-session behavior can replace another device's queue | Reporting on observed rollout behavior, not proof of every device/account combination |

Some public community pages required RSS, and search/community access was incomplete. The sources support the examples above; they do not establish which service fails most often or which complaint ranks first.
