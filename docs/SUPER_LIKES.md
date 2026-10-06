# Super Likes

R19 (`1.0.0 (9)`, local and uncommitted) adds a stronger tier above a like. Unit, phone/SE/iPad light/dark and unsigned Release checks passed; [VERIFICATION.md](VERIFICATION.md) owns counts and limits. The owner's story: many songs earn a like, a few earn a super like (Heartless by Kanye West), and those few should count more in mixes and be the ones that download on their own. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts; [ROADMAP.md](ROADMAP.md) items 14 and 15 hold the Watch/CarPlay follow-up and the deferred extras.

## Behaviour

A super like is a like with more weight. A super liked song stays in Liked Songs, `LibraryStore.isFavorite` stays true for it, and every existing like consumer (widgets, import, Moment Mixes, Not Liked downloads) keeps working unchanged; the Watch and CarPlay show the tier through companion wire version 2.

**Gestures.** Tapping the heart toggles a like exactly as before; tapping it on a liked or super liked song removes the song from Liked Songs completely. Holding the heart (0.4 s) toggles the super like: not liked or liked becomes super liked, super liked steps back to liked. Menus offer the same without the gesture: **Super Like** when the song is not super liked, **Change to Like** and **Remove from Liked Songs** when it is. The heart exposes **Super Like** / **Change to Like** as a VoiceOver custom action.

**Order.** A promotion or demotion is a new reaction revision, so the song moves to the top of Liked Songs on this device and, after sync, on the others. Newest reaction first is the existing synced order; the local edit matches it instead of jumping later.

**Look and feel.** `bolt.heart.fill` in the accent when super liked, `heart.fill` when liked, `heart` outline otherwise, all in the same 52-point `player.like` target. Promotion plays the success haptic and a 0.12 s scale bounce; Reduce Motion removes the bounce. Song rows and menus use `bolt.heart.fill` for the action glyph. No toast.

**Discoverability.** Four layers, so nobody has to guess the gesture:

1. `SuperLikeTip` (TipKit) anchors to the heart after the listener likes a song with the player open. It shows once, is dismissable, and its state lives in TipKit's device datastore. Copy: title **Hold to Super Like**, message "Super likes count more in your mixes and can download on their own."
2. Text rows in the song context menu, Player More (first row) and Liked Songs swipe actions.
3. A **Super Liked** filter in Liked Songs and Downloads whose empty state explains how to add one, and the three-way download control naming Super Liked Only. Settings > Discovery gets a footer: "Super liked songs count more in Daily Mixes and seed Discover Weekly."
4. The glyph change and haptic on promotion.

**Liked Songs.** Filters read All, Super Liked, Downloaded, On This Device (`library.likes.filter.superLiked`). Super Liked empty state: **No Super Likes Yet**, "Hold the heart on a song you love, or choose Super Like from its menu." Leading swipe: **Super Like** / **Change to Like** (`library.superLike.<id>`); the trailing **Unlike** swipe is unchanged.

**Downloads.** Filters read All, Super Liked, Liked, Not Liked (`downloads.filter.superLiked`). Not Liked still means absent from favorites.

**Download Liked Songs** becomes a three-way choice in Liked Songs (`library.likes.autoDownload`) and Settings > Library & iCloud > Downloads (`settings.autoDownloadLiked`): **Off**, **Super Liked Only**, **All Liked**. Choosing a scope with a backlog confirms it first (existing alert, counts now follow the scope). New likes download under All Liked; promotions download under Super Liked Only and All Liked. Narrowing the scope never deletes files; Remove Download stays manual. All Liked hides the Downloaded/On This Device chips as before; Super Liked Only keeps them.

**Recommendations.**

- `TasteProfile.superLikeBoost = 540`, three times `favoriteBoost`, credited to the track and its artists instead of the like credit. `superLikedTrackIDs` is exposed beside `heardTrackIDs`.
- Seeds: one of the four recording seeds is reserved for an eligible super liked recording (recommendable, not disliked) whenever one exists. The pick rotates by period key through `jitter(periodKey:id:)` order, so different super likes seed different days and weeks. Discover Weekly's single-mix seeds and the scoped Daily Mix seeds both apply it; the scoped variant places the reserved seed in the scope that owns the song.
- Daily Mix: each mix places at least one eligible super liked song from its scope at the head of its familiar pool, rotating by day key, counted within the familiar share and the artist cap. Songs excluded by another mix, disliked or not recommendable are skipped; a scope without super likes is unchanged.
- Discover Weekly stays unheard-only. A super liked song never appears in it; its neighbours and artist affinity do. The existing known-artist multipliers still apply, so under Balanced the super liked artist's own songs are penalised while adjacent artists rise.
- Because you like, Moment Mixes, autoplay and experience radio keep their current mechanisms; only the affinity input changes.

**YouTube.** Import creates plain likes only and never downgrades a super like (`addFavorites` skips known ids). Write-back is untouched: no super like, like or unlike sends anything.

**Dislike.** Don't Recommend This Song removes a like and a super like together; the reaction register holds exactly one state per recording.

**Watch and CarPlay.** Companion wire version 2 carries `isSuperLiked` in the now-playing snapshot and a `setSuperLiked(Bool)` action. The Watch heart shows the tier (`bolt.heart.fill`), a tap unlikes fully and a 0.4-second hold promotes or steps back, with the success haptic on promotion. CarPlay's Now Playing adds a fourth Super Like button beside Favorite. Both companions route through `CompanionPlaybackController`, which calls the model's `toggleLike`/`toggleSuperLike` with the `watch` or `carPlay` surface, requires a current track and a fresh execution lease, and never queues an offline mutation. Both sides ship together; a version-1 request is refused with the update message. [WATCH.md](WATCH.md) and [CARPLAY.md](CARPLAY.md) own the controls. **Widgets** still treat a super like as an ordinary like; the snapshot format is unchanged.

**Extras (R20, backlog item 15).** Home gets a **Super Liked** shelf (`HomeSectionKind.superLiked`, the last case so a saved six-section order still reads as default and the shelf appends for existing users; `home.group.superLiked`): the newest 20 songs of `LibraryStore.superLikes` in Liked Songs order as track cards, hidden while there are none, ordered and hidden through Customize Home like every section (`home.customization.show.superLiked`). Its header (`home.superLiked.seeAll`) pushes Liked Songs on the Home tab with the Super Liked chip preselected (`LibrarySavedSongsView(kind: .likes, initialFilter: .superLiked)`), and its play button starts every super like. Settings > Library & iCloud > Storage lists **Super Liked** with the tier's count directly after Liked Songs (`storage.library.superLikes`). Every `TrackRow` of a super liked song shows a caption2 accent `bolt.heart.fill` after the duration and before the downloaded glyph (`track.superLiked.<id>`), at every text size like that glyph, and VoiceOver appends "Super liked" before the downloaded or cached state. [LIBRARY_AND_RECAP.md](LIBRARY_AND_RECAP.md) owns the row and page identities; `GanaBajanaR20UITests` and `SuperLikeExtrasTests` cover them.

## Formats and Sync

| Store | Version | Change |
| --- | --- | --- |
| `library.json` (`LibraryPersistence.currentVersion`) | 5, reads 1 to 4 | `superLikedIDs: [String]`, unique, each present in `favorites`, ordered as `favorites`. A file below version 5 that carries the key fails with `invalidData("super like format version")` |
| `LibrarySyncState` (journal) | 4, reads 1 to 3 | `LibrarySyncReaction.superLiked(Track)` in the existing `(.reaction, id)` register. A journal below 4 that carries the case fails with `invalidData("super like journal version")` |
| `LibrarySyncReplica` | 4, reads 1 to 3 | Same check as the journal |

Merge is unchanged: one last-writer-wins register per recording covering liked, super liked, disliked and removal. Materialization rebuilds `favorites`, `superLikedIDs` and `disliked` from live reaction registers ordered by revision. `LibrarySyncValidation.validateValue` checks `track.id == key.id` for the new case, and `LibraryValidation.validate` rejects a super like outside favorites, a duplicate id or a conflicting dislike. Older binaries, including delivered build 6, fail closed with `newerVersion` on the new file or replica and keep their files. [ICLOUD_SYNC.md](ICLOUD_SYNC.md) lists the collections.

`UserPreferences.autoDownloadSuperLikedSongs` (default false) decodes leniently and syncs as its own leaf beside `autoDownloadLikedSongs`. All Liked implies Super Liked Only; the two leaves merge independently and an All Liked value wins in effect.

## Integrated APIs

| API | Contract |
| --- | --- |
| `LibraryStore.isSuperLiked(_:)`, `superLikedIDs`, `superLikes` | Observation through `favoritesRevision`; `superLikes` is `favorites` filtered to the tier |
| `LibraryStore.setSuperLiked(_ track: Track, _ flag: Bool)` | Promote: ensure liked, move to index 0, add the id, lift a dislike. Demote: keep liked, remove the id, move to index 0. Same-state calls write nothing |
| `LibraryStore.toggleFavorite(_:)` | Removing a like also removes the id; `toggleDislike` removes both |
| `MusicAppModel.toggleLike(_:surface:)`, `toggleSuperLike(_:surface:)` | Player heart, menus and Liked Songs call these; they emit the metric, donate `SuperLikeTip.songLiked` on a like and keep `library` mutations synchronous |
| `MusicAppModel.favoritesChanged()` | Diffs favorites and super likes against known ids; downloads per the scope, logging `download_auto_like` or `download_auto_super_like` |
| `UserPreferences.autoDownloadScope` | Derived `AutoDownloadScope` (`off`, `superLiked`, `liked`) over the two Bool leaves; the picker writes both |
| `TasteProfile.build(... superLikedIDs:)` | Credits 540 for super likes and exposes `superLikedTrackIDs` |
| `RecommendationEngine.Seeds.init(profile:languageProfile:periodKey:)`, `scopedSeeds(... periodKey:)` | Reserved rotating super-like seed |
| `RecommendationEngine.composeDailyMix(...)` | Reserved rotating super-like familiar pick per mix |
| `SuperLikeTip`, `TipSupport.configure(arguments:)` | Real launches use the default datastore; `--uitesting` uses a temporary datastore and hides tips unless `--show-tips` |

## Metrics

OSLog only, bounded fields, no song, account or URL data.

| Event | Emitted when | Bounded fields | Purpose |
| --- | --- | --- | --- |
| `super_like` | A promotion, demotion or full removal of a super liked song through the model wrappers | `action=promote/demote/remove`, `surface=player/menu/more/library` | Confirm which surface listeners use and that the gesture is found |
| `download_auto_super_like` | Promotions trigger downloads under Super Liked Only or All Liked | `count` | Distinguish tier-driven downloads from `download_auto_like` |
| `mix_super_like` | Seeds and Daily Mix composition run | `scope=seeds/daily`, `reserved=0/1`, `eligible=<count>` | Show whether the reservation applied and why it did not |

## Test Coverage

| Case / test | Branch or path | Unit or integration |
| --- | --- | --- |
| v5 encodes `superLikedIDs`; v4 file decodes with none; v4 file carrying the key is rejected; version 6 is `newerVersion` | persistence and migration | unit |
| Super like outside favorites, duplicate id or conflicting dislike fails validation | `LibraryValidation` | unit |
| `setSuperLiked` promotes to index 0, lifts a dislike, is idempotent; demote keeps the like; `toggleFavorite` and `toggleDislike` remove the tier; `addFavorites` never downgrades | store | unit |
| Projection writes `.superLiked`; materialize rebuilds favorites and ids by revision; validation checks identity; LWW between like, super like and removal across two writers; journal/replica v3 read, v3 with the case rejected | sync | unit |
| `TasteProfile` credits 540 and exposes ids | recommendations | unit |
| Seeds reserve one super-like seed, rotate by period key, skip disliked/non-recommendable, leave seeds unchanged with none | recommendations | unit |
| Daily Mix includes a super like from its scope first, rotates by day, respects artist cap and exclusions, leaves a scope without super likes unchanged | recommendations | unit |
| Discover Weekly still excludes heard super liked songs | recommendations | unit |
| `autoDownloadSuperLikedSongs` lenient decode and sync leaf; `autoDownloadScope` mapping | preferences | unit |
| `favoritesChanged` downloads promotions under Super Liked Only, likes and promotions under All Liked, nothing under Off | downloads | unit |
| Downloads and Liked Songs filters classify super liked songs | filters | unit |
| Model wrappers mutate the library, emit metrics, donate the tip event; import keeps a super like | R19 integration | integration |
| Player heart tap/hold, glyph, menu rows, Liked Songs chip/swipe, Downloads filter and three-way setting, tip after a like | `GanaBajanaR19UITests`, light/dark on phone, SE and iPad | UI |

Deliberately uncovered: physical Watch and CarPlay head-unit behaviour (the fixture and bridge tests stand in), audible haptics on hardware, TipKit's own persistence across reinstall, and live-account import against a super liked song (needs the owner's signed-in device).
