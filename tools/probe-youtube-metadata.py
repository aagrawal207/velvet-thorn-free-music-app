#!/usr/bin/env python3
"""Inspect recording metadata without logging credentials or media URLs."""

import argparse
from datetime import datetime, timezone
import importlib.metadata
import json
from pathlib import Path
import plistlib
import re
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def official(ids, credentials, bundle_identifier):
    query = urllib.parse.urlencode({
        "part": "snippet,contentDetails", "id": ",".join(ids),
        "fields": "items(id,snippet(defaultAudioLanguage,defaultLanguage),contentDetails(duration))",
    })
    request = urllib.request.Request("https://www.googleapis.com/youtube/v3/videos?" + query, headers={
        "X-Goog-Api-Key": credentials["APIKey"], "X-Ios-Bundle-Identifier": bundle_identifier,
    })
    opener = urllib.request.build_opener(NoRedirect())
    try:
        with opener.open(request, timeout=15) as response:
            raw = response.read(256 * 1024 + 1)
            if len(raw) > 256 * 1024:
                raise ValueError("Oversized metadata response")
            items = json.loads(raw)["items"]
            return {"httpStatus": response.status, "recordings": [{
                "id": item.get("id"),
                "audioLanguage": item.get("snippet", {}).get("defaultAudioLanguage"),
                "snippetLanguage": item.get("snippet", {}).get("defaultLanguage"),
                "duration": item.get("contentDetails", {}).get("duration"),
            } for item in items]}
    except urllib.error.HTTPError as error:
        return {"httpStatus": error.code}


def music_metadata(ids):
    import requests
    from ytmusicapi import YTMusic

    class BoundedSession(requests.Session):
        def request(self, method, url, **kwargs):
            kwargs["timeout"] = (5, 10)
            return super().request(method, url, **kwargs)

    def language_fields(node, path="", depth=0):
        if depth > 20:
            return []
        if isinstance(node, dict):
            fields = []
            for key, value in node.items():
                child = f"{path}.{key}" if path else key
                if "language" in key.lower() and isinstance(value, (str, bool, int)):
                    fields.append({"path": child, "value": str(value)[:64]})
                fields.extend(language_fields(value, child, depth + 1))
            return fields[:50]
        if isinstance(node, list):
            return [field for index, value in enumerate(node[:100])
                    for field in language_fields(value, f"{path}[{index}]", depth + 1)][:50]
        return []

    with BoundedSession() as session:
        client = YTMusic(requests_session=session)
        recordings = []
        for video_id in ids:
            try:
                result = client.get_song(video_id)
                details = result.get("videoDetails", {})
                formats = result.get("streamingData", {}).get("adaptiveFormats", [])
                tracks = []
                for item in formats:
                    track = item.get("audioTrack")
                    if isinstance(track, dict):
                        selected = {key: track.get(key) for key in ("id", "displayName", "audioIsDefault")}
                        if selected not in tracks:
                            tracks.append(selected)
                recordings.append({"requestedID": video_id, "returnedID": details.get("videoId"),
                    "durationSeconds": details.get("lengthSeconds"),
                    "languageFields": language_fields(result), "audioTracks": tracks})
            except Exception as error:
                recordings.append({"requestedID": video_id, "errorType": type(error).__name__})
        return {"version": importlib.metadata.version("ytmusicapi"), "recordings": recordings}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ids", nargs="+")
    parser.add_argument("--with-ytmusicapi", action="store_true")
    parser.add_argument("--verify-ios-restriction", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= len(args.ids) <= 10 or any(re.fullmatch(r"[A-Za-z0-9_-]{11}", value) is None for value in args.ids):
        parser.error("Provide between one and ten recording IDs.")
    if args.output and args.output.exists():
        parser.error("The output already exists; use a new receipt path.")
    config = Path(__file__).resolve().parents[1] / "Resources" / "YouTubeDataAPI.local.plist"
    if config.stat().st_mode & 0o077:
        parser.error("The local credential file must have owner-only permissions.")
    credentials = plistlib.loads(config.read_bytes())
    result = {"checkedAt": datetime.now(timezone.utc).isoformat(),
              "official": official(args.ids, credentials, credentials["BundleIdentifier"])}
    if args.verify_ios_restriction:
        result["wrongBundle"] = official(args.ids[:1], credentials, credentials["BundleIdentifier"] + ".invalid")
    if args.with_ytmusicapi:
        result["ytmusicapi"] = music_metadata(args.ids)
    output = json.dumps(result, indent=2) + "\n"
    if args.output:
        with args.output.open("x") as handle:
            handle.write(output)
    print(output, end="")
    if result["official"]["httpStatus"] != 200:
        raise SystemExit(1)
    if args.verify_ios_restriction and result["wrongBundle"]["httpStatus"] != 403:
        raise SystemExit("The iOS application restriction was not verified.")


if __name__ == "__main__":
    main()
