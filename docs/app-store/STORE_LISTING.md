# Breezy store listing

**Local draft for the initial release.** Nothing in this file has been published to App Store Connect. Submission is on hold for the [content-rights decision](RELEASE_STATUS.md#submission-hold). The copy describes the current implementation and must be reconciled with the selected licensed provider/content approach before use. The fenced fields below contain only customer-facing copy.

Breezy remains the provisional name for **1.0.0 (2)**. [NAMING.md](NAMING.md) records alternatives awaiting owner selection. [Release status](RELEASE_STATUS.md) records the signed local archive/development export, multi-run fixture/provider results, open live UI/platform acceptance, and content-rights/recipient-FFmpeg-delivery blockers.

## App information

| Field | Draft value |
| --- | --- |
| Primary locale | English (U.S.), `en-US` |
| Current provisional name | `Breezy - Stream Music & Chill` (29/30 characters) |
| Subtitle | `Radio, lyrics & daily mixes` (27/30 characters) |
| Primary category | Music |
| Platform | iOS, iPhone; minimum iOS 18 |
| Home Screen name | Breezy |
| Version | 1.0.0, initial release |
| Current source build | 2; signed local Release archive and development IPA generated |
| Default icon | Leafnote; 14 unique visible choices |
| Copyright | `2026 Abhishek` |
| Support URL | [Published Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md); local source: [SUPPORT.md](../../SUPPORT.md) |
| Privacy Policy URL | [Published Privacy Policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md); local source: [PRIVACY.md](../../PRIVACY.md) |
| Marketing URL | Not supplied; leave unset |
| App price, territories, and release date | Not configured; owner decisions pending |
| Age rating and App Privacy answers | Pending assessment of the final content/provider model |

`GanaBajana` remains the internal module/project/folder, with bundle ID `com.agraabhi.ganabajana`. Support/Privacy pages were updated and readback-verified on 21 September 2026; Settings links and copy are aligned. Store fields remain unwritten: API access works, the web session is unauthenticated, and app readback is empty. The development IPA remains local. The source repository is private on `main`.

## Promotional text

142/170 characters.

```text
Find a radio for your mood, build playlists and follow the lyrics. Make Breezy yours with a custom Home, 14 app icons and seven accent colors.
```

## Description

2,727/4,000 characters, including paragraph breaks.

```text
Breezy brings music search, personal mixes and a simple player to your iPhone.

MAKE HOME YOURS
Arrange your Home sections and hide the ones you don't use. Return to recently played songs, explore your Daily Mix and Discover Weekly, and find new releases from artists you follow. Personal mixes develop from your listening and library choices.

START A RADIO
Choose from ten genre, mood and classics stations. Select at least one language and an era preference. Artist hints are optional: start with none, or add up to four. The station guides discovery through song searches, playlists and related-song radio. Results can span other eras or include songs without language labels. If a station cannot load enough music, try again or change your preferences.

FIND YOUR NEXT SONG
Search for songs, artists, albums and playlists in any language. Return to recent searches or explore an artist's popular recordings, sorted by available provider play counts. Song-language labels show their source, and you can save your own corrections.

STAY WITH THE MUSIC
Use the full-screen player, keep the mini-player close while browsing, and open More for additional actions. Adjust crossfade, gapless playback, Automix and Autoplay, or set a sleep timer. Volume normalization turns louder songs down without boosting quieter ones.

FOLLOW THE LYRICS
Read recording-matched lyrics when available. Synchronized lyrics follow source timestamps and let you tap a line to seek. Some recordings have plain lyrics only. Source credits stay visible.

KEEP YOUR FAVORITES
Save liked songs, build playlists and follow artists. Explore a personal recap of your last week, month or year of listening. Optional new-release alerts depend on notification permission and when iOS allows checks.

CHOOSE YOUR LOOK
Choose from 14 original app icons, with Leafnote as the default, and seven accent colors. Use dark, light or system appearance.

Music and lyrics depend on external providers and your connection. Breezy uses an unofficial YouTube Music integration and is not affiliated with YouTube or Google. More shows available source audio details and offers Reload best available audio. On iOS 26.5 or later, eligible Opus audio is prepared locally for native playback without re-encoding, with AAC fallback. A prepared higher-bitrate cache copy can be reused later. Source bitrates are not guaranteed. Temporary audio is purgeable and is not a managed offline-download library.

Your library is saved on your iPhone and may be included in device backups. Providers receive requests for music, artwork and lyrics. Settings includes history and storage controls.

Optional one-time tips through Apple support development and unlock no features or music.
```

## Keywords

89/100 characters, including commas and spaces.

```text
radio,lyrics,playlists,hindi,english,bollywood,artists,albums,recap,crossfade,sleep timer
```

## Initial release note

This is the initial release, with no previous published App Store version or release tag. Use the launch copy only if the initial-version metadata workflow calls for release notes.

```text
- Search for music and start a radio for your mood.
- Arrange Home, save playlists and explore personal listening mixes.
- Read available lyrics and keep playback close with the mini-player.
- Choose from 14 app icons and seven accent colors.
```

## Supporting assets

- [IAP manifest](IAP_MANIFEST.json): all five intended consumable tips.
- [Review notes](REVIEW_NOTES.md): screen path, purchase behavior, and pending reviewer details.
- [Screenshot plan](SCREENSHOTS.md): real-app captures and separate IAP review evidence.
- [Privacy assessment](PRIVACY_REVIEW.md) and [public-page integration](PUBLIC_PAGES.md).
- [Provisional naming and public-search scope](NAMING.md).
- [FFmpeg source and relink delivery](../FFMPEG_DISTRIBUTION.md).

Avoid claims of authorized YouTube access, paid music access, lossless/hi-fi quality, strict all-track radio filtering, universal lyrics coverage, or guaranteed offline playback. A tip is support for development, not ad removal or a music entitlement.
