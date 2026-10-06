# YouTube Music account library import

R12 WP8 implements opt-in, read-only import of liked songs, playlists, followed artists and recent history.
Import writes only to the local library. R18's separately enabled, per-action-confirmed [YouTube Changes](ACCOUNT_WRITEBACK.md)
client does not change import semantics or turn local edits into remote writes. Shared documentation is integrated;
[VERIFICATION.md](VERIFICATION.md) owns counts and run evidence.

## Purpose

- Let the owner bring years of likes, playlists and subscriptions over without retyping them, while keeping the
  one library model: imported songs are ordinary `Track` values, playlists are ordinary `UserPlaylist`s, follows go
  through `LibraryStore.follow`. There is no second saved library and no account mirror.
- Cookies live in device-only Keychain storage. Import uses its own actor and URLSession for read-only `browse`
  calls; ordinary `CatalogTransport` remains account-cookie-free. TVHTML5 playback and the separate R18 account-write
  client have their own scoped uses of the saved session.
- Make re-imports safe: additive and idempotent. A second run adds what is new and never removes, unlikes or
  unfollows anything, so the local library stays the listener's own.

## Behaviour

- Entry point: Settings > Account & connection > **Import from YouTube Music** (`settings.youtubeImport`). The row
  appears only while a session exists (not while sign-out is pending); its value is the last import date or
  **Not imported**. Reaching the page without a session shows "Sign in to YouTube in Settings first."
- The page explains "Copies liked songs, playlists, followed artists and recent history from the signed-in YouTube
  Music account into this device's library. Nothing is changed on the account." and warns "Google can see these
  requests on your account." Toggles per kind (`import.kind.likes|playlists|subscriptions|history`); likes,
  playlists and followed artists start on, history starts off because it creates a playlist.
- With Playlists on, the page lists the account's playlists (up to 200) as checkmark rows `import.playlist.<index>`,
  all selected; a tap deselects. Liked Music (`VLLM`) and Episodes for Later (`VLSE`) are not offered: likes are
  their own kind and podcasts are not music.
- **Start import** (`import.start`, 44 pt) runs the selected kinds in order likes, playlists, followed artists,
  history. Each kind shows `import.progress.<kind>` with "N read, M liked|added|followed" and its state; **Cancel**
  (`import.cancel`) stops between pages and keeps what was already applied. A summary line
  (`import.summary`) reads like "Liked 143 songs, added 6 playlists, followed 12 artists." or "Nothing new to
  import."
- Likes: every remote liked song not yet liked here is liked, in remote order ahead of local likes, in one library
  write per page. A song the listener disliked here stays disliked (a like and a dislike cannot coexist). Import
  creates plain likes only: `addFavorites` skips ids already in Liked Songs, so a local super like
  ([SUPER_LIKES.md](SUPER_LIKES.md)) is never downgraded. Liked
  music videos stay tracks with `isAudioRecording == false`, as playlist pages keep them (R13 item 9).
- Playlists: each selected remote playlist becomes a local playlist with the remote name, or " (YouTube)" appended
  when a local playlist already has that name (case-insensitive). The ledger maps the remote id to the local UUID,
  so a later import adds new songs to the same playlist (appended) instead of creating a copy. Songs removed
  remotely stay. A mapped playlist the listener deleted here is created again only if it is selected again.
- Followed artists: subscribed channels are followed through `LibraryStore.follow` without a release baseline, so
  `ReleaseWatcher` records today's releases silently on its next run and announces nothing old. No notification
  permission prompt is raised by the import.
- History: the most recent 200 unique plays (read from up to 500 rows) go into one playlist "YouTube Music history"
  in recency order. On re-import the newest plays lead and earlier imported songs follow in their previous order;
  nothing is removed. No `ListeningEvent` or `RecentListen` is written, so Recap and the language profile stay
  truthful about what was played on this device.
- Failures are per kind: a failed, rate-limited or unreadable kind leaves the others running. One unreadable
  playlist is skipped and counted in the kind's status. A 401/403 (HTTP or `error.status UNAUTHENTICATED`) marks the
  kind **Sign in again**, stops the remaining kinds and shows "Sign in again in Settings, then retry."
- Sign-out keeps imported content and the ledger. Imported likes, playlists and follows are ordinary library
  records, so they sync through iCloud like any other edit; the ledger itself is device-local and not synced.
- Legacy sessions without `writeSessionID` retain playback/import compatibility. Reconnecting to enable R18
  YouTube Changes is a separate requirement; importing never enables that permission or submits a mutation.

## Endpoints

Host `https://music.youtube.com`, `POST /youtubei/v1/browse?prettyPrint=false`, WEB_REMIX context
(`clientName WEB_REMIX`, `clientVersion` from the same anonymous bootstrap as the catalog with the same fallback,
`hl en`, `gl IN`). Headers: browser `User-Agent`, `Accept-Language`, `Content-Type: application/json`,
`X-YouTube-Client-Name: 67`, `X-YouTube-Client-Version`, `Origin`, `Referer`, plus the account session through
`YouTubeAccountSession.apply(to:origin: "https://music.youtube.com")`: `Cookie` (YouTube-domain cookies only),
`Authorization: SAPISIDHASH <seconds>_<sha1(seconds SAPISID origin)>`, `X-Origin`, `X-Goog-AuthUser: 0`,
`X-Youtube-Bootstrap-Logged-In: true`. Continuations send `{"continuation": token}` in the body instead of
`browseId`, with the first page's `responseContext.visitorData` in the client context, encoded through the existing
`CatalogContinuation` cursor (scope `account|<browseId>`).

| browseId | Kind | Parsed with | Continuation source |
| --- | --- | --- | --- |
| `FEmusic_liked_videos` | Liked songs | `CatalogParser.browse(_:context:)` with `keepsVideoRows` | `continuationItemRenderer` token or `musicPlaylistShelfContinuation.continuations` |
| `FEmusic_liked_playlists` | Playlist list | `CatalogParser.browse(_:id:)` collections filtered to `VL` ids minus `VLLM`/`VLSE` | `gridRenderer`/`gridContinuation.continuations[].nextContinuationData` |
| `VLPL...`, `VLRDCLAK...` | One playlist's songs | `CatalogParser.browse(_:id:)` (playlist rows keep video entries) | same as liked songs |
| `FEmusic_library_corpus_artists` | Followed artists | `YouTubeAccountLibraryParser.artists`: `musicResponsiveListItemRenderer` rows whose `navigationEndpoint.browseEndpoint.browseId` is `UC...` or `MPLAUC...` (library artist page, prefix stripped) | `musicShelfRenderer`/`musicShelfContinuation.continuations` |
| `FEmusic_history` | Recent plays | `CatalogParser.browse(_:context:)` with `keepsVideoRows`; day shelves in page order, repeats dropped | `musicShelfRenderer.continuations` when present |

`FEmusic_library_corpus_track_artists` (artists with songs in the library) is not requested: it lists artists the
listener saved songs from, not subscriptions, and would follow artists the listener never chose.

Bounds (mirroring `CatalogTransport` and `docs/PROVIDERS.md`):

| Bound | Value |
| --- | --- |
| Request timeout | 20 s per request, 35 s resource |
| Body cap | 8 MiB through `URLSession.boundedData`, checked while receiving |
| Connections | 2 per host, ephemeral session, no cookie storage (the Cookie header is set per request), no URL cache |
| Retries | One retry after 350 ms for a timeout, connection loss or 5xx; `Retry-After` above 2 s blocks the client for that long |
| 429 | `MusicServiceError.rateLimited`; `Retry-After` (seconds or HTTP date) or 30 s default blocks further requests |
| 401/403 or `error.code` 401/403 | `YouTubeAccountLibraryError.unauthorized`, no retry |
| Caches | None. Account pages are never cached in memory or on disk; only the WEB_REMIX version is cached (6 h, as for the catalog) |
| Likes | 2,000 songs |
| Each playlist | 1,000 songs |
| Playlist list | 200 playlists |
| Followed artists | 500 |
| History | 500 rows read, 200 unique songs kept |
| Pages per listing | 60, and a repeated token ends the listing |

Verified without an account: request shapes and headers (unit tests), parsing of the trimmed fixtures below, error
mapping through a mock `URLSession`. The fixture shapes are hand-written from the InnerTube renderers the catalog
already parses (`musicResponsiveListItemRenderer`, `musicTwoRowItemRenderer`, `musicPlaylistShelfRenderer`,
`gridRenderer`, `musicShelfRenderer`, `continuationItemRenderer`, `onResponseReceivedActions`). Assumed, not
recorded from a signed-in account: that `FEmusic_liked_videos` renders the two-column playlist layout of `VLLM`;
that `FEmusic_liked_playlists` uses a `gridRenderer` with a leading "New playlist" card and `nextContinuationData`;
that subscription rows link `UC...` and library artist rows `MPLAUC...`; that history rows sit in per-day
`musicShelfRenderer`s. `YouTubeAccountLibraryClient` also accepts `continuationContents.*Continuation` envelopes.

## Import ledger

`Application Support/GanaBajana/youtube-import.json` (`YouTubeImportLedgerStore`, `YouTubeImportLedger` version 1),
atomic writes with `completeFileProtectionUntilFirstUserAuthentication`, 4 MiB read cap, a newer version refuses
to load and the page reports it. Fields: `lastImportedAt`, `playlists` (remote `VL...` id to local playlist UUID),
`historyPlaylistID`, `lastCounts` per kind. The ledger is saved after each kind and again with the date when at
least one kind completed; a cancelled run that completed no kind leaves the date alone. It is device-local, not
synced, not in the library file, and untouched by sign-out: a signed-out listener keeps imported content and a
later sign-in resumes updating the same playlists. UI fixtures keep it in the isolated test directory.

## APIs

| Type | Role |
| --- | --- |
| `YouTubeAccountLibraryProviding` (`Sources/Account/YouTubeAccountLibraryClient.swift`) | Page-based read-only account library: `likedSongs`, `playlists`, `playlistTracks(id:)`, `subscribedArtists`, `history`, each `(continuation:) -> YouTubeLibraryPage` |
| `YouTubeAccountLibraryClient` (actor) | Authenticated WEB_REMIX `browse` transport with the bounds above; `request(browseID:cursor:version:session:now:)` is the testable request shape |
| `YouTubeAccountLibraryParser` | Artist rows and grid continuations the catalog parser does not cover; playlist filter |
| `CatalogParser.browse(_:context:)` | New internal entry point: rows with a caller-fixed `RowContext` (video rows kept, no album header) |
| `YouTubeLibraryImporter` (`@MainActor @Observable`) | `start(_:)`, `run(_:)`, `cancel()`, `loadPlaylists()`, `progress`, `summary`, `needsSignIn`, `remotePlaylists`, `lastImportedAt`, `hasSession`; `YouTubeImportBounds` for tests |
| `YouTubeImportLedger`, `YouTubeImportLedgerStore` | Device-local record described above |
| `LibraryStore.addFavorites(_:)`, `LibraryStore.merge(_:into:leading:)` | Bulk, single-write additions (likes; playlist membership with optional newest-first ordering); both skip duplicates, never remove, and return the number added. `addFavorites` adds plain likes and leaves an existing super like's tier alone |
| `MusicAppModel.youTubeImport` | The importer for views; `init(youTubeImport:)` lets fixtures inject one |
| `YouTubeImportView` (`Sources/Views/YouTubeImportView.swift`) | The Settings page |
| `DebugYouTubeImportFixtureClient` (`DEBUG`, `--youtube-import-fixture`) | Fixture sign-in in a memory secret store plus canned pages; the ledger pre-maps the remote "Late night favorites" to the seeded local playlist |

## Metrics

OSLog only, subsystem `com.agraabhi.ganabajana`, category `Account`. No names, ids, titles or URLs.

| Metric or event fields | Emitted when | Dimensions / bounded values | Why |
| --- | --- | --- | --- |
| `event=import_started kinds=` | `YouTubeLibraryImporter.run` begins | kinds = 1...4 | Marks a run for pairing with its finish line |
| `event=import_kind kind= status= fetched= count=` | A kind finishes | kind = likes, playlists, subscriptions, history; status = ok, failed, unauthorized, rateLimited, cancelled; fetched, count = row counts | Shows which listing broke and how much was applied |
| `event=import_finished status=` | The run ends | status = ok, failed, cancelled, unauthorized | One line per run for the overall outcome |
| `event=import_request kind= status=` | Each browse call resolves | kind as above; status = ok, failed, unauthorized, rateLimited | Separates provider refusals from parsing or library problems |
| `event=import_ledger_read_failed`, `event=import_ledger_write_failed` | The ledger cannot be read at init or saved after a kind | none | A lost ledger is the one way a re-import can duplicate playlists |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| `testRequestCarriesTheAccountOnlyWithASession` | Headers, SAPISIDHASH bound to the music origin, WEB_REMIX context, continuation body and visitorData; no account headers without a session | Unit (`YouTubeImportClientTests`) |
| `testNoSessionThrowsUnauthorizedBeforeAnyRequest` | Registry without a session: `unauthorized`, zero requests | Unit |
| `testLikedSongsKeepAudioAndVideoRowsAndFollowTheContinuation` | Two-column playlist page, OMV row kept, podcast and greyed-out rows dropped, `continuationItemRenderer` token, `appendContinuationItemsAction` page, anonymous bootstrap | Integration (mock `URLSession`, fixtures) |
| `testPlaylistListSkipsSystemEntriesAndFollowsTheGridContinuation` | Grid with New playlist, `VLLM`, `VLSE`; `gridContinuation` page | Integration (fixtures) |
| `testSubscriptionsParseChannelAndLibraryArtistIDs` | `UC` and `MPLAUC` rows, upload channel dropped, `musicShelfContinuation` | Integration (fixtures) |
| `testHistoryListsDayShelvesMostRecentFirstWithoutRepeats` | Today/Yesterday shelves, repeat dropped, video row kept | Integration (fixture) |
| `testPlaylistTracksUseTheRecordedPlaylistPageShape` | Recorded live `VLPL` page through the account client; non-`VL` id rejected | Integration (recorded fixture) |
| `testHTTPErrorsMapToUnauthorizedAndRateLimited` | 403, `UNAUTHENTICATED` envelope, 429 with `Retry-After` blocking the next call | Integration (mock `URLSession`) |
| `testOversizedBodiesAreRejectedWhileReceiving` | 8 MiB + 1 body | Integration (mock `URLSession`) |
| `testFirstImportAppliesEveryKindAndASecondRunChangesNothing` | All kinds, dislike kept, name clash suffix, mapped playlists, follow without baseline, history order, summary, ledger, idempotent second run | Integration (`YouTubeImporterTests`, temp `LibraryStore`) |
| `testReimportIsAdditiveOnlyAndUpdatesMappedPlaylists` | Local unlike kept, remote removals kept, appended songs, history newest-first merge | Integration |
| `testHistoryKeepsTheMostRecentTwoHundredUniqueSongsAndLikesStopAtTheirCap` | 500-row history cap and 200-song playlist, likes cap truncates a page and stops paging | Integration |
| `testLedgerPersistsAcrossImporterInstancesAndSignOut` | Ledger read back by a new importer, sign-out keeps content, counts of other kinds kept | Integration |
| `testDeletedLocalPlaylistIsRecreatedWhileOthersAreOnlySelected` | Playlist selection, stale mapping re-creates | Integration |
| `testAFailingKindDoesNotStopTheOthers` | Network failure and rate limit isolated per kind; one unreadable playlist skipped with a status message | Integration |
| `testUnauthorizedStopsTheRemainingKindsAndAsksForSignIn` | `unauthorized` stops later kinds, `needsSignIn` | Integration |
| `testCancellationStopsBetweenPagesAndKeepsWhatWasApplied` | Gate before page two, cancel, applied page kept, no later kinds, no import date | Integration |
| `testStartRequiresASessionAndIgnoresOverlappingRuns` | No session: `start` is a no-op | Unit |
| `testUniqueNamesAndSummaryWording` | Name clash rule, summary and progress copy | Unit |
| `testLedgerStoreRoundTripsAndRefusesNewerVersions` | Missing file, round trip, newer version refused and reported | Unit |
| `testLibraryBulkHelpersSkipDuplicatesAndKeepDislikes` | `addFavorites`, `merge` append and leading, no-op detection | Unit |
| Import keeps a local super like (`addFavorites` never downgrades) | `addFavorites` against a super liked id | Unit and R19 integration ([SUPER_LIKES.md](SUPER_LIKES.md#test-coverage)) |
| `testImportCopiesTheAccountLibraryOnceAndASecondRunAddsNothing` | Settings row and value, page copy, toggles, picker select/deselect, start, progress and summary, second run, Library counts and playlists, relaunch | UI (`GanaBajanaYouTubeImportUITests`, `--youtube-import-fixture`) |
| `testTheRowIsHiddenWithoutASignIn` | Signed-out Settings has no import row | UI |
| Settings inventory (`testIconLabeledSettingsKeepSixSectionsAndNativeTargetsAtLargestTextSize`) | Unchanged signed-out inventory still passes with the conditional row absent | UI (`GanaBajanaListeningControlsUITests`) |

Runs on a dedicated iPhone 17 Pro / iOS 26.5 simulator (`R13-WP8`): `artifacts/R13/WP8-ImportUnit-03.xcresult`
(63 tests, 0 failures: the 21 new `YouTubeImportClientTests`/`YouTubeImporterTests` plus the existing
`AccountSessionTests`, `AccountStoreTests`, `AccountSignInTests`, `AccountSignOutTests`, `AccountAuthBridgeTests`
and `LibraryPlaylistTests`), `artifacts/R13/WP8-ImportUIInventory-07.xcresult` (both import UI tests and the
Settings inventory test at accessibility XXXL, 3 tests, 0 failures), `artifacts/R13/WP8-ImportUI-08.xcresult` (the
import flow again with a light-appearance relaunch and capture, 1 test, 0 failures). Earlier bundles
`WP8-ImportUI-01/04/05` hold the failing iterations (lazy-list rows not yet in the accessibility tree) that the
test's reveal logic now handles; `WP8-ImportUnit-02` holds one stub bug fixed before `-03`.

## Not verified

- No signed-in account was available on the Mac or the simulator, so the four browse ids were not exercised
  against Google. The response shapes are assumed from the InnerTube renderers the catalog already parses; a first
  real import should be watched with `event=import_request` and `event=import_kind` lines. If Google serves a
  different layout for a listing, that kind fails closed ("could not be read") and the others still run.
- Whether Google rate-limits or flags an account that pages through 2,000 likes in one sitting.
- Real-account expiry: an expired session surfaces as `unauthorized` only when Google answers 401/403; a silently
  anonymous response would parse as an empty listing ("Nothing new to import").
- iPad and small-phone layouts of the import page were not captured in this package; the page uses the same Form
  chrome as the other Settings sub-pages.
