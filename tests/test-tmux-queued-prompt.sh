#!/bin/bash

# A UserPromptSubmit that lands while a window's running marker is still up
# (queued message, or a submission racing the ending turn's teardown) means
# the coming Stop has a successor turn. That Stop must keep the running
# indicator, or the successor runs dark: nothing between a Stop and the next
# UserPromptSubmit re-lights the spinner.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
state_dir="$test_dir/state"
mkdir -p "$HOME/.claude/notifications" "$fake_bin" "$state_dir"

# Spinner mode keeps prompt-submit on the light path (no rename mechanics).
touch "$HOME/.claude/notifications/tmux-spinner-enabled"

# The end-to-end stop below reaches delivery; absorb it so the test never
# raises a real desktop notification.
for tool in terminal-notifier osascript notify-send; do
    printf '#!/bin/bash\nexit 0\n' > "$fake_bin/$tool"
    chmod +x "$fake_bin/$tool"
done

# Stateful fake tmux: window/global options persist as files so set-option,
# show-options and unset round-trip across processes the way real tmux
# options do. display-message answers the two formats the focus helpers use;
# list-windows reports nothing so sweeps and disarm checks stay inert.
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
args=("$@")
cmd="${args[0]}"
args=("${args[@]:1}")
target=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F|-d) args=("${args[@]:2}") ;;
        -*) [[ "$a" == *u* ]] && unset_opt=1; args=("${args[@]:1}") ;;
        *) rest+=("$a"); args=("${args[@]:1}") ;;
    esac
done
scope="${target:-_global}"
case "$cmd" in
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        else
            printf '%s' "${rest[1]:-}" > "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        fi
        ;;
    show-options)
        if [[ "${rest[0]}" == "@code_notify_queued_prompt" ]] &&
            [[ "${FAKE_TMUX_PAUSE_QUEUED_READ:-}" == "1" ]]; then
            : > "$FAKE_TMUX_PAUSE_SIGNAL_FILE"
            while [[ ! -e "$FAKE_TMUX_RELEASE_FILE" ]]; do sleep 0.01; done
        fi
        cat "$FAKE_TMUX_STATE/$scope.${rest[0]}" 2>/dev/null || true
        ;;
    display-message)
        if [[ "${rest[0]}" == "#{window_id}" ]]; then
            printf '@1\n'
        elif [[ "${rest[0]}" == *"|"* ]]; then
            printf '@1|off|1|proj\n'
        else
            printf '$1 @1 %%1\n'
        fi
        ;;
    list-windows)
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"

export PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"
export FAKE_TMUX_STATE="$state_dir"
export TMUX="$test_dir/fake-socket,1,\$1"
export TMUX_PANE="%1"

opt() {
    cat "$state_dir/@1.$1" 2>/dev/null
}

run_lib() {
    bash -c 'source "$1"; shift; "$@"' _ "$ROOT_DIR/lib/code-notify/utils/tmux.sh" "$@"
}

wait_for_file() {
    local file="$1" description="$2" i
    for ((i = 0; i < 300; i++)); do
        [[ -e "$file" ]] && return 0
        sleep 0.01
    done
    fail "$description"
}

# 1. A fresh prompt (no marker) arms the indicator and leaves no hint.
run_lib tmux_prompt_submit
[[ -n "$(opt @code_notify_running)" ]] || fail "prompt submit should set the running marker"
[[ -z "$(opt @code_notify_queued_prompt)" ]] || fail "fresh prompt should not leave a queued-prompt hint"

# 2. A terminal stop with no hint clears the marker (baseline behavior).
run_lib tmux_running_stop consume-queued-prompt
[[ -z "$(opt @code_notify_running)" ]] || fail "stop without hint should clear the running marker"

# 3. A submission while the marker is up leaves a hint; the ending turn's
#    Stop consumes it and keeps the indicator for the successor turn.
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
[[ -n "$(opt @code_notify_queued_prompt)" ]] || fail "submit over a live marker should leave a queued-prompt hint"
run_lib tmux_running_stop consume-queued-prompt
[[ -n "$(opt @code_notify_running)" ]] || fail "stop must keep the indicator for a queued successor turn"
[[ -z "$(opt @code_notify_queued_prompt)" ]] || fail "stop should consume the queued-prompt hint"

# 4. One hint covers one Stop: the successor's own Stop clears normally.
run_lib tmux_running_stop consume-queued-prompt
[[ -z "$(opt @code_notify_running)" ]] || fail "successor turn's stop should clear the marker"

# 5. Input pauses neither honor nor consume the hint: a dialog still pauses
#    the indicator and the hint survives for the real Stop.
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
run_lib tmux_running_pause_for_input
[[ -z "$(opt @code_notify_running)" ]] || fail "input pause should still take the indicator down"
[[ -n "$(opt @code_notify_queued_prompt)" ]] || fail "input pause should not consume the queued-prompt hint"
run_lib tmux_running_stop consume-queued-prompt
[[ -z "$(opt @code_notify_queued_prompt)" ]] || fail "real stop should consume the surviving hint"

# 6. Callers without the opt-in flag ignore the hint entirely.
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
run_lib tmux_running_stop
[[ -z "$(opt @code_notify_running)" ]] || fail "stop without the flag should clear the marker regardless of hints"
[[ -n "$(opt @code_notify_queued_prompt)" ]] || fail "stop without the flag should leave the hint alone"
rm -f "$state_dir/@1.@code_notify_queued_prompt"

# 7. A stale hint (older than the running TTL) is pruned, not honored.
run_lib tmux_prompt_submit
printf '%s' "$(( $(date +%s) - 14400 - 10 ))" > "$state_dir/@1.@code_notify_queued_prompt"
run_lib tmux_running_stop consume-queued-prompt
[[ -z "$(opt @code_notify_running)" ]] || fail "stale hint should not keep the marker"
[[ -z "$(opt @code_notify_queued_prompt)" ]] || fail "stale hint should be pruned"

# 8. End to end: the notifier's stop path passes the opt-in flag, so a real
#    Stop event keeps the indicator when a queued submission preceded it.
mkdir -p "$HOME/.claude/logs"
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
printf '%s\n' '{"session_id":"sess1","stop_hook_active":false}' | \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
    FAKE_TMUX_STATE="$state_dir" \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" stop claude proj >/dev/null 2>&1 || true
[[ -n "$(opt @code_notify_running)" ]] || fail "notifier stop should keep the indicator for a queued successor"
[[ -z "$(opt @code_notify_queued_prompt)" ]] || fail "notifier stop should consume the queued-prompt hint"

# 9. Static mode must retain the running badge as well as its epoch. A normal
#    terminal badge would replace @code_notify_clear_mode with the completion
#    mode even though the queued successor is still running.
run_lib tmux_running_stop consume-queued-prompt
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
printf '%s\n' '{"session_id":"sess1","stop_hook_active":false}' | \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
    FAKE_TMUX_STATE="$state_dir" \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" stop claude proj >/dev/null 2>&1 || true
[[ "$(opt @code_notify_clear_mode)" == "running" ]] \
    || fail "queued successor's static running badge must not be replaced by completion"
[[ -n "$(opt @code_notify_running)" ]] \
    || fail "queued successor's running epoch must survive terminal badging"

# 10. Force the problematic ordering: Stop holds the transition lock after it
#     has found no hint, while a prompt submission tries to arm the successor.
#     The submission must wait; after Stop clears the old turn it installs a
#     fresh marker without a stale hint for a later Stop to misconsume.
run_lib tmux_running_stop consume-queued-prompt
run_lib tmux_prompt_submit
stop_read="$state_dir/stop-read"
stop_release="$state_dir/stop-release"
prompt_started="$state_dir/prompt-started"
FAKE_TMUX_PAUSE_QUEUED_READ=1 \
FAKE_TMUX_PAUSE_SIGNAL_FILE="$stop_read" \
FAKE_TMUX_RELEASE_FILE="$stop_release" \
    bash -c 'source "$1"; tmux_running_stop consume-queued-prompt' \
    _ "$ROOT_DIR/lib/code-notify/utils/tmux.sh" &
stop_pid=$!
wait_for_file "$stop_read" "Stop did not reach the queued-prompt check"
bash -c ': > "$2"; source "$1"; tmux_prompt_submit' \
    _ "$ROOT_DIR/lib/code-notify/utils/tmux.sh" "$prompt_started" &
prompt_pid=$!
wait_for_file "$prompt_started" "prompt submission did not start"
sleep 0.1
kill -0 "$prompt_pid" 2>/dev/null \
    || fail "prompt submission must wait while Stop owns the transition lock"
[[ -z "$(opt @code_notify_queued_prompt)" ]] \
    || fail "blocked prompt submission must not mutate queued state before Stop releases"
: > "$stop_release"
wait "$stop_pid"
wait "$prompt_pid"
[[ -n "$(opt @code_notify_running)" ]] \
    || fail "prompt submission after serialized Stop must leave a fresh running marker"
[[ -z "$(opt @code_notify_queued_prompt)" ]] \
    || fail "serialized Stop-first handoff must not leave a stale queued-prompt hint"

# 11. The older Stop notifier may reach terminal delivery only after the
#     serialized successor has started. Its final badge check uses the same
#     lock and must leave that successor's static rendering untouched.
run_lib tmux_badge_set_unless_running "DONE" engage "" apply
[[ "$(opt @code_notify_clear_mode)" == "running" ]] \
    || fail "late terminal delivery must not overwrite a fresh running badge"

# 12. Safety net for a FALSE hint: a marker lingering from an interrupted turn
#     (Esc emits no Stop) makes the next prompt set a hint that the SAME turn's
#     only Stop consumes, which would strand the indicator with no successor to
#     clear it. The preserving Stop must arm a settle watch — for any agent,
#     even one with real Stop hooks — recording the pane and agent/project the
#     sweep needs to reconcile the marker and apply the withheld badge.
rm -f "$state_dir"/@1.@code_notify_running \
    "$state_dir"/@1.@code_notify_queued_prompt \
    "$state_dir"/@1.@code_notify_settle_pane \
    "$state_dir"/@1.@code_notify_settle_ctx
export CODE_NOTIFY_TMUX_AGENT_NAME=claude
run_lib tmux_prompt_submit
run_lib tmux_prompt_submit
[[ -n "$(opt @code_notify_queued_prompt)" ]] || fail "precondition: submit over a live marker leaves a hint"
run_lib tmux_running_stop consume-queued-prompt
[[ -n "$(opt @code_notify_running)" ]] || fail "preserve must keep the running marker"
[[ "$(opt @code_notify_settle_pane)" == "%1" ]] \
    || fail "a preserved hint must arm the settle safety-net watch"
[[ "$(opt @code_notify_settle_ctx)" == "claude "* ]] \
    || fail "the settle watch must record the agent/project for the synthetic completion"
# The preserving Stop already delivered its toast (only the badge was
# withheld), so the safety-net watch must be marked badge-only — the
# reconcile applies badge and idle watch without a second notification.
[[ "$(opt @code_notify_settle_badge_only)" == "1" ]] \
    || fail "a preserve-armed settle watch must be marked badge-only"
# The genuine successor's own Stop clears the marker and disarms the safety net.
run_lib tmux_running_stop consume-queued-prompt
[[ -z "$(opt @code_notify_running)" ]] || fail "successor stop should clear the marker"
[[ -z "$(opt @code_notify_settle_pane)" ]] || fail "successor stop should disarm the settle watch"
[[ -z "$(opt @code_notify_settle_badge_only)" ]] \
    || fail "successor stop should clear the badge-only marker"
unset CODE_NOTIFY_TMUX_AGENT_NAME

# 13. A badge-only synthetic stop (the settle reconcile of a preserved Stop)
#     must skip desktop delivery and leave the stop rate limiter unstamped —
#     the preserving Stop already toasted, and a stamp here could swallow the
#     next real completion's alert. Control run first so an empty delivery
#     log proves suppression rather than broken recording fakes.
deliver_log="$test_dir/deliver.log"
for tool in terminal-notifier osascript notify-send; do
    printf '#!/bin/bash\necho "%s" >> "%s"\nexit 0\n' "$tool" "$deliver_log" \
        > "$fake_bin/$tool"
    chmod +x "$fake_bin/$tool"
done
stop_stamp="$HOME/.claude/notifications/state/last_stop_notification"
rm -f "$stop_stamp"
printf '%s\n' '{"session_id":"sess1","stop_hook_active":false}' | \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 CODE_NOTIFY_TAIL_SYNC=1 \
    CODE_NOTIFY_SKIP_USAGE_CHECK=1 FAKE_TMUX_STATE="$state_dir" \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" stop claude proj >/dev/null 2>&1 || true
[[ -s "$deliver_log" ]] || fail "control stop should reach desktop delivery"
[[ -f "$stop_stamp" ]] || fail "control stop should stamp the rate limiter"
rm -f "$stop_stamp"
: > "$deliver_log"
printf '%s\n' '{"session_id":"sess1","stop_hook_active":false}' | \
    CODE_NOTIFY_BADGE_ONLY=1 CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED=1 \
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
    FAKE_TMUX_STATE="$state_dir" \
    bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" stop claude proj >/dev/null 2>&1 || true
[[ ! -s "$deliver_log" ]] || fail "a badge-only stop must not deliver a desktop notification"
[[ ! -f "$stop_stamp" ]] || fail "a badge-only stop must not stamp the stop rate limiter"

pass "queued prompt submissions keep the running indicator across the racing stop"
