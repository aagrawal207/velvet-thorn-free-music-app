# Velvet Thorn Support

**Publication: 24 September 2026 UTC.** The [Support page](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md) includes R6/R7/R8/R9 guidance, readback-verified at Gist revision `e84b3f6fba4d81425f5609196dc12fd59506a4ef`. The public copy omits internal acceptance/signing notes and states standard-build CarPlay availability. [PUBLIC_PAGES.md](docs/app-store/PUBLIC_PAGES.md) records current and historical copies; [VERIFICATION.md](docs/VERIFICATION.md) owns test evidence.

For help with **Velvet Thorn** (App Store record: Breezy - Stream Music & Chill), email **[aagrawal207@gmail.com](mailto:aagrawal207@gmail.com?subject=Velvet%20Thorn%20Support)**.

## What to include

- The app version and build shown in **Settings > About Velvet Thorn**.
- Your iPhone or iPad model and iOS version. If you use the iPad app on a Mac, the Mac model and macOS version.
- For Watch or CarPlay issues, the Watch model/watchOS version or vehicle/head-unit model, connection type, and the message shown.
- What happened and what you expected. Include the steps that led to the problem.
- For a song, artwork, or lyrics issue, the title, artist, and song share link if available.
- For a purchase issue, the tip name and the message shown by the app.

A screenshot can help. Leave out account passwords, sign-in cookies, verification codes, and payment-card details.

## Playback and connection problems

Music availability depends on external providers and your connection. If a song does not load, try another recording and note whether the problem affects one song or several. Provider restrictions and temporary outages can affect playback. Oversized or stalled lookup/artwork responses are stopped within the app's resource limits and may leave an error or placeholder.

When Velvet Thorn detects that you are offline, Search can find saved songs by local metadata and **Cached songs** offers audio available on this device. A mixed queue can skip uncached songs while keeping its order. If no more cached songs are available, playback pauses with an explanation. Reconnecting does not start paused playback; press Play when ready. An unknown network status does not establish that the provider is reachable.

If YouTube asks for sign-in, **Settings > Account & connection** offers an optional sign-in flow. It may help some playback requests, but it does not guarantee that a recording will become available. Sign-in can also be refused by Google. Velvet Thorn is an independent app and is not affiliated with YouTube or Google.

The full player opens from the mini-player. A subtle left-to-right fill across the mini-player's capsule background shows playback progress. Use **More** at the top of the full player for additional actions, **Queue** for the song list with **Shuffle** and **Repeat**, or swipe down to minimize. Returning to Velvet Thorn from the Home Screen or app switcher shows the screen you left; open the player again from the mini-player. Volume is controlled through your device, connected headphones, or system controls.

If Autoplay cannot find more songs when your queue ends, the Queue sheet says why and offers **Try more songs**. A busy music service or a connection problem can cause this; radio stations have their own retry.

**Crossfade** and **Automix** sit together in Playback settings. Crossfade defaults to 0 seconds and Automix defaults off. Crossfade sets a fixed overlap; Automix supplies a short blend when Crossfade is 0. Keep both off for no overlap. Existing saved choices are preserved.

**AirPlay**, the first icon in the player's bottom row, opens Apple's audio-output control. **Album and artists** opens one chooser with **Go to album**, when available, and the credited artists. Pictures load after the choices appear; you can select a name before its picture arrives.

### Shuffle order

Choose **Settings > Playback > Shuffle order > Fewer repeats** to favor songs you have not played recently the next time you shuffle. It uses counted plays from the last seven days, preserves every queued occurrence and can still repeat a song. **Random** keeps ordinary shuffle. A list's Shuffle action chooses the first song using the same policy as the rest; enabling Shuffle during playback keeps the current song.

The setting does not rearrange your current queue. **Repeat song** and explicit song choices still take priority. With **Save listening history** off, or no usable saved history, shuffle is random; the Fewer repeats choice stays saved for later. Changing this setting does not turn history saving on.

### Save the remaining queue

Open **Queue > Save remaining songs**, enter a name and choose **Save playlist**. The selection is captured when the naming sheet opens: the current song and upcoming songs in the visible order. Repeated recording IDs are saved once. Playback can advance while the sheet is open without changing that selection.

Saving keeps the active queue, position, shuffle and repeat settings. A blank name cannot be saved. If saving fails, the sheet keeps the name and songs for retry; use **Reload saved library** when offered, then retry Save. Closing with **Done** does not create a playlist.

### Song play counts

Song rows and the player use the catalog's song-play total when supplied. Individual audio-upload views and weekly chart figures have different scopes and are not substitutes. Counts are rounded provider snapshots, not continuously live counters; different recordings are never added together. An unavailable total stays hidden. Older saved metadata can retain an earlier count; a fresh Search or album page uses the latest available catalog response.

### Audio quality

**More > Audio quality** shows the source encoding information when available. **Reload best available audio** checks the current recording again and keeps a usable cached fallback if the lookup or preparation fails. The action is disabled when Velvet Thorn knows it is offline. Available encodings depend on the provider; a particular bitrate or Premium tier is not guaranteed. More and Queue also show compact current/next cache captions; an unavailable cache status is not proof of a saved file.

On iOS 26.5 or later, eligible Opus audio is prepared on the phone for native playback. Preparation changes the file container without re-encoding its audio, and each prepared file must pass a native decoding check. Older systems use AAC. Preparation failures can fall back to AAC.

A successful preparation may save a higher-bitrate encoding alongside the previous cached copy. Later plays can reuse it. Existing audio that is still in use is protected; the app does not replace every song in the cache when you reload one recording.

## Home Screen widgets

Touch and hold the Home Screen, choose **Edit > Add Widget**, and search for **Velvet Thorn**. Recently played, Liked songs and Mix are available in small, medium and large sizes. Touch and hold a Mix widget and choose **Edit Widget** to select Daily Mix or Discover Weekly.

Tap a song to open playback in Velvet Thorn. Recently played resumes its saved position; list headings open the corresponding library page. The small Mix widget opens its saved mix; larger sizes also offer **Play mix**. If a saved mix has refreshed since the widget was displayed, Velvet Thorn opens the current mix for you to choose Play.

Widgets use saved metadata and small local artwork copies. Compatible cached songs can play offline, but adding a widget does not download music. Open Velvet Thorn after editing the library if a widget looks out of date; iOS controls when refresh requests appear. **Save listening history** off hides recent songs on the widget. Clearing history removes its recents and generated mixes. Removed or unavailable songs open an explanation rather than being restored from an old widget.

## Apple Watch

The native companion requires watchOS 11+ and Velvet Thorn on the paired iPhone running iOS 18+. Now Playing offers play/pause, previous, next, and favorite controls. **Playback options** contains shuffle and repeat. **Library** opens Favorites, Recently played, Playlists, individual playlists, and Queue. Selecting a song starts it on the iPhone and its selected audio route. The Watch does not play or download standalone audio.

**Last seen on iPhone** means the displayed state is cached or unconfirmed. Playback actions are disabled and elapsed time stays frozen while disconnected. Open Velvet Thorn on the paired iPhone, unlock it after a restart if prompted, and refresh the Watch. Commands are not queued for later reconnection. If a command times out, let the player refresh and check its state before choosing the action again; the phone may already have accepted it.

If a list has changed, reload it before choosing a song. **Library needs attention** refers to saved-library recovery on the iPhone, separately from playback. Physical pairing, locked-phone/wake behavior, and background delivery remain pending acceptance.

## CarPlay

The native audio interface offers Favorites, Recently played, Playlists, Queue, and the system Now Playing screen. The **Queue** button on Now Playing opens the current queue. Native transport controls and the shuffle, repeat, and favorite buttons use the same iPhone player and library. **More on iPhone** marks a list limited by the app or vehicle.

A changed list needs a reload before selecting a song. For **Library needs attention**, recover the library on iPhone, then reload the list. A library-error screen's **Now Playing** action returns to the player without retrying the failed change. Disconnecting the CarPlay scene does not itself pause audio, but the phone's audio-route-change policy can still pause playback when a route disappears.

The custom CarPlay app requires Apple's audio-entitlement approval for the App ID and a matching provisioning profile. Approval and signing have not been verified, and native CarPlay device acceptance is pending. Current source or simulator checks do not establish vehicle availability.

**Local development and signing.** Select **`GanaBajana` or `GanaBajanaWatch`** for normal automatic signing without the CarPlay capability. The earlier default configuration requested that capability before it was provisioned, causing the reported signing error. Choose **`GanaBajanaCarPlay` only after Apple approves the capability and the profile includes it**. A valid [CarPlay entitlement key](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-audio) does not grant it to an existing profile; see [Apple's capability request guidance](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements). Do not add the key to the Watch target. Checks of the corrected signing configurations are still in progress.

## Storage and your library

**Settings > Library & iCloud > Storage** shows temporary audio, artwork and saved library usage. It offers audio-cache size choices, unused-cache clearing and **Cached songs**. Cached songs also opens directly from blank Search. Search that list by title, artist or album; play/shuffle uses the matching locally eligible files.

- Cached audio is temporary. iOS can remove it, and songs that are not cached need an internet connection. Saving a song to a playlist does not download its audio.
- Storage bytes include all cached encodings of a song and files being prepared. The song count counts that recording once, so extra bytes do not necessarily mean extra songs.
- Cached songs lists complete stored files and marks whether a compatible copy is available. Partial downloads are not playable entries. An incompatible copy can remain visible for removal. Legacy files use matching saved-library metadata when available, or a **Cached song** fallback. File inventory is not a full decoder check, so playback can still reject damaged audio.
- **Remove cached song** removes all cached versions of that recording. **In use** protects current, upcoming and outgoing audio, including while paused. A failed read or removal keeps an error and retry action instead of claiming an empty cache or successful deletion.
- Clearing caches keeps your library. Audio currently in use may be retained so playback can continue, and the cache can grow again as you listen.
- Turning off **Save listening history** stops new listening-history entries and automatic listening-language checks. **Clear listening history** removes listening history, recent songs, generated mixes and derived language evidence while keeping likes, playlists and explicit language adjustments.
- **Search > Recently opened** has individual removal and **Clear all**. This history is independent of listening history. Older saved query terms remain available to the legacy Storage clear control; a successful search-history clear removes both terms and opened items.

Complete cached audio does not expire on a timer. Recent and repeated durable listening guide which unused songs are evicted when a size/song limit is reached. Turning history off creates no new listening signal for that policy. Artwork and lyrics have separate availability and may still need a connection.

Library data is saved on your device and may be included in device backups. iCloud sync shares library data through your own iCloud Drive when enabled and available. The paired Watch receives library rows from the phone. The developer cannot retrieve a copy from a Velvet Thorn server.

### iCloud sync

**iCloud sync is on by default when this device has no saved sync setting.** A saved Off choice stays off. Manage it in **Settings > Library & iCloud > iCloud sync**. Sign in to the same Apple Account and enable iCloud Drive in system settings. The green cloud means the preference is on; Status reports availability and activity. Likes, playlists, follows, history, recently opened Search items, mixes, preferences and saved song metadata merge across devices. This includes app icon choices, language corrections, lyric timing and each language's recommendation adjustment. Current playback, cached media, derived language-cache files, sign-in and tip records stay on each device.

**Sync now** retries a pending or failed operation. “Handed to iCloud” means Velvet Thorn saved the file for iCloud; another device may update later. If iCloud storage is full, free space in system settings and retry. Turning sync off keeps your local library and existing iCloud files. Offline changes, including removals and history clears, sync when you re-enable it. A changed Apple Account pauses sync until you enable it for that account.

Clearing history also clears it from other devices as they sync. Historical iCloud file versions and device backups are managed separately by Apple; turning sync off or deleting Velvet Thorn does not remove those copies. Corrupt or newer-format sync files are preserved and reported rather than silently replaced.

### Recovering a library-storage error

When offered in the error banner, welcome screen, Settings, or Storage, **Reload saved library** checks the saved file again. A successful reload applies its preferences while keeping your current queue and playback. If startup could not load a library and you have not started another queue, the recovered saved queue can return paused. The action preserves an unreadable file and shows another error if it still cannot load safely.

Listening time that cannot be saved is buffered only while the app remains open. Playback pauses if the buffer fills. Unsaved time can be lost when the app closes; clearing or disabling history successfully discards it. If reload keeps failing, contact support before deleting the app, which removes the local library.

### Finishing YouTube sign-out

Use **Settings > Account & connection > Sign out**. If **Sign-out pending** appears, use **Retry sign-out** and check that the operation finishes without an error. Pending status can mean credentials could not be deleted or the local sign-out marker could not be saved or cleared.

A saved, credential-free marker keeps a failed deletion from restoring the account after relaunch. If Velvet Thorn says sign-out could not be saved, retry before closing the app; otherwise the old session may return. Keychain data can survive app deletion, so finish sign-out before removing the app.

## Lyrics and song languages

Lyrics are matched to a recording when available. Some sources provide plain text only; synchronized lines and tap-to-seek require source timestamps. The lyrics sheet shows the source and any available recording link. Use the **-** and **+** row at the bottom of the lyrics sheet to shift timing by half a second; **Reset** returns to the source timing. The adjustment is saved per recording. Report incorrect text or timing with the song title, artist, and source shown.

An artist page lists **Top songs** from the provider and, below them, **Featuring [artist]**: songs where the artist appears after another performer or in a “feat.” clause. That section appears once such songs are found and is absent for artists without collaborations.

On a **This is [artist]** page, open **Languages** first to see filters and per-song language labels. The compact control reads **Browse by language** when at least two recording languages have been identified. It starts collapsed so the popular-song list is not filled with unknown-language labels. **Check more song languages** and **Retry language checks** appear in the browser when available.

Tap a song's language label to see its source or set a correction. You can also touch and hold the song and choose **Song language**, or use its **Review song language** accessibility action, while the browser is collapsed. **Keep unclassified** saves that choice; **Clear my correction** returns to automatic evidence. Corrections are saved locally and are not sent to the metadata provider.

**YouTube audio language** means the provider supplied a language for that recording's audio. Velvet Thorn uses that tag before lyrics recognition. When it is missing, lyrics and MusicBrainz can supply evidence; cached results avoid repeating recent checks. Titles written in English do not make a song English. Missing or unsupported language evidence can remain Unclassified, and your correction takes priority.

Collapsing and reopening the browser keeps the selected filter. Background results and corrections also keep that selection, even if it becomes empty; use **Show all songs** to return to the full list. A “Likely” label is a suggestion, and uncertain or conflicting songs remain in All/Unclassified. An artist's country or a Latin-script title does not prove the song's language. Automatic checks can remain uncertain even for English songs.

## Listening languages and recommendations

**Settings > Discovery > Discovery balance** offers **More familiar**, **Balanced** and **More new**. It guides new Home recommendations and future mixes. Familiar music includes songs you have heard or saved; Discover Weekly still selects unheard songs while shifting toward familiar or less-known artists. Available songs and artist limits affect the final balance. Existing mixes keep their current-period songs, and changing the setting preserves current playback.

Open **Recap > Listening languages** or **Settings > Discovery > Listening languages** for the last 30 days. A play counts after 30 seconds, or halfway through a song shorter than a minute. Every counted play remains in the totals, including Unclassified; repeated sessions can count again, but extra listening checkpoints within one session do not.

**Tune recommendations** offers **More**, **Automatic** and **Less** for Bengali, English, Hindi, Tamil and Telugu. These adjustments guide the next Home refresh, new radios and newly generated mixes. They do not change your statistics, replace an active queue or remove a language completely. Existing saved mixes keep their current-period selection. **Reset adjustments** restores Automatic.

While Velvet Thorn is active, history saving is on and the device is not known offline, songs you have played can trigger recording-metadata and lyrics checks without opening an artist or lyrics page. Checks run in bounded batches; **Check more songs** can request another pass, subject to recent-check cooldowns. Lyrics recognition runs on this device, and uncertain evidence stays Unclassified.

History off pauses new checks and keeps existing statistics. Previously cached classification evidence can still be read for saved history. Clearing history resets the learned counts and derived evidence, while your explicit adjustments and recording corrections stay saved.

## Album descriptions

Album pages use a larger cover and an artwork-colored background, as do artist pages. Album, mix and playlist rows show available song lengths. The song count and complete running time appear at the bottom; incomplete catalog durations are not guessed.

An album can show **About this album** inline, starting at three lines. Use **Read more** and **Show less** to expand or collapse it. **Wikipedia via YouTube Music** and the supplied license link stay visible in both states. The prose and article link come from that album's YouTube Music header; the license remains the one supplied with the text, including CC BY-SA 3.0 when present.

Descriptions appear only when the album identity and header artist or soundtrack-composer credits agree. Missing or uncertain text leaves the section absent. A lookup failure offers **Retry** without reloading the songs; playback and save actions remain usable. This feature needs no extra account and makes no automatic Wikipedia request. The article and license websites open only when you follow their links. Report incorrect descriptions with the album title, credited artists, and displayed article link.

## App icons and compact switches

**Settings > Appearance > App icon** offers 7 choices, including the rose-pen pair **Thorn** and **Sonnet**. Each pen points toward the lower-left through the rose. **Leafnote** remains the default. Select an icon in the picker; iOS keeps the installed choice across relaunches. If you had picked an icon that is no longer offered, the app returns your Home Screen icon to Leafnote; iOS shows its usual confirmation once. The App icon row appears only where the system allows alternate icons; on a Mac running the iPad app it is not shown.

Settings groups its icon-labeled rows as Playback, Library & iCloud, Appearance, Discovery, Account & connection, and About Velvet Thorn, with consistent section spacing. Storage and library recovery sit under Library & iCloud; **Discovery balance**, **Customize Home**, Listening languages, follows and release alerts sit under Discovery. Home customization opens from Settings. Switches in Settings and Customize Home use a 20% smaller native visual while retaining full-row taps, a minimum 44-point height and native accessibility actions. Language adjustments and listening preferences use menus.

## Radio and search

Blank Search starts with **Liked songs**, **Cached songs**, your recent playlists and **Recently opened**. The separate **Radio** row opens the 34 stations grouped as Moods and Genres. Radio starts from the station's genre or mood, with languages following your listening and optional adjustments. Choose an era and zero to four artist hints; none are selected initially. **Clear artist hints** returns to the station defaults. Targeted genre/mood searches fill gaps where hand-picked songs are unavailable.

The era preference guides starting-song selection and searches. Related songs can span other years, include other artists, or lack a catalog language label. If a station cannot find enough music, use the displayed retry action or try another era. Startup retries and manual continuation can request fresh radio results, but provider cooldowns and outages can still prevent discovery. For stations without hand-picked songs, the era shapes the searches; when no result can be dated, undated songs may still start the station.

Search accepts songs, artists, albums and playlists in any language. Filters appear after a request starts for the current text. Recently opened saves the actual destination you select, not the text you type or submit. Reopening an item goes directly to that song or collection; a collection loads its current provider content rather than a saved old song list.

The first Search-tab tap opens Search without forcing the keyboard. Tapping the selected tab returns from a nested page, keeps the query and warmed results, then focuses with one scroll. Reduce Motion disables the animation. **Find music** and **Search all music** return to blank Search rather than leaving a native destination in front of it.

Inside liked songs or a playlist, local search matches title, any credited artist and album, ignoring case and accents. Play and Shuffle use the matching list captured at the tap. Removing a filtered row removes that recording; cancel search before reordering. These local queries do not become Recently opened entries by themselves.

## New-release alerts

Enable **Settings > Discovery > New release alerts** and allow notifications in iOS. Checks depend on when the app runs and when iOS permits background refresh. Pending alerts are saved for later retry, but permission, storage errors, and the retained-release limit can prevent delivery. Turning alerts off or unfollowing an artist removes the corresponding pending records when saved; notifications already submitted to iOS are managed separately through system notification controls.

## Optional tips and billing

**Settings > About Velvet Thorn > Support development** contains optional, repeatable one-time tips through Apple. Tips support app development and unlock no features or music. They are not subscriptions.

If a tip is pending or the app cannot confirm it, check your Apple purchase history before trying again. A message that a verified tip could not be saved is not a request to buy it again. The count shown in Velvet Thorn is a local record, not a complete or guaranteed cross-device purchase history.

For missing tip options or an in-app error, contact the support email above. Apple handles payments and refund decisions. For billing help or a refund request, visit **[reportaproblem.apple.com](https://reportaproblem.apple.com/)**.

## Privacy

See the [Velvet Thorn privacy policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) for provider requests, optional sign-in, local storage, backups, and purchases.

## Open-source notices

**Settings > About Velvet Thorn > Acknowledgements** includes YouTubeKit and FFmpeg/FFmpegBridge notices. FFmpegBridge is used only for local audio-container preparation. For license, corresponding-source, or rebuild questions, use the support email above. Binary distribution must make the exact corresponding source and required relinking materials available to recipients; a public download URL has not yet been published.

Copyright © 2026 Abhishek.
