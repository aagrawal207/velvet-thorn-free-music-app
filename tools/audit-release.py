#!/usr/bin/env python3
"""Validate an archived Breezy app before local export or distribution preparation."""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    apps = list((args.archive / "Products" / "Applications").glob("*.app"))
    require(len(apps) == 1, "Expected exactly one archived application")
    app = apps[0]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.agraabhi.ganabajana", "Unexpected bundle identity")
    require(info["CFBundleDisplayName"] == "Breezy", "Unexpected display name")
    require(info["CFBundleShortVersionString"] == args.version and info["CFBundleVersion"] == args.build,
            "Archive version/build does not match the requested candidate")
    require(info["UIDeviceFamily"] == [1], "Release must target iPhone only")
    require(info["MinimumOSVersion"] == "18.0", "Unexpected deployment target")
    require(set(info["UISupportedInterfaceOrientations"]) == {
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
    }, "Unexpected supported orientations")
    executable = app / info["CFBundleExecutable"]
    require(run("xcrun", "lipo", "-archs", str(executable)) == "arm64", "Unexpected device architectures")
    data = executable.read_bytes()
    for marker in (b"--uitesting", b"--seed-ui", b"--ui-scene-geometry", b"--library-recovery-fixture",
                   b"--artist-navigation-fixture", b"DebugMusicFixtures", b"OpusFixtures.json"):
        require(marker not in data, f"Debug fixture marker in Release: {marker.decode()}")
    require(not list(app.rglob("*.storekit")), "Local StoreKit test catalog must not ship in Release")
    require(not list(app.rglob("*.webm")), "Test media must not ship in Release")
    privacy = plistlib.loads((app / "PrivacyInfo.xcprivacy").read_bytes())
    require("NSPrivacyAccessedAPITypes" in privacy, "Privacy manifest is missing required-reason APIs")
    notices = (app / "Acknowledgements.txt").read_text()
    require("FFmpeg" in notices and "YouTubeKit" in notices, "Missing dependency acknowledgements")
    framework = app / "Frameworks" / "FFmpegBridge.framework"
    root = Path(__file__).resolve().parent.parent
    package = root / "Vendor" / "FFmpegBridge"
    for name in ("COPYING.LGPLv2.1", "LICENSE.md", "NOTICE.md"):
        require((framework / name).read_bytes() == (package / name).read_bytes(), f"Missing or changed {name}")
    symbols = set(run("xcrun", "nm", "-gUj", str(framework / "FFmpegBridge")).splitlines())
    require(symbols == {"_gb_ffmpeg_version", "_gb_remux_opus"}, "Unexpected bridge exports")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(json.dumps({"app": str(app), "version": args.version, "build": args.build,
                      "bundleID": info["CFBundleIdentifier"], "architecture": "arm64",
                      "signatureVerified": True, "debugFixturesAbsent": True,
                      "storeKitTestCatalogAbsent": True, "dependencyNoticesVerified": True}, indent=2))


if __name__ == "__main__":
    main()
