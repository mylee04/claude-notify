#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CLAUDE_HOME="$HOME/.claude"
export CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
mkdir -p "$CLAUDE_HOME/notifications"

source "$ROOT_DIR/lib/code-notify/utils/colors.sh"
source "$ROOT_DIR/lib/code-notify/core/config.sh"
source "$ROOT_DIR/lib/code-notify/commands/global.sh"

notify_script="$test_dir/notify.sh"
get_notify_script() {
    printf '%s\n' "$notify_script"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

get_claude_matcher() {
    python3 - "$GLOBAL_SETTINGS_FILE" "$notify_script" <<'PYTHON'
import json
import sys

settings_file, notify_script = sys.argv[1:3]
with open(settings_file, "r") as fh:
    settings = json.load(fh)

command = f"{notify_script} notification claude"
for entry in settings.get("hooks", {}).get("Notification", []):
    if any(hook.get("command") == command for hook in entry.get("hooks", [])):
        print(entry.get("matcher", ""), end="")
        break
PYTHON
}

enable_hooks_in_settings
[[ "$(get_claude_matcher)" == "idle_prompt" ]] || fail "initial matcher is incorrect"

add_alert_type permission_prompt >/dev/null
[[ "$(get_claude_matcher)" == "idle_prompt|permission_prompt" ]] ||
    fail "adding permission_prompt did not immediately refresh Claude hooks"

# Repeating the command must also repair a stale matcher left by an older
# version that changed notify-types without rewriting settings.json.
python3 - "$GLOBAL_SETTINGS_FILE" <<'PYTHON'
import json
import sys

path = sys.argv[1]
with open(path, "r") as fh:
    settings = json.load(fh)
settings["hooks"]["Notification"][0]["matcher"] = "idle_prompt"
with open(path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
PYTHON

add_alert_type permission_prompt >/dev/null
[[ "$(get_claude_matcher)" == "idle_prompt|permission_prompt" ]] ||
    fail "re-adding an enabled type did not repair the stale matcher"

remove_alert_type permission_prompt >/dev/null
[[ "$(get_claude_matcher)" == "idle_prompt" ]] ||
    fail "removing permission_prompt did not immediately refresh Claude hooks"

add_alert_type permission_prompt >/dev/null
reset_alert_types >/dev/null
[[ "$(get_claude_matcher)" == "idle_prompt" ]] ||
    fail "reset did not immediately refresh Claude hooks"

echo "PASS: alert changes automatically refresh enabled Claude hooks"
