# Breezy App Privacy assessment

**Draft assessment, not an App Store Connect declaration.** Final answers depend on the licensed provider/content approach and confirmed third-party data use. [PRIVACY.md](../../PRIVACY.md) is published at the [public policy URL](https://gist.github.com/aagrawal207/95acc71ba167fb754c435de17d256e59#file-privacy-md), updated and readback-verified on 21 September 2026. [PROVIDERS.md](../PROVIDERS.md#network-requests) owns the domain/payload inventory.

## Definition and current manifest

Apple defines collection as transmitting data off the device so the developer or third-party partners can access it for longer than needed to service the request in real time. On-device processing alone is not collection under that definition, but derived data sent to a provider must be considered separately. Apple also requires assessment of data collected through a purpose-specific web view. See [App privacy details](https://developer.apple.com/app-store/app-privacy-details/), checked 20 September 2026.

The current `Resources/PrivacyInfo.xcprivacy` contains:

- `NSPrivacyTracking = false` and an empty tracking-domain array.
- An empty `NSPrivacyCollectedDataTypes` array.
- Required-reason entries for system boot time (`35F9.1`) and file timestamps (`C617.1`).

That manifest is not proof that providers do not collect data. It must not be copied into a “Data Not Collected” store answer without assessment. `tools/audit-release.py` checks for the bundled manifest and its required-reason API key; it does not determine correct store answers or certify every API-use declaration.

## Data-flow assessment

The possible label categories below are candidates for review, not selected answers. App functionality is an observed request purpose; provider analytics, marketing, retention, and tracking use remain unverified unless separately established.

| Data | Observed behavior | App Privacy question to resolve |
| --- | --- | --- |
| Library, playlists, preferences, and corrections | Saved in a versioned atomic library; no complete-library upload. Normal device backups may include it. Explicit disk reload validates recovered state and preserves newer playback intent | Keep local data distinct from provider-derived requests and Apple backup services |
| Listening recovery and history reset | Failed listening saves remain in a bounded process-memory buffer. Successful history clearing/disabling changes a saved privacy epoch and retires pending time. That epoch can enter backups | Distinguish memory-only unsaved time from persistent history/reset state; neither adds a remote recipient |
| Release-alert delivery | Up to 60 pending alert IDs are saved with retained releases, can enter backups, and retry through local iOS notifications. Disable/unfollow retires relevant pending state when saved | Distinguish local notification bookkeeping and Lock Screen content from the followed-artist requests already sent to the catalog provider |
| Search text and radio preferences | Debounced searches, genre/mood queries, and optional artist hints go to YouTube Music. Only deliberate music-search commits enter local recent history | Assess **Search History**, retention, linkage, and purposes for the final provider |
| Listening interests / recording requests | Playback IDs, prefetch choices, radio seeds, followed artists, artwork, and lyric requests leave the device. Explicit quality reload requests a fresh source for the current play through existing providers | Assess **Product Interaction** or other applicable usage data; on-device ranking does not make these requests local-only |
| Google sign-in | Purpose-specific web view loads Google login resources. YouTube cookies are retained in device-only Keychain and sent with TVHTML5 lookups | Assess account **Identifiers**, web-flow data, account linkage, retention, and any tracking. No separate account-name/email/password field is saved by Breezy |
| Sign-out recovery | A credential-free marker in Application Support blocks session restoration after a saved sign-out intent; it can enter normal backups. Write/deletion/cleanup failures surface as pending sign-out | The marker contains no credentials. A pending state does not establish deletion; failure to save the initial intent can permit restoration after relaunch |
| IP addresses and provider visitor data | Network recipients see source addresses; some requests carry provider visitor/continuation values | Classify based on actual use. `gl: IN` is static catalog context, not evidence of collecting precise location. Do not assume account-cookie-free means unlinked |
| LRCLIB / linked lyrics | Recording metadata or IDs sent for lookup, including automatic artist-language checks | Establish retention and purposes. LyricFind/Musixmatch are attribution sources through YouTube, not direct Breezy request recipients |
| MusicBrainz | `MusicBrainzContactURL` is configured to the published Support anchor. Eligible language lookups send title, artists, duration range, matched ID, and that developer contact URL | Include configured shipping behavior and confirm applicable provider retention; do not treat a bounded local cache as a server-retention limit |
| Remote extraction | Opt-in, default off; recording/app identity and service-directed response bodies/headers are sent to YouTubeKit's remote service. Transport disables automatic cookie/credential storage and bounds reception, but supplied/returned headers may contain cookies | Assess the full exchange and service-selected destinations. Local byte/time limits do not establish server retention; optional functionality is not automatically exempt from disclosure |
| DNS | System resolver or Cloudflare fallback receives hostname queries | Confirm resolver data practices; encrypted DNS does not make provider requests anonymous |
| Tips | Apple processes purchases; a verified transaction-ID credit/revocation ledger is stored locally and can enter backups | Assess **Purchase History** only for data collected by the app/developer/partners as defined by Apple. Apple-only payment collection is distinct; do not declare payment-card access the app does not have |
| Diagnostics | OSLog on device, including outcomes, timing, provider identifiers, and error text; no custom remote telemetry endpoint | Confirm any diagnostic reports the developer actually receives from Apple or support before finalizing **Diagnostics** answers |
| Support correspondence | Voluntary email sends address, message, and attachments to the support mailbox and email providers | Confirm support retention/use and whether every optional-disclosure condition applies; do not presume all support data is exempt |
| Public support/privacy pages | Settings opens the published `gist.github.com` anchors; the host receives ordinary browser request data | Distinguish user-opened web pages from background provider requests and account-cookie handling |
| Opus preparation and cache variants | FFmpegBridge performs local packet copy with no network or decoder; AVFoundation validates native PCM. Multiple encodings and active preparation files stay in purgeable cache storage | The original media download is an existing provider request; local remuxing does not add a recipient or upload the cache |

## Public-policy details retained

- Distinguish local saved state from device backups and direct provider requests.
- Explain automatic search/prefetch/language lookups, not only explicit Play and Lyrics taps.
- Describe optional account credentials, the credential-free sign-out marker and its failure states, and the remote extractor's broader response exchange.
- State the scope of history clearing and pending-time retirement, separate recent-search controls, retained in-use cache files, and the persistent tip ledger.
- Include pending notification IDs and privacy-reset state in the saved-data/backup inventory. Local alert retries do not guarantee delivery or withdraw already submitted system notifications.
- Avoid a blanket “no tracking” claim about third parties. Source inspection establishes no custom Breezy analytics endpoint, not the providers' purposes or retention.

## Integration and pending facts

Support/Privacy updates, including recovery, history-epoch, sign-out, and FFmpeg sections, are published and readback-verified. Settings copy is [aligned](PUBLIC_PAGES.md#in-app-copy-alignment) on backups, optional account/provider logging, remote response exchange, and cache/preparation bytes. Store fields remain unwritten because the App Store Connect app has not been created. Local archive/export generation and completed source reviews do not establish final App Privacy answers or native account acceptance.

Source-quality metadata and preparation versions are stored in sidecars without signed URLs. A quality reload can publish a higher-quality immutable Opus variant alongside an existing encoding, and later playback can reuse it. Privacy copy must account for the extra local bytes and fresh provider request. The exact corresponding-source/relink delivery for the LGPL component is a separate [distribution dependency](../FFMPEG_DISTRIBUTION.md).

Final store answers still need the provider/content decision and verified retention, linkage, and tracking practices. Support-message handling and any developer-received diagnostics also need confirmation. The questionnaire, age rating, and manifest must describe the final binary, including optional paths. The current empty collected-data array does not close the release hold.
