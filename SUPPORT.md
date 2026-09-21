# Breezy Support

For help with **Breezy - Stream Music & Chill**, email **[aagrawal207@gmail.com](mailto:aagrawal207@gmail.com?subject=Breezy%20Support)**.

## What to include

- The app version and build shown in **Settings > About Breezy**.
- Your iPhone model and iOS version.
- What happened and what you expected. Include the steps that led to the problem.
- For a song, artwork, or lyrics issue, the title, artist, and song share link if available.
- For a purchase issue, the tip name and the message shown by the app.

A screenshot can help. Leave out account passwords, sign-in cookies, verification codes, and payment-card details.

## Playback and connection problems

Music availability depends on external providers and your connection. If a song does not load, try another recording and note whether the problem affects one song or several. Provider restrictions and temporary outages can affect playback. Oversized or stalled lookup/artwork responses are stopped within the app's resource limits and may leave an error or placeholder.

If YouTube asks for sign-in, **Settings > YouTube account** offers an optional sign-in flow. It may help some playback requests, but it does not guarantee that a recording will become available. Sign-in can also be refused by Google. Breezy is an independent app and is not affiliated with YouTube or Google.

The full player opens from the mini-player. Use **More** at the top for additional actions, or swipe down to minimize. Volume is controlled through your iPhone, connected headphones, or system controls.

### Audio quality

**More > Audio quality** shows the source encoding information when available. **Reload best available audio** checks the current recording again and keeps a usable cached fallback if the lookup or preparation fails. Available encodings depend on the provider; a particular bitrate or Premium tier is not guaranteed.

On iOS 26.5 or later, eligible Opus audio is prepared on the phone for native playback. Preparation changes the file container without re-encoding its audio, and each prepared file must pass a native decoding check. Older systems use AAC. Preparation failures can fall back to AAC.

A successful preparation may save a higher-bitrate encoding alongside the previous cached copy. Later plays can reuse it. Existing audio that is still in use is protected; the app does not replace every song in the cache when you reload one recording.

## Storage and your library

**Settings > Storage** shows temporary audio, artwork, and saved library usage. It also offers audio-cache size choices and controls to clear unused audio, artwork, and recent searches.

- Cached audio is temporary. iOS can remove it, and songs that are not cached need an internet connection. Saving a song to a playlist does not download its audio.
- Storage bytes include all cached encodings of a song and files being prepared. The song count counts that recording once, so extra bytes do not necessarily mean extra songs.
- Clearing caches keeps your library. Audio currently in use may be retained so playback can continue, and the cache can grow again as you listen.
- Turning off **Save listening history** stops new listening-history entries. **Clear listening history** removes existing listening history, recent songs, and generated mixes while keeping likes and playlists.
- Recent searches have separate removal controls in Search and Storage.

Library data is saved on your iPhone and may be included in device backups. Breezy has no app-provided cross-device library sync. The developer cannot retrieve a copy from a Breezy server.

### Recovering a library-storage error

When offered in the error banner, welcome screen, Settings, or Storage, **Reload saved library** checks the saved file again. A successful reload applies its preferences while keeping your current queue and playback. If startup could not load a library and you have not started another queue, the recovered saved queue can return paused. The action preserves an unreadable file and shows another error if it still cannot load safely.

Listening time that cannot be saved is buffered only while the app remains open. Playback pauses if the buffer fills. Unsaved time can be lost when the app closes; clearing or disabling history successfully discards it. If reload keeps failing, contact support before deleting the app, which removes the local library.

### Finishing YouTube sign-out

Use **Settings > YouTube account > Sign out**. If **Sign-out pending** appears, use **Retry sign-out** and check that the operation finishes without an error. Pending status can mean credentials could not be deleted or the local sign-out marker could not be saved or cleared.

A saved, credential-free marker keeps a failed deletion from restoring the account after relaunch. If Breezy says sign-out could not be saved, retry before closing the app; otherwise the old session may return. Keychain data can survive app deletion, so finish sign-out before removing the app.

## Lyrics and song languages

Lyrics are matched to a recording when available. Some sources provide plain text only; synchronized lines and tap-to-seek require source timestamps. The lyrics sheet shows the source and any available recording link. Report incorrect text or timing with the song title, artist, and source shown.

On a **This is [artist]** page, tap a song's language label to see its source or set a correction. **Clear my correction** returns to automatic evidence. A “Likely” label is a suggestion, and uncertain songs remain in All/Unclassified. Corrections are saved locally and are not sent to the metadata provider.

## Radio and search

Radio starts from the station's genre or mood. Choose at least one language; artist hints are optional and none are selected initially. You can start with no hint, add a single artist, or use up to four hints. **Clear artist hints** returns to the station defaults.

The era preference guides starting-song selection and searches. Related songs can span other years, include other artists, or lack a catalog language label. If a station cannot find enough music, use the displayed retry action or try another era. Startup retries and manual continuation can request fresh radio results, but provider cooldowns and outages can still prevent discovery.

The first Search-tab tap opens Search without forcing the keyboard. Tapping the selected tab returns to the top and focuses the existing query.

## New-release alerts

Enable **Settings > New release alerts** and allow notifications in iOS. Checks depend on when the app runs and when iOS permits background refresh. Pending alerts are saved for later retry, but permission, storage errors, and the retained-release limit can prevent delivery. Turning alerts off or unfollowing an artist removes the corresponding pending records when saved; notifications already submitted to iOS are managed separately through system notification controls.

## Optional tips and billing

**Settings > Support development** contains optional, repeatable one-time tips through Apple. Tips support app development and unlock no features or music. They are not subscriptions.

If a tip is pending or the app cannot confirm it, check your Apple purchase history before trying again. A message that a verified tip could not be saved is not a request to buy it again. The count shown in Breezy is a local record, not a complete or guaranteed cross-device purchase history.

For missing tip options or an in-app error, contact the support email above. Apple handles payments and refund decisions. For billing help or a refund request, visit **[reportaproblem.apple.com](https://reportaproblem.apple.com/)**.

## Privacy

See the [Breezy privacy policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) for provider requests, optional sign-in, local storage, backups, and purchases.

## Open-source notices

**Settings > About Breezy > Acknowledgements** includes YouTubeKit and FFmpeg/FFmpegBridge notices. FFmpegBridge is used only for local audio-container preparation. For license, corresponding-source, or rebuild questions, use the support email above. Binary distribution must make the exact corresponding source and required relinking materials available to recipients; a public download URL has not yet been published.

Copyright © 2026 Abhishek.
