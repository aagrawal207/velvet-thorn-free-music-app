# Settings redesign (R13 item 5, R14 items 11, 12, 16, 17, 18)

R13 WP16 built the visual system; R14/R15 integrated six topic pages. R17's Moment Mixes and background/account copy have targeted verification. R18 integrates Normalize Volume's gain-up explanation, YouTube Changes and Extractor Updates. R19 makes Download Liked Songs a three-way menu and adds the Discovery super-like footer ([SUPER_LIKES.md](SUPER_LIKES.md)). R18 verification is in progress; [VERIFICATION.md](VERIFICATION.md) owns counts and results. Historical WP26 receipts below retain their scope.

## Purpose

Current UI copy uses natural title case for headings, navigation, buttons and options: **Account & Connection**, **Storage & Cached Songs**, **Audio Quality**, **Fewer Repeats**, **Best Available** and **More Options**. Explanatory paragraphs, provider names and saved user names keep their original casing. Stored preference values and `settings.*` identifiers are unchanged; `SettingsChoice.settingsTitle` supplies explicit presentation labels for the affected finite choices.

**Download Liked Songs** (`settings.autoDownloadLiked`) and the direct Liked Songs control (`library.likes.autoDownload`) are the same `DownloadLikedSongsToggle`, a menu row over `UserPreferences.autoDownloadScope` with the choices **Off**, **Super Liked Only** and **All Liked** (`<id>.choice.off|superLiked|liked`). The scope derives from the `autoDownloadLikedSongs` and `autoDownloadSuperLikedSongs` leaves and writes both. A scope with a backlog confirms first through "Download Liked Songs?" or "Download Super Liked Songs?" (`<id>.confirm`, `<id>.cancel`), and a failed save does not enqueue the backlog. The footer `settings.autoDownloadLiked.description` reads "Download Liked Songs saves each new like to this device. Super Liked Only saves only your super likes. Changing it never removes a download." The next footer paragraph, `settings.downloads.background.description`, explains that submitted transfers can continue in the background, preparation waits for foreground runtime, and force-quit stops transfers until reopening; Wi-Fi remains the default. [BACKGROUND_DOWNLOADS.md](BACKGROUND_DOWNLOADS.md) owns runtime limits. Settings > Discovery's Home and mixes footer carries `settings.superLikes.description`: "Super liked songs count more in Daily Mixes and seed Discover Weekly."

**Moment Mixes** (`settings.moments.open`) uses the model's controller. Learn Moment Mixes defaults on; Use Motion Activity defaults off and requests permission only on explicit enable. Per-context switches are device-local. Shared `settingsPageChrome` includes `settings.done`, with the correction covered by targeted R17 UI checks. [MOMENT_MIXES.md](MOMENT_MIXES.md) owns learning/privacy bounds.

**Normalize Volume** keeps `settings.normalize` and adds `settings.normalize.description` in the Sound footer: source-based attenuation and up to +6 dB boost, possible limiter reduction, unity for missing metadata and unsupported live/stream boost. The shared EQ tap contract is in [VOLUME_NORMALISATION.md](VOLUME_NORMALISATION.md).

**YouTube Changes** (`settings.youtubeChanges`) opens the model-owned write controller even while signed out, with a reconnect explanation. Permission starts off and is device/sign-in-bound; each remote action requires separate confirmation. This switch is not a synced `UserPreferences` leaf. Done closes Settings. [ACCOUNT_WRITEBACK.md](ACCOUNT_WRITEBACK.md) owns eligibility and uncertainty.

**Extractor Updates** (`settings.extractorUpdates`) opens the model-owned center under Connection. Files import validates a bounded package and requires explicit unsigned-source trust before activation. Roll Back Update and Use Bundled Rules preserve the revision floor. No feed or publisher key is configured; there is no automatic rule download. [EXTRACTOR_UPDATES.md](EXTRACTOR_UPDATES.md) owns the format and limits.

Account copy uses `YouTubeConnectionCopy`. Optional post-Welcome Connect YouTube never imports automatically; Settings retains explicit import. Both sign-out actions stop TV lyrics on intent before account sign-out, including Retry. [DISCOVERY_ONBOARDING.md](DISCOVERY_ONBOARDING.md) owns R17 UI-01 evidence. Downloads' separate All/Super Liked/Liked/Not Liked filter does not change a Settings preference; its All/Liked/Not Liked subset passed R17 phone light/dark UI-02 checks.

Authored UI selectors: `GanaBajanaUITests/GanaBajanaSettingsPagesUITests`, `GanaBajanaUITests/GanaBajanaListeningControlsUITests`, `GanaBajanaUITests/GanaBajanaDownloadsUITests`. Label expectations remain exact and selected-state checks use `.isSelected`. No new telemetry; existing download enqueue/outcome events apply. Execution of this follow-up is coordinator-owned.

- One row shape on the main page and every Form-based sub-page: a 28-point decorative tile, a body title and a trailing value or control, at least 44 points tall.
- No description text inside a row. Explanations live in the section footer as short paragraphs, one per topic that needs it.
- One spacing between sections whether or not a section ends with a footer.
- The root is a short list: a status summary, then one row per section page (R14).
- The iCloud status renders in a fixed-height slot that only its own view observes, with a 700 ms hold so short-lived states never reach the screen.

## Visual system

`Sources/UI/SettingsRowStyle.swift` owns the components; `SettingsRowMetrics` holds the numbers.

| Element | Rule |
| --- | --- |
| Row | `HStack` of tile, title, trailing content. `minHeight` 44, row insets 20/20 inside the inset-grouped card. Menu, navigation, information and link rows use `SettingsRowContent`; toggles use `CompactSwitchToggleStyle`; buttons and links use `settingsRowTarget()` for a full-width 44-point hit shape. |
| Tile | `SettingsRowIcon`: 28 by 28 rounded square (corner 7, continuous), fill = glyph tint at 16 percent, glyph 15 pt semibold. Default tint is the accent; iCloud uses green (enabled) or gray (off). Accent color shows its 28-point colour circle and App icon its 28-point preview instead of a tile. Chosen over bare symbols because wide and narrow glyphs no longer change the visual weight of a row, and over iOS-style solid multicolour tiles because the app has one accent palette on a dark or white page. |
| Values | Secondary colour, right-aligned. Menu rows add `chevron.up.chevron.down`; navigation rows get the system chevron; external links add `arrow.up.right`. At accessibility sizes the value stacks under the title, indented by the 40-point text inset. |
| Header | `SettingsSectionHeader`: caption semibold, title case, `minHeight` 24 (28-point supplementary frame). Identifiers `settings.section.<id>` are a contract. |
| Footer | `SettingsFooter`: footnote, secondary colour, 6 points between paragraphs, aligned with the row content inset (x = card + 20), and `footerTopSpacing` (10) above its first line, applied outside the accessibility container so the container frame starts at the text. Each paragraph keeps its `<row>.description` identifier where a test reads it. Footer containers are `settings.footer.<page>.<group>`, for example `settings.footer.playback.shuffle`. A footer cell with a single note reports that note with the whole cell's frame (x = card, including the 10-point gap), so tests take footer geometry from the container and check notes by membership. |
| Section spacing | `listSectionSpacing(24)` from `settingsFormChrome()` (20 in R13). Measured on iOS 26.5: the system default gave 17.3 points after a card and 0 after a footer, so the explicit value is what keeps the rhythm equal. |
| Group header | First header of a page: `settings.section.<page>` (the R13 contract, so tests find a page by it). Later headers: `settings.group.<page>.<group>`. |
| Chrome | `settingsFormChrome()` (body font, 44-point minimum row height, spacing, tint, page colours) and `settingsSectionRows()` (surface fill, insets) on every Form-based Settings page. |

Measured on iPhone 17 Pro, iOS 26.5, dark, default text size (`artifacts/R13/WP16-captures/before` and `after-v2`):

| Measure | Before | After |
| --- | --- | --- |
| Row heights on the main page | 44, 70.3, 84.7, 99, 113.3, 127.7 (control plus 1 to 5 description lines plus 8) | 44 for every row (Automix 44.3 with its hairline divider) |
| Description right edges | ragged, text widths 153 to 290 pt inside rows | footer paragraphs at full 330-pt width |
| Row to description, description to next row | 4 pt, 8 pt | none (no description in rows) |
| Card to next header | 20 pt after a plain row, 28 pt after a described row | 20 pt everywhere (footer end or card end to header frame) |
| Header frame, header to card | 28 pt, 0 | 28 pt, 0 |
| iCloud row height | 70.3 with a one-line status, 84.7 with two lines | 44; status slot 28.7 pt in the footer regardless of wording |

Accessibility XXXL: rows stack their value under the title (unchanged behaviour); footer paragraphs wrap freely; the status slot drops its reservation so nothing truncates.

## Pages (R14 item 18)

`SettingsView` is the root list (`settings.form`, title Settings):

1. Summary: `settings.summary.account` (YouTube: Not signed in, Signed in, Sign-in expired or Sign-out pending) and, in its footer `settings.summary`, a second `SettingsCloudSyncStatusLine` (`settings.summary.icloud`). The root body reads no `cloudSync` property; the status line observes it on its own, and only the Library page's line feeds the flicker fixture's transition counter (`countsFixtureTransitions`).
2. Six navigation rows `settings.page.<playback|library|appearance|discovery|account|about>`, pushing `SettingsPlaybackPage`, `SettingsLibraryPage`, `SettingsAppearancePage`, `SettingsDiscoveryPage`, `SettingsAccountPage` and `SettingsAboutPage` (`Sources/Views/SettingsPages.swift`, `SettingsPage` enum).

3. A search field (`Search Settings`, always visible in the navigation bar). Typing replaces the summary and page rows with results from `SettingsSearchIndex` (`Sources/Views/SettingsSearch.swift`): one entry per row with its title, page, group and everyday keywords ("dark mode", "cache", "eq", "sign in"). Every query word must start a word in the entry; title matches rank first. A result `settings.search.result.<id>` shows the row's title and page, has the accessibility value "Page › Group", and opens that page. No match shows `settings.search.empty`. Import from YouTube Music is offered only with a signed-in session, like its row. A new or renamed row needs its entry in the index and in `GanaBajanaSettingsSearchUITests`, which opens every result and finds its row.

Every page is a Form with the same chrome (`settingsPageChrome`): `settings.form` identifier, inline title, the banner inset and a Done button `settings.done` that closes the whole sheet (`isSettingsPresented = false`), since the page's `dismiss` would only pop it. Groups, in order:

| Page (title) | Groups (header id) | Rows |
| --- | --- | --- |
| Playback | Sound (`settings.section.playback`), Transitions (`settings.group.playback.transitions`), Player (`.player`), Shuffle (`.shuffle`) | Audio quality, Equalizer, Normalize volume; Crossfade and Automix (`settings.transitions`), Gapless playback, Autoplay; Swipe up on the player, Skip non-music sections; Shuffle order |
| Library & iCloud | iCloud (`settings.section.library`), Downloads (`settings.group.library.downloads`), Storage (`.storage`), History (`.history`) | iCloud sync (status slot in the footer); Download over cellular, Download Liked Songs (menu); Storage & cached songs and the recovery rows; Save listening history, Clear listening history |
| Appearance | Theme (`settings.section.appearance`), Player (`settings.group.appearance.player`) | Appearance, Accent color, App icon; Player Background |
| Discovery | Home and mixes (`settings.section.discovery`), Languages and genres (`settings.group.discovery.languages`), Artists (`.artists`), Sources (`.sources`) | Discovery Balance, Customize Home, Moment Mixes; Listening Languages, Listening Genres; Following, New Release Alerts; Catalog Sources |
| Account & connection | YouTube (`settings.section.account`), Connection (`settings.group.account.connection`) | account rows, YouTube Changes; Encrypted DNS, Remote Playback Fallback, Extractor Updates |
| About Velvet Thorn | Velvet Thorn (`settings.section.about`), Credits (`settings.group.about.credits`) | Support development, Help & feedback, Privacy policy, Version; Catalog, On-device audio lookup, Lyrics, Acknowledgements |

The six-section contract is represented by six pages; retained controls keep their row identifiers. Following (`settings.following`) is a button with a chevron and the follow count ("n artists") that calls `MusicAppModel.openFollowingInLibrary()`, which closes Settings, selects Library and scrolls to `library.following`. The Right time label row (`settings.trailingTime`) is gone: `UserPreferences.trailingTimeStyle` stays and only the player's `player.trailingTime` tap writes it.

Cached songs and data management are reached through Settings > Library & iCloud > **Storage & cached songs** (`settings.storage`, destination title Storage). The visible row names the cache browser, and Storage keeps `storage.cachedSongs`, Downloads (`storage.downloads`), cache limits, artwork and saved-data controls. Its cached browser uses `showsOfflineStatus: true` because Settings covers the app's offline bar. Library has Liked songs and Downloads, with no `library.cachedSongs` management entry. Likes' On this device filter and the offline On this device list still include playable cached copies.

## Row catalogue

R13 inventory by section (now by page; see the table above for R14 grouping). Types: T toggle, M menu, N navigation, B button, L external link, I information.

| Section | Row identifier | Type | Trailing | Footer note identifier |
| --- | --- | --- | --- | --- |
| Playback (`settings.section.playback`) | `settings.crossfade` (in `settings.transitions`) | slider | value "n s" | `settings.automix.description` (Crossfade and Automix relation) |
| | `settings.automix` (in `settings.transitions`) | T | switch | see above |
| | `settings.gapless`, `settings.autoplay` | T | switch | none |
| | `settings.normalize` | T | switch | `settings.normalize.description` |
| | `settings.shuffleStyle` | M | style title | `settings.shuffleStyle.description` (history on or off wording) |
| | `settings.audioQuality` | M | tier title | `settings.audioQuality.description` ("Audio quality applies from the next song. <Tier>: <detail>.") |
| | `settings.equalizer` | N | preset summary or Off | none |
| | `settings.playerSwipeUp` | M | action title | none |
| | `settings.sponsorBlock` | T | switch | `settings.sponsorBlock.description` |
| Library & iCloud (`settings.section.library`) | `settings.icloud` | N | On or Off | `settings.icloud.summary` (status slot, first footer line) |
| | `settings.history` | T | switch | `settings.history.description` |
| | `settings.clearHistory` | B | | none |
| | `settings.storage` | N | | none |
| | `settings.downloadsCellular` | T | switch | `settings.downloadsCellular.description` |
| | `settings.autoDownloadLiked` | M | Off, Super Liked Only or All Liked | `settings.autoDownloadLiked.description` (scope wording), then `settings.downloads.background.description` |
| | `settings.library.error`, `settings.library.reload` (only on a storage error) | I, B | "Needs attention" | `settings.library.error.description` |
| Appearance (`settings.section.appearance`) | `settings.appearance` | M | mode title | no footer |
| | `settings.accent` | N | palette title | |
| | `settings.appIcon` (alternate icons supported) | N | icon title | |
| | `settings.playerBackground` (Player group) | M | Off, Drift, Pulse or React to Music | `settings.playerBackground.description` (battery and fallbacks; Theme keeps no footer) |
| Discovery (`settings.section.discovery`) | `settings.discoveryFamiliarity` | M | balance title | `settings.discoveryFamiliarity.description`; the same footer (`settings.footer.discovery.home`) carries `settings.superLikes.description` |
| | `settings.customizeHome` | N | | none |
| | `settings.moments.open` | N | | Device-local learning, motion and per-context controls on the destination |
| | `settings.languages` | N | | shared note on languages and genres (no identifier) |
| | `settings.genres` | N | top family or "Learning" | see above |
| | `settings.sources` | N | "YouTube Music" or "n sources" | `settings.sources.description` (names every enabled source) |
| | `settings.following` | B | "n artists", chevron; opens Library at Following | none |
| | `settings.releaseAlerts` | T | switch | `settings.releaseAlerts.description` |
| Account & connection (`settings.section.account`) | `settings.youtubeSignIn` (signed out or expired) | B | | `settings.youtubeSignIn.description` (signed out) |
| | `settings.youtubeStatus`, `settings.youtubeImport`, `settings.youtubeSignOut`, `settings.youtubeSignOutRetry` (account states) | I, N, B, B | status, last import | session notes, `settings.youtubeError` |
| | `settings.youtubeChanges` | N | | Device/sign-in permission and per-action confirmation on destination |
| | `settings.encryptedDNS` | T | switch | `settings.encryptedDNS.description` (Cloudflare fallback) |
| | `settings.remoteFallback` | T | switch | `settings.remoteFallback.description` (headers disclosure) |
| | `settings.extractorUpdates` | N | | Manual Files trust, unavailable feed and rollback on destination |
| About Velvet Thorn (`settings.section.about`) | `settings.tipJar`, `settings.acknowledgements` | N | | none |
| | `settings.support`, `settings.privacy` | L | arrow | none |
| | `settings.provider.catalog`, `.audio`, `.lyrics` | L | provider name, arrow | none |
| | `settings.version` | I | version string | `settings.version.description` (backup qualification) |

The Version row stays an information row in look and accessibility; seven quick taps are one of the [hidden delights](DELIGHTS.md), which also cover the equalizer pages.
Description identifiers dropped because the row's value or title already carries the meaning: `settings.crossfade.description`, `settings.gapless.description`, `settings.autoplay.description`, `settings.trailingTime.description`, `settings.equalizer.description`, `settings.playerSwipeUp.description`, `settings.storage.description`, `settings.languages.description`, `settings.genres.description`, `settings.icloud.description` (replaced by `settings.icloud.summary`). R18 uses `settings.normalize.description` for the gain-up limits.

Sub-pages on the same components: iCloud sync (`ICloudSyncSettingsView`: the toggle, the status row with its state glyph tile, Sync now, and the What syncs entries all use the tile label), Storage (no icon column at all: metrics, navigation rows, the cache-limit menu and the clear buttons are text rows so the page stays one shape; metric details stay under their title because other tests read them as one combined element, while the downloads, cache-limit and clearing notes moved to footers), Accent color (44-point rows, was 52), Catalog sources (source details moved to the footer; rows are plain toggles), Customize Home (intro and hiding note merged into one footer; rows keep their one-line detail because each is a checklist entry), Equalizer (tiles on Equalizer, Preset, Preamp and Reset; shared header and footer style), Import from YouTube Music and Support development (chrome only). Listening languages and Listening genres stay card-based statistics pages.

Catalog sources value and note filter `enabledCatalogSources` with `!= .youTubeMusic`, so JioSaavn and Gaana are both named (R13 fix for WP9b).

Customize Home lists the seven `HomeSectionKind` cases in the saved order as toggle rows (`home.customization.show.<rawValue>`, 44 points, title plus one-line detail, native reorder handles, `home.customization.reset`). R20 appends `superLiked` (**Super Liked**, "The songs you super liked, newest first.") as the last case: `HomeLayoutPreferences` stores raw identifiers, so a layout saved by the six-section build still reads as default and shows the new shelf last, hidden on Home while there are no super likes. Storage's Saved Library section gains a **Super Liked** value row (`storage.library.superLikes`) directly after Liked Songs. [SUPER_LIKES.md](SUPER_LIKES.md#behaviour) owns the shelf.

## Footer rhythm (R14 item 17)

Measured on iPhone 17 Pro, iOS 26.5, default size, by `testRowsShareOneHeightAndSectionsShareOneRhythm` (note attachment `settings-layout-rhythm`):

| Measure | Before (R13) | After (R14) |
| --- | --- | --- |
| Last row to footer text | 0 pt (the footer's first line starts on the card edge; `settings.footer.library.downloads` measured -0.00001 in `artifacts/R14/WP26-LayoutBefore-01.xcresult`) | 10 pt |
| Footer end to next header | 20 pt | 24 pt |
| Card end to next header (group without a footer) | 20 pt | 24 pt, the same value by design |
| Row height | 44 pt | 44 pt |

## Shuffle default (R14 item 12)

The required behavior is Fewer repeats for new or missing preferences, with every stored Random preserved. Every saved library encodes `shuffleStyle`; the available data cannot distinguish an old default from an explicit selection. An absent or false `shuffleDefaultMigrated` flag is not evidence that the listener never chose Random. Present invalid shuffle values must still fail closed.

`UserPreferences.shuffleStyle` defaults to `.fewerRepeats`; a present value still decodes strictly. `migrateShuffleDefault()` returns `false` without mutation. Its init/reload callers pass through `updatePreferences`' equality guard and create no default-change edit. The `shuffleDefaultMigrated` Codable/sync leaf remains for compatibility, but has no migration behavior. `chooseShuffleStyle(_:)` records an explicit selection and sets that marker; the marker never proves an earlier choice.

`LibraryCloudMergePreparation` excludes shuffle style and its compatibility marker from recommendation invalidation. Mixed history/content edits still refresh Home. Legacy v1/v2 shuffle tombstones retain Random through `LibrarySyncPreferences.resetFields()`; they are not missing preferences in a new library. [ICLOUD_SYNC.md](ICLOUD_SYNC.md) owns this compatibility rule.

Current `AppModelListeningControlsTests` includes `testFreshInstallDefaultsToFewerRepeatsWithoutAMigrationWrite`, `testSavedRandomPreservesBytesAndRevisionsOnLaunchAndReloadRegardlessOfMarker` and `testRandomChosenOnFreshInstallStaysRandomWithoutRepeatedWrites`. `SettingsShufflePreservationTests` covers absent/false/true markers; sync suites cover remote preservation, sparse defaults and strict invalid values. Execution status belongs to the coordinator's R15 evidence.

History off still explains effective Random in the Shuffle footer without erasing the saved choice. Do not automatically reverse values already changed by a partial build: those values also lack reliable choice provenance.

## Flicker fix

Root cause, confirmed with `SettingsRowLayoutTests.testOneSyncOperationPassesThroughShortLivedStatusTexts` (status transitions at 0.2 ms, 27.7 ms and 44 ms into one operation with the test transport) and the before measurement:

1. Every library write that touches sync state calls `LibraryStore.onSyncChange`, which `ICloudLibrarySync.refresh()` debounces for 750 ms and then runs `beginSync()`. Toggling any preference in Settings therefore starts a sync cycle whose `statusText` moves through "Checking iCloud Drive…", "Reading your iCloud library…", "Saving your library to iCloud Drive…" and "Handed to iCloud. Other devices may update later." within milliseconds where iCloud answers quickly.
2. The old iCloud row drew `statusText` as its in-row description. Wording that wraps to a second line (49 to 61 characters do on iPhone SE at default size, and on every phone at larger sizes) changed the row from 70.3 to 84.7 points, so the rows and section below jumped by 14.3 points and back within one cycle.
3. `SettingsView.body` read `model.cloudSync.statusText` and `isEnabled` directly, so every status change re-evaluated the whole six-section form.

Fix (`ICloudSyncSettingsView.swift`):

- `SettingsCloudSyncRow` reads only `isEnabled` for its glyph and value (the accessibility value still reports "On. Status: <text>").
- `SettingsCloudSyncStatusLine` is the first line of the Library & iCloud footer and the only view whose body reads `statusText`, `isSyncing` and `errorMessage`. It projects them through `SettingsCloudSyncStatus`, reserves two footnote lines (`lineLimit(2, reservesSpace: true)`; every status string fits two lines at xxxLarge on iPhone SE, checked by unit test) below accessibility sizes, keeps the glyph in a `@ScaledMetric` 16-point column so the text origin never moves when the symbol changes, and disables implicit animation on the slot.
- A new state is shown only after it has held for `SettingsCloudSyncStatus.holdDuration` (700 ms), implemented with `.task(id:)` so a superseded state cancels its own reveal. The first value on appearance shows immediately.
- `SettingsView.body` no longer reads any `cloudSync` property.

The DEBUG fixture `DebugCloudSyncStatusFixture` (`--icloud-status-fixture`, Darwin notification `com.agraabhi.ganabajana.uitests.icloud.cycle`) stands in for the sync object through `CloudSyncStatusReporting` and replays 120 ms Checking, 1.6 s Reading, 120 ms Saving, then Handed. Both markers are in `tools/audit-release.py`.

## Metrics

None added. These are UI changes; the status slot presents existing sync state. Following reuses Library's existing bounded `event=library_scroll target=following outcome=landed|no_anchor` OSLog event.

R18 pages expose the existing bounded normalization, account-write and extractor-update events. Their feature documents own the metric tables; Settings adds no screen-view or identity telemetry.

## Test coverage

`GanaBajanaR18UITests` covers normalization copy/persistence and manual extractor trust/rollback, plus the separate fake-account opt-in/confirmation workflow. The coordinator reports R18 phone UI-02 export/extractor passing in light/dark. The account confirmation-popover cancellation helper is repaired, with the account workflow rerun and small-phone/iPad matrix pending. [VERIFICATION.md](VERIFICATION.md) owns execution details. Model/client unit and integration cases remain in the feature documents, with no real-account submission by tests.

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `SettingsSearchTests` | every-word matching, title-first ranking, keyword hits, blank queries, sign-in-only rows, unique ids covering all six pages | unit |
| `GanaBajanaSettingsSearchUITests.testEverySearchResultOpensThePageThatShowsItsRow` | each of 38 signed-out entries ranks first for its title, opens its page and reveals its row; Back returns to the results | integration |
| `GanaBajanaSettingsSearchUITests.testEverydayWordsNoMatchAndClearingInLightAndDark` | keyword results with page location, sign-in-only row hidden, empty state, Clear restores the page list, light and dark | integration |
| `SettingsRowLayoutTests.testRowMetricsKeepTheDocumentedShape` | metrics constants (28, 40, 44, 20/20, section spacing 24, footer top 10) | unit |
| `testStatusGlyphFollowsTheSyncState` | `SettingsCloudSyncStatus.symbolName` for off, syncing, error, idle, off with stale error | unit |
| `testStatusProjectionReadsTheSyncObject` | projection from `ICloudLibrarySync`, changes after `setEnabled(false)` | unit |
| `testSlotReservesTwoLinesOnlyBelowAccessibilitySizes` | `reservedLineCount` at large, xxxLarge, accessibility sizes; 700 ms hold | unit |
| `testEveryStatusFitsTheReservedLinesOnTheSmallestPhone` | all 17 status strings at xxxLarge footnote width on iPhone SE fit 2 lines | unit |
| `testOneSyncOperationPassesThroughShortLivedStatusTexts` | one sync cycle publishes several texts, each held under 700 ms | unit |
| `GanaBajanaSettingsLayoutUITests.testRowsShareOneHeightAndSectionsShareOneRhythm` | every root and page row is 44 pt, no `.description` inside a row, footers align at the content inset, one header-to-card gap, row to footer 10 pt, footer or card to next header 24 pt | integration (17 Pro, SE, iPad) |
| `testICloudStatusChangesLeaveTheLibrarySectionStill` | on the Library page: iCloud header, row, status slot, Downloads header, rows and note keep frames; Checking and Saving never shown; Reading and Handed are the two visible changes | integration |
| `GanaBajanaSettingsPagesUITests` | summary and six root rows; each page's header and actual Done dismissal; grouped Playback; Following lands on Library; no time-label setting; repeated page helpers keep the scroll position, nested Storage > Cached songs returns safely, and one Back reaches the root without duplicate pages | UI integration; R15 execution owned by coordinator |
| `GanaBajanaPlayerShellUITests.testRightTimeLabelIsSetFromThePlayerOnlyAndPersists` | no Settings row; the player tap persists across relaunch | integration |
| `SettingsShufflePreservationTests.testSavedRandomWithoutProvenanceIsNeverRewritten` | stored Random with absent/false/true compatibility marker preserves all preference leaves | unit; R15 execution owned by coordinator |
| `AppModelListeningControlsTests`, `LibraryPlaybackDiscoveryPreferencesTests`, `LibrarySyncPlaybackDiscoveryPreferencesTests` | fresh/missing defaults, saved choices, queue and journal preservation, strict invalid-value handling and remote merge behavior | unit; preservation expectations present in source |
| `testRecordsSettingsLayoutMeasurements*` (4) | frame dump and captures per page in dark, light, default and accessibility XXXL | integration (evidence) |
| `GanaBajanaListeningControlsUITests.testIconLabeledSettingsKeepSixSectionsAndNativeTargetsAtLargestTextSize` | six sections, every row 44 pt with its label at accessibility XXXL, footers present except Appearance | integration (17 Pro, SE, iPad) |
| `GanaBajanaListeningControlsUITests` shuffle and discovery notes | footer notes sit in their section footer at the content inset, rows stay 44 to 52 pt | integration |
| `GanaBajanaSettingsOrganizationUITests.testSettingsRowsKeepCompactNativeTargetsAndConsistentDescriptionGaps` | eleven rows share one height; noted rows explain themselves in their footer; unnoted rows have no note | integration |
| `GanaBajanaSettingsOrganizationUITests.testLargeTextKeepsDisclosuresAndDestructiveActionsReadable` | history, release alerts, encrypted DNS and remote fallback disclosures stay readable at accessibility XXXL | integration |
| `GanaBajanaICloudSettingsUITests` | row value "On. Status: …", sub-page status, toggle persistence | integration |
| `GanaBajanaAudioQualityUITests`, `GanaBajanaSponsorBlockUITests`, `GanaBajanaDownloadsUITests`, `GanaBajanaCatalogSourcesUITests`, `GanaBajanaPlayerShellUITests`, `GanaBajanaPlayerGesturesUITests`, `GanaBajanaEqualizerUITests` | footer wording and dropped notes | integration (assertions updated) |
| `GanaBajanaAccentUITests`, `GanaBajanaTipJarUITests` (settings row test), `GanaBajanaYouTubeImportUITests` (import row test), `GanaBajanaCompactControlsUITests`, `GanaBajanaHomeCustomizationUITests`, `GanaBajanaStorageUITests`, `GanaBajanaGaanaUITests` and `GanaBajanaGenreProfileUITests` (settings row tests), `GanaBajanaCachedSongsUITests` inventory test | sub-page chrome and rows, 44-point accent rows, storage metrics still read as one element | integration |

## Historical WP26 verification status

The following existing artifacts were inspected during the resumed work. They predate these Settings/helper/test edits. No build or simulator/test run was performed for the resumed changes; the coordinator owns regeneration and execution on the shared working set.

| Evidence under `artifacts/R14/` | Verified result |
| --- | --- |
| `WP26-build-06.log` | Latest WP26 build-for-testing log ends `TEST BUILD SUCCEEDED`; not a build of the resumed edits. |
| `WP26-test-09.log`, `WP26-SettingsRerun17Pro-01.xcresult` | 12 passed, 0 failed: four page tests, three listening-control tests and five Settings organization tests on iPhone 17 Pro. |
| `WP26-test-11.log`, `WP26-PagesSE-01.xcresult` | Four page tests passed on iPhone SE 3. |
| `WP26-test-12.log`, `WP26-PagesiPad-01.xcresult` | Three page tests passed; Following failed at the `tabBars` query after reaching Library. The resumed test resolves `tab.library` first and checks that a TabBar exists before querying descendants. Rerun pending. |
| `WP26-test-08.log`, `WP26-SettingsUI17Pro-01.xcresult` | The player-only time-label persistence test and all seven Settings layout tests passed. The overall run failed; it is not a green regression suite. |
| `WP26-test-10.log`, `WP26-HeavyUI17Pro-01.xcresult` | 61 passed, 8 failed, 11 skipped. Failures cover cached inventory at large text, three rotation checks, three mini-player scroll checks and the seek/transport/sleep workflow. Those remain coordinator follow-ups. |
| `WP26-test-03.log`, `WP26-Unit-02.xcresult` | 74 unit tests passed on the earlier source. The saved-Random overwrite expectations are superseded by the preservation requirement above. |

Coordinator regression selectors for the integrated source (results belong in the R15 verification entry):

```text
-only-testing:GanaBajanaTests/SettingsShufflePreservationTests
-only-testing:GanaBajanaTests/SettingsRowLayoutTests
-only-testing:GanaBajanaTests/AppModelListeningControlsTests
-only-testing:GanaBajanaTests/LibraryPlaybackDiscoveryPreferencesTests
-only-testing:GanaBajanaTests/LibrarySyncPlaybackDiscoveryPreferencesTests
-only-testing:GanaBajanaUITests/GanaBajanaSettingsPagesUITests
-only-testing:GanaBajanaUITests/GanaBajanaSettingsLayoutUITests/testRowsShareOneHeightAndSectionsShareOneRhythm
-only-testing:GanaBajanaUITests/GanaBajanaSettingsLayoutUITests/testICloudStatusChangesLeaveTheLibrarySectionStill
-only-testing:GanaBajanaUITests/GanaBajanaListeningControlsUITests
-only-testing:GanaBajanaUITests/GanaBajanaSettingsOrganizationUITests
-only-testing:GanaBajanaUITests/GanaBajanaStorageUITests
-only-testing:GanaBajanaUITests/GanaBajanaPlayerShellUITests/testRightTimeLabelIsSetFromThePlayerOnlyAndPersists
```

Run the five page tests, the two layout checks and `GanaBajanaListeningControlsUITests` on 17 Pro, SE 3 and iPad. The organization, storage and player-only persistence selectors above currently use the phone driver's launch/tab helpers; run them on 17 Pro and SE. The iPad page suite covers the Settings-to-Storage-to-Cached songs route.

The broad run's pending selectors are:

```text
-only-testing:GanaBajanaUITests/GanaBajanaCachedSongsUITests/testControlsRemainReachableAtLargestDynamicTypeOnPhoneAndIPad
-only-testing:GanaBajanaUITests/GanaBajanaRefinementUITests/testLargePlayerTextAndLightLandscapeKeepControlsReachable
-only-testing:GanaBajanaUITests/GanaBajanaRefinementUITests/testLowerSheetListsExpandAndSwipeDismissWithoutClosingThePlayer
-only-testing:GanaBajanaUITests/GanaBajanaRefinementUITests/testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabs
-only-testing:GanaBajanaUITests/GanaBajanaRefinementUITests/testMiniPlayerKeepsLastRowsAboveTheBarAcrossTabsAtLargestTextSize
-only-testing:GanaBajanaUITests/GanaBajanaRefinementUITests/testMiniPlayerKeepsPushedScrollAndListEndsAboveTheBarAtLargestTextSize
-only-testing:GanaBajanaUITests/GanaBajanaWorkflowUITests/testPlayerSeekTransportRepeatAndSleepTimer
-only-testing:GanaBajanaUITests/GanaBajanaWorkflowUITests/testWelcomeStartsWithoutLanguageSelectionAndLandscapeKeyboardRemainsReachable
```

Rotation checks require `GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1` in the test runner as documented in `AGENTS.md`. No rotation failure is considered fixed without that rerun. [ROADMAP.md](ROADMAP.md) and [VERIFICATION.md](VERIFICATION.md) remain coordinator-owned.

## Not verified

- Physical devices and the owner's own iCloud account: the sync cycle timings above come from the test transport and the fixture, not from iCloud Drive.
- Mac (Designed for iPad) and CarPlay are outside this package.
- Import from YouTube Music and Support development got chrome-only changes and one capture each in the WP16 report; their UI classes were not rerun beyond the import row test listed there.
- Import from YouTube Music keeps its default row insets (chrome only: the shared font, spacing and colours); Support development keeps its 52-point tip rows through an explicit `defaultMinListRowHeight` after the shared chrome. Neither page was redesigned.
