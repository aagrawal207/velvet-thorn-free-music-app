# Liked heart (R12 WP2, replaced in R13 WP13, super like tier in R19)

## Purpose

The owner used the R12 build and rejected the progress-to-heart trail: it reduced the seek range and did not look good. R13 item 6 puts the heart back in the track heading, beside the title and artist lines, and lets the progress bar run across the whole column. R19 gives the same heart a second tier: a super like ([SUPER_LIKES.md](SUPER_LIKES.md)) reached by holding it. A super liked song is a bolt heart in the accent colour, a liked song a filled heart in the accent colour, an unliked song an outline in the artwork text colour. `PlayerLikeButton` owns the heart; `PlayerProgressRow` draws the bar only; `PlayerProgressTrail` and its geometry tests are gone.

## Behaviour

- Super liked. `Image(systemName: "bolt.heart.fill")`, 22-point semibold, `AppTheme.accent`.
- Liked. `Image(systemName: "heart.fill")`, 22-point semibold, `AppTheme.accent` (coral by default: 0xFF5A7A in dark, 0xDC3159 in light). Accent changes in Settings recolour it like every other accent surface; the player owns its accent (`.accentColor` and `.tint` with the preference's colour) so the direct-launch cover no longer falls back to system blue.
- Unliked. `Image(systemName: "heart")`, 22-point semibold, `AppTheme.artworkSecondaryText` (0xEFEFF4 dark, 0x3F3F49 light), the same colour as the artist line, the time labels and the Lyrics and Queue symbols; the interior shows the backdrop.
- Target and placement. 52 by 52 points at the trailing edge of the heading, centred on the title plus artist block (not on the play-count caption). The title and artist texts lose the 56-point slot and keep one line. On the 17 Pro the heart's trailing edge is the column's trailing edge (378), so it shares that edge with the right time label and the Queue button.
- Tap. Runs `MusicAppModel.toggleLike(_:surface: .player)`: like an unliked song; remove a liked or super liked song from Liked Songs completely.
- Hold. A press of `PlayerLikeButton.holdDuration` (0.4 s) runs `MusicAppModel.toggleSuperLike(_:surface: .player)`: not liked or liked becomes super liked, super liked steps back to liked. The hold is a `LongPressGesture(minimumDuration: 0.4)` attached with `.simultaneousGesture` so the Button keeps recognising plain taps; the default 10-point movement allowance means a swipe that starts on the heart fails the hold and still opens the swipe-up sheet. When the hold fires it marks the press, and the Button action for that press's release is skipped, so a hold can never promote and then unlike. Any press beginning or ending clears the mark (`PlayerHeartButtonStyle.onPressingChanged`), so the next tap starts clean even if the hold's release landed outside the target.
- Feedback. A like made from the heart (a tap on an unliked song) bounces the glyph (`.symbolEffect(.bounce.up.byLayer, options: .speed(1.6))`) and plays `.sensoryFeedback(.impact(weight: .light))`. A promotion made from the heart (the hold or the VoiceOver action) plays `.sensoryFeedback(.success)`, bounces the glyph 1.0 to 1.18 and back (`phaseAnimator`, `.easeInOut` 0.12 s each way) and fires `SuperLikeBurst`: six 5-point accent sparks at 60-degree steps fly from the centre to a 30-point radius, grow to full size then shrink to 0.2, and fade over the last 0.25 s, about 0.5 s in all, driven by one-shot `KeyframeAnimator` keyframes on the promotion count so nothing runs on appearance or on a revisit. Demotions and removals give no haptic or motion. The triggers are the heart's own like and promotion counts, not the liked or super liked state, so skipping to a song that is already liked or super liked stays silent and still. Reduce Motion keeps both haptics and the colour/glyph changes and drops the like bounce, the promotion bounce and the burst.
- State switching. The glyph and colour flip without animation (`.transaction { $0.animation = nil }` on the symbol); the press scales the glyph to 0.88 in place (`PlayerHeartButtonStyle`, no press animation under Reduce Motion). The like bounce, the promotion bounce and the burst sit outside that transaction, so they multiply with the press scale while the finger is still down.
- Tip. `.popoverTip(SuperLikeTip(), arrowEdge: .top)` anchors the TipKit popover to the heart once the listener has liked a song with the player open; one display, dismissable, state in TipKit's datastore. `--uitesting` launches hide it unless `--show-tips`.
- Accessibility. Identifier `player.like`. Label "Unlike this song" while liked or super liked, "Like this song" otherwise. Value "Super Liked" or "Liked", none while unliked. Hint "Hold to super like" while not super liked. `.isSelected` while liked or super liked. One custom action, "Super Like" while not super liked or "Change to Like" while super liked, runs the tier toggle.
- The bar no longer reaches the heart: it is a full-width 3.5-point stroke with the accent progress, described in [PLAYER_SHELL.md](PLAYER_SHELL.md). The 45 percent tint, the solid `primaryText` fill and the rim colours of R12 are gone with the trail.

What a viewer sees (17 Pro, dark, `player-dark` capture of a liked song): the title "Tum Hi Ho" and artist "Arijit Singh" on the left, a solid coral heart to the right of them at the column's edge, the play count below the artist, then a full-width bar half coral and half grey with the time labels under its ends, the white play circle with previous and next straight on the backdrop, and AirPlay, Lyrics and Queue along the bottom at one size. Light appearance: the same with a deeper coral heart and dark grey outline colours over the lilac backdrop. A super liked song shows the coral bolt heart in the same slot.

## APIs

| Symbol | Kind | Notes |
| --- | --- | --- |
| `PlayerLikeButton(liked:superLiked:action:superLikeAction:)` | view, `Sources/Views/Player/PlayerLikeButton.swift` | `size 52`, `holdDuration 0.4`; `bolt.heart.fill` or `heart.fill` in `AppTheme.accent`, `heart` in `AppTheme.artworkSecondaryText`; tap runs `action`, hold and the custom action run `superLikeAction`; private `likes` and `promotions` counts drive the symbol bounce, the 1.18 `phaseAnimator` bounce, the burst and the two `sensoryFeedback` triggers |
| `SuperLikeBurst(trigger:)` | private view, same file | Six accent sparks on one-shot keyframes per promotion; `allowsHitTesting(false)`, hidden from accessibility, not built under Reduce Motion |
| `PlayerHeartButtonStyle(onPressingChanged:)` | `ButtonStyle`, same file | 0.88 press scale, off under Reduce Motion; reports each press beginning and ending; no anchor parameter any more |
| `PlayerProgressRow.liked`, `onToggleLike`, `likedRimColor` | removed | the row no longer draws a heart |
| `PlayerProgressTrail` | removed | `heartPath`, `heartProgressPath(_:)`, junction geometry and the `Layout` constants are gone |
| `PlayerProgressRowRenderingTests`, `PlayerProgressTrailTests` | removed | replaced by `PlayerProgressBarTests` and the pixel checks in `GanaBajanaPlayerProgressBarUITests` |

## Metrics

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `super_like` | The hold or the custom action promotes or demotes, or a tap removes a super liked song, through the model wrappers | `action=promote/demote/remove`, `surface=player` | [SUPER_LIKES.md](SUPER_LIKES.md#metrics) owns the event; the heart adds no logging of its own |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Mini-player flow, dark, coral: the liked heart glyph inside `player.like` is 16 to 28 points wide and its centre is coral (red above 0.7, red minus green above 0.3, red minus blue above 0.25); after unliking the glyph keeps its size and the centre is not coral; a tap on the heart never moves the position | `PlayerLikeButton` in the real player | UI (`GanaBajanaPlayerProgressBarUITests.testBarSpansTheColumnAndTheHeartInTheHeadingStillLikes`, 17 Pro and SE) |
| Direct-launch artwork fixture, dark and light: liked heart centre coral and the filled bar coral (asserting the launch accent fix), unliked centre within 0.15 of the backdrop sampled 6 points above the heart, glyph found in both states | `HeartGlyph` over the `player-dark` / `player-light` captures | UI (`GanaBajanaPlayerProgressBarUITests.testHeadingBarAndTransportSitOnTheArtworkBackdropIn{Dark,Light}Appearance`, 17 Pro, SE, iPad) |
| Heart 52 by 52, centred on the title plus artist block, ending at the column's trailing edge; the title ends before the heart | `trackHeading` | UI (same suite, `assertBarAndHeadingGeometry`; `GanaBajanaRefinementUITests.assertThumbTargets`) |
| Heart taps in other suites still like and persist; the lower corner of the target likes rather than switching the time label | `action` | UI (`GanaBajanaRefinementUITests.testMiniPlayerOpensFullScreenWithThumbSizedControlsAndBottomOptions`, `GanaBajanaWorkflowUITests.testLikesSurviveRelaunchAndRestorePausedPlayer`, `GanaBajanaPlayerShellUITests.testTrailingTimeLabelSwitchesStylesAndKeepsTheChoiceAcrossReopenAndRelaunch`) |
| A swipe that starts on the heart opens the swipe-up sheet without toggling the like or the tier | `PlayerSwipeUpRegion` cancelling the press; the drag fails the hold | UI (`GanaBajanaPlayerGesturesUITests`) |
| Hold promotes (value "Super Liked", `bolt.heart.fill`) without unliking on release; a second hold demotes to "Liked"; a tap on a super liked song unlikes; the custom action and the tip after a like | `hold`, `tap`, `toggleTier`, `.popoverTip` | UI (`GanaBajanaR19UITests`, light and dark on phone, SE and iPad; [SUPER_LIKES.md](SUPER_LIKES.md#test-coverage)) |

Tolerances: `HeartGlyph` marks pixels more than 0.35 (largest channel) from the median colour of the 52-point slot as glyph, so half-covered edge pixels (about 0.4 away) count and the backdrop gradient across the slot (well under 0.1) does not; the centre of the glyph's bounding box is inside the fill of `heart.fill` and inside the empty interior of `heart`.

## Not verified

- Only coral was exercised in the running app; the other six palettes recolour the heart through the same `AppTheme.accent` the bar, the Settings previews and the mini-player already use, and were not captured.
- Increase Contrast and Reduce Transparency were not rendered; the heart uses the plain accent and text colours those modes already govern.
- Physical devices and VoiceOver were not run; the light impact and success haptics are silent in the simulator, and the like bounce and spark burst were not captured frame by frame.
- The tip popover's placement against the heading was not rendered; the R19 captures own it.
