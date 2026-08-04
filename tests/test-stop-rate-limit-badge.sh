#!/bin/bash

# The stop rate limit exists to keep parallel sub-agents from spamming toasts.
# Its key (last_stop_notification) is a single process-wide file — not scoped by
# agent, project or window — so any agent finishing anywhere silences the next
# completion from everywhere for STOP_RATE_LIMIT_SECONDS.
#
# That is fine for the toast, but it used to take the tmux badge with it: the
# notifier exited before the badge, while the running-marker teardown had
# already run (it deliberately precedes the suppression check). The window ended
# up with neither spinner nor badge — a completed turn looking untouched, with
# nothing to re-light it. Observed live: a Codex completion at 18:28:01 blanked
# an unrelated Claude window's completion badge one second later.
#
# A rate-limited stop must therefore still badge its window, while every hard
# suppressor (snooze, kill switch, stop_hook_active, auto-accept) still
# withholds the badge along with the alert.

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
# notifications.log is only written when the directory already exists, so create
# it — otherwise the "no log entry" assertions below would pass vacuously.
mkdir -p "$HOME/.claude/notifications/state" "$HOME/.claude/logs" \
    "$fake_bin" "$state_dir"
notify_log="$HOME/.claude/logs/notifications.log"

deliver_log="$test_dir/deliver.log"
: > "$deliver_log"
for tool in terminal-notifier osascript notify-send; do
    printf '#!/bin/bash\necho "%s" >> "%s"\nexit 0\n' "$tool" "$deliver_log" \
        > "$fake_bin/$tool"
    chmod +x "$fake_bin/$tool"
done

# Stateful fake tmux: options and the window name persist as files so they
# round-trip across notifier processes the way real tmux options do.
# rename-window is honoured, so the badge is asserted on the visible name and
# not merely on the bookkeeping options. The window reports itself as hidden
# (third display-message field 0) — the ordinary case for a missed badge.
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
window_name_file="$FAKE_TMUX_STATE/@1.window_name"
case "$cmd" in
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        else
            printf '%s' "${rest[1]:-}" > "$FAKE_TMUX_STATE/$scope.${rest[0]}"
        fi
        ;;
    show-options)
        cat "$FAKE_TMUX_STATE/$scope.${rest[0]}" 2>/dev/null || true
        ;;
    rename-window)
        printf '%s' "${rest[0]}" > "$window_name_file"
        ;;
    display-message)
        name="$(cat "$window_name_file" 2>/dev/null || echo proj)"
        if [[ "${rest[0]}" == "#{window_id}" ]]; then
            printf '@1\n'
        elif [[ "${rest[0]}" == *"|"* ]]; then
            printf '@1|off|0|%s\n' "$name"
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

stop_stamp="$HOME/.claude/notifications/state/last_stop_notification"

window_name() {
    cat "$state_dir/@1.window_name" 2>/dev/null || echo proj
}

# Return the window to a clean, unbadged state between cases.
reset_window() {
    local opt_name
    for opt_name in @code_notify_orig_name @code_notify_badged_name \
        @code_notify_clear_mode @code_notify_autorename @code_notify_agent_pid \
        @code_notify_running @code_notify_run_gen; do
        rm -f "$state_dir/@1.$opt_name"
    done
    rm -f "$state_dir/@1.@code_notify_queued_prompt"
    printf '%s' "proj" > "$state_dir/@1.window_name"
    : > "$deliver_log"
    : > "$notify_log"
}

# Run a claude Stop through the real notifier. Extra env assignments are passed
# as NAME=VALUE arguments. --global omits the project argument, which is what
# makes a hook global-scoped (a project-scoped hook deliberately opts out of the
# global kill switch — see is_project_scoped_notification).
run_stop() {
    local hook_data='{"session_id":"sess1","stop_hook_active":false}'
    local -a hook_args=(stop claude proj)
    while true; do
        case "${1:-}" in
            --hook-data) hook_data="$2"; shift 2 ;;
            --global) hook_args=(stop claude); shift ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$hook_data" | \
        env "$@" CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        FAKE_TMUX_STATE="$state_dir" \
        bash "$ROOT_DIR/lib/code-notify/core/notifier.sh" "${hook_args[@]}" \
        >/dev/null 2>&1 || true
}

# 1. Control: an unlimited stop toasts, stamps the key, and badges the window.
#    Asserting this first means an empty delivery log later proves suppression
#    rather than broken recording fakes.
reset_window
rm -f "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0
[[ -s "$deliver_log" ]] || fail "control stop should reach desktop delivery"
[[ -f "$stop_stamp" ]] || fail "control stop should stamp the rate limiter"
[[ -s "$notify_log" ]] || fail "control stop should write a notifications.log entry"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "control stop should badge the window (got: $(window_name))"
[[ "$(cat "$state_dir/@1.@code_notify_clear_mode" 2>/dev/null)" == "engage" ]] \
    || fail "a claude completion badge should be engage-clear"
pass "an unlimited stop toasts, stamps and badges"

# 2. THE FIX: a stop suppressed purely by the rate limit still badges. It must
#    not toast, and must not stamp the key either — stamping would push the
#    next real completion's alert out by another window.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] \
    || fail "a rate-limited stop must not deliver a desktop notification"
[[ ! -s "$HOME/.claude/logs/notifications.log" ]] \
    || fail "a rate-limited stop must not write a notifications.log entry"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "a rate-limited stop must still badge its window (got: $(window_name))"
[[ "$(cat "$state_dir/@1.@code_notify_clear_mode" 2>/dev/null)" == "engage" ]] \
    || fail "the rate-limited badge should carry the normal engage-clear mode"
pass "a rate-limited stop badges the window without toasting"

# 3. The badge-only downgrade must leave the rate-limit key untouched, so the
#    next completion elsewhere still alerts on time rather than being pushed out
#    by a stop that never made a sound.
#
#    The seed is deliberately a minute old rather than "now": an erroneous
#    refresh writes date +%s, which within the same wall-clock second is
#    byte-identical to a "now" seed, so this assertion would have passed through
#    the very bug it exists to catch. Backdating makes any refresh observable
#    while 60 < 600 keeps the run rate limited.
reset_window
now_stamp="$(( $(date +%s) - 60 ))"
printf '%s' "$now_stamp" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ "$(cat "$stop_stamp")" == "$now_stamp" ]] \
    || fail "a rate-limited badge-only stop must not stamp the rate limiter (got: $(cat "$stop_stamp"), expected $now_stamp)"
[[ "$(window_name)" == "🟢 proj" ]] \
    || fail "precondition: this run should still have been rate limited and badged"
pass "a rate-limited stop leaves the rate-limit key unstamped"

# 4. Ordering guard: stop_hook_active is a hard suppressor and must win over
#    the rate limit, so a nested stop gets no badge. This is what makes the
#    rate-limit check's position (last in should_suppress_notification)
#    load-bearing — checked before the hard suppressors, it would have let
#    these through as badges.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop --hook-data '{"session_id":"sess1","stop_hook_active":true}' \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a stop_hook_active stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "a stop_hook_active stop must not badge, even when rate limited (got: $(window_name))"
pass "stop_hook_active suppresses the badge even while rate limited"

# 5. Same for auto-accept, the other hard suppressor that shares the stop path.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop --hook-data '{"session_id":"sess1","autoAccepted":true}' \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ "$(window_name)" == "proj" ]] \
    || fail "an auto-accepted stop must not badge, even when rate limited (got: $(window_name))"
pass "an auto-accepted stop suppresses the badge even while rate limited"

# 6. Snooze is an explicit request for quiet, not spam control: it withholds
#    the badge too. Seeded with an ACTIVE rate limit so both suppressors apply
#    at once — with the limit inert this would pass without ever exercising the
#    badge-only conversion snooze has to win against.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
printf '%s' "$(( $(date +%s) + 3600 ))" > "$HOME/.claude/notifications/snooze-until"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a snoozed stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "snooze must beat the rate-limit badge-only conversion (got: $(window_name))"
rm -f "$HOME/.claude/notifications/snooze-until"
pass "snooze suppresses the badge even while rate limited"

# 7. The kill switch (cn off) likewise silences the badge, and likewise has to
#    beat an active rate limit. Global scope: a project-scoped hook deliberately
#    ignores the global switch.
reset_window
printf '%s' "$(date +%s)" > "$stop_stamp"
touch "$HOME/.claude/notifications/disabled"
run_stop --global CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ ! -s "$deliver_log" ]] || fail "a disabled stop must not deliver"
[[ "$(window_name)" == "proj" ]] \
    || fail "the kill switch must beat the rate-limit badge-only conversion (got: $(window_name))"
rm -f "$HOME/.claude/notifications/disabled"
pass "the kill switch suppresses the badge even while rate limited"

# 8. The badge-only path must not paint over a successor turn. A queued-prompt
#    hint makes this Stop preserve the running marker for the turn that is
#    already starting; the badge block is skipped on that preserve
#    (TMUX_RUNNING_STOP_PRESERVED), and being rate limited must not change that
#    — otherwise the fix would trade a missing badge for a stolen spinner.
reset_window
printf '%s' "$(date +%s)" > "$state_dir/@1.@code_notify_running"
printf '%s' "$(date +%s)" > "$state_dir/@1.@code_notify_queued_prompt"
printf '%s' "$(date +%s)" > "$stop_stamp"
run_stop CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=600
[[ -s "$state_dir/@1.@code_notify_running" ]] \
    || fail "a preserving stop must keep the running marker for the successor turn"
[[ "$(window_name)" == "proj" ]] \
    || fail "a rate-limited preserving stop must not badge over a live successor (got: $(window_name))"
pass "a rate-limited stop leaves a preserved successor turn alone"

echo "All stop rate-limit badge tests passed"
