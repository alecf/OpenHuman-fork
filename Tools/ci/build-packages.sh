#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APPLE_ONLY="OpenHumanMailUI OpenHumanAIMLX"

usage() {
    cat <<'EOF'
Usage: Tools/ci/build-packages.sh [--platform macos|linux] [--build-only | --test-only] [Package ...]

Builds and tests every package in Packages/, or only the packages named.

  --platform <macos|linux>  default: the host. On linux the Apple-only packages are skipped;
                            the product targets macOS, so a linux run is a convenience only.
  --build-only              build the packages and their tests, run nothing
  --test-only               run the tests (swift test still builds first)
  -h, --help                show this help

OH_SCRATCH_ROOT=<dir>  build each package in <dir>/<Package> (swift --scratch-path) instead of its
                       .build folder, so the cache can live outside the checkout between runs.
EOF
}

platform=""; mode="all"; selected=()
while (( $# )); do
    case "$1" in
        --platform) platform="$2"; shift 2 ;;
        --build-only) mode="build"; shift ;;
        --test-only) mode="test"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) selected+=("$1"); shift ;;
    esac
done
if [[ -z "$platform" ]]; then
    [[ "$(uname -s)" == "Darwin" ]] && platform="macos" || platform="linux"
fi
[[ "$platform" == "macos" || "$platform" == "linux" ]] || { echo "unknown platform: $platform" >&2; exit 2; }

swift --version | head -1
failed=()
for manifest in "$ROOT"/Packages/*/Package.swift; do
    dir="$(dirname "$manifest")"; pkg="$(basename "$dir")"
    if (( ${#selected[@]} )) && [[ " ${selected[*]} " != *" $pkg "* ]]; then continue; fi
    if [[ "$platform" == "linux" && " $APPLE_ONLY " == *" $pkg "* ]]; then
        echo "== $pkg: skipped on linux (Apple-only)"; continue
    fi
    scratch=()
    [[ -z "${OH_SCRATCH_ROOT:-}" ]] || scratch=(--scratch-path "$OH_SCRATCH_ROOT/$pkg")
    echo "== $pkg ($mode, $platform)"
    ok=1
    if [[ "$mode" != "test" ]]; then
        (cd "$dir" && swift build --build-tests ${scratch[@]+"${scratch[@]}"}) || ok=0
    fi
    if [[ "$ok" == 1 && "$mode" != "build" ]]; then
        log="$(mktemp -t "oh-test-$pkg")"
        (cd "$dir" && swift test ${scratch[@]+"${scratch[@]}"} 2>&1 | tee "$log"; exit "${PIPESTATUS[0]}") || ok=0
        if [[ "$ok" == 1 ]] && ! "$ROOT/Tools/ci/check-test-log.sh" "$log" "$dir"; then
            echo "== $pkg: incomplete test run"; ok=0
        fi
        rm -f "$log"
    fi
    (( ok )) || failed+=("$pkg")
done

if (( ${#failed[@]} )); then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "All packages OK ($mode, $platform)"
