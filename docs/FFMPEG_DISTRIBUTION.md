# FFmpegBridge source and distribution

**Library source and rebuild materials are public; recipient application relinking remains pending.** The owner authorized the separate [Breezy-FFmpegBridge repository](https://github.com/aagrawal207/Breezy-FFmpegBridge). Its [9.0.2-patch2 release](https://github.com/aagrawal207/Breezy-FFmpegBridge/releases/tag/9.0.2-patch2) was published September 25 UTC and verified through an anonymous download. The application source and credentials remain private. This dependency remains alongside the [content-rights hold](app-store/RELEASE_STATUS.md#submission-hold).

## Public source delivery

- [Complete corresponding-source archive](https://github.com/aagrawal207/Breezy-FFmpegBridge/releases/download/9.0.2-patch2/FFmpegBridge-9.0.2-source-ad454b1bc22d2b462619a393e9598a2553d0df01465569f9631438ca290588a1.tar.xz): **11,788,692 bytes**, SHA-256 `ad454b1bc22d2b462619a393e9598a2553d0df01465569f9631438ca290588a1`.
- [Public rebuild instructions](https://github.com/aagrawal207/Breezy-FFmpegBridge#build-the-library), license text and notices accompany the source.
- [SOURCE-DISTRIBUTION.json](https://github.com/aagrawal207/Breezy-FFmpegBridge/blob/main/SOURCE-DISTRIBUTION.json) maps the public repack to the original build provenance. One Xcode per-user scheme file was omitted; all **10,413** retained files are byte-identical, including every compiled source, patch and wrapper input.
- Standalone source preparation in the public checkout reproduced source-tree SHA-256 `0106cdb70aa8d5788503239fc4357661c9f55217d4c0f9911d54c52517bbde67`. Existing three-slice binary verification also passed; no new three-slice rebuild is claimed.

`artifacts/Authorization-20260925/ffmpeg-publication.json` records the public commit, six uploaded assets and anonymous checksum/byte comparison. The original archive and packaged framework provenance remain intact.

## Authoritative package records

| Record | Purpose |
| --- | --- |
| [Package README](../Vendor/FFmpegBridge/README.md) | C ABI, accepted files, build recipe, and framework substitution |
| [Source.json](../Vendor/FFmpegBridge/Source.json) | FFmpeg 9.0.2 upstream URL, tag/commit, source hash, and license hash |
| [BUILD-PROVENANCE.json](../Vendor/FFmpegBridge/BUILD-PROVENANCE.json) | Exact source/patch/toolchain inputs, corresponding-source archive, and output hashes |
| [LICENSE.md](../Vendor/FFmpegBridge/LICENSE.md) and [NOTICE.md](../Vendor/FFmpegBridge/NOTICE.md) | FFmpeg and wrapper licensing and distribution conditions |
| [COPYING.LGPLv2.1](../Vendor/FFmpegBridge/COPYING.LGPLv2.1) | Verbatim GNU LGPL v2.1 text, also packaged in each framework slice |
| [Wrapper source](../Vendor/FFmpegBridge/Sources/FFmpegBridge.c), [header](../Vendor/FFmpegBridge/include/FFmpegBridge.h), and [patches](../Vendor/FFmpegBridge/Patches/) | Local C bridge, exported interface, minimal configure selection, and skipped unused Matroska metadata |

The wrapper and package build materials are **LGPL-2.1-or-later**, copyright (C) 2026 Breezy contributors, as stated in the package license. Upstream FFmpeg retains its contributors' notices. This license does not relicense the application or grant content rights.

The app loads `FFmpegBridge.framework` dynamically through `@rpath`. Its private static FFmpeg archives provide local WebM demuxing and MP4 muxing; network, encoders, and decoders are disabled. The Homebrew executable used for fixtures is not a linked dependency. Current build/playback evidence is in [release status](app-store/RELEASE_STATUS.md#verification-snapshot), not inferred from the recipe.

## Exact local corresponding source

The verified current archive, identified by `corresponding_source.file` in [BUILD-PROVENANCE.json](../Vendor/FFmpegBridge/BUILD-PROVENANCE.json), is:

```text
artifacts/FFmpegBuild/FFmpegBridge-9.0.2-source-7611a2169ae337a8acc66375227b23b73636a5c3f85518f74f1902a4a3180ce2.tar.xz
```

That archive belongs to the five-slice package built on 3 October 2026 for the Mac app (two Mac Catalyst slices added; the iPhone device binary is byte-identical to the published build, and the simulator binary differs only in its ad hoc signature). Its build script differs from the published 9.0.2-patch2 release, so a Mac distribution needs that archive published first; the publication above still matches the iPhone binary only. The earlier three-slice archive `…933effa8…` remains in `artifacts/FFmpegBuild/`.

`corresponding_source.sha256` matches the digest in that filename. The same provenance records `prepared_source.tree_sha256`, required patches, toolchain/recipe identity, and output hashes. Source repackaging is complete.

The current rebuilt package records **patch policy 2** and both required patches: `0001-no-auto-bitstream-filters.patch` and `0002-skip-unused-matroska-metadata.patch`. Preparation checks every patch forward or reverse, including explicit source overrides, and fails on conflict. Verification checks current build-script and patch hashes rather than accepting an older configure marker as proof of the full patch set.

The original bundle contains the prepared FFmpeg tree, both patches, C wrapper/header, notices, package documentation, build recipe and one Xcode per-user scheme file. The public repack above omits only that non-build file. The [official upstream source](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) alone supplies only the upstream portion.

## Rebuild and relink materials

The package's [LGPL rebuild instructions](../Vendor/FFmpegBridge/README.md#build-provenance-and-lgpl-rebuilds) describe unpacking the source bundle, modifying its FFmpeg tree, rebuilding with the included recipe, and substituting an ABI-compatible XCFramework. The two exported symbols are `gb_remux_opus` and `gb_ffmpeg_version`. The application is then re-resolved/relinked, embeds the replacement framework, and requires signing appropriate to the recipient's installation method.

Binary distribution must retain the notices/full license and provide the exact corresponding-source bundle. Its terms must permit modification for the recipient's own use and reverse engineering to debug those modifications as required by LGPL section 6. Dynamic linkage alone does not establish that the available iOS installation/replacement path satisfies those conditions. If it does not, the package notice calls for relinkable application objects or source and the other section 6(a) materials.

| Delivery item | Current state |
| --- | --- |
| Corresponding-source archive and provenance | Public versioned release; anonymous download, checksums and retained file contents verified |
| Full LGPL text, wrapper license, and notice | Present in the package/framework; preserve in the distributed binary |
| User-facing acknowledgement | Current `Resources/Acknowledgements.txt` links the public release; uploaded build 5 retains its original acknowledgement |
| Recipient library rebuild instructions | Public and source-preparation verified; usable application replacement/signing path remains pending |
| Relinkable application materials, if required | Delivery method/materials not established |

Public library source delivery is complete. Recipient application installation/relinking is not verified; no application objects, application source or signing credentials were published. The local development IPA and dynamic linkage alone do not resolve that remaining requirement.
