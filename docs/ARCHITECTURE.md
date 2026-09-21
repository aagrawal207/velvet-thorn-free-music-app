# Breezy implementation contracts

## Product and identity

Breezy is a native iPhone streaming player for iOS 18+, with Hindi/English-targeted discovery, unrestricted search, radio, lyrics, and a local library. The provisional name is `Breezy - Stream Music & Chill`; the Home Screen displays `Breezy`. Project/module/scheme `GanaBajana`, bundle ID `com.agraabhi.ganabajana`, URL scheme `ganabajana`, and `Application Support/GanaBajana` are stable identities. Candidate 1.0.0 (2) has a signed local Release archive and development IPA. [Release status](app-store/RELEASE_STATUS.md) records source-review closure, multi-run test coverage, and remaining acceptance.

The current provider integration is unofficial. [Release status](app-store/RELEASE_STATUS.md) records the content-rights hold; these contracts describe implemented behavior, not an approved distribution model. The active verification target is iPhone 17 Pro.

## Runtime ownership

| Files | Responsibility |
| --- | --- |
| `Sources/Core/` | Shared recording, artist, playlist, lyrics, preferences, cache-limit, and radio value types; provider protocols |
| `Sources/App/MusicAppModel.swift` | Main-actor UI coordination, navigation, search, preferences, personalization, and radio generations |
| `Sources/Catalog/` | Account-cookie-free catalog/chart transport, parsing, artist song expansion, and language evidence |
| `Sources/Networking/BoundedURLSession.swift` | Incremental response reception, body-size enforcement, and request-local cancellation |
| `Sources/Playback/` | AVPlayer state, stream resolution, complete-file cache, transitions, listening clock, and system controls |
| `Vendor/FFmpegBridge/` | Minimal dynamic LGPL framework for local Opus WebM-to-MP4 packet copy; source/build contract remains in the package README and provenance |
| `Sources/Library/` | Versioned atomic persistence, history retention, and personal listening summaries |
| `Sources/Lyrics/` | Recording matching, LRC timestamps, linked plain lyrics, attribution, and bounded lookup caches |
| `Sources/Recommendations/` | On-device taste ranking, period-stable mixes, experience radio, and followed-artist release checks |
| `Sources/Account/` | Optional YouTube session capture, device Keychain, and a lock-protected process-wide session registry |
| `Sources/Support/TipJarService.swift` | StoreKit product loading, purchase state, verified transaction handling, and recovery |
| `Sources/UI/`, `Sources/Views/` | Shared typography/artwork/theme, screen presentation, and user actions |

`MusicAppModel`, `PlayerController`, `LibraryStore`, and observable UI services are main-actor isolated. Network services are actors. `ReleaseWatcher` coordinates local state on the main actor and delegates network work to catalog providers.

## Shared models

- `Track.credits: [ArtistCredit]` holds provider-order artist names and optional IDs. `artists`/`artistID` are derived; legacy stored tracks decode into credits. `Track.allCredits` adds artists named in title feature clauses. `CatalogPage.credits` carries album-header credits.
- `ArtistPage.monthlyAudience` retains the provider metric, numeric value, and raw display text. A listener count is not a monthly play count. Recording counts stay attached to recording IDs.
- `HomeLayoutPreferences` stores section order and hidden identifiers, preserving unknown identifiers across decoding. `UserPreferences` includes `homeLayout`, `accent`, and `audioCacheLimit` alongside playback, discovery, DNS, and history choices.
- `RadioConfiguration` is an unsaved era/language draft with zero to four optional `ArtistCredit` hints, initially empty. `experience()` carries those hints into `RadioExperience`, whose language-aware variants hold style queries and recording cues. Persisted queue state does not preserve a complete active radio session.
- `ArtistSongLanguageResult` distinguishes identified, likely, and unclassified results with provenance. Only identified results participate in language-specific filters; weak suggestions remain unclassified for filtering. Library overrides take priority over automatic evidence.
- `LyricsDocument` distinguishes synced, plain, instrumental, and unavailable content. A thrown lookup error is not an unavailable document. `LyricsRequestKey` includes recording ID and metadata so dubbed recordings cannot share a lyrics result accidentally.
- `SourceAudioQuality: Codable, Equatable, Sendable` holds AAC-family or Opus codec metadata with optional bitrate, sample rate, and channels. `preferredBitRate(average:advertised:)` uses valid average bitrate first; `prefers(_:over:)` orders encodings by that value and prefers AAC on ties. This is a selection rule, not perceptual equivalence between codecs. `ResolvedStream.quality` and cache sidecars carry metadata without signed URLs; missing optional quality leaves legacy AAC entries usable.

## Provider APIs

The protocols in [`ProviderProtocols.swift`](../Sources/Core/ProviderProtocols.swift) are the integration boundary:

| Protocol | Contract |
| --- | --- |
| `MusicCatalogProviding` | `search(query:filter:continuation:)`, `browse(id:)`, `artist(id:)`, `recommendations(seed:language:)`, `radio(seed:)`, `radio(seed:forceRefresh:)`, and `discovery(languages:)`, all async/throwing |
| `MusicChartsProviding` | `weeklyChart(language:) async throws -> ChartSnapshot` |
| `LyricsProviding` | `lyrics(for:) async throws -> LyricsDocument` |
| `StreamResolving` | `resolve(track:forceRefresh:) async throws -> ResolvedStream`; `prefetch(_:) async` defaults to a no-op |

Concrete providers:

- `YouTubeMusicService: MusicCatalogProviding, LyricsProviding` has defaulted `session` and `now` injection. Its lyrics method follows the selected recording's Lyrics-tab browse ID and returns plain text. `audioMetadata(for:)` batch-validates album-audio metadata.
- `YouTubeChartsService: MusicChartsProviding` selects weekly `TRACKS` entries with album-audio counterparts. Original ranks, dates, and region remain in the result.
- `LRCLyricsService: LyricsProviding` performs recording matching. `CompositeLyricsProvider(primary:fallback:configuration:now:)` tries LRCLIB first, then the catalog's `LyricsProviding` conformance for missing/error results. Instrumental and usable primary lyrics stop the fallback. Its cache and concurrent requests are bounded.
- `ArtistSpotlightLanguageService.classification(for:)` combines recording metadata, lyrics inference, and an optional metadata lookup. `ArtistSpotlightMusicBrainz.shared` requires a valid HTTPS `MusicBrainzContactURL`, configured in `project.yml` to the published Support Gist anchor. Its `language(for:)` uses the official MusicBrainz metadata API with a shared rate limiter.
- `YouTubeStreamResolver: StreamCacheManaging` has `init(allowRemoteFallback: Bool = false)` and an injected initializer with `qualityExtract`, `opusEnabled`, and `opusTimeout`. Ordinary resolution chooses the best compatible cached variant, then a usable in-memory URL or provider extraction. `refreshQuality(track:) async throws -> ResolvedStream` requests fresh source selection while retaining cached fallback.

`StreamCaching` extends resolution with `download(_:)`, `discardCached(_:)`, variant-specific `discardCached(_:url:)`, `retainCached(_:)`, and `isCachedStream(_:)`. `StreamCacheManaging` adds usage, clearing, and cache-limit APIs. Other resolvers need not own a production cache; unsupported management must not be displayed as successful.

`URLSession.boundedData(for:maximumBytes:)` checks declared and incrementally received body size before returning data. Early exit and caller cancellation cancel that request's task; HTTP status and payload validation remain caller-owned. The vendored extraction transport applies its own request budgets and cancellation, and concurrent player lookups use structured task groups. [PROVIDERS.md](PROVIDERS.md#response-limits-and-cancellation) owns the exact limits.

## LibraryStore API and durability

`LibraryStore.init(directory:now:)` uses `Application Support/GanaBajana/library.json` by default and permits an isolated directory/clock. Readable state includes library collections/history/preferences, `playback`, `pendingReleaseNotifications`, `tipCount`, `storageBytes`, `errorMessage`, `requiresReload`, and `hasLoadedDocument`. A genuine new empty library is loaded state; an unreadable startup placeholder is not.

| Operation | API |
| --- | --- |
| Likes/dislikes | `isFavorite(_:)`, `toggleFavorite(_:)`, `isDisliked(_:)`, `toggleDislike(_:)` |
| Playlists | `createPlaylist(name:) -> UUID`, `renamePlaylist(id:name:)`, `deletePlaylist(id:)`, `add(_:to:)`, `remove(trackID:from:)`, `moveTracks(in:from:to:)` |
| History/resume | `recordListening(track:sessionID:startedAt:seconds:) -> Bool`, `recordRecent(track:position:)`, `updatePlayback(_:)`, `clearHistory()`, `summary(for:now:)` |
| Search history | `recordSearch(_:)`, `removeRecentSearch(_:)`, `clearRecentSearches()` |
| Follows/mixes | `isFollowing(artistID:)`, `follow(_:)`, `unfollow(artistID:)`, `recordReleaseCheck(artistID:knownReleaseIDs:newReleases:checkedAt:catalogReadSucceeded:) -> Bool`, `markReleasesSeen()`, `mix(_:)`, `saveMix(_:)` |
| Release delivery | `canDeliverReleaseNotification(_:) -> Bool`, `acknowledgeReleaseNotification(id:) -> Bool` |
| Disk recovery | `reloadFromDisk() -> LibraryReloadResult`; app-facing `MusicAppModel.reloadSavedLibrary()` |
| Recording corrections | `lyricsOffset(for:)`, `setLyricsOffset(_:for:)`, `setRecordingLanguageOverride(_:for:) -> Bool` |
| Tip ledger | `tipCredit(for: UInt64) -> Bool?`, `recordTip(transactionID:credited:) -> Bool` |

The writable `preferences` property commits mutations. Views use `MusicAppModel.updatePreferences(_:)` so dependent services receive only the preferences actually saved. Each commit validates a candidate document, checks the prior bytes on disk, writes atomically, and publishes state only after success. Unreadable/future stores block writes. A stale writer cannot replace an externally changed library.

Listening updates are delta seconds. A true acknowledgement means the delta was durably saved, or was a no-op for disabled history/zero time. `PlaybackListeningBuffer` retains unacknowledged deltas for up to 128 original session identities; delivery removes only acknowledged time. Capacity exhaustion pauses playback instead of dropping pending time. The buffer is memory-only and does not survive termination.

Clearing history or successfully disabling history changes the persisted privacy epoch and discards pending listening. Clearing also removes events, recents, and generated mixes, while preserving explicit library choices, queue, searches, and tips. `LibraryRecovery.crossesHistoryBoundary` also recognizes conservative legacy signals such as removed/reduced retained history, preventing an ordinary reload from resurrecting erased listening.

`reloadFromDisk()` validates and rechecks the bytes before adopting them, without itself writing a replacement. It returns `.reloaded`, `.historyBoundary`, or `.failed`; failure preserves the established document and blocks writes. `reloadSavedLibrary()` runs outside listening callbacks, retires stale personalization/radio work, reconciles playback/cache/DNS preferences, and then retries eligible buffered listening. A live queue takes precedence over a saved snapshot. Only an untouched failed-startup placeholder receives the recovered queue, restored paused. Lifecycle and restore-retirement callbacks cannot write that placeholder over repaired disk state. [PROVIDERS.md](PROVIDERS.md#local-data-and-backups) owns retention and backups.

## PlayerController API and lifecycle

`PlayerController.init(resolver: any StreamResolving = YouTubeStreamResolver())` is the single playback-state owner. Readable state includes current track/queue/index, position/duration, play/loading/error state, shuffle/repeat, sleep deadline, transition settings, normalization gain, resolved view count, `sourceAudioQuality`, `canReloadAudioQuality`, radio identity, and cache-management status.

- Selection and transport: `play(_:startingAt:isRadio:)`, `togglePlayback()`, `pause()`, `next()`, `previous()`, `seek(to:)`, `retry(preferBestAudio: Bool = false)`, `restore(_:)`.
- Queue: `toggleShuffle()`, `cycleRepeatMode()`, `enqueue(_:next:)`, `appendAutoplay(_:)`, `removeFromQueue(at:)`, `moveQueue(from:to:)`.
- Settings and maintenance: `apply(_:)`, `setSleepTimer(minutes:)`, `setRemoteFallbackEnabled(_:)`, `prefetch(_:)`, `flushListeningProgress()`.
- Storage: `audioCacheUsage() async throws -> AudioCache.Usage?`, `clearTemporaryAudioCache() async throws -> AudioCache.Usage?`, and `setAudioCacheLimit(_:) -> Task<AudioCache.Usage?, Error>`. The UI observes `isUpdatingAudioCacheLimit`, `audioCacheLimitError`, and `audioCacheLimitUsage`.
- Callbacks: `onListeningProgress(Track, UUID, Date, TimeInterval) -> Bool`, `onSnapshotChanged(PlaybackSnapshot)`, `onTrackStarted(Track)`, and async `onQueueExhausted(Track) -> [Track]`. `discardPendingListening()` retires buffered deltas at privacy boundaries.

Selection updates synchronously before cancellable resolution. Restore remains paused. Generation checks protect newer selections from late resolver, seek, radio, and transition callbacks. `PlaybackListeningClock` measures actual listening rather than seek distance. `PlaybackQueue` preserves the original queue through shuffle.

`PlaybackCachePipeline` coordinates full-song downloads and pins. `StandbyDeck` and `PlaybackCrossfade` in `PlaybackTransition.swift` prepare and blend adjacent playback. Cache clearing or limit changes stop old writers and re-read the live retained set before removing unused files. In-use files can temporarily exceed the policy; storage UI reports them rather than claiming a zero-byte clear.

### Opus preparation, cache variants, and reload

`OpusNativeAudio.isSupported` enables the Opus path only on **iOS 26.5+**. Older systems select AAC. The resolver ranks eligible source encodings before checking URL usability and keeps AAC candidates for fallback. A challenged best tier reaches full extraction rather than silently selecting a lower clear tier. Each Opus candidate requires a complete local download and prepared MP4; AVPlayer is never given the original WebM as this path's playable file.

`OpusRemuxer.remux(input:output:timeout:)` invokes the synchronous `gb_remux_opus` C bridge off the main actor. FFmpeg copies encoded Opus packets into MP4 without re-encoding, decoding, or network I/O. `OpusNativeAudio.inspect(_:)` requires one Opus audio track, no video, 48 kHz mono/stereo, a usable duration, and an actual nonempty PCM sample from AVAssetReader. This is per-file native validation, not a claim that every sample is decoded before playback.

| Operation | Default bound |
| --- | --- |
| Resolver Opus acquisition/preparation attempt | 12 seconds |
| App remux interrupt callback | 10 seconds; the underlying C bridge also has its independent 30-second ceiling |
| Explicit quality reload | Up to 60 seconds for resolution |
| Input/output preparation files | 64 MiB each; reserve 128 MiB of cache headroom before preparation |

Timeouts/cancellation retire the work and prevent publication; preparation owns its files until native work unwinds. A failed Opus attempt falls back to AAC and has a bounded per-recording cooldown. Explicit reload clears that recording's cooldown.

`AudioCache.storeOpus(trackID:stream:permit:foreground:)` writes a fresh immutable `<trackID>.opus-<UUID>.m4a` and atomic sidecar with `opusPreparationVersion: 1`. It preserves the existing encoding and protects every variant of an in-use logical song. Up to two prepared Opus variants are retained; unavailable space or a protected variant limit causes fallback rather than overwriting a live file. Rejection can target one variant through `rejectPlaybackFile(_:)`.

`entry(for:allowOpus:)` chooses the best compatible committed encoding for the logical ID. Consequently, a successful quality reload can add a higher-quality prepared variant that **later ordinary plays reuse**. The reload does not mutate the original file, set a persistent user bitrate preference, or reprocess the entire library.

`AudioCache.Usage.bytes` sums all committed encodings plus bytes present in active preparation files. `songCount` counts distinct logical recording IDs; preparation bytes do not create an extra song. Retained bytes include all committed variants of retained IDs. Sidecars and abandoned partial files are excluded from that media-byte total. Cache limits and privacy behavior are in [PROVIDERS.md](PROVIDERS.md#audio-cache-and-quality).

## Discovery, radio, and language evidence

`TasteProfile` derives preferences from local library data. `RecommendationEngine` ranks provider candidates locally and saves period-keyed mixes. A still-valid mix is stable within its period; save-time eligibility rechecks current dislikes and language evidence so a late result cannot reintroduce a removed song.

Ordinary autoplay calls `catalog.radio(seed:)`, then excludes disliked/queued songs and alternate versions using `SongTitle.core`. Home language mixes use `recommendations(seed:language:)`. Experience radio accepts zero artist hints and retains station intent through fallback discovery. Its bounded final startup retries and explicit manual continuation use `forceRefresh: true`; normal continuation may use cached responses. YouTube Music bypasses cached radio responses on force refresh and does not retain empty/unusable radios, while honoring provider cooldowns. [Provider documentation](PROVIDERS.md#radio-and-language-evidence) owns the budgets and targeting limits.

`ArtistSpotlightCatalogService` expands an artist's available recordings. `ArtistSpotlight.sorted(_:)` deduplicates by provider recording ID and sorts known counts descending, unknowns last, with deterministic title/ID ties. `ArtistSpotlightLoader` performs bounded language batches, exposes partial/failure states, and applies persisted corrections. Opening this screen can trigger lyrics and configured MusicBrainz requests even without opening the lyrics sheet.

### Durable release-alert delivery

`ReleaseWatcher` checks up to eight due artists with a six-hour catalog throttle. Successful catalog reads establish a baseline even when empty; failed reads do not invent one. `recordReleaseCheck` atomically saves release state and up to 60 pending notification IDs. Pending delivery runs even when no artist is due, so a failed notification can retry inside the catalog throttle window.

Turning alerts off or unfollowing retires the relevant pending IDs when saved. Delivery checks current durable eligibility, asynchronously looks up existing platform notification IDs, and deduplicates with the stable `ArtistRelease.notificationIdentifier`. After that lookup, the final eligibility check and `ReleaseNotificationSubmitting.submit(_:completion:)` initiation share one main-actor turn with no suspension between them. The callback runs exactly once and reports acceptance or failure. Accepted work attempts durable acknowledgement even if cancellation follows initiation; a failed acknowledgement leaves the pending record for a deduplicated retry. Already submitted system notifications are distinct from pending local intent.

## UI and account integration

Views receive `@Environment(MusicAppModel.self)`. `selectTab(_:)` handles Search reselection; `commitSearch()` saves an intentional query. Explicit `search()` cancels pending artist navigation even when input is unchanged, while lifecycle/debounce calls `loadSearch()` under the existing intent. `loadMoreSearch()` does not record history. `open(_:)`, `openArtist(_:)`, and `playQueueTrack(at:)` preserve the corresponding navigation/playback intent boundaries.

`AppNavigationIntent`, `AppNavigationLink`, and presentation bindings handle native activation, Back, keyboard, and accessibility actions rather than relying on touch gestures. They invalidate obsolete artist callbacks while allowing an older sheet dismissal to leave a newer Search focus request intact.

- `RootView` retains the native `TabView` and Liquid Glass tab navigation. `MiniPlayerNavigationLayout` uses a `VStack` outside each `NavigationStack`, reducing the stack's viewport by the mini-player's intrinsic height. Direct NavigationLink destinations and programmatic pushes therefore share the reserved space. The mini-player is hidden with the keyboard.
- The mini-player has a **64-point minimum height**, **44-point artwork**, and **52-point transport/open targets**. Text can increase its height under Dynamic Type. Full-screen Now Playing keeps its main controls fixed; More, Lyrics, and Queue are scrollable sheets, and system controls own volume.
- `RootMessageBanner` gives Retry and Dismiss genuine 44-point hit regions, including the label frame/content shape. The target size is independent of the surrounding banner's layout.
- `HomeCustomizationView` edits persisted section order/visibility. Recently played is first by default. The model excludes the two hitlist shelf IDs while retaining other discovery sections.
- `SearchView` debounces network queries. A first tab tap shows Search without forcing focus; reselection scrolls to `search.top` and focuses the existing query, including after keyboard layout changes. `RadioSetupView` starts from genre/mood defaults, with no artist hints preselected and at least one language required. Loading occupies one reserved indicator slot.
- `AppTypography` supplies compact Dynamic Type styles. Home track/album art uses 4-point corners, mix art 6, and compact Home containers 10. These are surface-specific values, not a blanket radius for every card.
- `AppTheme.onAccent` pairs opaque palette fills with a foreground meeting at least 4.5:1 contrast in light/dark appearance. Interactive rows expose labels, selection, and actions. `AppAccessibilityAnnouncements` queues confirmations after dismissal when VoiceOver is running without moving navigation focus. Native VoiceOver acceptance is still separate from source and automated checks.
- `ArtworkLoader` coalesces URL/pixel-size work per waiter. Cancelling one waiter returns it promptly without stopping other consumers; cancelling the last retires and cancels the transfer. A later waiter gets a new flight, and clearing waits for retired readers before clearing caches. Reception is bounded and a non-renewing resource deadline prevents trickle responses from keeping a flight alive indefinitely.
- `AppIcons.all` lists 14 unique visible icons. Leafnote (`id: Beat`, `isPrimary: true`) uses a nil alternate name and the primary `AppIcon.png`. Breeze (`Dhol`) uses `AppIcon-Dhol`. The project contains 15 app-icon sets because `AppIcon-Beat` remains a compatibility alias for existing installations; it is not a fifteenth picker choice. `AppIconController` resolves that alias to Leafnote. Generator recipes and project names must retain this mapping.
- **Settings > About Breezy** links **Help & feedback** and **Privacy policy** to the published Gist anchors in [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md). The same Support anchor supplies `MusicBrainzContactURL`.
- `YouTubeAccountStore` keeps credentials only in Keychain; the session registry feeds only TVHTML5 decoration. Sign-out first disables the in-process account, purges legacy YouTube cookies, and saves a credential-free `Application Support/GanaBajana/Account/pending-sign-out` marker before deletion. A saved marker blocks restoration after a failed deletion. Marker-write, deletion, or marker-clear failures remain pending/retry states, not success confirmations.

## Consumable tip transactions

`TipJarService(library:observeTransactions:)` loads the five allowlisted consumables, uses verified StoreKit results, and listens to `Transaction.updates` and `Transaction.unfinished`. The library stores transaction IDs with credited/revoked state before `finish()`. Duplicate deliveries do not increase the count; refund records prevent an old delivery from restoring credit. Unverified or unsaved transactions remain unfinished for recovery. Missing products and partial catalogs remain retryable.

`TipJarView` is reached through **Settings > Support development**. Names, descriptions, and prices come from StoreKit products. Tips are repeatable one-time purchases and grant nothing. [IAP_MANIFEST.json](app-store/IAP_MANIFEST.json) records the intended store configuration, not created products.

## Verification ownership

[VERIFICATION.md](VERIFICATION.md) records execution details; [REVIEW_FINDINGS.md](REVIEW_FINDINGS.md) records the five completed source reviews. [Release status](app-store/RELEASE_STATUS.md#verification-snapshot) distinguishes full-run failures, successful targeted follow-ups, exclusions, and remaining acceptance. Passing coverage across runs must not be presented as one green full suite.

`tools/verify.sh` separates unit, fixture UI, live provider, live UI, and local release modes. `SKIP_NATIVE_STOREKIT=1` opts out of native StoreKit unit/UI suites; the default is 0. Fixture UI always excludes live UI. Live provider mode includes `ExperienceRadioLiveTests` and `LyricsFallbackLiveTests` alongside catalog, stream, lyrics, and DNS checks.

UI geometry assertions allow only a `1e-6` floating-point epsilon around the 44-point minimum. Artist workflows wait for observable readiness; resume checks account for playback elapsed during automation. These assertion rules preserve the actual hit-target and playback contracts.

For headless rotation checks, `TEST_RUNNER_GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS=1` reaches the runner as `GANABAJANA_UI_SCENE_GEOMETRY_REQUESTS`. The runner launches the app with `--uitesting --ui-scene-geometry` and sends a DEBUG-only Darwin notification. `DebugBootstrap` calls the public `UIWindowScene.requestGeometryUpdate` API in the existing process, preserving state while layout and keyboard adapt. These controls are compiled out of Release. This verifies scene-layout transitions, not physical-device autorotation.

### Release archive audit

Release configuration excludes `TipJar.storekit` through `EXCLUDED_SOURCE_FILE_NAMES`; Debug retains its local StoreKit setup. `tools/audit-release.py` accepts an archive plus required `--version` and `--build` arguments. It validates the archived app's identity, iPhone-only arm64 target, iOS 18 minimum, portrait/landscape orientations, signatures, FFmpeg symbols/licenses, acknowledgements, privacy-manifest presence, and absence of DEBUG markers, `.storekit`, and test `.webm` resources. It audits the archive, not an App Store submission. Current archive and development-export paths are in [release status](app-store/RELEASE_STATUS.md#local-release-artifacts).
