# Player More sheet (R14)

R14 WP25 and R15 integration: order of the player's More sheet, the single share entry and song card, the downloaded row, the Dislike
explanation and the equalizer entry. The equalizer itself, its Simple mode, saved presets and per-song overrides
are owned by [EQUALIZER.md](EQUALIZER.md); downloads by [DOWNLOADS.md](DOWNLOADS.md); Song details by
[SONG_DETAILS.md](SONG_DETAILS.md).

## Order

`PlayerOptionsSheet` (`player.options.sheet`, list `player.options.list`), one card:

1. Super Like (`player.options.superLike`, `bolt.heart.fill`), value "Counts more in your mixes and can download on its own."
   While the song is super liked the row reads Change to Like (`heart.fill`), value "Keeps the like, drops the extra weight." A tap runs
   `MusicAppModel.toggleSuperLike(_:surface: .more)` and closes the sheet. Track menus offer the same two labels; [SUPER_LIKES.md](SUPER_LIKES.md) owns the tier.
2. Don't Recommend This Song (`player.options.dislike`), hidden while the song is liked; value "Keeps this song out of mixes and radio."
   Undo is Allow Recommendations, with "Lets this song back into mixes and radio." Track menus use the same labels and accessibility explanation.
3. Share Song (`player.options.share`), value "Preview the cover, song details and link"; opens `SongShareCardPage`.
4. Divider, then Start Radio (`player.options.radio`), Song Details (`player.options.details`), Go to Album (`player.options.album`), Go to Artist
   (`player.options.artist`), Add to Playlist (`player.options.playlist`).
5. YouTube Changes for an eligible recording, then with a download center: Download or its state (`player.options.download`), Export Audio (`player.options.export`).
6. Equalizer (`player.options.equalizer`), value Off, the preset or saved preset name, Custom, or "This Song".
7. Sleep Timer (`player.sleepTimer`) and, while one runs, Cancel Sleep Timer (`player.sleepTimer.cancel`).
8. For the current song only, after a divider: Audio Quality (`player.options.audioQuality`), Reload Best Available
   Audio (`player.options.reloadAudioQuality`), the cache captions (`player.options.cache.*`), then Skipped n
   non-music sections (`player.options.sponsorBlock`, only while positive).

The separate `player.options.shareCard` row is removed; `PlayerOptionsRoute.shareCard` remains the preview route,
titled Share song. Pushed pages include Song details, Go to artist, Add to playlist, New playlist, Sleep timer,
Export audio, Equalizer (`PlayerEqualizerSheet`), More controls (`EqualizerView`) and Share song. Pushing New
playlist, Song details, either Equalizer page or Share song raises the sheet to the large detent.

Start Radio captures the displayed recording and closes Song Options. When it is already current, attachment preserves its position and paused/playing intent. Tune Radio lives in Queue and the Radio browser, with one shared draft sheet. [SEED_RADIO.md](SEED_RADIO.md) owns continuation and tuning.

## Sharing

- More has one **Share song** entry (`player.options.share`) that opens the preview before any system share sheet.
  `TrackActionsMenu` supplies `onShareCard` to `TrackActionButtons` and exposes the same one **Share song** action
  (`track.share.<id>`), presenting `SongShareCardSheet` with Done (`songShare.done`). There is no second
  `track.shareCard.<id>` row. Callers without a preview presenter retain a **Share song link** fallback at
  `track.share.<id>`, only when `Track.shareURL` exists.
- `SongShareCardPage` shows the preview (`songShare.preview`, label "Song card for <title>"). Once rendered,
  **Share** (`songShare.share`) sends the picture with the URL as its message
  (`ShareLink(item: Image, subject:, message:, preview:)`). **Share link only** (`songShare.linkOnly`) shares the
  URL with a title preview and is available even while the picture is preparing. `Track.shareURL` is a YouTube
  Music watch URL or JioSaavn/Gaana search page; if absent, the image's message uses the song title and the link-only
  action is omitted. Share targets decide how they retain or render the image and message.
- `SongShareCard` is 1080 by 1350 points drawn by `ImageRenderer` at scale 1 (exactly 1080 by 1350 pixels, opaque):
  760-point artwork (large tier, 1080 px; a waveform placeholder without artwork), title (60 pt bold, two lines),
  artists (40 pt, one line), album and year (32 pt, one line), duration and source name, a "Listen on YouTube
  Music" / "Listen on JioSaavn" / "Listen on Gaana" line and the app name "Velvet Thorn". Long text truncates with an
  ellipsis; the card never grows. Light and dark follow the current appearance.
- Album and year come from `TrackDetails` (Song details) when `model.songDetails.details(for:refresh: false)`
  answers within 2 s (`SongShareCardRenderer.details(from:for:deadline:)`); a cached entry answers at once, offline
  lookups read files only. Otherwise the card shows the track's own album title and no year.

## Download row

- Not downloaded: "Download", `arrow.down.circle`, value "Keeps this song on this device."
- Queued or waiting for Wi-Fi: the state title with `arrow.down.circle.dotted`, value "Tap to cancel".
- Downloading: "Downloading 42%", a thin accent progress bar under the title, value "Tap to cancel".
- Downloaded: "Downloaded" with `arrow.down.circle.fill` in `AppTheme.accent` and the value "Remove download". A tap
  asks "Remove download?" (Remove download, `player.options.download.remove`, and Cancel; "The song stays cached
  for now.") and then demotes it to the cache, matching the player's Download button.
- Failed: "Download failed", value "<reason> Tap to retry."

## Dislike

Disliking is local to the library (`LibraryStore.toggleDislike`): it adds a `DislikedSong` (id, title, artists,
date), removes any like and super like, and drops the song from saved generated mixes. `MusicAppModel.toggleDislike` also removes
it from the Home shelves on screen and from a running radio queue, and skips it when it is playing with more songs
queued. Generated mixes, autoplay (`autoplaySelection`, `AutoplayContinuation`) and radio
(`ExperienceRadioEngine.isDisliked`, which also matches other versions by core title) exclude it; a song the
listener picks explicitly still plays. Nothing is sent to YouTube Music, JioSaavn or Gaana. The dislike syncs to
the listener's other devices through iCloud as a reaction register (`LibrarySyncReaction.disliked`). Decision (R14
item 9): there is no Dislike button on the main player; the heading keeps one like control.

## Metrics

The Super Like row logs `super_like action=promote/demote surface=more` through `MusicAppModel.toggleSuperLike`
([SUPER_LIKES.md](SUPER_LIKES.md#metrics)); the sheet adds nothing of its own. The equalizer rows reuse the Equalizer category events in [EQUALIZER.md](EQUALIZER.md#metrics);
sharing is a system share sheet and logs nothing (no identifiers or titles are logged).

## Coverage

The title-case follow-up preserves route and control identifiers and the existing dislike semantics, including skipping an actively playing song and allowing explicit playback. `GanaBajanaUITests/GanaBajanaPlayerMoreUITests/testRecommendationExclusionPersistsAndCanBeUndoneWithoutBlockingExplicitPlayback` covers the exact exclusion/undo copy, relaunch persistence, explicit playback and track-menu undo. The existing More order and `GanaBajanaRefinementUITests` skip workflow keep exact updated labels. All follow-up execution is coordinator-owned. No new metrics or remote telemetry.

| Case | Path | Unit or integration |
| --- | --- | --- |
| `SongShareCardTests.testContentUsesTrackFactsAndDetailsWhenKnown` | Title, artists, album, year from `releaseDateText`, invalid year, duration, source and listen lines for all three sources, share URL | Unit |
| `testCardRendersAtTheFixedSizeInLightAndDark` | 1080 by 1350 at scale 1, light corner near white, dark near black | Unit (ImageRenderer) |
| `testLongNamesTruncateInsideTheCard` | Very long title, twelve artists, long album, over an hour; with and without artwork | Unit |
| `testDetailsLookupGivesUpAtTheDeadline` | Slow details provider ignored after the deadline; a fast one fills the card | Unit |
| `GanaBajanaPlayerMoreUITests.testMoreSheetLeadsWithDislikeAndSharingAndKeepsEveryRowInOrder` | Row order by frame, single Share song entry and absent shareCard row, Equalizer value Off, card preview 4:5, Share and Share link only, Dislike above Share with its value after unliking | UI |
| `GanaBajanaR19UITests` (menu rows) | Super Like row first with its value, Change to Like after a promotion, the sheet closing on the tap; see [SUPER_LIKES.md](SUPER_LIKES.md#test-coverage) | UI |
| `testDownloadedRowKeepsItsFilledGlyphAndAsksBeforeRemoving` | Download promotes the cached fixture copy, label Downloaded, value Remove download, accent pixels in the glyph column, confirmation, back to Download | UI (cache fixture) |
| `testEqualizerFromMoreKeepsAPerSongOverrideAcrossASkip` | See [EQUALIZER.md](EQUALIZER.md#test-coverage) | UI |
| `GanaBajanaDownloadsUITests.testPlayerDownloadPromotesTheCachedSongAndDownloadsScreenListsAndDeletesIt`, `GanaBajanaPlayerDownloadUITests.testDownloadButtonDownloadsTheSongAndRemoveReturnsItToTheCache` | More row reads Downloaded with the Remove download value (assertions updated from "Remove download") | UI |
| `GanaBajanaRefinementUITests` More-sheet tests | Share row reachable, 52-point targets, Dislike hidden when liked and closing the sheet with a skip | UI (unchanged assertions) |

## Runs

The R14 runs below predate share consolidation. The coordinator's upcoming R15 entry in
[VERIFICATION.md](VERIFICATION.md) owns integrated execution evidence; these receipts do not verify the new flow.

All on a dedicated iPhone 17 Pro / iOS 26.5 simulator with `artifacts/R14/DerivedData-WP25`.

- `artifacts/R14/WP25-Unit-01.xcresult`: EqualizerProfileTests 11, SongShareCardTests 4, EqualizerTests 14; 29
  tests, 0 failures.
- `WP25-UI-01.xcresult`: first UI pass, PlayerMore and Equalizer UI, 5 tests, 5 failures, all test-side (the
  medium detent kept lower rows out of reach; the longer equalizer page recycled the preset row before its value was
  read; the Simple slider's accessibility frame is the native 31-point control). Tests fixed.
- `WP25-UI-02.xcresult`: 5 tests, 1 failure (the preset helper scrolled the wrong way once the row was recycled;
  helper fixed to scroll toward the top).
- `WP25-Touched-03.xcresult`: EqualizerProfileTests 11, SongShareCardTests 4, GanaBajanaEqualizerUITests 2,
  GanaBajanaPlayerMoreUITests 3, GanaBajanaPlayerDownloadUITests download test 1, seven GanaBajanaRefinementUITests
  More-sheet tests, GanaBajanaDownloadsUITests player test 1, GanaBajanaSongDetailsUITests 3; 32 tests, 4 failures:
  the Downloads test could not reach the lower Download row at the medium detent and the three Song details tests
  asserted the R13 order. Both fixed.
- `WP25-Rerun-04.xcresult`: GanaBajanaSongDetailsUITests 3, the Downloads player test and SongShareCardTests 4; 8
  tests, 0 failures.
- `WP25-Unit-05.xcresult` (after the card accent fix): EqualizerProfileTests 11, EqualizerTests 14,
  SongShareCardTests 5, PlayerMore order test 1; 31 tests, 0 failures.
- Captures: `artifacts/R14/WP25-captures/` (More sheet top, Dislike, Downloaded row, equalizer sheet with the song
  override, Advanced page, Simple page, share card preview, rendered cards light, dark, long text and artwork).

## Not verified

- Messages' rendering of the link preview and of the picture plus link on a device (the simulator share sheet only).
- The card at accessibility text sizes (it is a fixed-size picture; the preview page scales with the text).
