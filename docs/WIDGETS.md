# Widgets and Controls

Velvet Thorn has Recently played, Liked songs and Mix widgets for iPhone and iPad, plus Lock Screen widgets and Controls ([below](#lock-screen-widgets-and-controls)). Each supports small, medium and large sizes. Edit a Mix widget to choose Daily Mix 1, Daily Mix 2, Daily Mix 3 or Discover Weekly ([DAILY_MIXES.md](DAILY_MIXES.md)). WidgetKit controls placement and refresh timing.

## Actions

| Widget | Small | Medium and large |
| --- | --- | --- |
| Recently played | Open Velvet Thorn and resume the first saved recent song | Tap a song to resume it; tap the heading to browse recent listens |
| Liked songs | Open Velvet Thorn and play the first liked song | Tap a song to play it; tap the heading to browse the live liked list |
| Mix | Open the selected saved mix | Open the mix or use Play mix |

The app resolves actions against its current saved library. A removed song cannot be restored from an old widget entry. A Play mix action carries its saved period: if that period has changed, Velvet Thorn opens the current mix for a new selection instead of starting different music. Opening a list keeps current playback intact. Selecting an already-current recent song keeps its queue and position.

Known-offline playback waits for the existing cache inventory before accepting a selection. A recent song's saved position is applied only after that song is accepted. Mix playback uses its compatible cached members. An unavailable inventory or an uncached selection leaves existing playback in place. Newer navigation, privacy changes and native playback controls retire a deferred widget action, including a pause/resume or seek/back sequence.

## Shared data

`BreezyWidgets` is an embedded WidgetKit extension, bundle `com.agraabhi.ganabajana.widgets`, with minimum iOS 18. The phone and extension share `group.com.agraabhi.ganabajana`. The Watch has no App Group entitlement; the extension has no iCloud or CarPlay entitlement.

`WidgetSnapshotPublisher` reads durably saved state from `LibraryStore` through `onWidgetLibraryChange`. It publishes an atomic derived file at `Library/Caches/BreezyWidgets/widget-library.json` in the shared container. The installed library stays at its existing path and retains its format and sync journal.

The version-1 projection reuses `Track`, `ArtistCredit` and `GeneratedPlaylist`. It includes up to six recent songs, six liked songs and six preview songs for each of up to four saved mix kinds (Discover Weekly and Daily Mix 1 to 3). Full liked/mix counts are separate from preview length. A super like ([SUPER_LIKES.md](SUPER_LIKES.md)) is an ordinary like in the snapshot: the Liked songs widget lists it like any other like, and the version-1 snapshot carries no tier field. The extension reads metadata and local thumbnails, with no catalog, account, audio or artwork-network client.

| Bound | Value |
| --- | --- |
| Snapshot file | 1 MiB, checked before reading its contents |
| Recording and period identifiers | 256 UTF-8 bytes |
| Song title / credited name | 384 / 192 UTF-8 bytes |
| Credits per song | 4 |
| JPEG thumbnail | 240 pixels per side, 24 KiB per image |
| Combined artwork | 512 KiB, at most 24 displayed recording IDs |

Metadata publishes before optional artwork. `ArtworkLoader.cachedThumbnail` checks its existing response cache and downsamples locally. A cache miss produces the widget's artwork placeholder. Delayed artwork must match the current publication generation and saved source; it cannot restore cleared data. No remote URLs, audio, listening-session records, account credentials or transaction data enter the shared file. The derived directory and file are excluded from backups on successful writes.

Turning listening history off hides recents on the widget while retaining explicit likes and saved mixes. Clearing history removes recents and generated mixes. An unavailable or externally changed library publishes an unavailable state. Existing corrupt, oversized or future-version widget files are preserved and reported as unavailable rather than overwritten.

Content-identical updates do not rewrite the file or request a reload. Successful changes request reloads for the three widget kinds. A publication retry retains any outstanding reload obligation even if the first attempt replaced data before failing to set file metadata. WidgetKit also receives a 30-minute refresh request; neither path guarantees immediate on-screen updates.

## Navigation and ownership

`MusicWidgetRoute` encodes and strictly parses `ganabajana://widget/open`, `/play` and `/mix`. Parameters have fixed names and bounded values; duplicate or unknown parameters and foreign authorities are rejected. Existing Search links keep their route. A link contains an identifier and source, never a playable URL.

`MusicAppModel` owns action handling, library validation and the deferred offline task. `PlayerController.controlRevision` identifies native/companion control changes while that task is waiting. Playback still goes through the existing player and resolver. WidgetKit does not play audio in the extension or generate new mixes.

Mix configuration uses a native options provider (`MixWidgetOptions`) with the existing `GeneratedPlaylistKind` raw values and separate display titles. An unset or unknown selection defaults to Daily Mix 1; the original `dailyMix` value is Daily Mix 1 and `dailyMix1` is accepted as an alias, so saved configurations keep resolving. The string boundary avoids an observed AppEnum runtime resolution failure that silently displayed Daily Mix for a saved Discover Weekly selection.

The shared visual implementation is `MusicWidgetView`. Action frames use 46 points so their pixel-aligned native bounds retain the 44-point minimum. Small widgets supply a card-sized accessibility representation because WidgetKit otherwise associated the link with a decorative descendant. Large text reduces visible rows/artwork, and personal content uses `privacySensitive`. The system's widget appearance governs full-color and accented rendering; the saved app accent supplies Velvet Thorn's full-color tint.

## Lock Screen widgets and Controls

| Surface | Kind | Families or placement | Tap |
| --- | --- | --- | --- |
| Play or Pause widget | `Breezy.NowPlaying` | Lock Screen circular, rectangular and inline; small on the Home Screen and Today View | The play/pause button runs `TogglePlaybackIntent`; the rest opens the player through `ganabajana://player` |
| Open Velvet Thorn widget | `Breezy.Launcher` | Lock Screen circular | Opens Velvet Thorn |
| Play or Pause Control | `com.agraabhi.ganabajana.control.playPause` | Control Center, Lock Screen and Action button | Toggle backed by `SetBreezyPlaybackIntent` |
| Open Velvet Thorn Control | `com.agraabhi.ganabajana.control.open` | Control Center, Lock Screen and Action button | `OpenBreezyPlayerIntent`, `openAppWhenRun` |

**Playback runs in the app.** The intents in `Sources/Core/Widgets/PlaybackControlIntents.swift` compile into both targets. The system runs the two `AudioPlaybackIntent` intents and the open intent in the app process, where `PlaybackIntentRuntime` reaches `MusicAppModel.performPlaybackIntent`. After a cold launch, `init` has already restored the paused queue, so Play resumes the last song or station at its saved position. In the extension the hook is nil and an intent does nothing. Play and pause cancel a pending radio request; nothing starts before Welcome is complete or while the library is unloaded.

**Shared state.** `PlaybackWidgetPublisher` writes `widget-playback.json` (version 1, at most 4 KiB) next to the library snapshot. It holds selection, play state (playing or loading), live-radio flag, title, subtitle and accent. Titles are capped at 192 UTF-8 bytes. With listening history off, the title and subtitle are nil. The publisher observes the player and library and debounces for 300 ms. Identical state is not rewritten, and every real change reloads the Play or Pause widget and Control; position ticks never write. Timelines use `.never`, because the app reloads them.

**Accent.** Full-colour surfaces and the Control tint use the saved accent; accented and vibrant rendering follow the system.

## Metrics

Diagnostics use local numeric OSLog in category `Widgets`. No events are sent to an analytics service, and URLs, titles and identifiers are absent from the fields.

| Event | Fields | Purpose |
| --- | --- | --- |
| `widget_snapshot` | success, unchanged, failure, unavailable; bounded recent/liked/mix/artwork counts and bytes | Publication and recovery outcomes |
| `widget_timeline` | widget kind, weekly; ready, empty, unavailable | Extension selection/read outcome |
| `widget_open` | widget kind, play; success, stale, unavailable, offline, invalid, cancelled | App route outcome |
| `widget_playback_state` | success, changed, selection, playing, radio, titled | Lock Screen and Control state publication |
| `playback_intent` | action (toggle, play, pause, openPlayer); outcome (success, unchanged, noSelection, unavailable) | Widget, Control and Shortcuts requests |

Outcome flags include zero counterparts. Tests assert saved state, invalidation effects and native behavior rather than OSLog text.

## Test coverage

| Tests | Coverage | Level |
| --- | --- | --- |
| `WidgetSnapshotTests`, `WidgetSnapshotStoreTests` | Projection bounds, metadata minimization, strict read validation, atomic writes, backup metadata failures and equal-content suppression | Unit with isolated files |
| `WidgetPublisherLibraryCallbackTests`, `WidgetPublisherTests`, `WidgetPublisherThumbnailTests` | Durable changes, cloud/reload, failed storage, history boundaries, delayed/ABA artwork and reload recovery | Unit with isolated files |
| `WidgetPublisherCacheOnlyTests` | Cached image candidates, miss/failure/clear, response limits and zero requests | Unit |
| `MusicWidgetRouteTests` | Route round trips, encoding and malformed input | Unit |
| `AppModelWidgetNavigationTests`, `AppModelWidgetPlaybackTests`, `AppModelWidgetMixTests` | Current membership, welcome/recovery, saved mix periods, resume and pending radio intent | Model integration |
| `AppModelWidgetOfflineTests`, `AppModelWidgetSupersessionTests` | Gated cache inventory, real local audio, refused playback and newer intent/privacy boundaries | Native playback integration |
| `MusicWidgetPresentationTests` | Empty/private states, counts, layouts, image fallback and rendered appearance | Unit/rendering |
| `GanaBajanaWidgetPreviewUITests`, `GanaBajanaWidgetLinksUITests` | Exact shared view on fixed canvases; actual collection/queue, URI activation, relaunch, long text, light/dark and offline playback | UI |
| `GanaBajanaNativeWidgetsUITests` | Actual WidgetKit gallery, shared container, Home Screen placement, Mix configuration and cached playback | Native UI |
| `PlaybackWidgetTests` | Playback state store bounds and versions, presentation text, intent-to-command mapping, play/pause/open on a restored queue, no selection, before Welcome, history redaction, accent and no writes on ticks | Unit and native playback integration |

`docs/VERIFICATION.md` records execution outcomes. DEBUG preview canvases establish shared-view layout, not SpringBoard placement. Native gallery tests use an explicitly enabled isolated app fixture on a dedicated QA simulator. Source fixture types and launch switches are excluded from Release. Physical VoiceOver, device refresh scheduling and Mac/Continuity widget placement require separate acceptance.
