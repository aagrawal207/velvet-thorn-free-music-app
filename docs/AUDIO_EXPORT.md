# Compatible Audio Export

## Contract

`AudioExporter` produces a tagged AAC-LC `.m4a` from a complete local file. Success requires verified audio and metadata; unsupported or damaged input has no original-file fallback. R18 integrates timeline-aware verification, reason-specific errors, the artwork resolver and embedded-cover sharing. The coordinator reports passing Core-02, Regression-01 and phone UI-02 export/extractor scopes after the corrections below. Verification is still in progress. [VERIFICATION.md](VERIFICATION.md) owns counts and receipts, including historical R17 results and R18 Build-05/Core-01 failures.

The exporter reads the asset's audio format descriptions, not the file extension, `CachedAudio.quality`, or cached/catalog duration. It accepts one audio track, no video, one or two channels, a finite sample rate from 8 through 192 kHz, and the existing `PlaybackTiming.validDuration` bounds. Unsupported channel layouts fail rather than silently downmixing.

Asset creation reads only the first 12 file bytes and reuses `AudioDownloader.looksLikeMedia` to recognize RIFF/WAVE and MP4 `ftyp` headers. Recognized containers receive `AVURLAssetOverrideMIMETypeKey` (`audio/vnd.wave` or `audio/mp4`) on every inspection, passthrough, encoding and verification open. This prevents a misleading extension from selecting the wrong native parser before format descriptions can be loaded. The header selects a container parser, not a codec; native format inspection and output verification still determine the audio format. Other containers retain AVFoundation's normal handling.

- **AAC-LC:** attempt `AVAssetExportPresetPassthrough` with tags. If export or readback fails within its 20-second budget, drain that attempt, delete its private output, and encode from the source. AAC passthrough retains compressed samples when the native container writer supports it.
- **Other native-decodable audio, including PCM and prepared Opus in MP4:** `AVAssetReader` decodes linear PCM and `AVAssetWriter` explicitly encodes `kAudioFormatMPEG4AAC` into M4A. Encoding uses the source's mono/stereo channel count, 44.1 kHz for a 44.1-kHz source and 48 kHz otherwise, with a 128-kbps mono or 256-kbps stereo target. The bitrate is an encoding target, not a fidelity improvement or a measured guarantee.
- **Unavailable native decoder or encoder:** return an error. The exporter does not remux WebM, invoke FFmpeg, fetch audio, or modify the cached/downloaded original. Existing prepared MP4 fixtures exercise Opus without any bridge invocation.

Title and artist come from `Track.title` and `Track.artistName`. A nonempty `Track.albumTitle` becomes the album tag. Supplied artwork must be valid and survive readback; malformed artwork fails rather than disappearing silently. `artwork: nil` is accepted only when the track has no known artwork URL. A known URL without supplied bytes fails with `artworkUnavailable`, including callers that still silently map a loader failure to nil. The exporter does not invent an album or a cover when metadata is absent.

## Verification Before Publication

Every successful output is reopened independently. Verification requires:

1. A nonempty file, exactly one audio track, no video, and AAC-LC format descriptions.
2. Finite, positive asset duration matching the inspected source duration. Tolerance is 1% clamped to 150 ms through one second, with an additional 80% minimum-duration floor for short clips.
3. Exact Unicode title, artist and supplied album readback from the iTunes metadata identifiers. Text is written with the UTF-8 metadata type. Supplied JPEG bytes must match the embedded `iTunesMetadataCoverArt`, carry the JPEG metadata type and pass ImageIO validation. Verification returns those read-back bytes for the result and share preview.
4. PCM decoding through the end of the output and a completed reader. Every media-bearing buffer must contain ready linear PCM and the expected frame payload. Zero-sample, zero-payload marker buffers are allowed; marker-only output cannot pass. Raw duration must agree with frame count/sample rate to one frame. Output duration and timestamps must be numeric; invalid trims and overlapping presentation intervals beyond one frame fail.
5. Decoded playable intervals, clipped to the nonempty track edit ranges, must cover their declared media duration under the existing tolerance and 80% floor. Source and output asset durations are checked separately. Output nonempty edit duration must not be shorter than the source nonempty edit duration beyond that tolerance/floor; an encoder may render an empty edit as silence. Priming and end padding are handled once by Core Media's output timing APIs.

Validation checks file compatibility and decodability. It does not establish perceptual quality or support in every recipient application.

### R18 Timing Diagnosis

`CMSampleBufferGetOutputDuration` is not itself the wrong API. Apple's `CMSampleBuffer.h` defines it as `(duration - trimStart - trimEnd) / speedMultiplier`. `GetOutputPresentationTimeStamp` provides the presentation position after trims/edit mapping. Summing output durations loses empty edit intervals and cannot be compared directly to an asset's whole timeline. A 3-second recording beginning at 2.25 seconds has about 3 seconds of decoded media and a 5.25-second asset timeline. Both are valid. The earlier encoder also started its writer session at the first decoded timestamp, removing that offset while verification still expected the original asset duration.

`AudioExportPCM` checks the presentation intervals against `AVAssetTrack.segments` target ranges, excluding `isEmpty` segments. With no segment table it uses the track time range. The encoder starts at asset time zero and ends at the asset duration, preserving empty leading/trailing edits. Internal empty edits may remain edits or become encoded silence. Decoder control markers are excluded from payload checks, while every nonzero frame count still requires actual PCM. Declared media coverage, the source duration checks and reader completion remain mandatory.

For a 1,024-frame buffer at 48 kHz with 211 priming frames, output duration is `813/48000` seconds, not `1024/48000` and not `602/48000`. The regression fixture combines this with a final 137-frame trim and a permanent-empty marker. The expected total is exactly `1700/48000` seconds. Coordinator Core-01 passed this Core Media test and the native PCM test with a 2.25-second leading empty edit. The user's failing asset has not been supplied.

## Integrated APIs

```swift
let exporter = AudioExporter() // Keep one model-owned instance.
let result = try await exporter.export(
    track: track,
    source: source,            // CachedAudio held under the cache's reading lease.
    artwork: coverJPEG         // Data?; nil only when the track has no known artwork URL.
)
```

`AudioExport` retains `url`, `bytes`, `tagged`, `codec`, `transcoded` and `hasArtwork`, and adds `artworkJPEG: Data?`. Exporter-created success always has `tagged == true` and `codec == .aac`. `hasArtwork` and `artworkJPEG` derive from native cover readback, not a supplied URL or fetch attempt. `transcoded == false` identifies verified AAC passthrough; `true` identifies native AAC encoding. Existing result construction remains source-compatible through defaulted arguments.

### Larger Artwork

`MusicAppModel.exportAudio(for:)` calls the integrated resolver before acquiring the audio reading lease:

```swift
let coverJPEG = try await AudioExportArtworkResolver.resolve(for: track)
```

The earlier model used `image.map`, so a loader failure silently became nil artwork. `ArtworkLoader.image` intentionally returns nil for HTTP/decode failure, cache clearing and cancellation. The resolver distinguishes caller cancellation, genuinely absent `Track.artworkURL`, and exhaustion of a known URL. An absent URL returns nil without requests. A known URL that cannot be loaded throws `artworkUnavailable`, which the export page displays with Try Again; it does not produce a coverless file.

The resolver tries the existing large, standard and thumbnail tiers, skipping tiers whose candidates have already all been attempted. YouTube tries maxresdefault/sddefault/hqdefault through the loader, then mqdefault if needed. Googleusercontent/ggpht can fall back from large to smaller sized URLs. Other hosts with one unchanged candidate get one attempt. A stale recording URL can still fail all sizes; there is no album search, new provider, URL scraping or synthetic cover. The caller supplies known track metadata; the resolver cannot discover artwork for a nil URL.

The loader owns provider size candidates, bounded transfers, waiter cancellation and image coalescing. Its response and decoded caches are reused, and each candidate keeps the loader's 30-second resource and 12-MiB transfer bounds. The resolver adds at most three tiers, four distinct URLs for supported YouTube URLs or three for sized Google URLs; there is no independent transfer implementation. `cachedThumbnail` clamps to widget bounds and is unsuitable for export. Artwork fetching precedes the exporter's 120-second audio-operation budget.

`AudioExportArtwork.jpeg(from: UIImage) throws -> Data` handles orientation, opaque rendering and JPEG compression. `prepare(_ data: Data) throws -> Data` accepts image bytes and downsamples through ImageIO. The export entry point applies `prepare` itself, so callers cannot bypass the output bounds. Both paths cap covers at 1,024 pixels on the longest edge and 512 KiB, with bounded quality/size retries. Byte inputs are capped at 12 MiB. `isValid(_:)` checks JPEG type, completeness, dimensions and actual decoding. A compliant JPEG is retained byte-for-byte.

### Source Reading Lease

`MusicAppModel.exportAudio(for:)` holds `downloads.withLocalCopy(for:operation:)` around the whole export. `DownloadCenter` and `DownloadManager` forward to `AudioCache.withLocalCopy`, which registers its reader before selecting the source, retains the selected URL, and releases the lease after the operation returns or throws. Artwork is fetched before this scope:

```swift
guard let result = try await downloads.withLocalCopy(for: track.id, operation: { source in
    try await exporter.export(track: track, source: source, artwork: coverJPEG)
}) else { throw AudioExportError.noLocalCopy }
```

Calling `preparedEntry` or `downloads.localCopy` before export is insufficient because those calls do not retain a reader across the subsequent export operation. A separate `pin`/`unpin` pair is not an independent reader lease because playback replaces the pinned set. Do not wrap export in `PlaybackDeadline.run`: that helper can return before its worker stops reading. `AudioExporter` owns a draining deadline. The coordinator's lease/model implementation was inspected but not modified during the export corrections.

### Sharing and Copy

Keep the returned `AudioExport` alive until the share activity finishes, rather than retaining only its URL. Copies of the result share a reference-counted pruning lease. A result can outlive one hour and still remain protected. The lease protects the exported file only; the source reading lease ends after export returns.

`AudioExportView` describes the actual result:

- Passthrough: “Original AAC preserved”.
- Encoded: “Converted to AAC”.
- Tags and artwork are reported from `tagged` and `hasArtwork`; missing artwork is not claimed as embedded.
- Missing artwork explicitly reads “No cover art available”. Successful cover verification shows the actual read-back image at `export.cover` and explains recipient-app behavior at `export.coverEvidence`.

Share File (`export.share`) presents `AudioExportShareSheet` with `AudioExportShareSource`, a `UIActivityItemSource`. Its placeholder and actual activity item are the same M4A URL, with the `public.mpeg-4-audio` type. `LPLinkMetadata.imageProvider` and `iconProvider` serve the verified JPEG bytes, and the thumbnail callback returns that image. No separate image attachment is shared. The native activity's completion closure retains the result lease if the SwiftUI page disappears.

`AudioExportShareSource` is a final, non-actor-isolated class with checked `Sendable` conformance and immutable stored properties. The SDK marks `UIImage` Sendable; the stored preview is decoded once from the verified JPEG. UIKit may invoke any item-source callback on a background queue. Callbacks read the immutable result and construct fresh metadata/providers per invocation; they do not access controller state. There is no `@preconcurrency` conformance or assumed actor isolation. `AudioExportShareSheet` remains main-actor isolated because it creates the view controller.

Embedded artwork and destination presentation are separate observations. Read-back `iTunesMetadataCoverArt`, JPEG type, ImageIO decode and byte equality establish the file contains the expected cover. Matching preview-provider bytes establish which image Velvet Thorn supplies to the share sheet. A destination can still ignore the metadata or use its own generic file preview. No destination-app display acceptance has been established for R18. Byte equality remains enforced: code inspection found no evidence that the native writer legitimately rewrites JPEG bytes, so it was not replaced with a permissive “any decodable image” check.

## Bounds, Cancellation and File Lifetime

| Resource | Bound / behavior |
| --- | --- |
| Whole audio operation | 120 seconds, including artwork byte processing, inspection, passthrough, encoding and validation; a caller may inject a shorter timeout |
| AAC passthrough plus its validation | 20 seconds within the whole-operation budget; fallback gets only the remaining whole-operation time |
| Admission | At most two in-flight operations per exporter instance; the third fails with `.busy` |
| Samples | One PCM buffer at a time; backpressure sleeps for 5 ms, cancellation checks between buffers, scheduler yields every 32 buffers |
| Native cancellation | Reader reads/setup and writer appends/setup are serialized with native cancellation, following Apple's prohibition on concurrent cancellation and sample access |
| Timeout return | Deadline requests cancellation and waits for native work to drain before returning; a stuck platform call can extend drainage beyond the nominal deadline, but cannot publish success after expiry |
| Paths | `tmp/Export/<UUID>/<artist> - <title>.m4a`; unique request directories across instances, no shared title-based destination |
| Filename | Sanitized separators/control characters, at most 120 characters and 240 UTF-8 bytes before `.m4a` |
| Failure cleanup | Removes only the request's directory after its native work drains; a failed passthrough file is removed before encoding |
| Pruning | One-hour age, owned UUID directories and legacy `.m4a`/`.wav` files only; active/retained result directories, symlinks and unrelated files are skipped |

`AudioExportError` retains its legacy cases and adds `artworkUnavailable` and `failed(stage:reason:)`. Bounded stages are inspect, passthrough, encode, verify and publish. Reasons distinguish native failures, empty files, output format, container duration, title/artist/album, missing/wrong-type/mismatched cover, decoder start/read, PCM payload/timing and PCM duration. Visible copy names the failed check, offers retry guidance and carries a short code such as `verify/pcm_duration`. Raw native error text is never shown by the exporter. Caller cancellation remains `CancellationError`, including native errors caused by cancellation. Partial files never become returned URLs. Foreground/background policy stays coordinator-owned; a backgrounded native writer may fail and remains retryable.

## Metrics

Events use the existing `Logger(subsystem: "com.agraabhi.ganabajana", category: "Downloads")`. No titles, IDs, paths, URLs, image data or raw platform errors are logged. Bytes are numeric measurements, not dimensions.

| Event | Emitted when | Bounded dimensions | Why |
| --- | --- | --- | --- |
| `export_input` | Source inspection succeeds | `codec=aac\|other` | Distinguish eligible passthrough from native-conversion inputs |
| `export_passthrough_failed` | AAC passthrough or validation fails before conversion | Bounded `reason=<stage>/<reason>` from `AudioExportError.diagnostic` | Identify why native encoding was needed |
| `export` | Successful publication | `outcome=ok`, `codec=aac`, `tagged=1`, `mode=passthrough\|encode`, `artwork=0\|1`; numeric `bytes` | Report actual successful output, including both mode/cover outcomes |
| `export` | Failure, expiry or caller cancellation after admission | `outcome=failed\|timeout\|cancelled`, bounded diagnostic `reason`, `bytes=0` | Distinguish stage/check failure from timeout and cancellation |
| `export_artwork` | Resolver completes a lookup decision | `outcome=unknown\|loaded\|unavailable` | Distinguish absent metadata from a failed known URL |
| `export` | Concurrency rejection | `outcome=busy`, `bytes=0` | Show admission pressure |
| `export_pruned` | At least one stale export is removed | Numeric `count` | Temporary-storage cleanup |

Pre-cancelled calls exit before admission and emit no event. OSLog emission is not intercepted by these tests.

## Test Coverage

The R17 cases below are in `Tests/AudioExporterTests.swift`. Native-media cases are local integration tests even though they live in the XCTest unit-test target. Each test owns an isolated temporary directory; no test removes the application's shared export directory.

| Test | Branch/path | Unit or integration |
| --- | --- | --- |
| `testAACPassthroughPreservesPacketsAndReadsBackAllTagsAndCover` | Generated local AAC; compressed-packet SHA-256, byte-count and sample-count equality, full tag/cover readback, PCM decoding, source unchanged; zero-sample marker buffers are excluded from the fingerprint | Integration |
| `testActualAACOverridesWrongSidecarCodecAndWavExtension` | AAC content with `.wav` name and Opus sidecar; bitstream preservation | Integration |
| `testPCMWithM4ANameAndAACSidecarIsActuallyEncodedToAAC` | The same generated PCM bytes under both `.wav` and misleading `.m4a` names, with an AAC sidecar; real AAC output, tag/PCM readback, preserved original and stale duration ignored | Integration |
| `testFailedAACPassthroughFallsBackToNativeEncodingWithTags` | Injected passthrough failure, real native encoder, cover and tags retained | Integration |
| `testGeneratedOpusFixturesConvertToTaggedAACOnSupportedRuntime` | Existing generated 160/256-kbps Opus MP4 fixtures; actual AAC output, cover/tags, eight-second duration and intact source | Integration; skipped below supported native Opus runtime |
| `testDamagedAndEmptyAudioFailWithoutPublishingOrChangingSource` | Empty, invalid and truncated containers; no copy fallback | Integration |
| `testUnsupportedMultichannelPCMIsRejectedTruthfully` | Generated six-channel PCM; explicit unsupported error and no publication | Integration |
| `testInvalidArtworkFailsInsteadOfSilentlyDroppingCover` | Invalid supplied cover fails and cleans its request | Integration |
| `testCancellationAfterEncodingDrainsAndRemovesUnpublishedOutput` | Real PCM encoding followed by gated verification; cancellation drains and removes written bytes | Integration with deterministic stage gate |
| `testDeadlineDrainsAndRemovesPartialFilesWithoutLatePublication` | Gated inspection with a partial-file sentinel; short deadline drains and cleans | Unit with real files |
| `testPreCancelledAndZeroDeadlineCallsCreateNoOutput` | Cancellation before admission and zero-budget expiry | Unit with generated local source |
| `testConcurrentSameTitleExportsHaveIndependentFilesAndActiveSharesSurvivePruning` | Two real exports with identical names, separate paths, byte preservation through stale pruning | Integration |
| `testConcurrencyLimitRejectsThirdRequestWithoutTouchingActiveFiles` | Two gated active operations, third rejected, active directories protected, cleanup after cancellation | Unit with real files |
| `testVerifierRejectsMissingTagsWrongMetadataAndWrongDuration` | Independent verifier rejects absent/wrong tags and truncated duration | Integration |
| `testExportCoverUsesLargeJPEGAndHonoursPixelAndByteBounds` | Large PNG to valid JPEG, aspect ratio, 1,024-pixel bound, byte cap, invalid/oversize input | Unit with ImageIO/UIKit |
| `testFileNamesAreSanitisedAndBoundedInCharactersAndUTF8Bytes` | Path tricks, hidden names and multi-scalar Unicode | Unit |
| `testPruningRemovesExpiredReleasedExportsButKeepsFreshAndUnrelatedFiles` | Retained result protection, release, expiry and ownership filtering | Integration with real exported file |

## Verification Status

### R18 Regression Coverage and Core-01 Corrections

The historical `artifacts/R18/Core-01.log` and `.xcresult` passed the native mono/stereo 44.1/48-kHz PCM matrix, nonzero PCM timeline, Opus, trim/coverage and loader fallback cases. The failures below remain failures of that run. The coordinator reports the corrected Core-02 scope passing; [VERIFICATION.md](VERIFICATION.md) owns the rerun record. `AudioExporterTests/testVerifierRejectsMissingTagsWrongMetadataAndWrongDuration` expects specific title/duration reasons; its independent native reader permits only zero-count markers to bypass payload assertions.

| Core-01 failure | Evidence and correction |
| --- | --- |
| `testNativeAACEditListWithLeadingAndInteriorGapsPassesBothExportPaths` | The seed AAC export succeeded. At the fixture helper's Build-05 line 422, `AVAssetExportPresetPassthrough` rejected the two-cut AAC composition as M4A with AVFoundation `-11838`, underlying `-16976`. No edited source was produced and neither production export branch was reached. That generator is replaced by an independent `AVAssetWriter` AAC source with input PTS/session origin 2.25 seconds, one contiguous native media edit and 3 seconds plus 137 PCM frames. Its file timeline is checked at `3 + 137/44100` seconds before passthrough and forced encoding. |
| Share-source crashes in `testShareSourceUsesVerifiedEmbeddedJPEGAndKeepsM4AAsTheOnlySharedItem`, `testWrongCoverAndMissingCoverFailWithBoundedReasons` and coordinator `R18IntegrationTests/testPNGAndJPEGLoaderToAACExportPreserveEmbeddedCoverAndSharePreview` | Export success preceded UIKit item discovery. The xcresult identifies the Objective-C `activityViewController(_:itemForActivityType:)` entry point. `@MainActor` plus `@preconcurrency UIActivityItemSource` left a runtime actor check in a callback UIKit invokes from a worker queue. Removing class isolation and the compatibility conformance makes the immutable callbacks safe on those queues. The two owned share tests also invoke all callbacks through an Objective-C protocol existential on a dedicated background queue, then compare URL/type, title, thumbnail and provider JPEG with native readback. |

Core-01's passing PCM fixture remains the native reproduction of the whole-timeline versus media-duration mismatch: a first timestamp of 2.25 seconds, about 3 seconds of PCM and about 5.25 seconds of asset duration. The replacement AAC fixture has a nonzero **input** timestamp but a zero-based **file** timeline because its session starts at the same input timestamp. It does not claim native interior-gap AAC support. `testInteriorEmptyEditsUseMappedPresentationTimesAndRequireEveryMediaInterval` separately checks a 3.25-second presentation timeline with 1.75 seconds of media, explicit output-PTS remapping and rejection when the second interval is missing. Interior-gap AAC composition serialization on that native passthrough path remains unsupported in the observed run; it is not skipped or counted as a passing production export. Duration tolerances and all production verification checks are retained.

| Selector (`AudioExportRegressionTests/…`) | Fixture and assertion | Level |
| --- | --- | --- |
| `testNativePCM441And48kMonoStereoWithPartialFinalPacketPNGAndUnicode` | Native PCM MOV, all four rate/channel combinations, 3 seconds plus 137 frames, irregular 4,093-frame input chunks, distinct channel tones; PNG converted to JPEG, Unicode iTunes readback, native AAC format, complete decode and audible tail | Integration |
| `testNativeNonzeroPCMTimestampsKeepLeadingEmptyEditAndCompleteAudio` | Actual first PCM timestamp 2.25 seconds, asserts source edit mapping and 5.25-second timeline versus 3-second media, then native export/readback | Integration |
| `testNativeAACWriterTimelinePassesBothExportPaths` | Independent native AAC writer, nonzero input PTS/session origin, contiguous file edit, partial final packet; strict source timeline/format, passthrough and forced native conversion with cover/Unicode tags | Integration |
| `testInteriorEmptyEditsUseMappedPresentationTimesAndRequireEveryMediaInterval` | Two noncontiguous media intervals with explicit output PTS mapping, empty markers and missing-interval rejection | Unit using Core Media |
| `testPCMTrimMathDoesNotDoubleSubtractPrimingOrEndPadding` | Real CMSampleBuffers with complete priming, partial start/end trims and permanent-empty marker; rational expected duration | Unit using Core Media |
| `testPCMCoverageUsesPresentationIntervalsAndRejectsMissingOrDuplicateFrames` | Nonzero presentation interval, markers, duplicated interval, missing half and marker-only output | Unit using Core Media |
| `testPCMPayloadAndInvalidTrimAreNotAcceptedAsEmptyMarkers` | Nonzero samples without payload and trim beyond the available frames fail with specific reasons | Unit using Core Media |
| `testNativeOpusReadbackRetainsJPEGAndUnicode` | Existing local 160/256-kbps stereo 48-kHz Opus MP4 fixtures, source preservation and real AAC decoding through the final tone | Integration; native-runtime gate |
| `testShareSourceUsesVerifiedEmbeddedJPEGAndKeepsM4AAsTheOnlySharedItem` | Native cover readback equals item-provider bytes; main/background Objective-C callbacks, thumbnail pixels, file item/type and retained export path | Integration with UIKit provider |
| `testKnownCoverFailureIsVisibleRetryableAndUnknownCoverMakesNoRequests` | Real loader with isolated mock transport: nil URL, 404, retry success and decoded-cache reuse | Integration with mocked network |
| `testExporterRejectsSilentlyDroppedKnownCoverBeforePublishing` | A caller passes nil bytes for a known artwork URL; exporter refuses before creating output | Integration with generated local media |
| `testSizedYouTubeCoverFallsBackThroughExistingLoaderCandidates` | Max/sd sizes 404, hq succeeds; exact ordered requests and valid cover | Integration with mocked network |
| `testSizedGoogleCoverRetriesSmallerImageAndCancellationMakesNoRequest` | Pre-cancelled lookup makes no request; failed 1,080-pixel URL falls back to 544 pixels | Integration with mocked network |
| `testWrongCoverAndMissingCoverFailWithBoundedReasons` | Native files with absent/wrong cover, explicit failure reasons, coverless main/background callbacks and bounded diagnostics | Integration |

Core-02 passed the replacement native fixtures and background share callbacks. Light/dark export/system-sharing workflows passed on phone, SE and iPad. The user's exact failing songs/assets, live stale artwork URLs, destination-app cover rendering and physical background encoder interruption remain unverified. Existing tests cover source corruption, cancellation/drainage, leases and admission bounds. Native embedded-cover bytes and Velvet Thorn's supplied preview do not establish a destination's display support. [VERIFICATION.md](VERIFICATION.md) owns receipts.

### Historical R17 Evidence

Core-02 exposed the failures below. Core-03 passed after their corrections; Integration-03 and UI-02 also passed in their targeted scopes. [VERIFICATION.md](VERIFICATION.md) owns exact counts and run boundaries. Native local-media tests are simulator integration evidence, not physical-device acceptance.

| Failure | Evidence and correction |
| --- | --- |
| AAC packet preservation test | Failed at the source fingerprint's `CMSampleBufferGetDataBuffer` unwrap before export began. The helper assumed every compressed-reader buffer carried media bytes. Apple's `AVAssetReaderOutput.h` explicitly permits zero-sample marker buffers when `outputSettings` is nil. The helper excludes only zero-sample markers, checks their sample size is zero, and still requires every nonempty sample to expose AAC format and packet bytes. Source/output SHA-256, byte counts and sample counts are compared independently. |
| AAC with a misleading `.wav` name | The log reports successful tagged AAC passthrough before the same fingerprint-helper failure. The packet helper receives the same correction; output-codec and PCM-readback assertions remain. |
| PCM with a misleading `.m4a` name | Failed before `export_input`, with a native file-format-reader error (`FFR_Common`, -12848). The same PCM fixture under `.wav` reached the native encoder in the passing cancellation case. Container-parser selection therefore failed before encoding. Every native asset open now applies a MIME override from recognized header bytes, and the conversion test exercises both filenames against the same PCM bytes. |

The pre-correction run passed both generated Opus fixture conversions, native AAC fallback with artwork, cancellation/deadline cleanup, concurrent-file protection, artwork bounds and verifier rejection cases. It did not establish AAC packet preservation because the fingerprint helper stopped those assertions.

The corrected suite has executed Core-03 coverage. The historical Core-02 diagnosis remains above so its failures are not presented as current blockers.

R17 UI-02 covered the phone export UI in light/dark; R17 Integration-03 covered model/cache lease paths as recorded in VERIFICATION. Live artwork fetch/failure handling, physical-device background interruption, slow/full storage and recipient-app playback remain separate checks. Deterministic cancellation/deadline tests do not establish interruption timing inside a hardware encoder or decoder.
