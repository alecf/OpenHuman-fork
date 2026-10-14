#!/usr/bin/env bash
# swift test can exit 0 after a swift-testing run stops early, so the log must show every run finishing
set -euo pipefail
log="${1:?usage: check-test-log.sh <log-file> [<package-dir>]}"
pkg="${2:-}"
clean="$(sed $'s/\x1b\\[[0-9;]*m//g' "$log")"
started="$(grep -cE 'Test run started' <<<"$clean" || true)"
finished="$(grep -cE 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' <<<"$clean" || true)"
if (( started != finished )); then
    echo "swift-testing run started but never finished: $started started, $finished finished" >&2
    exit 1
fi
has_tests=0
if [[ -n "$pkg" && -d "$pkg/Tests" ]] && grep -rlq --include='*.swift' -E '^\s*(@testable )?import Testing' "$pkg/Tests"; then
    has_tests=1
fi
if (( has_tests )); then
    if (( finished == 0 )); then
        echo "swift-testing run missing: package has swift-testing test files but no run was reported" >&2
        exit 1
    fi
    total="$(grep -oE 'Test run with [0-9]+ tests?' <<<"$clean" | grep -oE '[0-9]+' | paste -sd+ - | bc)"
    if (( total == 0 )); then
        echo "swift-testing run reported 0 tests for a package that has test files" >&2
        exit 1
    fi
fi
exit 0
