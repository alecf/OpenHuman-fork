#!/usr/bin/env bash
python3 -B "$(dirname "$0")/check-test-patterns.py" || exit $?
exec "$(dirname "$0")/build-packages.sh" --test-only "$@"
