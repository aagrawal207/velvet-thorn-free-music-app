# AirPlay (R14 item 1, WP21)

## Current Acceptance

The owner reports constant physical testing and actual TV audio AirPlay working great. This closes the existing audio acceptance item as an owner report. It is not a measured receiver matrix or a claim about every codec, equalizer setting or transition.

R17 TV Lyrics is implemented and integrated separately. Core and phone light/dark checks passed in their targeted scope; actual TV lyrics/mirroring, native idle-timer behavior and receiver latency remain unverified. [TV_LYRICS.md](TV_LYRICS.md) owns that presentation and [VERIFICATION.md](VERIFICATION.md) owns run evidence. Native motion and background-download OS-suspension checks are also separate from audio acceptance.

## Symptom

Owner report: "AirPlay to TV is not working well, it is stuck loading." Choosing an Apple TV or an AirPlay TV from
the player's route button left the player on its loading indicator.

## Source diagnosis

Before WP21, every app-created `AVPlayer` kept `allowsExternalPlayback` at its default, `true`. That permits
receiver-side external playback rather than requiring phone-rendered audio. This is a source-established risk
for Velvet Thorn's media, not a hardware-confirmed root cause of the reported loading symptom:

- cached and downloaded copies are `file://` URLs local to the phone, not receiver-accessible network URLs;
- YouTube googlevideo URLs are signed and may depend on request/client context, so receiver access is not assured;
- Opus-in-MP4 (the iOS 26.5+ native Opus path) is not a format the receiver is known to accept.

Evidence from the source before the fix (`rg "AVPlayer\(|AVQueuePlayer|allowsExternalPlayback|usesExternalPlaybackWhileExternalScreenIsActive|routeSharingPolicy|setCategory" Sources/`):

| Site | Code | External playback |
| --- | --- | --- |
| `PlayerController.swift`, stored `player` | `AVPlayer()` | default (true) |
| `PlayerController.handleMediaServicesReset()` | `player = AVPlayer()` | default (true) |
| `PlaybackTransition.swift`, `StandbyDeck.makePlayer()` (standby, gapless and crossfade deck) | `AVPlayer()` | default (true) |
| `PlaybackSystemControls.configureSession()` / `activateSession()` | `setCategory(.playback, mode: .default, options: [])` | no route-sharing policy |

No `AVQueuePlayer` exists, and `allowsExternalPlayback`, `usesExternalPlaybackWhileExternalScreenIsActive` and
`routeSharingPolicy` appeared nowhere in `Sources/`. Only the test-only players in `OpusPlaybackIntegrationTests`
and `AudioFormatLiveTests` already set `allowsExternalPlayback = false`. `PlayerAirPlayPicker` already set
`prioritizesVideoDevices = false`, which only affects how the picker lists routes, not how the player uses them.

The source can explain prolonged loading if external playback never advances: the 500-ms tick detects a stall
after 20 seconds, re-resolves the stream through `recoverPlayback(reason: "stalled")`, and permits at most two
recovery attempts before reporting failure. The reported TV session has no hardware trace confirming which
fetch, decode or routing step stalled.

## Fix

- `PlaybackAudioRoute` (`Sources/Playback/PlaybackSystemControls.swift`) is the one place players and the session
  policy come from:
  - `makePlayer()` returns an `AVPlayer` with `allowsExternalPlayback = false`. `PlayerController` uses it for the
    stored player and for the media-services reset; `StandbyDeck.makePlayer()` uses it for the standby deck. The
    deck's player becomes the active player at a gapless cut or crossfade and the outgoing one returns to the deck,
    so every player in rotation has the flag.
  - `session` is `.playback`, mode `.default`, `routeSharingPolicy .longFormAudio`, options `[]`, applied through
    `setCategory(_:mode:policy:options:)` by both `configureSession()` and `activateSession()`.
- The path is phone-rendered audio over an AirPlay output route rather than handing media URLs to the receiver.
  Existing TV audio acceptance is closed by the owner's report above. Local routing tests alone do not prove
  compatibility with every receiver.
- `.longFormAudio` compatibility: long-form audio forbids mixing options (`mixWithOthers`,
  `duckOthers`, `interruptSpokenAudioAndMixWithOthers`); the existing options were already empty, so nothing is
  lost. CarPlay continues to use the `.playback` session, but head-unit behavior with this policy is unverified.
- `AVRoutePickerView.prioritizesVideoDevices = false` is kept, with a comment explaining the pairing.
- Route changes: `routeChangeNotification` logs every change and pauses on `oldDeviceUnavailable`. A new-route
  notification alone does not request a pause. Stall recovery remains capped at two attempts per selection
  (`recoveryAttempts`, reset on a new selection or explicit Retry); whether the receiver progresses must be observed.
- Equalizer: `MTAudioProcessingTap` remains on the local audio render path for eligible items. The routing policy
  is intended to retain processing during AirPlay; audible receiver output is unverified.
- Crossfade and gapless: both decks use the factory and retain local playback policy through swaps. Receiver
  buffering, latency and audible transitions have not been measured; no fixed TV latency is guaranteed.
- Now Playing: `MPNowPlayingInfoCenter` publishes title, artist, optional album/artwork, duration, elapsed time,
  rate and queue metadata. `MPRemoteCommandCenter` supplies transport/seek handlers. A receiver may display that
  metadata and expose controls; actual presentation and command support are receiver-dependent.

## Receiver visuals

Audio AirPlay supports Now Playing metadata, not a custom Velvet Thorn screen. Its public metadata/route APIs do not
provide a channel for timed lyrics or Velvet Thorn's artwork-derived background colours. The receiver owns its own
visual presentation. R17 adds opt-in app-owned [TV Lyrics](TV_LYRICS.md) through phone mirroring or a separate
noninteractive external-display scene. Its selected text/source comes from the shared phone loader.

## Metrics

| Log (category `AudioSession`) | When | Fields and bounds |
| --- | --- | --- |
| `event=route_change kind=<k> reason=<r> external=<0\|1>` | every `AVAudioSession.routeChangeNotification` | `kind` is one of `airplay`, `bluetooth`, `car`, `builtin`, `other` (`PlaybackAudioRoute.Kind`; the most specific output wins: airplay, car, bluetooth, builtin); `reason` is the `AVAudioSession.RouteChangeReason` raw value (0 to 8); `external` is `AVPlayer.isExternalPlaybackActive` of the active player, expected to be 0 always |
| `event=route_detached` (category `Playback`, existing) | `oldDeviceUnavailable` | none |
| `event=stream_refresh reason=stalled ...` (existing) | 20 s without progress | correlate with route changes during device acceptance; audio routing does not rule out other stalls |

No identifiers, device names or route UIDs are logged.

## Test coverage

| Test (`Tests/AirPlayRoutingTests.swift`, unit) | Contract |
| --- | --- |
| `testFactoryPlayerForbidsExternalPlayback` | `PlaybackAudioRoute.makePlayer()` sets `allowsExternalPlayback == false` |
| `testMainAndStandbyPlayersForbidExternalPlaybackIncludingAfterMediaServicesReset` | a new `PlayerController` has main and standby players without external playback, also after `handleMediaServicesReset()`; `isExternalPlaybackActive` is false |
| `testStandbyDeckPlayerForbidsExternalPlaybackIncludingAfterReset` | `StandbyDeck` player at init and after `reset()` |
| `testPlayersSwappedByGaplessAndCrossfadeStillForbidExternalPlayback` | native local file, 1 s crossfade: the incoming deck player that becomes active and the outgoing player returned to the deck both keep the flag (integration with AVPlayer) |
| `testSessionConfigurationIsLongFormPlaybackWithoutMixingOptions` | configuration values |
| `testControllerAppliesTheSessionConfigurationToTheSharedSession` | after `PlayerController` init the shared `AVAudioSession` reads `.playback`, `.default`, `.longFormAudio`, `[]` (unit host) |
| `testRouteClassificationMapsEachPortType` | port to kind mapping, including headphones, HDMI, USB and line out as `other` |
| `testRouteClassificationPrefersTheMostSpecificOutput` | multi-output routes and the empty route |
| `testRouteKindsAreTheBoundedLogValues` | the five log values |

Regression suites to run with it: `PlaybackControllerTests`, `PlaybackTransitionTests`,
`PlaybackAudioIntegrationTests`, `EqualizerTests`, and the UI suite `GanaBajanaPlayerAirPlayUITests` (the native
chooser test stays skipped unless `TEST_RUNNER_GANABAJANA_NATIVE_AIRPLAY_UI=1`). No existing assertion changed.

**R15/Core-01:** `AirPlayRoutingTests` compiled and ran; all tests in the class passed, as reported by the
coordinator. The R15 entry in [VERIFICATION.md](VERIFICATION.md) owns the integrated evidence and run
boundaries. This result verifies the local contracts above, not real TV playback.

Historical WP21 attempts: four build-for-testing attempts (`artifacts/R14/WP21-build-01.log` to `-04.log`)
failed in other packages' in-progress files (`MusicAppModel.swift` `LibraryScrollTarget` and an exhaustive switch,
`DailyMixes.swift` type-check time, `GanaBajanaSettingsLayoutUITests.swift` `SettingsLayout`). WP21 app sources
compiled without errors in builds 02 and 03, but the unit test target was not reached then. Those runs stopped
after free disk fell to 5 GB, below that package's 6 GB floor.

## Historical Device Checklist and Remaining Detail

The original WP21 worker had no receiver and left the checklist below. The later owner report closes general
TV audio acceptance; it does not supply separate measurements for each checklist row. Keep those details
unmeasured rather than reopening the owner's accepted audio behavior:

1. Start a song on the phone speaker. Open the player, tap the AirPlay button and pick the TV.
2. Check that audio starts and the loading indicator clears; record startup delay rather than assuming a fixed
   buffer duration. Record which title, artist, artwork and controls the receiver actually displays.
3. Repeat step 1 with a downloaded song (Library > Downloads), a cached song and, on iOS 26.5+, an Opus song; each
   must play on the TV.
4. From the lock screen and Control Center: pause, resume, seek with the scrubber, next and previous. Each acts on
   the TV within the AirPlay latency, and the lock-screen position stays in step.
5. With Crossfade set to a few seconds, let one song run into the next: the blend is audible on the TV with no gap
   or restart. Repeat with Crossfade 0 and Gapless on.
6. With the equalizer on (a strong preset such as Bass boost), the change is audible on the TV.
7. Turn the TV off or pick iPhone again: playback pauses on losing the TV (expected) and resumes on the phone when
   you press play.
8. Optional, Console.app filtered on `com.agraabhi.ganabajana` category `AudioSession`: a line
   `event=route_change kind=airplay ... external=0`, and no `event=stream_refresh reason=stalled` after it.

Also not verified: CarPlay head units with `.longFormAudio`, and AirPlay multi-room (several speakers at once).
