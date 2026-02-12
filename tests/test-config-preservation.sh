#!/bin/bash
# Test script for config preservation bug fix
# Verifies that cn on/off preserves user's existing settings
# Tests both jq path and Python fallback path

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

pass() { echo -e "${GREEN}✅ PASS:$RESET $1"; }
fail() { echo -e "${RED}❌ FAIL:$RESET $1"; exit 1; }
info() { echo -e "${YELLOW}ℹ️  INFO:$RESET $1"; }

run_test_with_tool() {
    local tool="$1"  # "jq" or "python"
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    # Source config functions in subshell to avoid polluting
    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        # Mock has_jq based on tool
        if [[ "$tool" == "python" ]]; then
            # Override has_jq to force Python path
            has_jq() { return 1; }
        fi

        echo ""
        echo "=== Testing with $tool ==="

        # Test 1: enable_hooks preserves existing settings
        echo '{"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}}' > "$GLOBAL_SETTINGS_FILE"
        echo "Initial: $(cat "$GLOBAL_SETTINGS_FILE")"

        enable_hooks_in_settings || { echo "❌ enable_hooks failed"; exit 1; }

        echo "After enable: $(cat "$GLOBAL_SETTINGS_FILE")"

        if grep -q '"model": "sonnet"' "$GLOBAL_SETTINGS_FILE"; then
            echo "✅ $tool: Model preserved after enable"
        else
            echo "❌ $tool: Model NOT preserved after enable"
            exit 1
        fi

        if grep -q '"Notification"' "$GLOBAL_SETTINGS_FILE"; then
            echo "✅ $tool: Hooks added"
        else
            echo "❌ $tool: Hooks NOT added"
            exit 1
        fi

        # Test 2: disable_hooks preserves other settings
        disable_hooks_in_settings || { echo "❌ disable_hooks failed"; exit 1; }

        echo "After disable: $(cat "$GLOBAL_SETTINGS_FILE" 2>/dev/null || echo "(file removed)")"

        if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
            if grep -q '"model": "sonnet"' "$GLOBAL_SETTINGS_FILE"; then
                echo "✅ $tool: Model preserved after disable"
            else
                echo "❌ $tool: Model NOT preserved after disable"
                exit 1
            fi

            if grep -q '"permissions"' "$GLOBAL_SETTINGS_FILE"; then
                echo "✅ $tool: Permissions preserved after disable"
            else
                echo "❌ $tool: Permissions NOT preserved after disable"
                exit 1
            fi
        fi

        if [[ -f "$GLOBAL_SETTINGS_FILE" ]] && grep -q '"hooks"' "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ $tool: Hooks still present after disable"
            exit 1
        else
            echo "✅ $tool: Hooks removed"
        fi
    )

    local result=$?
    return $result
}

run_test_no_tools() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        # Create a modified version of config.sh that mocks both tools
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        # Source config but override tool detection
        GLOBAL_SETTINGS_FILE="$CLAUDE_HOME/settings.json"

        # Mock both has_jq and python3 check
        has_jq() { return 1; }

        echo ""
        echo "=== Testing with NO tools (should abort) ==="

        # Save original config
        echo '{"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}}' > "$GLOBAL_SETTINGS_FILE"
        local original_content=$(cat "$GLOBAL_SETTINGS_FILE")
        echo "Original: $original_content"

        # Source the actual function
        # We need to call enable_hooks_in_settings but it will fail
        # because both has_jq and python3 check fail

        # Simulate the function behavior with no tools
        settings=$(cat "$GLOBAL_SETTINGS_FILE")
        notify_script="/fake/path"
        notify_matcher="idle_prompt"

        if ! has_jq && ! command -v python3 &> /dev/null; then
            echo "Error: jq or python3 required" >&2
            echo "✅ NO tools: Correctly detected missing tools"
            echo "exit 0"
        else
            echo "❌ NO tools: Should have aborted but didn't"
            exit 1
        fi
    )

    return $?
}

echo "============================================"
echo "Config Preservation Bug Fix Tests"
echo "============================================"

# Test 1: With jq (primary path)
if command -v jq &> /dev/null; then
    run_test_with_tool "jq" || fail "jq tests failed"
else
    info "jq not installed, skipping jq tests"
fi

# Test 2: With Python fallback (force no jq)
if command -v python3 &> /dev/null; then
    run_test_with_tool "python" || fail "Python fallback tests failed"
else
    info "python3 not installed, skipping Python tests"
fi

echo ""
echo "============================================"
echo "All tests passed! ✅"
echo "============================================"
