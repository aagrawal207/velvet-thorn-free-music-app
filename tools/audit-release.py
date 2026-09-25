#!/usr/bin/env python3
"""Validate an archived Breezy app before local export or distribution preparation."""

import argparse
import json
from pathlib import Path
import plistlib
import re
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
    parser.add_argument("--require-youtube-data-api", action="store_true")
    args = parser.parse_args()
    apps = list((args.archive / "Products" / "Applications").glob("*.app"))
    require(len(apps) == 1, "Expected exactly one archived application")
    app = apps[0]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.agraabhi.ganabajana", "Unexpected bundle identity")
    require(info["CFBundleDisplayName"] == "Breezy", "Unexpected display name")
    require(info["CFBundleShortVersionString"] == args.version and info["CFBundleVersion"] == args.build,
            "Archive version/build does not match the requested candidate")
    require(sorted(info["UIDeviceFamily"]) == [1, 2], "Release must target iPhone and iPad")
    require(info["MinimumOSVersion"] == "18.0", "Unexpected deployment target")
    require(set(info["UISupportedInterfaceOrientations"]) == {
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
    }, "Unexpected iPhone orientations")
    require(set(info.get("UISupportedInterfaceOrientations~ipad", [])) == {
        "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"
    }, "iPad must support all four orientations")
    # Multitasking (Split View, Slide Over, Stage Manager) requires all four iPad orientations without full-screen-only.
    require(not info.get("UIRequiresFullScreen", False), "iPad multitasking must stay enabled")
    executable = app / info["CFBundleExecutable"]
    require(run("xcrun", "lipo", "-archs", str(executable)) == "arm64", "Unexpected device architectures")
    data = executable.read_bytes()
    for marker in (b"--uitesting", b"--seed-ui", b"--ui-scene-geometry", b"--library-recovery-fixture",
                   b"--artist-navigation-fixture", b"--listening-languages-unknown", b"--cache-fixture",
                   b"--cached-songs-fixture", b"--offline-fixture", b"--slow-search", b"--fail-search-once",
                   b"--reduce-motion", b"DebugMusicFixtures", b"DebugCachedAudioFixture", b"DebugFixtureAudio",
                   b"--widget-fixture", b"--widget-preview", b"--widget-sharing-fixture", b"DebugWidgetSupport", b"r8-small-card-v2",
                   b"OpusFixtures.json"):
        require(marker not in data, f"Debug fixture marker in Release: {marker.decode()}")
    require(not list(app.rglob("*.storekit")), "Local StoreKit test catalog must not ship in Release")
    require(not list(app.rglob("*.webm")), "Test media must not ship in Release")
    api_file = app / "YouTubeDataAPI.local.plist"
    if args.require_youtube_data_api:
        require(api_file.is_file(), "The release requires its restricted YouTube Data API configuration")
    if api_file.exists():
        api = plistlib.loads(api_file.read_bytes())
        require(api.get("BundleIdentifier") == info["CFBundleIdentifier"], "YouTube API bundle restriction mismatch")
        require(re.fullmatch(r"AIza[A-Za-z0-9_-]{35}", api.get("APIKey", "")) is not None,
                "Invalid bundled YouTube Data API configuration")
    widgets = list((app / "PlugIns").glob("*.appex"))
    require(len(widgets) == 1, "Expected the Breezy widget extension")
    widget = widgets[0]
    widget_info = plistlib.loads((widget / "Info.plist").read_bytes())
    require(widget_info["CFBundleIdentifier"] == "com.agraabhi.ganabajana.widgets", "Unexpected widget identity")
    require(widget_info["CFBundleShortVersionString"] == args.version and widget_info["CFBundleVersion"] == args.build,
            "Widget version/build must match Breezy")
    require(widget_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension",
            "The extension must use native WidgetKit")
    require(widget_info["MinimumOSVersion"] == "18.0" and sorted(widget_info["UIDeviceFamily"]) == [1, 2],
            "Widgets must retain iOS 18 iPhone/iPad support")
    widget_executable = widget / widget_info["CFBundleExecutable"]
    require(run("xcrun", "lipo", "-archs", str(widget_executable)) == "arm64", "Unexpected widget architecture")
    widget_data = widget_executable.read_bytes()
    for marker in (b"DebugWidgetSupport", b"musicWidgetPreviewFamily", b"--widget-fixture", b"--widget-preview", b"r8-small-card-v2",
                   b"DebugMusicFixtures", b"PlayerController", b"YouTubeStreamResolver", b"YouTubeAccountStore", b"YouTubeDataAPI"):
        require(marker not in widget_data, f"App-only or DEBUG implementation in widget: {marker.decode()}")
    dependencies = run("xcrun", "otool", "-L", str(widget_executable))
    require("FFmpegBridge" not in dependencies and "YouTubeKit" not in dependencies,
             "Widgets must not link audio/provider dependencies")
    require(not list(widget.rglob("YouTubeDataAPI.local.plist")), "Widget must not contain the API credential")
    require(not list((app / "Watch").rglob("YouTubeDataAPI.local.plist")), "Watch must not contain the API credential")
    group = ["group.com.agraabhi.ganabajana"]
    for bundle in (app, widget):
        entitlements = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)).encode())
        require(entitlements.get("com.apple.security.application-groups") == group,
                f"Unexpected shared widget App Group in {bundle.name}")
        if bundle == widget:
            require(not any(key.startswith("com.apple.developer.icloud") or key.startswith("com.apple.developer.ubiquity")
                            or key == "com.apple.developer.carplay-audio" for key in entitlements),
                    "Widget must not request iCloud or CarPlay entitlements")
    run("codesign", "--verify", "--strict", str(widget))
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
                      "deviceFamilies": ["iPhone", "iPad"],
                      "signatureVerified": True, "debugFixturesAbsent": True,
                       "storeKitTestCatalogAbsent": True, "dependencyNoticesVerified": True,
                       "widgetExtensionVerified": True, "widgetAppGroupVerified": True,
                        "widgetAppOnlyDependenciesAbsent": True,
                        "youTubeDataAPIConfigured": api_file.exists(), "apiCredentialExcludedFromCompanions": True}, indent=2))


if __name__ == "__main__":
    main()
