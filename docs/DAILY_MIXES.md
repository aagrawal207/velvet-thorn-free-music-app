# Daily Mixes

**R14 item 19, WP27, 26 September 2026.** Home's Made for You grid shows Discover Weekly first and up to three Daily Mixes after it, all on screen without horizontal scrolling. Each Daily Mix is built around a different taste cluster (a group of artists sharing genre family, recording language and listening sessions) and names its focus beside its collage.

## Behaviour

- Order in the grid, in reading order: Discover Weekly, Daily Mix 1, Daily Mix 2, Daily Mix 3 (`mix.mix.discoverWeekly`, `mix.mix.dailyMix`, `mix.mix.dailyMix2`, `mix.mix.dailyMix3`; Play controls `mix.play.mix.<kind>`; the grid container is `home.mixes`). The section keeps the `madeForYou` Home section id, so Customize Home order and visibility work unchanged.
- The grid never scrolls sideways and stays inside the column on wide iPads. `HomeShelfMetrics.mixGridColumns` gives two columns on phones (2 by 2) and four in one row across an iPad column, halved while a card would be narrower than 160 points (a narrow regular window shows 2 by 2, Slide Over one column), and one column at accessibility sizes. Fewer mixes fill rows left to right. Cards are `mixCardWidth` wide with 10-point gaps, and each row takes its tallest card's height.
- Each card is the shared `MixTile` at the grid's card width (176 points on an iPhone 17 Pro): the square collage under the mix's tint gradient, then the name and focus line below it at the card's full width, each up to two lines (three at accessibility sizes). Cards in a row stretch to the tallest neighbour (`fillsRowHeight`), rows sit 18 points apart (`mixGridRowSpacing`) and columns 10. Play (`mix.play.<id>`) is the tile's 44-point glass control at the collage's top-trailing corner, announced as a button; the card opens the mix page and keeps the Play and Shuffle context menu. Tints: Discover Weekly violet, Daily Mix 1 the app accent, Daily Mix 2 gold, Daily Mix 3 teal (ocean when the accent is teal). The caption is the cluster focus: a genre family title ("Hip hop") when one family dominates, otherwise the strongest artists ("Arijit Singh, Pritam and more").
- The detail page subtitle reads "<focus> · Fresh every day · Made on this device from your listening".
- With too little history the grid shows fewer Daily Mixes rather than near-duplicates. One cluster (or none that qualifies) produces exactly today's single Daily Mix as Daily Mix 1, with its seed-artist caption.
- All three mixes share one period key (the calendar day). A current-period Daily Mix 1 is never regenerated; `MusicAppModel.dailyMixes` only shows Daily Mix 2 and 3 when they carry Daily Mix 1's period. A recording appears in at most one Daily Mix. Dislikes are excluded from every mix and pruned from saved ones.
- A super liked song ([SUPER_LIKES.md](SUPER_LIKES.md)) counts more: `TasteProfile.superLikeBoost` (540, three likes) credits it and its artists in the affinity that clustering and ranking read, and each Daily Mix leads its familiar pool with one eligible super like from its scope, rotating by day key. A scope without super likes is unchanged. Discover Weekly stays unheard-only.

## Clustering

`TasteClustering.clusters(_:)` (`Sources/Recommendations/TasteClustering.swift`) is pure and runs on device over the existing `TasteProfile`.

| Step | Rule | Numbers |
| --- | --- | --- |
| Evidence | Heard recordings with affinity (decayed qualified plays, likes, playlists), minus dislikes and unusable audio; each recording's weight counts for every credited artist. Language from `ListeningLanguageProfile.language(for:)`, else verified Hindi/English metadata. Genre from `ListeningGenreProfile.distribution(for:)` shares where classified. Sessions from `TasteProfile.sessionArtists`. Follows add a boost to an artist that already has weight | Sessions: qualified plays in the last 30 days, split after a 30-minute gap, newest 300 kept. Follow boost 60 (a playlist add) |
| Candidates | Strongest artists by weight | 24 |
| Similarity | Weighted mean of the available overlaps: genre distribution overlap, language distribution overlap, shared sessions / the smaller session count. A missing feature on either side drops out of the mean | Genre 0.4, language 0.3, sessions 0.3 |
| Seeding and assignment | Artists in weight order join the most similar cluster at or above the threshold, else seed a new one; once the seed limit is reached, join the best positive match or stay out | Threshold 0.5, at most 6 seed clusters |
| Merge | Two clusters merge when recordings crediting both carry more than half the smaller cluster's weight, or their aggregate similarity reaches the threshold | 0.5 |
| Ownership | A recording belongs to the cluster of its strongest credited artist | |
| Keep | Clusters with at least 4 owned recordings and 15 percent of total weight, strongest first; fewer than two such clusters yield one cluster (the fallback) | At most 3 |
| Focus | Genre title when the family holds at least 60 percent of the cluster's classified weight, genre evidence covers at least half the cluster's weight and no other kept cluster has the same family; else `GeneratedPlaylist.artistSummary` of the two strongest artists | 120 UTF-8 bytes |

Worked example (the unit fixture): two Hindi Bollywood artists and two English hip hop artists, three recordings each, played in separate sessions. Hindi pairs score 1.0 (same family, language and sessions); a Hindi and an English artist score 0.0. Result: two clusters of six recordings named "Bollywood" and "Hip hop".

## Mix building

`RecommendationEngine.dailyMixes(profile:periodKey:languageProfile:familiarity:genreProfile:followedArtistKeys:)` (`Sources/Recommendations/DailyMixes.swift`):

1. Fewer than two clusters: call the unchanged `dailyMix(...)` and return it as Daily Mix 1.
2. Otherwise build one `MixScope` per cluster and call `scopedMixes`. Kinds are renumbered so a skipped middle cluster never leaves a gap.

`scopedMixes(profile:scopes:periodKey:languageProfile:familiarity:genreProfile:fallbackKind:)`:

- Seeds split the single-mix budget: four recording radios and three artist pages, an even quota per scope with the remainder to the strongest and unused slots spilling to later scopes; related-artist fan-out keeps its cap of `providerCallBudget - seeds` (at most 3). Total provider calls stay at most 10 for all three mixes. One of the four recording seeds is reserved for an eligible super liked recording (recommendable, not disliked) whenever one exists: `RecommendationEngine.Seeds.init(profile:languageProfile:periodKey:)` and `scopedSeeds(..., periodKey:)` rotate the pick by period key through `jitter(periodKey:id:)`, and the scoped variant places it in the scope that owns the song.
- `gather` accumulates each response into the global candidate map and into the producing scope's map (`Harvest.scoped`).
- A provider candidate belongs to the scope owning one of its credited artists; otherwise to the scope whose seeds scored it highest.
- Each scope then applies the existing Daily Mix rules through `rankedMixCandidates` (dislikes, audio-only, language soft ranking, gated genre multiplier, period jitter) and `composeDailyMix` (familiarity target 18/10/4 of 25, heard versus unheard by `TasteProfile.heardTrackIDs`, one eligible super like from the scope at the head of the familiar pool, rotating by day key and counted within the familiar share and the artist cap, reserved unheard artist capacity, artist cap 3, familiar top-ups, interleaving). Songs excluded by another mix, disliked or not recommendable are skipped for that head pick. Scopes pick in order and later scopes exclude recordings already chosen.
- A scope below `minimumPlaylistSize` (8) is skipped. If fewer than two mixes remain and `fallbackKind` is set, the result is one whole-profile mix from the same harvest (no extra requests).

The single `dailyMix(...)` now calls the same two helpers with an unrestricted pool, so its output is byte-identical to before.

### Hooks for moment mixes (R14 item 21)

A later Commute or Gym Mix reuses the pipeline without touching the Daily Mix code:

- `TasteClustering.Input.trackWeight` weights each heard recording before clustering (for example its share of plays in a car audio route); 0 removes it.
- `MixScope(kind:focus:artistKeys:trackIDs:includes:weight:)` describes one mix. Empty `artistKeys` and `trackIDs` make an open scope over the whole profile; `includes` is a hard filter on heard recordings and provider candidates; `weight` multiplies familiar weights and candidate scores (non-positive drops).
- `scopedMixes(... fallbackKind: nil)` builds any number of scopes from one bounded harvest and guarantees disjoint recordings across them. A moment mix adds its own `GeneratedPlaylistKind` case and period key.

## Identity and migration

`GeneratedPlaylistKind` gains `dailyMix2` and `dailyMix3`. The existing `dailyMix` case keeps its raw value `"dailyMix"` and is Daily Mix 1 (`GeneratedPlaylistKind.dailyMix1` is an alias), so saved libraries, iCloud registers (`mix/dailyMix`), widget configurations and `ganabajana://widget/mix?kind=dailyMix` links resolve unchanged. `GeneratedPlaylistKind(identifier:)` also accepts `"dailyMix1"`; widget selections and routes parse through it. Titles are "Daily Mix 1", "Daily Mix 2", "Daily Mix 3" (formerly "Your Daily Mix"; widgets said "Daily Mix").

`GeneratedPlaylist.focus` is optional and encoded only when present, so older saved mixes decode and a mix without a focus keeps the exact legacy JSON shape. Widget projections drop it along with seed artists. `LibraryStore.saveDailyMixes(_:)` writes one period's Daily Mixes in a single commit, replacing all Daily Mix kinds so a thinner day removes yesterday's Daily Mix 2 and 3; a saved current-period Daily Mix 1 is kept.

Widgets: the Mix configuration lists Daily Mix 1, Daily Mix 2, Daily Mix 3 and Discover Weekly (`MixWidgetOptions.kinds`); an unset or unknown selection shows Daily Mix 1. The snapshot carries up to four mixes (`WidgetLibrarySnapshot.maximumMixes = 4`). CarPlay and the Watch list no generated mixes (their lists are Favorites, Recently played, Playlists and Queue), so nothing changes there.

## Background refresh

`MixRefreshRegistration` (`Sources/App/MixRefreshRegistration.swift`) registers the `BGAppRefreshTask` `com.agraabhi.ganabajana.mixes` beside the release refresh so a new day or ISO week can have its mixes before Home opens (the owner saw an empty Discover Weekly on Monday morning until Home refreshed). The schedule rule is `nextRefreshDate(after:calendar:)`: the next 04:00 local strictly after now, computed with `Calendar` arithmetic so DST changes keep the wall-clock hour. Period keys roll at local midnight and Monday's midnight is also the ISO week boundary, so one rule covers both mixes; 04:00 is when the device is usually idle and charging. `GanaBajanaApp` registers and schedules at launch, schedules again on every background transition, and each run reschedules itself (a foreground `loadHome` hook can call `GanaBajanaApp.scheduleMixRefresh()` too). When iOS runs the task, `MusicAppModel.refreshMixesForBackgroundTask()` calls the same `refreshMixes()` as Home, awaits the shared generation task and returns whether both current-period mixes exist; the task completes with that result. Expiry cancels the in-flight generation (nothing is saved and `mixesTask` clears) and completes as a failure. Foreground refresh stays primary: iOS may run the task late or never, and nothing waits on it.

## Metrics

Local OSLog, subsystem `com.agraabhi.ganabajana`.

| Event | Category | Fields | Emitted when |
| --- | --- | --- | --- |
| `event=daily_mixes` | `Discovery` | `clusters` 0 to 3 (mixes produced from clusters; 1 for the single fallback, 0 when none), `tracks` 0 to 75 (songs across the returned mixes) | Every `dailyMixes` call that completes |
| `event=discovery_balance scope=daily_mix` | `Recommendations` | Existing fields; counts cover all returned Daily Mixes | Once per `dailyMix` or `scopedMixes` call |
| `event=mix_super_like` | `Recommendations` | `scope` `seeds` or `daily`, `reserved` 0 or 1, `eligible` (count of eligible super likes) | Seeds are built, and each Daily Mix composition |
| `event=mix_background_refresh` | `Discovery` | `status` `ran` (generation finished), `skipped` (offline, mixes disabled, cold profile or both keys already current) or `expired` (iOS cancelled the run); `weekly` and `daily` 0 or 1 (a current-period mix exists afterwards) | Every background-task run |

No artist, recording, cluster focus or genre value is logged.

## Test coverage

| Case | Contract | Type |
| --- | --- | --- |
| `DailyMixClusteringTests.testTwoGenresAndTwoLanguagesFormTwoDistinctNamedClusters` | Two genres and two languages give two disjoint clusters named by family | Unit |
| `testLanguageAndSessionsAloneSeparateTastesAndNameTheirArtists`, `testArtistsPlayedTogetherInOneLanguageStayOneCluster`, `testCollaborationsKeepEveryRecordingInOneCluster` | Features without genre evidence, co-occurrence joining, exclusive ownership | Unit |
| `testThinSecondTasteDoesNotBecomeANearDuplicateMix`, `testThinHistoryFallsBackToTheSingleDailyMixAsDailyMixOne` | Fewer mixes with thin history; fallback identical to the single mix; cold start empty | Unit, fake catalog |
| `testThreeMixBuilderProducesDisjointClusterMixesWithinTheSingleMixBudget` | No recording in two mixes, each mix inside one taste, artist caps, focus caption, at most 10 calls with 4 radios and 3 artists | Unit, fake catalog |
| `testMixesAreStableWithinAPeriodKeyAndChangeWithIt`, `testDislikesAreExcludedFromEveryDailyMix` | Period stability and dislikes | Unit, fake catalog |
| Super-like seed reservation rotates by period key and skips disliked or non-recommendable songs; each Daily Mix leads with a super like from its scope, rotates by day, respects the artist cap and exclusions, and a scope without super likes is unchanged; Discover Weekly still excludes heard super liked songs | [SUPER_LIKES.md](SUPER_LIKES.md#test-coverage) | Unit, fake catalog |
| `testContextWeightingHookReshapesClustersWithoutChangingTheProfile`, `testOpenScopeWithAContextFilterReusesTheMixPipelineForMomentMixes` | Moment-mix hooks | Unit, fake catalog |
| `testLegacyDailyMixIdentifierResolvesToDailyMixOneEverywhere` | Old `dailyMix` id, `dailyMix1` alias, widget options and routes, legacy JSON shape | Unit |
| `testDailyMixesSaveTogetherAndRetireStaleLaterMixes`, `testWidgetSnapshotCarriesDiscoverWeeklyAndThreeDailyMixes` | Atomic save and retirement, reload, four-mix widget snapshot round trip | Unit, local files |
| `AppModelWidgetMixTests`, `AppModelWidgetSupersessionTests` (iterate every kind) | Widget routes open and play Daily Mix 2 and 3 like the original kinds | Model integration |
| `MixRefreshRegistrationTests` (`testNextRefreshDate*`, `testScheduleSubmits*`, `testHandler*`, `testExpirationCancels*`, `testBackgroundRefresh*`, `testCancelledBackgroundRefresh*`) | Schedule rule from Sunday 23:30, Monday 05:00, 02:00 and across both DST changes; the submitter receives the identifier and next date and refusals report false; the handler runs on the main queue, completes with the operation result after rescheduling, and expiry cancels the work and completes as a failure; the model hook returns false cold or disabled without requests, true once both current mixes are saved and on a request-free rerun, and false with no saved mix when cancelled mid-harvest | Unit, fake catalog (no `BGTaskScheduler`) |
| `GanaBajanaDailyMixesUITests.testMadeForYouShowsDiscoverWeeklyThenThreeDailyMixesAndOpensDailyMixTwo` | At default text size every mix is hittable at once inside the window with no horizontal swipe, in reading order (2 by 2 on a phone, one row on iPad) with equal widths and row heights, and in no carousel scroller of its own; titles and focus captions; each Play control is a 44 by 44 target on its own card, and Daily Mix 2's starts its first song without opening the page; Daily Mix 2 opens its own page with its songs | Fixture UI (`--daily-mixes-fixture`) |
| `GanaBajanaDailyMixesUITests.testMadeForYouStacksOneMixPerRowAtAccessibilityTextSizes` | Accessibility XXXL stacks one column-wide card per row in order, each at least 44 points tall with its 44-point Play control | Fixture UI (`--daily-mixes-fixture`) |
| `AdaptiveLayoutTests.testMadeForYouGridIsTwoAcrossOnPhonesFourAcrossOnIPadsAndOneAtAccessibilitySizes`, `testGridRowsFillLeftToRightAndLeaveTheLastRowShort` | Column counts and card widths for iPhone 17 Pro, SE, landscape, Slide Over, iPad mini to 13-inch, a narrow regular window and accessibility sizes; cards and gaps exactly fill the column; reading-order rows with a short last row | Unit |

The DEBUG argument `--daily-mixes-fixture` (with `--uitesting --seed-ui`) seeds a current-period Discover Weekly and Daily Mix 1 to 3 with disjoint synthetic songs; it is parsed inside the `#if DEBUG` bootstrap and is not yet in `tools/audit-release.py`'s marker list.

## Verification

WP27 package runs on a dedicated iPhone 17 Pro / iOS 26.5 simulator (since deleted), derived data `artifacts/R14/DerivedData-WP27` (since deleted):

| Bundle | Scope | Result |
| --- | --- | --- |
| `WP27-Unit-04.xcresult` | 20 unit classes: `DailyMixClusteringTests` (14), recommendation, familiarity, language, model mix, listening controls, widget presentation/route/snapshot/store/publisher, widget model routes, library mix/sync/clock/search, genre and Home customization | 227 passed, 0 failed |
| `WP27-UI-01.xcresult`, `WP27-UI-02.xcresult` | `GanaBajanaDailyMixesUITests` (1), `GanaBajanaWidgetPreviewUITests` (8), `GanaBajanaHomeCustomizationUITests` (4) | 12 of 13 passed; `testCompactEmptyPlaylistCardKeepsItsCreateActionReachableAboveTheMiniPlayer` failed on a disabled playlist Save button (Library flow) and passed alone in `WP27-UI-03.xcresult` |
| `WP27-build-widgets-01.log`, `WP27-build-watch-01.log` | `BreezyWidgets` and `GanaBajanaWatch` (Apple Watch SE 3 40 mm, watchOS 26.5) scheme builds | Succeeded |

Captures: `artifacts/R14/WP27-captures/WP27-home-mixes-shelf.png`, `WP27-home-mixes-scrolled.png`, `WP27-daily-mix-2-page.png`; the first two show the earlier horizontal shelf that the grid replaced. `GanaBajanaNativeWidgetsUITests` (SpringBoard gallery) was not run.
