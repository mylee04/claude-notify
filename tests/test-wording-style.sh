#!/bin/bash

# Wording styles: banner and voice each pick from the short (terse) or long
# (friendly) message pool, banner defaulting to short and voice to long.
# Covers the `cn wording` state files, the env overrides, and the reset path.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
CN="$ROOT_DIR/bin/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

os_name="$(uname -s)"
case "$os_name" in
    Darwin|Linux) ;;
    *)
        echo "SKIP: unsupported OS for wording style test"
        exit 0
        ;;
esac

# Voice is only wired up on macOS (see the `macos)` branch of notifier.sh's
# OS case statement — Linux never calls speak_notification). Banner wording
# still applies on both, since it goes through the same pool-selection code.
can_speak=false
[[ "$os_name" == "Darwin" ]] && can_speak=true

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
banner_log="$test_dir/banner.log"
say_log="$test_dir/say.log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

if [[ "$os_name" == "Darwin" ]]; then
    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then exit 0; fi
printf '%s\n' "\$*" >> "$banner_log"
EOF
else
    cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$banner_log"
EOF
fi
cat > "$fake_bin/say" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$say_log"
EOF
chmod +x "$fake_bin"/*
fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Enable spoken messages: the voice file both turns speech on for the tool
# and names the `say` voice the stub receives.
printf 'TestVoice\n' > "$HOME/.claude/notifications/voice-claude"

# stop banner pools (see notifier.sh): the long pool is recognizable by its
# exclamation openers. Keep one alternative per pool entry — a phrase the
# regex misses turns these assertions flaky, since the pool is picked from
# at random.
short_re='Claude (completed the task|finished the task|is done|wrapped up)'
long_re='(All done!|Task complete!|Over to you!|Good news!|Finished!)'

# Speech runs in a detached background process, so every notifier invocation
# must wait for its say output to land before the next run truncates the log;
# a late writer from run N would otherwise pollute run N+1's assertions
# (deadly for the ones asserting absence). Every run here speaks, so an empty
# log after the timeout is a failure, not a tolerable slow start.
wait_for_say() {
    for _ in $(seq 1 200); do
        [[ -s "$say_log" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for spoken output"
}

run_stop() {
    : > "$banner_log"
    : > "$say_log"
    # Each run must notify: drop the rate-limit state from the previous one.
    rm -rf "$HOME/.claude/notifications/state"
    printf '{}' | PATH="$fake_path" bash "$NOTIFIER" stop claude wording-test
    # Speech runs detached only where it exists at all (macOS); on Linux the
    # banner is written synchronously and there is nothing to wait for.
    if "$can_speak"; then wait_for_say; fi
}

banner_matches() { grep -Eq "$1" "$banner_log"; }
say_matches() { [[ -f "$say_log" ]] && grep -Eq "$1" "$say_log"; }

# --- defaults: banner short, voice long ---
run_stop
banner_matches "$short_re" || fail "default banner should use the short pool"
banner_matches "$long_re" && fail "default banner must not use the long pool"
if "$can_speak"; then
    say_matches "$long_re" || fail "default voice should use the long pool"
    say_matches 'in project wording-test' || fail "voice should speak the hyphenated project name"
fi

# --- cn wording writes state files the notifier honours ---
PATH="$fake_path" "$CN" wording banner long >/dev/null
[[ "$(cat "$HOME/.claude/notifications/wording-banner")" == "long" ]] ||
    fail "cn wording banner long should write the state file"
run_stop
banner_matches "$long_re" || fail "banner should follow wording-banner=long"

PATH="$fake_path" "$CN" wording voice short >/dev/null
run_stop
if "$can_speak"; then
    say_matches "$short_re" || fail "voice should follow wording-voice=short"
    say_matches "$long_re" && fail "voice set to short must not use the long pool"
fi

# --- env vars override the state files ---
: > "$banner_log"
: > "$say_log"
rm -rf "$HOME/.claude/notifications/state"
printf '{}' | PATH="$fake_path" CODE_NOTIFY_BANNER_WORDING=short \
    bash "$NOTIFIER" stop claude wording-test
if "$can_speak"; then wait_for_say; fi
banner_matches "$short_re" || fail "CODE_NOTIFY_BANNER_WORDING should override the state file"
banner_matches "$long_re" && fail "env-overridden banner must not use the long pool"

# --- project name toggles, independent per target ---
# Match the subtitle specifically: the macOS stub also logs the -group
# argument, which always carries the project name.
banner_project_re='Task Complete - wording-test'

run_stop
banner_matches "$banner_project_re" || fail "default banner should include the project name"

PATH="$fake_path" "$CN" wording project voice off >/dev/null
[[ "$(cat "$HOME/.claude/notifications/wording-project-voice")" == "off" ]] ||
    fail "cn wording project voice off should write the state file"
run_stop
say_matches 'in project wording-test' && fail "voice project off must not speak the project"
banner_matches "$banner_project_re" || fail "banner keeps the project while only voice is off"

PATH="$fake_path" "$CN" wording project voice reset >/dev/null
[[ ! -f "$HOME/.claude/notifications/wording-project-voice" ]] ||
    fail "reset should remove the project-voice state file"
PATH="$fake_path" "$CN" wording project banner off >/dev/null
run_stop
banner_matches "$banner_project_re" && fail "banner project off must not show the project"
if "$can_speak"; then
    say_matches 'in project wording-test' || fail "voice keeps the project while only banner is off"
fi

# env var overrides the state file (banner still off in the state file)
: > "$banner_log"
: > "$say_log"
rm -rf "$HOME/.claude/notifications/state"
printf '{}' | PATH="$fake_path" CODE_NOTIFY_BANNER_PROJECT=on \
    bash "$NOTIFIER" stop claude wording-test
if "$can_speak"; then wait_for_say; fi
banner_matches "$banner_project_re" || fail "CODE_NOTIFY_BANNER_PROJECT should override the state file"

PATH="$fake_path" "$CN" wording project banner reset >/dev/null

# --- reset removes the state files (defaults return) ---
PATH="$fake_path" "$CN" wording banner reset >/dev/null
PATH="$fake_path" "$CN" wording voice reset >/dev/null
[[ ! -f "$HOME/.claude/notifications/wording-banner" ]] ||
    fail "reset should remove the banner state file"
run_stop
banner_matches "$short_re" || fail "banner should be short again after reset"
if "$can_speak"; then
    say_matches "$long_re" || fail "voice should be long again after reset"
fi

# --- garbage in the state file falls back to the default ---
printf 'sonnet-form\n' > "$HOME/.claude/notifications/wording-banner"
run_stop
banner_matches "$short_re" || fail "unrecognized style should fall back to the default"

# --- status reports both targets ---
status_out="$(PATH="$fake_path" "$CN" wording status)"
printf '%s' "$status_out" | grep -q "banner wording" || fail "status should report banner wording"
printf '%s' "$status_out" | grep -q "voice wording" || fail "status should report voice wording"
printf '%s' "$status_out" | grep -q "banner project name" || fail "status should report banner project toggle"
printf '%s' "$status_out" | grep -q "voice project name" || fail "status should report voice project toggle"

pass "wording styles"
