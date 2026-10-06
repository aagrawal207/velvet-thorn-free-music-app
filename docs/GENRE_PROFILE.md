# Genre taste profile (R13 item 10)

R13 WP17. Shared docs (`ARCHITECTURE`, `PROVIDERS`, `PRIVACY`, `VERIFICATION`, `AGENTS`) are integrated at round end; until then this file owns the contract. The "Docs delta" at the end lists the facts those files need.

## Purpose

Velvet Thorn already learns which languages a listener plays ([SONG_LANGUAGES.md](SONG_LANGUAGES.md), [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md)). This package adds the same kind of tuner for genre: MusicBrainz genre and tag votes for the recordings and artists of qualified plays, folded into a bounded family taxonomy, summed over the last 30 days into `ListeningGenreProfile`, and used as a small ranking term in Home shelves, Daily Mix, Discover Weekly and the Search > Radio station order. A Recap "Top genres" card, a Settings > Discovery > Listening genres page with More/Automatic/Less nudges and a "Genres" row in Song details show the evidence. Adjustments change recommendations, never the recorded statistics.

## Taxonomy

`GenreFamily` (`Sources/Genres/GenreTaxonomy.swift`) has 29 cases and is the only genre dimension that metrics may carry:

| Family | Title | Typical MusicBrainz tags |
| --- | --- | --- |
| `bollywood` | Bollywood | bollywood, filmi, hindi film music, tollywood, kollywood |
| `indiePop` | Indie | indie, indie pop, indie rock, indie folk, dream pop, shoegaze, bedroom pop |
| `pop` | Pop | pop, synth pop, electropop, indipop, j pop, hyperpop |
| `hipHop` | Hip hop | hip hop, rap, trap, drill, desi hip hop, grime, boom bap |
| `rnb` | R&B and soul | r&b, soul, neo soul, funk, motown, new jack swing |
| `rock` | Rock | rock, alternative, hard rock, grunge, punk, post rock, new wave |
| `metal` | Metal | metal, heavy metal, death metal, metalcore, nu metal, djent |
| `electronic` | Electronic | electronic, edm, house, techno, trance, dubstep, drum and bass, synthwave |
| `dance` | Dance | dance, dance pop, disco, nu disco, eurodance |
| `lofi` | Lo-fi | lo-fi, lofi hip hop, chillhop, study beats |
| `jazz` | Jazz | jazz, bebop, swing, smooth jazz, fusion |
| `blues` | Blues | blues, delta blues, electric blues |
| `classical` | Classical | classical, orchestral, baroque, opera, chamber music, piano |
| `hindustani` | Hindustani classical | hindustani classical, khayal, thumri, dhrupad, raga, indian classical |
| `carnatic` | Carnatic | carnatic, kriti, varnam, south indian classical |
| `sufi` | Sufi | sufi, qawwali, kafi, sufi rock |
| `ghazal` | Ghazal | ghazal, urdu ghazal, nazm |
| `devotional` | Devotional | bhajan, kirtan, gurbani, shabad, aarti, gospel, worship, naat |
| `punjabi` | Punjabi | punjabi, bhangra, punjabi pop, punjabi hip hop |
| `folk` | Folk | folk, indian folk, rajasthani folk, bhojpuri, garba, bluegrass, americana |
| `country` | Country | country, country pop, honky tonk, alt country |
| `kpop` | K-pop | k pop, korean pop, k indie |
| `latin` | Latin | latin, reggaeton, salsa, bachata, bossa nova, cumbia |
| `reggae` | Reggae | reggae, dancehall, dub, ska |
| `soundtrack` | Soundtrack | soundtrack, film score, video game music, musical |
| `instrumental` | Instrumental | instrumental, instrumental rock, guitar instrumental |
| `acoustic` | Acoustic | acoustic, singer songwriter, unplugged |
| `ambient` | Ambient | ambient, new age, meditation, chillout, lounge |
| `world` | World | world, afrobeats, amapiano, arabic pop, chanson, fado |

`GenreTaxonomy.table` maps 784 normalised tag spellings (well above the 200 the design asked for) to families. `normalize` lowercases, folds diacritics and width, and turns every punctuation run into one space, so "Hip-Hop", "hip hop", "HipHop" (own row), "R&B" ("r b") and "Reggaetón" resolve the same way. Unknown tags map to nothing. Mood and era words ("romantic", "sad", "party", "90s") are deliberately absent: era exists elsewhere (`RadioEra`) and moods are not genres. `GenreTaxonomy.version` (1) is stored in the evidence file; a bump drops the cached distributions so recordings are reclassified lazily within the normal budgets.

## Evidence sources and budgets

`GenreEvidenceLoader` (`Sources/Genres/GenreClassifier.swift`) classifies the distinct recordings with a qualified play in the last 30 days, most recent first, using the recap's own qualification (30 seconds, or half of a song shorter than a minute; valid dates, tracks and sessions). Classification runs one recording at a time on MusicBrainz's shared one-request-per-second limiter (`MusicBrainzRateLimiter.shared`).

| Bound | Value |
| --- | --- |
| MusicBrainz requests per recording | At most 3: search, recording lookup, one follow-up |
| Classifications per app session | 60 (attempts, including failures) |
| Attempts per recording | Once per session; a transport failure is not cached and is retried in a later session |
| Start | Never within 10 s of launch, never while known offline, only with device services active and listening history on |
| Negative result lifetime | 30 days (`GenreDistribution.unclassified` with `source=none`) |
| Positive result lifetime | Until LRU eviction |
| Artist evidence lifetime | 30 days per MusicBrainz artist MBID, reused by every song of that artist |

Per recording, `GenreClassifier.plan` and `finish` decide in this order:

1. `recording/<mbid>?inc=artist-credits+releases+release-groups+genres+tags` (after the same title/artist/duration search the language and details lookups use; JioSaavn and Gaana ids search the same way because MusicBrainz is source-agnostic). Recording `genres` plus `tags` win when any vote maps to a family.
2. Embedded release-group votes (present when MusicBrainz includes tag lists on the sub-entity) when the recording had none.
3. Embedded or cached artist votes for the credited artists, in credit order.
4. One follow-up request: `artist/<mbid>?inc=genres+tags` for the first credited artist without cached evidence (its answer is cached 30 days and settles that artist's other songs for free), otherwise `release-group/<mbid>?inc=genres+tags` when the release group was not embedded. Nothing left: the recording is unclassified for 30 days.

A Song details fetch (WP4) now requests `+release-groups+genres+tags` on its recording lookup and stores the votes in `MusicBrainzRecordingDetails.genres`; while that 24-hour details cache entry is alive, `recordingGenres(for:)` answers from it with zero requests, and a cached details miss is a zero-request genre miss.

Votes are weighted by their MusicBrainz `count` (at least one each), summed per family within one source, normalised, cut to the top three families and renormalised so a play always distributes one unit across its families (`GenreDistribution`). Tag lists are capped at 12 votes per entity.

## Profile weighting

`ListeningAnalytics.genreSummary` projects the existing recap: for every recording with a qualified play in the window, its plays multiply into its family shares. Plays without evidence stay in the total, so `coverage = classifiedPlays / totalPlays` is honest; displayed shares divide the classified plays, so bars sum to 100 percent.

`ListeningGenreProfile` (`Sources/Genres/ListeningGenreProfile.swift`) mirrors `ListeningLanguageProfile` over the last 30 days:

```text
base weight = 0.9 * family plays / classified plays + 0.1 / number of observed families
More        = max(0.2, 2 * base weight)        (activates an unheard family at 0.2)
Less        = 0.25 * base weight               (never activates an unobserved family)
```

Weights are normalised after nudges; `orderedFamilies` sorts by weight with taxonomy order as the tie-break; `topFamilies` is the first three. The profile is unlearned until a classified qualified play exists, in which case every multiplier is exactly 1. `requestKey` (`genres-v1|learned|coverage:<tenth>|<top three in 5 percent buckets>|<non-automatic nudges>`) changes Home's cache identity only when the picture changes, not on every classified song.

Nudges live in `UserPreferences.genreNudges: GenreNudges` (`Sources/Genres/GenreNudges.swift`), reusing the language `LanguageRecommendationNudge` cases as `ListeningNudge`. Every family encodes as its own `genreNudges/<family>` leaf, so iCloud library sync treats each as an independent register like `languageNudges/hindi`; unknown families and unreadable values decode to Automatic, and the sync round trip refuses a remote value the lenient decoder would rewrite.

## Where it is used

| Surface | Term | Weight |
| --- | --- | --- |
| Home shelves (`becauseYouListen`, `languageDiscovery`) | `Candidate.weighted(byGenres:mix: false)` multiplies the score by `1 + 0.15 * (weight of the dominant family / top weight)`; a Less family gets 0.85; no evidence stays at 1 | 1.0 to 1.15, so it reorders near ties but cannot beat the 1.5x familiarity tier or the 0.6 to 2.0 language range |
| Daily Mix clustering | `distribution(for:)` shares give each artist a family profile for `TasteClustering` ([DAILY_MIXES.md](DAILY_MIXES.md)); unclassified recordings contribute no genre feature | Genre overlap weight 0.4 of the similarity |
| Daily Mix, Discover Weekly | `mixMultiplier`: neutral until at least 40 percent of the last 30 days' plays are classified, then the same term for candidates whose dominant family is in the top three (or nudged Less); artist caps and dislikes unchanged | Gate 0.4, weight 0.15 |
| Search > Radio grid | `ExperienceRadioEngine.orderedStations`: within each group, stations whose `genreFamilies` have a positive weight move to the front in descending affinity; every other station keeps its curated order behind them; station content unchanged | Ordering only |
| Settings > Discovery | "Listening genres" row (`settings.genres`), value = top family or "Learning"; `ListeningGenresView` with coverage, family bars (`genres.family.<family>`), nudge menus (`genres.nudge.<family>`), "Tune other genres" for unplayed families, Reset | |
| Recap | "Top genres" card (`recap.genres`) with the top five families of the selected 7/30/365-day window, placed directly above Listening languages; hidden when nothing in the window is classified | |
| Song details | "Genres" row in the Playback group (`player.details.genres`) with footer "Genres from MusicBrainz" | |

Station families: Rap and hip hop `hipHop`; Rock `rock`; Alt rock `rock, indiePop`; Indie `indiePop`; Pop `pop`; R&B and soul `rnb`; Dance and EDM `dance, electronic`; Lo-fi `lofi`; Acoustic `acoustic`; Jazz `jazz, blues`; Classical and instrumental `classical, hindustani, carnatic, instrumental`; Folk `folk`; Sufi and Qawwali `sufi`; Ghazal `ghazal`; Punjabi hits `punjabi`; Bollywood classics `bollywood`; Metal `metal`; Country `country`; Reggae `reggae`; Devotional (mood) `devotional`. Golden oldies, 90s and the other moods carry none.

A Home "More <family>" shelf was out of scope and is not implemented.

## Storage

`GenreEvidenceStore` (`Sources/Genres/GenreEvidenceStore.swift`) keeps `Application Support/GanaBajana/genres.json`: `{version: 1, taxonomyVersion: 1, recordings: [...], artists: [...]}`. Recording records hold the metadata-aware `LyricsRequestKey` (recording id plus normalised title, artists, album and duration, like the language cache), the distribution (families with shares and the source), `checkedAt`, an optional `expiresAt` and `lastUsedAt`; artist records hold the MusicBrainz artist MBID, distribution and the same dates. Bounds: 5,000 recordings and 2,000 artists, least recently used first (every refresh marks the current 30-day snapshot as used). Writes are atomic, coalesced 2 s after a change, protected until first unlock, capped at 6 MiB on read; malformed records and unknown families are dropped individually, a newer format or taxonomy version starts over. The file is device-local: not part of iCloud library sync, kept in Application Support rather than the purgeable Caches folder the language cache uses, and deleted when listening history is cleared (its keys name played recordings). Fixture and unit hosts use a memory-only store; `--uitesting --seed-ui --genre-fixture` seeds Tum Hi Ho as Bollywood and Blinding Lights as Hip hop through `DebugGenreFixture` (DEBUG only, audited out of Release).

## APIs

| Symbol | Role |
| --- | --- |
| `GenreFamily`, `GenreVote`, `GenreTaxonomy.normalize/family(forTag:)/distribution(votes:source:)/table/version` | Taxonomy and vote folding |
| `RadioExperience.genreFamilies` | Station family hints (extension keyed by `stationID`) |
| `GenreEvidenceSource`, `GenreShare`, `GenreDistribution` | Evidence values; lenient Codable |
| `GenreRecordingRecord`, `GenreArtistRecord`, `GenreEvidenceSnapshot`, `GenreEvidenceDisk` | File format and disk actor |
| `GenreEvidenceStore` | Main-actor observable store: `distributions`, `revision`, `load()`, `distribution(for:)`, `needsClassification`, `artistDistribution(id:)`, `record`, `recordArtist`, `touch`, `reset`, `flush`, `snapshot` |
| `GenreMetadataProviding`, `MusicBrainzRecordingGenres`, `MusicBrainzGenreLookup` | Provider protocol the classifier consumes; `ArtistSpotlightMusicBrainz` conforms (`recordingGenres(for:)`, `releaseGroupGenres(id:)`, `artistGenres(id:)`, `recordingGenres(in:recordingID:)`, `votes(in:)`) |
| `MusicBrainzRecordingDetails.genres`, `ArtistSpotlightMusicBrainz.recordingDetailsInc` | WP4 details lookup extended with `+release-groups+genres+tags` |
| `GenreClassifier.plan/finish`, `GenreEvidenceLoader` | Decision logic and the bounded session queue (`refresh`, `pause`, `reset`, `waitForChecks`, `isChecking`, `classifiedThisSession`, `pendingCount`) |
| `GenreListeningStat`, `ListeningGenreSummary`, `ListeningAnalytics.genreSummary` | Period aggregation |
| `ListeningGenreProfile` | Weights, `multiplier(for:)`, `mixMultiplier(for:)`, `affinity(for:)`, `topFamilies`, `qualifiesForMixBoost`, `requestKey` |
| `ListeningNudge`, `GenreNudges`, `UserPreferences.genreNudges` | Preferences |
| `RecommendationEngine.applyingGenres`, `Candidate.weighted(byGenres:mix:)`, `genreProfile:` parameters on `discoverWeekly`, `dailyMix`, `becauseYouListen`, `languageDiscovery` | Ranking |
| `ExperienceRadioEngine.orderedStations(_:genreProfile:)` | Station ordering |
| `MusicAppModel.genreEvidence`, `genreClassification`, `listeningGenreProfile`, `listeningGenreSummary(for:now:)`, `refreshListeningGenres()`, `setGenreNudge`, `resetGenreNudges`, init parameters `genreEvidence:` and `genreMetadata:` | Model wiring; `radioExperiences` is affinity-ordered |
| `ListeningGenresView`, Recap `topGenres`, Song details `genres` row | UI |

## Metrics

OSLog, subsystem `com.agraabhi.ganabajana`, categories `Genres` (store, loader, ranking) and the existing `Recommendations`/`SongDetails`. Values are bounded enums or counts; no titles, ids or tags.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=genre_classified source families requests` | A recording's classification is recorded | `source` in `recording, releaseGroup, artist, none`; counts 0..3 | Evidence source mix and request cost per song |
| `event=genre_classify_failed` | A lookup threw (not cancellation) | none | Transport failures are retried next session, never cached |
| `event=genre_pass completed failed pending session` | A classification pass ends | counts | Budget use per session and remaining backlog |
| `event=genre_profile coverage top` | The model rebuilds a profile whose request key changed | `coverage` 0..100, `top` a family raw value or `none` | Learning progress without listening details |
| `event=genre_rank_applied candidates mix` | A ranking operation applied the genre term | count of candidates with evidence, `mix` 0/1 | Shows how often the term actually moves anything |
| `event=genre_store_load outcome recordings artists`, `event=genre_store_save ok recordings artists` | Disk read or write completes | `outcome` in `missing, loaded, taxonomy_changed`; counts, 0/1 | Bound compliance and durability |
| Existing `musicBrainzRequestSuccess/Failure`, `event=musicBrainzDetails ...` | Unchanged MusicBrainz transport and details paths | see `SONG_LANGUAGES.md`, `SONG_DETAILS.md` | Shared limiter health |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `GenreTaxonomyTests.testSampleTagsMapToFamiliesAndUnknownOrMoodWordsMapToNothing` | 35 sample tags including filmi, bhangra, qawwali; moods, eras and unknown tags map to nothing; table size and unique titles | Unit |
| `GenreTaxonomyTests.testNormalisationMakesPunctuationCaseAndDiacriticVariantsAgree` | Hip-Hop / hip hop / HipHop, R&B, Lo-Fi, Reggaetón, drum 'n' bass | Unit |
| `GenreTaxonomyTests.testVotesAreNormalisedPerSourceAndKeepTheTopThreeFamilies` | Count weighting, top three, renormalisation, zero counts | Unit |
| `GenreEvidenceTests.testRecordingGenresWinOverEmbeddedReleaseGroupAndArtistVotes` | Recording votes settle; embedded artist votes cached free | Unit, canned JSON |
| `GenreEvidenceTests.testEmbeddedReleaseGroupGenresFillInWhenTheRecordingHasNone` | Release-group fallback | Unit |
| `GenreEvidenceTests.testArtistFallbackUsesTheCacheFirstAndSpendsTheThirdRequestOnAnUnknownArtist` | Cached artist, artist follow-up, bare artist remembered | Unit |
| `GenreEvidenceTests.testKnownArtistWithoutGenresSendsTheFollowUpToTheReleaseGroupAndNothingEndsUnclassified` | Release-group follow-up, unclassified, budget of three | Unit |
| `GenreEvidenceTests.testLiveShapedLookupStaysWithinThreeRateLimitedRequestsAndReusesADetailsMatch` | Search + recording + artist through the real client, inc parameters, User-Agent, details-cache reuse with zero requests | Unit with mock transport |
| `GenreEvidenceTests.testStoreKeepsFiveThousandRecordingsAndTwoThousandArtistsByLastUse` | LRU eviction, touch, artist lifetime | Unit |
| `GenreEvidenceTests.testNegativeResultsExpireAfterThirtyDaysWhilePositiveOnesStayUntilEvicted` | Expiry rules | Unit, controlled clock |
| `GenreEvidenceTests.testStorePersistsAVersionedFileDecodesLenientlyAndResetDeletesIt` | File format, relaunch reuse, unknown family and malformed record, taxonomy bump, reset | Unit, local file |
| `ListeningGenreProfileTests.testSummarySpreadsPlaysOverFamiliesAndReportsHonestCoverage` | Share spreading, coverage denominator | Unit |
| `ListeningGenreProfileTests.testProfileUsesTheThirtyDayWindowWithTheRecapQualification` | 30-day window, 30 second threshold, year window | Unit |
| `ListeningGenreProfileTests.testMoreDoublesAndLessQuartersWeightsWhileStatisticsStayUntouched` | Nudge arithmetic, unheard More at 0.2, unchanged summary | Unit |
| `ListeningGenreProfileTests.testNudgesEncodeEveryFamilyAsItsOwnSyncRegisterAndDecodeLeniently` | `genreNudges/<family>` leaves, sync refusal of rewritten values, lenient decode | Unit, sync codec |
| `ListeningGenreProfileTests.testRapHeavyProfileLiftsHipHopAboveAnEqualPopCandidateWithoutBeatingLanguageOrDislikes` | 1.15 vs 1.0 reorder, neutral unknown, language preference wins, Less at 0.85 | Unit |
| `ListeningGenreProfileTests.testBecauseYouListenRanksHipHopFirstOnlyWithAGenreProfileAndNeverShowsDislikes` | End-to-end shelf ranking through the engine and a mock catalog | Unit, fake catalog |
| `ListeningGenreProfileTests.testMixBoostWaitsForFortyPercentCoverageAndThenLiftsOnlyTopThreeFamilies` | 38 vs 40 percent gate, top-three restriction, Less in mixes | Unit |
| `ListeningGenreProfileTests.testRadioStationsWithAffinityMoveToTheFrontOfTheirGroupAndTheRestKeepTheirOrder` | Station ordering per group, unlearned keeps curated order | Unit |
| `ListeningGenreProfileTests.testRecapAggregatesTheSelectedPeriod` | Week, month, year aggregation | Unit |
| `GenreEvidenceLoaderTests.testSixtyClassificationsPerSessionOncePerRecordingAndNoneWhileOffline` | 60 per session, once per recording, unqualified skipped, disabled classifies nothing | Unit, fake provider |
| `GenreEvidenceLoaderTests.testFailuresAreNotCachedAndAFreshSessionRetriesOnlyTheMissingRecordings` | Failure handling across sessions | Unit |
| `GenreEvidenceLoaderTests.testPauseStopsTheQueueAndArtistEvidenceIsReusedAcrossSongs` | Artist reuse, pause | Unit |
| `GanaBajanaGenreProfileUITests.testListeningGenresListsFamiliesWithBarsAndAHipHopNudgePersistsAcrossRelaunch` | Settings row value, coverage line, bars, native nudge menu, relaunch persistence, reset | Fixture UI |
| `GanaBajanaGenreProfileUITests.testRecapShowsTopGenresDirectlyAboveListeningLanguagesAndHidesWithoutEvidence` | Card position, shares, year window, navigation, hidden without evidence | Fixture UI |
| `GanaBajanaGenreProfileUITests.testSongDetailsShowTheGenresRowWithItsMusicBrainzSource` | Genres row and footer | Fixture UI |
| `GanaBajanaListeningControlsUITests.testIconLabeledSettingsKeepSixSectionsAndNativeTargetsAtLargestTextSize` | Settings inventory including `settings.genres` | Fixture UI |

Runs on the dedicated iPhone 17 Pro / iOS 26.5 simulator `R13-WP17`, Debug, `artifacts/R13/DerivedData-WP17`: `WP17-GenreUnit-02.xcresult` (23 passed), `WP17-Regression-01.xcresult` (292 passed across the language, recommendation, taste, familiarity, radio, sync and persistence classes), `WP17-GenreUI-01.xcresult` (3 run, 2 passed, the recap case failed on a stale scroll position and was corrected), `WP17-GenreUI-02.xcresult` (5 passed: the corrected recap case, the Settings inventory case and `GanaBajanaRecapReviewUITests`).

## Not verified

- Live MusicBrainz responses: whether `inc=genres+tags` also embeds tag lists on artist-credit artists and release groups was not probed; the code accepts both shapes and spends the one follow-up request when they are absent.
- Live effect of `+release-groups+genres+tags` on the Song details lookup (documented as valid recording subqueries and misc includes; no live details run in this package).
- iPad and largest Dynamic Type layouts of `ListeningGenresView` and the Recap card were designed (stacked rows at accessibility sizes) but not captured.
- OSLog emission is not asserted by tests.
- Real-world coverage rates and how quickly 60 classifications per session fill a listener's month.

## Docs delta

- `PRIVACY.md`: MusicBrainz now also receives `inc=genres+tags` (and `release-groups`) on recording lookups and, for at most one follow-up per song, an artist or release-group MBID lookup; still no account data, listening history or lyrics. A new device-local file `Application Support/GanaBajana/genres.json` stores genre families per played recording and per MusicBrainz artist; it is not synced through iCloud library sync, is bounded (5,000 recordings, 2,000 artists) and is deleted when listening history is cleared.
- `PROVIDERS.md`: MusicBrainz request recipe for genres (search, `recording/<id>?inc=artist-credits+releases+release-groups+genres+tags`, one `artist/<id>?inc=genres+tags` or `release-group/<id>?inc=genres+tags`), 3 requests per recording, 60 classifications per app session, shared 1 req/s limiter, negative cache 30 days, artist cache 30 days; the details lookup's `inc` grew by `+release-groups+genres+tags`. Non-CC0 supplementary data (genres) is now read, which MetaBrainz's 2026-09-25 reply permits under the supporter arrangement; the acknowledgement already names MusicBrainz.
- `ARCHITECTURE.md`: `Sources/Genres/` (taxonomy, store, classifier and loader, profile, nudges), `UserPreferences.genreNudges`, `MusicAppModel.genreEvidence/genreClassification/listeningGenreProfile`, engine `genreProfile:` parameters, `ExperienceRadioEngine.orderedStations`.
- `LISTENING_DISCOVERY.md`: the genre term (1.0 to 1.15, Less 0.85, unclassified 1) composes with the language multiplier and familiarity tier; mixes gate at 40 percent coverage; radio station order follows affinity.
- `SONG_DETAILS.md`: Playback group gains a "Genres" row with footer "Genres from MusicBrainz"; `recordingDetailsInc` and `MusicBrainzRecordingDetails.genres`.
- `VERIFICATION.md`: the runs listed above; `tools/audit-release.py` now rejects `--genre-fixture` and `DebugGenreFixture` in Release.
- `AGENTS.md` provider contract: `ListeningGenreProfile` learns from the same qualified plays; nudges change weights, never statistics; families are the bounded metrics dimension; no MusicBrainz tag or id in logs.
