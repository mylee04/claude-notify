#!/bin/bash

# Per-event sound pools: a folder per event under the pool root, and each alert
# plays a RANDOM file from the folder matching its event. Events with no folder
# (or an empty one) must fall back to the single configured sound, so a
# collection holding only error/idle/permission/question still covers every
# hook type.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
mkdir -p "$HOME/.claude/notifications"

# shellcheck source=../lib/code-notify/utils/sound.sh
source "$ROOT_DIR/lib/code-notify/utils/sound.sh"

pool="$test_dir/pool"
mkdir -p "$pool/error" "$pool/idle" "$pool/permission" "$pool/question"
for i in 1 2 3; do
    touch "$pool/error/e$i.mp3" "$pool/idle/i$i.mp3" \
        "$pool/permission/p$i.mp3" "$pool/question/q$i.mp3"
done
# Non-audio files must be ignored, names with spaces must survive.
touch "$pool/error/notes.txt" "$pool/idle/soft pop.mp3"

# --- pool root ---
[[ "$(get_sound_pool_dir)" == "$HOME/.claude/notifications/sounds" ]] ||
    fail "pool should default to ~/.claude/notifications/sounds, got: $(get_sound_pool_dir)"
set_sound_pool_dir "$pool"
[[ "$(get_sound_pool_dir)" == "$pool" ]] ||
    fail "pool root not set, got: $(get_sound_pool_dir)"
set_sound_pool_dir "$test_dir/nope" 2>/dev/null &&
    fail "a missing pool directory should be rejected"
pass "pool root defaults, sets, and rejects missing directories"

# --- scanning ---
[[ "$(list_pool_sounds error | grep -c .)" == "3" ]] ||
    fail "non-audio files must be filtered out of a pool"
[[ "$(list_pool_sounds idle | grep -c .)" == "4" ]] ||
    fail "a filename with a space must still be listed"
[[ "$(list_pool_sounds missing-event | grep -c . || true)" == "0" ]] ||
    fail "an absent pool folder must list nothing"
pass "pool scan keeps audio files only"

# --- randomness: 40 draws from a 3-file pool must not all be the same file ---
draws="$(for _ in $(seq 40); do pick_pool_sound error; done | sort -u | grep -c .)"
[[ "$draws" -gt 1 ]] ||
    fail "40 draws from a 3-sound pool all returned the same file"
for _ in $(seq 20); do
    picked="$(pick_pool_sound error)"
    [[ "$picked" == "$pool/error/"*.mp3 ]] ||
        fail "pick strayed outside its event folder: $picked"
done
pass "picks are random and stay inside the event folder"

# --- event mapping, including the fallbacks ---
assert_event() {
    local hook_type="$1" subtype="$2" want_folder="$3"
    local got
    got="$(pick_event_sound "$hook_type" "$subtype")" ||
        fail "no pick for $hook_type/$subtype"
    [[ "$(basename "$(dirname "$got")")" == "$want_folder" ]] ||
        fail "$hook_type/$subtype should draw from $want_folder, got: $got"
}

assert_event "notification" "idle_prompt" "idle"
assert_event "notification" "permission_prompt" "permission"
assert_event "notification" "" "question"
assert_event "PreToolUse" "" "question"
assert_event "error" "" "error"
# No complete/ folder: task-complete falls back to idle/.
assert_event "stop" "" "idle"
# No limit/ folder: the usage-limit stop falls back to error/.
assert_event "StopFailure" "" "error"
pass "events map to their folder, with fallbacks for absent folders"

# A folder that exists takes precedence over the fallback.
mkdir -p "$pool/complete"
touch "$pool/complete/done.mp3"
assert_event "stop" "" "complete"
pass "a present folder wins over its fallback"

# --- subagent and agent-team events ---
# Without their own folders they fall back through the generic ones.
assert_event "SubagentStop" "" "complete"
assert_event "TeammateIdle" "" "idle"
assert_event "TaskCreated" "" "idle"
mkdir -p "$pool/subagent-stop" "$pool/teammate-idle" "$pool/task-completed"
touch "$pool/subagent-stop/s.mp3" "$pool/teammate-idle/t.mp3" "$pool/task-completed/c.mp3"
assert_event "SubagentStop" "" "subagent-stop"
assert_event "TeammateIdle" "" "teammate-idle"
assert_event "TaskCompleted" "" "task-completed"
pass "subagent and agent-team events use their own folders"

# The hook-type spelling works as an alias for the kebab-case folder.
mkdir -p "$pool/SubagentStart"
touch "$pool/SubagentStart/s.mp3"
assert_event "SubagentStart" "" "SubagentStart"
pass "hook-type folder names work as aliases"

# --- `cn sound set` mutes the pools so its one file plays for everything ---
touch "$test_dir/custom.aiff"
set_custom_sound "$test_dir/custom.aiff"
is_sound_pool_enabled &&
    fail "setting a single sound should disable the pools"
pick_event_sound "error" "" >/dev/null 2>&1 &&
    fail "a disabled pool must not produce a pick"
[[ "$(get_event_sound "error" "")" == "$test_dir/custom.aiff" ]] ||
    fail "a disabled pool should fall back to the single configured sound"
# ...and the pool root is remembered, so re-enabling needs no path.
[[ "$(get_sound_pool_dir)" == "$pool" ]] ||
    fail "disabling the pools must not forget the pool root"
enable_sound_pool
assert_event "error" "" "error"
pass "cn sound set disables the pools; cn sound pool on restores them"

# Naming a pool re-enables it even when a single sound muted them.
set_custom_sound "$test_dir/custom.aiff"
set_sound_pool_dir "$pool"
is_sound_pool_enabled ||
    fail "setting a pool directory should re-enable the pools"
pass "setting a pool directory re-enables per-event sounds"

# --- empty pool falls back to the single configured sound ---
printf '%s\n' "$test_dir/custom.aiff" > "$HOME/.claude/notifications/sound-custom"
reset_sound_pool_dir
[[ "$(get_sound_pool_dir)" == "$HOME/.claude/notifications/sounds" ]] ||
    fail "reset should restore the default pool root"
pick_event_sound "stop" "" >/dev/null 2>&1 &&
    fail "an empty pool must not produce a pick"
[[ "$(get_event_sound "stop" "")" == "$test_dir/custom.aiff" ]] ||
    fail "an empty pool should fall back to the configured sound"
pass "empty pool falls back to the configured sound"

# --- end to end: the notifier plays a pooled sound for the event ---
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: notifier playback assertions require macOS"
    exit 0
fi

export CODE_NOTIFY_SKIP_USAGE_CHECK=1
stub_bin="$test_dir/bin"
afplay_log="$test_dir/afplay.log"
mkdir -p "$stub_bin" "$HOME/.claude/logs"

cat > "$stub_bin/afplay" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$afplay_log"
STUB
cat > "$stub_bin/terminal-notifier" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "-help" ]] && exit 0
exit 0
STUB
chmod +x "$stub_bin"/*
fake_path="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin"

: > "$HOME/.claude/notifications/sound-enabled"
set_sound_pool_dir "$pool"

wait_for_log() {
    local _
    for _ in $(seq 1 60); do
        [[ -s "$afplay_log" ]] && return 0
        sleep 0.05
    done
    return 1
}

run_hook() {
    rm -rf "$HOME/.claude/notifications/state"
    : > "$afplay_log"
    printf '%s' "$2" | PATH="$fake_path" bash "$NOTIFIER" "$1" claude sound-pool-proj
    wait_for_log || fail "no sound played for hook: $1"
}

run_hook "stop" '{}'
grep -q "$pool/complete/" "$afplay_log" ||
    fail "stop should play from complete/, got: $(cat "$afplay_log")"
pass "notifier plays the complete pool on stop"

run_hook "notification" '{"message":"Claude needs your permission to use Bash"}'
grep -q "$pool/permission/" "$afplay_log" ||
    fail "permission prompt should play from permission/, got: $(cat "$afplay_log")"
pass "notifier plays the permission pool on an approval prompt"

run_hook "error" '{}'
grep -q "$pool/error/" "$afplay_log" ||
    fail "error should play from error/, got: $(cat "$afplay_log")"
pass "notifier plays the error pool on an error"

echo "All sound pool tests passed"
