#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swift build --build-tests
log="$(mktemp -t oh-searcheval-test)"
trap 'rm -f "$log"' EXIT
swift test 2>&1 | tee "$log"
"$(cd .. && pwd)/ci/check-test-log.sh" "$log" "$PWD"
swift run --quiet search-eval --provider none --no-grid
swift run --quiet search-eval --provider fake
