#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo "usage: $0 <prompt-id> <fixture.json>" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec swift run --quiet --package-path "$ROOT" ai-render "$1" "$2"
