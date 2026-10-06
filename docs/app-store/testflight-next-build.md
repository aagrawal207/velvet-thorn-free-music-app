# Next-build TestFlight text

**Superseded for What to Test on September 30, 2026.** Build 11's final notes were saved and read back; see `artifacts/AppStore-1.0.0-11/test-notes.txt` and `test-notes-readback.json`. The beta app description below remains an unpublished historical draft. [Current TestFlight state](../APPSTORE_TESTFLIGHT.md) owns delivery status.

**Local draft, 27 September 2026. Do not apply to uploaded build 5.** The target is a verified successor containing the current `1.0.0 (6)` work and the owner-requested visible name **Stats**. Source still says **Listening** at this check. Performance fixes are underway; verify the final binary before using these notes. [Current TestFlight evidence](../APPSTORE_TESTFLIGHT.md) owns distribution status.

## Beta app description

Breezy is a music player for iPhone and iPad. Stream music, build playlists and explore personal mixes. Follow synced lyrics where available, adjust the equalizer for supported audio, and keep complete local copies of supported songs for offline listening. Stats shows your saved listening history and lets you create share cards.

YouTube Music, JioSaavn and Gaana integrations are unofficial. Availability varies by provider. Gaana's own HLS streams cannot be downloaded or equalized; a matching fallback file from another source may be available. Lyrics are not available for every song.

## What to Test

Please try Breezy during your usual listening and send feedback through TestFlight. Include your device model, iOS version and the steps that led to a problem. Avoid sending account cookies or other sign-in details.

- Search for a song and start playback. Try JioSaavn and Gaana with those catalog sources enabled in Settings. Report a wrong recording, a failed start or an unusually long wait.
- Like songs, make a playlist and try a personal mix. Scroll Home and open albums while music plays. Report stutters or taps that feel slow.
- Open lyrics on a song that has synced lyrics and tap a line. Try seeking, Next and returning after locking the phone. Report unexpected pauses or lost position.
- Download a supported song with Breezy open, then play its completed local copy in airplane mode. Check On this device and the difference between downloads and cached songs. Gaana's own HLS streams cannot be downloaded.
- Try equalizer presets on supported audio and switch the equalizer off again. Gaana's own HLS streams bypass it. Report distortion, silence or an unexpected change in volume.
- Open Stats, change the history window and preview a share card. Share a song card too. Check readability with long song names and larger text.
- Relaunch Breezy and check that your playlists and likes remain. If you use iCloud on two devices, check library changes on both and report repeated sync errors. Playback and audio files stay on each device.

## Before these drafts can be applied

Confirm the exact successor build and its feature set, visible Stats label, completed performance work and real-device acceptance. Beta app description is app-level TestFlight text; What to Test belongs to the selected build. Neither is the public App Store description or its What's New field. The TestFlight feedback address and review contact still need owner confirmation in that separate setup. No contact values or review credentials are stored here.
