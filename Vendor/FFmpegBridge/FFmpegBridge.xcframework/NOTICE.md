# FFmpeg notice

FFmpegBridge contains software from the [FFmpeg project](https://ffmpeg.org/),
licensed under the GNU Lesser General Public License, version 2.1 or later.
Copyright belongs to the FFmpeg contributors identified in the corresponding
source. `COPYING.LGPLv2.1` accompanies this framework. FFmpegBridge is a Breezy
component and is not an official FFmpeg binary distribution.

## Corresponding source

- Release: **FFmpeg 9.0.2**.
- Official source: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>.
- Compressed source SHA-256:
  `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
- Official Git mirror: <https://github.com/FFmpeg/FFmpeg>.
- Tag: `n9.0.2`; commit: `946fcce07b6dcd0331c8cc609192aeff5e1924f8`.
- Build inputs: `Source.json`, `Patches/`, `Sources/`, `include/`,
  `Framework.modulemap`, `exports.txt`, and `tools/build-ffmpeg.py` in the Breezy
  source tree.

The build verifies the original compressed source before extraction, then
applies the patches in `Patches/`:

- `0001-no-auto-bitstream-filters.patch` changes `configure` to remove the MOV
  muxer's AAC/VP9 bitstream-filter selections and optional IAMF writer.
- `0002-skip-unused-matroska-metadata.patch` changes `libavformat/matroskadec.c`
  for SEC-1. The private packet-copy build skips Tags, Chapters, and Attachments
  through FFmpeg's existing bounded skip path before allocating their children.
  Buffered element parsing, resynchronization, and SeekHead traversal poll the
  interrupt callback. The modification notice in that file is dated 2026-09-21.

The source archive pin above still identifies the original upstream release;
prepared-source and patch hashes identify the modified build. Audio packet
parsing, lacing, and the MP4 packet-copy implementation remain upstream code.
No Homebrew binary or library is included.

Each completed build supplies `BUILD-PROVENANCE.json` with the source-tree and
patch hashes, compiler/SDK versions, exact configure arguments, enabled
components, linkage flags, and output hashes. The generated
`FFmpegBridge-9.0.2-source-<sha256>.tar.xz` contains the complete prepared FFmpeg source,
wrapper, licenses, and build recipe. A `--source-dir` rebuild is explicitly
identified as modified source in its provenance.

## Linkage and redistribution

The application loads `FFmpegBridge.framework/FFmpegBridge` dynamically through
`@rpath`. This framework contains private static builds of libavformat,
libavcodec, and libavutil. The application does not statically link those
archives. Only `gb_remux_opus` and `gb_ffmpeg_version` are exported.

Supply this notice, the LGPL text, and the exact corresponding-source bundle
alongside a distribution of the framework. The official upstream URL alone
does not supply the wrapper or its build modification. Distribution terms must
permit modification for the recipient's own use and reverse engineering to
debug those modifications, as required by LGPL section 6.

`README.md` describes rebuilding and substituting an interface-compatible
framework. Apple platforms require the modified application and embedded
framework to be signed for the recipient's permitted installation method.
Dynamic linkage does not itself provide Apple signing credentials or establish
that an App Store distribution satisfies every LGPL condition. If the shared
library mechanism available to recipients is insufficient, supply the relinkable
application objects or source and the other materials required by LGPL section
6(a). No public source-hosting location or source offer is asserted here.
