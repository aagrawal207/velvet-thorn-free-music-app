# FFmpegBridge source and distribution

**Local rebuilding, repackaging, and verification are complete; recipient source/relink delivery is pending.** The 2.16 MiB framework and matching source bundle are recorded in provenance. No public source URL or usable recipient relink path is established. This dependency remains alongside the [content-rights hold](app-store/RELEASE_STATUS.md#submission-hold).

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
artifacts/FFmpegBuild/FFmpegBridge-9.0.2-source-933effa8f979bfc29d20e967628542fb5f8897f0c2f747c2733f82648455c68f.tar.xz
```

`corresponding_source.sha256` matches the digest in that filename. The same provenance records `prepared_source.tree_sha256`, required patches, toolchain/recipe identity, and output hashes. Source repackaging is complete.

The current rebuilt package records **patch policy 2** and both required patches: `0001-no-auto-bitstream-filters.patch` and `0002-skip-unused-matroska-metadata.patch`. Preparation checks every patch forward or reverse, including explicit source overrides, and fails on conflict. Verification checks current build-script and patch hashes rather than accepting an older configure marker as proof of the full patch set.

The bundle contains the prepared FFmpeg tree, both patches, C wrapper/header, notices, package documentation, and build recipe. The [official upstream source](https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz) supplies only the upstream portion. The verified bundle remains a **local artifact**, not a public download or completed recipient source offer.

## Rebuild and relink materials

The package's [LGPL rebuild instructions](../Vendor/FFmpegBridge/README.md#build-provenance-and-lgpl-rebuilds) describe unpacking the source bundle, modifying its FFmpeg tree, rebuilding with the included recipe, and substituting an ABI-compatible XCFramework. The two exported symbols are `gb_remux_opus` and `gb_ffmpeg_version`. The application is then re-resolved/relinked, embeds the replacement framework, and requires signing appropriate to the recipient's installation method.

Binary distribution must retain the notices/full license and provide the exact corresponding-source bundle. Its terms must permit modification for the recipient's own use and reverse engineering to debug those modifications as required by LGPL section 6. Dynamic linkage alone does not establish that the available iOS installation/replacement path satisfies those conditions. If it does not, the package notice calls for relinkable application objects or source and the other section 6(a) materials.

| Delivery item | Current state |
| --- | --- |
| Corresponding-source archive and provenance | Rebuilt, repackaged, and verified locally; public URL **TBD** |
| Full LGPL text, wrapper license, and notice | Present in the package/framework; preserve in the distributed binary |
| User-facing acknowledgement | `Resources/Acknowledgements.txt`; exact source URL still pending |
| Recipient rebuild/relink instructions | Available locally in the package README; public delivery and usable recipient path pending |
| Relinkable application materials, if required | Delivery method/materials not established |

The verified source-to-binary record is available locally. Public URLs and the recipient installation/relink path remain unresolved; the private repository and local development IPA do not complete delivery.
