# Album descriptions

Album descriptions are integrated and have passing parser/provider/loader, catalog, live-provider, and fixture UI coverage across runs. [VERIFICATION.md](VERIFICATION.md) owns the full execution record, including the original license-path and Retry-accessibility failures and their successful follow-ups.

## Source decision

Album descriptions use the Wikipedia text already supplied on the selected YouTube Music album's browse header. Live public requests on 21 September 2026 returned that field for both **Graduation** and **Aashiqui 2**, with full Wikipedia article URLs and explicit **CC BY-SA 3.0** links. The microformat descriptions in those responses were short catalog labels, such as `Album • Kanye West`, and are not used as prose.

The field is `musicResponsiveHeaderRenderer.description.musicDescriptionShelfRenderer.description.runs`. Its last runs contain a `From Wikipedia (…) under Creative Commons Attribution CC-BY-SA 3.0 (…)` footer. The visible URL labels are shortened; the actual links come from each run's `navigationEndpoint.urlEndpoint.url`.

This gives the lookup a provider album ID and its own header credits. A separate title search is unnecessary for the supported source. Missing or unrecognized descriptions remain absent. This implementation does not turn catalog metadata, MusicBrainz annotations, or search snippets into an album biography.

### Public API research

| Official source | Evidence and decision |
| --- | --- |
| [MediaWiki search](https://www.mediawiki.org/wiki/API:Search) | Supports bounded title/content search and use as a generator. Search results identify candidates, not the intended album. An `In Rainbows` / `Radiohead` query returned the album and *From the Basement*. A `Rockstar` / `Rahman` query returned a soundtrack, a film, and a disambiguation page among its results. |
| [Wikimedia Page Content Service](https://www.mediawiki.org/wiki/Page_Content_Service#JSON_endpoints) | Documents `/api/rest_v1/page/summary/{title}` as stable. Live summaries for *In Rainbows*, *Graduation (album)*, and *Rockstar (soundtrack)* returned `type: standard`, plain `extract`, a Wikidata item, and article URLs. A future independent fallback would need to verify album and artist identity before using this text. |
| [TextExtracts](https://www.mediawiki.org/wiki/Extension:TextExtracts#API) | Supports plain introduction extracts and response-length parameters, but its documentation recommends the Page Content Service for Wikimedia summaries and describes sentence-boundary limitations. It is not used. |
| [Wikidata data access](https://www.wikidata.org/wiki/Wikidata:Data_access) | Documents small `wbgetentities` batches and CC0 structured data. A live lookup for *In Rainbows*, `Q223295`, returned an album instance claim `P31 → Q482994`, a performer claim `P175 → Q44190`, and the `enwiki` sitelink. These relationships could support a future fallback; a short Wikidata description alone would not be an album biography. |
| [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) | Documents release-group searches/lookups, artist credits, URL relationships, and annotations. Public reads need no API key but require an identifiable User-Agent and no more than one call per second. The existing album-scoped prose makes another metadata lookup unnecessary. |
| [Wikimedia licensing terms](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use#7._Licensing_of_Content) | Article links can provide contributor attribution; reuse needs the applicable license link and notice of modifications. Direct Wikipedia's current terms describe CC BY-SA 4.0. The provider's explicit 3.0 notice is preserved for its supplied copy rather than silently changed to 4.0. |

These original documentation reads and direct HTTP research were **not executed app tests**. The later live-provider test described below is separate evidence.

### Recorded provider responses

| Browse ID | Header | Wikipedia article | Header artists |
| --- | --- | --- | --- |
| `MPREb_KCNeTnK02S7` | Graduation | [Graduation (album)](https://en.wikipedia.org/wiki/Graduation_(album)) | Kanye West |
| `MPREb_E4GfUXfDfhy` | Aashiqui 2 | [Aashiqui 2 (soundtrack)](https://en.wikipedia.org/wiki/Aashiqui_2_(soundtrack)) | Jeet Gannguli, Ankit Tiwari, Mithoon |

Both responses supplied `https://creativecommons.org/licenses/by-sa/3.0/legalcode`. Reduced snapshots are in `Tests/Fixtures/album-description-graduation.json` and `Tests/Fixtures/album-description-aashiqui-2.json`. They preserve the observed prose and attribution; unrelated response fields and tracking values are omitted. The quoted text in these snapshots retains the provider's linked Wikipedia attribution and CC BY-SA 3.0 notice.

## Identity and parsing

`CatalogAlbumDescriptionParser` accepts only validated `MPRE`/`MPAL` album identifiers. It reads the page's direct header or a top-level header in the selected browse tab. The description, title, release kind, and linked credits all come from that same header. Its subtitle must identify an album, soundtrack, or EP. `CatalogParser.albumHeaderCredits` reuses the linked-credit extraction for that header. Related shelves and unselected tabs cannot supply missing credits or suppress a valid selected description, including when their album titles are identical. `CatalogPage.albumDescription` is optional and defaulted, and `AlbumDescriptionProviding` is a separate optional capability. Existing catalog implementations need no new method.

The first English sentence starts with the normalized album title followed by `is` or `was`, then identifies an album, soundtrack, or EP within the first 16 definition words. A film, song, biography, or disambiguation lead is rejected. Album matching uses `LyricsMatcher.normalized`, which preserves native-script marks; artist matching reuses `SearchRelevance.normalize` to handle initials such as `A.R. Rahman`.

Every header artist needs an album-artist or soundtrack-composer relationship. An explicit lead such as `album by …` must credit every header artist in its byline. Guest, production, and comparison clauses end that byline, and later mentions cannot repair a conflicting lead. The recorded *Graduation* description identifies Kanye West as the album artist; Chris Martin's guest appearance and DJ Toomp's production contribution do not establish album identity for either contributor.

A soundtrack lead can instead use later composition clauses tied to its music, score, or songs. In the *Aashiqui 2* fixture, `The songs of the film were mostly composed by Jeet Gannguli` supplies one relationship. The same sentence continues with `although Mithoon and Ankit Tiwari composed two songs each as guest composers`, supplying the other two. All three relationships are required. Merely retaining the three names while changing one clause to production, guest appearances, or comparison is insufficient.

The article title must match the album title, optionally with an album, soundtrack, EP, or credited-artist album suffix. Only HTTPS `en.wikipedia.org/wiki/…` article links and recognized `creativecommons.org` CC BY-SA 3.0/4.0 license links are accepted. License paths must equal `/licenses/by-sa/{version}`, that base with a trailing slash, or its `/legalcode` or `/deed.en` path. Matching is exact, not an arbitrary path prefix. Credentials, alternate ports, query strings, fragments, other hosts, and unknown licenses are rejected. The footer's stated version must agree with its license link. Both navigation links are required.

The parser deliberately favors absence when metadata does not agree. It does not collapse live, remix, or deluxe titles using song-version matching. Attribution parsing recognizes a bounded set of English descriptors and clause shapes; unfamiliar qualifiers or sentence structures may omit valid text. Descriptions using another language, another attribution shape, aliases absent from the header, or an edition title that differs from the article may also be omitted. There is no independent Wikipedia disambiguation-page request: rejection uses the scoped header, definition, credits, and article title. Source accuracy remains the responsibility of the supplied article; this is not independent fact-checking.

## Loading and presentation

- Ordinary album browsing carries the parsed description alongside songs. A valid supplied description is displayed without another lookup.
- A description-only lookup is available for prepopulated albums and for catalog pages without a parsed description. It reads only the first browse header. A just-fetched browse response normally satisfies it from the existing cache.
- Song loading completes before the optional lookup is awaited. Play, shuffle, song rows, and save actions remain independent of description state.
- The section starts at three lines, with **Read more** / **Show less**. The source and license links remain visible in both states and have 44-point minimum targets. The collapsed accessibility label is also shortened.
- Missing or rejected text hides the section. A thrown lookup failure shows a local **Retry** action. The error row uses `.accessibilityElement(children: .contain)` so the identified Retry button remains a separate accessible action. Rendering or revisiting a failed state does not start a retry loop.
- `AlbumDescriptionLoader` owns cancellation and a generation. Its request identity includes the complete `MusicCollection`, not just its ID. New selections, changed metadata, supplied catalog results, cancellation, and deadlines retire older work. Returned album IDs are checked before publication. `CollectionDetailView` also gates publication and retry starts on current collection identity and visibility.

## Network and retention

| Operation or retained value | Bound |
| --- | --- |
| Description-only provider operation | 5 seconds total, including client bootstrap, transport retry delays, and the first browse request |
| UI loader, including injected providers | 6 seconds total; cancellation returns without waiting for a non-cooperative provider |
| Description-only browse depth | One header response; no continuation or recording-enrichment requests |
| HTTP response reception | Existing `URLSession.boundedData` limit of 8 MiB, checked while receiving, including absent/chunked lengths |
| Catalog transport retry | Existing maximum two attempts per bootstrap/browse request, within the description deadline; existing Retry-After cooldown applies |
| Raw description field | 32 KiB and at most 64 runs |
| Album title / credit / source URL | 512 bytes / 256 bytes per credit, at most eight credits / 2,048 bytes |
| Displayed prose | At most 2,400 characters plus an ellipsis, cut at a word boundary; shortened text is marked **Excerpt** |
| Cache | Existing account-cookie-free `CatalogTransport` memory cache, 24 responses and 12 MiB; album browse TTL is 10 minutes |

Successful responses without a usable description use that same ten-minute response cache. Description lookup HTTP errors, malformed JSON, and structurally invalid response envelopes do not become cached absence. Cancellation cancels only the relevant transfer; the shared session remains available to other requests. The feature introduces no persistent description store.

Requests go to the existing `music.youtube.com` catalog endpoint with an album browse ID and WEB_REMIX client context. Cold lookups can also request the catalog bootstrap. The existing ephemeral session excludes account cookies and stored credentials. A provider sees the normal request/network metadata. Wikipedia and Creative Commons URLs are opened only when the user follows their links; this implementation makes no automatic requests to Wikipedia, Wikidata, or MusicBrainz for album descriptions.

## Metrics

Diagnostics follow the app's existing local OSLog style, category `AlbumDescriptions`. They do not send analytics and do not log prose, album IDs, artist names, or URLs. There are no metric dimensions.

| Diagnostic | Emitted when | Purpose |
| --- | --- | --- |
| `albumDescriptionPresent` / `albumDescriptionMissing` | A matching result or successful absence is published, with zero counterpart | Distinguish content availability from lookup failure |
| `albumDescriptionLoadSuccess` / `albumDescriptionLoadFailure` | A current optional lookup completes or fails, with zero counterpart | Identify retryable lookup failures |
| `albumDescriptionLoadMilliseconds` | Optional lookup completion/failure | Observe bounded loading latency |
| `albumDescriptionRetry` | Optional load starts, zero or one | Identify explicit retries |
| `albumDescriptionCancelled` | Pending work is retired or the caller cancels; zero on completed/failed loads | Observe cancellation separately from failure |
| `albumDescriptionRejected` | Returned album ID is rejected; zero for valid result publication | Identify provider identity violations |

Header or prose identity rejection returns absence, which publishes through `albumDescriptionMissing=1` and `albumDescriptionPresent=0`. The pure parser emits no separate diagnostic; `albumDescriptionRejected` covers the loader's returned-ID check. The tests exercise these branches but do not assert OSLog output, consistent with neighboring app tests.

## Verification and test coverage

`Breezy-Companions-Unit-02` ran 202 targeted phone tests: 201 passed and `testLicenseFourIsOnlyUsedWhenTheProviderActuallySuppliesIt` failed on a valid license-base URL. Foundation's `URL.path` can omit its trailing slash. Accepting the exact canonical base as well as the slash/legalcode/deed forms fixed the mismatch without widening the host or license allowlist.

`Breezy-Album-Verification-01` then passed **71/71** parser, catalog, and live checks. Its one live test fetched real **Graduation** and **Aashiqui 2** album headers and verified their supplied attribution. These are overlapping scoped runs; the original phone run remains failed and is not relabeled as a green full suite.

All four album-description UI workflows have passing coverage across `Breezy-Phone-Experience-UI-01` and `Breezy-Phone-Experience-UI-Fixes-02`. The Retry workflow's initial accessibility-group failure was resolved by the containing-group change above. The successful follow-up exercises Retry without reloading songs. [VERIFICATION.md](VERIFICATION.md) records the complete phone UI counts of those runs, including the separate mini-player workflows and the since-removed automatic player-presentation workflows.

Unit tests use `CatalogMockSession`, injected clocks/counters, and the existing bounded transport. The table records coverage, not additional executions beyond those runs.

| Suite | Test method | Coverage |
| --- | --- | --- |
| `AlbumDescriptionParserTests` | `testRecordedEnglishAndHindiAlbumHeadersRetainTheirActualAttribution` | Reduced live payload fixtures and composer credits |
| | `testAlbumHeaderPreservesGenuineTextLinkedAttributionAndSuppliedLicense` | Catalog-page integration, unmodified prose, full navigation URLs |
| | `testLicenseFourIsOnlyUsedWhenTheProviderActuallySuppliesIt` | Exact canonical base, trailing-slash, legalcode/deed forms, and license version agreement |
| | `testMetadataSubtitlesArtistBiosAndOtherCollectionKindsAreNotDescriptions` | Absent/generic text, collection kinds, defaulted model field |
| | `testDescriptionsInRelatedShelvesOrAnUnselectedTabAreNotAdopted` | Header scoping |
| | `testSelectedAlbumHeaderWinsOverUnselectedHeaderWithSameTitleAndDifferentArtist` | Competing equal-title headers preserve the selected Kanye West credit, its ID, and prose |
| | `testSelectedAlbumHeaderWinsOverUnselectedHeaderWithDifferentTitle` | Both recorded albums retain their own title, artists, and article link despite an earlier unselected header |
| | `testRelatedHeaderCannotReplaceSelectedAlbumMetadata` | Earlier related headers with equal or different titles cannot replace selected metadata |
| | `testSelectedHeaderCannotBorrowMissingOrConflictingCredits` | Selected missing/guest-only credits cannot be repaired by valid unselected or related headers |
| | `testSelectedHeaderMustSupplyItsOwnAlbumType` | Release-kind validation uses the selected header in both directions |
| | `testWrongAlbumArtistFilmSongAndDisambiguationContentAreRejected` | Identity and content-kind rejection |
| | `testRecordedGraduationRejectsGuestOnlyArtistCredits` | Recorded Chris Martin guest mention is insufficient alone or alongside Kanye West |
| | `testRecordedAlbumsRejectProducerOnlyArtistCredits` | Recorded DJ Toomp and Bhushan Kumar production mentions are insufficient |
| | `testGuestProducerAndComparisonMentionsCannotSatisfyAlbumCredits` | Lead/later incidental clauses cannot satisfy sole or additional header credits; genuine lead artist remains accepted |
| | `testConflictingSoundtrackLeadCannotBeRepairedByLaterComposition` | Explicit conflicting album byline vetoes later composer evidence |
| | `testRecordedSoundtrackRequiresEveryComposersActualRelationship` | Recorded later passive/active composer clauses remain valid; losing any relationship rejects the full credit list |
| | `testSoundtracksUseAlbumHeaderComposersAndPreserveInitialsAndLaterCreditMentions` | Initials in direct, later passive, and later active soundtrack-composer clauses |
| | `testAlbumVersionsAreNotCollapsedUsingSongTitleHeuristics` | Edition/version rejection |
| | `testExtendedPlaysRequireEveryAlbumCreditAndNativeTitleMarksStayDistinct` | EPs, partial-credit rejection, Unicode title identity |
| | `testMissingForgedOrUnlicensedAttributionIsRejected` | Unsafe or missing source/license links |
| | `testLongTextIsBoundedAtAWordBoundaryAndOversizedOrMarkupTextIsAbsent` | Text budget and literal-text rendering contract |
| `AlbumDescriptionProviderTests` | `testDescriptionOnlyLookupUsesOneHeaderWithoutPaginationOrRecordingEnrichment` | Request budget, memory reuse, credential-free request |
| | `testOrdinaryBrowseCarriesTheDescriptionAndWarmsTheOptionalLookupCache` | Existing catalog protocol and shared response cache |
| | `testMissingDescriptionIsNegativeCachedUntilTheBrowseResponseExpires` | Cached absence and expiry |
| | `testRateLimitIsRetryableAndItsCooldownIsSharedWithCatalogReads` | Retry-After and recovery |
| | `testMalformedAndOversizedResponsesDoNotBecomeCachedAbsence` | Errors remain errors; declared body-size rejection |
| | `testTotalDescriptionDeadlineCancelsThePendingRequest` | Actual transport cancellation on timeout |
| | `testCancellationDoesNotCancelAnotherAlbumsRequestOrPublishAResult` | Request-local cancellation |
| | `testUnsupportedIDsAndAlreadyCancelledCallersStartNoNetworkWork` | Early guards |
| `AlbumDescriptionLoaderTests` | `testAlreadyProvidedDescriptionNeedsNoLookup` | Primary supplied description preference |
| | `testLateSuccessCannotAttachToAnotherAlbum` | Stale success |
| | `testSameIDWithNewMetadataAndLateFailureCannotReplaceNewerState` | Metadata identity and stale error |
| | `testMissingDescriptionIsDistinctFromFailureAndDoesNotAutomaticallyRetry` | Absence and optional-provider compatibility |
| | `testExplicitRetryClearsFailureAndRejectsWrongAlbumIDs` | Retry, mismatch, recovery |
| | `testCallerAndViewCancellationRetireResultsAndAllowANewLoad` | Caller/view cancellation and reopening |
| | `testDeadlineDoesNotDependOnAnInjectedProviderCooperatingWithCancellation` | Non-cooperative provider |
| | `testCatalogDescriptionSupersedesPendingOptionalLookupAndNeedsNoSecondRequest` | Catalog publication supersedes optional work |
| `GanaBajanaAlbumDescriptionUITests` | `testDescriptionExpandsAndCollapsesWithVisibleSourceAndLicense` | Deterministic UI integration: text height, controls, attribution |
| | `testSongsCanPlayWhileTheOptionalDescriptionIsLoading` | Deterministic UI integration: nonblocking playback |
| | `testUnavailableDescriptionLeavesSongsAndActionsUsable` | Deterministic UI integration: absence |
| | `testRetryableDescriptionFailureRecoversWithoutReloadingTheSongs` | Deterministic UI integration: retry |
| `AlbumDescriptionLiveTests` | `testLiveEnglishAndHindiAlbumHeadersSupplyAttributedDescriptions` | Opt-in integration with the actual provider |

The existing `BoundedURLSessionTests` cover unknown/chunked lengths, overflow before EOF, and request-local cancellation at the transport layer. This feature reuses that implementation rather than creating another receiver. Native VoiceOver, large Dynamic Type, and real external-link opening remain coordinator/device verification work. No test claims broader catalog coverage than its fixtures/reference albums.

## Runtime and test configuration

- `project.yml` includes the implementation and tests through `Sources`, `Tests`, and `UITests`, with `Tests/Fixtures` in the unit-test resource bundle.
- The focused unit suites are `AlbumDescriptionParserTests`, `AlbumDescriptionProviderTests`, and `AlbumDescriptionLoaderTests` in `GanaBajanaTests`.
- `GanaBajanaUITests/GanaBajanaAlbumDescriptionUITests` supplies `--uitesting --seed-ui --album-description-fixture` through the existing driver. The fixture extends `DebugMusicFixtures` and is excluded from Release.
- `GanaBajanaLive` supplies `GANABAJANA_LIVE_TESTS=1`, and `tools/verify.sh live` includes `AlbumDescriptionLiveTests`.
- [PROVIDERS.md](PROVIDERS.md#album-descriptions) and [PRIVACY.md](../PRIVACY.md) describe the network, retention, and attribution behavior. Public Support/Privacy publication and release records remain coordinator-owned; the local disclosures have not been published by this closeout.
