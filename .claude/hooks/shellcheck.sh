#!/bin/bash

# Post-edit hook: Run shellcheck on modified shell files
# Called by Claude Code after Edit/Write operations

set -e

FILE_PATH="${1:-}"

# Only run on shell files
if [[ "$FILE_PATH" != *.sh ]] && [[ "$FILE_PATH" != */claude-notify ]]; then
    exit 0
fi

# Check if shellcheck is installed
if ! command -v shellcheck &> /dev/null; then
    echo "[Hook] shellcheck not installed, skipping validation" >&2
    exit 0
fi

# Run shellcheck
if shellcheck "$FILE_PATH" 2>/dev/null; then
    echo "[Hook] shellcheck passed: $FILE_PATH"
else
    echo "[Hook] shellcheck found issues in: $FILE_PATH" >&2
    echo "[Hook] Run 'shellcheck $FILE_PATH' for details" >&2
fi

exit 0
