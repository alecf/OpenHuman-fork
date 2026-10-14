#!/usr/bin/env bash
exec "$(dirname "$0")/build-packages.sh" --build-only "$@"
