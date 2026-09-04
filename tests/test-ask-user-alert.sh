#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
mkdir -p "$CLAUDE_HOME/notifications"

source "$ROOT_DIR/lib/code-notify/core/config.sh"

notify_script="$test_dir/notifier.sh"
get_notify_script() {
    printf '%s\n' "$notify_script"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

cat > "$GLOBAL_SETTINGS_FILE" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom ask-user hook"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo custom bash hook"
          }
        ]
      }
    ]
  }
}
JSON

set_notify_types "idle_prompt|ask_user"
enable_hooks_in_settings
enable_hooks_in_settings

if claude_global_hooks_need_repair; then
    fail "current ask_user hook was incorrectly flagged as legacy"
fi

python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    hooks = json.load(fh).get("hooks", {})

pre_tool = hooks.get("PreToolUse", [])
ask_entries = [entry for entry in pre_tool if entry.get("matcher") == "AskUserQuestion"]
bash_entries = [entry for entry in pre_tool if entry.get("matcher") == "Bash"]
managed_command = f"{notify_script} PreToolUse claude"

if not any(
    hook.get("command") == "echo custom ask-user hook"
    for entry in ask_entries
    for hook in entry.get("hooks", [])
):
    raise SystemExit("custom AskUserQuestion hook was not preserved")

managed_count = sum(
    1
    for entry in ask_entries
    for hook in entry.get("hooks", [])
    if hook.get("command") == managed_command
)
if managed_count != 1:
    raise SystemExit(f"expected one managed AskUserQuestion hook, found {managed_count}")

if not any(
    hook.get("command") == "echo custom bash hook"
    for entry in bash_entries
    for hook in entry.get("hooks", [])
):
    raise SystemExit("custom non-AskUserQuestion PreToolUse hook was not preserved")
PYTHON

legacy_settings_file="$test_dir/legacy-settings.json"
cat > "$legacy_settings_file" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script PreToolUse"
          }
        ]
      }
    ]
  }
}
JSON

if ! has_legacy_global_claude_hooks "$legacy_settings_file"; then
    fail "legacy PreToolUse hook was not flagged for repair"
fi

unregister_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"

python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    hooks = json.load(fh).get("hooks", {})

managed_command = f"{notify_script} PreToolUse claude"
pre_tool = hooks.get("PreToolUse", [])

if any(
    hook.get("command") == managed_command
    for entry in pre_tool
    for hook in entry.get("hooks", [])
):
    raise SystemExit("managed AskUserQuestion hook was not removed")

if not any(
    entry.get("matcher") == "AskUserQuestion" and
    any(hook.get("command") == "echo custom ask-user hook" for hook in entry.get("hooks", []))
    for entry in pre_tool
):
    raise SystemExit("custom AskUserQuestion hook was removed")

if not any(
    entry.get("matcher") == "Bash" and
    any(hook.get("command") == "echo custom bash hook" for hook in entry.get("hooks", []))
    for entry in pre_tool
):
    raise SystemExit("custom Bash hook was removed")
PYTHON

echo "PASS: ask_user alert preserves custom PreToolUse hooks"
