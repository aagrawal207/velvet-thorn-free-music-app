# Breezy Privacy Policy

Last updated: 21 September 2026

This policy covers **Breezy - Stream Music & Chill**, developed by Abhishek. For privacy questions, contact **[aagrawal207@gmail.com](mailto:aagrawal207@gmail.com?subject=Breezy%20Privacy)**.

Breezy stores your library on your iPhone and contacts external services directly for music, artwork, lyrics, and purchases. It has no Breezy account service or app-operated analytics server. This does not mean that all data stays on your phone: provider requests leave the device, and device backups may include saved app data.

## Data saved on your iPhone

Breezy's saved library includes:

- Liked and disliked songs, playlists and their names, followed artists, release updates, and identifiers for up to 60 pending release alerts.
- Listening sessions and recent songs, with recording details, dates, and time listened. A history-reset identifier prevents pending listening from restoring history that you cleared or stopped saving.
- The queue, playback position, generated mixes, and preferences such as Home layout, accent, discovery languages, and cache size.
- Up to 20 recent search terms that you deliberately commit, for example by submitting a search or choosing a result.
- Lyrics timing adjustments and manual song-language corrections.
- Verified tip transaction identifiers and whether each transaction is credited or revoked, to avoid counting the same purchase twice.

The library uses versioned atomic saves. If a saved file cannot be read safely, Breezy preserves it and shows an error rather than replacing it with an empty library. **Reload saved library** checks the saved file again and applies recovered preferences while keeping current playback. An untouched startup state can restore a recovered queue paused. Failed reloads preserve the last safely loaded library.

Listening time that cannot be saved remains in a bounded memory buffer during the current app session. Playback pauses if that buffer fills. This unsaved time can be lost when the app closes; it is discarded when a successful history-clear or history-disable change requires it. The buffer is not a second persistent history file.

Audio and artwork use separate temporary caches. The audio cache can hold several immutable encodings of the same recording, with metadata such as codec, bitrate, duration, byte count, preparation version, and storage time. It does not save signed streaming URLs. Lyrics text, temporary catalog responses, language lookup results, and resolved stream links use in-memory caches. Saved song metadata in your library remains persistent.

For eligible Opus recordings on supported iOS versions, Breezy downloads a complete WebM file and uses the bundled FFmpegBridge to copy its encoded audio into an MP4 container locally. Apple's media framework checks native decoded audio before the prepared file becomes playable. FFmpegBridge has no network or audio-decoder functionality and does not send audio to an additional service. Preparation uses temporary files and memory; the source preparation file is removed when the operation finishes or fails. A validated output can remain in the purgeable audio cache alongside an existing encoding.

## Requests to external services

Every network service can receive the connection's source IP address, request time, and normal connection/request headers. The address seen may depend on your network, VPN, or relay. The following requests are part of the current app:

| Service and domains | Data sent and purpose |
| --- | --- |
| YouTube Music and YouTube Charts: `music.youtube.com`, `charts.youtube.com` | Search text and filters; genre/mood queries and optional artist hints; artist, album, playlist, recording, or radio-seed IDs; chart region; client language/version context; and provider continuation or visitor data. Used for search, discovery, artist pages, charts, and radio. Saved YouTube account cookies are not added to these requests |
| YouTube playback: `youtube.com`, `www.youtube.com`, `*.googlevideo.com` | Recording IDs, player/client context, provider visitor data, and signed media requests. Used to resolve, validate, stream, and cache audio. A specific playback lookup can also include your saved YouTube session if you choose to sign in |
| Artwork hosts | Requests to image URLs supplied by the provider, commonly under `*.ytimg.com`, `*.googleusercontent.com`, and `*.ggpht.com`. The URL identifies the image and may identify its recording. Other provider-returned image hosts may also be used |
| LRCLIB: `lrclib.net` | Song title, artist, optional album, and recording duration when available, plus app-client headers. Used to match lyrics through `/api/get` and `/api/search` |
| YouTube Music lyrics: `music.youtube.com` | The selected recording ID and its linked lyrics-page ID. Used when LRCLIB does not provide usable lyrics or a lookup fails. LyricFind and Musixmatch credits, when present, arrive through YouTube Music; Breezy does not request their services directly |
| MusicBrainz: `musicbrainz.org`, when language metadata lookup is enabled | Cleaned song title, artist names, a duration range, and a matched recording ID. Used to look up recording/work language metadata through the official `/ws/2/` API. The client header contains app identification and a developer contact URL |
| Apple StoreKit services | App and product identification and purchase/transaction requests. Apple processes storefront information, Apple Account authentication, and payment details through its services |
| Public Support and Privacy pages: `gist.github.com` | When you open these links, GitHub receives ordinary browser request data for the page. These user-opened pages are separate from background music requests |

Search results update while you type, so partial search text can be sent before you submit it. Keeping only deliberate searches in local history does not prevent these requests.

Home and search can prefetch suggested audio before you press Play. Playback also prepares upcoming songs. These requests and complete-file downloads can use your network connection, including cellular data when iOS permits it. Opening an artist's song-language view can trigger lyrics and enabled MusicBrainz requests even if you do not open the lyrics sheet.

**Reload best available audio** requests fresh source selection and may download a new encoding. The resulting prepared cache variant can be reused on later plays; it does not upload your cached library. Radio setup drafts and artist hints are not saved as preferences, but the queries and recording requests they generate are sent to the catalog provider.

Personal mix ranking and recap calculations run on the phone. Provider requests for candidate songs, followed artists, and radio seeds can still reveal music interests derived from your library. The complete local library is not uploaded to a Breezy server.

## Optional YouTube sign-in

Signing in is optional. The sign-in sheet loads Google's page at `accounts.google.com` and related Google/YouTube resources. Google receives the information you enter on that page and the associated browser/session data.

After sign-in, Breezy retains only cookies scoped to YouTube domains, together with their scope/expiry information and sign-in time. These cookies are authentication credentials. They are stored separately from the library in the iPhone Keychain using an after-first-unlock, device-only protection setting. Breezy does not save a separate account-name field, email field, or password. The sign-in web view uses a non-persistent data store.

The saved session is added only to YouTubeKit's TVHTML5 playback lookup, using cookies and a request signature. It is not added to catalog, chart, artwork, LRCLIB, MusicBrainz, or linked-lyrics requests. Google can associate a signed-in playback lookup with your account. Breezy does not deliberately send YouTube watch-history updates, but this does not prevent Google from retaining or using request data under its own policies.

Use **Settings > YouTube account > Sign out** to remove the saved session. Breezy clears its in-process session and saves a small, credential-free sign-out marker in the app's local data before deleting the Keychain entry. A successfully saved marker prevents that session from being restored after relaunch if deletion fails. An unreadable sign-out status also blocks restoration.

**Sign-out pending** means another step is needed, not that credentials have necessarily been deleted. **Retry sign-out** retries deletion and marker cleanup. If the app says sign-out could not be saved, retry before closing: without a saved marker, the old session may return on relaunch. Device-only Keychain credentials do not migrate to another device, and Keychain items may survive app deletion.

## Optional remote playback fallback

**Remote playback fallback is off by default.** If you enable it in Settings and local extraction fails, YouTubeKit contacts `remote-production.youtubekit.dev` with the recording ID and, when available, an app-identity header derived from the signed app.

That service can ask the phone to make additional extraction requests to service-selected URLs. It receives the resulting response URLs, status codes, headers, and bodies, including intermediate responses when requested. Extraction transport disables automatic cookie and credential storage, but service-directed or returned headers may still contain cookies. Breezy's account bridge does not add your saved YouTube session to this remote path. Response-size limits and cancellation do not determine the remote service's retention or data use, which have not been independently established.

## Encrypted DNS

**Encrypted DNS is enabled by default** and can be changed in Settings. Breezy prefers the system's encrypted DNS or Private Relay and configures Cloudflare's `cloudflare-dns.com/dns-query` as a fallback. The selected resolver receives hostname queries and connection metadata.

This setting applies to new app connections that use the system networking context. It does not change device-wide DNS and does not hide music requests from their providers.

## Purchases

Tips are optional, one-time consumable purchases through Apple and unlock no features or music. Apple handles payment details; Breezy does not receive your payment-card number.

The app verifies StoreKit transactions and keeps a local transaction-ID record, including credit or revocation state, before acknowledging them. The record supports duplicate prevention and the tip count shown on this iPhone. It is part of the saved library and may be included in device backups. It is not a subscription or a cross-device entitlement. Billing and refund requests are handled by Apple at [reportaproblem.apple.com](https://reportaproblem.apple.com/).

## Notifications and diagnostics

New-release alerts use local iOS notifications after permission is granted. The app checks followed artists when opened and when iOS schedules background refresh. Pending alert identifiers are saved with release data so eligible alerts can retry after relaunch or a failed delivery, including before the next catalog check is due. Stable notification identifiers help avoid duplicates. Pending records are limited to retained releases; delivery is not guaranteed.

Turning off **New release alerts** or unfollowing an artist removes the corresponding pending records when the change saves. This does not withdraw notifications already submitted to iOS. Alert content can include artist and release names on the Lock Screen, subject to your notification settings. There is no Breezy push-notification server.

Breezy writes diagnostic messages through Apple's local logging system. These can include operation outcomes, timings, provider identifiers, and error details. The app has no custom remote analytics or crash-reporting endpoint. Apple may process diagnostics according to your device's analytics and sharing settings.

## Retention, deletion, and backups

- Listening history saving defaults on. Successfully turning off **Save listening history** stops new listening events and recent-song records and discards pending listening. It does not erase existing saved records, stop provider requests, or disable queue-position saving.
- **Clear listening history** removes saved listening sessions, recent songs, and generated mixes. Detailed history and recents otherwise have a 400-day retention window, applied when the library loads or saves. A current streak can retain one real session per older streak day; clearing history removes those too.
- Recent search terms have separate individual removal and clear controls. Clearing listening history does not clear recent searches.
- **Settings > Storage** shows actual usage and offers cache clearing. Its audio-byte total includes every committed encoding and active preparation files; the song count counts distinct recordings. All encodings of audio currently in use may be retained, and caches can refill during use. iOS can purge caches independently.
- Likes, playlists, follows, preferences, corrections, and tip records persist until removed through their available controls or the local app data is deleted. Cache/history clearing does not erase the tip ledger.
- Normal iOS backups may include the library, preferences, history and its reset identifier, search terms, corrections, pending alert identifiers, tip identifiers, and the credential-free sign-out marker. Depending on your backup settings, those copies may be stored in iCloud or on a computer. Device-only Keychain credentials do not migrate with them. Breezy has no app-provided cross-device library sync. Temporary audio/artwork caches use the app's purgeable Caches storage.
- Deleting the app removes its local app-container data. It does not delete existing backups, Apple purchase records, provider-held records, or necessarily Keychain items. Sign out before app deletion if you want to remove the saved YouTube session, and manage backups through iOS or your backup software.

## Support messages and third-party policies

If you email support, the developer and the email services involved receive your email address, message, and any attachments you choose to send. Those messages are used to respond to the request and investigate the reported issue. To ask about or request deletion of support correspondence, email the contact above. Do not include passwords, sign-in cookies, verification codes, or payment-card details.

Music providers, sign-in services, DNS resolvers, and Apple apply their own data-handling policies. Their retention, account association, and tracking practices are not determined by Breezy's local-storage design. Relevant policies include the [Google Privacy Policy](https://policies.google.com/privacy), [Apple Privacy Policy](https://www.apple.com/legal/privacy/), and [Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/). The [YouTube Terms of Service](https://www.youtube.com/static?template=terms) describe the provider's service terms.

Questions about this policy or a provider request can be sent to [Breezy Support](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-support-md). This page will be updated when the app's data handling changes.

Copyright © 2026 Abhishek.
