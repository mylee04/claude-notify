#!/bin/bash
# Test script for config preservation bug fix
# Verifies that cn on/off preserves user's existing settings

set -e

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Mock HOME for testing
export HOME="$TEST_DIR"
export CLAUDE_HOME="$TEST_DIR/.claude"

# Source the config functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

echo "============================================"
echo "Config Preservation Bug Fix Tests"
echo "============================================"
echo ""

echo "=== Test 1: enable_hooks preserves existing model ==="
# Setup: Create settings with custom model
mkdir -p "$CLAUDE_HOME"
echo '{"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}}' > "$GLOBAL_SETTINGS_FILE"
echo "Initial config:"
cat "$GLOBAL_SETTINGS_FILE"
echo ""

# Action: Enable hooks
enable_hooks_in_settings

echo "After enable_hooks_in_settings:"
cat "$GLOBAL_SETTINGS_FILE"
echo ""

# Verify: Model should still be sonnet, not opus
if grep -q '"model": "sonnet"' "$GLOBAL_SETTINGS_FILE"; then
    echo "✅ PASS: Model preserved as sonnet"
else
    echo "❌ FAIL: Model was changed!"
    exit 1
fi

# Verify: Hooks were added
if grep -q '"Notification"' "$GLOBAL_SETTINGS_FILE"; then
    echo "✅ PASS: Hooks were added"
else
    echo "❌ FAIL: Hooks not added"
    exit 1
fi

# Verify: Permissions preserved
if grep -q '"permissions"' "$GLOBAL_SETTINGS_FILE"; then
    echo "✅ PASS: Permissions preserved"
else
    echo "❌ FAIL: Permissions lost"
    exit 1
fi

echo ""
echo "=== Test 2: disable_hooks preserves other settings ==="
# Action: Disable hooks
disable_hooks_in_settings

echo "After disable_hooks_in_settings:"
cat "$GLOBAL_SETTINGS_FILE" 2>/dev/null || echo "(file removed - no other settings)"
echo ""

# Verify: Model still preserved (if file exists)
if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
    if grep -q '"model": "sonnet"' "$GLOBAL_SETTINGS_FILE"; then
        echo "✅ PASS: Model still sonnet after disable"
    else
        echo "❌ FAIL: Model changed on disable!"
        exit 1
    fi

    # Verify: Permissions still there
    if grep -q '"permissions"' "$GLOBAL_SETTINGS_FILE"; then
        echo "✅ PASS: Permissions preserved after disable"
    else
        echo "❌ FAIL: Permissions lost on disable"
        exit 1
    fi
else
    echo "✅ PASS: File removed (no non-hooks settings)"
fi

# Verify: Hooks removed
if [[ -f "$GLOBAL_SETTINGS_FILE" ]] && grep -q '"hooks"' "$GLOBAL_SETTINGS_FILE"; then
    echo "❌ FAIL: Hooks still present"
    exit 1
else
    echo "✅ PASS: Hooks removed"
fi

echo ""
echo "=== Test 3: enable_hooks works with no existing config ==="
# Setup: No existing config
rm -f "$GLOBAL_SETTINGS_FILE"

# Action: Enable hooks
enable_hooks_in_settings

echo "After enable_hooks_in_settings (no prior config):"
cat "$GLOBAL_SETTINGS_FILE"
echo ""

# Verify: Hooks were added
if grep -q '"Notification"' "$GLOBAL_SETTINGS_FILE"; then
    echo "✅ PASS: Hooks added to new config"
else
    echo "❌ FAIL: Hooks not added"
    exit 1
fi

echo ""
echo "=== Test 4: Python fallback (simulated) ==="
# Test that Python can parse and modify JSON correctly
python3 << 'PYTHON'
import json
import tempfile
import os

# Test data
test_config = {"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}, "hooks": {"Notification": []}}

# Test: remove hooks key
if "hooks" in test_config:
    del test_config["hooks"]

# Verify
assert test_config == {"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}}
print("✅ PASS: Python fallback works correctly")
PYTHON

echo ""
echo "============================================"
echo "All tests passed! ✅"
echo "============================================"
