# Hidden Delights

Seven small, cheeky surprises requested by the owner on 2 October 2026. None changes playback, the library, sync or
any setting; none blocks interaction, makes a network request or adds a launch flag. Copy is short, plain and has no
em dashes. Rules live in `Sources/App/Delights.swift`, session state and flags in `Sources/App/DelightController.swift`
(`MusicAppModel.delights`), views in `Sources/UI/DelightViews.swift`, `Sources/UI/HeartBurstOverlay.swift` and
`Sources/UI/TablaFlourish.swift`.

## Behaviour

| Delight | Trigger | Copy and presentation |
| --- | --- | --- |
| Equalizer extremes | Every saved band at +12 dB (`EqualizerExtreme.maximum`) or -12 dB (`.minimum`), on Settings > Equalizer and the player's compact equalizer. The line keeps its state while a finger is on a control and updates on lift, because its height would otherwise move the slider under the finger | Inline under the curve (`equalizer.delight`, footnote, accent): "Every band at max. Your neighbours have been notified." / "Every band at minimum. Bold of you to call this music." A change made while the page is open is announced to VoiceOver. EQ behaviour is unchanged |
| Late night | 2:00 to 3:59 local time while the full player is open; a minute `TimelineView` swaps the line in and out | Replaces the "NOW PLAYING" eyebrow only; the context line stays. One option per calendar night (`LateNightEyebrow.night`, day ordinal modulo 5): STILL UP? SAME. / SLEEP IS JUST A RUMOUR / 2 A.M. or 3 A.M. BOLD CHOICE (the current hour) / BEDTIME WAS HOURS AGO / YOUR PILLOW MISSES YOU. VoiceOver reads a sentence-case label |
| 100th liked song | An explicit like that makes `favorites.count` exactly 100: `toggleLike` from any surface, or `toggleSuperLike` on a song that was not liked. Imports (`addFavorites`), iCloud merges and promotions of an already liked song never call the hook. Once per installation | Toast "Century! 100 liked songs. Sachin would be proud." with a leading `heart.fill`, plus `HeartBurstOverlay`: 18 hearts arc up from the lower middle for 1.5 s, non-interactive and hidden from VoiceOver, over Root or the full player. Reduce Motion shows only the toast |
| Tenth repeat | The 10th consecutive start of one queue occurrence under Repeat One (`RepeatStreak`, fed by `player.onTrackStarted`). Turning Repeat One on counts the play under way as the first; another occurrence, Repeat All, Off or any mode change resets. Once per recording per app session | Toast "Ten times in a row. The song is flattered. Slightly concerned, but flattered." |
| About tabla | Seven taps on Settings > About > Version (`settings.version`), each within 1.5 s of the previous (`AboutTapCounter`). The row keeps its information-row look, label and value | First round: "There’s no secret menu. Nice try, though." Later rounds: "Still no secret menu. Persistence noted." Each round plays the flourish and a light impact haptic (`aboutFlourishes`) |
| Sleep timer | `PlayerController.onSleepTimerFired`, called just before the timer pauses. A timer that finds the music already paused stays quiet | Active app: toast "Shh. Paused for you." with `moon.zzz.fill`. Inactive or background: the pause time is saved and, on the next activation within 12 hours, the toast reads "Paused at 1:12 AM, like you asked. You were asleep anyway." (the listener's time format). Shown once; older pauses are dropped |
| Anniversary card | Home, below the masthead, for days 0 to 6 from each anniversary of the first recorded listen: the earliest lifetime receipt (`lifetimeListeningSummary.coverageStartedAt`) or retained event, whichever is earlier. Hidden while Save Listening History is off | **One year of Velvet Thorn.** (Two years, Three years and so on), then "<N> hours together. Your first song was <title>, and honestly, it shows." Hours are whole lifetime hours ("Less than an hour" and "1 hour" read naturally). The song sentence appears only when the earliest retained event is the first session to the millisecond; after detail retention removes it, the sentence is omitted. A 44-point close button (`home.anniversary.dismiss`, VoiceOver "Dismiss") hides that anniversary |

Toasts use `model.showToast`, so they reach VoiceOver as queued announcements and the existing banners on Root, the
player, Settings pages, Queue and Equalizer. The banner draws a delight's glyph through `DelightController.toastSymbol(for:)`.

## State and flags

All flags are device-local `UserDefaults.standard` keys with the `delight.` prefix. None is part of the library, its
journal, iCloud sync, widgets or companions; clearing history does not reset them.

| Key | Value | Lifetime |
| --- | --- | --- |
| `delight.likesCentury.shown` | Bool | Set when the century shows; stays for the installation |
| `delight.anniversary.dismissed` | Calendar year of the dismissed anniversary | Until the next dismissal |
| `delight.sleepPause.pausedAt` | Seconds since 1970 of a background sleep pause | Removed at the next activation (shown only within 12 hours) or by a later foreground pause |

Repeat streaks, About rounds, the late-night record and the burst live in memory for the app session. The flourish
is synthesized in code (`TablaFlourish`: three strokes, decaying harmonics with a 1.2 to 1.3 times pitch drop, a
fixed-seed click, 22.05 kHz 16-bit mono, 0.67 s, normalized to 80 percent) and written once to
`Caches/GanaBajana/Delights/tabla-flourish-1.wav`; a purged or resized file is rewritten. `TablaFlourishPlayer` plays it
with `AudioServicesCreateSystemSoundID` and `AudioServicesPlaySystemSound`, which obey the silent switch, mix with music
and never touch the app's `AVAudioSession`. `Resources/PrivacyInfo.xcprivacy` declares the user defaults API with
reason `CA92.1`.

Unit and UI test hosts (DEBUG with `XCTestConfigurationFilePath` or `--uitesting`) get a scratch suite,
`com.agraabhi.ganabajana.delights.fixture`, cleared by each new controller; `tools/audit-release.py` rejects that
marker in Release. Unit tests inject their own suite and clock.

## Hooks in existing files

| File | Hook |
| --- | --- |
| `MusicAppModel.swift` | `@ObservationIgnored lazy var delights`; `onTrackStarted` calls `trackStarted` before its checkpoint guard; `onSleepTimerFired` passes `isPlaying \|\| isLoading`; `activateDeviceServices` / `deactivateDeviceServices` call `sceneDidBecomeActive` / `sceneDidResignActive`; `toggleLike` and `toggleSuperLike` call `likeAdded(likedCount:)` only when a song became liked |
| `PlayerController.swift` | `var onSleepTimerFired`, called in `expireSleepTimer` before `pause()` |
| `EqualizerView.swift`, `Player/PlayerEqualizerSheet.swift` | `.equalizerDelightLine(gains:isAdjusting:)` on the curve stack |
| `NowPlayingView.swift` | `PlayerEyebrow()` replaces the eyebrow text; `.overlay { HeartBurstOverlay() }` |
| `RootView.swift` | `.overlay { HeartBurstOverlay(isActive: !model.isPlayerPresented) }`; banner glyph |
| `SettingsPages.swift` | Version row: `onTapGesture`, light `sensoryFeedback` |
| `HomeView.swift` | `HomeAnniversaryCard()` between the masthead and the sections |
| `CollectionDetailView.swift` | Like All Songs skips its "Songs added to your likes." confirmation while `delights.isShowingCentury`, so a century reached mid-loop keeps the banner |

`activateDeviceServices` is not called in test hosts, so the background sleep line never appears in UI tests. The
streak watches `player.repeatMode` through `withObservationTracking`, one main-actor turn after a change. Outside the
anniversary week the card reads only the store's lifetime summary; inside it, the earliest retained event is cached by
history and lifetime revisions.

## Metrics

One bounded local OSLog event, subsystem `com.agraabhi.ganabajana`, category `Delights`:
`event=delight kind=<equalizerMax|equalizerMin|lateNight|likesCentury|repeatTen|aboutTabla|sleepPaused|anniversary> shown=1`.
It carries no identifier, title, time or count beyond the kind.

| Kind | Recorded |
| --- | --- |
| `equalizerMax`, `equalizerMin` | Each time the line appears, including on opening a page in that state; never during a drag |
| `lateNight` | Once per calendar night per app session |
| `likesCentury` | Once per installation |
| `repeatTen` | Once per recording per app session |
| `aboutTabla` | Each completed round |
| `sleepPaused` | Each toast shown, foreground or on return |
| `anniversary` | Once per anniversary per app session, on first appearance |

## Tests

| Case | Covers | Type |
| --- | --- | --- |
| `DelightsTests.testEqualizerLineNeedsEveryBandAtOneEndOfTheRange` | All-max/all-min in Advanced and Simple curves; partial, mixed, flat, empty and preset curves stay quiet; copy and kinds | Unit |
| `testLateNightLineCoversTwoToFourLocalTime` | 1:59:59 no, 2:00 yes, 3:59:59 yes, 4:00 no; local time zone | Unit |
| `testLateNightLineStaysForTheNightAndMovesOnTheNextNight` | One line per night, rotation across five nights, capitals and spoken text, hour-aware bold-choice line | Unit |
| `testCenturyCelebratesTheExplicitLikeThatReachesOneHundredOnce` | `toggleLike` to exactly 100, toast, burst, glyph, flag; unlike/re-like and a relaunched controller stay quiet | Model integration (`AppModelTestContext`) |
| `testCenturyIgnoresImportsAndPromotionsButCountsASuperLikedNewSong` | Import to 100, promotion at 100, 101 and unlike to 100 stay quiet; a super like of a new song as the 100th celebrates | Model integration |
| `testCenturyDuringLikeAllSongsKeepsTheBannerFromTheBulkConfirmation` | A bulk like loop crossing 100 leaves the century on the banner and reports it to the collection page | Model integration |
| `testRepeatStreakCelebratesTheTenthStartInARowOnce`, `...ResetsOnAnotherSongAndIgnoresRepeatAll`, `...CountsThePlayThatTurnedRepeatOneOnAndEndsOnOtherModes` | Tenth start once; another song resets; Repeat All and missing occurrences never count; mode changes | Unit |
| `testTenthRepeatOneStartShowsTheToastThroughThePlayerCallback` | `onTrackStarted` wiring, real queue occurrence and `cycleRepeatMode` observation | Model integration |
| `testAboutNeedsSevenQuickTapsAndTheSecondRoundChangesItsLine`, `testVersionTapsPlayTheFlourishAndShowTheToast` | Seven within the gap fires, slow taps never, a pause restarts, later rounds; flourish and haptic trigger per round | Unit and model integration |
| `testTablaFlourishIsAShortMonoPCMWave` | RIFF/WAVE header, PCM mono 16-bit, size, under one second, level and headroom, three strikes, quiet ending, deterministic bytes | Unit |
| `testSleepMessagesForTheForegroundAndForAReturnWithinTwelveHours` | Foreground copy, formatted return line, 12-hour edge, clock moved backwards | Unit |
| `testSleepTimerToastsInTheForegroundAndWaitsForTheNextActivationInTheBackground` | Real `expireSleepTimer` hook: paused music stays quiet, foreground toast and pause, background save, return within 12 hours once, stale pause dropped | Model integration |
| `testAnniversaryCardShowsForSevenDaysFromEachAnniversary` | Days 364/365/366/371/372, years 2 and later wording, history off, dismissed year, omitted song sentence, hour wording | Unit |
| `testListeningOriginNamesTheFirstSongOnlyWhileItsDetailSurvives` | Millisecond receipt match, expired first session, events or receipts alone | Unit |
| `testAnniversaryCardReadsTheLibraryAndHidesWhileHistoryIsOffOrOnceDismissed` | Real `recordListening` receipts and events, lifetime hours, history off and on, dismissal persisted across controllers | Model integration |
| `GanaBajanaDelightsUITests.testSevenVersionTapsShowTheSecretMenuLineThenItsSequel` | Seven plain taps on Version show the first line, seven more the sequel | UI |

Coordinator selectors: `-only-testing:GanaBajanaTests/DelightsTests` and
`-only-testing:GanaBajanaUITests/GanaBajanaDelightsUITests`.

## Not verified

Nothing here has been built or run by the author; the coordinator owns builds, test runs and
[VERIFICATION.md](VERIFICATION.md). Unverified: the flourish's sound on hardware and with the silent switch, haptics,
the burst's look and frame rate, the late-night swap at the window edges on a device, Reduce Motion rendering, and
whether VoiceOver double-taps on the Version row reach its tap handler.
