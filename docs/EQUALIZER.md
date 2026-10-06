# Equalizer

R12 WP7, extended by R14 WP25. A 10-band graphic equalizer for AVPlayer playback, with presets, a custom curve, a
preamp and an automatic headroom rule; R14 adds a Simple mode, plain band and preset names, saved presets, a compact
sheet in the player's More and per-song overrides. Reached from Settings > Playback > Equalizer and from More >
Equalizer ([PLAYER_MORE.md](PLAYER_MORE.md)).

R18 integrates normalization gain-up and a channel-linked sample limiter in the same tap. The model/player hooks
are applied. [VOLUME_NORMALISATION.md](VOLUME_NORMALISATION.md) owns gain bounds and native coverage;
[VERIFICATION.md](VERIFICATION.md) owns current run counts. Historical EQ-only measurements below retain their scope.

## Purpose

Let the listener shape the sound of every song on this device without changing how playback works: the same
`AVPlayer` items, the same volume normalization and crossfades, the same cache and download files. The setting
syncs like every other preference (`UserPreferences.equalizer`, one register per leaf) and defaults to off.

## Behaviour

- EQ defaults off. A fresh item needs no tap when EQ is off and normalization requests no gain-up. Enabling EQ
  installs or reuses the active/standby tap and applies live curve changes with a 20 ms ramp, without a restart.
  Disabling EQ ramps the curve to flat and drains its filters for 50 ms; normalization can remain active in that
  same tap. Later items are untapped only when neither effect needs processing.
- React to Music metering (`EqualizerTapInstaller.setMetering`, `needsTap(equalizerEnabled:normalizationGain:allowsGainUp:meteringRequested:)`)
  also needs a tap, but only while a visible player resolves to that style and only on items that allow gain-up, so
  live items never take a measuring tap; HLS and unsupported PCM bypass as before and the backdrop falls back to
  Pulse. A measuring-only render reads the buffer after EQ and gain-up and leaves it bit-identical. `AudioLevelMeter`
  smooths the mean square (30 ms attack, 250 ms release), flags an onset above 1.6 times a 1.2 s average, and
  `PlaybackLevelMeter` publishes level and beat as Float bit patterns in atomics. Withdrawing metering leaves
  installed taps passing audio through.
- Gapless cost while on: AVFoundation prepares a tapped item at preroll but does not pull audio through the tap
  until play, so the swap first primes the tap pipeline. Historical EQ-on simulator measurements with the 22 kHz tone fixture:
  0.20 to 0.40 s between songs (the untapped path stays under 0.15 s). The page footer says so in plain words;
  Crossfade or Automix hide it because the incoming song starts under the outgoing one. R18 normalization-only
  taps can also incur priming delay; their timing has not been measured.
- Presets (`EqualizerPreset`): Flat, Bass boost, Bass reducer, Treble boost, Vocal, Rock, Pop, Jazz, Electronic,
  Acoustic, Loudness, Custom. Custom is the listener's own curve in `EqualizerSettings.gains`.
- Moving a band while a named preset is selected copies that preset's gains into `gains` and switches the preset to
  Custom, so the other nine bands keep their sound.
- Bands: ISO octave centres 31.25 Hz to 16 kHz (`EqualizerPreset.bandFrequencies`), gains -12 to +12 dB in 0.5 dB
  steps. The curve strip above the sliders is the band-only magnitude response from 20 Hz to 20 kHz.
- Preamp: -12 to +12 dB, default 0. Headroom rule: when the preamp is 0 and the largest band gain is positive, that
  amount is subtracted automatically (Bass boost plays 6 dB quieter through the tap), so a boosted curve keeps the
  headroom of the flat signal. Any nonzero preamp is applied exactly as set and replaces the automatic offset. The
  offset covers the largest single band, not overlapping neighbours. The footer's "never clip" wording is not
  an output guarantee. R18 limits decoded sample peaks after EQ, but not intersample or final-crossfade peaks.
- Reset returns the preset to Flat, all gains to 0 and the preamp to 0; the on/off choice stays.
- The Settings row shows the state: Off, the preset title, or Custom.

### Simple and Advanced (R14)

- The page opens in Simple mode (segmented control `equalizer.mode`, segments `equalizer.mode.simple` and
  `equalizer.mode.advanced`). The choice is view state in `UserDefaults` (`equalizer.mode`), device-local and never
  synced; the curve is the same in both modes.
- Simple shows three native sliders, Bass, Mids and Treble (`equalizer.simple.bass|mids|treble`, -12 to +12 dB in
  0.5 dB steps, VoiceOver value "+3 dB"). `SimpleEqualizer.weights` spreads them over the ten bands; every row sums
  to 1, so equal controls give a flat shift:

  | Band | 31 | 62 | 125 | 250 | 500 | 1k | 2k | 4k | 8k | 16k |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | Bass | 1 | 1 | 0.9 | 0.5 | 0.1 | 0 | 0 | 0 | 0 | 0 |
  | Mids | 0 | 0 | 0.1 | 0.5 | 0.9 | 1 | 0.5 | 0.1 | 0 | 0 |
  | Treble | 0 | 0 | 0 | 0 | 0 | 0 | 0.5 | 0.9 | 1 | 1 |

  Band gains are rounded to 0.5 dB and clamped. The sliders read any curve back through a least-squares fit
  (`SimpleEqualizer.controls(for:)`, exact for curves the matrix made), so a named preset shows its nearest
  three-control shape (Bass boost reads about +5, -0.5, 0). Moving a Simple slider rebuilds all ten bands from the
  three values and switches to Custom; the footer says "Simple sliders reshape the whole curve."
- Advanced shows the ten bands with a name over the frequency: Sub-bass 31, Bass 62, Bass 125, Low mids 250, Mids
  500, Mids 1k, Upper mids 2k, Presence 4k, Treble 8k, Air 16k (`EqualizerPreset.bandNames`). VoiceOver reads
  "Sub-bass, 31 Hz, +3 dB".
- Both modes show the curve with Low, Mid and High under it (`equalizer.curve.axis`) and three hints
  (`equalizer.hints`): "Bass: thump and warmth", "Mids: vocals and guitars", "Treble: clarity and cymbals".
- Every preset has a plain description (`EqualizerPreset.summaryDescription`), shown for the chosen preset under
  the row (`equalizer.preset.description`, "Bass boost: more thump for hip hop and EDM") and for all of them in
  "What the presets do" (`equalizer.guide`, rows `equalizer.guide.<raw>`). The menu entries stay title-only so the
  native menu keeps one-line buttons.

### Saved presets and per-song overrides (R14)

- "Save as preset" (`equalizer.savePreset`, alert field `equalizer.savePreset.name`) stores the effective gains and
  preamp under a name: up to 20, 40 characters, case-insensitive unique, never a built-in title. Saving an existing
  name replaces it. The preset menu lists them under "Your presets" (`equalizer.preset.saved.<index>`); choosing one
  copies its curve into Custom, and while the curve matches, the row and the More value show the saved name. The
  full page lists them in "Your presets" (`equalizer.saved.<name>`) with swipe to delete.
- "Use for this song" (`equalizer.song.toggle`, player sheet only) copies the current global settings as an
  override for that recording id. While it is on, every control in the player sheet and in More controls edits the
  override, never the synced preference. Off deletes the override.
- Settings > Playback > Equalizer always edits the global equalizer. A song with its own settings keeps them while
  it plays, and its More row reads "This song".
- `PlayerController.refreshEqualizer()` runs when the current recording changes (`ordering` `didSet`) and after an
  override edit: the current song's override, or the global setting, goes to `EqualizerTapInstaller.update`, which
  ignores an unchanged value. Nothing is reinstalled, and the lazy-attach rule holds: an override that turns the
   equalizer on installs taps on the registered items, one that turns it off drains them. Active music and standby items share
  one curve, so the incoming song's override ramps in (20 ms) at the swap; with Crossfade the outgoing song ends on
  the incoming song's curve.
- `EqualizerProfileStore` keeps both in `Application Support/GanaBajana/equalizer-profiles.json` (version 1, 1,000
  overrides least recently used first, 20 presets, 2 MiB read cap, atomic writes, play-time LRU touches coalesced for
  2 s). It is device-local and not synced: a curve suits this device's speakers or headphones, and the synced
  `UserPreferences.equalizer` leaves stay as they were. Fixture and unit hosts keep it in memory. An unreadable file
  is ignored and replaced on the next write; clearing history does not touch it.
- Slider drags write through `MusicAppModel.updatePreferences` at most about ten times a second and always once more
  when the finger lifts. The dragged knob follows the finger from local state in between.
- Layout: ten 52-point columns in one row where the width allows (iPad, landscape), otherwise two rows of five.
  Every column is at least 44 points wide and 150 points tall; captions may shrink or wrap at large text sizes.
  VoiceOver reads each band as "31 Hz, +3 dB" and adjusts in 1 dB steps.

## Signal path

```
AVPlayerItem (AAC, Opus-in-MP4 or LPCM; local file or progressive HTTP)
  └─ AVMutableAudioMix ── AVMutableAudioMixInputParameters(trackID: first audio track)
        └─ MTAudioProcessingTap (PostEffects, Float32 at the item's decode rate)
              └─ EqualizerProcessor.render
                    preamp -> 10 RBJ peaking biquads -> normalization gain-up -> linked sample limiter
AVPlayer.volume <- attenuation-only normalization factor and crossfade envelope
```

Why a tap rather than an engine: playback is `AVPlayer`-owned (remote HTTP streams, local cache files, standby deck,
system controls), and `MTAudioProcessingTap` is the only per-item hook that keeps all of that. An `AVAudioEngine`
rebuild would have replaced the player, the standby deck and the cache pipeline.

- `EqualizerTapInstaller.setNormalizationGain(_:for:allowsGainUp:)` registers active items during installation
  and standby items through `StandbyDeck.onConfigureAudio` before replacement/preroll. `attach(to:)` is idempotent.
  The shared mix installs when EQ is enabled or that item needs supported gain-up; `update` can install it later.
- The installer loads the asset's audio tracks (`AVURLAsset.loadTracks(withMediaType: .audio)`) and installs the mix
  with the first track ID. No track (HLS, an unsupported asset type) or a failed load logs a bypass and the item
  plays without EQ. The item's playback never depends on the tap.
- One `EqualizerProcessor` per item owns one `BiquadBank`. `prepare` learns the processing format (sample rate,
  channels, interleaved or planar Float32) and allocates the bank; a non-Float32 format is bypassed. `process`
  pulls source audio with `MTAudioProcessingTapGetSourceAudio` and filters in place. Bands at or above 45% of the
  sample rate are identities, so an 8 kHz or 22 kHz file keeps its audible bands.
- Settings travel main actor to audio thread as a trivially copyable snapshot (`SIMD16<Double>` gains, preamp,
  enabled, revision) behind a `Mutex`. The render callback uses `withLockIfAvailable`: a busy lock defers the change
  to the next buffer. `render` allocates nothing: coefficients, filter state and channel pointers are preallocated.
- Smoothing: gains and preamp ramp linearly in dB over 20 ms, recomputing coefficients every 32 frames. A tap that
  is prepared while enabled starts on the live curve directly rather than fading in.
- Normalization gain-up follows EQ inside the same processor, capped at +6 dB with a 20 ms ramp. Gain targets are
  independent per item even though decks share the EQ curve. A channel-linked limiter bounds decoded frames to
  0.98 full scale with instant attack and 100 ms release. It is not true-peak or final-mix limiting.
- `PlaybackNormalization` and `PlaybackCrossfade` apply only attenuation/envelope factors through `AVPlayer.volume`.
  Native callbacks allocate and log nothing; unsupported PCM and HLS/live gain-up retain normal playback.

## APIs

| API | Owner | Notes |
| --- | --- | --- |
| `EqualizerSettings` (`isEnabled`, `preset`, `gains`, `preamp`, `effectiveGains`) | `Sources/Core/EqualizerSettings.swift` | Lenient decode; exactly 10 clamped gains. New: `resolvedPreamp`, `isFlat`, `summary`, `setGain(_:band:)`, `reset()`, `formattedGain(_:)` |
| `EqualizerPreset.bandFrequencies`, `bandLabels`, `bandTitle(_:)` | same | ISO centres, slider captions, spoken names |
| `BiquadCoefficients.peaking(frequency:sampleRate:gainDb:q:)`, `magnitude(frequency:sampleRate:)` | `Sources/Audio/BiquadBank.swift` | RBJ cookbook, normalized by a0 |
| `BiquadBank` (`setTargets`, `snapToTargets`, `process(frames:channelStarts:stride:)`, `magnitudeDb(at:)`, `responseDb`) | same | Pure DSP, no AVFoundation; Double state, Float32 buffers |
| `EqualizerProcessor` (`apply(_:revision:)`, `makeTap()`, `prepare`, `unprepare`, `render`) | `Sources/Audio/EqualizerProcessor.swift` | One per item; `@unchecked Sendable` with the mutex snapshot |
| `EqualizerTapInstaller` (`update(_:)`, `attach(to:)`, `setNormalizationGain(_:for:allowsGainUp:)`, `normalizationStatus(for:)`, `reportMetrics()`, `status`) | `Sources/Audio/EqualizerTap.swift` | Main-actor item registry; one mix/tap for EQ or gain-up; prunes released items |
| `PlayerController.setEqualizer(_:)`, `equalizerSettings`, `equalizerStatus` | `Sources/Playback/PlayerController.swift` | Idempotent; updates every installed tap live |
| `MusicAppModel.applyPreferenceServices` | `Sources/App/MusicAppModel.swift` | Calls `setEqualizer` at launch and whenever `preferences.equalizer` changes |
| `EqualizerView` | `Sources/Views/EqualizerView.swift` | Identifiers `equalizer.enabled`, `equalizer.preset`, `equalizer.preset.choice.<raw>`, `equalizer.band.<0-9>`, `equalizer.preamp`, `equalizer.reset` |
| Settings row | `Sources/Views/SettingsView.swift` | `settings.equalizer` after Audio quality; value Off, preset title or Custom |
| `SimpleEqualizer` (`weights`, `gains(bass:mids:treble:)`, `controls(for:)`), `EqualizerSettings.simpleControls`, `setSimple(_:to:)` | `Sources/Core/EqualizerSettings.swift` | R14 Simple mode matrix and its least-squares inverse |
| `EqualizerPreset.bandNames`, `bandAccessibilityTitle(_:)`, `summaryDescription`, `describedTitle` | same | R14 plain names |
| `EqualizerProfileStore` (`override(for:)`, `setOverride`, `removeOverride`, `markUsed`, `savePreset(named:from:)`, `deletePreset`, `presetName(matching:)`) | `Sources/Audio/EqualizerProfileStore.swift` | Device-local JSON, bounds above |
| `PlayerController.refreshEqualizer()`, `equalizerSongOverride`, `isEqualizerSongOverrideActive` | `Sources/Playback/PlayerController.swift` | `setEqualizer` stores the global value and calls `refreshEqualizer` |
| `EqualizerTarget`, `EqualizerPresetChoice`, `MusicAppModel.equalizerSettings(for:)`, `updateEqualizer(_:_:)`, `setSongEqualizer(_:for:)`, `applyEqualizerChoice(_:to:)`, `equalizerSummary(for:)` | `Sources/App/MusicAppModel+Equalizer.swift` | Global edits through `updatePreferences`; song edits in the store |
| `EqualizerView(target:)`, `EqualizerPresetMenuRow`, `EqualizerSimpleSliders`, `EqualizerCurveAxis`, `EqualizerBandHints` | `Sources/Views/EqualizerView.swift` | Settings passes `.global`; More controls passes the sheet's target |
| `PlayerEqualizerSheet` | `Sources/Views/Player/PlayerEqualizerSheet.swift` | More > Equalizer page; `player.equalizer.content`, `equalizer.moreControls` |

## Metrics

OSLog only, subsystem `com.agraabhi.ganabajana`, category `Equalizer`. No identifiers, URLs or free text.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=equalizer_settings enabled= preset= preamp=` | `EqualizerTapInstaller.update` accepts a changed setting (launch and every change) | enabled 0/1; preset = `EqualizerPreset` raw value (12 values); preamp auto/manual | Confirms the preference reached the player and which headroom rule applies |
| `event=gapless_swap`, `event=crossfade_started` (existing, category Playback) | Unchanged | Unchanged | Read next to `equalizer_attached` to see whether a boundary ran with taps |
| `event=equalizer_attached path=tap` | The shared item mix/tap installs | path = tap | Includes normalization-only taps |
| `event=equalizer_bypass reason=` | Installer bypasses an item | reason = no_audio_track, asset_type, tap_create, tracks_failed, item_released, existing_mix | Unsupported paths retain normal playback; foreign mixes are preserved |
| `event=normalization_gain`, `event=normalization_limiter` | Main-actor reporting of mode changes and render counters | Closed mode enum and numeric limited-frame/invalid-sample deltas | Full table in VOLUME_NORMALISATION; no logging from native prepare/render callbacks |
| `event=equalizer_settings ...` (existing) | Also on a track change whose override differs from the previous curve | Unchanged | A per-song override shows up as a settings change at the boundary, with no new dimension |
| `event=equalizer_profiles_load result= songs= presets=` | `EqualizerProfileStore` init with a file | result ok, too_large, unreadable; songs 0-1000; presets 0-20 | Confirms the device-local file loads and stays within bounds |
| `event=equalizer_profiles_write result=failed` | An atomic write throws | result failed | Surfaces a full or read-only container without logging names or ids |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `testPeakingCoefficientsMatchTheCookbookFormula` | 1 kHz, +6 dB, Q 1.41 against the RBJ formula; 0 dB gives b0 = 1; above-range band is identity | Unit (`EqualizerTests`) |
| `testEveryBandCentreReachesItsConfiguredGainWhenTheOthersAreFlat` | Transfer function at every centre within 0.5 dB for +6, -4, +12 dB; Bass boost sums neighbours | Unit |
| `testProcessedSineToneCarriesTheBandGain` | Rendered 1 kHz tone gains 6 dB after the transient | Unit |
| `testFlatSettingsAreBitTransparentAndPreampScalesLinearly` | Flat stereo output equals input within 1e-6; preamp scales by 10^(dB/20) | Unit |
| `testSmoothingRampsLinearlyAndSettlesWithinFiftyMilliseconds` | Half the ramp after 10 ms, settled before 50 ms, measured +9 dB (12 dB band, -3 dB preamp) | Unit |
| `testAutomaticMakeupOffsetsTheLargestBoostUnlessAPreampIsSet` | Headroom rule, manual preamp precedence, `Targets` snapshot | Unit |
| `testEditingABandLeavesThePresetAndCopiesItsCurveFirst` | Preset to Custom copy, clamping, out-of-range band, reset, summary and formatting | Unit |
| `testDisabledProcessorPassesAudioThroughAndEnablingRampsIn` | Planar stereo tap render: disabled untouched, enabled filters, disable drains then passes through | Unit |
| `testInterleavedBuffersAndUnsupportedFormatsAreHandled` | Interleaved stereo render; Int16 format bypass | Unit |
| `testSetEqualizerInstallsTapsOnTheCurrentAndStandbyItemsAndUpdatesThemLive` | Off registers two items without taps; enabling while playing installs both; standby keeps its tap after the swap; disabling leaves it passing through | Integration (native AVPlayer, WAV fixture) |
| `testGaplessSwapWithTheEqualizerEnabledStaysNearlySeamless` | Gapless boundary with taps on both decks stays under 0.8 s and prints the measured gap (0.20, 0.21 and 0.40 s in three runs) | Integration (native AVPlayer) |
| `testRemoteStyleProgressiveHTTPItemGetsTheTapAndKeepsPlaying` | Loopback HTTP/1.1 server with byte ranges serves the AAC file; the tap attaches and processes on the HTTP loading path | Integration (native AVPlayer, Network.framework) |
| `testBundledAACFixturePlaysAndAdvancesWithTheEqualizerEnabled` | AAC-in-MP4 exported from the tone fixture plays, advances, seeks and takes a live curve change with EQ on | Integration (native AVPlayer) |
| `testModelAppliesTheSavedEqualizerAtLaunchAndOnEveryChange` | `applyPreferenceServices` fan-out at init and on `updatePreferences` | Integration (model + library) |
| `testSettingsRowOpensTheEqualizerAndShowsTheChosenPresetAfterBack` | Light appearance: row value Off, open, enable, choose Bass boost, band values, Auto -6 dB preamp, Back shows Bass boost, relaunch persists | UI (`GanaBajanaEqualizerUITests`) |
| `testDraggingABandSwitchesToCustomResetReturnsToFlatAndPlaybackKeepsAdvancing` | Dark appearance: drag band 0 from Rock to Custom, neighbour unchanged, Reset to Flat/0 dB, fixture playback advances, pauses and resumes with EQ on | UI |
| Settings inventory (`testIconLabeledSettingsKeepSixSectionsAndNativeTargetsAtLargestTextSize`) | `settings.equalizer` row at accessibility XXXL | UI (`GanaBajanaListeningControlsUITests`) |
| `testSimpleWeightsCoverEveryBandAndSumToOne`, `testSimpleControlsMapToTheirRegionsWithGentleOverlap`, `testSimpleControlsRoundTripThroughTheBands`, `testMovingASimpleControlKeepsTheOtherTwoAndSwitchesToCustom` | Matrix shape, row sums, regional mapping and rounding, clamping, least-squares round trip, Custom switch | Unit (`EqualizerProfileTests`) |
| `testBandNamesAndPresetDescriptionsArePlain` | Band names, spoken titles, preset descriptions, no em dashes | Unit |
| `testStoreKeepsAtMostOneThousandSongsDroppingTheLeastRecentlyUsed`, `testStoreKeepsTwentyNamedPresetsAndRejectsBuiltInNames`, `testStorePersistsAtomicallyAndIgnoresUnreadableFiles`, `testDefaultLocationIsApplicationSupport` | LRU bound with a play-time touch, empty id, 20-preset bound, replace, built-in and blank names, 40-character cap, reload from disk, damaged file | Unit |
| `testPlayerPicksTheSongOverrideOnTrackChangeAndTheGlobalSettingOtherwise` | Next applies the override, a global change leaves it, Previous returns to the latest global | Integration (PlayerController, WAV fixture) |
| `testModelSongToggleSavesTheGlobalCurveAndEditsOnlyThatSong` | Toggle copies the global curve, song edits leave the preference, skip away and back, saved preset name as the row value | Integration (model + library + player) |
| `testSettingsRowOpensTheEqualizerAndShowsTheChosenPresetAfterBack` (R14 additions) | Preset description, Simple Bass reads a boost, Treble 0 dB, bands hidden in Simple, hints; Advanced band name label | UI (`GanaBajanaEqualizerUITests`) |
| `testEqualizerFromMoreKeepsAPerSongOverrideAcrossASkip` | More > Equalizer, enable, Bass boost, Use for this song, Treble slider, More controls Advanced 8 kHz label and boost, row value This song, next song reads Bass boost, back restores the treble, toggle off | UI (`GanaBajanaPlayerMoreUITests`) |

Runs: `artifacts/R13/WP7-EqualizerFinal-01.xcresult` (14 unit, 1 UI), `WP7-EqualizerUI-02.xcresult` (drag UI test
and the Settings inventory test at accessibility XXXL), `WP7-EqualizerUnit-03.xcresult` (EqualizerTests plus
PlaybackTransitionTests, PlaybackControllerTests and PlaybackAudioIntegrationTests, 49 tests, 0 failures), all on
an iPhone 17 Pro / iOS 26.5 simulator.

R14 WP25 runs: `artifacts/R14/WP25-Unit-05.xcresult` (EqualizerProfileTests 11, EqualizerTests 14, 0 failures)
and `WP25-Touched-03.xcresult` (both GanaBajanaEqualizerUITests and the three GanaBajanaPlayerMoreUITests pass);
the full list is in [PLAYER_MORE.md](PLAYER_MORE.md#runs).

## Not verified

- Real remote progressive streams (YouTube googlevideo MP4/M4A, JioSaavn) on a device; the HTTP fixture is a
  loopback server on the simulator. AVFoundation supports taps on progressive MP4 but not on HLS, which bypasses
  with `no_audio_track`.
- AirPlay and other external routes: AVFoundation may skip the tap while audio is routed externally. The listener
  would hear the flat signal without an error.
- Opus-in-MP4 items with the tap (iOS 26.5+ path) on hardware; the tap sees decoded Float32 either way.
- Clipping headroom for stacked adjacent boosts on hot masters (see the headroom rule above).
- Battery cost on a device: 10 biquads per sample in Double is about 20 M multiply-adds per second at 48 kHz stereo.
- iPad and iPhone SE layouts by run: the single-row/two-row choice is `ViewThatFits` on the 52-point column ideal
  width, exercised only on the 17 Pro simulator. The XXXL Settings inventory covers the row, not the page.
- Audible result: the tests measure the transfer function and rendered buffers, not a listening check on hardware.
- Per-song overrides with Crossfade: both decks share one curve, so the outgoing song's tail takes the incoming
  song's curve. Separate curves per deck would need the installer to track which item plays which recording.
- Simple mode at accessibility sizes and on iPad (the rows stack their label above the slider; not captured).
