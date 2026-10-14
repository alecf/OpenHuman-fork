#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product perf-harness
exec .build/release/perf-harness "$@"
