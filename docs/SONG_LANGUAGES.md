# Recording languages

Artist spotlights open on the popular-song list. A compact **Languages** control opens filters, check/retry actions, and per-song source/correction buttons. With at least two confirmed recording languages, the control reads **Browse by language** and shows the number found. Suggestions and unknown songs do not count toward that threshold.

The browser opens only on a user action. Background results never expand it, collapse it, or select a different filter. A selected language or Unclassified filter can reach zero songs; it remains selected and offers **Show all songs**. Collapsing the browser retains the filter and displays its name in the compact control. Song context menus and a named accessibility action also open the correction sheet.

Popularity ordering and playback use the existing `ArtistSpotlight.sorted` and `visibleTracks` paths. Counts remain attached to provider recording IDs. Language browsing does not assign a language to the artist or change Home discovery preferences.

The refinements remain **uncommitted after `ebb5d5c`**. Scoped unit, fixture UI, and live verification are complete across the coordinator's recorded runs below. The earlier signed 1.0.0 (2) archive/IPA predates this work; [release status](app-store/RELEASE_STATUS.md) records the current unsigned Release build and historical baseline separately.

## Evidence and precedence

1. `LibraryStore.recordingLanguageOverrides` wins, including **Keep unclassified** and preserved unknown/future codes. Clearing a correction reveals the latest automatic result. Corrections are independent of in-flight network results.
2. Verified individual `Track.language` metadata can supply a result without a lyrics request.
3. A valid language-cache entry is reused. Otherwise, configured `YouTubeDataAPI` reads `snippet.defaultAudioLanguage` for the exact recording ID. A supported tag returns **YouTube audio language** before lyrics, MusicBrainz or recognition. Explicit unsupported/undetermined, mixed or nonlinguistic tags remain unclassified. Title/description `defaultLanguage` and site localization are never audio evidence.
4. When provider audio language is missing or fails, `ArtistSpotlightLanguageService` concurrently requests lyrics and optional MusicBrainz evidence. Lyrics use the existing `CompositeLyricsProvider`: matched LRCLIB text first, recording-linked YouTube Music text on the provider's existing fallback conditions. The API can supply a missing duration to a temporary lookup copy; existing valid durations win. LyricFind/Musixmatch attribution remains with the lyrics document; these are not direct publisher integrations.
5. `ArtistSpotlightLanguageSignals.combine` preserves explicit conflicts before considering positive fallback results. Different identified languages, multiple work languages, and confidently different lyric segments stay unclassified. Explicit unsupported/undetermined work language is not treated as absent metadata. Missing evidence can use another source; a network failure by itself is not negative language evidence.
6. Title labels and narrow script hints remain **Likely** suggestions. Only identified results enter language-specific filters. Artist name, nationality, region, album text language, and Latin title script are not recording-language evidence.

Identified MusicBrainz results retain both recording and work IDs in `.musicBrainzWork(recordingID:workID:)`. The correction sheet links to both entities. `.youTubeAudioLanguage` identifies the official audio-tag source and is accepted by the existing bounded derived cache for valid YouTube recording IDs. Lyric-derived results retain the matched/linked source distinction and are labelled as on-device inference. Result explanations distinguish uncertainty, insufficient text, lookup failure, and conflicting evidence. [YOUTUBE_DATA_API.md](YOUTUBE_DATA_API.md) owns API behavior and the six-recording comparison with ytmusicapi.

Recording languages are one of two learned dimensions; genre is the other ([GENRE_PROFILE.md](GENRE_PROFILE.md)). The genre profile reuses the same qualified plays and the same MusicBrainz search (title, artist, duration) but reads genre and tag votes on the recording, its release group and its artists rather than work languages, folds them into a bounded family taxonomy, and stores the result in a separate device-local file (`Application Support/GanaBajana/genres.json`) rather than the language cache. Genre evidence never feeds language classification or language filters, and a recording's language never feeds its genre. Its ranking term (1.0 to 1.15, Less 0.85, unclassified 1) multiplies the language weights in Home shelves and mixes and orders radio stations; [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md#recommendation-weights) records where it applies.

## Classifier changes

The classifier verifies document/provider identity, title, and compatible artist credits before reading lyrics. Synced original text takes precedence over an accompanying plain-text translation. Recognition uses Apple's unconstrained `NLLanguageRecognizer`; there are no song/artist priors or forced English language hints.

Whole-text and window recognition receive original punctuation, contractions, and line breaks. Lexical checks separately use normalized contraction expansions. Named section labels are removed without dropping text after an inline label, equivalent repeated lines are deduplicated, and lines consisting only of shared vocalizations supply no language evidence.

All languages use cores of up to **40 original words at a 20-word stride**. Each core must pass its own script and applicable English lexical checks. Only an ambiguous core with no confident alternative language code can receive **one** context retry, adding at most 20 original words on each side, preferring complete neighboring lines, for a maximum of **80 words**. The expanded sample must pass the same checks. Context cannot supply missing core lexical evidence, dilute a confident foreign result, or grow repeatedly until English wins.

| Recognition check | Minimum confidence | Required margin over next hypothesis |
| --- | ---: | ---: |
| Whole text | 0.92 | 0.20 |
| Core or expanded window | 0.88 | 0.20 |
| Credible conflicting segment | 0.95 | 0.20 |
| Recognizer-assisted sparse English line | 0.97 | 0.20 |

The independent segment-conflict veto runs before positive classification and window context. A credible foreign segment can veto English even when that language is outside the five filter choices. A confident alternative window below the conflict threshold still prevents a context retry and leaves the result uncertain. Supported languages must also pass their script check.

English requires lexical evidence across the document and windows. A line normally needs two distinct English function words at a lexical ratio of at least 0.12. A sparse line can reset the unsupported-word run with one non-ambiguous anchor only if its script passes and native English confidence meets 0.97 with the 0.20 margin. Zero-anchor lines and words shared with transliterations cannot use confidence alone. Consecutive unsupported lines totaling eight normalized words reject English classification. These checks do not identify a romanized Indian language from a word list.

The minimum remains 20 normalized words, 12 distinct words, and 80 letters after cleanup. Text longer than 12,000 characters stays uncertain instead of classifying a prefix that might omit a guest verse. Very short, fragmented, transliterated, or mixed songs can still remain unknown. The live examples below verify those recordings, not an English-catalog accuracy rate.

### Live evidence behind the lexical and context rules

For Kanye West's **All Falls Down (feat. Syleena Johnson)**, recording-linked lyrics produced **98.75% whole-text English confidence**. An eight-word line with one non-ambiguous anchor scored **98.48% English** but failed the previous two-word lexical gate. The recognizer-assisted rule permits that line while retaining the zero-anchor and foreign-segment checks.

A subsequent normalized 40-word fragment scored about **47% English**, with no confident foreign alternative. Recognition therefore retains original text in overlapping windows and permits the bounded context retry only after the core's lexical/script checks pass. The matched real recording classified as English in the final live run. These percentages are observed recognizer scores for specific text, not measured catalog accuracy.

## Public-source research

The following were public read-only observations on 2026-09-21. MusicBrainz requests used the app's published contact URL in the User-Agent and were spaced at least one second apart. Printed research output contained metadata, never lyric text.

### Documented contracts and terms

| Source | Verified documentation | Decision |
| --- | --- | --- |
| MusicBrainz work languages | [Work: lyrics languages](https://musicbrainz.org/doc/Work#Lyrics_languages), [API lookups and relationships](https://musicbrainz.org/doc/MusicBrainz_API#Lookups) | `language`/`languages` belong to the linked work. A translation is a distinct work. Follow an exact compatible performance link, never a work-title search. |
| MusicBrainz access | [API identification, rate limiting, and authentication](https://musicbrainz.org/doc/MusicBrainz_API#Application_rate_limiting_and_identification) | Public metadata reads require no API key. A meaningful User-Agent and at most one request per second are required. |
| MusicBrainz licensing | [Data license](https://musicbrainz.org/doc/About/Data_License), [core versus supplementary data](https://musicbrainz.org/doc/MusicBrainz_Database) | Core entity/relationship data is CC0; supplementary data has separate noncommercial/share-alike terms. API documentation separately directs commercial users to commercial plans. This implementation does not establish commercial API permission. |
| Wikidata | [P407](https://www.wikidata.org/wiki/Property:P407), [entity access, licensing, and request etiquette](https://www.wikidata.org/wiki/Wikidata:Data_access) | P407 describes a work/name's language. Structured data is CC0; exact entity JSON reads are documented. The observed exact links did not add usable coverage, so no Wikidata provider was added. |
| Apple Natural Language | [Identifying the language in text](https://developer.apple.com/documentation/naturallanguage/identifying-the-language-in-text.md) | Text hypotheses are inference. Keep the recognizer unconstrained and check segments rather than treating a dominant language as proof of a monolingual recording. |

### Live metadata observations

| Recording/query | Observation | Consequence |
| --- | --- | --- |
| Radiohead, [No Surprises search, 229 seconds](https://musicbrainz.org/ws/2/recording?query=recording%3A%22No+Surprises%22+AND+artist%3A%22Radiohead%22+AND+dur%3A%5B227000+TO+231000%5D&limit=20&fmt=json) | 38 results exceeded the 20-result response. The [inspected recording](https://musicbrainz.org/ws/2/recording/6bb29353-ba61-4c5a-85ff-f33693808dc3?inc=artist-credits%2Bwork-rels&fmt=json) also had a `live` performance attribute. | Neither a truncated search nor this version establishes a unique compatible studio recording. The [work](https://musicbrainz.org/ws/2/work/15cd1194-5633-3b5b-a68b-f8fffc213915?inc=url-rels&fmt=json) had `eng` but no Wikidata relation. |
| Kanye West, [Heartless search, 211 seconds](https://musicbrainz.org/ws/2/recording?query=recording%3A%22Heartless%22+AND+artist%3A%22Kanye+West%22+AND+dur%3A%5B209000+TO+213000%5D&limit=20&fmt=json) | Two same-title duration matches, plus an instrumental candidate. The [inspected recording](https://musicbrainz.org/ws/2/recording/986077d0-162b-43b3-b8ff-514cfd774eba?inc=artist-credits%2Bwork-rels&fmt=json) had a `live` performance attribute. | Remains ambiguous. Its [linked work](https://musicbrainz.org/ws/2/work/2c4d0ab9-8f9e-3cd2-b74e-3685c0003617?inc=url-rels&fmt=json) linked [Wikidata Q2075331](https://www.wikidata.org/wiki/Special:EntityData/Q2075331.json), which had no P407 statement. |
| Arijit Singh, [Tum Hi Ho search, 262 seconds](https://musicbrainz.org/ws/2/recording?query=recording%3A%22Tum+Hi+Ho%22+AND+artist%3A%22Arijit+Singh%22+AND+dur%3A%5B260000+TO+264000%5D&limit=20&fmt=json) | One recording candidate, but the [recording lookup](https://musicbrainz.org/ws/2/recording/3e5bc764-dfa4-454d-a2a9-0ee84ae35db2?inc=artist-credits%2Bwork-rels&fmt=json) linked two works. | Multiple works remain ambiguous even though both embedded values were `hin`. One [work](https://musicbrainz.org/ws/2/work/c7e2331f-4c0d-4542-a69e-b4afd203ecfb?inc=url-rels&fmt=json) linked [Q15322556](https://www.wikidata.org/wiki/Special:EntityData/Q15322556.json), whose P407 was [Hindi, Q1568](https://www.wikidata.org/wiki/Special:EntityData/Q1568.json). That did not resolve the recording/work ambiguity. |
| Kanye West, [I Wonder search, 243 seconds](https://musicbrainz.org/ws/2/recording?query=recording%3A%22I+Wonder%22+AND+artist%3A%22Kanye+West%22+AND+dur%3A%5B241000+TO+245000%5D&limit=20&fmt=json) | The sole eligible candidate's [recording lookup](https://musicbrainz.org/ws/2/recording/f4d13637-f991-4932-aa4e-9d56529e8f3c?inc=artist-credits%2Bwork-rels&fmt=json) had no work relation. | There is no exact work ID to fetch. |
| Radiohead, [Everything in Its Right Place search, 251 seconds](https://musicbrainz.org/ws/2/recording?query=recording%3A%22Everything+in+Its+Right+Place%22+AND+artist%3A%22Radiohead%22+AND+dur%3A%5B249000+TO+253000%5D&limit=20&fmt=json) | One eligible candidate among six results. [Recording 60bd9d53-01ff-4562-8058-eb44b3940317](https://musicbrainz.org/ws/2/recording/60bd9d53-01ff-4562-8058-eb44b3940317?inc=artist-credits%2Bwork-rels&fmt=json) linked one compatible Song work with no performance attributes. | Both embedded metadata and the [full work lookup](https://musicbrainz.org/ws/2/work/9dfa4a7e-5993-3c95-b41e-e6a66b777044?fmt=json) returned `language: eng`, `languages: [eng]`. This is a useful recording-specific metadata example. |

The observed embedded work objects already included language fields. An extra full-work fetch therefore has no demonstrated coverage gain for those examples. The implemented fallback handles a compatible link whose embedded fields are missing or empty. It uses the documented work endpoint and has fake-backed recovery tests; its incremental live recovery rate is unverified. It cannot fix absent links, ambiguous recordings, or multiple works.

During the initial research, direct LRCLIB documentation/record requests could not complete; the bounded curl read reported DNS resolution timeout. That was an access observation, not evidence that a song had no lyrics. Subsequent app-level live lyrics checks completed through the existing Composite provider, as recorded below.

## Lookup bounds and privacy

| Layer | Bound |
| --- | --- |
| Loader | 12 automatic checks, 12 per manual batch, two concurrent classifications, 36-second batch deadline |
| Language service | Six seconds overall, including up to two seconds for explicit recording metadata; fallback sources get up to 5.5 seconds within that original deadline; two active lookups and 12 waiters per lookup |
| Classification cache | 256 recording-and-metadata keys; identified results 12 hours, unclassified/suggestions five minutes |
| MusicBrainz | Six-second provider deadline shared across search, recording, and optional work lookup; at most three requests, each at most three seconds; shared one-request-per-second limiter; two MiB response cap enforced while receiving |
| MusicBrainz cache | 128 recording-and-metadata keys; identified results 24 hours, missing/uncertain/conflicting results 15 minutes |

The service's outer deadline still bounds both sources together. A source timeout can return useful independent evidence from the other source. Transport errors remain retryable and do not become cached misses. Explicit conflicting evidence can be cached as unclassified even when the other source fails. Last-waiter cancellation retires the classification flight and cancels both source branches; stale completions cannot publish into a replacement flight. A cancelled MusicBrainz lookup does not insert a negative result.

The conditional work operation is `GET https://musicbrainz.org/ws/2/work/<exact-linked-work-ID>?fmt=json`. Its ephemeral session has no cookie/credential storage or URL cache. The separate official YouTube metadata path uses `www.googleapis.com` and the app-restricted project key; it adds no on-server lyrics analysis. MusicBrainz still sees normal request information, the app/contact User-Agent, search metadata, and requested entity IDs. Anonymous session configuration does not make requests unidentifiable.

Browser inference and expansion remain memory-only; listening-led checks can use the separate bounded derived cache described in [LISTENING_DISCOVERY.md](LISTENING_DISCOVERY.md). Corrections use the saved library and its backup behavior. Production language logs contain fixed outcome counters and latency, not lyric text, titles, artists, or entity IDs. The conditional work-ID disclosure in [PRIVACY.md](../PRIVACY.md) is included in the September 23 publication recorded by [PUBLIC_PAGES.md](app-store/PUBLIC_PAGES.md).

### Metrics

These are local `ArtistSpotlight` OSLog diagnostics, not remote telemetry. No new dimensions are introduced.

| Counters | Emitted when |
| --- | --- |
| `musicBrainzCacheHit`, `musicBrainzCacheMiss` | Metadata-provider cache lookup |
| `musicBrainzWorkFetch` | A matched recording's work is evaluated; 1 for the extra hop, 0 for embedded evidence or an incompatible/missing link |
| `musicBrainzMatched`, `musicBrainzUnknown`, `musicBrainzConflict` | Completed metadata lookup, with identified/unknown/conflicting outcomes distinguished |
| `lyricsSourceFailure`, `metadataSourceFailure`, `languageConflict` | Source results are combined |
| `providerLanguageUsed`, `classificationSkipped`, `providerLanguageFailure` | Explicit audio metadata selects the shortcut or fallback; API request/cache counters are in `YOUTUBE_DATA_API.md` |
| Existing `languageSuccess`, `languageFailure`, `languageCancelled`, `timedOut`, `latencyMs` and request/cache counters | Existing classification completion, cancellation, cache, and transport paths |

Unit cases cover branch behavior but do not assert OSLog output. The live diagnostic attachments used in the investigation are separate from these production counters.

`englishLexicalInspection` exists only under `DEBUG` and is called only by tests. It reuses production identity validation and text cleanup, inspects at most 128 retained lines, and returns numeric/Boolean evidence such as word counts, confidence, gate results, and the first unsupported run. It returns no lyric text and reports omitted lines without assigning them a diagnostic verdict. The inspection is excluded from Release and does not alter classification.

## Coordinator integration and verification

### Implementation and test files

| Area | Files |
| --- | --- |
| Evidence | `Sources/Catalog/ArtistSpotlightLanguageClassifier.swift`, `Sources/Catalog/ArtistSpotlightLanguageService.swift`, `Sources/Catalog/ArtistSpotlightLanguageSignals.swift`, `Sources/Catalog/ArtistSpotlightMusicBrainz.swift` |
| Model | `Sources/Core/ArtistSpotlight.swift` |
| UI | `Sources/Views/ArtistSpotlightLoader.swift`, `Sources/Views/ArtistSpotlightView.swift`, `Sources/Views/ArtistSpotlightSongRow.swift`, `Sources/Views/CollectionDetailView.swift` |
| Existing unit suites/support | `Tests/ArtistSpotlightLanguageTests.swift`, `Tests/ArtistSpotlightLanguageServiceTests.swift`, `Tests/ArtistSpotlightMultiSignalTests.swift`, `Tests/ArtistSpotlightMusicBrainzTests.swift`, `Tests/ArtistSpotlightOverrideTests.swift`, `Tests/ArtistSpotlightTestSupport.swift` |
| New unit/live suites | `Tests/ArtistSpotlightLanguagePresentationTests.swift`, `Tests/ArtistSpotlightMusicBrainzWorkTests.swift`, `Tests/ArtistSpotlightLanguageLiveTests.swift` |
| UI suites | `UITests/GanaBajanaArtistSpotlightUITests.swift`, `UITests/GanaBajanaLanguageCorrectionUITests.swift` |
| Domain record | `docs/SONG_LANGUAGES.md` |

`MusicAppModel` supplies the shared API actor through `recordingMetadataLookup` and lookup preparation. `ArtistSpotlightLoader` uses that language service; the existing MusicBrainz fallback still requires its configured public contact URL. The API adds `.youTubeAudioLanguage` provenance, while the five supported language choices remain unchanged.

| API | Change |
| --- | --- |
| `ArtistSpotlightLanguageService.Configuration.sourceTimeout` | New defaulted 5.5-second per-source bound |
| `ArtistSpotlightMusicBrainz.workLanguage(in:recordingID:for:fetchedWork:)` | Defaulted optional full-work payload, validated against the original recording/link and combined with any explicit embedded codes |
| `ArtistSongLanguageResult.hasConflictingEvidence`, `.explanation` | Conflict precedence and source/uncertainty copy |
| `ArtistSpotlightLoader.isBrowsingLanguages`, `.hasUsefulLanguageFacets`, `.languageControlTitle` | Explicit presentation state and confirmed-language threshold |
| `ArtistSpotlightLoader.overridesChanged()` | Removed along with its owned call sites. Results and filter choices observe the library directly; corrections no longer trigger automatic filter resets. |
| `ArtistSpotlightLanguageClassifier.englishLexicalInspection(_:for:hypotheses:)` | DEBUG-only, test-called numeric/Boolean inspection with shared cleanup and a 128-line bound |

New accessibility identifiers: `artist.spotlight.browseLanguages`, `artist.spotlight.emptyFilter`, and `artist.spotlight.showAll`. Existing filter, correction, playback, and queue identifiers remain available in their relevant views.

The new test files are `Tests/ArtistSpotlightLanguagePresentationTests.swift`, `Tests/ArtistSpotlightMusicBrainzWorkTests.swift`, and `Tests/ArtistSpotlightLanguageLiveTests.swift`. Coordinator builds included them through the existing `Tests` directory configuration. Selector-based live verification must include `ArtistSpotlightLanguageLiveTests` explicitly.

### Coverage

| Selector | Cases | Type |
| --- | --- | --- |
| `GanaBajanaTests/ArtistSpotlightLanguageTests` | Native sparse-English acceptance and low-confidence uncertainty; strict injected confidence/margin/anchor checks; original-text overlapping windows and one bounded context retry; core lexical rejection and foreign-context vetoes; DEBUG inspection cleanup/bounds; rap/rock, contractions, transliteration, guest segments, identity/script/translation checks | Unit |
| `GanaBajanaTests/ArtistSpotlightLanguageServiceTests` | Either source stalling; explicit conflict with failed peer and negative-cache expiry; mixed work veto; both-source cancellation; existing coalescing, metadata-first, capacity, deadline, and stale-completion checks | Unit |
| `GanaBajanaTests/ArtistSpotlightMusicBrainzTests` | Existing recording ambiguity, version/credit/duration mismatches, source IDs, rate limiting and request identity; inconsistent search counts; explicit multilingual evidence | Unit |
| `GanaBajanaTests/ArtistSpotlightMusicBrainzWorkTests` | Exact third-hop URL/provenance; plural/legacy/conflicting/unsupported fields; incompatible/multiple relations; wrong work/title/version; negative cache; malformed response retry; cancellation and original deadline | Unit |
| `GanaBajanaTests/ArtistSpotlightMultiSignalTests` | Conflict retention before metadata/lyrics/title fallback; unsupported work language; existing suggestion/linked-identity/automatic-batch bounds | Unit |
| `GanaBajanaTests/ArtistSpotlightLanguagePresentationTests` | Unknown, monolingual, multilingual, and empty catalogs; late results; retained empty Unclassified/language filters; explicit browser state; manual correction and clear; popularity/collection scope | Unit |
| `GanaBajanaTests/ArtistSpotlightOverrideTests` | Durable corrections and future codes; correction during an older lookup; clearing a correction without silently changing selection | Unit |
| `GanaBajanaTests/ArtistSpotlightTests`, `GanaBajanaTests/ArtistSpotlightLoaderTests` | Existing popularity/filter ordering, incremental batches, failure retry, generation/cancellation behavior | Unit regression |
| `GanaBajanaTests/ArtistSpotlightLanguageLiveTests` | Catalog-matched Kanye West/Radiohead lyrics; Hindi/transliteration not certified English; mismatched recording rejected; exact observed MusicBrainz recording/work JSON contract | Live integration |
| `GanaBajanaUITests/GanaBajanaArtistSpotlightUITests` | Opt-in browser and hidden default annotations; collapse/reopen retaining Hindi selection; manual correction and clear through the sheet; existing sorted/filtered Play, Shuffle, queue, and playlist workflow; artist-page **Featuring** section with two search-only collaborations (fixture counts All 22 / Unclassified 17) | Fixture UI integration |
| `GanaBajanaUITests/GanaBajanaLanguageCorrectionUITests` | Correction persists across relaunch and can be cleared independently | Fixture UI integration |

Live tests require `GANABAJANA_LIVE_TESTS=1`. Missing public lyrics explicitly skip the relevant test. Usable English lyrics producing an unknown language fail rather than being skipped. Network and contract failures remain visible; public lyric text is neither printed nor saved as a fixture. The pinned MusicBrainz contract test uses a MusicBrainz recording identity, not a made-up YouTube-to-MusicBrainz mapping.

### Coordinator runtime results

| Run / scope | Result | Boundary |
| --- | --- | --- |
| `Breezy-Refinements-Language-Final-04` | **36/36 unit cases passed** | Final classifier cases, including separate native high-confidence acceptance and low-confidence uncertainty; strict injected thresholds retained |
| `Breezy-Refinements-Language-08`, live subset | **4/4 live cases passed** | Kanye West's All Falls Down (feat. Syleena Johnson), Radiohead's No Surprises, Hindi/transliteration not certified English, and the exact MusicBrainz recording/work contract |
| `Breezy-Refinements-Language-08`, entire bundle | **38 passed, 1 failed** | The failure was a native unit fixture's incorrect confidence assumption, subsequently corrected and covered in Language-Final-04; this was not a failed live case |
| `Breezy-Refinements-UI-01`, language UI | **Two spotlight workflows and one separate correction workflow passed** | Browser/filter/playback behavior and persisted correction/clear |

The sole failure in the final whole-unit run, `Breezy-Refinements-Unit-Final-02` (**929 passed, 1 failed, 33 skipped**), was the same new native fixture assumption. An ambiguous repetitive-pronoun phrase did not meet `NLLanguageRecognizer`'s confidence threshold. The fixture was split into an explicit low-confidence/unclassified case and a separate sparse-English acceptance case. This was a test correction, not a production regression or threshold relaxation.

Independent review cleared the P2 foreign-segment veto and the raw-context logic. `Breezy-Refinements-Release-02` passed after the final production changes as an **unsigned generic-device Release build**. No current archive/export was produced. [VERIFICATION.md](VERIFICATION.md) and [REVIEW_FINDINGS.md](REVIEW_FINDINGS.md) remain coordinator-owned. The evidence spans runs, not one green full suite, and establishes no catalog-wide accuracy guarantee or incremental live work-fetch recovery rate.
