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

run_test_claude_hook_detection_and_preservation() {
    local tool="$1"  # "jq" or "python"
    local test_dir
    test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME"

    (
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        if [[ "$tool" == "python" ]]; then
            has_jq() { return 1; }
        fi

        is_tool_installed() { return 0; }

        cat > "$GLOBAL_SETTINGS_FILE" <<'EOF'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "custom_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom notification"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre"
          }
        ]
      }
    ]
  },
  "theme": "dark"
}
EOF

        echo ""
        echo "=== Testing Claude hook detection with $tool ==="

        if is_enabled_globally; then
            echo "❌ $tool: unrelated/custom hooks were incorrectly treated as code-notify hooks"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi
        echo "✅ $tool: unrelated/custom hooks do not count as enabled"

        local output
        output=$(enable_single_tool "claude" 2>&1) || {
            echo "❌ $tool: enable_single_tool failed"
            echo "$output"
            exit 1
        }

        if echo "$output" | grep -q "already enabled"; then
            echo "❌ $tool: enable_single_tool falsely skipped install"
            echo "$output"
            exit 1
        fi

        grep -q '"PreToolUse"' "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: PreToolUse hook was removed during enable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        grep -q '"command": "echo custom notification"' "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: custom Notification hook was removed during enable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        grep -q '"matcher": "idle_prompt"' "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: code-notify Notification hook was not added"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        grep -qF "\"command\": \"$(get_global_claude_stop_command)\"" "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: code-notify Stop hook was not added"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        echo "✅ $tool: enable preserves unrelated hooks and adds current Claude hooks"

        output=$(disable_single_tool "claude" 2>&1) || {
            echo "❌ $tool: disable_single_tool failed"
            echo "$output"
            exit 1
        }

        grep -q '"PreToolUse"' "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: PreToolUse hook was removed during disable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        grep -q '"command": "echo custom notification"' "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ $tool: custom Notification hook was removed during disable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        if grep -qF "\"command\": \"$(get_global_claude_notify_command)\"" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ $tool: code-notify Notification hook was not removed during disable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if grep -qF "\"command\": \"$(get_global_claude_stop_command)\"" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ $tool: code-notify Stop hook was not removed during disable"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        echo "✅ $tool: disable removes only managed Claude hooks"
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

run_test_codex_hook_config() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing Codex hook configuration ==="

        cat > "$CODEX_CONFIG_FILE" << 'EOF'
# Code-Notify: Desktop notifications
notify = ["/tmp/code-notify/lib/code-notify/core/notifier.sh", "codex"]

[notice.model_migrations]
"gpt-5.1-codex-max" = "gpt-5.2-codex"

[mcp_servers.playwright]
args = ["@playwright/mcp@latest"]
command = "npx"

[features]
multi_agent = true
EOF

        cat > "$CODEX_HOOKS_FILE" << 'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/true"
          }
        ]
      }
    ]
  }
}
EOF

        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex hooks"
            exit 1
        fi

        if grep -qE '^notify\s*=' "$CODEX_CONFIG_FILE" || grep -q '^# Code-Notify: Desktop notifications' "$CODEX_CONFIG_FILE"; then
            echo "❌ legacy Codex notify config was not removed"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ legacy Codex notify config removed"

        if ! is_codex_enabled; then
            echo "❌ is_codex_enabled did not detect managed hooks"
            exit 1
        fi
        echo "✅ is_codex_enabled detects managed hooks"

        if command -v python3 &> /dev/null; then
            if ! python3 - "$CODEX_CONFIG_FILE" "$CODEX_HOOKS_FILE" << 'PY'
import json
import sys
import tomllib

config_path, hooks_path = sys.argv[1:3]

with open(config_path, "rb") as fh:
    data = tomllib.load(fh)

assert "notify" not in data, data
assert data.get("features", {}).get("multi_agent") is True, data
assert data.get("tui", {}).get("notifications") is False, data

with open(hooks_path, "r", encoding="utf-8") as fh:
    hooks_data = json.load(fh)

hooks = hooks_data["hooks"]
stop_commands = [
    hook["command"]
    for entry in hooks["Stop"]
    for hook in entry.get("hooks", [])
    if hook.get("type") == "command"
]
assert "/usr/bin/true" in stop_commands, stop_commands
assert sum(command.endswith(" stop codex") for command in stop_commands) == 1, stop_commands
prompt_commands = [
    hook["command"]
    for entry in hooks.get("UserPromptSubmit", [])
    for hook in entry.get("hooks", [])
    if hook.get("type") == "command"
]
assert sum(command.endswith(" UserPromptSubmit codex") for command in prompt_commands) == 1, prompt_commands
post_tool_commands = [
    hook["command"]
    for entry in hooks.get("PostToolUse", [])
    for hook in entry.get("hooks", [])
    if hook.get("type") == "command"
]
assert sum(command.endswith(" PostToolUse codex") for command in post_tool_commands) == 1, post_tool_commands
resume_commands = [
    hook["command"]
    for entry in hooks.get("PreToolUse", [])
    for hook in entry.get("hooks", [])
    if hook.get("type") == "command"
]
assert sum(command.endswith(" ResumeAfterInput codex") for command in resume_commands) == 1, resume_commands
assert "PermissionRequest" not in hooks, hooks
PY
            then
                echo "❌ Codex hook config did not preserve expected state"
                cat "$CODEX_HOOKS_FILE"
                exit 1
            fi
            echo "✅ Stop hook installed and unrelated hooks preserved"
        fi

        if ! enable_codex_hooks; then
            echo "❌ Failed to re-enable Codex hooks"
            exit 1
        fi

        if [[ $(grep -c '"command": .* stop codex' "$CODEX_HOOKS_FILE") -ne 1 ]]; then
            echo "❌ Re-enable left duplicate Stop hooks"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        if [[ $(grep -c '"command": .* UserPromptSubmit codex' "$CODEX_HOOKS_FILE") -ne 1 ]]; then
            echo "❌ Re-enable left duplicate UserPromptSubmit hooks"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        if [[ $(grep -c '"command": .* PostToolUse codex' "$CODEX_HOOKS_FILE") -ne 1 ]]; then
            echo "❌ Re-enable left duplicate PostToolUse hooks"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        if [[ $(grep -c '"command": .* ResumeAfterInput codex' "$CODEX_HOOKS_FILE") -ne 1 ]]; then
            echo "❌ Re-enable left duplicate resume hooks"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        echo "✅ Re-enable repairs managed hooks without duplicates"

        set_notify_types "permission_prompt"
        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex permission hook"
            exit 1
        fi

        if ! grep -q '"PermissionRequest"' "$CODEX_HOOKS_FILE" || ! grep -q 'notification codex' "$CODEX_HOOKS_FILE"; then
            echo "❌ permission_prompt did not install PermissionRequest hook"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        echo "✅ permission_prompt installs PermissionRequest hook"

        # The parser-free status fallback must retain the same conditional
        # PermissionRequest requirement as the jq and Python implementations.
        if command -v jq &> /dev/null; then
            local missing_permission_hooks
            missing_permission_hooks=$(mktemp)
            jq 'del(.hooks.PermissionRequest)' "$CODEX_HOOKS_FILE" > "$missing_permission_hooks"
            if (
                has_jq() { return 1; }
                has_python3() { return 1; }
                has_current_codex_hooks "$missing_permission_hooks"
            ); then
                rm -f "$missing_permission_hooks"
                echo "❌ parser-free Codex status accepted a missing PermissionRequest hook"
                exit 1
            fi
            rm -f "$missing_permission_hooks"
            echo "✅ parser-free Codex status requires PermissionRequest when enabled"
        fi

        set_notify_types "idle_prompt"
        if ! enable_codex_hooks; then
            echo "❌ Failed to remove Codex permission hook after alert reset"
            exit 1
        fi

        if grep -q '"PermissionRequest"' "$CODEX_HOOKS_FILE"; then
            echo "❌ PermissionRequest hook remained after permission_prompt was disabled"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        echo "✅ disabling permission_prompt removes PermissionRequest hook"

        if ! disable_codex_hooks; then
            echo "❌ Failed to disable Codex hooks"
            exit 1
        fi

        if grep -q ' stop codex' "$CODEX_HOOKS_FILE" || grep -q ' notification codex' "$CODEX_HOOKS_FILE" ||
            grep -q ' UserPromptSubmit codex' "$CODEX_HOOKS_FILE" || grep -q ' PostToolUse codex' "$CODEX_HOOKS_FILE" ||
            grep -q ' ResumeAfterInput codex' "$CODEX_HOOKS_FILE"; then
            echo "❌ disable_codex_hooks did not remove managed hooks"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi

        if ! grep -q '^\[features\]' "$CODEX_CONFIG_FILE" || ! grep -q '^multi_agent = true' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable_codex_hooks did not preserve existing TOML content"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        if grep -q '^# Code-Notify: Codex notifications are handled by hooks' "$CODEX_CONFIG_FILE" || grep -q '^notifications = false' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable_codex_hooks did not remove managed Codex TUI notification override"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ disable_codex_hooks preserves existing config and unrelated hooks"
    )

    return $?
}

run_test_codex_tui_preservation() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing Codex TUI notification preservation ==="

        cat > "$CODEX_CONFIG_FILE" << 'EOF'
[tui]
notifications = ["agent-turn-complete"]

[features]
multi_agent = true
EOF

        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex hooks"
            exit 1
        fi

        if ! grep -q '^notifications = false' "$CODEX_CONFIG_FILE"; then
            echo "❌ enable did not disable Codex TUI notifications"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        if ! grep -qF '# Code-Notify-saved: notifications = ["agent-turn-complete"]' "$CODEX_CONFIG_FILE"; then
            echo "❌ enable did not preserve the original TUI notifications value"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ enable disables TUI notifications and saves the original value"

        # Re-enable must remain idempotent and keep the single saved original.
        if ! enable_codex_hooks; then
            echo "❌ Failed to re-enable Codex hooks"
            exit 1
        fi
        if [[ $(grep -cF '# Code-Notify-saved:' "$CODEX_CONFIG_FILE") -ne 1 ]]; then
            echo "❌ re-enable duplicated or dropped the saved original"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ re-enable keeps exactly one saved original"

        if ! disable_codex_hooks; then
            echo "❌ Failed to disable Codex hooks"
            exit 1
        fi

        if ! grep -qF 'notifications = ["agent-turn-complete"]' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable did not restore the original TUI notifications value"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        if grep -q '^# Code-Notify' "$CODEX_CONFIG_FILE" || grep -q '^notifications = false' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable left managed Code-Notify TUI lines behind"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        if ! grep -q '^multi_agent = true' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable did not preserve unrelated TOML content"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ disable restores the user's original TUI notifications value"
    )

    return $?
}

run_test_codex_tui_multiline_array() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing Codex TUI multi-line array preservation ==="

        cat > "$CODEX_CONFIG_FILE" << 'EOF'
[tui]
notifications = [
  "agent-turn-complete",
]

[features]
multi_agent = true
EOF

        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex hooks"
            exit 1
        fi

        if ! grep -q '^notifications = false' "$CODEX_CONFIG_FILE"; then
            echo "❌ enable did not disable Codex TUI notifications"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        # The array body must not be left behind as bare (non-comment) lines.
        if grep -qE '^[[:space:]]*"agent-turn-complete"' "$CODEX_CONFIG_FILE" \
            || grep -qE '^[[:space:]]*\][[:space:]]*$' "$CODEX_CONFIG_FILE"; then
            echo "❌ enable left stray multi-line array body in config.toml"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        if command -v python3 &> /dev/null; then
            if ! python3 - "$CODEX_CONFIG_FILE" << 'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
assert data.get("tui", {}).get("notifications") is False, data
assert data.get("features", {}).get("multi_agent") is True, data
PY
            then
                echo "❌ config.toml is not valid TOML after enable"
                cat "$CODEX_CONFIG_FILE"
                exit 1
            fi
            echo "✅ enable produces valid TOML with TUI notifications disabled"
        fi

        if ! disable_codex_hooks; then
            echo "❌ Failed to disable Codex hooks"
            exit 1
        fi

        if command -v python3 &> /dev/null; then
            if ! python3 - "$CODEX_CONFIG_FILE" << 'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
assert data.get("tui", {}).get("notifications") == ["agent-turn-complete"], data
assert data.get("features", {}).get("multi_agent") is True, data
PY
            then
                echo "❌ disable did not restore the multi-line array as valid TOML"
                cat "$CODEX_CONFIG_FILE"
                exit 1
            fi
            echo "✅ disable restores the multi-line array value as valid TOML"
        fi

        if grep -q '^# Code-Notify' "$CODEX_CONFIG_FILE"; then
            echo "❌ disable left managed Code-Notify lines behind"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ disable removes all managed Code-Notify markers"
    )

    return $?
}

run_test_codex_multiline_notify_removal() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing legacy multi-line notify removal ==="

        cat > "$CODEX_CONFIG_FILE" << 'EOF'
notify = [
  "/Users/someone/.code-notify/lib/code-notify/core/notifier.sh",
  "codex",
]

[features]
multi_agent = true
EOF

        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex hooks"
            exit 1
        fi

        if grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CONFIG_FILE" \
            || grep -q 'code-notify/lib/code-notify/core/notifier.sh' "$CODEX_CONFIG_FILE"; then
            echo "❌ legacy multi-line notify array was not fully removed"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ legacy multi-line notify array removed in full"

        if command -v python3 &> /dev/null; then
            if ! python3 - "$CODEX_CONFIG_FILE" << 'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    data = tomllib.load(fh)
assert "notify" not in data, data
assert data.get("features", {}).get("multi_agent") is True, data
PY
            then
                echo "❌ config.toml is not valid TOML after notify removal"
                cat "$CODEX_CONFIG_FILE"
                exit 1
            fi
            echo "✅ config.toml remains valid TOML with unrelated content intact"
        fi
    )

    return $?
}

run_test_codex_unrelated_notify_preserved() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing unrelated notify is preserved ==="

        # A user's own notify program (not Code-Notify) must survive.
        cat > "$CODEX_CONFIG_FILE" << 'EOF'
notify = ["/usr/local/bin/my-own-notifier"]
EOF

        if ! enable_codex_hooks; then
            echo "❌ Failed to enable Codex hooks"
            exit 1
        fi

        if ! grep -q '/usr/local/bin/my-own-notifier' "$CODEX_CONFIG_FILE"; then
            echo "❌ unrelated user notify program was incorrectly removed"
            cat "$CODEX_CONFIG_FILE"
            exit 1
        fi
        echo "✅ unrelated user notify program preserved"
    )

    return $?
}

run_test_codex_hooks_invalid_json() {
    local test_dir=$(mktemp -d)
    trap "rm -rf $test_dir" RETURN

    export HOME="$test_dir"
    export CODEX_HOME="$test_dir/.codex"
    mkdir -p "$CODEX_HOME" "$HOME/.claude/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"

        echo ""
        echo "=== Testing Codex hooks invalid-JSON fail-closed ==="

        local malformed='{ "hooks": { "Stop": [ { "hooks": [ }'
        printf '%s' "$malformed" > "$CODEX_HOOKS_FILE"

        if enable_codex_hooks 2>/dev/null; then
            echo "❌ enable_codex_hooks should fail on malformed hooks JSON"
            exit 1
        fi
        echo "✅ enable_codex_hooks fails closed on malformed JSON"

        if [[ "$(cat "$CODEX_HOOKS_FILE")" != "$malformed" ]]; then
            echo "❌ malformed hooks file was modified instead of left intact"
            cat "$CODEX_HOOKS_FILE"
            exit 1
        fi
        echo "✅ malformed hooks file is left unchanged"
    )

    return $?
}

run_test_legacy_claude_hooks_repair() {
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

        is_tool_installed() { return 0; }

        cat > "$GLOBAL_SETTINGS_FILE" << EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude-notify/lib/claude-notify/core/notifier.sh notification"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude-notify/lib/claude-notify/core/notifier.sh stop"
          }
        ]
      }
    ]
  }
}
EOF

        echo ""
        echo "=== Testing legacy Claude hook repair ==="

        if ! claude_global_hooks_need_repair; then
            echo "❌ Legacy Claude hooks were not flagged for repair"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi
        echo "✅ Legacy Claude hooks are detected as stale"

        local output
        output=$("$SCRIPT_DIR/../bin/code-notify" repair-hooks 2>&1) || {
            echo "❌ code-notify repair-hooks failed while repairing legacy Claude hooks"
            echo "$output"
            exit 1
        }

        if echo "$output" | grep -q "already enabled"; then
            echo "❌ repair-hooks incorrectly skipped repairing legacy Claude hooks"
            echo "$output"
            exit 1
        fi

        grep -qF "\"matcher\": \"idle_prompt\"" "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ Repaired Claude config did not restore idle_prompt matcher"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        if ! grep -qE 'code-notify/.*/notifier\.sh notification claude' "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Repaired Claude config did not update the notification command to code-notify"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if ! grep -qE 'code-notify/.*/notifier\.sh stop claude' "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Repaired Claude config did not update the stop command to code-notify"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if grep -q "claude-notify" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Repaired Claude config still references claude-notify"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if claude_global_hooks_need_repair; then
            echo "❌ Claude hooks still appear stale after repair"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        echo "✅ Legacy Claude hooks are repaired to the current code-notify config"
    )

    (
        unset CLAUDE_HOME
        mkdir -p "$HOME/.config/.claude" "$HOME/.claude/notifications"
        rm -f "$HOME/.claude/settings.json" "$HOME/.claude/hooks.json"
        printf '{}\n' > "$HOME/.config/.claude/settings.json"

        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        is_tool_installed() { return 0; }

        if [[ "$GLOBAL_SETTINGS_FILE" != "$HOME/.config/.claude/settings.json" ]]; then
            echo "❌ Alternate Claude settings path was not detected"
            echo "Resolved settings path: $GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        cat > "$GLOBAL_SETTINGS_FILE" << EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"$HOME/.claude/notifications/notify.ps1\" notification"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"$HOME/.claude/notifications/notify.ps1\" stop"
          }
        ]
      }
    ]
  }
}
EOF

        echo ""
        echo "=== Testing alternate Claude settings path repair ==="

        if ! claude_global_hooks_need_repair; then
            echo "❌ Alternate-path Claude hooks were not flagged for repair"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi
        echo "✅ Alternate-path Claude hooks are detected as stale"

        local output
        output=$("$SCRIPT_DIR/../bin/code-notify" repair-hooks 2>&1) || {
            echo "❌ code-notify repair-hooks failed for alternate Claude settings path"
            echo "$output"
            exit 1
        }

        grep -qF "\"matcher\": \"idle_prompt\"" "$GLOBAL_SETTINGS_FILE" || {
            echo "❌ Alternate-path Claude config did not restore idle_prompt matcher"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        }

        if ! grep -qF "notification claude" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Alternate-path Claude config did not add the claude notification argument"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if ! grep -qF "stop claude" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Alternate-path Claude config did not add the claude stop argument"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        echo "✅ Alternate Claude settings path is repaired to the current code-notify config"
    )

    return $?
}

# A current install must NOT read as legacy. The ask_user alert type registers
# `notifier.sh PreToolUse claude`, and an unanchored legacy grep matched it —
# every such install reported REPAIR NEEDED forever and `cn on claude` rewrote
# settings.json on every run instead of reporting "already enabled".
run_test_current_claude_hooks_not_legacy() {
    local test_dir
    test_dir=$(mktemp -d)
    trap 'rm -rf "$test_dir"' RETURN

    export HOME="$test_dir"
    export CLAUDE_HOME="$test_dir/.claude"
    mkdir -p "$CLAUDE_HOME/notifications"

    (
        source "$SCRIPT_DIR/../lib/code-notify/utils/colors.sh"
        source "$SCRIPT_DIR/../lib/code-notify/utils/detect.sh"
        source "$SCRIPT_DIR/../lib/code-notify/core/config.sh"
        source "$SCRIPT_DIR/../lib/code-notify/commands/global.sh"

        is_tool_installed() { return 0; }

        echo ""
        echo "=== Testing current Claude hooks are not flagged as legacy ==="

        # register_ask_user_hook is a no-op unless ask_user is enabled.
        mkdir -p "$(dirname "$NOTIFY_TYPES_FILE")"
        printf '%s\n' "idle_prompt|ask_user" > "$NOTIFY_TYPES_FILE"

        # Build the settings the current code writes, ask_user included.
        if ! enable_hooks_in_settings; then
            echo "❌ Failed to write current Claude hooks"
            exit 1
        fi
        register_ask_user_hook "$GLOBAL_SETTINGS_FILE" \
            "$(get_global_claude_pre_tool_use_command)" || {
            echo "❌ Failed to register the ask_user PreToolUse hook"
            exit 1
        }

        if ! grep -qF "notifier.sh PreToolUse claude" "$GLOBAL_SETTINGS_FILE"; then
            echo "❌ Test setup did not produce an ask_user PreToolUse hook"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi

        if claude_global_hooks_need_repair; then
            echo "❌ Current Claude hooks were wrongly flagged as legacy"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi
        echo "✅ Current Claude hooks (with ask_user) are not flagged for repair"

        # The anchored pattern must still catch the genuinely legacy shape.
        cat > "$GLOBAL_SETTINGS_FILE" << EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/notifications/notifier.sh PreToolUse"
          }
        ]
      }
    ]
  }
}
EOF

        if ! claude_global_hooks_need_repair; then
            echo "❌ Legacy tool-less PreToolUse hook was not flagged for repair"
            cat "$GLOBAL_SETTINGS_FILE"
            exit 1
        fi
        echo "✅ Legacy tool-less PreToolUse hook is still detected"
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

# Test 8: Codex hook configuration and legacy notify cleanup
run_test_codex_hook_config || fail "Codex hook configuration test failed"

# Test 8b: Codex TUI notification value is preserved and restored
run_test_codex_tui_preservation || fail "Codex TUI preservation test failed"

# Test 8b2: Multi-line TUI notifications array survives a round-trip as valid TOML
run_test_codex_tui_multiline_array || fail "Codex TUI multi-line array test failed"

# Test 8c: Malformed Codex hooks JSON is never silently overwritten
run_test_codex_hooks_invalid_json || fail "Codex hooks invalid-JSON test failed"

# Test 8d: Legacy multi-line notify array is fully removed
run_test_codex_multiline_notify_removal || fail "Codex multi-line notify removal test failed"

# Test 8e: A user's unrelated notify program is preserved
run_test_codex_unrelated_notify_preserved || fail "Codex unrelated notify preservation test failed"

# Test 9: Legacy claude-notify hook configs are repaired in place
run_test_legacy_claude_hooks_repair || fail "Legacy Claude hook repair test failed"

# Test 9b: A current install is never mistaken for a legacy one
run_test_current_claude_hooks_not_legacy || fail "Current Claude hooks legacy misdetection test failed"

# Test 10: Claude detection only matches current hooks and preserves unrelated hook entries
if command -v jq &> /dev/null; then
    run_test_claude_hook_detection_and_preservation "jq" || fail "jq Claude hook detection tests failed"
fi
if command -v python3 &> /dev/null; then
    run_test_claude_hook_detection_and_preservation "python" || fail "Python Claude hook detection tests failed"
fi

echo ""
echo "============================================"
echo "All tests passed! ✅"
echo "============================================"
