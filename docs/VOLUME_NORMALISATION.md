# Volume Normalisation

R18 integrates gain-up processing with the existing Normalize Volume preference, PlayerController, standby deck
and Settings. Targeted core/regression verification has passing coordinator-reported coverage; the broader matrix
is in progress. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts.

## Behaviour

Source loudness is advisory metadata relative to the provider's reference. Positive `loudnessDb` means a loud
recording and requests attenuation; negative means a quiet recording and requests gain-up. This is not an output
LUFS measurement or a guarantee that every song sounds equally loud. The limiter can reduce the requested boost.

`PlaybackNormalization.gainDb(loudnessDb:enabled:)` accepts finite metadata in the existing provider range
[-60, +60] dB and returns `min(6, -loudnessDb)`. `gain(loudnessDb:enabled:)` converts that result to linear gain
with `10^(dB / 20)`. Missing metadata, NaN, infinity, out-of-range metadata and Normalize Volume Off return unity.

| Source offset | Requested change | Linear gain | AVPlayer attenuation | Tap gain-up |
| --- | --- | --- | --- | --- |
| +6 dB | -6 dB | 0.501187 | 0.501187 | 1 |
| -3 dB | +3 dB | 1.412538 | 1 | 1.412538 |
| -6 through -60 dB | +6 dB maximum | 1.995262 | 1 | 1.995262 |
| 0, unknown or invalid | 0 dB | 1 | 1 | 1 |

The same `ResolvedStream.loudnessDb` feeds network playback, cached files and downloads. Existing cache sidecars
and extraction caches supply that field; there is no new scan, metadata fetch, sidecar or persistence field.
The system volume control remains user-owned.

## Signal Path and Bounds

```text
Decoded Float32 PCM
  -> existing EQ preamp and 10-band bank, when enabled
  -> normalization gain-up, at most +6 dB
  -> channel-linked sample-peak limiter
  -> existing player attenuation and equal-power crossfade envelope
  -> system output volume
```

`EqualizerTapInstaller` keeps one `EqualizerProcessor` and one native `MTAudioProcessingTap` per item. The existing
audio mix carries both EQ and normalization; a second normalization mix is never installed. An unrelated existing
mix is preserved and reported as `existing_mix`. EQ settings retain their existing shared-curve behaviour across
decks, while normalization gain is independent for each item.

- EQ Off with a positive normalization request still installs the shared tap. With EQ Off and attenuation or
  unity, a fresh item needs no tap. An already installed tap drains to pass-through after both effects turn off.
  Disabling during asynchronous track loading cancels the need for installation without failing the item.
- `EqualizerProcessor.setNormalizationGain(_:)` takes total requested linear gain but applies only the portion
  above unity. `AVPlayer.volume` takes `min(1, requestedGain)`, multiplied by the crossfade envelope exactly once.
  `PlaybackNormalization.attenuationGain(loudnessDb:enabled:)` exposes this player-side factor directly.
- `GainLimiter` ramps linearly in dB over 20 ms, including installation on an already audible item. Mid-ramp edits
  start from the current gain. The existing player-side attenuation behaviour is retained; the new sample ramp
  applies to gain-up. EQ preamp and normalization remain separate factors, each applied once.
- The limiter follows EQ, including manual preamp. One envelope follows the largest absolute sample across all
  channels in each frame. Instant attack bounds that frame to 0.98 full scale; a 100 ms exponential release
  restores gain. This preserves the stereo ratio instead of independently changing the left and right channels.
  It adds no look-ahead latency. Limiting includes the release tail, so sustained limiting can audibly compress peaks.
- Native support is packed-stride, little-endian Float32 PCM, 1 through 8 channels, planar or interleaved, at
  8 through 192 kHz. Formats and buffer sizes are validated before reads. Nonfinite input samples are zeroed in
  the active DSP path, and nonfinite filter state resets instead of contaminating subsequent samples.
- The render callback allocates no arrays or buffers and performs no logging or blocking lock acquisition.
  EQ and gain targets share the existing trivial SIMD snapshot. Prepare and render try the snapshot lock once;
  contention keeps the previous targets until another buffer. DSP/channel storage is allocated in prepare.
  Limiter gain changes precompute their linear step; the sample loop performs no exponentiation.
- `.m3u8` assets bypass before track loading. Missing tracks, unsupported formats, unsupported asset types,
  track-load failure and tap creation failure leave playback on its normal path. Known live paths can explicitly
  pass `allowsGainUp: false`. Loud recordings retain attenuation; quiet recordings fall back to unity.
- A tap installation does not establish an audible boost. `gain_up_pending` means it has not rendered gain-up;
  `gain_up` means the processor has rendered with positive gain in its current preparation. The status is not a
  measurement of an external route. Native routing can bypass taps, and HLS/live gain-up is unsupported.

Peak protection is per decoded item. It is not an oversampled true-peak limiter or a limiter on the final mix of
two crossfading players, and it does not certify DAC output or prevent intersample peaks. Existing equal-power
crossfade geometry is retained. Native tap priming can add a gapless boundary delay even with EQ Off when
normalization requires a tap; the historical EQ measurements in [EQUALIZER.md](EQUALIZER.md) are not R18 evidence.
The earlier EQ timing measurements do not measure normalization-only taps.

## Integrated APIs

| API | Current contract |
| --- | --- |
| `PlayerController.normalizationGain` | Total requested linear gain, possibly above one; not measured output gain |
| `StandbyDeck.onConfigureAudio` | Installed beside `onChange`; calls `equalizer.setNormalizationGain(_:for:)` before replacement/preroll, after cache adoption and on preference changes. `take` retains the item and its own tap target |
| `refreshNormalizationGain(applyToPlayer:)` | Updates requested gain and `deck.normalizeVolume`; when permitted, configures the current item with `allowsGainUp: !isLiveRadio` and sets player volume to `min(1, normalizationGain)` |
| `install(_:track:generation:)` | Configures the incoming item's gain, replaces the item, then refreshes player attenuation so new metadata cannot alter the previous item's gain |
| `activateStandby(_:order:blend:)` | Passes attenuation-only incoming gain and the outgoing player's volume to `PlaybackCrossfade`; each tap retains its own gain-up |
| `tick()` | Calls `equalizer.reportMetrics()`; five-second coalescing uses the existing playback tick |
| `equalizer.normalizationStatus(for:)`, `equalizer.status` | Per-item render state and aggregate bounded counters |

Live selection clears song loudness. A running crossfade keeps its original factors; `endTransition()` applies
the latest saved preference afterward. Normalization targets are not transferred between item processors.

Settings uses `UserPreferences.normalizeVolume`, `PlaybackTransitionSettings.normalizeVolume` and the existing
`MusicAppModel.updatePreferences` path. `settings.normalize` retains its Toggle, and `settings.normalize.description`
explains the +6 dB ceiling, limiter reduction, missing-metadata unity and unsupported live/stream boost.
`Sources/Audio/GainLimiter.swift` and `Tests/GainUpNormalizationTests.swift` belong to the existing recursive source/test targets.

## Metrics

OSLog subsystem `com.agraabhi.ganabajana`, category `Equalizer`. No recording IDs, URLs, source strings or per-frame
events. Render stores counters once per buffer; the main actor reads them.

| Metric | Meaning and bounded dimensions |
| --- | --- |
| `event=normalization_gain mode=` | Mode changes: `unity`, `attenuation`, `gain_up_pending`, `gain_up`, `unsupported`. `gain_up` is native render evidence, not an external-route guarantee. |
| `event=normalization_limiter limiter_clips= invalid_samples=` | Aggregate deltas. `limiter_clips` counts channel-linked frames under gain reduction, including release, not escaped clipped samples. Invalid samples count nonfinite inputs found by the limiter. Counts are values, not dimensions. |
| `Status.normalizationFrames` | Frames processed while normalization gain is nonzero or moving to/from nonzero. |
| `Status.limiterClips` | Aggregate limited-frame counter on retained processors, including EQ-only peaks. |
| `Status.processedFrames` | Frames processed by EQ or normalization, excluding pure pass-through. |
| `event=equalizer_bypass reason=` | Existing bounded reasons, plus `existing_mix`. Unsupported PCM is exposed through `formatBypassed`/normalization status; prepare no longer logs from the native callback. |

`lastInputRMS` and `lastOutputRMS` are atomic per-buffer diagnostic samples around the gain/limiter stage, after EQ
and before player attenuation. They are not loudness analysis and are not logged. Reads are approximate independent
snapshots, not a synchronized pair. `preparedChannels`, `renderedNormalizationGainDb` and `normalizationFrames`
support native render evidence without copying PCM out of the callback. Counters cover retained items, not a
persisted session total. Pruning a released item reports its remaining deltas.

## Coverage and Selectors

The following table maps source coverage. Coordinator-reported Core-02 and Regression-01 results are tracked in
[VERIFICATION.md](VERIFICATION.md); the earlier worker-only unexecuted status is superseded.

| Selector suffix under `GanaBajanaTests/GainUpNormalizationTests/` | Type and intended coverage |
| --- | --- |
| `testKnownLoudnessUsesProviderOffsetAndCapsBoostAtSixDb` | Unit: positive/negative offsets, zero, ±60 dB boundaries, +6 dB cap, attenuation split. |
| `testUnknownInvalidOutOfRangeAndDisabledMetadataNeverBoost` | Unit: nil/NaN/infinity/out-of-range, Off, existing preference-to-playback mapping. |
| `testLimiterZeroFramesSilenceAndUnityAreTransparent` | Unit: empty buffers, silence, unity transparency, direct negative dB gain. |
| `testLimiterPeaksAreBoundedAndStereoChannelsShareOneEnvelope` | Unit: both polarities, stereo ratio, instantaneous peak bound, release recovery. |
| `testLimiterSanitizesNonfiniteAudioAndGainsAndSurvivesHugeFinitePeaks` | Unit: NaN/infinite controls and PCM, huge finite peaks, finite energy counters. |
| `testGainChangesRampInDbAndRetargetFromTheCurrentLevel` | Unit: 20 ms dB ramp and mid-ramp reversal without stepping. |
| `testNormalizationOnlyTapRampsWithEQDisabledAndDrainsToPassThrough` | Unit: EQ-disabled gain-up, live disable ramp, settled pass-through and counters. |
| `testEQPreampAppliesOnceAndEQChangesPreserveNormalization` | Unit: manual preamp and normalization cancel once; EQ edits preserve normalization; no double attenuation. |
| `testPlanarStereoLimiterLinksChannelsAfterEQAndMatchesInterleaved` | Unit: planar/interleaved equivalence, post-preamp limiting and stereo linkage. |
| `testMalformedAndUnsupportedBuffersBypassWithoutReadingPastStorage` | Unit: oversized frame requests, unsupported PCM/rate, prepare/unprepare recovery. |
| `testNonfiniteInputDoesNotPoisonTheEQState` | Unit: EQ-state recovery after nonfinite source samples. |
| `testInstallerKeepsOneSharedTapAndIndependentDeckGainsAcrossToggles` | Native asset integration: independent item targets, mix/tap identity across EQ/normalization toggles, future unity item untapped. |
| `testUnsupportedHLSAndExistingMixRetainUnityFallbackWithoutReplacingAudio` | Installer unit boundary: HLS/live opt-out, attenuation fallback, foreign mix retained. Does not establish live network playback. |
| `testDisablingDuringPendingInstallationLeavesTheItemUntapped` | Native asset integration: disable while loading, no stale mix installation, later re-enable. |
| `testStandbyConfigurationHasItsOwnCallbackAndUsesLatestPreference` | Deck integration with native item readiness and injected preroll: callback preservation, latest preference, muted standby, take/reclaim. |
| `testCrossfadeUsesAttenuationOnlyAndNeverSendsBoostToPlayerVolume` | Unit: bounded player-side factors, nonfinite rejection, attenuation preservation. |
| `testNativeTapReadsKnownPCMAndAppliesLiveGainAndEQChanges` | Native AVPlayer integration: pulls the known 440 Hz PCM fixture, measures gain, edits gain/preamp on the same tap, verifies user-side player volume stays unity. |

Additional focused regression selectors:

```text
GanaBajanaTests/PlaybackTransitionTests/testNormalizationGainFormula
GanaBajanaTests/PlaybackTransitionTests/testNormalizationRequestsAttenuationAndGainUpAndFollowsTheSetting
GanaBajanaTests/PlaybackTransitionTests/testApplyingSettingsMidCrossfadeFinishesTheTransitionWithItsOriginalValues
GanaBajanaTests/PlaybackTransitionTests/testCrossfadeStartsBeforeTheEndRampsBothDecksAndCreditsOnlyPlayedSeconds
GanaBajanaTests/EqualizerTests/testDisabledProcessorPassesAudioThroughAndEnablingRampsIn
GanaBajanaTests/EqualizerTests/testInterleavedBuffersAndUnsupportedFormatsAreHandled
GanaBajanaTests/EqualizerTests/testSetEqualizerInstallsTapsOnTheCurrentAndStandbyItemsAndUpdatesThemLive
```

The two normalization expectations in `PlaybackTransitionTests` intentionally request 1.412538 for -3 dB metadata;
positive-loudness attenuation expectations retain their values. Native-device listening, AirPlay, HLS playback,
correlated crossfade output peaks and normalization-only gapless timing still need coordinator verification.
