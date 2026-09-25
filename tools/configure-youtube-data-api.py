#!/usr/bin/env python3
"""Install the app-restricted YouTube API key without placing it in argv or Git."""

import argparse
import getpass
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-clipboard", action="store_true", help="Read the key copied from Google Cloud Console")
    parser.add_argument("--replace", action="store_true", help="Replace existing local configuration")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    target = root / "Resources" / "YouTubeDataAPI.local.plist"
    ignored = subprocess.run(["git", "check-ignore", "--quiet", str(target)], cwd=root, check=False)
    if ignored.returncode != 0:
        parser.error("The local configuration must be ignored by Git before installing a key.")
    if target.is_symlink() or (target.exists() and not args.replace):
        parser.error("Local configuration already exists. Inspect it before using --replace.")
    key = (subprocess.run(["pbpaste"], capture_output=True, text=True, check=True).stdout
           if args.from_clipboard else getpass.getpass("Restricted YouTube Data API key: ")).strip()
    if re.fullmatch(r"AIza[A-Za-z0-9_-]{35}", key) is None:
        parser.error("Expected a Google API key. The supplied value was not saved.")
    payload = plistlib.dumps({"APIKey": key, "BundleIdentifier": "com.agraabhi.ganabajana"})
    descriptor, temporary = tempfile.mkstemp(prefix=".youtube-api-", dir=target.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(payload)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    if args.from_clipboard:
        current = subprocess.run(["pbpaste"], capture_output=True, text=True, check=True).stdout.strip()
        if current == key:
            subprocess.run(["pbcopy"], input="", text=True, check=True)
    print("Configured Resources/YouTubeDataAPI.local.plist (Git-ignored, owner-only permissions).")
    print("The Google key must be restricted to YouTube Data API v3 and this app's iOS bundle identifier.")


if __name__ == "__main__":
    main()
