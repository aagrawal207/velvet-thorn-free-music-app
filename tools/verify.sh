#!/usr/bin/env bash
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash tools/verify.sh [unit|ui|live|live-ui|release]' \
        '' \
        'Modes (default: unit):' \
        '  unit      GanaBajana unit target; opt-in live checks stay disabled.' \
        '  ui        GanaBajana fixture UI suites, excluding the live UI suite.' \
        '  live      GanaBajanaLive provider suites, including encrypted DNS/TLS.' \
        '  live-ui   GanaBajanaLiveUI real-recording playback workflow.' \
        '  release   Local generic-iOS Release archive; unsigned by default.' \
        '' \
        'Environment:' \
        '  DESTINATION       Required for tests: platform=iOS Simulator,id=<UDID>' \
        '                    or platform=iOS,id=<UDID> for a signed device run.' \
        '                    Release accepts only generic/platform=iOS (default).' \
        '  RELEASE_SIGNING   unsigned (default) or automatic, for release.' \
        '  DEVELOPMENT_TEAM  Optional local signing-team override.' \
        '  SKIP_NATIVE_STOREKIT  1 excludes native StoreKit suites (default: 0).' \
        '' \
        'Requires Xcode and XcodeGen. Regenerates the project from project.yml.' \
        'Uses app-owned artifacts/DerivedData and artifacts/SourcePackages.' \
        'Creates a unique artifacts/verify-<mode>-<timestamp>-<random>/ directory.' \
        'Runs with 4 jobs, parallel testing off, and automatic diagnostics off.' \
        'Archives stay local; no export or upload.' \
        '' \
        'Exit codes: 64 for usage/configuration, 69 for missing tools;' \
        'otherwise the first failing command status. --help creates no outputs.'
}

fail() {
    printf 'verify: %s\n' "$2" >&2
    exit "$1"
}

[[ $# -le 1 ]] || fail 64 'Expected one mode. See --help.'
mode="${1:-unit}"
case "$mode" in
    -h|--help) usage; exit 0 ;;
    unit|ui|live|live-ui|release) ;;
    *) fail 64 "Unknown mode: $mode. See --help." ;;
esac

case "${SKIP_NATIVE_STOREKIT:-0}" in
    0|1) ;;
    *) fail 64 'SKIP_NATIVE_STOREKIT must be 0 or 1.' ;;
esac

if [[ "$mode" == release ]]; then
    destination="${DESTINATION:-generic/platform=iOS}"
    [[ "$destination" == 'generic/platform=iOS' ]] \
        || fail 64 'Release requires DESTINATION=generic/platform=iOS.'
    release_signing="${RELEASE_SIGNING:-unsigned}"
    case "$release_signing" in
        unsigned|automatic) ;;
        *) fail 64 'RELEASE_SIGNING must be unsigned or automatic.' ;;
    esac
else
    [[ -n "${DESTINATION:-}" ]] || fail 64 'Set DESTINATION explicitly. See --help.'
    destination="$DESTINATION"
fi

for tool in xcodegen xcodebuild; do
    command -v "$tool" >/dev/null 2>&1 || fail 69 "Required tool not found: $tool"
done

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$project_root/project.yml" ]] || fail 64 'Cannot locate project.yml beside tools/.'
artifact_root="$project_root/artifacts"
mkdir -p "$artifact_root/DerivedData" "$artifact_root/SourcePackages"
run_directory="$(mktemp -d "$artifact_root/verify-${mode}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
result_bundle="$run_directory/$mode.xcresult"
log="$run_directory/verify.log"

args=(
    -project "$project_root/GanaBajana.xcodeproj"
    -destination "$destination"
    -derivedDataPath "$artifact_root/DerivedData"
    -clonedSourcePackagesDirPath "$artifact_root/SourcePackages"
    -resultBundlePath "$result_bundle"
    -jobs 4
    -parallel-testing-enabled NO
    -collect-test-diagnostics never
)

# Opt-in belongs to the selected scheme, not a previous shell's test settings.
unset GANABAJANA_LIVE_TESTS GANABAJANA_LIVE_UI GANABAJANA_LYRICS_DNS_RESOLVER
unset TEST_RUNNER_GANABAJANA_LIVE_TESTS TEST_RUNNER_GANABAJANA_LIVE_UI TEST_RUNNER_GANABAJANA_LYRICS_DNS_RESOLVER

case "$mode" in
    unit)
        args+=(test -scheme GanaBajana -configuration Debug -only-testing:GanaBajanaTests)
        ;;
    ui)
        args+=(test -scheme GanaBajana -configuration Debug
            -only-testing:GanaBajanaUITests -skip-testing:GanaBajanaUITests/GanaBajanaLiveUITests)
        ;;
    live)
        args+=(test -scheme GanaBajanaLive -configuration Debug
            -only-testing:GanaBajanaTests/CatalogLiveTests
            -only-testing:GanaBajanaTests/StreamLiveIntegrationTests
            -only-testing:GanaBajanaTests/LyricsLiveTests
            -only-testing:GanaBajanaTests/LyricsDNSLiveTests
            -only-testing:GanaBajanaTests/LyricsFallbackLiveTests
            -only-testing:GanaBajanaTests/ExperienceRadioLiveTests)
        ;;
    live-ui)
        args+=(test -scheme GanaBajanaLiveUI -configuration Debug
            -only-testing:GanaBajanaUITests/GanaBajanaLiveUITests)
        ;;
    release)
        args+=(archive -scheme GanaBajana -configuration Release
            -archivePath "$run_directory/GanaBajana.xcarchive")
        if [[ "$release_signing" == unsigned ]]; then
            args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
        else
            args+=(CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES)
        fi
        ;;
esac

if [[ "${SKIP_NATIVE_STOREKIT:-0}" == 1 ]]; then
    if [[ "$mode" == unit ]]; then
        args+=(-skip-testing:GanaBajanaTests/TipJarStoreKitTests)
    elif [[ "$mode" == ui ]]; then
        args+=(-skip-testing:GanaBajanaUITests/GanaBajanaTipJarUITests)
    fi
fi

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

printf 'Mode: %s\nDestination: %s\nArtifacts: %s\n' \
    "$mode" "$destination" "$run_directory" | tee "$log"
xcodebuild -version 2>&1 | tee -a "$log"
xcodegen --version 2>&1 | tee -a "$log"
xcodegen generate --spec "$project_root/project.yml" --project "$project_root" 2>&1 | tee -a "$log"
xcodebuild "${args[@]}" 2>&1 | tee -a "$log"
printf 'Result bundle: %s\n' "$result_bundle"
