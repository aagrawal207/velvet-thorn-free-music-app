# Breezy Privacy Policy

Last updated: 25 September 2026

**Publication: 24 September 2026 UTC.** The [published policy](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md) includes R9 recording metadata and R6/R7/R8 data handling, byte-verified at Gist revision `e84b3f6fba4d81425f5609196dc12fd59506a4ef`. [PUBLIC_PAGES.md](docs/app-store/PUBLIC_PAGES.md) records current and historical copies. The public copy omits this internal paragraph and development-only notes; [official metadata](docs/YOUTUBE_DATA_API.md), [listening-led discovery](docs/LISTENING_DISCOVERY.md) and [widgets](docs/WIDGETS.md) own implementation bounds.

This policy covers **Breezy - Stream Music & Chill**, developed by Abhishek. For privacy questions, contact **[aagrawal207@gmail.com](mailto:aagrawal207@gmail.com?subject=Breezy%20Privacy)**.

Breezy stores your library on your device and syncs shared library data through your iCloud Drive when available. Sync starts enabled on installations without a saved sync setting; you can turn it off in Settings. It contacts external services directly for music, artwork, lyrics and purchases. Its companion shares limited playback and library data with your paired Apple Watch, and CarPlay displays the phone's music interface. It has no Breezy account service or app-operated analytics server. Provider requests leave the device, and device backups may include saved app data.

## Data saved on your device

Breezy's saved library includes:

- Liked and disliked songs, playlists and their names, followed artists, release updates, and identifiers for up to 60 pending release alerts.
- Listening sessions and recent songs, with recording details, dates, and time listened. A history-reset identifier prevents pending listening from restoring history that you cleared or stopped saving.
- The queue, playback position and occurrence-order mapping, generated mixes, and preferences such as Home layout, accent, legacy discovery-language choices, each language's More/Automatic/Less recommendation adjustment, Shuffle order, Discovery balance, and cache size.
- Up to 20 recently opened Search destinations, stored as recording or collection metadata with their type and provider identity. Explicit result, recent-item and result-menu destination choices update this list. Collection snapshots omit their track lists. Typing or submitting a query does not add an entry.
- Lyrics timing adjustments and manual song-language corrections.
- Verified tip transaction identifiers and whether each transaction is credited or revoked, to avoid counting the same purchase twice.

Search terms saved by older versions remain in a separate compatibility field until removed or search history is cleared. They are not converted into guessed songs or collections. Local liked-song/playlist filters are view state, not another saved search history.

The library uses versioned atomic saves. If a saved file cannot be read safely, Breezy preserves it and shows an error rather than replacing it with an empty library. **Reload saved library** checks the saved file again and applies recovered preferences while keeping current playback. An untouched startup state can restore a recovered queue paused. Failed reloads preserve the last safely loaded library.

Listening time that cannot be saved remains in a bounded memory buffer during the current app session. Playback pauses if that buffer fills. This unsaved time can be lost when the app closes; it is discarded when a successful history-clear or history-disable change requires it. The buffer is not a second persistent history file.

Fewer repeats reads counted plays from the last seven days when a new shuffle order is requested. History off or unavailable saved storage supplies no evidence, so ordering is random while the chosen setting remains saved. Discovery balance ranks existing candidate pools using saved listening/library evidence. These controls maintain no separate persistent listening counter; the shuffle occurrence mapping belongs only to device-local playback state. The preference choices sync through iCloud when enabled.

Audio and artwork use separate temporary caches. The audio cache can hold several immutable encodings of the same recording, with codec, bitrate, duration, byte count, preparation version, storage time and optional display metadata such as title, credits, album and artwork URL. It does not save signed streaming URLs. Older sidecars can use matching metadata already in the saved library, without fetching missing names for the inventory. Lyrics text, album descriptions, temporary catalog responses and resolved stream links use in-memory caches. There is no separate persistent album-description store.

Listening-language discovery also uses a bounded, expiring local cache. It stores a recording ID and normalized matching metadata, the language result and its provenance, and check/expiry times. Provenance can identify YouTube audio-language metadata or MusicBrainz recording/work IDs. It stores no lyric text, audio, listening events or aggregate play counts. Identified results expire after 12 hours; unclassified results use a shorter lifetime. This derived file is purgeable, excluded from backups on successful writes and separate from the synced library. Saved recording corrections and explicit recommendation adjustments remain in the library.

For eligible Opus recordings on supported iOS versions, Breezy downloads a complete WebM file and uses the bundled FFmpegBridge to copy its encoded audio into an MP4 container locally. Apple's media framework checks native decoded audio before the prepared file becomes playable. FFmpegBridge has no network or audio-decoder functionality and does not send audio to an additional service. Preparation uses temporary files and memory; the source preparation file is removed when the operation finishes or fails. A validated output can remain in the purgeable audio cache alongside an existing encoding.

## Requests to external services

Every network service can receive the connection's source IP address, request time, and normal connection/request headers. The address seen may depend on your network, VPN, or relay. The following requests are part of the current app:

| Service and domains | Data sent and purpose |
| --- | --- |
| YouTube Music and YouTube Charts: `music.youtube.com`, `charts.youtube.com` | Search text and filters; genre/mood queries and optional artist hints; artist, album, playlist, recording, or radio-seed IDs; chart region; client language/version context; and provider continuation or visitor data. Used for search, discovery, artist pages, album descriptions, charts, and radio. Saved YouTube account cookies are not added to these requests |
| YouTube Data API: `www.googleapis.com` | Recording IDs, selected metadata fields, Breezy's app API credential and bundle identifier. Used to read default audio language and missing duration for lyrics or recording-language lookups. Saved YouTube account cookies are not added |
| YouTube playback: `youtube.com`, `www.youtube.com`, `*.googlevideo.com` | Recording IDs, player/client context, provider visitor data, and signed media requests. Used to resolve, validate, stream, and cache audio. A specific playback lookup can also include your saved YouTube session if you choose to sign in |
| Artwork hosts | Requests to image URLs supplied by the provider, commonly under `*.ytimg.com`, `*.googleusercontent.com`, and `*.ggpht.com`. The URL identifies the image and may identify its recording. Other provider-returned image hosts may also be used |
| LRCLIB: `lrclib.net` | Song title, artist, optional album, and recording duration when available, plus app-client headers. Used to match lyrics through `/api/get` and `/api/search` |
| YouTube Music lyrics: `music.youtube.com` | The selected recording ID and its linked lyrics-page ID. Used when LRCLIB does not provide usable lyrics or a lookup fails. LyricFind and Musixmatch credits, when present, arrive through YouTube Music; Breezy does not request their services directly |
| MusicBrainz: `musicbrainz.org`, when configured | Cleaned song title, artist names, a duration range, and a matched recording ID. If a compatible linked work's embedded language fields are missing or empty, the exact work ID is also sent in `GET /ws/2/work/<exact-linked-work-ID>?fmt=json`. Used to look up recording/work language metadata through the official API. The client header contains app identification and a developer contact URL |
| Apple StoreKit services | App and product identification and purchase/transaction requests. Apple processes storefront information, Apple Account authentication, and payment details through its services |
| Apple iCloud Drive, when sync is enabled | Library records, preferences, saved metadata and merge revisions described below. Apple handles storage and delivery through the signed-in Apple Account |
| Public Support and Privacy pages: `gist.github.com` | When you open these links, GitHub receives ordinary browser request data for the page. These user-opened pages are separate from background music requests |
| Album-description attribution links: `en.wikipedia.org`, `creativecommons.org` | Ordinary browser request data when you choose to open the article or license link. Breezy does not automatically fetch these sites for descriptions |

Online Search results update while you type, so partial text can be sent before you submit it even though query text is not added to Recently opened. Liked-song/playlist filtering uses local metadata. Known-offline Search searches saved metadata rather than sending a catalog search.

Opening the player's artist-choice list can request the credited artist IDs, or search their names, and download provider-supplied pictures before an artist is selected. Optional pictures use bounded in-memory lookup caches and the existing artwork cache. Selection remains available while these requests run.

Home and search can prefetch suggested audio before you press Play. Playback also prepares upcoming songs. These requests and complete-file downloads can use your network connection, including cellular data when iOS permits it. Opening an artist page sends bounded song searches to the catalog provider to find collaborations for its **Featuring [artist]** section. Opening a **This is [artist]** popular-song page can trigger bounded lyrics and configured MusicBrainz requests even while **Languages** is collapsed and the lyrics sheet is closed.

After qualifying listening, Breezy can also check recording languages automatically while the app is active, listening-history saving is enabled and the device is not known offline. It first reuses cached results or checks the recording's default audio-language tag through the YouTube Data API. A usable tag avoids lyrics lookup and recognition. Missing tags can lead to recording-matching requests to LRCLIB and configured MusicBrainz, with linked YouTube Music lyrics as fallback, without opening an artist page or lyrics sheet. Home and the Listening languages page can request another bounded pass. Pausing the app, known-offline status or disabling history retires these automatic checks; previously saved cache evidence may still be read for existing history.

Language recognition from matched lyrics runs on your phone. The YouTube metadata response uses a bounded memory cache and can supply a missing duration to a temporary lyrics/MusicBrainz request; it does not rewrite the saved track or playback position. The conditional work lookup sends a MusicBrainz entity ID, not lyric text. Manual corrections are saved in your library and are not submitted to Google or MusicBrainz. Language-browser expansion and filter selection are kept only in memory.

Album descriptions use Wikipedia text already supplied in the selected YouTube Music album header. An optional description-only lookup sends the album browse ID to the existing catalog endpoint and can use its normal bootstrap request. The article and supplied license links are retained, including CC BY-SA 3.0 when supplied. This feature adds no automatic Wikipedia, Wikidata, or MusicBrainz request, and requires no additional account or authentication.

**Reload best available audio** requests fresh source selection and may download a new encoding when a connection is available. Known-offline resolution uses compatible local files, including on a forced retry; the quality-reload control is disabled in that state. The resulting prepared cache variant can be reused on later plays; it does not upload your cached library. Radio setup drafts and artist hints are not saved as preferences, but the queries and recording requests they generate are sent to the catalog provider.

Personal mix ranking, recap and language-share calculations run on the phone. Automatic discovery uses qualified listening and saved language adjustments to choose recording seeds and language search text. Provider requests for candidates, followed artists and radio seeds can therefore reveal interests derived from your library. The complete local library is not uploaded to a Breezy server.

## iCloud sync

**iCloud sync defaults on when this device has no saved sync setting.** A saved Off choice stays off. Manage it through **Settings > Library & iCloud > iCloud sync**. When enabled and iCloud Drive is available, shared library records are sent to the app's container in your iCloud Drive. They include likes/dislikes, playlists and names, followed artists and release metadata, listening sessions and recents, typed Search selections and retained legacy queries, generated mixes, saved recording metadata and artwork URLs, manual language corrections, lyric timing, and all saved preferences. Preferences include Home layout, app icon, appearance, legacy discovery choices, independent recommendation adjustments for each language, playback controls, cache-size choice, DNS and remote-fallback choices.

The app also stores merge revisions, writer/installation identifiers, deletion markers, history/search reset generations and separate compaction boundaries for legacy queries and typed selections. These let devices combine offline changes and avoid restoring removed items from older copies. Your current queue/position, pending device notification deliveries, tip transaction ledger, YouTube credentials, audio files, artwork image files and derived language-cache file are excluded. Language shares and cache-retention scores are calculated locally from saved evidence, not synced as additional aggregate counters. Apple handles account authentication and cloud storage; Breezy does not receive your Apple Account password.

A device-local configuration stores the opaque iCloud account binding, installation replica identifier, sync enablement and last-success time. This configuration is excluded from backups, so a restored installation without it starts with sync enabled and a fresh identity. On an installation with an existing account binding, a different Apple Account disables sync until you explicitly enable it for that account. Turning sync off, signing out or deleting the app keeps existing iCloud files; offline changes are merged if sync resumes.

Item removals and history/search clears propagate to other devices when they sync. Unresolved historical iCloud file versions are retained, so clearing data in Breezy does not physically purge those versions or existing device backups. Manage Apple's retained copies through the applicable iCloud and backup controls. The developer does not operate a library-storage server or receive the synced library.

## Home Screen widgets

Breezy publishes a bounded copy of saved song titles, artist names, recording identifiers, liked-song counts and generated-mix previews to a shared container on this device. It includes small artwork images already cached by the app. This derived copy is separate from the saved library, excluded from iCloud sync and excluded from backups on successful writes.

The widget extension reads this copy without contacting music, artwork or account services. It receives no audio, signed media URLs, account credentials or tip records. Tapping a widget opens Breezy, whose ordinary playback and provider behavior still applies. Personal widget content is marked sensitive for the system's privacy presentation.

Turning listening history off hides recent songs on the widget; clearing history removes its recents and generated mixes. The app replaces the shared projection and requests a widget refresh after a durable change. iOS controls when the displayed widget updates, so an earlier rendering may remain visible until the refresh occurs.

## Apple Watch and CarPlay

When the Watch companion is installed, Apple's WatchConnectivity framework exchanges data with the paired iPhone. Playback snapshots include the recording ID, title, artist, position, duration, transport state, favorite/shuffle/repeat settings, and fixed error messages. Requested library pages include playlist names and song counts, and bounded rows from Favorites, Recently played, Playlists, and Queue. Watch actions send control choices and item identifiers back to the iPhone.

These Watch payloads contain no audio, signed media URLs, account cookies, or artwork/media assets. The Watch has no catalog, sign-in, or audio-streaming client. The iPhone owns playback and saves library changes. WatchConnectivity can retain the latest background snapshot for later delivery; browsed pages stay in Watch app memory rather than a second saved library. Disconnected or unconfirmed data can remain visible as **Last seen on iPhone** until refreshed.

CarPlay displays library rows and the phone's existing system Now Playing metadata through native templates. Its controls use the same iPhone player and audio route. CarPlay list artwork uses system symbols without additional image downloads. Watch and CarPlay controls can cause the phone's ordinary playback/provider requests, with the same optional account behavior described below. They add no external music provider or Breezy server.

## Optional YouTube sign-in

Signing in is optional. The sign-in sheet loads Google's page at `accounts.google.com` and related Google/YouTube resources. Google receives the information you enter on that page and the associated browser/session data.

After sign-in, Breezy retains only cookies scoped to YouTube domains, together with their scope/expiry information and sign-in time. These cookies are authentication credentials. They are stored separately from the library in the device Keychain using an after-first-unlock, device-only protection setting. Breezy does not save a separate account-name field, email field, or password. The sign-in web view uses a non-persistent data store.

The saved session is added only to YouTubeKit's TVHTML5 playback lookup, using cookies and a request signature. It is not added to catalog, chart, artwork, YouTube Data API, LRCLIB, MusicBrainz, or linked-lyrics requests. Google can associate a signed-in playback lookup with your account. Breezy does not deliberately send YouTube watch-history updates, but this does not prevent Google from retaining or using request data under its own policies.

Use **Settings > Account & connection > Sign out** to remove the saved session. Breezy clears its in-process session and saves a small, credential-free sign-out marker in the app's local data before deleting the Keychain entry. A successfully saved marker prevents that session from being restored after relaunch if deletion fails. An unreadable sign-out status also blocks restoration.

**Sign-out pending** means another step is needed, not that credentials have necessarily been deleted. **Retry sign-out** retries deletion and marker cleanup. If the app says sign-out could not be saved, retry before closing: without a saved marker, the old session may return on relaunch. Device-only Keychain credentials do not migrate to another device, and Keychain items may survive app deletion.

## Optional remote playback fallback

**Remote playback fallback is off by default.** If you enable it in Settings and local extraction fails, YouTubeKit contacts `remote-production.youtubekit.dev` with the recording ID and, when available, an app-identity header derived from the signed app.

That service can ask the phone to make additional extraction requests to service-selected URLs. It receives the resulting response URLs, status codes, headers, and bodies, including intermediate responses when requested. Extraction transport disables automatic cookie and credential storage, but service-directed or returned headers may still contain cookies. Breezy's account bridge does not add your saved YouTube session to this remote path. Response-size limits and cancellation do not determine the remote service's retention or data use, which have not been independently established.

## Encrypted DNS

**Encrypted DNS is enabled by default** and can be changed in Settings. It keeps the app's hostname lookups for music sites private from the local network, such as public Wi-Fi. Breezy prefers the system's encrypted DNS or Private Relay and configures Cloudflare's `cloudflare-dns.com/dns-query` as a fallback. The selected resolver receives hostname queries and connection metadata.

This setting applies to new app connections that use the system networking context. It does not change device-wide DNS and does not hide music requests from their providers.

## Purchases

Tips are optional, one-time consumable purchases through Apple and unlock no features or music. Apple handles payment details; Breezy does not receive your payment-card number.

The app verifies StoreKit transactions and keeps a local transaction-ID record, including credit or revocation state, before acknowledging them. The record supports duplicate prevention and the tip count shown on this device. It is part of the saved library and may be included in device backups. It is not a subscription or a cross-device entitlement. Billing and refund requests are handled by Apple at [reportaproblem.apple.com](https://reportaproblem.apple.com/).

## Notifications and diagnostics

New-release alerts use local iOS notifications after permission is granted. The app checks followed artists when opened and when iOS schedules background refresh. Pending alert identifiers are saved with release data so eligible alerts can retry after relaunch or a failed delivery, including before the next catalog check is due. Stable notification identifiers help avoid duplicates. Pending records are limited to retained releases; delivery is not guaranteed.

Turning off **New release alerts** or unfollowing an artist removes the corresponding pending records when the change saves. This does not withdraw notifications already submitted to iOS. Alert content can include artist and release names on the Lock Screen, subject to your notification settings. There is no Breezy push-notification server.

Breezy writes diagnostic messages through Apple's local logging system. These can include operation outcomes, timings, provider identifiers, and error details. The app has no custom remote analytics or crash-reporting endpoint. Apple may process diagnostics according to your device's analytics and sharing settings.

Song-language logs contain fixed outcome counters and timings, without lyric text, song titles, artist names, or entity IDs. Development tests can inspect bounded numerical language evidence without lyric text; that test-only inspection is excluded from release builds.

Listening-discovery, typed Search-selection, connectivity and cache records use fixed categories, numeric counts/status values and bounded outcomes. They do not add song, user, query or request-ID dimensions. Cache read failure is distinct from an empty cache, and a derived-cache write failure is distinct from saved evidence.

Album-description logs contain local outcome counters and timings, without prose, album IDs, artist names, or URLs. CarPlay logs local template and navigation failures. These features add no remote analytics endpoint.

## Retention, deletion, and backups

- Listening history saving defaults on. Successfully turning off **Save listening history** stops new listening events, recent-song records and automatic listening-derived language checks, and discards pending listening. Existing history and explicit adjustments remain. It does not disable requests caused by browsing/playback, typed Search-history saving or queue-position saving.
- **Clear listening history** removes saved listening sessions, recent songs and generated mixes, resets derived language evidence and schedules deletion of its local cache. Cleanup has its own result if storage cannot complete it. Explicit language adjustments and recording corrections stay saved. Detailed history and recents otherwise have a 400-day retention window, applied when the library loads or saves. A current streak can retain one real session per older streak day; clearing history removes those too.
- **Search > Recently opened** offers individual removal and **Clear all**. A successful search-history clear also removes retained legacy terms and advances the shared reset generation. Clearing listening history does not clear either search-history field.
- **Settings > Library & iCloud > Storage** shows actual usage and offers cache clearing. Its audio-byte total includes every committed encoding and active preparation files; the song count counts distinct recordings. All encodings of audio currently in use may be retained, and caches can refill during use. iOS can purge caches independently.
- Cached songs offers per-recording removal across its audio variants. Complete audio has no time-based expiry; byte/song capacity and a local score derived from durable listening guide eviction. No additional listening history is recorded while history saving is off. Cache-access times remain a fallback ordering signal. Artwork, lyrics and audio have separate availability.
- Likes, playlists, follows, preferences, corrections, and tip records persist until removed through their available controls or the local app data is deleted. Cache/history clearing does not erase the tip ledger.
- Normal iOS backups may include the library and its sync journal, preferences, history/reset generations, typed Search selections and retained legacy terms, corrections, pending alert identifiers, tip identifiers, and the credential-free sign-out marker. Depending on your backup settings, those copies may be stored in iCloud or on a computer. Device-only Keychain credentials and the excluded device-sync configuration do not migrate with them. iCloud library sync is separate from these backups. The paired Watch receives the limited display data described above. Temporary audio/artwork and derived language caches use purgeable Caches storage.
- Deleting the app removes its local app-container data. It does not delete existing backups, Apple purchase records, provider-held records, or necessarily Keychain items. Sign out before app deletion if you want to remove the saved YouTube session, and manage backups through iOS or your backup software.

## YouTube API Services

Breezy uses YouTube API Services (the YouTube Data API) to read a recording's default audio language and, when missing, its duration. By using Breezy you agree to be bound by the [YouTube Terms of Service](https://www.youtube.com/t/terms); Google's handling of the data it receives is described in the [Google Privacy Policy](https://policies.google.com/privacy). These requests carry Breezy's app credential and bundle identifier, not your Google account: Breezy requests no Google account authorization for the API, so there is no authorized access to revoke in your Google account settings. Google receives the recording IDs it looks up, along with the connection details described above. The returned metadata is kept in a bounded memory cache for up to 12 hours (missing recordings for 15 minutes), which ends with the app process, and its language result can enter the expiring local language cache described earlier, which **Clear listening history** or deleting the app removes. It is not shared with other services. Breezy adds no advertising to YouTube content and stores no YouTube API data about you beyond that cache.

## Support messages and third-party policies

If you email support, the developer and the email services involved receive your email address, message, and any attachments you choose to send. Those messages are used to respond to the request and investigate the reported issue. To ask about or request deletion of support correspondence, email the contact above. Do not include passwords, sign-in cookies, verification codes, or payment-card details.

Music providers, sign-in services, DNS resolvers, and Apple apply their own data-handling policies. Their retention, account association, and tracking practices are not determined by Breezy's local-storage design. Relevant policies include the [Google Privacy Policy](https://policies.google.com/privacy), [Apple Privacy Policy](https://www.apple.com/legal/privacy/), and [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/). The [YouTube Terms of Service](https://www.youtube.com/static?template=terms) describe the provider's service terms.

Questions about this policy or a provider request can be sent to [Breezy Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md). This page will be updated when the app's data handling changes.

Copyright © 2026 Abhishek.
