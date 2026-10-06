# Library and Stats Organisation

R14/R15 introduced compact Library entries, filters and image sharing. R16 named the page Stats. R17 integrates lifetime time/play totals and Not Liked Downloads. Core/regression/integration and UI-02/UI-03 targeted phone checks passed; [VERIFICATION.md](VERIFICATION.md) owns counts and boundaries. Broader verification remains ongoing.

## Current contract

- The tab and page title are **Stats**. `AppTab.recap`, `tab.recap` and `recap.*` identities remain. Week/Month/Year use `ListeningWindow`; All Time uses `library.lifetimeListeningSummary` for time/plays and `allAvailableSummary` for retained-detail rankings/charts.
- Order: header, Week/Month/Year/**All Time**, notices and history coverage, minutes tile with compact chart, metrics, one **Share** button, **On Repeat**, **Day by Day**, artists, genres, Listening Languages, counting notes, **Recently Played**. All Time calls the timeline **Over Time** because its bars represent calendar periods. `recap.onRepeat` and `recap.timeline` expose the adjacent section bounds.
- Recently played (`recap.recent`) starts collapsed. `recap.recent.toggle` is a 44-point button with Collapsed/Expanded value. Expanding reveals See all (`recap.recent.all`) and the same 20 newest song rows with play/resume controls. The history destination and ordering are unchanged; the subsection is last even in an empty selected window.
- `recap.share` opens **Stats Card** immediately from captured content/text, using cached artwork only. `recap.share.previewShare` is the only system-share action; the image remains 1080 × 1350. All Time's card uses **Lifetime Listening**, labels rankings **Retained History** and carries the earlier-deletion caveat. Render failures remain retryable.
- Stats sharing defaults to the image alone. **Include Summary Text** (`recap.share.includeText`) opts into the captured summary message for that preview; every newly opened preview starts off. `recap.share.contents` explains the selected payload.
- Shared list and cached-song Play/Shuffle controls use subheadline labels and 44-point minimum targets. Collection Play/Shuffle visuals use the same smaller height; Dynamic Type may increase intrinsic size. Liked Songs rows display valid known durations through `TrackRow.showsDuration`.
- `library.createPlaylist` sits beside the **Playlists** section heading, not the page title, and opens the existing editor.
- Top genres and the card's genre/language shares use the selected summary's qualified plays. New `languageSummary(listening:evidence:overrides:)` and `genreSummary(listening:evidence:)` projections share the existing classification logic; the event/window APIs keep their signatures. The Listening languages navigation row still explicitly describes its **Last 30 days** recommendation-tuning page.
- Library's compact group contains Liked songs and Downloads when available. `library.cachedSongs` is absent; cache management is reached through Settings > Library & iCloud > **Storage & cached songs** > Cached songs (`settings.storage`, `storage.cachedSongs`, destination title Storage). Likes' All/Super Liked/Downloaded/On This Device filters and the offline On this device list still expose playable local music, including cached copies. Existing compatibility destinations remain.
- R20 super-like extras ([SUPER_LIKES.md](SUPER_LIKES.md#behaviour)): `LibrarySavedSongsView(kind:initialFilter:)` accepts a preselected Likes chip, which Home's **Super Liked** shelf header (`home.superLiked.seeAll`) uses to push Liked Songs on the Home tab with `library.likes.filter.superLiked` selected, the way Stats' See All pushes Recently Played; Recently Played ignores the parameter. `TrackRow` shows a caption2 accent `bolt.heart.fill` after the duration and before the downloaded glyph for a super liked song (`track.superLiked.<id>`, at every text size like `track.downloaded.<id>`), and its VoiceOver value appends "Super liked" ahead of "Downloaded" or "Cached on this device" (`TrackRow.stateDescription`). Settings > Storage's Saved Library section lists **Super Liked** with `library.superLikes.count` directly after Liked Songs (`storage.library.superLikes`, same 44-point value row).

### Direct Liked Songs Downloads

Liked Songs offers the **Download Liked Songs** menu at `library.likes.autoDownload` (Off, Super Liked Only, All Liked; choices `library.likes.autoDownload.choice.off|superLiked|liked`), even before any likes exist when downloads are supported. It is the same `DownloadLikedSongsToggle` as Settings, bound to `autoDownloadScope`, which derives from the `autoDownloadLikedSongs` and `autoDownloadSuperLikedSongs` leaves. Choosing a scope with a backlog shows **Download Liked Songs?** or **Download Super Liked Songs?** with Download and Cancel (`library.likes.autoDownload.confirm|cancel`); only confirming saves the scope and queues that scope's backlog. Unliking, demoting and narrowing the scope never delete a download.

`library.likes.downloadStatus` reports **x of y downloaded**, the pending count, **Waiting for a connection** or **Waiting for Wi-Fi**, and failed counts with a direction to retry in Downloads. The counts use existing favorites, download state and inventory, not the preference as evidence of completed files. All Liked keeps pending likes visible, resets a Downloaded or On This Device selection to All and hides those two chips, leaving All and Super Liked; a selected or preselected Super Liked chip stays selected because All Liked keeps it. Super Liked Only and Off show every chip; leaving All Liked restores the chips and keeps the current selection. Settings changes are observed by the same page.

Authored integration selectors (not executed by this worker):

```text
GanaBajanaUITests/GanaBajanaMainStatsUITests
GanaBajanaUITests/GanaBajanaDownloadsUITests/testLikedSongsDownloadConfirmationResetsFiltersAndKeepsPendingLikesVisible
GanaBajanaUITests/GanaBajanaDownloadsUITests/testLikedSongsDownloadPreferencePersistsAndStaysSynchronizedWithSettings
GanaBajanaUITests/GanaBajanaLibraryOrganisationUITests
GanaBajanaUITests/GanaBajanaRecapReviewUITests
```

Unit coverage for Wi-Fi gating and unliking retaining files remains in `DownloadsTests`; the new UI cases use the existing offline cache fixture for confirmation/cancel, partial completion, all-liked visibility, reset-to-All, relaunch and Settings synchronization. The diagnostics are the `download_enqueued`, `download`, `download_auto_like`, `download_auto_super_like`, `super_like`, `audio_cache_inventory` and `recap_share_card` events ([SUPER_LIKES.md](SUPER_LIKES.md#metrics) owns the two super-like events).

### Saved-history Accuracy and Bounds

`LibraryHistoryRetention.apply` keeps 400 full local days and may retain one older session per active-streak day. All Time detail reads every valid surviving session, including those incomplete streak samples, using existing validation and qualification. Lifetime time/plays come from the separate receipt projection; detail does not infer deleted rankings.

All Time explains that lifetime time/plays survive detail pruning, while charts and rankings use retained history, normally 400 days. Plays deleted before lifetime tracking cannot be recovered. Coverage starts at the earliest included receipt, not a guarantee of complete days. Both All Time detail charts retain the 24-bucket bound; rolling windows keep their existing cutoffs.

[LIFETIME_STATISTICS.md](LIFETIME_STATISTICS.md) owns the implemented exact receipt rollup, its lifetime fields in the local and sync formats ([ICLOUD_SYNC.md](ICLOUD_SYNC.md) lists the current versions) and reset semantics. At most 200,000 receipts fit per history generation; shared journal and file limits may bind earlier. Exhaustion rejects writes, rather than silently approximating totals. History Off retains totals and stops new local credit; Clear History clears totals and rejects stale replica generations.

### Coverage and coordinator selectors

Current core/regression/integration and UI-03 Stats results belong in [VERIFICATION.md](VERIFICATION.md). Earlier evidence below retains its historical scope. Retained-detail regression selectors:

```text
GanaBajanaTests/ListeningAvailableHistoryTests
GanaBajanaTests/ListeningAnalyticsTests
GanaBajanaTests/LibraryRetentionTests
GanaBajanaTests/RecapListeningBucketsTests
GanaBajanaTests/RecapShareCardTests
GanaBajanaTests/ListeningLanguageProfileTests
GanaBajanaUITests/GanaBajanaRecapReviewUITests
GanaBajanaUITests/GanaBajanaLibraryOrganisationUITests
GanaBajanaUITests/GanaBajanaLibraryEntriesUITests
GanaBajanaUITests/GanaBajanaGenreProfileUITests/testRecapShowsTopGenresDirectlyAboveListeningLanguagesAndHidesWithoutEvidence
```

`ListeningAvailableHistoryTests` covers the 390-day saved event and exact 400-day retention boundary, incomplete older streak samples, invalid/future/duplicate events, sparse history, 24-bucket bounds over decades, local month boundaries and empty gaps, genre/language qualification and corrections, coverage copy and singular units. The updated UI cases cover the Listening label with `tab.recap`, All Time selection, adjacent rankings/timeline, collapsed-last recents with play/resume/history, one preview-first Share action in both appearances, absent Library cache management and reachable Storage cache management. Existing offline/filter cases retain playback coverage. Authored coverage is distinct from executed R15 evidence.

Metrics: the existing `event=recap_share_card` rendered/failed, appearance and artwork-count fields emit on preview rendering/retry. All Time, disclosure and navigation add no telemetry, persistence or provider requests. Render failure/retry and system share-target behavior still need coordinator/manual checks.

### Integration and remaining acceptance

The shared test driver resolves `tab.<route>`; Stats retains `recap` identities. UI-03 passed targeted phone Stats and card-preview checks in light/dark. UI-02 passed Downloads' Not Liked filter and heart-toggle workflow. Small-phone/iPad/accessibility geometry, recipient sharing and native two-device lifetime sync remain separate. [LIFETIME_STATISTICS.md](LIFETIME_STATISTICS.md) owns the R17 schema and merge change.

## R14 motivation

The three on-device cards at the top of Library (Liked songs, Downloads, Cached songs) took about 330 points before the first playlist, Liked songs could only toggle "Downloaded only", offline listeners were sent to Cached songs (which hides downloads), the Library and Recap both carried recent listens, and the Recap could only be shared as text. R14 made the entries compact, added All/Downloaded/On this device filters and a combined offline list, moved recents to Recap and added an image share card. R15's current contract above refines those routes and names the page Listening.

## Behaviour

### Item 3: compact Library entries

- `LibraryView.entries`: one inset card (`AppTheme.surface`, `AppCorner.compact` 10 pt, identifier `library.entries`) holding Liked songs (`heart.fill`) and, when available, Downloads (`arrow.down.circle.fill`), separated by a hairline inset to the title column. Cache management has no Library entry.
- Row: `SettingsRowIcon` (28 pt tile, reused from `SettingsRowStyle.swift`), body title, trailing secondary value, chevron; 16 pt horizontal and 8 pt vertical padding, 44 pt minimum. Accessibility sizes stack the value under the title.
- Trailing values are short: the liked count ("5"), the download count and/or "n in progress", empty when there is nothing to count. Full accessibility values remain at `library.likes` and `library.downloads`.
- Historical three-row R14 measurement on iPhone 17 Pro (402 × 874 pt): rows at y 154, 199 and 244, each 362 × 44 pt, gaps 1 pt; the group ended at y 288. The iPhone SE test also passed with all three rows above the tab bar. These measurements predate removal of the Cached songs row.
- The Library root is a plain `VStack` (it was lazy); see item 16.

### Item 4: liked vs downloaded vs on this device

- Liked songs (`LibrarySavedSongsView(kind: .likes)`) shows `LibraryFilterChips` under the count and above Play/Shuffle whenever there are likes: All (`library.likes.filter.all`), Super Liked (`library.likes.filter.superLiked`), Downloaded (`library.likes.filter.downloaded`, only when downloads are available) and On This Device (`library.likes.filter.onDevice`); under All Liked only All and Super Liked remain. Chips are single select, 34 pt capsules inside 44 pt targets, selected state as the `isSelected` trait. `ChipFlowLayout` wraps chips that no longer fit one line onto further rows, 8 pt apart, and accessibility sizes stack one per row; the capsule fill follows the selection in 180 ms (`.snappy`), with no animation under Reduce Motion and never an animated layout.
- `LikedSongsFilter.includes`: Super Liked is `model.library.isSuperLiked`; Downloaded is `model.isDownloaded`; On This Device is `model.hasLocalCopy` (a download or a complete playable cached copy, the same answer export uses). The filter composes with the local search; the count reads "n of m songs"; Play and Shuffle take the filtered list. Empty filter: `library.likes.filter.empty` (**No Super Likes Yet** "Hold the heart on a song you love, or choose Super Like from its menu.", **No Downloaded Likes**, **No Likes on This Device**). Each liked row has a leading swipe **Super Like** / **Change to Like** (`library.superLike.<id>`, `bolt.heart.fill` or `heart.fill`, `MusicAppModel.toggleSuperLike(_:surface: .library)`) and the trailing **Unlike** swipe (`library.unlike.<id>`, `toggleLike(_:surface: .library)`); both are also accessibility actions ("Remove from Liked Songs" for the unlike). The toolbar toggle `library.likes.downloadedOnly` and `library.likes.downloadedOnly.empty` are removed.
- Downloads has All (`downloads.filter.all`), Super Liked (`downloads.filter.superLiked`), Liked (`downloads.filter.liked`) and Not Liked (`downloads.filter.notLiked`) under the summary. Not Liked means not a favorite, independent of recommendation exclusions. Heart changes update membership without deleting files. Play/Shuffle follows filtered playable songs; the summary counts all downloads. `downloads.filter.empty` says No Super Liked Downloads, No Liked Downloads or All Downloads Are Liked as appropriate.
- `OnThisDeviceView` (new, `onThisDevice.screen`, title "On this device"): every playable local song, downloads first, then the temporary cache, each section sorted by title (`MusicAppModel.onThisDeviceSongs`). Count line `onThisDevice.count` "4 songs play without a connection · 1 downloaded · 3 cached", Play/Shuffle (`onThisDevice.play`, `onThisDevice.shuffle`, queue in list order), section headers `onThisDevice.section.downloaded|cached`, rows `onThisDevice.row.<id>` (value "Downloaded" or "Cached", tap plays the song in that queue). Offline, rows ask for no artwork. Loading (`onThisDevice.loading`) and empty (`onThisDevice.empty`) states. It refreshes the inventory on appear and on pull.
- Offline bar: the action is `offline.onThisDevice`, label "You’re offline. Open songs on this device", trailing text "On this device", action `openOnThisDevice()` (Library root reset plus `showsLibraryOnThisDevice`). It becomes `offline.status` while an On this device page or a Cached songs page is visible (`isOnThisDeviceScreenVisible || isCachedSongsScreenVisible`), so the status shows once. `offline.cachedSongs` is gone; Settings > Library & iCloud > Storage & cached songs owns cache management and its cached browser keeps an offline line.

### Item 5: recent listens in Listening only

- Library no longer has Recent listens (`library.recents.all`, `library.recent.<id>`, `library.resume.<id>`, `library.findMusic` and its empty state are gone from the root).
- **Recently played** (`recap.recent`) is last, after counting notes, initially collapsed behind `recap.recent.toggle`. It remains available when the selected window is empty if saved recents exist. On repeat is directly before the timeline; Share sits above On repeat.
- Source: `LibraryStore.recentlyPlayed` (one entry per song, newest first, with its resume position), first 20 rows, independent of the selected window. Rows are the existing `LibraryRecentSongRow` with the `recap` prefix: `recap.recent.<id>` containing `track.play.<id>` (tap plays in the recents queue) and, from 1 s in, `recap.resume.<id>` "Resume at m:ss".
- "See all" (`recap.recent.all`, 44 pt, label "See all recently played") pushes the existing `LibrarySavedSongsView(kind: .recents)`, now titled "Recently played" (was "Recent listens"; the widget route opens the same page). Its bound is `LibraryHistoryRetention` (400 days), the same retention the recap's listening events use.
- Decision: the section lists songs, not every session. `RecentListen` is what carries resume positions, and a per-session list would repeat a song many times; On repeat already ranks repeats.

### Item 6: share Listening as a picture

- `RecapShareCard` (`Sources/Views/RecapShareCard.swift`) is a 1080 × 1350 view rendered by `RecapShareCardRenderer.render` with `ImageRenderer`, scale 1, opaque, `colorMode = .nonLinear` (8-bit sRGB): exactly 1080 × 1350 pixels on every device.
- `RecapShareCardContent` includes the Velvet Thorn mark, period/date range, listening total and retained top songs/artists/genres or languages. R17 All Time supplies `lifetime:` and uses Lifetime Listening with retained-history ranking labels and a deletion caveat. Rolling periods retain their selected-window totals and shares.
- The card has fixed-height blocks (184, 226, 430, 212 pt and a footer of 36 pt, or 68 pt with coverage, inside 72 pt padding). Names are shortened before layout to a character budget (song titles 30, song artists 40, artist/genre/language rows 20, period 32, date 48) ending in "…". Historical longest-name captures cover the original footer in both appearances; the taller All Time footer needs its own geometry acceptance.
- Artwork: only images the artwork loader already holds (`ArtworkLoader.cachedThumbnail`, up to 240 px, response cache read without a request); a missing image draws the standard placeholder tile. Background: a top-to-bottom gradient from the top song's `ArtworkPalette` primary (tinted to luminance 0.06 dark or 0.6 light) when its artwork is loaded, otherwise the accent at 45 % (dark) or 35 % (light) opacity, over a near-black or near-white base. Text colours are fixed per appearance (white / 74 % white, or #0B0B10 / #3F3F49).
- `recap.share` captures content/text and opens Stats Card (`recap.share.preview`). Rendering uses cached artwork with progress and retry. The preview retains Done, image and its sole system-share action. It sends the image alone unless Include Summary Text is enabled. All Time carries lifetime totals, retained-detail labels and the earlier-deletion caveat.

### Item 16 (Library half): Following landing

- `MusicAppModel.openFollowingInLibrary()` = `openLibrary()` (tab, root reset, player and Settings closed) plus `libraryScrollTarget = .following`. `openLibrary()` clears the target and `showsLibraryOnThisDevice`.
- `LibraryView` wraps its scroller in a `ScrollViewReader`; `.task(id: model.libraryScrollTarget)` waits one yield plus 150 ms for the tab switch, scrolls the Following section (anchor and identifier `library.following`) to the top (animated, none with Reduce Motion), then clears the request, so later visits keep their own position. Without followed artists there is no anchor: nothing scrolls and the request is still cleared.
- The root stack is a plain `VStack`. With the previous `LazyVStack`, on the iPhone SE the jump stopped at the Playlists heading and scrolling back up then hung the main thread for more than 30 s (`WP23-OrganisationSE-02`); with the plain stack both runs pass.

## APIs

- `MusicAppModel`: `showsLibraryOnThisDevice`, `visibleOnThisDeviceScreens`, `isOnThisDeviceScreenVisible`, `onThisDeviceScreenAppeared()`, `onThisDeviceScreenDisappeared()`, `onThisDeviceSongs` (`downloaded` and `cached` arrays of `(song: CachedSong, track: Track)`), `openOnThisDevice()`, `libraryScrollTarget: LibraryScrollTarget?`, `openFollowingInLibrary()`.
- `LibraryScrollTarget.following` (`anchorID` "library.following"); `LibraryFilterOption`, `LikedSongsFilter` (`all`, `superLiked`, `downloaded`, `onDevice`), `DownloadsFilter` (`all`, `superLiked`, `liked`, `notLiked`), `LibraryFilterChips`, `ChipFlowLayout(horizontalSpacing:verticalSpacing:)` (a `Layout` in `LibraryView.swift`; a row breaks before the chip that would overflow the width); `LibrarySavedSongsView(kind:initialFilter:)` (`initialFilter` defaults to nil, meaning All; only `.likes` reads it); `LibraryRecentSongRow` retains its configurable identifier prefix.
- `RecapShareCardContent` (`clipped(_:limit:)`, limits as statics), `RecapShareCard.size`, `RecapShareCardRenderer.render(_:artwork:accent:colorScheme:)`, `RecapShareCardRenderer.cachedArtwork(for:)`, `RecapShareCardImage`.
- `OnThisDeviceView`.
- DEBUG fixtures (with `--uitesting --seed-ui`): `--library-organisation-fixture` (seven more playlists and three followed artists, so Following starts below the first screen), `--recap-long-names-fixture` (three long-named songs with the most listening this week), `--open-following-fixture` (calls `openFollowingInLibrary()` 2 s after launch from Home, standing in for the Settings row). All three are in the `tools/audit-release.py` marker list.

Identifiers include `library.entries`, `library.following`, `library.likes.filter.*`, `library.likes.autoDownload` and its `.choice.*`, `.confirm`, `.cancel` suffixes, `library.superLike.<id>`, `library.unlike.<id>`, `track.superLiked.<id>`, `home.superLiked.seeAll`, `storage.library.superLikes`, `downloads.filter.*`, `onThisDevice.*`, `offline.onThisDevice`, `recap.window.allTime`, `recap.historyCoverage`, `recap.onRepeat`, `recap.timeline`, `recap.recent`, `recap.recent.toggle`, `recap.recent.all`, `recap.recent.<id>`, `recap.resume.<id>`, `recap.share`, `recap.share.preview`, `recap.share.previewImage`, `recap.share.previewShare`, `recap.share.loading`, `recap.share.retry` and `recap.share.done`. Removed: `library.cachedSongs`, `library.likes.downloadedOnly`, `library.likes.downloadedOnly.empty`, `offline.cachedSongs`, and on the Library root `library.recents.all`, `library.recent.<id>`, `library.resume.<id>`, `library.findMusic` (the pushed Recently played page keeps `library.recents.*` and `library.recent.<id>`).

## Metrics

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=recap_share_card outcome= appearance= artwork=` (Logger category Recap, debug) | Every card render | `outcome` rendered or failed (nil image or wrong pixel size); `appearance` dark or light; `artwork` 0 to 3 loaded covers | The only new failure path; the artwork count shows how often cards fall back to placeholders |
| `event=library_scroll target=following outcome=` (Logger category Library, debug) | Every consumed `openFollowingInLibrary()` request | `target` following; `outcome` landed or no_anchor | Distinguishes a landing from a request with no followed artists |
| none for filters, On this device or Recently played | Local view state over existing inventory and history | none | No new provider call or persistence; inventory reads keep `event=audio_cache_inventory` |

## Historical R14 test coverage and runs

The selectors and receipts below describe the earlier three-entry Library and Recap UI. They retain the results recorded at that time; the current contract and authored follow-up coverage above supersede their labels, order and share actions.

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `RecapShareCardTests.testRendersExactly1080By1350PixelsWithVisibleContentInLightAndDark` | Pixel size and scale 1 in both appearances, drawn content (more than 40 luminance levels), near-white and near-black bases; attaches both long-name renders | Unit |
| `RecapShareCardTests.testLongNamesAreShortenedToTheCardBudgetAndListsKeepThree` | Character budgets and ellipsis, three-item caps, short names kept, trimming | Unit |
| `RecapShareCardTests.testSummaryContentUsesTheWindowPeriodTopThreeAndClassifiedFamilies` | Period title, minutes vs seconds, top three songs and artists, genres present or absent | Unit |
| `RecapShareCardTests.testLoadedTopArtworkTintsTheBackgroundAndMissingArtworkDrawsThePlaceholder` | Palette gradient from a loaded red cover vs accent gradient without artwork | Unit |
| `GanaBajanaLibraryOrganisationUITests.testCompactEntriesAreOneGroupOfShortRowsOnTheFirstScreenWithoutRecentListens` | Rows 44 to 60 pt, above the tab bar without scrolling, one group, values, Playlists on the first screen, Recent listens absent | UI (`--cache-fixture`) |
| `…testLikedSongsChipsFilterDownloadedAndOnThisDeviceAndDownloadsFiltersLiked` | Chip targets, labels and order; Downloaded 1 of 5; On this device 3 of 5 (download plus complete cached copies, incompatible and unfinished excluded); filtered Play; Downloads Liked chip before and after unliking, file kept | UI (`--cache-fixture --cache-fixture-downloaded`) |
| `…testOfflineBannerOpensOnThisDeviceWithDownloadsFirstAndPlaysWithoutNetwork` | Banner route, count line, downloads section first, row values, single status, cached row plays offline, zero network requests | UI (offline fixture) |
| `…testRecapRecentlyPlayedFollowsOnRepeatNewestFirstAndSeeAllOpensTheHistory` | Section between On repeat and Day by day, newest first, resume shortcut, row plays, See all target and pushed page count | UI |
| `…testShareCardPreviewShowsTheRenderedPictureInDarkAndLight` | Preview enabled after render, 1080 × 1350 value, aspect ratio, share action, Done, in dark and `--light`, at the longest fixture names | UI (`--recap-long-names-fixture`) |
| `…testOpenFollowingInLibraryLandsOnTheFollowedArtistsOnceFromAnotherTab` | Tab switch from Home, Following visible above the tab bar, header scrolled away, no second pull after scrolling up, Following below the first screen at the top | UI (`--library-organisation-fixture --open-following-fixture`) |
| `GanaBajanaLibraryEntriesUITests.testOfflineBannerOpensOnThisDeviceAndShowsTheStatusOnce` (renamed from `…OpensLibraryCachedSongs…`) | Banner opens On this device; status once there and on Cached songs; tab switches; Back; action replaces a pushed Liked songs page | UI (migrated) |
| `GanaBajanaLibraryEntriesUITests` other 3 cases | Cached songs row caption, target, grouping; Search start; Settings offline line | UI (regression, one identifier migrated) |
| `GanaBajanaDownloadsUITests.testLibraryRowMenuDownloadCopiesTheFixtureFileAndFilterShowsDownloadedLikes` | Downloaded chip replaces the toggle | UI (migrated) |
| `GanaBajanaCachedSongsUITests.testUnknownRecordingUsesTruthfulFallbackAndBrowsingDoesNotAddItToRecents` | Recents reached through Recap > See all | UI (migrated) |
| `GanaBajanaWorkflowUITests.testDatedChartsRecapWindowsAndSavedResume` | Saved resume from `recap.resume.<id>` | UI (migrated) |
| `GanaBajanaSearchRedesignUITests.testOfflineSearchRoutesCachedSongsThroughTheBannerAndDeduplicatesLocalMatches` | Banner opens On this device; a row plays offline | UI (migrated) |
| `GanaBajanaRecapReviewUITests.testListeningLanguagesIsTheLastSectionBelowEveryRecapSection` | `recap.recent` added to the sections above Listening languages | UI (extended) |
| `GanaBajanaWidgetPreviewUITests.testHistoryOffRecentPreviewHidesMetadataAndCanReenableHistory` | Recents page title "Recently played" via `expectSavedList` | UI (migrated helper) |
| `GanaBajanaDownloadTierUITests` (3), `GanaBajanaLibrarySearchUITests` (6), `GanaBajanaCachedSongsUITests` (other cases), `GanaBajanaGenreProfileUITests.testRecapShows…` | Library rows, liked search, cached browser and Recap order around the new pieces | UI (regression) |

Runs (dedicated simulators `R14-WP23` iPhone 17 Pro and `R14-WP23-SE` iPhone SE 3rd generation, iOS 26.5, `artifacts/R14/DerivedData-WP23`): `WP23-ShareCardUnit-01` (9 passed, with `RecapListeningBucketsTests`), `WP23-OrganisationUI-01` (5 of 6, the value assertion expected unformatted numbers; corrected), `WP23-RegressionUI-01` (24 run, 21 passed; failures in the player More sheet, Home and one keyboard entry flake), `WP23-OrganisationUI-02` (9 run: organisation 6 of 6, the flake passed, the More sheet and Home cases failed again), `WP23-OrganisationSE-01`, `-02` (the fixes above), `WP23-OrganisationSE-03` (6 of 6 on the SE), `WP23-TouchedUI-01` (4 unit and 47 UI run, 50 passed, 1 failed outside this package), `WP23-Final-01` (4 unit and 13 UI, all passed, after the metrics lines). Captures in `artifacts/R14/WP23-captures`.

## Historical R14 acceptance limits

- `GanaBajanaRefinementUITests.testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabs` fails on Home before it reaches the migrated Library step (`home.group.discovery` / `track.card` on the Home tab, which WP27 is changing), so the new Library scroll-end assertion (last playlist row above the mini-player) has not run.
- The Settings > Following row that calls `openFollowingInLibrary()` is WP26's; only the DEBUG launch hook exercises it here.
- Real cover artwork on the share card: the fixtures have no artwork URLs, so the palette gradient is covered by a unit render with a synthetic cover only; UI captures show placeholder tiles and the accent gradient.
- The share sheet itself (which targets keep the message text next to the image) was not driven; only the ShareLink's presence is asserted.
- iPad, accessibility text sizes for the chips and rows, and VoiceOver were not captured.
- `OnThisDeviceView` has no per-song removal; managing storage stays on Downloads and Cached songs.
