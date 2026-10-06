# Lyric Sources and Script Choices

`LyricsView` displays published alternatives for the same recording, with a source credit on each document. A known Punjabi recording can prefer Gurmukhi and offer a published Latin alternative. Selection changes the whole document, including its timestamps. This implementation performs no lyric transliteration or translation.

R17 lyric variants are implemented and integrated. Production installs JioSaavn cross-source discovery and one model-owned phone/TV selection. The coordinator reports Core-03, Integration-03 and UI-02 passing, including source text and phone light/dark presentation. [VERIFICATION.md](VERIFICATION.md) owns receipt details. Physical TV lyrics and recording-specific live script availability remain unverified.

## Behaviour

- The existing `LyricsProviding.lyrics(for:)` path retains LRCLIB first, then the recording-linked catalog fallback. A primary instrumental result ends discovery. Language classification and existing TV consumers can keep calling that method.
- `LyricsVariantsProviding` is an optional subprotocol. `CompositeLyricsProvider.lyricVariants(for:)` collects the baseline, LRCLIB search alternatives, the catalog fallback and an optional additional source. Old providers require no new methods.
- The phone shows usable baseline lyrics while checking alternatives. A missing baseline stays in Loading until discovery finishes. All successful absences produce No Lyrics; an outage without usable content produces a retryable error. A valid baseline survives failed variant discovery. Partial provider results are usable but are not cached as a complete search.
- Lyric Version appears only with at least two valid content candidates. Each menu item names the script, Timed or Plain, and source. The menu label and retry controls have explicit minimum 44-point targets; native menu items retain native accessibility. Long labels wrap.
- The first candidate in the known recording language's original script is preferred. An explicit candidate choice takes priority on later loads with the same recording metadata and language input. Choices retain at most 32 entries in the controller's memory and are not saved to the library or shared preferences.
- If no original-script candidate exists, the available document remains usable. No disabled or fabricated Gurmukhi choice appears. Unknown-language recordings use script names, without an Original claim.
- Original Script describes the writing system expected for the supplied recording language, not verified wording or an artist-approved edition. Latin text is labelled **Romanised / Latin** for a known non-Latin language. The UI says: “Latin text may be a romanisation or translation.” Each candidate retains its source credit.
- Punjabi accepts Gurmukhi or Arabic script when the language is `pa`; an explicit `pa-Guru` or `pa-Arab` narrows that choice. Mixed scripts and short/unknown text get neutral labels. Script detection requires at least four letter scalars and 90 percent agreement, and preserves the original Unicode text.
- Switching timed documents resets the following/highlight view using a content-and-timestamp identity. Plain alternatives have no lines/timestamps. The existing per-recording timing offset still applies to whichever timed document is selected; offsets are not converted between providers.

## Language Input

The inspected `Track` has `language: MusicLanguage?`, covering Hindi and English, but no `recordingLanguage` property. `ArtistSongLanguage` also lacks Punjabi. This change does not add a parallel recording-language model or alter the shared track schema.

`LyricsLoader.load(for:using:recordingLanguage:)` and `LyricsView(..., recordingLanguage:)` accept an optional recording language code, for example `pa` or `pa-Guru`. The input must come from recording-level metadata or an explicit recording correction. When absent, the loader reuses `Track.language`. An artist name, nationality, catalog region, title script or discovery preference is never evidence for that input. The view does not carry a supplied code to a different playing track.

`MusicAppModel.loadSelectedLyrics` supplies saved recording-language corrections first, then an explicit caller code, then the Data API's raw audio-language tag. Missing input falls back to `Track.language`. Gurmukhi receives an Original Script label only with suitable recording-language evidence. Choosing a display script does not change saved language evidence or the baseline classification path.

### YouTube Recording Metadata

`YouTubeDataAPI.Metadata.audioLanguageCode: String? = nil` retains the normalized `snippet.defaultAudioLanguage` tag independently of the existing classifier result. For example, `pa-Guru` remains available to lyric selection even though `ArtistSongLanguageResult` still classifies Punjabi as unsupported. Existing classifier behaviour and the shared Track schema are unchanged.

`YouTubeDataAPI.lyricLanguageCode(for: Track) async throws -> String?` reads this field through the existing `metadata(for:)` request, cache and coalescing path. `defaultAudioLanguage` was already included in the requested fields, so this adds no endpoint, request field or separate lookup cache. It can reuse a duration, language-classification or Song details request. A cold lookup still uses the configured Data API key and existing quota, offline, timeout and cancellation rules.

Accepted input is at most 64 UTF-8 bytes before trimming, with the existing classifier's BCP47-like syntax: a two- or three-letter ASCII language followed by hyphen-separated ASCII alphanumeric subtags of two to eight characters. Surrounding whitespace is trimmed; language/other subtags use lowercase, four-letter alphabetic script subtags use title case, and two-letter region subtags use uppercase. This checks bounded syntax, not language-registry membership. Underscores, embedded whitespace, empty subtags, non-ASCII text and singleton extension/private-use tags are rejected. Invalid or absent values produce nil. Tags such as `und`, `mul` and `zxx` are retained as supplied metadata, without implying an identified language or an original-script choice.

The accessor excludes prefixed catalog IDs, invalid recording IDs and tracks explicitly marked `isAudioRecording == false` before requesting metadata. Legacy YouTube recordings with an absent audio flag remain eligible, as in the existing recording-language accessor. It never substitutes `defaultLanguage`, Track language, artist metadata or a description. Provider failures still throw; cancellation never returns a late code.

The model installs `dataAPI.lyricLanguageCode(for:)` as `lyricLanguageLookup`. Its async load preserves correction priority, checks the current track/token after metadata lookup and restarts if the saved correction changed during the await. Correction observation clears stale selection and reloads the current recording.

## Recording Matching

### LRCLIB

The single-document matcher and its ambiguity rule are retained. Variant discovery makes at most two existing `search` queries and considers at most 20 records per response. Each variant must pass `LyricsMatcher.evaluate(...).isExact`: title/version agreement, complete artist agreement, known duration within two seconds, and album agreement when the requested album is useful.

Candidates are grouped by the script of the displayed text. The existing `bestMatch` ambiguity rule is then applied within each script. Different-script exact candidates can coexist; competing same-script text/timing cannot evade that rule. A record whose plain and timed fields use different detected scripts can produce two candidates. The plain candidate keeps its published text and gets an empty `lines` array. Both retain the LRCLIB record ID and source link.

This discovers alternatives already present in search results or distinct plain/timed fields. LRCLIB search exposes each track's current lyrics, not all historical edits. No language/script query parameter, variant-history endpoint or automatic Roman-to-Gurmukhi conversion is assumed. Exact metadata is strong matching evidence, not an acoustic identity or translation-equivalence proof.

### JioSaavn

`JioSaavnLyricsProvider(catalog:)` reuses the installed `JioSaavnCatalogService` and its transport. For a `saavn:` track it reads that recording directly. For another source it performs one song search, validates the first page, and fetches lyrics only when exactly one distinct recording matches. Duplicate rows with the same ID do not add a request.

Cross-source matching requires the same cleaned title, complete artist sets in both directions, the existing version/album checks, known duration within two seconds, and no conflict in available `Track.language` values. Missing duration, different artists, live/remix versions and ambiguous releases produce no candidate. Composer-versus-singer credit differences can deliberately prevent a match. Regional language values unavailable in `Track.language` cannot be compared by this adapter.

The adapter preserves `lyrics_copyright` as `LyricsDocument.attributionText`, sets `providerTrackID` to the matched `saavn:` recording, and binds `trackID` to the requested recording. It supplies plain text only. A provider failure envelope retains the existing JioSaavn absence convention; malformed payloads, transport failures and cancellation remain errors. No provider song URL is guessed from the opaque ID. The response's tracking URL is not fetched.

## APIs and Integrated Wiring

All symbols use the app's existing module-internal visibility.

| API | Contract |
| --- | --- |
| `LyricsProviding.lyrics(for: Track) async throws -> LyricsDocument` | Existing baseline contract, unchanged |
| `LyricsVariantsProviding.lyricVariants(for: Track) async throws -> [LyricsDocument]` | Optional discovery; at most eight validated documents in the composite result; an empty source result means successful absence |
| `CompositeLyricsProvider(..., additionalVariantSource: (any LyricsProviding)? = nil)` | Optional additional source, used only by variant discovery |
| `JioSaavnLyricsProvider(catalog: JioSaavnCatalogService)` | Direct or strict cross-source JioSaavn lyrics, using the shared catalog transport |
| `YouTubeDataAPI.Metadata.audioLanguageCode: String? = nil` | Normalized, bounded recording audio-language tag; existing memberwise initializer calls remain valid |
| `YouTubeDataAPI.lyricLanguageCode(for: Track) async throws -> String?` | Uses the existing metadata/cache/request path; rejects ineligible recording IDs before lookup |
| `LyricsDocument.attributionText`, `.attributionURL`, `.providerTrackID` | Optional Codable fields; old documents and initializer calls remain valid; `providerTrackID` uses the app's prefixed recording identity |
| `LyricsDocument.selectionID` | Content/timing/source identity, excluding fetch date; not a log value |
| `LyricsLoader.load(for:using:recordingLanguage:)` | Main-actor load with generation/cancellation fences and defaulted language argument |
| `LyricsLoader.variants`, `.selectedDocument`, `.recordingLanguage` | Observable selection state |
| `LyricsLoader.selectVariant(id:for:)` | Selects only a candidate belonging to the current complete Track value |
| `LyricsLoader.clear()` | Retires the generation, clears visible/TV state, keeps bounded remembered choices |
| `LyricsLoader.onSelectionChanged: (@MainActor (Track, LyricsDocument?) -> Void)?` | Synchronous callback on baseline/variant publication, selection and clearing; nil means clear the projection |
| `LyricsView(track:loader:recordingLanguage:requestLoad:)` | All new arguments default. With `requestLoad`, initial load and Retry delegate to the coordinator instead of a sheet-owned async task |

### Install the Additional Provider

`MusicAppModel.init` reuses `ProductionSources.saavn` when constructing the default provider. Equivalent constructor excerpt:

```swift
let extraLyrics: (any LyricsProviding)? = sources.map {
    JioSaavnLyricsProvider(catalog: $0.saavn)
}
let lyrics = lyrics ?? CompositeLyricsProvider(
    primary: LRCLyricsService(),
    fallback: catalog as? any LyricsProviding,
    prepareTrack: prepareTrack,
    additionalVariantSource: extraLyrics
)
self.lyrics = lyrics
```

This constructor is integrated. Injected fixtures without production sources remain isolated. Catalog source settings govern Search visibility, not saved-track routing or this additional lyric source. Cross-source discovery can request JioSaavn even for another catalog's recording.

### Share the Chosen Document with TV

`MusicAppModel` owns one `LyricsLoader` and its task. `PlayerLyricsSheet` passes that loader and `requestLoad` to `LyricsView`. The callback receives the duration-adjusted track and language on the main actor; initial loading and Retry use `loadSelectedLyrics`. Sheet dismissal does not cancel the model-owned task.

The model owns the following state; `MusicAppModel+Lyrics.swift` owns the fenced loading method:

```swift
let lyricsSelection = LyricsLoader()
@ObservationIgnored var lyricsSelectionTask: Task<Void, Never>?
```

The sheet passes `loader: model.lyricsSelection` and the model load callback. Other callers may omit both and keep sheet-owned loading. The integrated method resolves recording-language evidence with the precedence described above.

`installLyricsSelection()` installs `onSelectionChanged` once. It checks the selected Track, current player ID and captured TV token before passing the exact chosen document, source and variant label to TV. Track/correction observation cancels old work and clears selection; `clearSelectedLyrics` also stops TV on privacy or sign-out. The loader and TV retain their own late-result fences.

Selection uses the model callback, not a shared preference or notification bus. `prepareTVLyrics()` republishes the current selected document under a fresh token when starting again after Stop, or schedules a load when needed. TV does not fetch its own baseline or generate a conversion.

## Bounds and Privacy

| Component | Bound |
| --- | --- |
| Composite variant discovery | Two coalesced active lookups, 16 waiters per lookup, at most three discovery sources after the baseline |
| Discovery deadline | 12 seconds total; baseline up to six seconds; each further source up to three seconds within the remaining deadline |
| Optional duration preparation | Existing metadata callback, normally up to one additional second, only when duration is missing; copies duration only from the same ID |
| LRCLIB alternatives | At most two searches; six-second client deadline; two concurrent variant calls; existing rate/cooldown and streamed 2 MiB response cap |
| JioSaavn adapter | Two active calls, one search page of at most 20 tracks, at most one lyrics fetch; existing transport request/retry/body/cache bounds in `JIOSAAVN.md` |
| Variant result | At most eight documents; each plain body and total line text bounded by `LRCParser.maximumSourceBytes` (512 KiB), at most 5,000 lines; copyright at most 4 KiB |
| Discovery cache | 32 recording entries or 4 MiB encoded documents, least recently used first; ten-minute positive / one-minute missing TTL; no errors or partial searches cached |
| Controller choices | 32 recording-metadata/language keys and content IDs, memory only; at most eight loaded variants |
| Cancellation | One cancelled waiter does not cancel others; the last waiter cancels discovery; a retired flight cannot cache or publish a late result |

The initial sheet baseline request precedes discovery. Successful baseline reads are normally reused from the existing composite cache. A baseline failure may be retried during discovery, so an unsuccessful initial load can spend the baseline budget plus the discovery budget. Missing duration may also require the bounded preparation above. No automatic polling is added.

Source requests contain the metadata needed to match the recording, or the provider's song ID. Lyrics and copyright remain in memory. New logging contains only counts, latency and closed enum values; no track names, artists, IDs, lyric text, user data or URLs are logged. The source attribution URL is opened only as a user action and must be HTTPS without embedded credentials. Credit text is rendered as text, not executable markup.

## Provider Evidence

Public research on 27 September 2026:

| Provider | Evidence | Available vs gated |
| --- | --- | --- |
| LRCLIB | The [public docs](https://lrclib.net/docs) timed out twice. The maintainer's [router](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/router.rs) confirms `/api/get`, `/api/get/:track_id` and `/api/search`; [search implementation](https://github.com/tranxuanthang/lrclib/blob/05ad8590f6fc4d47a2d74e70f4915273df20f63c/server/src/routes/search_lyrics.rs) confirms title/artist/album query fields and plain/synced results from each track's current lyrics. | Implemented using those existing endpoints. No live claim that a particular Punjabi recording currently has both scripts. The optional `lyricsfile` field is not parsed. |
| JioSaavn | A [direct call using the existing adapter's parameters](https://www.jiosaavn.com/api.php?__call=lyrics.getLyrics&lyrics_id=aRZbUYD7&_format=json&_marker=0&api_version=4&ctx=web6dot0) returned Latin-script plain lyrics, `lyrics_copyright: "Lyrics powered by JioSaavn"` and a tracking URL. Existing catalog call evidence is in `JIOSAAVN.md`. | Unofficial adapter installed for cross-source discovery. No script selector or guaranteed Gurmukhi coverage was observed. API availability does not establish distribution rights. |
| YouTube Music | Existing `YouTubeLyricsParser` and fallback tests validate the exact recording's lyrics-tab link and preserve LyricFind/Musixmatch credits. | Existing baseline and variant source retained. No direct publisher integration is implied by a footer. |
| Genius | [Official API documentation](https://docs.genius.com/) documents authenticated search/song metadata and annotations; commercial use requires a license. | Search/page links are not a licensed full-lyrics response. No Genius provider, token invention or page scraping added. |
| Musixmatch | [Official getting-started documentation](https://docs.musixmatch.com/lyrics-api/introduction) requires registration and an API key, with `track.search` and `track.lyrics.get` under its terms and implementation guidelines. | Direct integration is gated on credentials and applicable lyric display rights. Existing Musixmatch-via-YouTube attribution remains supported. |

Published-script availability is provider-controlled. The implementation cannot recover overwritten LRCLIB text, authenticate user-submitted wording, guarantee lyric language from Latin script, or turn ambiguous Roman Punjabi into a reliable original. Any future generated conversion needs an explicit Generated label and independent verification; no such conversion exists here.

## Metrics

All new events use the existing `LyricsDiagnostics` logger, subsystem `com.agraabhi.ganabajana`, category `Lyrics`.

| Fields | Emitted when | Dimensions | Purpose |
| --- | --- | --- | --- |
| `variantCacheHit`, `variantCacheMiss` | Discovery cache read | 0/1 counterparts | Cache use |
| `variantBaselineSuccess`, `variantBaselineFailure`, `outcome` | Baseline completes or fails during discovery | `LyricsKind` when successful | Distinguish content, instrumental, absence and failure |
| `variantSourceSuccess`, `variantSourceFailure`, `variantSourceTimedOut`, `candidates`, `latencyMs` | A discovery source completes or fails | Flags, usable-candidate count, milliseconds | Detect source failures without logging metadata |
| `variantCancelled=1` | Last waiter leaves a discovery flight | None | Cancelled work |
| `variantSelected=1`, `script` | Valid explicit selection | Closed `LyricsScript` enum | Script-choice use |

The existing LRCLIB/JioSaavn transport events continue to report bounded request outcomes. Tests exercise the branches; OSLog emission is not captured/asserted by these suites.

The audio-language accessor reuses existing `YouTubeDataAPI` cache-hit/coalescing, request-success/failure, cancellation and quota metrics. Tag normalization is a pure metadata projection and adds no logging of language codes, track values or users.

## Test Selectors and Verification

Core suite selectors: `GanaBajanaTests/LyricsVariantSelectionTests`, `GanaBajanaTests/LyricsVariantProviderTests`, `GanaBajanaTests/JioSaavnLyricsProviderTests`. Their executed R17 scope belongs in [VERIFICATION.md](VERIFICATION.md); the earlier uncompiled-worker status is superseded.

`YouTubeLyricLanguageCodeTests` covers normalized Punjabi/script tags and unchanged classification; malformed/type/64-byte boundaries; no inference from other fields; shared request/cache; eligibility; waiter cancellation; and missing metadata versus quota failure. Normalization/decoding cases are unit tests; request/cache/cancellation cases use mock URLSession for in-process integration. See Core-03 and regression scope in [VERIFICATION.md](VERIFICATION.md). Existing Data API and language metadata suites remain regression coverage.

| Cases | Coverage | Level |
| --- | --- | --- |
| `testPunjabiUnicodeAndLatinHaveHonestDistinctLabels`, `testRecordingLanguageComesFromInputOrTrackNeverArtist` | Gurmukhi/Latin, Shahmukhi code, mixed text, Unicode marks, unknown language and explicit metadata | Unit |
| `testOriginalScriptIsPreferredAndAnExplicitLatinChoiceSurvivesReload`, `testChoicesAreBoundedAndDoNotCrossRecordingMetadataChanges` | Preference, override retention, 32-choice bound and recording-key isolation | Unit |
| `testSwitchingUsesSelectedTimestampsAndClearsPlainTimingAndAttribution` | Active index, seek time, plain state, source/copyright and TV callback switch together | Unit |
| `testLateVariantsAndFailuresCannotReplaceANewerTrackOrClearedTVProjection`, `testClearRetiresAnOutstandingLookupAndPublishesNilForTV`, `testCancellationDuringDiscoveryKeepsBaselineAndDoesNotPublishLateChoice` | Old success/failure, cancellation, clear and stale selection fences | Unit |
| `testUnavailableInstrumentalFailureAndMalformedVariantsStayDistinct`, `testLegacyDocumentDecodesAndAttributionRoundTripsWithoutChangingIdentityOnRefresh` | State distinction, malformed IDs, backward decoding, credit fields and stable identity | Unit |
| `testLRCLIBSearchKeepsExactPunjabiScriptsAndUsesOnlyTwoDocumentedQueries`, `testLRCLIBCancellationAndMalformedSearchAreNotSuccessfulAbsence` | Strict matches, query budget, parameters, transport cancellation and malformed response | In-process provider integration with fake HTTP transport |
| `testVariantDiscoveryDoesNotRelaxSameScriptAmbiguityOrUnknownDuration`, `testPlainOriginalWithinATimedLatinRecordNeverBorrowsTiming` | Existing ambiguity fence and a record's independent plain/timed scripts | Unit |
| `testCombinedDiscoveryEnrichesAttributionAndCachesOnlyCompleteResults`, `testNoDataOutageWrongRecordingAndInstrumentalAreDistinct`, `testVariantCacheHonorsCapacityBytesAndExpiry` | Enriched credits, complete/partial cache policy, error vs absence, memory/TTL limits | Unit |
| `testCoalescedCancellationDoesNotCancelOtherWaitersAndLastCancellationCannotCache`, `testSourceTimeoutPreservesBaselineAndDoesNotCachePartialDiscovery` | Waiter isolation, late result fence and timeout degradation | Unit |
| `testCompositeDiscoversWithoutChangingLegacyFallbackOrderAndPreparesDurationOnly` | Optional protocol dispatch, added source and same-ID duration preparation | In-process provider integration |
| `JioSaavnLyricsProviderTests` matching/cancellation cases | Exact metadata, artist/version/duration/album/language rejection, ambiguity, ID rebinding, cancellation before fetch, wrong source response | Unit |
| `testExistingTransportFetchesPublishedLyricsWithCreditAndNoTrackingRequest`, `testFailureEnvelopeAndEmptyLyricsAreNoDataButMalformedPayloadIsAnError`, `testOversizedLyricsAndCopyrightAreRejected` | Actual adapter/transport composition, endpoint/header contract, credits, error envelopes and payload limits | Mock-URLSession integration and parser unit |

Retain regression selectors `CompositeLyricsProviderTests`, `CompositeLyricsMetadataTests`, `LyricsLoaderTests`, `LyricsMatchingTests`, `LyricsServiceTests`, `YouTubeLyricsTests`, `ArtistSpotlightLanguageTests`, `ArtistSpotlightLanguageServiceTests`, `JioSaavnTests` and the existing opt-in lyrics fallback/live suites. No live suite was run in this work.

UI identifiers: `lyrics.variantPicker`, `lyrics.variant.<document.selectionID>`, `lyrics.variants.loading`, `lyrics.variants.retry`, `lyrics.attribution`, `lyrics.copyright`. Existing synced/plain/line/instrumental/unavailable/retry identities remain. UI-02 passed targeted phone light/dark selection and source-text checks. VoiceOver/Dynamic Type, broader geometry, live provider availability and physical TV updates remain separate checks.
