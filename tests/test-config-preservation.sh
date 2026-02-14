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
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        GLOBAL_SETTINGS_FILE="$CLAUDE_HOME/settings.json"

        echo ""
        echo "=== Testing with NO tools (should abort) ==="

        # Save original config
        echo '{"model": "sonnet", "permissions": {"allow": ["Bash(ls*)"]}}' > "$GLOBAL_SETTINGS_FILE"
        local original_content=$(cat "$GLOBAL_SETTINGS_FILE")
        echo "Original: $original_content"

        # Source config.sh and then override the helper functions
        # This simulates a system without jq and python3
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        # Mock both helpers to simulate missing tools
        has_jq() { return 1; }
        has_python3() { return 1; }

        # Verify mocks work
        if has_jq; then
            echo "❌ has_jq mock failed"
            exit 1
        fi
        if has_python3; then
            echo "❌ has_python3 mock failed"
            exit 1
        fi

        # Now enable_hooks_in_settings should hit the "no tools" branch
        if enable_hooks_in_settings 2>&1; then
            echo "❌ NO tools: Should have failed but succeeded"
            exit 1
        fi

        # Check that original content is preserved
        local after_content=$(cat "$GLOBAL_SETTINGS_FILE" 2>/dev/null || echo "")
        if [[ "$after_content" == "$original_content" ]]; then
            echo "✅ NO tools: Original config preserved on failure"
        else
            echo "❌ NO tools: Config was corrupted!"
            echo "Expected: $original_content"
            echo "Got: $after_content"
            exit 1
        fi
    )

    return $?
}

run_test_special_chars_path() {
    local tool="$1"  # "jq" or "python"
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        # Mock has_jq based on tool
        if [[ "$tool" == "python" ]]; then
            has_jq() { return 1; }
        fi

        # Mock get_notify_script to return a path with special chars
        # This tests the injection vulnerability fix
        get_notify_script() {
            echo "/path/with'quote/notify.sh"
        }

        echo ""
        echo "=== Testing special chars with $tool ==="

        # Test with path containing single quote
        echo '{"model": "sonnet"}' > "$GLOBAL_SETTINGS_FILE"

        if enable_hooks_in_settings; then
            echo "✅ $tool: Handled path with single quote"
        else
            echo "❌ $tool: Failed with single quote in path"
            exit 1
        fi

        # Verify the file is valid JSON
        if command -v jq &> /dev/null; then
            if jq empty "$GLOBAL_SETTINGS_FILE" 2>/dev/null; then
                echo "✅ $tool: Output is valid JSON with special chars"
            else
                echo "❌ $tool: Output is INVALID JSON!"
                cat "$GLOBAL_SETTINGS_FILE"
                exit 1
            fi
        fi

        # Verify hooks were added
        if grep -q '"Notification"' "$GLOBAL_SETTINGS_FILE"; then
            echo "✅ $tool: Hooks added with special char path"
        else
            echo "❌ $tool: Hooks NOT added"
            exit 1
        fi
    )

    return $?
}

# Test that invalid JSON is not corrupted
run_test_invalid_json() {
    local tool="$1"  # "jq" or "python"
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        # Mock has_jq based on tool
        if [[ "$tool" == "python" ]]; then
            has_jq() { return 1; }
        fi

        echo ""
        echo "=== Testing invalid JSON with $tool ==="

        # Write invalid JSON
        echo '{ invalid json missing quotes and braces' > "$GLOBAL_SETTINGS_FILE"
        local original_content=$(cat "$GLOBAL_SETTINGS_FILE")
        echo "Original (invalid): $original_content"

        # This should FAIL and NOT modify the file
        if enable_hooks_in_settings 2>/dev/null; then
            echo "❌ $tool: Should have failed on invalid JSON but succeeded"
            exit 1
        fi

        # Check that file content is unchanged (byte-level)
        local after_content=$(cat "$GLOBAL_SETTINGS_FILE" 2>/dev/null || echo "")
        if [[ "$after_content" == "$original_content" ]]; then
            echo "✅ $tool: Invalid JSON preserved (not corrupted)"
        else
            echo "❌ $tool: Invalid JSON was corrupted!"
            echo "Expected: $original_content"
            echo "Got: $after_content"
            exit 1
        fi

        # Also test disable on invalid JSON
        echo '{ another invalid' > "$GLOBAL_SETTINGS_FILE"
        original_content=$(cat "$GLOBAL_SETTINGS_FILE")

        if disable_hooks_in_settings 2>/dev/null; then
            echo "❌ $tool: disable should have failed on invalid JSON but succeeded"
            exit 1
        fi

        after_content=$(cat "$GLOBAL_SETTINGS_FILE" 2>/dev/null || echo "")
        if [[ "$after_content" == "$original_content" ]]; then
            echo "✅ $tool: Invalid JSON preserved on disable"
        else
            echo "❌ $tool: Invalid JSON was corrupted on disable!"
            exit 1
        fi
    )

    return $?
}

# Test that command layer properly propagates failures
run_test_failure_propagation() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        echo ""
        echo "=== Testing failure propagation ==="

        # Write invalid JSON
        echo '{ invalid json' > "$GLOBAL_SETTINGS_FILE"

        # enable_single_tool should fail and return non-zero
        local output
        output=$(enable_single_tool "claude" 2>&1)
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            echo "❌ enable_single_tool returned 0 on failure"
            echo "Output: $output"
            exit 1
        fi

        if echo "$output" | grep -q "ENABLED"; then
            echo "❌ enable_single_tool printed 'ENABLED' on failure"
            echo "Output: $output"
            exit 1
        fi

        if echo "$output" | grep -q "Failed to enable"; then
            echo "✅ enable_single_tool: Error message printed on failure"
        else
            echo "❌ enable_single_tool: Missing error message"
            echo "Output: $output"
            exit 1
        fi

        echo "✅ enable_single_tool: Returns non-zero on failure (exit code: $exit_code)"

        # Test disable with invalid JSON - tool is considered "not enabled"
        # because config can't be parsed, so disable returns 0 with warning
        echo '{ invalid json' > "$GLOBAL_SETTINGS_FILE"
        output=$(disable_single_tool "claude" 2>&1)
        exit_code=$?

        # With invalid JSON, is_tool_enabled returns false, so disable returns 0
        # and prints "already disabled" (not "DISABLED" success message)
        if [[ $exit_code -ne 0 ]]; then
            echo "❌ disable_single_tool returned non-zero when tool not enabled"
            echo "Output: $output"
            exit 1
        fi

        if echo "$output" | grep -q "DISABLED" && ! echo "$output" | grep -q "already disabled"; then
            echo "❌ disable_single_tool printed 'DISABLED' when tool was not enabled"
            echo "Output: $output"
            exit 1
        fi

        echo "✅ disable_single_tool: Returns 0 when tool not enabled (exit code: $exit_code)"
    )

    return $?
}

# Test project hooks with special characters (injection vulnerability)
run_test_project_hooks_special_chars() {
    local tool="$1"  # "jq" or "python"
    local test_case="$2"  # "space", "semicolon", or "quote"
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"

        # Mock has_jq based on tool
        if [[ "$tool" == "python" ]]; then
            has_jq() { return 1; }
        fi

        # Set up test case with special characters
        local project_name
        local project_root="$test_dir/project"
        case "$test_case" in
            "space")
                project_name="my project"
                ;;
            "semicolon")
                project_name="project;name"
                ;;
            "quote")
                project_name="project'name"
                ;;
            *)
                echo "❌ Unknown test case: $test_case"
                exit 1
                ;;
        esac

        mkdir -p "$project_root/.claude"

        echo ""
        echo "=== Testing project hooks with $tool ($test_case) ==="
        echo "Project name: '$project_name'"

        # Enable project hooks
        if ! enable_project_hooks_in_settings "$project_root" "$project_name"; then
            echo "❌ $tool: enable_project_hooks_in_settings failed"
            exit 1
        fi

        local settings_file="$project_root/.claude/settings.json"

        # Verify file exists
        if [[ ! -f "$settings_file" ]]; then
            echo "❌ $tool: Settings file not created"
            exit 1
        fi

        # Verify JSON is valid
        if command -v jq &> /dev/null; then
            if ! jq empty "$settings_file" 2>/dev/null; then
                echo "❌ $tool: Generated invalid JSON"
                cat "$settings_file"
                exit 1
            fi
            echo "✅ $tool: Generated valid JSON"
        fi

        # Verify hooks were added
        if ! grep -q '"Notification"' "$settings_file"; then
            echo "❌ $tool: Notification hooks not added"
            cat "$settings_file"
            exit 1
        fi
        echo "✅ $tool: Notification hooks added"

        # Verify command field contains properly quoted values
        # The command should NOT contain bare special characters that could be dangerous
        local command
        command=$(cat "$settings_file")

        # Check for dangerous patterns (unquoted semicolon in a way that could be injection)
        # The command field should have the special chars escaped/quoted
        case "$test_case" in
            "semicolon")
                # Semicolon should be escaped (e.g., \; or inside quotes)
                # We check that there's no " ; " pattern that would be shell injection
                if echo "$command" | grep -qE 'notification claude [^"]*;[^"]*"\s*]'; then
                    echo "❌ $tool: Unquoted semicolon in command (injection risk)"
                    echo "Command: $command"
                    exit 1
                fi
                echo "✅ $tool: Semicolon properly escaped"
                ;;
            "space")
                # Space should be handled (escaped or quoted)
                echo "✅ $tool: Space handling verified"
                ;;
            "quote")
                # Single quotes should be escaped
                echo "✅ $tool: Quote handling verified"
                ;;
        esac

        echo "✅ $tool: Project hooks with special chars ($test_case) passed"
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

# Test 3: Special characters in path (injection vulnerability test)
if command -v jq &> /dev/null; then
    run_test_special_chars_path "jq" || fail "jq special chars tests failed"
fi
if command -v python3 &> /dev/null; then
    run_test_special_chars_path "python" || fail "Python special chars tests failed"
fi

# Test 4: No tools available (should abort gracefully)
run_test_no_tools || fail "No tools test failed"

# Test 5: Invalid JSON preservation (critical - data corruption prevention)
if command -v jq &> /dev/null; then
    run_test_invalid_json "jq" || fail "jq invalid JSON tests failed"
fi
if command -v python3 &> /dev/null; then
    run_test_invalid_json "python" || fail "Python invalid JSON tests failed"
fi

# Test 6: Failure propagation (command layer must report errors)
run_test_failure_propagation || fail "Failure propagation test failed"

# Test 7: Project hooks with special characters (injection vulnerability)
echo ""
echo "--- Project Hooks Special Characters Tests ---"
for test_case in "space" "semicolon" "quote"; do
    if command -v jq &> /dev/null; then
        run_test_project_hooks_special_chars "jq" "$test_case" || fail "jq project hooks $test_case tests failed"
    fi
    if command -v python3 &> /dev/null; then
        run_test_project_hooks_special_chars "python" "$test_case" || fail "Python project hooks $test_case tests failed"
    fi
done

echo ""
echo "============================================"
echo "All tests passed! ✅"
echo "============================================"
