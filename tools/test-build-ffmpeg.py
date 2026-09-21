#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later

import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("build_ffmpeg", Path(__file__).with_name("build-ffmpeg.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class SourcePatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="patch-test-", dir=build.owned_directory(build.WORK))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "configure").write_text("original configure\n")
        (self.source / "demux.c").write_text("original demux\n")
        self.patches = [self.patch("0001-configure.patch", "configure", "original configure",
                                   "# FFmpegBridge modification, 2026-09-20:"),
                        self.patch("0002-metadata.patch", "demux.c", "original demux", "bounded demux")]

    def patch(self, name, target, before, after):
        path = self.root / name
        path.write_text(f"--- a/{target}\n+++ b/{target}\n@@ -1 +1 @@\n-{before}\n+{after}\n")
        return path

    def apply(self, patches=None):
        build.apply_required_patches(self.source, self.patches if patches is None else patches, self.root / "patch.log")

    def test_fresh_source_receives_every_required_patch(self):
        self.apply()
        self.assertEqual((self.source / "configure").read_text(), "# FFmpegBridge modification, 2026-09-20:\n")
        self.assertEqual((self.source / "demux.c").read_text(), "bounded demux\n")

    def test_older_patched_source_still_receives_new_metadata_patch(self):
        self.apply(self.patches[:1])
        self.apply()
        self.assertEqual((self.source / "demux.c").read_text(), "bounded demux\n")

    def test_complete_patched_source_is_reusable(self):
        self.apply()
        before = build.tree_manifest(self.source)
        self.apply()
        self.assertEqual(build.tree_manifest(self.source), before)

    def test_conflicting_source_is_rejected_instead_of_claiming_patch_applied(self):
        (self.source / "demux.c").write_text("incompatible custom demux\n")
        with self.assertRaisesRegex(build.BuildError, "0002-metadata.patch"):
            self.apply()
        self.assertEqual((self.source / "demux.c").read_text(), "incompatible custom demux\n")


if __name__ == "__main__":
    unittest.main()
