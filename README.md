# Velvet Thorn

**A free, open-source music app for iPhone, iPad, Mac and Apple Watch.** You can use it instead of paid streaming apps like Spotify: no subscription, no ads, no account needed. You build it yourself and install it with Xcode.

Velvet Thorn is a native Swift 6 / SwiftUI app for iOS 18 and later. It plays audio from YouTube Music, JioSaavn and Gaana, learns what you like on your device, and keeps your library in iCloud if you want it to.

> Velvet Thorn has no connection to Spotify, YouTube, Google, JioSaavn or Gaana, and none of them endorse it. See [Important notes](#important-notes) before using it.

## Features

- **Search and play** songs, albums, artists and playlists from YouTube Music, JioSaavn and Gaana, with source badges and one shared player.
- **Personal mixes on your device:** Daily Mixes, Discover Weekly, Moment Mixes and a Home screen you can rearrange.
- **Song and artist Radio** that stays close to the song or artist you started from, plus **Live Radio** stations from Radio Browser.
- **Likes and Super Likes:** hold the heart to super like a song. Super liked songs count more in your mixes.
- **Downloads** for offline listening, an audio cache, and **Export Audio** to tagged M4A files.
- **Synced lyrics** from LRCLIB and JioSaavn, which can also show on a TV over AirPlay.
- **Stats:** top songs, artists, genres and languages for the week, month, year and all time, with shareable cards.
- **Sound:** a 10-band equalizer, volume normalization, crossfade, Automix, gapless playback and a sleep timer.
- **Optional extras:** skip sponsor segments and intros with SponsorBlock, import your YouTube Music library, and connect a YouTube account for higher-quality audio. All of these are off until you turn them on.
- **Everywhere:** Home Screen widgets, an Apple Watch remote, Handoff and nearby-device playback between your own devices, a Mac app (Mac Catalyst) and CarPlay (needs Apple approval, see below).
- **Make it yours:** 20 app icons, seven accent colors, and dark, light or system appearance.

Nothing you do leaves your device unless a feature needs it. There is no Velvet Thorn server. See [PRIVACY.md](PRIVACY.md).

## Install on your iPhone with Xcode

### What you need

- A Mac with **Xcode 27** or later. The app runs on iOS 18 and later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), which creates the Xcode project: `brew install xcodegen`.
- An **Apple ID**. A free account works. A paid Apple Developer account ($99 a year) adds iCloud sync and avoids the 7-day expiry.
- An iPhone or iPad with **Developer Mode** turned on (Settings > Privacy & Security > Developer Mode).

### Steps

1. **Clone the repository.**

   ```sh
   git clone https://github.com/aagrawal207/velvet-thorn-free-music-app.git
   cd velvet-thorn-free-music-app
   ```

2. **Find your Team ID.** In Xcode > Settings > Accounts, add your Apple ID, select it and click **Manage Certificates** > **+** > **Apple Development** if you don't have a certificate yet. Then print your 10-character Team ID:

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject | sed -E 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/'
   ```

   With a paid account you can also read it at [developer.apple.com/account](https://developer.apple.com/account) > Membership.

3. **Point the project at your team.** Pick a bundle ID prefix that is unique to you, for example `com.yourname.velvetthorn`.

   ```sh
   # Free Apple account (no iCloud sync):
   tools/configure-signing.sh YOURTEAMID com.yourname.velvetthorn --no-icloud

   # Paid Apple Developer account (keeps iCloud sync):
   tools/configure-signing.sh YOURTEAMID com.yourname.velvetthorn
   ```

   The script sets your team and replaces the original bundle ID, App Group and iCloud container everywhere they appear.

4. **Generate and open the project.**

   ```sh
   xcodegen generate
   open GanaBajana.xcodeproj
   ```

5. **Run it.** Connect your iPhone, choose the **GanaBajana** scheme and your device at the top of Xcode, then press **Run** (⌘R). The first time, iOS asks you to trust the developer: open Settings > General > VPN & Device Management, select your Apple ID and tap Trust.

The project, module and scheme are still called `GanaBajana`, the app's original working name. The app on your Home Screen is called Velvet Thorn.

### Free account limits

- The app stops opening after **7 days**. Connect your phone and press Run again; your library stays in place.
- Free accounts can run **3 apps** of your own on a device at a time.
- **iCloud sync** needs a paid account. With `--no-icloud`, Settings shows sync as unavailable, and everything else works.

### Apple Watch, Mac and CarPlay

- **Apple Watch:** the Watch app is embedded in the iPhone app. When your Watch is paired, it installs from the Watch app on your iPhone (or run the **GanaBajanaWatch** scheme). The Watch is a remote; music plays on the iPhone.
- **Mac:** choose the **GanaBajana** scheme with **My Mac (Mac Catalyst)** as the destination. Requires macOS 15 or later.
- **CarPlay:** Apple only grants the CarPlay audio entitlement to approved developers. If you have it, use the **GanaBajanaCarPlay** scheme. The normal scheme builds without CarPlay.

### Optional: better language detection

Velvet Thorn can ask the official YouTube Data API for a song's audio language. This is optional; without it the app falls back to lyrics and MusicBrainz. Create an API key in the [Google Cloud console](https://console.cloud.google.com/apis/credentials) with the YouTube Data API v3 enabled, then run:

```sh
python3 tools/configure-youtube-data-api.py
xcodegen generate
```

The key is stored in `Resources/YouTubeDataAPI.local.plist`, which Git ignores. Details are in [docs/YOUTUBE_DATA_API.md](docs/YOUTUBE_DATA_API.md).

## Troubleshooting

| Problem | Fix |
| --- | --- |
| "No profiles for 'com.agraabhi.ganabajana' were found" or the bundle ID is unavailable | Run `tools/configure-signing.sh` (step 3), then `xcodegen generate` again. |
| "Personal development teams do not support the iCloud capability" | Run the script again with the same team and prefix plus `--no-icloud`, then `xcodegen generate`. To switch to a different prefix, run `git checkout .` first. |
| Xcode says the YouTubeKit or FFmpegBridge package is missing | Close and reopen the project so Xcode refreshes its package graph. |
| `xcodegen: command not found` | `brew install xcodegen` |
| "Untrusted Developer" on the iPhone | Settings > General > VPN & Device Management > your Apple ID > Trust. |
| The app stopped opening after a week | Free accounts sign for 7 days. Run it from Xcode again. |

## Important notes

- **Unofficial sources.** Playback, search and downloads use unofficial, undocumented YouTube Music, JioSaavn and Gaana interfaces. They can change or break at any time, and using them may go against those services' terms. You are responsible for how you use this app and for respecting the rights of the people who make the music.
- **For personal use.** Velvet Thorn is not on the App Store, and the features that rely on these sources would not be accepted there. Do not redistribute music you download with it.
- **Your data stays with you.** Your library, history and mixes live on your device and, if you turn it on, in your own iCloud Drive. Optional YouTube sign-in is stored in the device Keychain and is used only for the features you enable. See [PRIVACY.md](PRIVACY.md) and [docs/PROVIDERS.md](docs/PROVIDERS.md).

## For developers

- [Architecture and API contracts](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md) and [verification records](docs/VERIFICATION.md)
- [Providers, data handling and attribution](docs/PROVIDERS.md)
- Feature notes in [docs/](docs/), for example [Seed Radio](docs/SEED_RADIO.md), [iCloud sync](docs/ICLOUD_SYNC.md), [Downloads](docs/DOWNLOADS.md), [Equalizer](docs/EQUALIZER.md), [Watch](docs/WATCH.md), [CarPlay](docs/CARPLAY.md) and [Widgets](docs/WIDGETS.md)
- [AGENTS.md](AGENTS.md) holds the full set of code and persistence rules used during development.

`project.yml` is the source of truth for the Xcode project; edit it rather than the generated `.xcodeproj`. `tools/verify.sh` runs the unit, UI, Watch, live-provider and release checks and writes output to `artifacts/`, which Git ignores.

## License

Velvet Thorn is released under the [MIT License](LICENSE). Bundled third-party code keeps its own license: [YouTubeKit](Vendor/YouTubeKit/LICENSE) (MIT) and [FFmpeg/FFmpegBridge](Vendor/FFmpegBridge/LICENSE.md) (LGPL 2.1). See [Acknowledgements](Resources/Acknowledgements.txt). The license covers this code only, not any music, lyrics or artwork the app plays or shows.
