// SPDX-License-Identifier: LGPL-2.1-or-later

#ifndef GB_FFMPEG_BRIDGE_H
#define GB_FFMPEG_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*GBRemuxInterrupt)(void *context);

// Paths are absolute; input must be a complete, length-verified download and output must not exist.
// The caller owns threading, callback lifetime, failure cleanup, and native output inspection.
__attribute__((visibility("default")))
int gb_remux_opus(const char *input_path, const char *output_path,
                  GBRemuxInterrupt interrupt, void *context);

// Returns a process-lifetime, immutable UTF-8 string; do not free it.
__attribute__((visibility("default")))
const char *gb_ffmpeg_version(void);

#ifdef __cplusplus
}
#endif

#endif
