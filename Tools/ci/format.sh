#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
files=()
while IFS= read -r f; do files+=("$f"); done < <(find "$ROOT/Packages" "$ROOT/Apps" -name '*.swift' -not -path '*/.build/*' 2>/dev/null)
(( ${#files[@]} )) || exit 0
if [[ "${1:-}" == "--check" ]]; then
    swift format lint --parallel "${files[@]}"
else
    swift format --in-place --parallel "${files[@]}"
fi
