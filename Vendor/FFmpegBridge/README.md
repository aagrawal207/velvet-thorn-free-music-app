# FFmpegBridge

An iOS 18+ dynamic C framework for local WebM-to-MP4 Opus packet copy. The
SwiftPM product and imported module are both `FFmpegBridge`. Playback remains
the application's AVPlayer responsibility.

## Build

From the Breezy repository root, with Python 3.9+ and an active Xcode installation:

```sh
python3 tools/build-ffmpeg.py --jobs 8 --sign-simulator
```

The script builds `arm64` for iPhoneOS and `arm64` plus `x86_64` for
iPhoneSimulator, then publishes `Vendor/FFmpegBridge/FFmpegBridge.xcframework`.
The contained binaries are `MH_DYLIB` frameworks. The SwiftPM binary target
requires that output to exist before package resolution. No placeholder binary
is included in the source-only package.

Downloads, source trees, object files, logs, and previous binary backups stay
under the app-owned `artifacts/FFmpegBuild/`, which the repository already
ignores. The XCFramework and package-level `BUILD-PROVENANCE.json` are intended
to be tracked. The build prints the actual XCFramework size. Simulator ad-hoc
signing is optional; the application build must sign embedded device frameworks.

Incremental components can be run separately:

```sh
python3 tools/build-ffmpeg.py --component source
python3 tools/build-ffmpeg.py --component libraries --slice iphoneos-arm64 --jobs 8
python3 tools/build-ffmpeg.py --component bridge --slice iphoneos-arm64
python3 tools/build-ffmpeg.py --component package --sign-simulator
python3 tools/build-ffmpeg.py --component verify
```

Repeat `--slice` to select several slices. `all` rebuilds selected slices and
packages them with current cached copies of the other slices. `package` requires
all three current slices. A wrapper change invalidates its bridge cache; source,
configure, build-script, or toolchain changes invalidate the library cache.
An interrupted `make` resumes within its matching configuration. Completed
caches are checked against recorded hashes. A build lock prevents simultaneous
writers. Existing published binaries are retained until a replacement passes
the packaging checks, then moved into an artifacts backup.

The build uses Apple command-line tools, not a generated Xcode project. Its
`xcodebuild` calls read the toolchain version and assemble the XCFramework; it
does not build the application or run tests or simulators. Homebrew FFmpeg can
generate external fixtures, but its libraries are never build inputs.

## C and Swift contract

```c
typedef int (*GBRemuxInterrupt)(void *context);
int gb_remux_opus(const char *input_path, const char *output_path,
                  GBRemuxInterrupt interrupt, void *context);
const char *gb_ffmpeg_version(void);
```

Use `import FFmpegBridge` from Swift. Pass absolute filesystem paths, not URL
strings. A successful call returns `0`. Failures return a negative FFmpeg
`AVERROR` value, including negative POSIX errno values. Cancellation returns
`AVERROR_EXIT` (`-1414092869`). The independent time budget returns
`AVERROR(ETIMEDOUT)`. An existing output returns `AVERROR(EEXIST)`.

The function is synchronous. Keep the callback and its context alive until it
returns, run it off the main actor, and make a nonzero callback result mean
cancelled. The callback runs on the calling thread and must return promptly.
A null callback is allowed. Recursive calls from the callback return
`AVERROR(EBUSY)`; independent calls use separate operation state.

The downloader must verify the full expected Content-Length before calling the
bridge and keep the completed local input immutable. The caller owns the output
pathname and cleanup after any failure. Choose a fresh staging pathname for each
operation and publish it only after return `0` and native audio inspection.
A failed call can leave a partial file. Never delete a pre-existing file in
response to `EEXIST`. The wrapper does not unlink or rename files. It explicitly
selects the `mp4` muxer, so an output such as `audio.mp4.part` is supported.
The version function returns an immutable, process-lifetime string.

## Accepted input and limits

- Input is a nonempty regular file of at most **64 MiB**. `O_NOFOLLOW` rejects a
  symlink at the file itself. Parent directories are caller-controlled; system
  aliases such as Apple's `/var` are allowed. The file is copied into a bounded
  immutable snapshot, with size and modification/change timestamps checked
  before and after the copy.
- Output is created with `O_CREAT | O_EXCL | O_NOFOLLOW`, mode `0600`. The
  custom writer rejects seeks/writes that would exceed **64 MiB**. It checks
  flush, trailer, `fsync`, final size, and close errors before success.
- FFmpeg's Matroska/WebM demuxer handles the container, including unknown-sized
  Segments/Clusters and lacing in completed downloads. There is no custom EBML
  scanner. Its private syntax table skips unused Tags, Chapters, and Attachments
  before child allocation or conversion. Exactly one Opus audio track is required;
  video, extra streams, encryption, and changes to codec configuration fail.
  Encryption metadata and `AV_PKT_DATA_ENCRYPTION_*` side data are checked.
- Opus must be mono/stereo at **48 kHz**, with a 19-byte version-1 `OpusHead`
  and channel mapping family 0. The informational original-input sample rate
  and output gain in `OpusHead` are copied unchanged, along with codec delay,
  trailing padding, and seek preroll exported by FFmpeg.
- FFmpeg's existing Opus header parser validates frames and supplies durations
  and inferred timestamps for laced packets. The wrapper reads that parser's
  sample count through `av_stream_get_parser`; it has no separate RFC parser
  and does not call `avformat_find_stream_info` or open a decoder. Each emitted
  packet is capped at **64 KiB** and 5,760 coded samples (120 ms).
- Packet timestamps must be present, ordered by DTS, and within the bounded
  two-hour timeline, allowing two seconds for initial padding and rounding.
  Container packet durations must be positive and at most one second. There
  is no per-tick continuity test or exact comparison with Segment duration.
  The coded-sample and packet budgets are **two hours** plus initial padding
  and **400,000 packets**. Corrupt packets and invalid skip-sample metadata fail.
- FFmpeg allocations are capped at **32 MiB per allocation**, with an input
  index limit of 128 KiB. Input I/O is capped at 256 MiB of reads including
  rereads; output I/O at 128 MiB including header rewrites. The snapshot can use
  64 MiB in addition to FFmpeg allocations and sample tables. These are not an
  aggregate process-memory cap.
- Cancellation and a **30-second monotonic time budget** are checked during
  snapshotting, buffered EBML parsing, SeekHead traversal, packet processing,
  and I/O. They are cooperative;
  an in-progress filesystem system call returns before the callback can run.

FFmpeg receives custom I/O and an empty input name. All nested opens are denied,
network support is disabled, and the only compiled protocol is `file`.
No media path, URL, metadata, or FFmpeg message is logged. The private logging
callback records error severity without formatting the message, so recovered
demux errors still fail the operation.

`avcodec_parameters_copy` preserves the Opus configuration. Packet payloads and
trim side data pass unchanged to `av_write_frame`. The input time base is
offered to the MP4 muxer; `av_packet_rescale_ts` uses the muxer's actual output
time base without shifting timestamp origin or rewriting packet durations.
The parser's coded sample count supplies `frame_size`, which FFmpeg's MOV muxer
needs when applying trailing discard to its edit list. The movie timescale is
48 kHz. Track tags, titles, and other incidental metadata are not copied.

Return `0` means demuxing and muxing completed without a detected error, not
that the bridge proved transport completeness or decoded audio validity. A
packet-aligned truncated stream can resemble a complete stream when length or
duration metadata is absent. The downloader's full-length check and the
following native Swift PCM inspection remain required. FFmpeg errors, including
errors from which its demuxer recovers, fail the call; native inspection failure
must discard the output and allow AAC fallback.

## Build provenance and LGPL rebuilds

`Source.json` pins the official compressed source hash, release tag, and commit.
The hash is checked before extraction. `Patches/0001-no-auto-bitstream-filters.patch`
removes unneeded filter/IAMF selections from `configure`.
`Patches/0002-skip-unused-matroska-metadata.patch` addresses SEC-1 in the private
Matroska demuxer. Neither patch changes compressed Opus packets or the MP4 muxer.
Patch policy 2 checks each required patch independently with zero fuzz: apply
it after a successful forward dry run, otherwise require a successful reverse
dry run proving it is already present. Conflicting source fails preparation.
The same checks apply to `--source-dir`; a configure marker cannot bypass the
metadata patch. The configured component allowlist is:

| Type | Enabled |
| --- | --- |
| Demuxer | `matroska` |
| Muxers | `mp4`, its upstream `mov` implementation dependency |
| Parsers | `opus`, upstream MOV's required `ac3` parser support |
| Protocol | `file` |
| Encoders, decoders, bitstream filters, AV filters, hardware accelerators | None |

Upstream MOV/Matroska also compile shared RIFF/ISO and packet-header support.
They expose no additional bridge entry point. Static FFmpeg archives are linked
privately into the dynamic framework, with an exported-symbol allowlist. The
binary audit rejects a static framework, unexpected exports, wrong platform or
deployment target, and dynamic dependencies other than Apple's libSystem.

Reproducibility is scoped to the recorded Xcode/SDK/tool versions and source.
The recipe fixes component selection and targets, disables assembly and host
autodetection, normalizes source paths and archive timestamps, retains the
Mach-O UUIDs required by Xcode, and avoids signed timestamps. Different toolchain versions are separate
cache identities and are not claimed to produce byte-identical binaries.
`BUILD-PROVENANCE.json` records the exact inputs and file hashes. Verification
checks the current build-script digest, patch set/policy, source pins, wrapper
inputs, and published output hashes. The completed build also creates this
corresponding-source distribution:

```text
artifacts/FFmpegBuild/FFmpegBridge-9.0.2-source-<sha256>.tar.xz
```

The package-level provenance's `corresponding_source` entry owns the final archive
filename and hash. The source bundle includes its build-input/output manifest at
`breezy-bridge/BUILD-PROVENANCE.json`, recorded before the archive itself is hashed.
All three slices have been rebuilt with policy 2 and both patches. Packaging
includes the current package documentation in the corresponding-source bundle.
Public source and recipient relink delivery remain pending. The Breezy checkout's
`docs/FFMPEG_DISTRIBUTION.md` records that handoff.

To modify FFmpeg, unpack that bundle, edit its `ffmpeg-9.0.2` source tree, then
run the included recipe from `breezy-bridge`:

```sh
python3 tools/build-ffmpeg.py --source-dir ../ffmpeg-9.0.2 --jobs 8 --sign-simulator
```

The explicit source override records the modified tree and packages that exact
tree in the next corresponding-source bundle. Retain the two public C symbols
and their ABI to substitute a framework in an existing integration. Replace
the local SwiftPM XCFramework with the rebuilt one, re-resolve/relink the app,
embed it at `Frameworks/FFmpegBridge.framework`, and sign the framework and app
with credentials appropriate to the intended device or simulator. The
coordinator owns the application project and signing workflow.

## Verification handoff

### Unused metadata conversion and cancellation

FFmpeg 9.0.2 accumulates `SimpleTag` children in `MatroskaDemuxContext.tags` and
later calls `matroska_convert_tags` / `matroska_convert_tag`. Each unique key
causes a linear `av_dict_set` lookup. A single valid Tags element with 300,000
unique pairs fits the 64 MiB input and 32 MiB per-allocation limits while causing
quadratic CPU work without I/O or cancellation polls. Returning from a Swift
deadline race does not release that synchronous worker or a cache maintenance
operation waiting for it.

Patch 0002 marks Tags, Chapters, and Attachments as `EBML_NONE` in FFmpeg's
existing Segment syntax. Their payloads are skipped without allocating child
lists, converting dictionaries, creating chapter objects, or creating attached
streams. Ordinary audio/video Track entries still receive the existing
one-audio-stream validation. The existing skip path checks the declared extent
against the parent and file, checks the last byte, and rejects unknown-sized
skipped metadata. Unknown-sized Segments and Clusters still use their upstream
parsing rules. This does not inspect or validate the contents of ignored tags.

Interrupt polls inside buffered element parsing, resynchronization, and
SeekHead traversal keep cancellation observable when AVIO serves data from its
buffer. SeekHead does not revisit discarded metadata. Cancellation propagates
as `AVERROR_EXIT`; the C API and its error contract are unchanged.

The patch set and policy are part of prepared-source and library-cache identity.
Changing them requires matching libraries and wrapper outputs. Source overrides
receive the same per-patch checks described above; they cannot silently omit
patch 0002. The rebuilt binary and provenance include this fix, and the supplied
independent reviews have cleared SEC-1 and its follow-ups at source.

`Tests/FFmpegMetadataLimitTests.swift` generates adversarial fixtures at runtime
from the bundled `opus-160.webm`; no external fixture-generation command or
network is needed. It uses the native bridge/remux worker, reference packet
hashes, native PCM inspection, and the real cache with mocked transport.
All five cases passed in the coordinator's UnitReview03 and UnitReview04 runs.
Detailed results and timing limits are in the Breezy checkout's
`docs/app-store/RELEASE_STATUS.md`.
The targeted native selector is
`-only-testing:GanaBajanaTests/FFmpegMetadataLimitTests`:

- `test300000TagsCompleteWithinBudgetAndPreserveCompressedPackets`
- `testLargeChaptersAndAttachmentsCompleteWithinBudget`
- `testMalformedSkippedMetadataFailsPromptlyAndNextRemuxDrains`
- `testCancelledHighTagRemuxReleasesWorkerBeforeNextFile`
- `testExpiredHighTagPreparationCancelsDrainsAndNeverPublishes`

Fixture generation is outside the remux deadline measurement. The 2-second
native remux budget has a separate 4-second test watchdog; a watchdog timeout
is a failure, not successful input rejection. Cancellation also queues an
innocent remux afterward to prove the worker released. The cache test performs
real remuxing and native inspection before withholding a validation response
across a caller deadline, then verifies cancellation, drain, cleanup, and no
variant publication while preserving the pinned original.

### Regression coverage and acceptance

The script validates source/patch hashes, configured components, public exports,
Mach-O type, architectures, Apple platform, deployment target, install name,
system-library dependencies, framework metadata, and optional simulator
signature. These checks do not establish playback or packet equivalence.

The following table records regression scenarios and expected behavior. It does
not certify every scenario in the current selected run; completed results and
exclusions belong in the coordinator's verification record.

| Coverage | Scenarios and expected result |
| --- | --- |
| Bridge fixture tests | Actual completed YouTube WebM with unknown-sized Segment; finite and unknown-sized Clusters; Xiph, fixed-size, and EBML lacing. Remux through the FFmpeg path and compare every packet hash with CLI stream copy. |
| Native integration | Supplied 160/256 kbps fixtures and mono/stereo variants; inspect MP4 through AVAssetReader PCM and play through AVPlayer, including a `.part` pathname. Verify sample rate, channels, duration, and all compressed packet hashes. |
| Trim integration | Initial pre-skip, final discard, variable Opus packet durations, and a very short stream carrying both pre-skip and discard. Compare CLI output and native decoded sample counts; upstream/container limitations must lead to inspection failure and AAC fallback. |
| Bridge rejection | Empty input, malformed EBML, incomplete packet bodies, invalid 19-byte OpusHead, malformed Opus frames, video/extra tracks, encryption initialization/packet data, changed codec configuration, corrupt packets, and unresolved missing/backward/out-of-range packet timestamps after FFmpeg parsing. Require a negative result, including when FFmpeg logs an error and recovers. |
| Transport/native boundary | Cut a download at a packet boundary while retaining the original expected Content-Length. The downloader must reject it before the bridge. Do not require the bridge alone to detect an indistinguishable EOF with missing metadata. Native inspection must reject undecodable output or unacceptable duration. |
| Cancellation and limits | Cancel before entry, during snapshotting, during demuxing, and while writing/trailering. Require AVERROR_EXIT, caller cleanup, and no publication. Exercise input/output size limits, allocation failure, time budget, write/fsync failure, and successful trailer completion. |
| Filesystem and lifecycle | Input symlink/non-regular file, an existing destination or destination symlink, input modification during snapshotting, repeated calls, and independent concurrent calls. Preserve existing destination contents and release descriptors/buffers on failure. |

The coordinator owns fixture generation, builds, and test execution. Native
playback and adversarial metadata checks have passed. The app's verification
record owns current UI, live-provider, and remaining platform acceptance results.
