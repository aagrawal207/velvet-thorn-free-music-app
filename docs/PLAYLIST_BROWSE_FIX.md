# Playlist browse fix (R13 item 9)

Playlists found through Search opened with no songs. The catalog kept only confirmed album-audio rows on every page, and a community playlist made of music videos or uploads therefore parsed to an empty page. Playlist pages now list every playable entry: album audio where the provider links it, otherwise the video entry itself, marked as a video. Search results, radio, artist and album pages keep the audio-only rule.

## Symptom

Search a query, switch to the **Playlists** filter, tap a playlist. The collection page shows **No music in this collection** or only a fraction of the playlist's songs. The owner saw it on the R12 build with several playlist results in a row.

## Root cause with evidence

The browse id mapping and the parser's page layout handling were not at fault:

- The playlists search returns `VLPL…` browse ids directly (`browseEndpoint.browseId`, page type `MUSIC_PAGE_TYPE_PLAYLIST`); `YouTubeMusicService.browseID` passes them through unchanged, so there is no `VLVL…` double prefix. `CompositeCatalog.browse` routes a bare YouTube id to `YouTubeMusicService` because `MusicSource.source(of:)` treats any unprefixed id as YouTube.
- Playlist pages arrive as `twoColumnBrowseResultsRenderer`: the `musicResponsiveHeaderRenderer` sits in the tab and the `musicPlaylistShelfRenderer` rows in `secondaryContents`. `CatalogParser.collect` descends into both, and the recorded page `Tests/Fixtures/youtube-playlist-browse-bollywood-party.json` (24 ATV rows) parses to 24 tracks unchanged.

The live probe on 26 September 2026 (`CatalogLiveTests.testLivePlaylistSearchResultsOpenWithTheirSongs`, bundle `artifacts/R13/WP15-LivePlaylist-01.xcresult`) browsed the first three `bollywood party` playlist results the way `CollectionDetailView` does:

| Playlist | Rows | Row types | Before the fix |
| --- | --- | --- | --- |
| `VLPLCIh8-uf9gCfBR8HwjHjUWgp55gosCk5S` Bollywood Party songs | 24 | 24 ATV | 24 tracks |
| `VLPLVet2itwf3Bc-oJjmFAPgMy6rnTv1ZKwU` BOLLYWOOD HINDI REMIX … DJ MIX | 31 | 31 UGC | **0 tracks** |
| `VLPLpPdqemXJ05Cq314qMQyje7VbdrwltTgW` Bollywood Party | 70 | 45 ATV, 23 OMV, 2 podcast-typed | 45 tracks |

Across all 20 results of that search (raw pages fetched from the Mac with the same `WEB_REMIX` request), 6 playlists would have opened empty and 5 more lost most of their rows. None of the 90 OMV/UGC rows carried an `MPTC` credits link, so the existing album-audio rescue (`get_queue` confirmation of the credits-linked recording) had nothing to work with.

The cause is `CatalogParser.track`: outside an album page a row was accepted only with an ATV confirmation (`MUSIC_VIDEO_TYPE_ATV` watch endpoint, `atvExternalVideoId` or `musicVideoType`). Community playlists on YouTube Music are largely `MUSIC_VIDEO_TYPE_OMV` (official videos) and `MUSIC_VIDEO_TYPE_UGC` (uploads), so the audio-only rule emptied them. The raw page of the empty playlist is recorded, trimmed to four rows, as `Tests/Fixtures/youtube-playlist-browse-ugc-remixes.json`.

## Fix

`Sources/Catalog/CatalogParser.swift`

- `RowContext.keepsVideoRows` is true for `VL…` playlist ids (`rowContext(_:id:inheriting:)`), including continuation pages, and false for search, radio, artist and album contexts.
- `track` accepts `MUSIC_VIDEO_TYPE_OMV`, `MUSIC_VIDEO_TYPE_UGC` and `MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC` rows when the context keeps video rows, returning them with `isAudioRecording == false`. Confirmed rows stay `true`; podcast-typed and greyed-out rows stay excluded through `isPlayableRow`; rows without any playback type stay out.
- `browseRowCandidates(_:inheriting:)` replaces the flat candidate list with one ordered list per row: a confirmed row is itself; otherwise the `MPTC` credits-linked album recording comes first and the row's own video entry second. `audioCandidateIDs` keeps the previous audio-only view for callers that need it.

`Sources/Catalog/YouTubeMusicService.swift`

- `browsePage` confirms only the credits-linked candidates through `get_queue` (video entries are listed as themselves without a round trip) and rebuilds the page one recording per row in the provider's order: a confirmed album recording replaces its clip in place, and a replaced clip does not reappear at the end.

Downstream behaviour of `isAudioRecording == false` is unchanged and intended: `CatalogDiscovery.accepts`, `ExperienceRadioEngine.isUsable`, `RecommendationEngine.isRecommendable`, `AutoplayContinuation`, `YouTubeDataAPI`, `ArtistSpotlightMusicBrainz` and both prefetch paths already skip video entries, so Home shelves, stations, mixes, autoplay seeds and metadata lookups stay album-audio only. Playback extracts audio-only streams for any recording id, so a video entry plays like any other song; entries longer than the audio cache's 64 MiB file bound stream without being cached (code-level check, not measured on a device).

Not changed: `CollectionDetailView` (it already called `model.catalog.browse(id:)` for playlists), `MusicAppModel.open(_:)`/`activateSearchSelection`, the browse id mapping, and the JioSaavn playlist path. Rows are not yet labelled as videos in the UI; `TrackRow` lives in `Sources/UI/MusicComponents.swift` and would need a small caption if the owner wants the distinction visible.

## Metrics

OSLog debug records in the `Catalog` category, following the existing `providerPlayCount*` record style: numeric counts only, no ids or titles, no remote telemetry.

| Metric | Emitted when | Dimensions | Why |
| --- | --- | --- | --- |
| `browseTracks` | every parsed browse page | none (per page) | page size after merging; zero means the empty state |
| `browseVideoEntries` | every parsed browse page, including `0` | none | how many listed rows are video entries rather than album audio |
| `browseCandidatesChecked` | every parsed browse page, including `0` | none | credits-linked recordings sent to `get_queue`; distinguishes "nothing to confirm" from a failed confirmation |
| `Album-audio counterpart validation failed; unconfirmed credits links stay out.` (warning) | `get_queue` confirmation throws | none | the page falls back to the parsed rows |

## Test coverage

| Case | Branch/path | Unit or integration |
| --- | --- | --- |
| Recorded ATV playlist page parses 24/5 rows with linked credits, album ids, durations, no play count, no continuation | `CatalogParser.browse` two-column layout | Unit (`CatalogParsingTests.testRecordedCommunityPlaylistPageParsesEveryAudioRow`) |
| Recorded UGC-only playlist keeps its four uploads as video entries; the same rows on an album page stay excluded | `track` video-entry acceptance, `keepsVideoRows` gating | Unit (`testRecordedUploadOnlyPlaylistKeepsItsVideoEntries`) |
| Mixed page: audio, OMV, UGC, credits-linked OMV, podcast-typed and greyed-out rows; playlist vs album vs artist ids; songs search; `get_queue` metadata for a video entry | acceptance matrix, `browseRowCandidates` order, `audioCandidateIDs` compatibility | Unit (`testPlaylistPagesKeepVideoEntriesWhileOtherPagesStayAudioOnly`) |
| Playlist and album continuation pages inherit the right context | `rowContext` on continuation responses | Unit (`testPlaylistContinuationPagesKeepVideoEntriesAndAlbumContinuationsDoNot`) |
| Rows without any playback type stay out of playlists | `track` guard | Unit (existing `testAlbumHeaderStraplineCreditsRowsWithoutAnArtistColumn`, message rewritten) |
| Service keeps the owner's order, replaces a clip in place only after ATV confirmation, one `get_queue` call with only the credits link | `browsePage` merge | Unit, mock transport (`CatalogRequestTests.testCommunityPlaylistKeepsVideoEntriesInOrderAndUpgradesOnlyConfirmedCreditsLinks`) |
| Upload-only playlist makes no `get_queue` request; album page with the same rows stays empty | `browsePage` no-candidate path | Unit, mock transport (`testUploadOnlyPlaylistNeedsNoConfirmationRequests`) |
| Album clip credits still used only after ATV validation | album path unchanged | Unit (existing `testAlbumClipCreditsAreOnlyUsedAfterBatchedATVValidation`) |
| Live: first three `bollywood party` playlists open with classified entries; raw page captured on an empty browse | whole service against the provider | Integration, network (`CatalogLiveTests.testLivePlaylistSearchResultsOpenWithTheirSongs`) |
| Live: editorial playlist entries are classified and Home's selection stays album-audio | `CatalogDiscovery.accepts` on a real page | Integration, network (`testLiveSearchAllFiltersPaginationAndCollectionBrowse`, assertion rewritten) |
| Playlist result opens from the Playlists filter with rows, summary and playback | Search to collection page | Fixture UI (`GanaBajanaSearchDiscoveryUITests.testPlaylistSearchResultOpensWithItsSongs`) |

Metric emission is verifiable in the OSLog stream only; the existing catalog tests do not assert log records. Deliberately uncovered: a playlist whose rows are all podcast-typed still shows the empty state (unchanged behaviour); UI labelling of video entries (not implemented).

### Runs

All on a dedicated iPhone 17 Pro / iOS 26.5 simulator (`R13-WP15`), Debug, `artifacts/R13/DerivedData-WP15`, while other packages built on the same Mac.

| Bundle | Result | Scope |
| --- | --- | --- |
| `artifacts/R13/WP15-CatalogParsing-01.xcresult` | 33 passed | parser class with the ATV recording before the fix (proved the two-column layout parses) |
| `artifacts/R13/WP15-LivePlaylist-01.xcresult` | 1 failed (the reproduction) | live: `VLPLVet2…` opened with 0 tracks; raw page captured and recorded as the UGC fixture |
| `artifacts/R13/WP15-CatalogUnit-02.xcresult` | 88 passed | `CatalogParsingTests` 36, `CatalogPlayCountTests` 6, `CatalogRequestTests` 18, `CatalogServiceTests` 17, `CompositeCatalogTests` 11, after the fix |
| `artifacts/R13/WP15-LivePlaylist-02.xcresult` | 3 run, 3 failed on stale assertions | live browse already returned 24 / 31 / 68 tracks; the failing assertions were the old audio-only `allSatisfy` checks, rewritten as described above |
| `artifacts/R13/WP15-CatalogUnit-03.xcresult` | 118 passed | the five catalog classes plus `ExperienceRadioEngineTests` 11 and `ListeningLanguageRadioTests` 19 on the final source |
| `artifacts/R13/WP15-LivePlaylist-03.xcresult` | 4 passed | `testLivePlaylistSearchResultsOpenWithTheirSongs` (24 audio / 31 video / 45 audio + 23 video entries), `testLiveSearchAllFiltersPaginationAndCollectionBrowse` (editorial browse 129 entries, 124 of them video; Home's selection stays audio), album credits and artist page |
| `artifacts/R13/WP15-BaselineUI-01.xcresult` | 4 failed | the four triaged tests on the untouched checkpoint tree `6c34c9e`, same simulator |
| `artifacts/R13/WP15-DiscoveryUI-01.xcresult`, `-02.xcresult` | 3 passed, 2 failed; then 1 passed, 1 failed | intermediate runs while the fixture leak, the scroll precondition and the Norah expectation were corrected |
| `artifacts/R13/WP15-DiscoveryUI-03.xcresult` | **20 passed, 0 failed** (2,938 s) | the complete `GanaBajanaSearchDiscoveryUITests` class, including the new playlist test |

Observation outside this item: both editorial Home playlists (`CatalogDiscovery.hindiPlaylist`, `englishPlaylist`) are now mostly `OMV` rows on their first page (3 of 50 and 1 of 100 ATV rows on 26 September), so the **Bollywood hits** / **Pop hits** shelves have very few songs to select from. Unchanged here; a follow-up could pick different editorial sources or accept video entries for those shelves.

## Search discovery UI triage findings

The four `GanaBajanaSearchDiscoveryUITests` failures from the R12 WP9 run were rebuilt from the checkpoint tree (`git archive 6c34c9e` into `/tmp/r12-baseline`) and run on the same iPhone 17 Pro / iOS 26.5 simulator: all four fail identically at the checkpoint (`artifacts/R13/WP15-BaselineUI-01.xcresult`), so none is an R12 regression and none is on WP9's code. They are stale since the R6 listening-language work and had not been rerun as a class since `R3-UI-Radio2-0922-1029`.

| Test | Observed | Cause | Change |
| --- | --- | --- | --- |
| `testHindiLedMelancholyStartsFromStyleSearchesWithoutArtistHintsOrLanguageSwitches` | Melancholy active, **Tum Hi Ho** playing | `DebugMusicFixtures.search(filter: .playlists)` answered every query, including the station's style queries, with the "Evening favorites" fixture album, so `ExperienceRadioEngine.discoverStyle` browsed it and the seeded library songs (known language, weighted 2x by the profile) outranked the style songs | Fixture: style queries return no playlist (`Sources/App/DebugBootstrap.swift`). Test unchanged; passes |
| `testFastStationReselectKeepsTheNewStationAndExistingPlaybackDuringLoading` | Workout active, **Blinding Lights** playing | Same fixture leak on the slow-radio path | Same fixture change. Test unchanged; passes |
| `testArtistSearchAndNewerEraUseTheAddedArtistsActualDatedRecording` | Melancholy Newer active, **Carry On** (Norah 2016) playing instead of Apocalypse | R6 design, not the leak: a known-language anchor matching the dominant profile leads the queue (`ExperienceRadioEngine.select` weights, `ListeningLanguageRadioTests` assert the same order) and `MusicAppModel.startRadio` re-ranks the batch. The cue "Apocalypse" has no language evidence in the fixture | Stale expectation rewritten: Carry On first, Apocalypse and Norah's radio neighbours present, the 2002 album absent. The era assertion the test is named for is unchanged |
| `testSearchReselectPopsScrolledRadioAndFocusesTheField` | "The test must begin scrolled away from the top" | The radio page lost its language switches in R6, so the grid starts high enough that **Rap and hip hop** is visible without scrolling on this simulator; `reveal` had nothing to do | Stale precondition: the test now reveals the last genre tile (`search.station.nineties`). Passes |

Also in this class: `expectSearchAtTop` used `search.library.likes` as the empty-query anchor; WP14 removed that shortcut (R13 item 3) and the Radio row now leads the start screen, so the anchor is `search.radio.open`. WP14 owns `SearchView.swift`; if the start screen changes again the anchor must follow.
