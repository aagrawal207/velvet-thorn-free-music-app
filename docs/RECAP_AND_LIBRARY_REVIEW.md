# Recap layout, Library entries and the offline banner (R13 items 1 to 4, Extras A and B)

Historical R13 WP14 design and evidence. [LIBRARY_AND_RECAP.md](LIBRARY_AND_RECAP.md) owns the current Listening page, preview-first sharing, Library entries and offline banner. Cached audio management is in Settings > Library & iCloud > Storage & cached songs; the Library cache card described below is retired.

## Purpose

The Recap opened on a Listening languages card and showed the period total next to the top song's cover, which read as if that one song produced every minute. Search's start screen carried Liked songs, Cached songs and Your library shortcuts that duplicate the Library tab, and the offline banner offered "Cached songs" even while that page was open, above a second "You're offline" line. This package puts the languages card last, replaces the cover with a stat tile and a compact chart, moves the cached-audio entry into Library beside Downloads, and lets the banner and the page report the offline status once.

## Behaviour

### Item 1: Listening languages last

- `RecapView` order: header, window selector, store notices, hero, metrics, On repeat, Day by day, Artists in rotation, Share, then **Listening languages**, then the "How it's counted" disclosure. The empty recap keeps the same tail: empty state, languages, notes.
- Content and identifiers of the card are unchanged (`recap.listeningLanguages`, label "Listening languages, Last 30 days", value "n plays · m songs"). The counting notes stay the footer because they explain the page above them.

### Item 2: Minutes listened as a stat tile with a compact chart

- The hero row is `totalTile` beside `RecapCompactChart`; no artwork. Artwork remains only in On repeat rows (`TrackRow`) where it means that song. "Most listened: <title>", the divider, Top artist and the date range keep their places under the row.
- Tile: the large rounded number, the unit ("minutes listened", or "seconds listened" under a minute), the eyebrow "YOUR LAST n DAYS" above and the date range below give the period. Accessibility: one element, label "<n> minutes listened in the last <days> days", value = the comparison line, identifier `recap.totalListening` (unchanged, so `expectMetric`/`recapSeconds` in existing tests still parse the number first).
- Comparison (week and month only): "Up 12% from the previous 7 days", "Down 8% from the previous 30 days", "About the same as the previous 7 days" (within 0.5%), "2.9 times as much as the previous 7 days" (ratio of 2 and above), or "No listening in the previous 7 days". The year has no comparison because `LibraryHistoryRetention` keeps 400 days, so the previous 365 are never fully retained. The previous period is `library.summary(for: window, now: cutoff)`, the same qualified-listening source as the total.
- Chart: Swift Charts `BarMark`s without axes or legend, 72 pt tall (96 at accessibility sizes), beside the tile in compact width (140 to 220 pt wide) and below it at accessibility sizes. Buckets come from `summary.days` (the same per-day series the Day by day chart uses, so bars add up to the total): one bar per local day for the week (eight, because the rolling window starts on a partial day), seven-day spans counted back from today for the month (five, oldest partial), calendar months for the year (thirteen, oldest partial). The current span uses the accent colour. Accessibility: one element, label "Listening by day, last 7 days" (week/month/year variants), value "<k> of <n> days with listening. Most on Thursday, Sep 24: 10 min", identifier `recap.totalListening.chart`. The detailed Day by day chart (`recap.dayChart`) is unchanged and still exposes per-day marks.
- `RecapListeningBuckets` (internal, `RecapView.swift`) owns the grouping and the spoken titles; bucket titles use the calendar that placed the day so tests with a UTC calendar read the same day names.
- Fixture: `--recap-history-fixture` adds seven sessions 8 to 13 days back (1,862 s) so the week comparison reads "2.9 times as much as the previous 7 days" and the month total becomes 120 minutes; the default seed (89 minutes in every window) is untouched.

### Item 3: Search start screen and the Library Cached songs card

- Search start (`discovery`): Radio row (`search.radio.open`) first, then "Your playlists" (header `search.library.playlists`, up to three `search.library.playlist.<uuid>` rows, only when playlists exist), then Recently opened. Removed: the Liked songs card (`search.library.likes`), the Cached songs card (`search.library.cached`) and the Your library row (`search.library.open`). The offline typed-results list also drops its Cached songs and Your library rows; the offline bar above the tab already opens Cached songs, and local matches (`search.offline.results`) plus the empty state are unchanged. Live library matching for typed offline queries (`offlineSearchTracks`) is a separate feature and stays. The Radio page's offline copy now points to the Library tab.
- Library (`LibraryView`): after Liked songs, one group with 12 pt spacing holds the Downloads card (`library.downloads`, when downloads are available) and the new Cached songs card (`library.cachedSongs`): same 74 × 86 icon tile, title, caption, chevron, 20 pt padding, 12 pt corner. Caption from the model's inventory: "5 songs · 12.3 MB on this device" (count of `cachedSongs`, sum of their bytes, `ByteCountFormatter` binary), "Songs you play are cached on this device." when empty, "Checking this device…" before the first read, "Couldn’t check this device. Open to try again." after a read error. Accessibility label "Cached songs", value = caption. The card hides only once the provider has answered that it keeps no inventory (`hasLoadedCachedSongs && cachedSongsUsage == nil && cachedSongs.isEmpty && cachedSongsError == nil`). The Library root refreshes the inventory when it appears (`refreshCachedSongs`, a local disk pass) so the caption follows listening.
- Navigation: the card sets `MusicAppModel.showsLibraryCachedSongs`, bound to `navigationDestination(isPresented:)` on the Library root (`CachedSongsView().id(libraryRootGeneration)`), so the offline banner can push the same page: `openCachedSongs()` = `openLibrary()` (root reset, tab switch, player and settings closed) + flag. `openLibrary()` clears the flag like it clears `widgetLibraryDestination`. Storage's `storage.cachedSongs` row and the widget routes are unchanged.

### Item 4: Offline status once

- `MiniPlayerNavigationLayout` keeps its 44 pt offline bar in every tab. While a `CachedSongsView` is visible (`MusicAppModel.isCachedSongsScreenVisible`, an appear/disappear count reported by the view) the bar becomes `offline.status`: same height, "You’re offline" only, no button. Otherwise it is `offline.cachedSongs`, label "You’re offline. Open cached songs", and its action is `openCachedSongs()`; the former sheet with `cachedSongs.done` is gone.
- `CachedSongsView(showsOfflineStatus:)` defaults to false: inside a tab the bar owns the status. Settings > Storage passes true because the Settings sheet covers the bar, so that page shows its own "You're offline" line (`cachedSongs.offline`, now one accessibility element without the decorative glyph). Search field, count line, Play/Shuffle and rows are unchanged.
- Result: Library > Cached songs offline shows the status exactly once (bar). Settings > Storage > Cached songs shows it once inside the sheet; on iPad the dimmed tab bar behind the form sheet also reads "You're offline", which is the background context, not this screen.

### Extra A: checkpoint UI failures

- `GanaBajanaCachedSongsUITests.testInitialSnapshotShowsLoading…` and `testReadFailureOffersInlineRetry…`: fixture defect, not a product bug. `PlayerController.cachedSongsSnapshot()` bounds every inventory read at 5 s. The fixture used to block the first read until Settings or Search was presented, so Home's launch preload (offline `loadHome`) hit the deadline, recorded a timeout error, and the `.readError` scenario's synthetic failure was consumed by the test's Retry tap; `.slow` slept 15 s, which the deadline can never wait out. Now `DebugCachedAudioFixture.requireInventoryPresentation()` ends pre-presentation reads as `CancellationError` (the model records no error for a cancelled read and the next refresh tries again) and gates on `isCachedSongsScreenVisible`; the slow scenario sleeps 3 s. Both tests pass unchanged.
- `GanaBajanaStorageUITests.testClearingRecentSearchesPersists…`: stale expectation. Recently opened holds explicit `SearchSelection` destinations only (AGENTS contract; `GanaBajanaCachedSongsUITests.testStorageClearsRecentlyOpened…` already encodes it), so a typed query counts nothing. The test now opens the Kesariya result before expecting 1, then clears and checks persistence exactly as before.

### Extra B: sheet Done target

- Measured on iOS 26.5: the system glass toolbar style fixes its capsule at 68 × 36 and ignores a taller label; an outer frame enlarges the accessibility frame but not the hit region (edge taps did nothing). `AppSheetDoneButton` (iOS 26) now draws its own 36 pt `glassEffect` capsule (15 pt horizontal padding, matching the 68 pt system width within 1 pt) inside a plain button whose label is 46 × 46 with a rectangular content shape, and `appSheetDoneButton` hides the toolbar's automatic glass for that item (`sharedBackgroundVisibility(.hidden)`) so no second capsule hugs the target. 46 rather than 44: a sheet stacked on another sheet renders at 0.96 scale on iOS 26 (measured 386 pt wide, 51.9 pt bar), so 46 layout points keep 44.16 on screen in Queue > Save remaining songs. iOS 18 keeps the system text button with the same 46 pt label frame. Visual capsule size unchanged; edge taps within the 46 pt target dismiss.

## APIs

- `MusicAppModel`: `showsLibraryCachedSongs: Bool`, `isCachedSongsScreenVisible: Bool` (`visibleCachedSongsScreens` count), `cachedSongsScreenAppeared()`, `cachedSongsScreenDisappeared()`, `openCachedSongs()`; `openLibrary()` also clears `showsLibraryCachedSongs`; `refreshCachedSongs()` ignores `CancellationError` from the read.
- `CachedSongsView(showsOfflineStatus: Bool = false)`.
- `RecapListeningBucket` (`id`, `start`, `title`, `seconds`, `isCurrent`), `RecapListeningBuckets.buckets(days:window:now:calendar:)`, `.title(for:)`, `.summary(of:window:)`; `RecapText.comparison(current:previous:days:)` (internal for tests).
- `DebugCachedAudioFixture.requireInventoryPresentation()` replaces `waitForInventoryPresentation()`; `DebugMusicFixtures.seedPreviousPeriodListening(_:)` behind `--recap-history-fixture`.
- `AppSheetDoneButton.targetSize` (46).

Identifiers added: `library.cachedSongs`, `offline.status`, `recap.totalListening.chart`, `search.library.playlists`. Removed: `search.library.likes`, `search.library.cached`, `search.library.open`, `cachedSongs.done`.

## Metrics

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| none | This package adds layout, navigation and fixture changes only; inventory reads keep the existing `event=audio_cache_inventory` fields (category AudioCache) and a cancelled pre-presentation read emits nothing | none | No new failure path or provider call to observe |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `RecapListeningBucketsTests.testWeekKeepsOneBucketPerLocalDayAndMarksToday` | Eight daily buckets, sum equals total, single current bucket, disambiguated weekday titles | Unit |
| `RecapListeningBucketsTests.testMonthUsesSevenDaySpansCountedBackFromTodaySoTheNewestIsWhole` | Five spans, oldest partial, empty span kept as zero, newest span start and title | Unit |
| `RecapListeningBucketsTests.testYearGroupsByCalendarMonthWithThePartialFirstMonthKept` | Thirteen calendar months, partial oldest month sums both days, current month | Unit |
| `RecapListeningBucketsTests.testSummaryNamesThePeakSpanAndCountsActiveSpans` | Chart summary copy, empty summary, window titles | Unit |
| `RecapListeningBucketsTests.testComparisonCopyCoversUpDownSameMultiplesAndNoPreviousListening` | All five comparison branches | Unit |
| `ListeningAnalyticsTests` (10 cases) | Per-day series unchanged | Unit (regression) |
| `GanaBajanaRecapReviewUITests.testListeningLanguagesIsTheLastSectionBelowEveryRecapSection` | Frame order of hero, top artist, On repeat, Day by day, artists, Share above the languages card; only the notes below; card still opens the page | UI (seeded fixture) |
| `GanaBajanaRecapReviewUITests.testTotalIsAStatTileWithACompactChartAndAPreviousPeriodComparison` | Tile label/value, chart label/summary, chart beside the tile, month relabel and total with older history, year without comparison | UI (`--recap-history-fixture`) |
| `GanaBajanaRecapReviewUITests.testTileReadsTheSameTotalInEveryWindowWithoutOlderHistory` | 89 minutes in every window, "No listening in the previous n days", empty year value | UI |
| `GanaBajanaLibraryEntriesUITests.testLibraryShowsCachedSongsBesideDownloadsWithCountAndBytesAndOpensTheBrowser` | Card caption with count and bytes, 44 pt target, grouped under Downloads with equal width, push to the browser, Back | UI (`--cache-fixture`) |
| `GanaBajanaLibraryEntriesUITests.testSearchStartKeepsRadioPlaylistsAndRecentsWithoutLibraryShortcutCards` | Removed identifiers absent, Radio first at the top, playlists then recents, playlist shortcut still opens | UI |
| `GanaBajanaLibraryEntriesUITests.testOfflineBannerOpensLibraryCachedSongsAndShowsTheStatusOnce` | Banner action routes to Library > Cached songs, status without action while visible, no second line, tab switch restores the action, Back restores it, action from another tab replaces a pushed Liked songs page, zero network requests | UI (`--cache-fixture --offline-fixture`) |
| `GanaBajanaLibraryEntriesUITests.testSettingsCachedSongsCarriesItsOwnOfflineLineBecauseTheSheetCoversTheBanner` | `showsOfflineStatus: true` path inside Settings | UI (offline fixture) |
| `GanaBajanaSheetDoneUITests.testSettingsSheetDoneKeepsA44PointTargetWhoseEdgesDismiss` | Target at least 44 pt, inside the window, centred on the bar; taps 3% from the top and bottom edges dismiss | UI |
| `GanaBajanaQueueSaveUITests.testBlankNameAndDoneLeaveLibraryAndPlaybackUnchanged` | Nested (0.96-scaled) sheet Done still measures at least 44 on screen | UI (WP13 file, unchanged) |
| `GanaBajanaCachedSongsUITests` (15 cases) | `.slow` and `.readError` scenarios through the new gating; Settings path keeps `cachedSongs.offline` | UI (regression) |
| `GanaBajanaStorageUITests` (5 cases) | Recently opened counts an opened result; remaining storage flows unchanged | UI (regression) |
| `GanaBajanaSearchRedesignUITests` (rewritten cases listed in the report) | Radio-led start screen, playlist shortcut live edits, reselect pops playlist and radio pages, offline search routes through the banner, accessibility sizes | UI |
| `GanaBajanaNavigationIntentUITests` (edited cases) | Playlist shortcut as the Search-tab local link; `search.radio.open` as the discovery anchor | UI |
| `GanaBajanaLibrarySearchUITests` (6 cases) | Library pages unchanged around the new card | UI (regression) |

## Not verified

- iPad and Dynamic Type layouts of the new hero row and the Library card were built with the shared layout helpers (`AnyLayout` switch at accessibility sizes, `AppLayout.contentMaxWidth`) but not captured in this run; `GanaBajanaSearchRedesignUITests.testLargeDynamicTypeKeeps…` covers Search at XXXL on the phone only.
- The offline status "exactly once" rule is asserted for the Library path and the Settings path on the phone. On iPad the form sheet leaves the dimmed tab bar visible behind Settings; not captured.
- Light appearance captures of the Recap tile and the Library card were not taken (the seeded fixture runs dark by default).
- Real-device toolbar metrics for the Done capsule were not measured; the 36 pt capsule and 0.96 nested-sheet scale come from the iPhone 17 Pro / iOS 26.5 simulator.
- iOS 18 rendering of the Done button (the system text button branch) was not run; no iOS 18 simulator is part of this round.
- The cache fixture stages its audio (waveform plus AAC export) after launch while `PlayerController.cachedSongsSnapshot()` keeps its 5 s deadline. With two simulators running UI suites at once, one default-scenario run (`testFilteredLegacySongPlaysFromItsFileWithoutNetworkAccess`) recorded "Loading audio took too long" before the page opened; the same test passed on rerun. Declining reads during setup is not an option because cold widget launches need that first read to wait, so the race stays a load-only flake.
- `GanaBajanaSearchDiscoveryUITests.expectSearchAtTop` (WP15's file) still anchors an empty query on `search.library.likes`; it needs `search.radio.open`, the first control of the new start screen.
