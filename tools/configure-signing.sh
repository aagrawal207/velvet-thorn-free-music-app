#!/bin/sh
# Points a fresh clone at your own Apple team and bundle ID prefix so Xcode's
# automatic signing works. Run once before `xcodegen generate`.
#
#   tools/configure-signing.sh TEAM_ID com.yourname.velvetthorn [--no-icloud]
#
# --no-icloud removes the iCloud entitlement, which free Apple accounts cannot
# sign. iCloud library sync then reports itself unavailable; everything else works.
set -eu

usage() {
    echo "usage: $0 TEAM_ID BUNDLE_ID_PREFIX [--no-icloud]" >&2
    echo "example: $0 AB12CD34EF com.yourname.velvetthorn --no-icloud" >&2
    exit 64
}

[ $# -ge 2 ] || usage
team=$1
prefix=$2
no_icloud=0
[ "${3:-}" = "--no-icloud" ] && no_icloud=1

printf '%s' "$team" | grep -Eq '^[A-Z0-9]{10}$' || { echo "TEAM_ID must be 10 uppercase letters or digits." >&2; exit 65; }
printf '%s' "$prefix" | grep -Eq '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' || { echo "BUNDLE_ID_PREFIX must look like com.yourname.app" >&2; exit 65; }

cd "$(dirname "$0")/.."
original=com.agraabhi.ganabajana

perl -pi -e "s/^(\s*DEVELOPMENT_TEAM:).*/\$1 $team/" project.yml

# The prefix also names the App Group, iCloud container, Keychain items and
# background task IDs, so every copy must change together.
files=$(grep -rlF "$original" project.yml Signing Sources Resources WidgetExtension WatchApp Tests UITests WatchTests WatchUITests 2>/dev/null || true)
if [ -n "$files" ]; then
    printf '%s\n' "$files" | while IFS= read -r file; do
        perl -pi -e "s/\Q$original\E/$prefix/g" "$file"
    done
fi

if [ "$no_icloud" -eq 1 ]; then
    for entitlements in Signing/iCloud.entitlements Signing/CarPlay.entitlements Signing/MacCatalyst.entitlements; do
        for key in com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services com.apple.developer.ubiquity-container-identifiers; do
            /usr/libexec/PlistBuddy -c "Delete :$key" "$entitlements" >/dev/null 2>&1 || true
        done
    done
fi

echo "Team $team, bundle ID $prefix$( [ "$no_icloud" -eq 1 ] && echo ', iCloud removed')."
echo "Next: xcodegen generate && open GanaBajana.xcodeproj"
