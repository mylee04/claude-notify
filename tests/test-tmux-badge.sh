#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Resolve the real tmux binary now, before the fake tmux is put on PATH below.
# The real-tmux quoting test and the cleanup trap must use this absolute path;
# a bare `tmux` would hit the fake and neither detect the version nor actually
# kill the throwaway server.
REAL_TMUX="$(command -v tmux 2>/dev/null || true)"

test_dir="$(mktemp -d)"
# Dedicated throwaway tmux socket for the real-tmux quoting test below, on its
# own -L socket so it never touches the user's tmux. On every exit path (pass,
# fail's `exit 1`, or error) the server is killed AND the socket file it leaves
# behind is removed — kill-server does not unlink the socket, so we capture the
# real path from tmux (#{socket_path}) into quote_sock_path and rm it here.
QUOTE_SOCK="cn-badge-qtest-$$"
quote_sock_path=""
cleanup() {
    # A fail after the end-to-end fake agent starts exits through this trap;
    # reap it instead of leaving a five-minute sleep behind per failed run.
    if [[ -n "${idle_agent_pid:-}" ]]; then
        kill "$idle_agent_pid" 2>/dev/null || true
        wait "$idle_agent_pid" 2>/dev/null || true
    fi
    if [[ -n "${badge_clear_pid:-}" ]]; then
        kill "$badge_clear_pid" 2>/dev/null || true
        wait "$badge_clear_pid" 2>/dev/null || true
    fi
    if [[ -n "${badge_set_pid:-}" ]]; then
        kill "$badge_set_pid" 2>/dev/null || true
        wait "$badge_set_pid" 2>/dev/null || true
    fi
    if [[ -n "${click_clear_pid:-}" ]]; then
        kill "$click_clear_pid" 2>/dev/null || true
        wait "$click_clear_pid" 2>/dev/null || true
    fi
    if [[ -n "${reclaim_one_pid:-}" ]]; then
        kill "$reclaim_one_pid" 2>/dev/null || true
        wait "$reclaim_one_pid" 2>/dev/null || true
    fi
    if [[ -n "${reclaim_two_pid:-}" ]]; then
        kill "$reclaim_two_pid" 2>/dev/null || true
        wait "$reclaim_two_pid" 2>/dev/null || true
    fi
    if [[ -n "$REAL_TMUX" ]]; then
        # || true: on skip/early-exit paths no server was started, so kill-server
        # fails on a nonexistent socket; under set -e that would abort the trap
        # before rm and taint the script's exit status.
        "$REAL_TMUX" -L "$QUOTE_SOCK" kill-server 2>/dev/null || true
        [[ -n "$quote_sock_path" ]] && rm -f "$quote_sock_path"
    fi
    # The end-to-end section fires detached notifier runs whose side effects
    # the tests wait for, but the process itself may still be writing under
    # the sandbox HOME (e.g. python's bytecode cache) while this rm walks the
    # tree — "Directory not empty" would taint the exit status, so retry.
    local i
    for i in 1 2 3 4 5; do
        rm -rf "$test_dir" 2>/dev/null && return 0
        sleep 0.5
    done
    rm -rf "$test_dir"
}
trap cleanup EXIT

# Stateful fake tmux: window options persist as files under
# $FAKE_TMUX_STATE/<window>.<option> so set/show/unset round-trip across
# invocations, the way real tmux window options do across hook processes.
fake_bin="$test_dir/bin"
log_file="$test_dir/tmux-calls.log"
state_dir="$test_dir/state"
mkdir -p "$fake_bin" "$state_dir"
cat > "$fake_bin/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_TMUX_LOG"
args=("$@")
if [[ "${args[0]}" == "-S" ]]; then
    args=("${args[@]:2}")
fi
cmd="${args[0]}"
args=("${args[@]:1}")
capture_history=0
if [[ "$cmd" == "capture-pane" ]]; then
    for ((i = 0; i + 1 < ${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "-S" ]] && [[ "${args[$((i + 1))]}" == "-" ]]; then
            capture_history=1
            break
        fi
    done
fi
target=""
fmt=""
unset_opt=0
rest=()
while (( ${#args[@]} )); do
    a="${args[0]}"
    case "$a" in
        -t) target="${args[1]}"; args=("${args[@]:2}") ;;
        -F) fmt="${args[1]}"; args=("${args[@]:2}") ;;
        -*) [[ "$a" == -*u* ]] && unset_opt=1; args=("${args[@]:1}") ;;
        *) rest+=("$a"); args=("${args[@]:1}") ;;
    esac
done
case "$cmd" in
    display-message)
        # The badge info format is pipe-separated; a plain window-name query
        # reads the stateful name (kept current by rename-window); the focus
        # target format (session/window/pane IDs) is a fixture.
        case "${rest[0]}" in
            '#{window_id}|#{pane_height}')
                printf '%s|%s\n' "${FAKE_TMUX_PANE_WINDOW-@2}" \
                    "${FAKE_TMUX_PANE_HEIGHT:-24}"
                ;;
            *"|"*)
                if [[ "${FAKE_TMUX_DYNAMIC_BADGE_INFO:-}" == "1" ]]; then
                    badge_window="${FAKE_TMUX_PANE_WINDOW-@2}"
                    name=$(cat "$FAKE_TMUX_STATE/${badge_window}.window_name" 2>/dev/null)
                    printf '%s|on|0|%s\n' "$badge_window" "$name"
                else
                    printf '%s\n' "$FAKE_TMUX_BADGE_INFO"
                fi
                ;;
            '#{window_name}')
                if [[ "${FAKE_TMUX_PAUSE_BADGE_CLEAR:-}" == "1" ]]; then
                    : > "$FAKE_TMUX_BADGE_CLEAR_SIGNAL"
                    while [[ ! -e "$FAKE_TMUX_BADGE_CLEAR_RELEASE" ]]; do sleep 0.01; done
                fi
                cat "$FAKE_TMUX_STATE/${target}.window_name" 2>/dev/null
                echo
                ;;
            '#{window_id}') printf '%s\n' "${FAKE_TMUX_PANE_WINDOW-@2}" ;;
            *) printf '%s\n' "$FAKE_TMUX_TARGET" ;;
        esac
        ;;
    list-windows)
        # The badge sweep and the running sweep ask for different formats; the
        # badge one (containing window_active) comes from the fixture var, the
        # running ones are synthesized from the stateful @code_notify_running
        # options so epoch round-trips are exercised for real.
        if [[ "$fmt" == *window_active* ]]; then
            printf '%s\n' "$FAKE_TMUX_WINDOWS"
        elif [[ "$fmt" == *code_notify_agent_pid* ]]; then
            # Real tmux emits EVERY window, with an empty field when the
            # option is unset — the sweep must cope with untracked windows,
            # so list every window any state file mentions, not just tracked.
            seen=" "
            for f in "$FAKE_TMUX_STATE"/@*.*; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                case "$seen" in *" $w "*) continue ;; esac
                seen="$seen$w "
                pid=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_agent_pid" 2>/dev/null)
                run=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_running" 2>/dev/null)
                gen=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_run_gen" 2>/dev/null)
                sp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_settle_pane" 2>/dev/null)
                iw=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_idle_watch" 2>/dev/null)
                rp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_resume_pending" 2>/dev/null)
                dc=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_dialog_ctx" 2>/dev/null)
                ds=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_dialog_since" 2>/dev/null)
                dg=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_dialog_grace" 2>/dev/null)
                ip=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_interrupt_pane" 2>/dev/null)
                ifp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_interrupt_fp" 2>/dev/null)
                is=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_interrupt_since" 2>/dev/null)
                bo=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_settle_badge_only" 2>/dev/null)
                on=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_orig_name" 2>/dev/null)
                printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
                    "$w" "$pid" "$run" "$gen" "$sp" "$iw" "$rp" "$dc" "$ds" "$dg" "$ip" "$ifp" "$is" "$bo" "$on"
            done
        elif [[ "$fmt" == *resume_pending* ]]; then
            # The resume poll pairs each pending epoch with the window's
            # activity clock and dialog snapshot; the activity value comes
            # from a per-window state file so tests can move it independently
            # of the pause epoch.
            for f in "$FAKE_TMUX_STATE"/@*.@code_notify_resume_pending; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                act=$(cat "$FAKE_TMUX_STATE/${w}.window_activity" 2>/dev/null)
                fp=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_pause_fp" 2>/dev/null)
                printf '%s|%s|%s|%s\n' "$w" "$(cat "$f")" "$act" "$fp"
            done
        else
            for f in "$FAKE_TMUX_STATE"/*.@code_notify_running; do
                [[ -e "$f" ]] || continue
                w="${f##*/}"; w="${w%%.*}"
                since=$(cat "$f")
                if [[ "$fmt" == *clear_mode* ]]; then
                    mode=$(cat "$FAKE_TMUX_STATE/${w}.@code_notify_clear_mode" 2>/dev/null)
                    printf '%s|%s|%s\n' "$w" "$since" "$mode"
                else
                    printf '%s|%s\n' "$w" "$since"
                fi
            done
        fi
        ;;
    list-sessions)
        printf '%s\n' "$FAKE_TMUX_SESSIONS"
        ;;
    show-options)
        if [[ "${FAKE_TMUX_SETTLE_RACE_MARKER:-}" != "" ]] &&
            [[ "${rest[0]}" == "@code_notify_settle_since" ]] &&
            [[ ! -e "$FAKE_TMUX_SETTLE_RACE_MARKER" ]]; then
            cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
            : > "$FAKE_TMUX_SETTLE_RACE_MARKER"
            printf '%s' "$FAKE_TMUX_SETTLE_RACE_EPOCH" \
                > "$FAKE_TMUX_STATE/${target}.@code_notify_running"
            rm -f "$FAKE_TMUX_STATE/${target}.@code_notify_settle_since"
            exit 0
        fi
        if [[ "${FAKE_TMUX_INTERRUPT_RACE_MARKER:-}" != "" ]] &&
            [[ "${rest[0]}" == "@code_notify_running" ]] &&
            [[ ! -e "$FAKE_TMUX_INTERRUPT_RACE_MARKER" ]]; then
            # Model a queued-prompt preserve landing after the sweep's
            # list-windows snapshot. The preserve marks the settle watch
            # badge-only and deliberately leaves the running epoch alone
            # (tmux_running_stop returns before unsetting it), so the epoch
            # check the interrupt teardown makes cannot notice it.
            cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
            : > "$FAKE_TMUX_INTERRUPT_RACE_MARKER"
            printf '1' > "$FAKE_TMUX_STATE/${target}.@code_notify_settle_badge_only"
            exit 0
        fi
        if [[ "${FAKE_TMUX_LATE_GEN_RACE_MARKER:-}" != "" ]] &&
            [[ "${rest[0]}" == "@code_notify_run_gen" ]]; then
            # The first read answers truthfully, so a synthetic child's
            # start-up guard sees exactly the world it was scheduled against.
            # Every later read is the successor's — modelling the user
            # answering in the gap between that guard and the locked state
            # change it is supposed to protect.
            if [[ -e "$FAKE_TMUX_LATE_GEN_RACE_MARKER" ]]; then
                printf '%s' "successor.gen"
                exit 0
            fi
            : > "$FAKE_TMUX_LATE_GEN_RACE_MARKER"
        fi
        if [[ "${FAKE_TMUX_GEN_RACE_MARKER:-}" != "" ]] &&
            [[ "${rest[0]}" == "@code_notify_running" ]] &&
            [[ ! -e "$FAKE_TMUX_GEN_RACE_MARKER" ]]; then
            # Model a successor turn starting in the SAME second as the run the
            # sweep snapshotted, between that snapshot and this re-read. The
            # epoch is byte-identical; only the generation tells them apart.
            : > "$FAKE_TMUX_GEN_RACE_MARKER"
            printf '%s' "successor.gen" \
                > "$FAKE_TMUX_STATE/${target}.@code_notify_run_gen"
            cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
            exit 0
        fi
        if [[ "${FAKE_TMUX_PAUSE_BADGE_SET:-}" == "1" ]] &&
            [[ "${rest[0]}" == "@code_notify_orig_name" ]]; then
            : > "$FAKE_TMUX_BADGE_SET_SIGNAL"
            while [[ ! -e "$FAKE_TMUX_BADGE_SET_RELEASE" ]]; do sleep 0.01; done
        fi
        cat "$FAKE_TMUX_STATE/${target}.${rest[0]}" 2>/dev/null
        ;;
    set-option)
        if (( unset_opt )); then
            rm -f "$FAKE_TMUX_STATE/${target}.${rest[0]}"
            # Model a successor turn claiming the window in the instant a stop
            # drops the running marker — the gap in which tmux_running_stop has
            # released the transition lock and its caller has not yet re-taken
            # it. Fires once, so the successor's own later stops behave.
            if [[ -n "${FAKE_TMUX_SUCCESSOR_RACE_MARKER:-}" ]] &&
                [[ "${rest[0]}" == "@code_notify_running" ]] &&
                [[ ! -e "$FAKE_TMUX_SUCCESSOR_RACE_MARKER" ]]; then
                : > "$FAKE_TMUX_SUCCESSOR_RACE_MARKER"
                printf '%s' "$FAKE_TMUX_SUCCESSOR_RACE_EPOCH" \
                    > "$FAKE_TMUX_STATE/${target}.@code_notify_running"
                printf '%s' "successor.gen" \
                    > "$FAKE_TMUX_STATE/${target}.@code_notify_run_gen"
            fi
        else
            printf '%s' "${rest[1]}" > "$FAKE_TMUX_STATE/${target}.${rest[0]}"
        fi
        ;;
    rename-window)
        printf '%s' "${rest[0]}" > "$FAKE_TMUX_STATE/${target}.window_name"
        ;;
    capture-pane)
        # Real capture-pane fails on a vanished pane; mirror that so the
        # fail-propagation in tmux_resume_poll_fingerprint is exercised.
        if (( capture_history )) && [[ -f "$FAKE_TMUX_STATE/${target}.pane_history" ]]; then
            cat "$FAKE_TMUX_STATE/${target}.pane_history" 2>/dev/null || exit 1
        else
            cat "$FAKE_TMUX_STATE/${target}.pane_content" 2>/dev/null || exit 1
        fi
        ;;
    run-shell)
        # run-shell -d needs tmux >= 3.2; the knob simulates that failure so
        # the claim-rollback in the timer schedulers is exercised.
        if [[ -n "$FAKE_TMUX_RUN_SHELL_FAIL" ]]; then
            exit 1
        fi
        ;;
    if-shell)
        # Only the -F compare-and-clear form the timer schedulers use:
        # evaluate #{==:#{@option},value} against the state files and feed
        # the consequent back through this stub on a match. (The generic -*
        # parser above already captured the format into $fmt.)
        ifre='^#\{==:#\{(@[A-Za-z0-9_]+)\},(.*)\}$'
        if [[ "$fmt" =~ $ifre ]]; then
            opt="${BASH_REMATCH[1]}"
            want="${BASH_REMATCH[2]}"
            cur=$(cat "$FAKE_TMUX_STATE/${target}.${opt}" 2>/dev/null)
            if [[ "$cur" == "$want" ]]; then
                # shellcheck disable=SC2086
                "$0" ${rest[0]}
            fi
        fi
        ;;
esac
exit 0
EOF
chmod +x "$fake_bin/tmux"
export PATH="$fake_bin:$PATH"
export FAKE_TMUX_LOG="$log_file"
export FAKE_TMUX_STATE="$state_dir"

# Keep the disabled-flag file inside the sandbox
export HOME="$test_dir/home"
mkdir -p "$HOME"
# The real notifier falls back to python3 for JSON parsing when jq is off the
# restricted PATH; keep its bytecode cache out of the sandbox HOME so a
# detached run cannot repopulate the tree while the cleanup trap removes it.
export PYTHONDONTWRITEBYTECODE=1

source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"

# A hook launcher commonly has `codex` in its `sh -c` command line. The exit
# tracker must skip that short-lived wrapper and retain the actual agent parent.
resolved_agent_pid=$( (
    ps() {
        # ppid+comm and command are queried separately; answer each shape.
        if [[ "$*" == *command=* ]]; then
            case "${*: -1}" in
                100) printf '%s\n' '/bin/sh -c notifier.sh stop codex' ;;
                200) printf '%s\n' '/usr/local/bin/codex --resume' ;;
            esac
        else
            case "${*: -1}" in
                100) printf '%s\n' '  200 /bin/sh' ;;
                200) printf '%s\n' '    1 /usr/local/bin/codex' ;;
            esac
        fi
    }
    tmux_agent_exit_resolve_pid codex 100
) )
[[ "$resolved_agent_pid" == "200" ]] \
    || fail "agent exit tracker should skip a shell wrapper (got: $resolved_agent_pid)"
pass "agent exit tracker resolves the real agent process"

export TMUX="$test_dir/sock,12345,0"
export TMUX_PANE="%3"
# shellcheck disable=SC2016  # $1 is a literal tmux session ID, not a parameter
export FAKE_TMUX_TARGET='$1 @2 %3'
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
export FAKE_TMUX_WINDOWS=""
export FAKE_TMUX_SESSIONS=""

window_name() { cat "$state_dir/@2.window_name" 2>/dev/null; }
orig_option() { cat "$state_dir/@2.@code_notify_orig_name" 2>/dev/null; }
wait_for_path() {
    local path="$1" i
    for ((i = 0; i < 300; i++)); do
        [[ -e "$path" ]] && return 0
        sleep 0.01
    done
    return 1
}

# --- disabled via environment ---
CODE_NOTIFY_TMUX_BADGE=false tmux_badge_set "🟢" && fail "badge should be skipped when disabled via env"
[[ -z "$(window_name)" ]] || fail "disabled badge should not rename the window"
pass "disabled via environment"

# --- disabled via flag file ---
mkdir -p "$HOME/.claude/notifications"
touch "$HOME/.claude/notifications/tmux-badge-disabled"
tmux_badge_set "🟢" && fail "badge should be skipped when disabled via flag file"
rm -f "$HOME/.claude/notifications/tmux-badge-disabled"
pass "disabled via flag file"

# --- no-op outside tmux ---
(
    unset TMUX TMUX_PANE
    tmux_badge_set "🟢" && exit 1
    exit 0
) || fail "badge should fail outside tmux"
pass "no-op outside tmux"

# --- badge happy path ---
tmux_badge_set "🟢" || fail "badge should succeed inside tmux"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "window should be renamed with icon prefix (got: $(window_name))"
[[ "$(orig_option)" == "zsh" ]] || fail "original name should be saved in window option"
[[ "$(cat "$state_dir/@2.@code_notify_autorename")" == "on" ]] || fail "automatic-rename state should be saved"
pass "badge sets icon and saves state"

# --- repeat badge swaps icon, no stacking ---
tmux_badge_set "👋" || fail "second badge should succeed"
[[ "$(window_name)" == "👋 zsh" ]] || fail "second badge should swap the icon, not stack (got: $(window_name))"
[[ "$(orig_option)" == "zsh" ]] || fail "original name must survive a repeat badge"
pass "repeat badge swaps icon"

: > "$log_file"
export FAKE_TMUX_DYNAMIC_BADGE_INFO=1
tmux_badge_set "👋" || fail "identical badge should succeed"
unset FAKE_TMUX_DYNAMIC_BADGE_INFO
grep -q "rename-window" "$log_file" \
    && fail "an identical concurrent event should not rewrite the window"
pass "identical badge delivery is mutation-free"

# --- concurrent clear/apply stays atomic and never adopts a badge as the
# original name. Claude /code-review can launch many subagents whose hook
# processes all mutate the same tmux window. Force the old failing ordering:
# clear has captured the decorated name but not restored it yet, while a new
# badge setter tries to read state. The setter must wait for clear's window
# transition lock, then capture the restored name rather than "💬 project".
tmux_badge_clear "@2"
printf '%s' "project" > "$state_dir/@2.window_name"
export FAKE_TMUX_DYNAMIC_BADGE_INFO=1
tmux_badge_set "💬" engage || fail "concurrent badge setup should succeed"
badge_clear_signal="$test_dir/badge-clear-read"
badge_clear_release="$test_dir/badge-clear-release"
badge_set_lock_attempt="$test_dir/badge-set-lock-attempt"
badge_set_signal="$test_dir/badge-set-read"
badge_set_release="$test_dir/badge-set-release"
FAKE_TMUX_PAUSE_BADGE_CLEAR=1 \
FAKE_TMUX_BADGE_CLEAR_SIGNAL="$badge_clear_signal" \
FAKE_TMUX_BADGE_CLEAR_RELEASE="$badge_clear_release" \
    tmux_badge_clear "@2" &
badge_clear_pid=$!
wait_for_path "$badge_clear_signal" || fail "badge clear did not reach its paused state read"
# Instrument the real lock acquisition call, not scheduler timing. If
# tmux_badge_set ever stops taking the lock, this positive handshake never
# arrives and the regression fails deterministically.
mkdir() {
    if [[ -n "${FAKE_LOCK_ATTEMPT_SIGNAL:-}" ]] && [[ "$*" == *".lock"* ]]; then
        : > "$FAKE_LOCK_ATTEMPT_SIGNAL"
    fi
    command mkdir "$@"
}
FAKE_TMUX_PAUSE_BADGE_SET=1 \
FAKE_TMUX_BADGE_SET_SIGNAL="$badge_set_signal" \
FAKE_TMUX_BADGE_SET_RELEASE="$badge_set_release" \
FAKE_LOCK_ATTEMPT_SIGNAL="$badge_set_lock_attempt" \
    tmux_badge_set "💬" engage &
badge_set_pid=$!
wait_for_path "$badge_set_lock_attempt" || fail "badge setter did not attempt the transition lock"
: > "$badge_clear_release"
wait "$badge_clear_pid"
badge_clear_pid=""
wait_for_path "$badge_set_signal" || fail "badge setter did not continue after clear released"
: > "$badge_set_release"
wait "$badge_set_pid"
badge_set_pid=""
unset -f mkdir
[[ "$(window_name)" == "💬 project" ]] \
    || fail "concurrent hooks must not stack badge icons (got: $(window_name))"
[[ "$(orig_option)" == "project" ]] \
    || fail "concurrent hooks must preserve the undecorated original name"
unset FAKE_TMUX_DYNAMIC_BADGE_INFO
tmux_badge_clear "@2"
printf '%s' "zsh" > "$state_dir/@2.window_name"
tmux_badge_set "👋" || fail "badge state should be restored after the concurrency test"
pass "concurrent badge clear/apply preserves one event icon"

# --- lock fallback, stale-owner recovery, and bounded contention ---
saved_lock_dir="$TMUX_RUNNING_LOCK_DIR"
saved_lock_timeout="$TMUX_RUNNING_LOCK_TIMEOUT_MS"
saved_lock_stale="$TMUX_RUNNING_LOCK_STALE_SECONDS"
bad_lock_parent="$test_dir/not-a-directory"
printf '%s' "occupied" > "$bad_lock_parent"
TMUX_RUNNING_LOCK_DIR="$bad_lock_parent/running-locks"
tmux_badge_clear "@2"
tmux_badge_set "💬" engage || fail "badge should use the socket-local lock fallback"
[[ "$(window_name)" == "💬 zsh" ]] || fail "fallback lock should preserve normal badging"
tmux_badge_clear "@2"
TMUX_RUNNING_LOCK_DIR="$saved_lock_dir"

# Force the shared-temp fallback (a TMUX value without a socket-directory
# component) and reject both a planted final symlink and an intermediate
# per-user symlink. A securely created private directory remains usable.
saved_tmux="$TMUX"
saved_tmpdir_set="${TMPDIR+x}"
saved_tmpdir="${TMPDIR:-}"
shared_tmp="$test_dir/shared-tmp"
shared_uid="${UID:-$(id -u)}"
shared_parent="$shared_tmp/code-notify-$shared_uid"
shared_target="$test_dir/fallback-symlink-target"
mkdir "$shared_tmp" "$shared_target"
chmod 700 "$shared_tmp" "$shared_target"
mkdir "$shared_parent"
chmod 700 "$shared_parent"
ln -s "$shared_target" "$shared_parent/running-locks"
TMUX="fallback-noslash,123,0"
TMPDIR="$shared_tmp"
TMUX_RUNNING_LOCK_DIR="$bad_lock_parent/running-locks"
if tmux_running_transition_lock_acquire "@2"; then
    tmux_running_transition_lock_release \
        "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    fail "shared-temp fallback must reject a planted final symlink"
fi
rm -f "$shared_parent/running-locks"
rmdir "$shared_parent"
ln -s "$shared_target" "$shared_parent"
if tmux_running_transition_lock_acquire "@2"; then
    tmux_running_transition_lock_release \
        "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    fail "shared-temp fallback must reject a planted parent symlink"
fi
rm -f "$shared_parent"
tmux_running_transition_lock_acquire "@2" \
    || fail "secure shared-temp fallback should remain available"
tmux_running_transition_lock_release \
    "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
# A socket placed directly in a shared directory makes the socket-adjacent
# candidate unsafe; selection must continue to the same private hierarchy.
chmod 777 "$shared_tmp"
TMUX="$shared_tmp/direct.sock,123,0"
tmux_running_transition_lock_acquire "@2" \
    || fail "unsafe socket-adjacent fallback should use private shared-temp state"
[[ "$TMUX_RUNNING_TRANSITION_LOCKDIR" == "$shared_parent/running-locks/"* ]] \
    || fail "unsafe socket directory should fall through to the per-user fallback"
tmux_running_transition_lock_release \
    "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
TMUX="$saved_tmux"
if [[ "$saved_tmpdir_set" == "x" ]]; then TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
TMUX_RUNNING_LOCK_DIR="$saved_lock_dir"
pass "shared-temp lock fallback rejects symlinks and insecure ownership"

mkdir -p "$TMUX_RUNNING_LOCK_DIR"
stale_lock=$(tmux_running_transition_lock_path "@2")
mkdir "$stale_lock"
printf '%s %s %s' "$$" "$(( $(date +%s) - 10 ))" "reused.pid.token" > "$stale_lock/pid"
TMUX_RUNNING_LOCK_STALE_SECONDS=1
tmux_badge_set "💬" engage || fail "an old lock owned by a live/reused PID should be reclaimed"
[[ "$(window_name)" == "💬 zsh" ]] || fail "stale-lock recovery should still apply the badge"
tmux_badge_clear "@2"

# Two waiters that simultaneously decide the same dead generation is stale
# must serialize through the reclaim gate. Force waiter 1 to win that gate,
# hold the recovered lock, and make waiter 2 positively attempt acquisition
# while it is held; waiter 2 may acquire only after waiter 1 releases.
mkdir "$stale_lock"
printf '%s %s %s' "999999999" "$(( $(date +%s) - 10 ))" "dead.race.token" \
    > "$stale_lock/pid"
reclaim_gate="${stale_lock}.reclaim"
reclaim_ready_one="$test_dir/reclaim-ready-one"
reclaim_ready_two="$test_dir/reclaim-ready-two"
reclaim_gate_won="$test_dir/reclaim-gate-won"
reclaim_first_acquired="$test_dir/reclaim-first-acquired"
reclaim_second_retry="$test_dir/reclaim-second-retry"
reclaim_allow_retry="$test_dir/reclaim-allow-retry"
reclaim_retry_done="$test_dir/reclaim-retry-done"
reclaim_release_first="$test_dir/reclaim-release-first"
reclaim_second_acquired="$test_dir/reclaim-second-acquired"
reclaim_worker_failed="$test_dir/reclaim-worker-failed"
mkdir() {
    local last_arg="${!#}" status
    if [[ "$last_arg" == "$reclaim_gate" ]]; then
        if [[ "${LOCK_RECLAIM_RACE_ID:-}" == "1" ]]; then
            : > "$reclaim_ready_one"
            wait_for_path "$reclaim_ready_two" || return 1
            if command mkdir "$@"; then
                : > "$reclaim_gate_won"
                return 0
            fi
            return 1
        fi
        : > "$reclaim_ready_two"
        wait_for_path "$reclaim_gate_won" || return 1
        command mkdir "$@"
        status=$?
        LOCK_RECLAIM_RACE_AFTER_GATE=1
        return "$status"
    fi
    if [[ "${LOCK_RECLAIM_RACE_ID:-}" == "2" ]] &&
        [[ "${LOCK_RECLAIM_RACE_AFTER_GATE:-}" == "1" ]] &&
        [[ "$last_arg" == "$stale_lock" ]]; then
        : > "$reclaim_second_retry"
        wait_for_path "$reclaim_allow_retry" || return 1
        if command mkdir "$@"; then status=0; else status=$?; fi
        : > "$reclaim_retry_done"
        return "$status"
    fi
    command mkdir "$@"
}
reclaim_race_worker() {
    local id="$1" lock token
    if ! tmux_running_transition_lock_acquire "@2"; then
        : > "$reclaim_worker_failed"
        return 1
    fi
    lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    if [[ "$id" == "1" ]]; then
        : > "$reclaim_first_acquired"
        wait_for_path "$reclaim_release_first" || return 1
    else
        : > "$reclaim_second_acquired"
    fi
    tmux_running_transition_lock_release "$lock" "$token"
}
LOCK_RECLAIM_RACE_ID=1 reclaim_race_worker 1 &
reclaim_one_pid=$!
LOCK_RECLAIM_RACE_ID=2 reclaim_race_worker 2 &
reclaim_two_pid=$!
wait_for_path "$reclaim_first_acquired" || fail "first stale-lock waiter did not acquire"
wait_for_path "$reclaim_second_retry" || fail "second stale-lock waiter did not retry"
: > "$reclaim_allow_retry"
wait_for_path "$reclaim_retry_done" || fail "second stale-lock waiter did not contend with the recovered owner"
[[ ! -e "$reclaim_second_acquired" ]] \
    || fail "two stale-lock reclaimers entered the critical section together"
: > "$reclaim_release_first"
wait "$reclaim_one_pid"
reclaim_one_pid=""
wait "$reclaim_two_pid"
reclaim_two_pid=""
unset -f mkdir reclaim_race_worker
[[ ! -e "$reclaim_worker_failed" ]] || fail "a stale-lock race worker timed out"
[[ -e "$reclaim_second_acquired" ]] \
    || fail "second stale-lock waiter should acquire after the first releases"
pass "stale-lock reclamation admits exactly one waiter"

# A hook can itself die after claiming the reclaim gate. That gate carries an
# owner record too, so it must age out rather than permanently wedging every
# later badge operation on the window.
mkdir "$stale_lock"
printf '%s %s %s' "999999999" "$(( $(date +%s) - 10 ))" "dead.lock.token" \
    > "$stale_lock/pid"
mkdir "$reclaim_gate"
printf '%s %s %s' "999999998" "$(( $(date +%s) - 10 ))" "dead.gate.token" \
    > "$reclaim_gate/pid"
tmux_running_transition_lock_acquire "@2" \
    || fail "a dead reclaim-gate owner should not wedge lock recovery"
tmux_running_transition_lock_release \
    "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
[[ ! -e "$reclaim_gate" ]] || fail "stale reclaim gate should be retired"
pass "stale reclaim gate is recoverable"

# The reclaimer can be killed AFTER removing the primary lock but BEFORE
# releasing its gate: the lock is gone, only an orphaned stale gate remains.
# Every later acquire then re-creates the lock, sees that gate, and would
# relinquish forever. The mkdir-succeeds path must retire the aged-out gate.
rm -rf "$stale_lock" "$reclaim_gate"
mkdir "$reclaim_gate"
printf '%s %s %s' "999999997" "$(( $(date +%s) - 10 ))" "orphan.gate.token" \
    > "$reclaim_gate/pid"
tmux_running_transition_lock_acquire "@2" \
    || fail "an orphaned stale gate over a free lock should not wedge acquisition"
[[ ! -e "$reclaim_gate" ]] \
    || fail "an orphaned stale gate should be retired on the free-lock path"
tmux_running_transition_lock_release \
    "$TMUX_RUNNING_TRANSITION_LOCKDIR" "$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
pass "orphaned stale gate over a free lock is recoverable"

mkdir "$stale_lock"
printf '%s %s %s' "$$" "$(date +%s)" "active.owner.token" > "$stale_lock/pid"
TMUX_RUNNING_LOCK_STALE_SECONDS=30
TMUX_RUNNING_LOCK_TIMEOUT_MS=30
if tmux_running_transition_lock_acquire "@2"; then
    acquired_dir="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    acquired_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    tmux_running_transition_lock_release "$acquired_dir" "$acquired_token"
    fail "active lock contention should time out instead of stealing the lock"
fi
rm -f "$stale_lock/pid"
rmdir "$stale_lock"
TMUX_RUNNING_LOCK_DIR="$saved_lock_dir"
TMUX_RUNNING_LOCK_TIMEOUT_MS="$saved_lock_timeout"
TMUX_RUNNING_LOCK_STALE_SECONDS="$saved_lock_stale"
tmux_badge_set "👋" || fail "badge state should be restored after lock recovery tests"
pass "transition lock falls back, reclaims stale owners, and bounds waits"

# --- clear restores name, automatic-rename, and removes options ---
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "zsh" ]] || fail "clear should restore the original name"
grep -q -- "set-option -w -t @2 automatic-rename on" "$log_file" || fail "clear should restore automatic-rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should unset the orig-name option"
[[ ! -f "$state_dir/@2.@code_notify_autorename" ]] || fail "clear should unset the autorename option"
[[ ! -f "$state_dir/@2.@code_notify_badged_name" ]] || fail "clear should unset the badged-name option"
pass "clear restores window state"

# --- clear is a no-op without a badge ---
: > "$log_file"
tmux_badge_clear "@2"
grep -q "rename-window" "$log_file" && fail "clear without badge should not rename"
pass "clear no-op without badge"

# --- manual rename while badged becomes the new original ---
tmux_badge_set "🟢" || fail "badge before manual rename should succeed"
export FAKE_TMUX_BADGE_INFO='@2|off|0|work'   # user renamed the badged window
tmux_badge_set "👋" || fail "badge after manual rename should succeed"
[[ "$(window_name)" == "👋 work" ]] || fail "badge should adopt the user's new name (got: $(window_name))"
[[ "$(orig_option)" == "work" ]] || fail "manual rename should replace the saved original"
[[ "$(cat "$state_dir/@2.@code_notify_autorename")" == "off" ]] || fail "manual rename should pin automatic-rename off"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "manual rename becomes the new original"

# --- a rename that merely ends in the original name is still manual ---
# "api zsh" ends in " zsh", so a suffix match alone would mistake it for a
# badged form of "zsh"; the exact badged-name comparison must not.
tmux_badge_clear "@2"                          # reset state from the previous case
tmux_badge_set "🟢" || fail "badge before suffix-colliding rename should succeed"
export FAKE_TMUX_BADGE_INFO='@2|off|0|api zsh'   # user renamed "🟢 zsh" -> "api zsh"
tmux_badge_set "👋" || fail "badge after suffix-colliding rename should succeed"
[[ "$(window_name)" == "👋 api zsh" ]] || fail "badge should adopt a rename ending in the original name (got: $(window_name))"
[[ "$(orig_option)" == "api zsh" ]] || fail "suffix-colliding rename should replace the saved original"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "suffix-colliding rename becomes the new original"

# --- clear keeps a manual rename ---
tmux_badge_clear "@2"                          # reset state from the previous case
tmux_badge_set "🟢" || fail "badge for manual-rename clear test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "work" ]] || fail "clear must not clobber a manual rename (got: $(window_name))"
grep -q "automatic-rename on" "$log_file" && fail "clear after a manual rename must not re-enable automatic-rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state"
pass "clear keeps manual rename"

# --- clear keeps a manual rename that ends in the original name ---
tmux_badge_set "🟢" || fail "badge for suffix-colliding clear test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
tmux_badge_clear "@2"
[[ "$(window_name)" == "api zsh" ]] || fail "clear must not clobber a rename ending in the original name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear should still drop the badge state after a suffix-colliding rename"
pass "clear keeps suffix-colliding manual rename"

# --- legacy badge (no badged-name option) still clears via suffix match ---
printf '%s' "zsh" > "$state_dir/@2.@code_notify_orig_name"
printf '%s' "on" > "$state_dir/@2.@code_notify_autorename"
printf '%s' "🟢 zsh" > "$state_dir/@2.window_name"
rm -f "$state_dir/@2.@code_notify_badged_name"
tmux_badge_clear "@2"
[[ "$(window_name)" == "zsh" ]] || fail "legacy badge without a saved badged name should still restore (got: $(window_name))"
pass "legacy badge clears without badged-name option"

# --- visible window is not badged ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
: > "$log_file"
tmux_badge_set "🟢" || fail "badge on visible window should still exit 0"
grep -q "rename-window" "$log_file" && fail "visible window should not be renamed"
pass "visible window skipped"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a terminal event badges even the visible window, replacing a stale
# waiting badge (e.g. a permission prompt answered inline, then the task
# finishes while the user is looking right at the window) ---
tmux_badge_set "👋" engage || fail "stale-badge setup should succeed"
[[ "$(window_name)" == "👋 zsh" ]] || fail "precondition: window should carry the stale badge"
export FAKE_TMUX_BADGE_INFO='@2|on|1|👋 zsh'   # user is now looking at the window
tmux_badge_set "🟢" engage "" apply || fail "terminal badge on visible window should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "terminal event should badge the visible window (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "the visible completion badge should keep engage clear mode"
pass "terminal event badges the visible window, replacing a stale one"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a completion on a bare focused window still gets its badge ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
tmux_badge_set "🟢" engage "" apply || fail "completion badge on a bare visible window should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "completion badge should always show (got: $(window_name))"
pass "completion badge lands on a bare visible window"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- a waiting-type event (idle reminder, permission, mid-run) still skips
# the visible window and keeps an existing badge: it must not wipe or restack
# a done/complete badge the user has not engaged away yet ---
tmux_badge_set "🟢" engage || fail "done-badge setup should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should carry the done badge"
export FAKE_TMUX_BADGE_INFO='@2|on|1|🟢 zsh'   # user reads the output; idle reminder fires
tmux_badge_set "👋" engage || fail "waiting badge attempt on visible window should still exit 0"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "waiting event must keep the done badge (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "waiting event must keep the badge state"
pass "waiting event keeps an existing badge on a visible window"
tmux_badge_clear "@2"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'

# --- badge-visible toggle: env var wins, flag file is the persistent state ---
# The notifier promotes every event to visible_action=apply when this is on.
tmux_badge_visible_enabled && fail "badge-visible should default to off"
CODE_NOTIFY_TMUX_BADGE_VISIBLE=true tmux_badge_visible_enabled \
    || fail "badge-visible env true should enable"
touch "$HOME/.claude/notifications/tmux-badge-visible-enabled"
tmux_badge_visible_enabled || fail "badge-visible flag file should enable"
CODE_NOTIFY_TMUX_BADGE_VISIBLE=false tmux_badge_visible_enabled \
    && fail "badge-visible env false should override the flag file"
rm -f "$HOME/.claude/notifications/tmux-badge-visible-enabled"
pass "badge-visible toggle honours env and flag file"

# --- malformed window id is rejected ---
export FAKE_TMUX_BADGE_INFO='@2; rm -rf /|on|0|zsh'
tmux_badge_set "🟢" && fail "badge should reject a non-ID window"
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
pass "unsafe window id rejection"

# --- sweep clears only badged windows that are visible again ---
# list-windows format: window_id|visible|clear_mode|orig_name
tmux_badge_set "🟢" || fail "badge for sweep setup should succeed"
printf '%s' "other" > "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh\n@5|0|glance|other\n@7|1||'
tmux_badge_sweep
[[ "$(window_name)" == "zsh" ]] || fail "sweep should restore the visited window"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "sweep should unset options on the visited window"
[[ -f "$state_dir/@5.@code_notify_orig_name" ]] || fail "sweep must not touch a badged window that is still hidden"
pass "sweep clears visited windows only"
rm -f "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=""

# --- badge-set arms the focus-clear server hook ---
: > "$log_file"
tmux_badge_set "🟢" || fail "badge for hook-install test should succeed"
grep -qF "set-hook -g session-window-changed[8471]" "$log_file" \
    || fail "badge-set should install the session-window-changed focus hook"
grep -qF "set-hook -g client-session-changed[8471]" "$log_file" \
    || fail "badge-set should install the client-session-changed focus hook"
grep -qF "set-hook -g client-attached[8471]" "$log_file" \
    || fail "badge-set should install the client-attached focus hook"
grep -q "badge-sweep" "$log_file" || fail "focus hook should invoke badge-sweep"
pass "badge-set arms the focus-clear hook"

# --- the hook entry point (`tmux.sh badge-sweep`) clears from a subprocess ---
# This is exactly what the tmux hook runs: a fresh `bash tmux.sh badge-sweep`,
# with no TMUX_PANE. It must still clear the now-visible badged window. The
# empty clear-mode field doubles as the legacy-badge case (written before
# @code_notify_clear_mode existed): no saved mode is treated as glance.
export FAKE_TMUX_WINDOWS=$'@2|1||zsh'
env -u TMUX_PANE bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" badge-sweep
[[ "$(window_name)" == "zsh" ]] \
    || fail "badge-sweep subcommand should clear the visited window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "badge-sweep subcommand should drop the badge state"
export FAKE_TMUX_WINDOWS=""
pass "badge-sweep subcommand clears without TMUX_PANE"

# --- sweep is a no-op with no tmux server (TMUX unset) ---
tmux_badge_set "🟢" || fail "badge for no-server sweep should succeed"
: > "$log_file"
( unset TMUX; tmux_badge_sweep )
grep -q "list-windows" "$log_file" && fail "sweep should not query tmux when TMUX is unset"
tmux_badge_clear "@2"
export FAKE_TMUX_WINDOWS=""
pass "sweep no-ops without a tmux server"

# --- sweep retires the focus hook once no badge remains ---
tmux_badge_set "🟢" || fail "badge for hook-retire test should succeed"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh'   # the only badged window, now visible
: > "$log_file"
tmux_badge_sweep
[[ "$(window_name)" == "zsh" ]] || fail "sweep should clear the last badge"
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "sweep should retire the session hook when no badge remains"
grep -qF "set-hook -gu client-session-changed[8471]" "$log_file" \
    || fail "sweep should retire the client hook when no badge remains"
grep -qF "set-hook -gu client-attached[8471]" "$log_file" \
    || fail "sweep should retire the client-attached hook when no badge remains"
export FAKE_TMUX_WINDOWS=""
pass "sweep retires the focus hook when no badge remains"

# --- sweep keeps the hook while a badged window is still hidden ---
tmux_badge_set "🟢" || fail "badge for hook-keep test should succeed"
printf '%s' "other" > "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh\n@5|0|glance|other'   # @5 still hidden + badged
: > "$log_file"
tmux_badge_sweep
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    && fail "sweep must not retire the hook while a badge is still pending"
rm -f "$state_dir/@5.@code_notify_orig_name"
export FAKE_TMUX_WINDOWS=""
pass "sweep keeps the focus hook while a badge is still pending"

# --- focus hook self-retires when the lib has been uninstalled ---
# The hook payload embeds an absolute lib path that can outlive the install.
# With the lib gone the guard must unset both hooks via the embedded tmux
# binary + socket (run-shell guarantees neither PATH nor $TMUX) instead of
# erroring on every window switch forever. Exercised exactly as tmux would:
# the payload is pulled out of the recorded set-hook call and run with /bin/sh.
lib_copy="$test_dir/lib-copy.sh"
cp "$ROOT_DIR/lib/code-notify/utils/tmux.sh" "$lib_copy"
saved_lib_path="$TMUX_BADGE_LIB_PATH"
TMUX_BADGE_LIB_PATH="$lib_copy"
: > "$log_file"
tmux_badge_set "🟢" || fail "badge for self-retire test should succeed"
grep -qF 'run-shell -b "if [ -f ' "$log_file" \
    || fail "hook payload should guard on the lib file existing"
payload=$(sed -n 's/^set-hook -g session-window-changed\[8471\] run-shell -b "\(.*\)"$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "hook payload should be extractable from the set-hook call"

# lib still present: the payload's sweep branch clears the visible badge
export FAKE_TMUX_WINDOWS=$'@2|1|glance|zsh'
env -u TMUX_PANE /bin/sh -c "$payload" || fail "hook payload should run cleanly with the lib present"
[[ "$(window_name)" == "zsh" ]] \
    || fail "hook payload should sweep the badge while the lib exists (got: $(window_name))"
export FAKE_TMUX_WINDOWS=""

# lib gone: the payload unsets both hooks through the embedded tmux + socket
tmux_badge_set "🟢" || fail "re-badge for self-retire test should succeed"
rm -f "$lib_copy"
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$payload" || fail "hook payload should exit 0 with the lib missing"
grep -qF -- "-S $test_dir/sock set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "payload should self-retire the session hook when the lib is gone"
grep -qF -- "-S $test_dir/sock set-hook -gu client-session-changed[8471]" "$log_file" \
    || fail "payload should self-retire the client hook when the lib is gone"
grep -qF -- "-S $test_dir/sock set-hook -gu client-attached[8471]" "$log_file" \
    || fail "payload should self-retire the client-attached hook when the lib is gone"
grep -q "list-windows" "$log_file" && fail "payload must not attempt a sweep when the lib is gone"
tmux_badge_clear "@2"
TMUX_BADGE_LIB_PATH="$saved_lib_path"
pass "focus hook self-retires when the lib is gone"

# --- real tmux: the hook payload parses even with quote-hostile paths ---
# The fake tmux above logs calls and stores options but does NOT replicate
# tmux's own command-string parser, which re-processes \, " and $ inside "..."
# when a hook fires. So the tmux-quoting (tmux_focus_cmd_quote) is exercised
# here against a real, throwaway tmux server: a hook whose payload embeds a path
# containing " $ space and \ must still parse and run. Shell-quoting alone would
# let the " terminate tmux's double-quoted argument early and break the parse.
# The server uses a dedicated -L socket (killed by the EXIT trap) and -f
# /dev/null, so it never touches the user's tmux or config.
tmux_major=0
if [[ -n "$REAL_TMUX" ]]; then
    tmux_major=$("$REAL_TMUX" -V 2>/dev/null | grep -oE '[0-9]+' | head -n 1)
fi
if [[ "${tmux_major:-0}" -ge 3 ]]; then
    # dir name with " $ space \ and #{...} — all tmux-hostile. The #{q} exercises
    # run-shell's format expansion: an unescaped # would be rewritten as a format
    # before /bin/sh ever ran.
    qdir="$test_dir/pa\"th\$x #{q} \\y"
    marker="$qdir/fired.txt"
    mkdir -p "$qdir"
    # Build the payload exactly as tmux_badge_install_focus_hook does: an inner
    # shell command with shell-quoted paths, then the whole run-shell argument
    # tmux-quoted. run-shell (no -b) is synchronous so no polling race, but the
    # parse tmux performs is identical to the -b form the real hook uses.
    inner="touch $(tmux_focus_shell_quote "$marker")"
    payload="run-shell $(tmux_focus_cmd_quote "$inner")"
    "$REAL_TMUX" -L "$QUOTE_SOCK" -f /dev/null new-session -d -x 80 -y 24 \
        || fail "real-tmux: throwaway server should start"
    # Record the socket path so the EXIT trap can remove the file kill-server
    # leaves behind, wherever tmux placed it.
    quote_sock_path="$("$REAL_TMUX" -L "$QUOTE_SOCK" display-message -p '#{socket_path}' 2>/dev/null)"
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-hook -g "session-window-changed[8471]" "$payload"
    "$REAL_TMUX" -L "$QUOTE_SOCK" new-window        # fires session-window-changed
    i=0
    while [[ ! -f "$marker" && "$i" -lt 20 ]]; do sleep 0.1; i=$((i + 1)); done
    [[ -f "$marker" ]] \
        || fail "real-tmux: hook payload with quote-hostile paths should parse and run"
    pass "real-tmux hook payload survives quote-hostile paths"
else
    pass "real-tmux quote test skipped (tmux >= 3.0 not available)"
fi

# --- tmux_badge_clear_current clears the caller's own window ---
# The engage-clear path: an agent's UserPromptSubmit hook runs this to drop the
# badge on the window the user just handed work, resolving the window from the
# current pane (FAKE_TMUX_TARGET -> @2).
tmux_badge_set "🟢" || fail "badge for clear-current test should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should be badged"
tmux_badge_clear_current || fail "clear-current should succeed"
[[ "$(window_name)" == "zsh" ]] || fail "clear-current should restore the current window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear-current should drop the badge state"
pass "clear-current clears the caller's window"

# --- clear-current is a no-op without a badge ---
: > "$log_file"
tmux_badge_clear_current || fail "clear-current without a badge should still succeed"
grep -q "rename-window" "$log_file" && fail "clear-current without a badge should not rename"
pass "clear-current no-op without a badge"

# --- the badge-clear-current subcommand clears from a subprocess ---
# Exactly what the UserPromptSubmit hook runs: a fresh `bash tmux.sh
# badge-clear-current`, inheriting TMUX/TMUX_PANE from the pane it fired in.
tmux_badge_set "🟢" || fail "badge for clear-current subcommand test should succeed"
bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" badge-clear-current
[[ "$(window_name)" == "zsh" ]] || fail "badge-clear-current subcommand should clear the window (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "badge-clear-current subcommand should drop the badge state"
pass "badge-clear-current subcommand clears the window"

# --- badge-set suppresses the focus hook on request ---
# CODE_NOTIFY_TMUX_FOCUS_HOOK=false suppresses arming even for glance badges;
# the badge itself is still set.
: > "$log_file"
CODE_NOTIFY_TMUX_FOCUS_HOOK=false tmux_badge_set "🟢" || fail "suppressed-hook badge should still succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "badge should still be set when the focus hook is suppressed"
grep -q "set-hook -g session-window-changed" "$log_file" && fail "suppressed focus hook must not be armed"
tmux_badge_clear "@2"
pass "badge-set suppresses the focus hook on request"

# --- glance badge records its clear mode ---
tmux_badge_set "🟢" || fail "glance badge should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
    || fail "default badge should record clear mode glance"
tmux_badge_clear "@2"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "clear should unset the clear-mode option"
pass "glance badge records its clear mode"

# --- engage badge records its mode and arms no focus hook ---
: > "$log_file"
tmux_badge_set "🟢" engage || fail "engage badge should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "engage badge should still rename the window"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "engage badge should record clear mode engage"
grep -q "set-hook -g session-window-changed" "$log_file" \
    && fail "engage badge must not arm the glance-clear focus hook"
pass "engage badge records mode without arming the focus hook"

# --- sweep skips engage badges (and doesn't count them for the hook) ---
# The engage badge from above is visible, but only its owner's prompt-submit
# may clear it: the sweep must leave it badged. With no glance badge anywhere,
# the sweep must also retire the focus hook — an engage badge alone must not
# keep it alive.
export FAKE_TMUX_WINDOWS=$'@2|1|engage|zsh'
: > "$log_file"
tmux_badge_sweep
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "sweep must not clear a visible engage badge (got: $(window_name))"
[[ -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "sweep must not drop an engage badge's state"
grep -qF "set-hook -gu session-window-changed[8471]" "$log_file" \
    || fail "an engage badge alone must not keep the focus hook alive"
export FAKE_TMUX_WINDOWS=""
pass "sweep skips engage badges"

# --- clear-current clears an engage badge ---
# The owning agent's prompt-submit signal is the one path that clears an
# engage badge.
tmux_badge_clear_current || fail "clear-current on an engage badge should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "clear-current should clear an engage badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "clear-current should drop the engage badge's clear-mode option"
pass "clear-current clears an engage badge"

# --- running-start badges even the visible window with the static icon ---
export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'   # visible: event badges skip it, running must not
tmux_running_start || fail "running-start should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "running-start should set the static icon on a visible window (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "running marker should record clear mode running"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "running-start should store the start epoch"
pass "running-start sets the static icon and epoch"

# --- sweep leaves a fresh running marker alone ---
export FAKE_TMUX_WINDOWS="@2|1|running|zsh"
tmux_badge_sweep
[[ "$(window_name)" == "🌕 zsh" ]] || fail "sweep must not clear a fresh running marker (got: $(window_name))"
[[ -f "$state_dir/@2.@code_notify_running" ]] || fail "sweep must keep a fresh running epoch"
export FAKE_TMUX_WINDOWS=""
pass "sweep skips a fresh running marker"

# --- running-stop clears the marker and epoch ---
tmux_running_stop || fail "running-stop should succeed"
[[ "$(window_name)" == "zsh" ]] || fail "running-stop should restore the name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "running-stop should drop the epoch"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] || fail "running-stop should drop the badge state"
pass "running-stop clears marker and epoch"

# --- exiting an agent clears its running marker instead of waiting for TTL ---
# Hooks record the owning agent PID in real use. An impossible PID simulates a
# user quitting Codex/Claude (or closing the terminal) without a Stop hook.
tmux_running_start || fail "running-start before agent-exit cleanup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "agent exit should restore the static running badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "agent exit should drop the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_agent_pid" ]] \
    || fail "agent exit should drop the tracked process"
pass "agent exit clears the static running marker promptly"

# --- an exited agent also clears a pending completion/input badge ---
# Back to a hidden window: an engage badge skips a visible one (visible_action
# defaults to skip), which would make every badge_set below a silent no-op.
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
tmux_badge_set "🟢" engage || fail "badge before agent-exit cleanup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "badge agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "agent exit should restore an event badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] \
    || fail "agent exit should drop pending badge state"
pass "agent exit clears a pending event badge promptly"

# --- running-stop leaves exit tracking on a window that still carries a badge ---
# The stop pipeline calls tmux_running_stop before applying the completion
# badge, and some callers can never re-track afterwards: a synthetic notifier
# run (idle nudge, settle completion) has no agent ancestry to resolve a PID
# from, and badge-set skips a visible window entirely. If running-stop dropped
# the PID, the badge those paths leave behind would outlive the agent forever.
tmux_badge_set "🟢" engage || fail "badge before running-stop tracking test should succeed"
printf '%s' "$$" > "$state_dir/@2.@code_notify_agent_pid"
tmux_running_stop || fail "running-stop for the tracking test should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_agent_pid" 2>/dev/null)" == "$$" ]] \
    || fail "running-stop must keep the tracked agent PID for the remaining badge"
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "running-stop must leave the event badge in place (got: $(window_name))"
pass "running-stop keeps exit tracking alive for the remaining badge"

# --- the sweep serves a live agent's badge but retires a bare PID ---
# While the badge from above is up, a tick must keep the tracking (that is
# what cleans the badge when the agent exits). Once nothing remains on the
# window — e.g. a suppressed spinner-mode stop applied no badge — the same
# tick must retire the PID so the sweep chain winds down instead of polling
# for the rest of a long-lived agent session.
tmux_agent_exit_sweep || fail "sweep over a live tracked badge should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_agent_pid" 2>/dev/null)" == "$$" ]] \
    || fail "a live agent's badge must keep its exit tracking across ticks"
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "a tick with the agent alive must leave the badge alone (got: $(window_name))"
tmux_badge_clear "@2"
printf '%s' "$$" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "sweep over a bare tracked window should succeed"
[[ ! -f "$state_dir/@2.@code_notify_agent_pid" ]] \
    || fail "a live agent with nothing to clean must stop being polled"
pass "sweep keeps tracking for badges, retires bare PIDs"

# --- agent exit cleanup is scoped to the owning window ---
# A tmux server can have several Codex/Claude/agy panes. A dead process in one
# must not clear an unrelated live agent's marker or badge.
tmux_badge_set "🟢" engage || fail "dead-window badge setup should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
printf '%s' "code" > "$state_dir/@5.@code_notify_orig_name"
printf '%s' "off" > "$state_dir/@5.@code_notify_autorename"
printf '%s' "🌕 code" > "$state_dir/@5.@code_notify_badged_name"
printf '%s' "running" > "$state_dir/@5.@code_notify_clear_mode"
printf '%s' "🌕 code" > "$state_dir/@5.window_name"
printf '%s' "$(date +%s)" > "$state_dir/@5.@code_notify_running"
printf '%s' "$$" > "$state_dir/@5.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "multi-window agent-exit sweep should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "dead agent cleanup should restore only its own window (got: $(window_name))"
[[ "$(cat "$state_dir/@5.window_name")" == "🌕 code" ]] \
    || fail "live agent window must retain its running marker"
[[ -f "$state_dir/@5.@code_notify_agent_pid" ]] \
    || fail "live agent window must retain its tracked process"
rm -f "$state_dir/@5.@code_notify_orig_name" "$state_dir/@5.@code_notify_autorename" \
    "$state_dir/@5.@code_notify_badged_name" "$state_dir/@5.@code_notify_clear_mode" \
    "$state_dir/@5.@code_notify_running" "$state_dir/@5.@code_notify_agent_pid" "$state_dir/@5.window_name"
pass "agent exit cleanup is scoped to the owning window"

# --- the sweep leaves untracked windows alone ---
# Real tmux lists every window, with an empty pid field when the option is
# unset — e.g. an agy StopFinal badge, whose disowned watcher can never
# resolve an agent pid. Those badges live by glance/engage/TTL rules and must
# survive the exit sweep, even while a tracked agent keeps it re-arming.
tmux_badge_set "🟢" engage || fail "untracked badge setup should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should carry the untracked badge"
rm -f "$state_dir/@2.@code_notify_agent_pid"                # never tracked
printf '%s' "$$" > "$state_dir/@5.@code_notify_agent_pid"   # live tracked window elsewhere
tmux_agent_exit_sweep || fail "untracked-window sweep should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] \
    || fail "sweep must not clear an untracked window's badge (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
    || fail "sweep must not drop an untracked window's badge state"
rm -f "$state_dir/@5.@code_notify_agent_pid"
tmux_badge_clear "@2"
pass "agent-exit sweep leaves untracked windows alone"

# --- an input pause resumes only on a later lifecycle signal ---
tmux_running_start || fail "running-start before input pause should succeed"
tmux_running_pause_for_input || fail "input pause should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "input pause should remove the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "input pause should retain a resume marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "input pause should restore the static running icon (got: $(window_name))"
tmux_running_resume_after_input || fail "input resume should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "input resume should restore the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "input resume should consume the resume marker"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "input resume should restore the static running icon (got: $(window_name))"
tmux_running_stop || fail "cleanup after input resume should succeed"
pass "input pause resumes the running indicator once"

# --- the dialog-marker helper needs the question AND a Yes/No selector ---
# A real permission dialog renders both the "Do you want to …?" question and a
# numbered Yes/No selector; requiring both keeps a lone "Do you want …" line in
# ordinary transcript/model output — even one that opens a rendered line behind
# a bullet or box border — from being mistaken for the dialog. Explicitly empty
# overrides must disable each half (the top-level assignment uses `-`, not
# `:-`, so an empty value sticks).
default_markers="$TMUX_DIALOG_MARKERS"
default_options="$TMUX_DIALOG_OPTIONS"
default_cancel_markers="$TMUX_DIALOG_CANCEL_MARKERS"
default_cancel_agents="$TMUX_DIALOG_CANCEL_AGENTS"
# The exact real Claude Code permission rendering: a "Do you want …?" question
# and an indented "❯ 1. Yes" selector cursor (note the leading space before ❯).
real_dialog=$'Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don\'t ask again\n   3. No'
[[ "$(tmux_resume_poll_dialog_flag "$real_dialog")" == "1" ]] \
    || fail "the default should match the real permission dialog (question + ❯ selector)"
[[ "$(tmux_resume_poll_dialog_flag "$(printf '│ Do you want to run this command?\n│ 2. Yes, and\n│ 3. No')")" == "1" ]] \
    || fail "the default should match past box/indent framing"
# Plan-mode approval uses a different question ("Would you like to proceed?")
# with the same selector chrome; the default must cover it too.
plan_dialog=$'Would you like to proceed?\n ❯ 1. Yes, and auto-accept edits\n   3. No, keep planning'
[[ "$(tmux_resume_poll_dialog_flag "$plan_dialog")" == "1" ]] \
    || fail "the default should match plan-mode approval (Would you like + selector)"
# Line-leading prose the reviewer flagged: a question line with no Yes/No
# selector, plain or behind a bullet, must NOT read as a dialog.
[[ "$(tmux_resume_poll_dialog_flag "Do you want to know more about this approach?")" == "0" ]] \
    || fail "REGRESSION: a line-leading question with no selector must not match"
[[ "$(tmux_resume_poll_dialog_flag "• Do you want me to continue with the refactor?")" == "0" ]] \
    || fail "REGRESSION: a bullet-prefixed question with no selector must not match"
[[ "$(tmux_resume_poll_dialog_flag "Would you like me to continue? Do you want more?")" == "0" ]] \
    || fail "REGRESSION: mid-sentence prose must not be mistaken for a dialog"
[[ "$(tmux_resume_poll_dialog_flag "sure, do you want to proceed with that")" == "0" ]] \
    || fail "REGRESSION: a mid-line lowercase phrase must not match"
# A stray numbered Yes/No item alone (a prose list) is not a dialog either.
[[ "$(tmux_resume_poll_dialog_flag "$(printf 'Here are the options:\n1. Yes\n2. No')")" == "0" ]] \
    || fail "a Yes/No list with no question line must not match"
# Antigravity's file-write approval: an "Allow …?" question over the same
# numbered Yes/No selector chrome.
agy_file_dialog=$'Allow creation of this file?\n> 1. Yes, allow creation\n  2. No, deny creation'
[[ "$(tmux_resume_poll_dialog_flag "$agy_file_dialog")" == "1" ]] \
    || fail "the default should match Antigravity's file-write approval"
# Antigravity's subagent approval renders no question mark and no numbered
# options — an unanchored "needs approval for" line paired with its
# keybinding row is the equivalent question + selector pair.
agy_subagent_dialog=$'research needs approval for Read\n\nctrl+k approve · alt+j manage'
[[ "$(tmux_resume_poll_dialog_flag "$agy_subagent_dialog")" == "1" ]] \
    || fail "the default should match Antigravity's subagent approval"
# "Allow" opens prose lines far more often than "Do you want": without the
# question mark (or with one but no selector) it must not read as a dialog.
[[ "$(tmux_resume_poll_dialog_flag "Allow me to explain the approach first.")" == "0" ]] \
    || fail "line-leading Allow prose without a question mark must not match"
[[ "$(tmux_resume_poll_dialog_flag "Allow overwriting this file? I would not recommend it.")" == "0" ]] \
    || fail "an Allow question with no selector must not match"
[[ "$(tmux_resume_poll_dialog_flag "The setting needs approval for deployment to work.")" == "0" ]] \
    || fail "prose containing 'needs approval for' with no selector must not match"
# Antigravity renders this exact status when a permission is rejected and
# emits no matching lifecycle hook. It must be distinguishable from prose so
# the pause poll can retire the waiting badge without inventing a resumed run.
agy_declined=$'Command\n  └ User declined the tool call'
tmux_resume_poll_cancel_count "$agy_declined"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "1" ]] \
    || fail "the default should match Antigravity's declined-tool status"
tmux_resume_poll_cancel_count "The log says User declined the tool call yesterday"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "0" ]] \
    || fail "mid-line decline prose must not be mistaken for a cancelled dialog"
TMUX_DIALOG_CANCEL_MARKERS=""
tmux_resume_poll_cancel_count "$agy_declined"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "0" ]] \
    || fail "an empty cancel pattern should disable rejection detection"
TMUX_DIALOG_CANCEL_MARKERS="$default_cancel_markers"
TMUX_DIALOG_OPTIONS=""
[[ "$(tmux_resume_poll_dialog_flag "Do you want to proceed?")" == "1" ]] \
    || fail "an empty options pattern should fall back to question-only matching"
TMUX_DIALOG_OPTIONS="$default_options"
TMUX_DIALOG_MARKERS=""
[[ "$(tmux_resume_poll_dialog_flag "$real_dialog")" == "0" ]] \
    || fail "an empty marker pattern should disable dialog detection"
TMUX_DIALOG_MARKERS="$default_markers"
# The top-level assignments themselves: an explicit empty env value must not
# revert to the default (regression against the `:-` expansion), and an unset
# one must fall back to the default.
( CODE_NOTIFY_TMUX_DIALOG_MARKERS="" CODE_NOTIFY_TMUX_DIALOG_OPTIONS="" \
      CODE_NOTIFY_TMUX_DIALOG_CANCEL_MARKERS="" \
      source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"
  [[ -z "$TMUX_DIALOG_MARKERS" && -z "$TMUX_DIALOG_OPTIONS" &&
      -z "$TMUX_DIALOG_CANCEL_MARKERS" ]] \
      || fail "REGRESSION: explicit empty overrides must not revert to the default" ) \
    || exit 1
( unset CODE_NOTIFY_TMUX_DIALOG_MARKERS CODE_NOTIFY_TMUX_DIALOG_OPTIONS \
      CODE_NOTIFY_TMUX_DIALOG_CANCEL_MARKERS
  source "$ROOT_DIR/lib/code-notify/utils/tmux.sh"
  [[ -n "$TMUX_DIALOG_MARKERS" && -n "$TMUX_DIALOG_OPTIONS" &&
      -n "$TMUX_DIALOG_CANCEL_MARKERS" ]] \
      || fail "unset overrides should fall back to the default patterns" ) \
    || exit 1
# A custom pattern beginning with "-" must be treated as a pattern, not a grep
# option (grep -qE -e "$pattern"); otherwise grep errors and detection
# silently reports 0.
TMUX_DIALOG_OPTIONS=""
TMUX_DIALOG_MARKERS="-x approval"
[[ "$(tmux_resume_poll_dialog_flag "prefix -x approval suffix")" == "1" ]] \
    || fail "REGRESSION: a marker pattern starting with - must be treated as a pattern"
TMUX_DIALOG_MARKERS="$default_markers"
TMUX_DIALOG_OPTIONS="$default_options"
tmux_resume_poll_cancel_enabled antigravity \
    || fail "Antigravity should be eligible for decline detection by default"
tmux_resume_poll_cancel_enabled claude \
    && fail "Claude must not pay for Antigravity-only decline detection"
TMUX_DIALOG_CANCEL_AGENTS="codex"
tmux_resume_poll_cancel_enabled codex \
    || fail "the decline-detection agent allowlist should be configurable"
tmux_resume_poll_cancel_enabled antigravity \
    && fail "the configured decline allowlist should replace the default"
TMUX_DIALOG_CANCEL_AGENTS="$default_cancel_agents"
pass "dialog-marker helper needs question plus selector, prose-safe, disablable"

# --- resume capture keeps visible content separate from retained history ---
# Dialog/fingerprint input must come directly from ordinary capture-pane -p;
# retained history is a second Antigravity-only input used solely for the
# monotonic decline count. Reconstructing the viewport from `-N -S -` shifts
# blank-bottom screens upward and turns padded history into a Bash hot loop.
printf '%s' "VISIBLE SCREEN WITH BLANK BOTTOM ROWS" > "$state_dir/%3.pane_content"
printf '%s\n%s' "OFFSCREEN HISTORY" "$agy_declined" > "$state_dir/%3.pane_history"
: > "$log_file"
tmux_resume_poll_capture "%3" 0 || fail "visible-only resume capture should succeed"
[[ "$TMUX_RESUME_POLL_CONTENT" == "VISIBLE SCREEN WITH BLANK BOTTOM ROWS" ]] \
    || fail "visible-only capture must preserve ordinary capture-pane input"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "0" ]] \
    || fail "a non-eligible agent capture must not scan retained history"
[[ "$(grep -c 'capture-pane ' "$log_file")" == "1" ]] \
    || fail "a non-eligible agent should pay for one visible capture only"
grep -q 'capture-pane .* -S -' "$log_file" \
    && fail "a non-eligible agent must not capture retained history"
: > "$log_file"
tmux_resume_poll_capture "%3" 1 || fail "Antigravity resume capture should succeed"
[[ "$TMUX_RESUME_POLL_CONTENT" == "VISIBLE SCREEN WITH BLANK BOTTOM ROWS" ]] \
    || fail "history counting must not replace the visible fingerprint input"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "1" ]] \
    || fail "eligible capture should count declines in retained history"
[[ "$(grep -c 'capture-pane ' "$log_file")" == "2" ]] \
    || fail "eligible capture should use one visible and one history capture"
grep -q 'capture-pane .* -N' "$log_file" \
    && fail "resume capture must not request padded -N history"
# A malformed user ERE makes grep exit 2. Decline detection is advisory: the
# valid visible capture must still reach dialog/fingerprint evaluation so an
# answered request can resume normally.
TMUX_DIALOG_CANCEL_MARKERS='User declined ([unclosed'
tmux_resume_poll_cancel_history_count "%3" \
    && fail "the malformed-ERE fixture should make history counting fail"
tmux_resume_poll_capture "%3" 1 \
    || fail "a malformed decline ERE must not fail the visible capture"
[[ "$TMUX_RESUME_POLL_CONTENT" == "VISIBLE SCREEN WITH BLANK BOTTOM ROWS" ]] \
    || fail "malformed decline detection must preserve visible content"
[[ "$TMUX_RESUME_POLL_CANCEL_COUNT" == "0" ]] \
    || fail "a failed decline count should degrade to no decline this tick"
TMUX_DIALOG_CANCEL_MARKERS="$default_cancel_markers"
rm -f "$state_dir/%3.pane_content" "$state_dir/%3.pane_history"
pass "resume capture preserves visible content across optional history failures"

# --- a watched input pause defers its snapshot and schedules the poll ---
# No hook fires when the user answers an approval dialog, so a "watch" pause
# records its pane and parks a short run-shell timer on the server. It must not
# checksum synchronously: the hook's own transient status line is still on
# screen and its disappearance is not a user answer. The payload carries the
# poll settings AND the active
# running-indicator configuration — the timer's fresh process would otherwise
# resume with default icon/spinner/TTL, flipping per-session overrides.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
# A declined card from an older request is already visible when this new pause
# is armed. Its count becomes this request's synchronous rejection baseline.
printf '%s' "$agy_declined" > "$state_dir/%3.pane_content"
TMUX_RUNNING_ICON="🚀"   # per-session override; must survive into the payload
tmux_running_start || fail "running-start before the poll-schedule test should succeed"
: > "$log_file"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_pause_for_input watch \
    || fail "watched pause for the poll-schedule test should succeed"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "a watched input pause should schedule the 2s resume poll"
[[ -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "the pending poll should be recorded in @code_notify_resume_poll_scheduled"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,1,"* ]] \
    || fail "a watched pause should defer its checksum and record baseline plus generation"
grep "^run-shell -b -d 2 " "$log_file" | grep -q "CODE_NOTIFY_TMUX_RUNNING_ICON='🚀'" \
    || fail "the poll payload should carry the running-indicator configuration"
pass "watched pause defers the dialog snapshot and schedules the poll"

# --- the first poll baselines the settled dialog without resuming ---
# Run the timer payload exactly as tmux would (/bin/sh -c, no TMUX_PANE).
# The notification hook's status UI may have disappeared since the pause; the
# first poll must absorb that change as its baseline, not call it an answer.
payload=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "the poll payload should be extractable from the run-shell call"
payload_has_setting() {
    local payload_text="$1" setting="$2" value="$3" expected
    expected="$setting=$(tmux_focus_shell_quote "$value")"
    expected="${expected//\#/##}"
    [[ "$payload_text" == *"$expected"* ]]
}
payload_has_setting "$payload" CODE_NOTIFY_TMUX_AGENT_EXIT_POLL_SECONDS "$TMUX_AGENT_EXIT_POLL_SECONDS" \
    || fail "resume payload must preserve the agent-exit poll interval"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_SETTLE_SECONDS "$TMUX_SETTLE_SECONDS" \
    || fail "resume payload must preserve the settle threshold"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_IDLE_SECONDS "$TMUX_IDLE_SECONDS" \
    || fail "resume payload must preserve the idle threshold"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_IDLE_AGENTS "$TMUX_IDLE_AGENTS" \
    || fail "resume payload must preserve the idle-agent allowlist"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_DIALOG_NOTIFY_SECONDS "$TMUX_DIALOG_NOTIFY_SECONDS" \
    || fail "resume payload must preserve the dialog-watch threshold"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_DIALOG_WATCH_AGENTS "$TMUX_DIALOG_WATCH_AGENTS" \
    || fail "resume payload must preserve the dialog-watch allowlist"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_DIALOG_CANCEL_AGENTS "$TMUX_DIALOG_CANCEL_AGENTS" \
    || fail "resume payload must preserve the decline-detection allowlist"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_INTERRUPT_SECONDS "$TMUX_INTERRUPT_SECONDS" \
    || fail "resume payload must preserve the interrupt threshold"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_INTERRUPT_WATCH_AGENTS "$TMUX_INTERRUPT_WATCH_AGENTS" \
    || fail "resume payload must preserve the interrupt allowlist"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_INTERRUPT_MARKERS "$TMUX_INTERRUPT_MARKERS" \
    || fail "resume payload must preserve interrupt markers"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_INTERRUPT_QUIET_SECONDS "$TMUX_INTERRUPT_QUIET_SECONDS" \
    || fail "resume payload must preserve interrupt quiet time"
payload_has_setting "$payload" CODE_NOTIFY_TMUX_BUSY_MARKERS "$TMUX_BUSY_MARKERS" \
    || fail "resume payload must preserve busy markers"
payload_has_setting "$payload" CODE_NOTIFY_NOTIFIER_PATH "${CODE_NOTIFY_NOTIFIER_PATH:-}" \
    || fail "resume payload must preserve the notifier override"
# Each registration carries a fresh chain token, so a re-fired stale payload
# string deliberately loses ownership and exits (asserted in its own test
# below). Between ticks, adopt the payload the previous tick re-scheduled —
# exactly the timer real tmux would fire next.
fire_poll_payload() {
    env -u TMUX_PANE /bin/sh -c "$payload" || return 1
    local next
    next=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | tail -n 1)
    [[ -n "$next" ]] && payload="$next"
    return 0
}
pending=$(cat "$state_dir/@2.@code_notify_resume_pending")
# The new dialog still has not painted. Seeing exactly the old baseline count
# must keep the pause alive rather than attributing that card to this request.
printf '%s\n%s' "$agy_declined" "hook status cleared; new dialog not painted" \
    > "$state_dir/%3.pane_content"
printf '%s' "$((pending + 5))" > "$state_dir/@2.window_activity"
: > "$log_file"
fire_poll_payload || fail "the poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first poll must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a quiet window should keep its pause marker"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,1,"*" "* ]] \
    || fail "the first poll should save the settled dialog baseline"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "the poll should reschedule while a pause marker remains"
pass "first poll baselines hook UI changes without resuming"

# --- a glance (activity without content change) must not resume ---
# Visiting the waiting window delivers a focus event and the TUI repaints the
# same dialog: #{window_activity} advances but the snapshot still matches, so
# the poll must keep waiting instead of showing a running agent.
printf '%s' "$((pending + 5))" > "$state_dir/@2.window_activity"   # focus repaint
: > "$log_file"
fire_poll_payload || fail "the glance poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a glance must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a glanced-at window should keep its pause marker"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "the poll should keep watching after a glance"
pass "glance advances activity but does not resume"

# --- a vanished pane must not read as a content change ---
# capture-pane fails on a closed split; cksum of that empty pipe would be a
# valid-looking checksum that differs from the snapshot, resuming a window
# whose agent is gone (nothing would ever correct it — the agent fires no
# more hooks). The failure must propagate and keep the window waiting.
rm -f "$state_dir/%3.pane_content"   # the watched split was closed
tmux_resume_poll_sweep || fail "poll sweep with a vanished pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a vanished pane must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a vanished pane should keep its pause marker for the hooks"
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
pass "vanished pane keeps waiting instead of resuming"

# --- a pane moved to another window must not resume the recorded one ---
# break-pane keeps the pane id alive under a different window; its content
# says nothing about the recorded window's dialog.
export FAKE_TMUX_PANE_WINDOW='@9'
printf '%s' "content of some other window" > "$state_dir/%3.pane_content"
tmux_resume_poll_sweep || fail "poll sweep with a moved pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a moved pane's content must not resume the recorded window"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a moved pane should keep the recorded window's pause marker"
unset FAKE_TMUX_PANE_WINDOW
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
pass "moved pane keeps the recorded window waiting"

# --- a one-shot repaint must not resume ---
# The PermissionRequest hook fires before the dialog UI, so the baseline can
# predate the dialog entirely (in Ctrl+O verbose mode it only renders once the
# user leaves the transcript view). The dialog finally painting — or any
# focus/view-toggle repaint — is a single content change followed by
# stillness, and must re-baseline instead of clearing the waiting badge for a
# spinner; only a pane that keeps changing (a working agent's ticking TUI)
# reads as an answer.
printf '%s' "approval dialog rendered on focus" > "$state_dir/%3.pane_content"
: > "$log_file"
fire_poll_payload || fail "the one-shot poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a one-shot repaint must not restore the running epoch"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a one-shot repaint should keep the pause marker"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,1,"*" 1 0" ]] \
    || fail "a first content change should re-baseline with the changed flag"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "the poll should keep watching after a one-shot repaint"
: > "$log_file"
fire_poll_payload || fail "the still-tick poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a still tick after a one-shot repaint must not resume"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,1,"*" 0 0" ]] \
    || fail "a still tick should drop the changed flag"
pass "one-shot repaint re-baselines instead of resuming"

# --- an on-screen dialog suppresses resume even while the pane animates ---
# A backgrounded shell command keeps a flashing dot / ticking timer on screen
# while the approval dialog waits, so the fingerprint changes on EVERY tick
# with no answer given. While the capture shows the dialog (question + Yes/No
# selector) the poll must keep waiting, however much the rest of the pane
# moves. The selector row is stable; only the dot line animates.
dialog_head=$'Do you want to run this command?\n❯ 1. Yes\n  3. No'
# A prior rejected card can remain visible above a newer request; the live
# dialog must win over that stale terminal line.
printf '%s\n%s\n%s' "$agy_declined" "$dialog_head" "· make test (2s)" \
    > "$state_dir/%3.pane_content"
# A sibling ask is declined while this dialog remains visibly unanswered.
# Retained history now has two decline rows, but the visible tail is only the
# live dialog. The poll must absorb the sibling transition into this pause's
# baseline rather than cancelling when this dialog is later approved.
printf '%s\n%s\n%s\n%s' "$agy_declined" "$agy_declined" "$dialog_head" \
    "· make test (2s)" > "$state_dir/%3.pane_history"
export FAKE_TMUX_PANE_HEIGHT=4
fire_poll_payload || fail "the dialog-marker tick should run cleanly"
unset FAKE_TMUX_PANE_HEIGHT
rm -f "$state_dir/%3.pane_history"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an on-screen dialog must not resume on a content change"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a stale declined card must not cancel a newer on-screen dialog"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,2,"*" 0 1" ]] \
    || fail "the marker tick should absorb sibling declines and record the dialog flag"
printf '%s\n%s' "$dialog_head" "• make test (4s)" \
    > "$state_dir/%3.pane_content"
fire_poll_payload || fail "the animated-dialog tick should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an animating pane behind an on-screen dialog must not resume"
printf '%s\n%s' "$dialog_head" "· make test (6s)" \
    > "$state_dir/%3.pane_content"
fire_poll_payload || fail "the third animated-dialog tick should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "sustained animation under an on-screen dialog must not resume"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,2,"*" 0 1" ]] \
    || fail "the dialog flag should persist while the marker stays on screen"
pass "on-screen dialog suppresses resume despite continuous animation"

# --- hiding the dialog (Ctrl+O transcript view) is not an answer ---
# The marker vanishing re-baselines and hands over to the fingerprint
# heuristic: a transcript view over a waiting dialog holds still, so nothing
# resumes; returning to the normal view re-enters marker mode.
# Ctrl+O hides the still-unanswered dialog while exposing the old declined
# card. Its retained count does not exceed the ratcheted pause baseline, so
# this is not a rejection transition and must remain watched.
printf '%s\n%s' "$agy_declined" "transcript view, dialog hidden" \
    > "$state_dir/%3.pane_content"
fire_poll_payload || fail "the marker-vanish tick should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "hiding the dialog behind the transcript view must not resume"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,2,"*" 0 0" ]] \
    || fail "the marker-vanish tick should re-baseline without flags"
fire_poll_payload || fail "the still transcript tick should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a still transcript view must not resume"
printf '%s\n%s' "$dialog_head" "· make test (20s)" \
    > "$state_dir/%3.pane_content"
fire_poll_payload || fail "the view-return tick should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "returning to the dialog view must not resume"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,2,"*" 0 1" ]] \
    || fail "returning to the dialog view should re-enter marker mode"
pass "hiding and revealing the dialog never resumes"

# --- sustained content change resumes the indicator with the configured icon ---
# The user answers: the dialog collapses (marker vanishes) and the resumed
# turn keeps repainting its TUI, which is what finally reads as an answer.
printf '%s' "tool output streaming" > "$state_dir/%3.pane_content"   # user answered
: > "$log_file"
fire_poll_payload || fail "the marker-collapse poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the dialog collapsing alone must not restore the running epoch"
printf '%s' "tool output streaming (2s)" > "$state_dir/%3.pane_content"
: > "$log_file"
fire_poll_payload || fail "the first resuming poll payload should run cleanly"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first changed tick alone must not restore the running epoch"
printf '%s' "tool output streaming (4s)" > "$state_dir/%3.pane_content"
: > "$log_file"
fire_poll_payload || fail "the second resuming poll payload should run cleanly"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "two consecutive changed ticks should restore the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "the poll resume should consume the pause marker"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "the poll resume should consume the dialog snapshot"
[[ "$(window_name)" == "🚀 zsh" ]] \
    || fail "the poll resume should use the configured running icon (got: $(window_name))"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "the poll must not reschedule once no pause marker remains"
rm -f "$state_dir/@2.window_activity" "$state_dir/%3.pane_content"
tmux_running_stop || fail "cleanup after the poll resume should succeed"
TMUX_RUNNING_ICON="🌕"
pass "sustained content change resumes the indicator via the poll"

# --- declining a permission retires the pause instead of resuming it ---
# Antigravity writes one final status line and emits no PostToolUse/Stop when
# the user rejects the tool. The pane then holds still, so the ordinary
# two-repaint approval heuristic can never act: the explicit status must clear
# the pause, its mirrored flag, and the engage-clear waiting badge directly.
# The visible pane contains one old decline both before and after this request;
# only retained history reveals that a second, new decline replaced it. This
# is the viewport-replacement case a visible-count baseline cannot detect.
printf '%s' "$agy_declined" > "$state_dir/%3.pane_content"
printf '%s' "$agy_declined" > "$state_dir/%3.pane_history"
: > "$log_file"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_start \
    || fail "running-start before the rejection test should succeed"
saved_agent_exit_poll="$TMUX_AGENT_EXIT_POLL_SECONDS"
TMUX_AGENT_EXIT_POLL_SECONDS=0
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_pause_for_input watch \
    || fail "watched pause before the rejection test should succeed"
TMUX_AGENT_EXIT_POLL_SECONDS="$saved_agent_exit_poll"
tmux_badge_set "💬" engage \
    || fail "permission badge before the rejection test should succeed"
# A declined ask ends only this pause. Preserve the per-turn contexts needed
# by queued Antigravity asks, while proving their request-local epochs reset.
dialog_ctx="%3 antigravity queued-project"
interrupt_marker="$HOME/.claude/notifications/agy/queued.running"
mkdir -p "$(dirname "$interrupt_marker")"
printf '%s' "$dialog_ctx" > "$state_dir/@2.@code_notify_dialog_ctx"
printf '%s' "1700000000" > "$state_dir/@2.@code_notify_dialog_since"
printf '%s' "%3" > "$state_dir/@2.@code_notify_interrupt_pane"
printf '%s' "old-fingerprint" > "$state_dir/@2.@code_notify_interrupt_fp"
printf '%s' "1700000000" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s' "$interrupt_marker" > "$state_dir/@2.@code_notify_interrupt_markerfile"
printf '%s' "running-cache" > "$interrupt_marker"
payload=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | tail -n 1)
[[ -n "$payload" ]] || fail "the rejection poll payload should be extractable"
printf '%s' "$agy_declined" > "$state_dir/%3.pane_content"
printf '%s\n%s' "$agy_declined" "$agy_declined" > "$state_dir/%3.pane_history"
export FAKE_TMUX_PANE_HEIGHT=1
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
fire_poll_payload || fail "the rejection poll payload should run cleanly"
unset FAKE_TMUX_PANE_HEIGHT
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a rejected permission must not restore the running epoch"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "a rejected permission should consume the pause marker"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "a rejected permission should consume the dialog snapshot"
[[ ! -e "$(tmux_resume_flag_path '@2')" ]] \
    || fail "a rejected permission should remove the mirrored resume flag"
[[ "$(window_name)" == "zsh" ]] \
    || fail "a rejected permission should clear the waiting badge (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_dialog_ctx" 2>/dev/null)" == "$dialog_ctx" ]] \
    || fail "a rejected permission must preserve the queued-ask dialog context"
[[ ! -f "$state_dir/@2.@code_notify_dialog_since" ]] \
    || fail "a rejected permission should reset the dialog sighting epoch"
[[ "$(cat "$state_dir/@2.@code_notify_interrupt_pane" 2>/dev/null)" == "%3" ]] \
    || fail "a rejected permission must preserve the per-turn interrupt pane"
[[ "$(cat "$state_dir/@2.@code_notify_interrupt_markerfile" 2>/dev/null)" == "$interrupt_marker" ]] \
    || fail "a rejected permission must preserve the per-turn marker path"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_fp" &&
    ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a rejected permission should reset interrupt stillness state"
[[ ! -f "$interrupt_marker" ]] \
    || fail "a rejected permission should clear Antigravity's stale running cache"
dialog_grace=$(cat "$state_dir/@2.@code_notify_dialog_grace" 2>/dev/null)
[[ "$dialog_grace" == *,* ]] \
    || fail "a rejected permission should arm a queued-dialog grace generation"
[[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "a rejected permission should stop the resume poll chain"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "a rejected permission must not schedule another resume poll"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "a rejection must not resurrect a disabled agent-exit sweep"

# The retained context must be operational, not merely present: with no
# running epoch, a queued unannounced dialog should still enter the sighting
# countdown and keep the agent-exit sweep alive under the grace generation.
printf '%s' "$agy_file_dialog" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
tmux_agent_exit_sweep || fail "queued-dialog grace sweep should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_dialog_since" 2>/dev/null)" =~ ^[0-9]+$ ]] \
    || fail "a queued dialog after rejection should start a synthetic sighting"
[[ -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled" ]] \
    || fail "a queued-dialog grace should keep the agent-exit sweep alive"
rm -f "$state_dir/@2.window_activity" "$state_dir/%3.pane_content" \
    "$state_dir/%3.pane_history"
rm -f "$state_dir/@2.@code_notify_dialog_ctx" \
    "$state_dir/@2.@code_notify_dialog_since" \
    "$state_dir/@2.@code_notify_dialog_grace" \
    "$state_dir/@2.@code_notify_interrupt_pane" \
    "$state_dir/@2.@code_notify_interrupt_markerfile" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
pass "decline clears its pause while preserving an active queued-dialog watch"

# --- a stale rejection poll cannot consume a same-second successor pause ---
# Epoch seconds and a pane/count baseline can repeat across parallel asks. The
# packed pause generation must still differ, and the locked cancel helper must
# reject the older snapshot even when the pending epoch is forced identical.
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
tmux_running_start || fail "running-start before pause-generation test should succeed"
tmux_running_pause_for_input watch \
    || fail "first watched pause for generation test should succeed"
stale_pause_pending=$(cat "$state_dir/@2.@code_notify_resume_pending")
stale_pause_fp=$(cat "$state_dir/@2.@code_notify_pause_fp")
tmux_running_pause_for_input watch \
    || fail "successor watched pause for generation test should succeed"
successor_pause_fp=$(cat "$state_dir/@2.@code_notify_pause_fp")
[[ "$successor_pause_fp" != "$stale_pause_fp" ]] \
    || fail "successive pauses must mint distinct generations"
printf '%s' "$stale_pause_pending" > "$state_dir/@2.@code_notify_resume_pending"
tmux_running_cancel_input_window "@2" "$stale_pause_pending" "$stale_pause_fp" \
    && fail "a stale rejection must not cancel a same-epoch successor pause"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "$successor_pause_fp" ]] \
    || fail "the successor pause snapshot must survive a stale cancel"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_run_gen" \
    "$state_dir/@2.window_activity" "$state_dir/%3.pane_content" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
tmux_resume_flag_clear "@2"
pass "pause generations reject stale same-second cancellation"

# --- an unanswered request past the poll TTL stops the chain ---
# A dialog left open must not tick a 2s timer forever, and — even while a
# fresher pause elsewhere keeps the chain alive — an expired pause must not
# resume on late activity: the TTL gate comes before the content check. The
# marker stays for the lifecycle hooks.
printf '%s' "1000" > "$state_dir/@2.@code_notify_resume_pending"    # ancient pause
printf '%s' "%3 123 4" > "$state_dir/@2.@code_notify_pause_fp"      # snapshot mismatch
printf '%s' "$(date +%s)" > "$state_dir/@2.window_activity"         # late activity
printf '%s' "changed content" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
: > "$log_file"
tmux_resume_poll_sweep || fail "poll sweep on an expired pause should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an expired pause must not resume even on a changed snapshot"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an expired pause should keep its marker for the lifecycle hooks"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "the poll must not reschedule past TMUX_RESUME_POLL_TTL"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/@2.window_activity" "$state_dir/%3.pane_content"
pass "unanswered request past the poll TTL stops the chain"

# --- an idle-style pause must not arm the activity poll ---
# An idle reminder pauses without "watch": no turn is running, so pane
# activity after it (clicking the toast, typing the next prompt) must not
# light the spinner. UserPromptSubmit is its resume signal.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
tmux_running_start || fail "running-start before the idle-pause test should succeed"
: > "$log_file"
tmux_running_pause_for_input || fail "idle-style pause should succeed"
grep -q "^run-shell -b -d 2 " "$log_file" \
    && fail "a pause without watch must not schedule the resume poll"
[[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "a pause without watch must not record a pending poll"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "a pause without watch must not leave a dialog snapshot"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an idle-style pause should still retain the resume marker"
rm -f "$state_dir/@2.@code_notify_resume_pending" \
    "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
pass "idle-style pause keeps the marker without arming the poll"

# --- an uncapturable pane keeps only the deferred watch marker ---
# Capture is deliberately deferred until the hook UI settles. If that first
# capture fails, the poll keeps the pane-only marker and retries; it must never
# manufacture a checksum or resume the window from missing content.
rm -f "$state_dir/.@code_notify_resume_poll_scheduled" "$state_dir/%3.pane_content"
tmux_running_start || fail "running-start before the no-snapshot test should succeed"
: > "$log_file"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_pause_for_input watch \
    || fail "watched pause without a capturable pane should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,-,"* ]] \
    || fail "an uncapturable watch should retain its pane with an unknown decline baseline"
tmux_resume_poll_sweep || fail "the first uncapturable-pane poll should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,-,"* ]] \
    || fail "a failed baseline capture must not create a dialog checksum"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a failed baseline capture must not resume the running indicator"
grep -q "^run-shell -b -d 2 " "$log_file" \
    || fail "an uncapturable pane should remain watched for a later capture"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "the pause marker should still be retained for the hooks"
rm -f "$state_dir/@2.@code_notify_resume_pending" \
    "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
pass "uncapturable pane remains paused while the baseline is retried"

# --- legacy snapshots persist the rejection baseline they learn ---
# A pause written by the pre-decline format can already carry a checksum but
# no numeric decline baseline. Learning that baseline on a still tick must
# rewrite the snapshot immediately; otherwise every tick learns afresh and a
# later count can never exceed it. Disabled markers must also keep the old
# resume behavior independent of #{pane_height}.
legacy_pending=$(date +%s)
legacy_content="legacy paused dialog snapshot"
legacy_fp=$(printf '%s\n' "$legacy_content" | cksum)
printf '%s' "$legacy_content" > "$state_dir/%3.pane_content"
printf '%s' "$legacy_pending" > "$state_dir/@2.@code_notify_resume_pending"
printf '%s' "$((legacy_pending + 5))" > "$state_dir/@2.window_activity"
printf '%s' "%3,-,legacy.gen $legacy_fp 0 0" > "$state_dir/@2.@code_notify_pause_fp"
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
saved_cancel_markers="$TMUX_DIALOG_CANCEL_MARKERS"
TMUX_DIALOG_CANCEL_MARKERS=""
export FAKE_TMUX_PANE_HEIGHT=not-a-number
tmux_resume_poll_sweep || fail "legacy-baseline poll should succeed"
unset FAKE_TMUX_PANE_HEIGHT
TMUX_DIALOG_CANCEL_MARKERS="$saved_cancel_markers"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp")" == "%3,0,legacy.gen "* ]] \
    || fail "a learned legacy baseline must be persisted on a still tick"
rm -f "$state_dir/@2.@code_notify_resume_pending" \
    "$state_dir/@2.@code_notify_pause_fp" "$state_dir/@2.window_activity" \
    "$state_dir/%3.pane_content" "$state_dir/.@code_notify_resume_poll_scheduled"
pass "legacy baseline persists without a pane-height dependency"

# --- codex running marker arms the settle watch; claude's does not ---
# Codex ends /review without any turn-end hook, so its running marker gets a
# pane-settle watch (TMUX_SETTLE_AGENTS). Claude has real Stop hooks and must
# not be watched — its idle screen is static even mid-approval.
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_settle_pane" 2>/dev/null)" == "%3" ]] \
    || fail "codex prompt-submit should arm the settle watch on its pane"
tmux_running_stop || fail "running-stop after codex settle arm should succeed"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "running-stop should disarm the settle watch"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit should succeed"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "claude prompt-submit must not arm the settle watch"
tmux_running_stop || fail "running-stop after claude prompt should succeed"
pass "settle watch arms for codex only"

# The settle path calls the notifier synchronously after removing the running
# state. Keep this unit section isolated from desktop delivery; the macOS
# end-to-end section below exercises the real notifier and badge transition.
settle_notify_log="$test_dir/settle-notify.log"
cat > "$fake_bin/settle-notifier-stub" <<EOF
#!/bin/bash
running=0
[[ -f "$state_dir/@2.@code_notify_running" ]] && running=1
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "\$TMUX_PANE" "\$1" "\$2" "\$3" \
    "\${CODE_NOTIFY_TMUX_IDLE_AGENTS:-}" \
    "\$(cat "$state_dir/@2.window_name" 2>/dev/null)" "\$running" \
    "\${CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED:-}" \
    "\${CODE_NOTIFY_BADGE_ONLY:-}" \
    >> "$settle_notify_log"
EOF
chmod +x "$fake_bin/settle-notifier-stub"

# --- a settled codex pane takes the running marker down and completes ---
# Tick 1 stores the snapshot; a changed pane resets the countdown; once the
# pane holds still past the threshold (forced to 0 here), the sweep retires
# marker, restores the window name, and synthesizes the missing completion —
# the /review-without-stop case.
printf '%s' "review: analyzing diff" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the settle flow should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: running icon should be up"
tmux_agent_exit_sweep || fail "first settle tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first tick only snapshots; it must not stop the marker"
[[ -f "$state_dir/@2.@code_notify_settle_fp" ]] \
    || fail "the first tick should store the pane snapshot"
printf '%s' "review: writing findings" > "$state_dir/%3.pane_content"
tmux_agent_exit_sweep || fail "second settle tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a still-painting pane must keep the running marker"
: > "$settle_notify_log"
# The synthetic completion cannot re-resolve the agent PID (it runs in the
# sweep's process tree), so the sweep must restore the tracking it verified —
# otherwise the completion badge would outlive the agent forever.
printf '%s' "$$" > "$state_dir/@2.@code_notify_agent_pid"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
    TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "settling tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a settled pane should retire the running marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the settle stop should restore the window name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "the settle stop should disarm the watch"
[[ "$(cat "$settle_notify_log")" == "%3|stop|codex|"*"|zsh|0|1|" ]] \
    || fail "settle should invoke stop only after clearing the running rendering, with full delivery (got: $(cat "$settle_notify_log"))"
[[ "$(cat "$state_dir/@2.@code_notify_agent_pid" 2>/dev/null)" == "$$" ]] \
    || fail "the settle completion must keep the exit tracking for its badge"
rm -f "$state_dir/%3.pane_content" "$state_dir/@2.@code_notify_agent_pid"
pass "settled codex pane retires running state before synthetic completion"

# --- the interrupt watch arms for the listed agents, not for others ---
for a in claude codex antigravity; do
    CODE_NOTIFY_TMUX_AGENT_NAME=$a tmux_prompt_submit \
        || fail "$a prompt-submit for the interrupt watch should succeed"
    [[ "$(cat "$state_dir/@2.@code_notify_interrupt_pane" 2>/dev/null)" == "%3" ]] \
        || fail "$a prompt-submit should arm the interrupt watch on its pane"
    tmux_running_stop || fail "running-stop after $a interrupt arm should succeed"
done
CODE_NOTIFY_TMUX_AGENT_NAME=gemini tmux_prompt_submit \
    || fail "gemini prompt-submit should succeed"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_pane" ]] \
    || fail "an unlisted agent must not arm the interrupt watch"
tmux_running_stop || fail "running-stop after gemini prompt should succeed"
pass "interrupt watch arms for the listed agents only"

# --- each agent's real interrupt line matches; ordinary output does not ---
# Wording captured from live panes: Antigravity is a Claude Code fork and
# reuses Claude's line, Codex uses its own.
[[ "$(tmux_interrupt_flag "  ⎿  Interrupted · What should Claude do instead?")" == "1" ]] \
    || fail "claude's interrupt line should match"
[[ "$(tmux_interrupt_flag "  ⎿  Interrupted · What should Antigravity CLI do instead?")" == "1" ]] \
    || fail "antigravity's interrupt line should match"
[[ "$(tmux_interrupt_flag "■ Conversation interrupted - tell the model what to do differently.")" == "1" ]] \
    || fail "codex's interrupt line should match"
[[ "$(tmux_interrupt_flag "✻ Thinking… (4s · esc to interrupt)")" == "0" ]] \
    || fail "the working spinner's 'esc to interrupt' hint must not match"
[[ "$(tmux_interrupt_flag "the request was interrupted by a timeout")" == "0" ]] \
    || fail "prose mentioning an interruption mid-line must not match"
# The agent quoting an interrupt line out of a source file is not an interrupt.
# Claude Code prefixes tool output with line numbers, so the leading run of
# non-alphabetics must exclude digits or a Read of this very file reads as a
# cancelled turn — observed blanking a live turn's spinner for its whole run.
[[ "$(tmux_interrupt_flag "1779      \"  ⎿  Interrupted · What should Claude do instead?\"; do")" == "0" ]] \
    || fail "a line-numbered rendering of an interrupt line must not match"
[[ "$(tmux_interrupt_flag "   42→  ⎿  Interrupted · What should Claude do instead?")" == "0" ]] \
    || fail "a line-numbered read of an interrupt line must not match"
[[ "$(tmux_interrupt_flag "+  ⎿  Interrupted · What should Claude do instead?")" == "1" ]] \
    || fail "excluding digits must not disturb other leading decoration"
[[ "$(CODE_NOTIFY_TMUX_INTERRUPT_MARKERS= ; TMUX_INTERRUPT_MARKERS= ; tmux_interrupt_flag "  ⎿  Interrupted · x")" == "0" ]] \
    || fail "an empty marker set should disable detection"
pass "interrupt markers cover claude, antigravity and codex without false hits"

# --- a working pane keeps its marker; an interrupted one loses it silently ---
# The interrupt line alone is not enough: it stays rendered above the input box
# while the next turn runs, so the pane must also hold still. Once it does, the
# marker goes down with NO synthetic completion — the user pressed Escape and
# is sitting at the keyboard.
printf '%s' "✻ Thinking… (4s · esc to interrupt)" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the interrupt flow should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: running icon should be up"
tmux_agent_exit_sweep || fail "working-pane interrupt tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a working pane without an interrupt line must keep the marker"
# The quiet path (see TMUX_INTERRUPT_QUIET_SECONDS) does not start counting
# either: this pane still shows a working line, which vetoes it outright.
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a visibly working pane must not start any stillness countdown"
# Real geometry: Claude Code pins the input box to the bottom row but leaves
# the transcript where it ended, so on a short session the interrupt line sits
# near the TOP with dozens of blank rows below it. A tail-anchored match missed
# this entirely — the case that shipped a broken first cut of this watch.
{
    printf '%s\n' "❯ any performance issue in this tool?"
    printf '%s\n' "⏺ I'll look at the codebase to assess performance."
    printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?"
    for _ in $(seq 36); do printf '\n'; done
    printf '%s\n' "─────────────────────"
    printf '%s\n' "❯ "
    printf '%s\n' "  ⏸ manual mode on · ← for agents"
} > "$state_dir/%3.pane_content"
tmux_agent_exit_sweep || fail "first interrupt tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first sighting only baselines; it must not retire the marker"
[[ -f "$state_dir/@2.@code_notify_interrupt_fp" ]] \
    || fail "the first sighting should store the pane snapshot"
printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?" "(typing)" \
    > "$state_dir/%3.pane_content"
tmux_agent_exit_sweep || fail "moving-pane interrupt tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a still-repainting pane must keep the marker even with the line up"
: > "$settle_notify_log"
# Age the sighting past the stillness window instead of zeroing the threshold:
# 0 disables the watch (as it does for the dialog watch), so it cannot stand in
# for "the pane has held still long enough".
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" tmux_agent_exit_sweep \
    || fail "settled interrupt tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an interrupted still pane should retire the running marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the interrupt teardown should restore the window name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_pane" ]] \
    || fail "the interrupt teardown should disarm the watch"
[[ ! -s "$settle_notify_log" ]] \
    || fail "an interrupt must not notify (got: $(cat "$settle_notify_log"))"
pass "interrupted claude pane retires running state silently"

# --- a cancel that leaves no text behind still retires the marker ---
# Escape at a permission prompt rejects the tool AND ends the turn, and the only
# record is "[Request interrupted by user for tool use]" — which Claude Code
# renders as nothing. Claude Code also folds finished steps into an activity
# summary, hiding the tool-level "Interrupted by user" line. So the pane below
# is exactly what the user is left staring at: an ordinary transcript, an empty
# input box, and a spinner that used to run until the 4-hour TTL.
{
    printf '%s\n' "❯ can Ctrl-X be used instead of alt-x?"
    printf '%s\n' "⏺ ctrl-shift-x is unsupported by fzf outright."
    printf '%s\n' "  Made 1 scratchpad edit +26, ran 1 shell command"
    printf '%s\n' "─────────────────────"
    printf '%s\n' "❯ "
    printf '%s\n' "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
} > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the textless cancel should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: running icon should be up"
tmux_agent_exit_sweep || fail "first textless-cancel tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the first quiet sighting only baselines; it must not retire the marker"
# The quiet path must not fire on the interrupt-line threshold: the whole point
# of the longer window is the margin over a working agent's per-second repaint.
printf '%s' "$(( $(date +%s) - 10 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_agent_exit_sweep || fail "mid-quiet-window tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a line-less pane must outlast TMUX_INTERRUPT_SECONDS before retiring"
: > "$settle_notify_log"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" tmux_agent_exit_sweep \
    || fail "settled textless-cancel tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a quiet pane with no interrupt line should retire the running marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the quiet teardown should restore the window name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_pane" ]] \
    || fail "the quiet teardown should disarm the watch"
[[ ! -s "$settle_notify_log" ]] \
    || fail "a quiet teardown must not notify (got: $(cat "$settle_notify_log"))"
pass "textless cancel retires running state silently"

# --- a frozen working line vetoes the quiet path ---
# Stillness is not proof the turn ended: Claude Code's working line has been
# seen to stop repainting mid-turn, at which point a fingerprint cannot tell a
# live turn from a dead one. The line's PRESENCE is what counts, so a pane held
# artificially still with the line up must keep its indicator no matter how long
# it has been quiet.
# The verb is drawn at random from a pool shared by both states, so the match
# has to live entirely in the punctuation: an ellipsis means in flight, "<verb>
# for <duration>" with none means done. Every sample below is a real render.
for line in \
    "· Precipitating… (8m 0s · ↓ 18.0k tokens)" \
    "✶ Choreographing… (5m 14s · ↓ 15.0k tokens)" \
    "✢ Precipitating…" \
    "✻ Thinking… (4s · esc to interrupt)" \
    "✳ Saturating..." \
    "* Precipitating...."; do
    [[ "$(tmux_busy_flag "$line")" == "1" ]] \
        || fail "a working line should read as busy (got 0 for: $line)"
done
[[ "$(tmux_busy_flag "  ⎿  Running… (12s)")" == "1" ]] \
    || fail "a running tool row should read as busy"
[[ "$(tmux_busy_flag "• Working (12s • Esc to interrupt)")" == "1" ]] \
    || fail "a bullet-led working row should read as busy"
[[ "$(tmux_busy_flag "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll")" == "1" ]] \
    || fail "the transcript footer should read as busy"
[[ "$(tmux_busy_flag "  Showing detailed transcript · ctrl+o to toggle")" == "1" ]] \
    || fail "a footer with no trailing hints should read as busy"
# Deliberately NOT matched. The bullet above is a guess — no capture of a
# non-Claude working row exists — so these near-misses record the choice to keep
# the anchor strict rather than widen it speculatively: a wrong guess that never
# fires costs no more than omitting the alternative, whereas a loose one freezes
# the indicator on any sentence it collides with. Replace the bullet (and add
# cases here) when a real rendering is captured; do not widen to cover shapes
# nobody has seen.
for line in \
    "▌ Working (12s • Esc to interrupt)" \
    "● Thinking (3s · Esc to interrupt)" \
    "  Working (12s • Esc to interrupt)"; do
    [[ "$(tmux_busy_flag "$line")" == "0" ]] \
        || fail "uncaptured working-row shapes are out of scope (got 1 for: $line)"
done
# Every alternative is anchored to rendered structure, because a match on
# transcript prose does not over-match once — it pins the veto on for as long as
# the line stays on screen, which is the stuck spinner this path exists to clear.
# A veto has to be refutable by the next repaint.
for line in \
    "  Retrying… (30s)" \
    "  Retrying… (30s) before giving up" \
    "  I saw the log say Retrying… (30s) and gave up" \
    "  press esc to interrupt the run" \
    "  You can cancel (Esc to interrupt) while it runs" \
    "  The task waits (30s; Esc to interrupt) before retrying" \
    "  Showing the full transcript below" \
    "  Showing the transcript, and ctrl+o is unrelated" \
    "  Showing the menu; use ctrl+o to toggle details" \
    "  Showing detailed transcript and ctrl+o to toggle it" \
    "  ⎿  Read paste_buffer.sh (182 lines)" \
    "  ⎿  Interrupted · What should Claude do instead?"; do
    [[ "$(tmux_busy_flag "$line")" == "0" ]] \
        || fail "transcript text must not read as busy (got 1 for: $line)"
done
for line in \
    "✻ Baked for 4m 36s" \
    "✻ Churned for 14s" \
    "✻ Cogitated for 1m 43s" \
    "✻ Sautéed for 1m 8s"; do
    [[ "$(tmux_busy_flag "$line")" == "0" ]] \
        || fail "a completion line must not read as busy (got 1 for: $line)"
done
[[ "$(tmux_busy_flag "  I waited a while… (about 3 minutes) before retrying")" == "0" ]] \
    || fail "prose with an ellipsis and a parenthetical must not read as busy"
[[ "$(tmux_busy_flag "  my attempts were blocked by the sandbox…")" == "0" ]] \
    || fail "prose trailing an ellipsis must not read as busy"
# The in-progress activity summary is deliberately not matched: it opens with the
# ordinary assistant bullet, so matching it would veto on any paragraph that
# happens to trail an ellipsis, permanently.
[[ "$(tmux_busy_flag "⏺ Thinking for 5s, running 3 shell commands…")" == "0" ]] \
    || fail "the assistant bullet must not read as busy"
# Non-UTF-8 locales must not degrade a multibyte frame into loose byte matching.
[[ "$(LC_ALL=C tmux_busy_flag "✻ Churned for 14s")" == "0" ]] \
    || fail "a completion line must not read as busy under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "· Precipitating… (8m 0s)")" == "1" ]] \
    || fail "a working line should still read as busy under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "  ⎿  Running… (12s)")" == "1" ]] \
    || fail "a tool row should still read as busy under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "  Retrying… (30s)")" == "0" ]] \
    || fail "the ⎿ anchor must not degrade into byte matching under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "  The task waits (30s; Esc to interrupt) before retrying")" == "0" ]] \
    || fail "the hint anchor must hold under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "  Showing the menu; use ctrl+o to toggle details")" == "0" ]] \
    || fail "the footer anchor must hold under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "  Showing detailed transcript · ctrl+o to toggle")" == "1" ]] \
    || fail "the transcript footer should still read as busy under LC_ALL=C"
[[ "$(LC_ALL=C tmux_busy_flag "• Working (12s • Esc to interrupt)")" == "1" ]] \
    || fail "a bullet-led working row should still read as busy under LC_ALL=C"
[[ "$(tmux_busy_flag "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll")" == "1" ]] \
    || fail "the transcript view hides the working line, so it should read as busy"
[[ "$(CODE_NOTIFY_TMUX_BUSY_MARKERS= ; TMUX_BUSY_MARKERS= ; tmux_busy_flag "✻ Thinking… (4s)")" == "0" ]] \
    || fail "an empty busy-marker set should drop the veto"
{
    printf '%s\n' "❯ refactor the sweep"
    printf '%s\n' "✻ Cogitated for 1m 43s"
    printf '%s\n' "· Precipitating… (8m 0s · ↓ 18.0k tokens)"
} > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the frozen-spinner case should succeed"
tmux_agent_exit_sweep || fail "frozen-spinner tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a frozen working line must not start the quiet countdown"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "$(cat "$state_dir/%3.pane_content")" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
tmux_agent_exit_sweep || fail "aged frozen-spinner tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a pane frozen with its working line up must keep the running marker"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a busy sighting should clear any stale quiet baseline"
# The transcript view is the same story with the line invisible rather than
# frozen: still a live turn, still no teardown.
printf '%s' "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll" \
    > "$state_dir/%3.pane_content"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
tmux_agent_exit_sweep || fail "transcript-view tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a pane in the transcript view must keep the running marker"
tmux_running_stop || fail "running-stop after the frozen-spinner case should succeed"
pass "a frozen or hidden working line vetoes the quiet interrupt path"

# --- a working line vetoes the marker-text path too, not just the quiet one ---
# The observed bug: an agent editing this very file rendered a line-numbered
# "Interrupted" row into its own tool output, the pane went still in the
# transcript view, and 5s later the sweep tore down a live turn's indicator. It
# stayed dark for the rest of the turn — nothing re-lights mid-turn. The digit
# fix above stops that particular capture matching; this veto is the backstop
# for every other way an interrupt line can end up on a working pane.
{
    printf '%s\n' "❯ fix the interrupt watch"
    printf '%s\n' "⏺ Read(tests/test-tmux-badge.sh)"
    printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?"
    printf '%s\n' "✳ Cascading… (7m 6s · ↓ 8.3k tokens)"
} > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the busy-with-interrupt-line case should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: running icon should be up"
tmux_agent_exit_sweep || fail "busy-with-interrupt-line tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a working line must stop the interrupt line starting any countdown"
# Hold the pane perfectly still and age it well past TMUX_INTERRUPT_SECONDS —
# the exact conditions that fired the false teardown — then poll twice.
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "$(cat "$state_dir/%3.pane_content")" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
tmux_agent_exit_sweep || fail "aged busy-with-interrupt-line tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a pane showing work in flight must keep its marker despite an interrupt line"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_agent_exit_sweep || fail "second aged busy-with-interrupt-line tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the veto must hold across polls, not just the first"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "the live turn must keep its indicator lit (got: $(window_name))"
# The transcript view is the likeliest way a real turn goes still with the line
# up: the working row is not rendered at all, so only the busy marker for the
# view itself stands between a live turn and a teardown.
{
    printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?"
    printf '%s\n' "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll"
} > "$state_dir/%3.pane_content"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "$(cat "$state_dir/%3.pane_content")" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
tmux_agent_exit_sweep || fail "transcript-view-with-interrupt-line tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a transcript-view pane must keep its marker despite an interrupt line"
tmux_running_stop || fail "running-stop after the busy-veto case should succeed"
pass "a working line vetoes the marker-text interrupt path"

# --- an approval dialog suppresses the quiet path ---
# A pane parked on a permission prompt is as still as a cancelled one, but it is
# a pause the notification hooks own, not an ended turn: retiring here would
# drop the indicator while the agent is still mid-task, waiting on the user.
{
    printf '%s\n' "⏺ Bash(rm -rf build)"
    printf '%s\n' "  Do you want to proceed?"
    printf '%s\n' "  1. Yes"
    printf '%s\n' "  2. No, and tell Claude what to do differently"
} > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the dialog-suppression case should succeed"
tmux_agent_exit_sweep || fail "dialog-pane tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "an on-screen dialog must not start the quiet countdown"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "$(cat "$state_dir/%3.pane_content")" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
tmux_agent_exit_sweep || fail "aged dialog-pane tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a pane parked on an approval dialog must keep its running marker"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "a dialog sighting should clear any stale quiet baseline"
pass "approval dialog suppresses the quiet interrupt path"

# --- the quiet path can be switched off, leaving the marker-text watch ---
printf '%s' "an ordinary still transcript" > "$state_dir/%3.pane_content"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s\n' "an ordinary still transcript" | cksum \
    > "$state_dir/@2.@code_notify_interrupt_fp"
( TMUX_INTERRUPT_QUIET_SECONDS=0; tmux_agent_exit_sweep ) \
    || fail "quiet-path-disabled tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "quiet seconds of 0 should disable the line-less teardown"
# Turning the watch off has always meant TMUX_INTERRUPT_SECONDS=0; the quiet
# sub-path must not resurrect it for someone who set that.
( TMUX_INTERRUPT_SECONDS=0; tmux_agent_exit_sweep ) \
    || fail "watch-disabled tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "interrupt seconds of 0 should disable the quiet path too"
tmux_running_stop || fail "running-stop after the disabled-quiet case should succeed"
pass "quiet interrupt path honours a 0 threshold"

# --- the next prompt re-arms the indicator after a silent teardown ---
# The teardown must leave the window in a clean pre-turn state: nothing about
# it may stop the next UserPromptSubmit from lighting the indicator again, and
# it must not strand a queued-prompt hint for some later Stop to consume.
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "prompt-submit after an interrupt teardown should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the next prompt must re-arm the running marker"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "the next prompt must put the running indicator back (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_interrupt_pane" 2>/dev/null)" == "%3" ]] \
    || fail "the next prompt must re-arm the interrupt watch"
[[ ! -f "$state_dir/@2.@code_notify_queued_prompt" ]] \
    || fail "a teardown-then-prompt must not strand a queued-prompt hint"

# The interrupt line is STILL on screen during this new turn — it stays above
# the input box until output scrolls it away. Only the pane repainting keeps
# the watch off it, so prove a working turn survives the lingering line.
tmux_agent_exit_sweep || fail "new-turn baseline tick should succeed"
printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?" \
    "❯ do it differently" "✻ Thinking… (5s · esc to interrupt)" \
    > "$state_dir/%3.pane_content"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_agent_exit_sweep || fail "new-turn repaint tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a repainting new turn must survive the lingering interrupt line"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "the new turn must keep its running indicator (got: $(window_name))"
tmux_running_stop || fail "running-stop after the re-arm check should succeed"
pass "next prompt re-arms the indicator; a live turn survives the stale interrupt line"

# --- the teardown drops the caller's "already lit" cache (Antigravity) ---
# agy has no UserPromptSubmit: its PreInvocation is the only thing that lights
# the marker, and it skips the tmux call while its per-conversation marker file
# looks fresh. That file was sized for the 4-hour TTL, so an interrupt teardown
# that left it behind would keep the whole next turn unlit.
agy_marker="$HOME/.claude/notifications/agy/conv-test.running"
mkdir -p "$(dirname "$agy_marker")"
printf '%s' "$(date +%s)" > "$agy_marker"
printf '%s\n' "  ⎿  Interrupted · What should Antigravity CLI do instead?" \
    > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity \
    CODE_NOTIFY_TMUX_RUNNING_MARKERFILE="$agy_marker" tmux_prompt_submit \
    || fail "antigravity prompt-submit should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_interrupt_markerfile" 2>/dev/null)" == "$agy_marker" ]] \
    || fail "the arm should record the caller's marker file"
tmux_agent_exit_sweep || fail "agy interrupt baseline tick should succeed"
[[ -f "$agy_marker" ]] || fail "a baseline tick must not drop the marker file"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_agent_exit_sweep || fail "agy interrupt tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an interrupted agy pane should retire the running marker"
[[ ! -f "$agy_marker" ]] \
    || fail "the teardown must drop the marker file, or agy's next turn stays unlit"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_markerfile" ]] \
    || fail "the teardown should also drop the recorded path"

# A path outside the notification state dir is never unlinked.
outside="$test_dir/not-ours.running"
printf 'keep me' > "$outside"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity \
    CODE_NOTIFY_TMUX_RUNNING_MARKERFILE="$outside" tmux_prompt_submit \
    || fail "antigravity prompt-submit with a foreign path should succeed"
tmux_agent_exit_sweep || fail "foreign-path baseline tick should succeed"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_agent_exit_sweep || fail "foreign-path interrupt tick should succeed"
[[ -f "$outside" ]] \
    || fail "the teardown must never unlink outside the notification state dir"
rm -f "$outside" "$state_dir/%3.pane_content"
pass "interrupt teardown drops agy's lit-cache so its next turn re-arms"

# --- a codex interrupt pre-empts the settle watch's synthetic completion ---
# Codex arms both watches. Before this, an Escape reached the user as "Codex is
# done" (settle's synthetic completion) and then an idle nudge a minute later.
# The interrupt watch must win and end the turn silently; the settle path stays
# intact for a stall with no interrupt line (covered by the test above).
printf '%s\n' "■ Conversation interrupted - tell the model what to do differently." \
    > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the interrupt flow should succeed"
[[ -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "precondition: codex should still arm its settle watch"
tmux_agent_exit_sweep || fail "codex interrupt baseline tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the codex baseline tick must not retire the marker"
: > "$settle_notify_log"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" tmux_agent_exit_sweep \
    || fail "codex interrupt tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an interrupted codex pane should retire the running marker"
[[ ! -s "$settle_notify_log" ]] \
    || fail "a codex interrupt must not synthesize a completion (got: $(cat "$settle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "the interrupt teardown should disarm the settle watch too"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a silent interrupt teardown must not arm the idle nudge"
pass "codex interrupt pre-empts the settle completion and the idle nudge"

# --- ...and still pre-empts it when the pane also trips a busy marker ---
# The busy veto must not hand a Codex interrupt back to the settle watch. Settle
# has no busy veto of its own and fires purely on stillness, so a vetoed
# interrupt would fall straight through to it and reach the user as exactly the
# "Codex is done" completion plus idle nudge this watch exists to suppress. A
# bullet row is enough to trip TMUX_BUSY_MARKERS and Codex transcripts are full
# of them, so this is an ordinary interrupt screen, not a contrived one.
{
    printf '%s\n' "· Reviewing the diff…"
    printf '%s\n' "■ Conversation interrupted - tell the model what to do differently."
} > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the busy-vetoed interrupt should succeed"
[[ -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "precondition: codex should still arm its settle watch"
tmux_agent_exit_sweep || fail "busy-vetoed codex baseline tick should succeed"
: > "$settle_notify_log"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_settle_since"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" tmux_agent_exit_sweep \
    || fail "busy-vetoed codex interrupt tick should succeed"
[[ ! -s "$settle_notify_log" ]] \
    || fail "a busy-vetoed codex interrupt must not synthesize a completion (got: $(cat "$settle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a busy-vetoed codex interrupt must not arm the idle nudge"
tmux_running_stop || fail "running-stop after the busy-vetoed codex case should succeed"
pass "a busy-vetoed codex interrupt does not fall through to the settle completion"

# --- ...but the same busy row alone does NOT cost a stall its completion ---
# The counterpart to the case above, and the reason the suppression keys on the
# interrupt line rather than on the busy flag: a hook-less Codex stall is
# exactly what settle exists to notify, and its transcript may well end on a
# bullet row. Vetoing settle on the busy flag alone would silently swallow that
# completion — a worse failure than the one being fixed.
printf '%s\n' "· Reviewing the diff…" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the busy-row stall should succeed"
tmux_agent_exit_sweep || fail "busy-row stall baseline tick should succeed"
: > "$settle_notify_log"
printf '%s' "$(( $(date +%s) - 600 ))" > "$state_dir/@2.@code_notify_settle_since"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" tmux_agent_exit_sweep \
    || fail "busy-row stall settle tick should succeed"
[[ -s "$settle_notify_log" ]] \
    || fail "a stall with no interrupt line must still synthesize its completion"
pass "a busy row alone does not suppress the codex settle completion"

# --- a preserved stop's badge-only settle watch outranks the interrupt watch ---
# That stop withheld its terminal badge for the settle reconcile to apply; a
# silent interrupt teardown would drop the badge entirely.
printf '%s' "  ⎿  Interrupted · What should Claude do instead?" \
    > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the preserve precedence should succeed"
tmux_agent_exit_sweep || fail "preserve-precedence baseline tick should succeed"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
printf '1' > "$state_dir/@2.@code_notify_settle_badge_only"
tmux_agent_exit_sweep || fail "preserve-precedence tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a badge-only settle preserve must keep the interrupt watch off its marker"
rm -f "$state_dir/@2.@code_notify_settle_badge_only"
tmux_running_stop || fail "running-stop after the preserve precedence should succeed"
rm -f "$state_dir/%3.pane_content"
pass "badge-only settle preserve outranks the interrupt watch"

# --- a preserve landing mid-sweep also outranks the interrupt watch ---
# The badge-only value the sweep reads from list-windows is only a pre-filter.
# tmux_running_stop's queued-prompt path returns BEFORE unsetting
# @code_notify_running, so a preserve landing after the snapshot leaves the
# teardown's epoch check passing — only a lock-time re-read of the flag keeps
# the badge that Stop withheld alive.
printf '%s' "  ⎿  Interrupted · What should Claude do instead?" \
    > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the preserve race should succeed"
tmux_agent_exit_sweep || fail "preserve-race baseline tick should succeed"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
interrupt_race_marker="$test_dir/interrupt-race-fired"
FAKE_TMUX_INTERRUPT_RACE_MARKER="$interrupt_race_marker" tmux_agent_exit_sweep \
    || fail "preserve-race tick should succeed"
[[ -e "$interrupt_race_marker" ]] \
    || fail "precondition: the injected preserve should have fired"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "a preserve landing after the snapshot must still keep the interrupt watch off its marker"
rm -f "$state_dir/@2.@code_notify_settle_badge_only" "$interrupt_race_marker"
tmux_running_stop || fail "running-stop after the preserve race should succeed"
rm -f "$state_dir/%3.pane_content"
pass "a preserve landing mid-sweep outranks the interrupt watch"

# --- resuming from an approval clears the interrupt stillness baseline ---
# Answering an approval emits no hook, so the resume poll relights the marker
# through tmux_running_resume_window rather than tmux_running_start — nothing
# on that path re-arms the watch. A sighting recorded before the pause is
# always older than the threshold by the time anyone answers, so carrying it
# into the resumed turn leaves it one matching capture from a silent teardown.
printf '%s\n' "  ⎿  Interrupted · What should Claude do instead?" "working" \
    > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit before the approval pause should succeed"
tmux_agent_exit_sweep || fail "pre-pause interrupt baseline tick should succeed"
[[ -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "precondition: the pre-pause tick should baseline the watch"
printf '%s' "$(( $(date +%s) - 60 ))" > "$state_dir/@2.@code_notify_interrupt_since"
tmux_running_pause_for_input watch || fail "approval pause should succeed"
tmux_running_resume_window "@2" || fail "resume-window should succeed"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_since" ]] \
    || fail "the resume must not carry a pre-pause sighting into the resumed turn"
[[ ! -f "$state_dir/@2.@code_notify_interrupt_fp" ]] \
    || fail "the resume must drop the pre-pause pane fingerprint too"
# The resumed turn has to survive a tick with the interrupt line still up and
# the pane not yet repainted — that is exactly the frame the stale baseline
# would have torn down.
tmux_agent_exit_sweep || fail "post-resume interrupt tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the resumed turn must keep its marker instead of tearing down on the first tick"
tmux_running_stop || fail "running-stop after the resume check should succeed"
rm -f "$state_dir/%3.pane_content" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
pass "resume clears the interrupt baseline so the resumed turn counts afresh"

# --- a prompt racing settled-review teardown keeps the new run intact ---
# Mutate the epoch immediately after the sweep's pre-lock settle read, exactly
# where the old implementation could tear down a prompt that had just started.
printf '%s' "review: stable" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "codex prompt-submit for the settle race should succeed"
tmux_agent_exit_sweep || fail "settle-race baseline tick should succeed"
old_settle_epoch=$(cat "$state_dir/@2.@code_notify_running")
new_settle_epoch=$((old_settle_epoch + 1))
settle_race_marker="$test_dir/settle-race-fired"
: > "$settle_notify_log"
FAKE_TMUX_SETTLE_RACE_MARKER="$settle_race_marker" \
FAKE_TMUX_SETTLE_RACE_EPOCH="$new_settle_epoch" \
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "settle teardown racing a new prompt should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_running")" == "$new_settle_epoch" ]] \
    || fail "settle teardown must not remove a prompt that started after its snapshot"
[[ -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "settle teardown must keep the new prompt's watch"
[[ ! -s "$settle_notify_log" ]] \
    || fail "a superseded settle snapshot must not synthesize completion"
tmux_running_stop || fail "settle-race cleanup should succeed"
rm -f "$state_dir/%3.pane_content" "$settle_race_marker"
pass "settled-review teardown preserves a concurrently started prompt"

# --- scheduled settle completion preserves idle configuration ---
# The synthetic stop runs inside the timer's fresh process and arms its idle
# watch there, so the originating session's allowlist must ride the payload.
settle_handoff_round() {
    # $1: env value for TMUX_IDLE_AGENTS ("" = default). Arms a codex settle
    # watch, seeds it as already settled, then runs the scheduled payload
    # exactly as tmux would (fresh /bin/sh, no TMUX_PANE).
    printf '%s' "review output" > "$state_dir/%3.pane_content"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$log_file"
    : > "$settle_notify_log"
    if [[ -n "$1" ]]; then
        CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
            TMUX_IDLE_AGENTS="$1" CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
            || return 1
    else
        CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
            CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit || return 1
    fi
    printf '%s' "$(printf '%s\n' "review output" | cksum)" \
        > "$state_dir/@2.@code_notify_settle_fp"
    printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
    payload=$(sed -n 's/^run-shell -b -d 5 \(.*\)$/\1/p' "$log_file" | head -n 1)
    [[ -n "$payload" ]] || return 1
    env -u TMUX_PANE /bin/sh -c "$payload"
}
settle_handoff_round "" || fail "default-allowlist handoff round should run cleanly"
[[ "$(cat "$settle_notify_log")" == *"|codex|antigravity|zsh|0|1|" ]] \
    || fail "scheduled completion should inherit the default idle allowlist (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
settle_handoff_round "antigravity" || fail "override-allowlist handoff round should run cleanly"
[[ "$payload" == *"CODE_NOTIFY_TMUX_IDLE_AGENTS='antigravity'"* ]] \
    || fail "the scheduled payload should carry the session's allowlist"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the scheduled settle stop should still retire the running marker"
[[ "$(cat "$settle_notify_log")" == *"|antigravity|zsh|0|1|" ]] \
    || fail "synthetic completion should receive the overridden idle allowlist (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content" "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
printf '%s' "zsh" > "$state_dir/@2.window_name"
pass "scheduled synthetic completion preserves idle configuration"

# --- idle watch: arm gating (agent list, alert types, pane capture) ---
# Codex/Antigravity never send an idle reminder after a completion, so their
# stop events arm a post-completion idle watch; Claude nudges natively and
# must not be watched. The nudge is an alert type (idle_prompt), so the arm
# also honours the notify-types file, and an uncapturable pane never arms.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "idle arm for codex should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == "%3 "* ]] || fail "idle arm should record the watched pane (got: $iw)"
[[ "$iw" == *" codex projX" ]] \
    || fail "idle arm should record agent and project (got: $iw)"
rm -f "$state_dir/@2.@code_notify_idle_watch"
tmux_idle_watch_arm_current antigravity projX || fail "idle arm for antigravity should succeed"
[[ "$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)" == *" antigravity projX" ]] \
    || fail "antigravity (agy StopFinal path) should arm the idle watch too"
rm -f "$state_dir/@2.@code_notify_idle_watch"
tmux_idle_watch_arm_current claude projX || fail "idle arm for claude should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "claude must not get an idle watch (it has a native idle_prompt)"
mkdir -p "$HOME/.claude/notifications"
printf '%s' "permission_prompt" > "$HOME/.claude/notifications/notify-types"
tmux_idle_watch_arm_current codex projX \
    || fail "idle arm with idle_prompt disabled should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a disabled idle_prompt alert type must not arm the idle watch"
rm -f "$HOME/.claude/notifications/notify-types" "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX \
    || fail "idle arm without a capturable pane should no-op cleanly"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "an uncapturable pane must not arm the idle watch"
pass "idle watch arms for hook-less agents only, gated on alert type and capture"

# --- idle watch: sweep lifecycle (settling / young / fired / changed / vanished) ---
# The stub notifier logs its identity-bearing invocation; delivery is
# detached, so assertions on the log wait briefly.
idle_notify_log="$test_dir/idle-notify.log"
cat > "$fake_bin/notifier-stub" <<EOF
#!/bin/bash
printf '%s|%s|%s|%s|' "\$TMUX_PANE" "\$1" "\$2" "\$3" >> "$idle_notify_log"
cat >> "$idle_notify_log"
printf '\n' >> "$idle_notify_log"
EOF
chmod +x "$fake_bin/notifier-stub"
wait_for_idle_log() {
    local i
    for i in $(seq 1 50); do
        [[ -s "$idle_notify_log" ]] && return 0
        sleep 0.1
    done
    return 1
}
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "idle arm for the sweep tests should succeed"
# Codex repaints after Stop returns. The first changed snapshot must become the
# new settling baseline instead of cancelling the reminder.
printf '%s' "codex final frame" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "first settling sweep should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == *" settling codex projX" ]] \
    || fail "Codex's final repaint should refresh the settling baseline (got: $iw)"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "second settling sweep should succeed"
iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
[[ "$iw" == *" stable codex projX" ]] \
    || fail "two matching snapshots should stabilize the idle watch (got: $iw)"
pass "codex final repaint settles instead of cancelling the idle watch"

rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep with a young idle watch should succeed"
[[ -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a young idle watch must survive the tick"
[[ ! -s "$idle_notify_log" ]] || fail "a young idle watch must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    || fail "an armed idle watch should keep the sweep chain alive"
pass "young idle watch keeps the sweep ticking without notifying"

# Stillness past the threshold fires the synthetic idle_prompt once, with the
# watched pane in TMUX_PANE and the recorded identity in argv, then consumes
# the watch and lets the chain die.
idle_fp="$(printf '%s\n' "codex final frame" | cksum)"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "idle-firing sweep should succeed"
wait_for_idle_log || fail "stillness past the threshold should invoke the notifier"
[[ "$(cat "$idle_notify_log")" == '%3|notification|codex|projX|{"type":"idle_prompt"}' ]] \
    || fail "the synthetic nudge should carry pane, event, agent, project and payload (got: $(cat "$idle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "the fired idle watch should be consumed"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "the sweep chain must die once nothing is watched"
pass "stillness past the threshold fires the synthetic idle nudge once"

# A content change means the user is already there: disarm silently, even
# past the threshold.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "re-arm for the change test should succeed"
idle_fp="$(printf '%s\n' "turn finished, waiting" | cksum)"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
printf '%s' "user typed something" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep after a content change should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "changed content should disarm the idle watch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "changed content must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "a disarmed idle watch must not keep the chain alive"
pass "content change disarms the idle watch without notifying"

# A vanished pane disarms silently too — after a completed turn there is no
# recovery path worth keeping open, and cksum-of-empty must not read as a
# stable pane.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "re-arm for the vanish test should succeed"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
rm -f "$state_dir/%3.pane_content"   # the watched split was closed
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep with a vanished idle pane should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "a vanished pane should disarm the idle watch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "a vanished pane must not notify"
pass "vanished pane disarms the idle watch silently"

# --- approval-dialog watch: arm gating (agent list, alert type) ---
# Antigravity's hooks announce no pause for file-write or subagent approvals,
# so its running start arms a dialog watch; Claude's native Notification hook
# covers every dialog, so claiming the window must clear a leftover context
# instead of watching under a stale identity. The synthetic alert is the
# permission_prompt type, so the arm honours the notify-types file.
mkdir -p "$HOME/.claude/notifications"
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_start \
    || fail "antigravity running-start should succeed"
dc="$(cat "$state_dir/@2.@code_notify_dialog_ctx" 2>/dev/null)"
[[ "$dc" == "%3 antigravity $(basename "$PWD")" ]] \
    || fail "antigravity running-start should arm the dialog watch (got: $dc)"
tmux_running_stop || fail "running-stop after dialog arm should succeed"
[[ -f "$state_dir/@2.@code_notify_dialog_ctx" ]] \
    || fail "the dialog context must survive a stop (agy skips running-start after a pause)"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit should succeed"
[[ ! -f "$state_dir/@2.@code_notify_dialog_ctx" ]] \
    || fail "claude claiming the window must clear the leftover dialog context"
tmux_running_stop || fail "running-stop after claude prompt should succeed"
printf '%s' "idle_prompt" > "$HOME/.claude/notifications/notify-types"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_start \
    || fail "running-start with permission_prompt disabled should succeed"
[[ ! -f "$state_dir/@2.@code_notify_dialog_ctx" ]] \
    || fail "a disabled permission_prompt alert type must not arm the dialog watch"
tmux_running_stop || fail "running-stop after the disabled-arm check should succeed"
pass "dialog watch arms for antigravity only, gated on alert type"

# --- approval-dialog watch: sweep fires one synthetic permission_prompt ---
# The first sighting only records the epoch; stillness of the dialog past the
# threshold fires the synthetic alert once, with the watched pane in
# TMUX_PANE and the recorded identity in argv, then consumes the sighting.
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_start \
    || fail "antigravity running-start for the sweep tests should succeed"
printf '%s' "$agy_file_dialog" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "first dialog sighting sweep should succeed"
[[ -f "$state_dir/@2.@code_notify_dialog_since" ]] \
    || fail "the first sighting should record its epoch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "the first sighting must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    || fail "an active dialog watch should keep the sweep chain alive"
printf '%s' "$(( $(date +%s) - TMUX_DIALOG_NOTIFY_SECONDS - 1 ))" \
    > "$state_dir/@2.@code_notify_dialog_since"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "dialog-firing sweep should succeed"
wait_for_idle_log || fail "a dialog past the threshold should invoke the notifier"
[[ "$(cat "$idle_notify_log")" == '%3|notification|antigravity|'"$(basename "$PWD")"'|{"type":"permission_prompt"}' ]] \
    || fail "the synthetic approval should carry pane, event, agent, project and payload (got: $(cat "$idle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_dialog_since" ]] \
    || fail "the fired sighting epoch should be consumed"
pass "dialog on screen past the threshold fires the synthetic approval once"

# --- approval-dialog watch: an answer before the threshold resets silently ---
printf '%s' "$(date +%s)" > "$state_dir/@2.@code_notify_dialog_since"
printf '%s' "generating code ..." > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep after an early answer should succeed"
[[ ! -f "$state_dir/@2.@code_notify_dialog_since" ]] \
    || fail "an answered dialog should reset the sighting epoch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "an answered dialog must not notify"
pass "dialog answered before the threshold resets the watch silently"

# --- approval-dialog watch: no running marker means no sighting ---
# After the synthetic alert's own pause (or any stop), the marker is gone;
# the same waiting dialog must not re-fire on later ticks.
printf '%s' "$agy_file_dialog" > "$state_dir/%3.pane_content"
tmux_running_stop || fail "running-stop before the paused-window check should succeed"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$idle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_sweep \
    || fail "sweep on a paused window should succeed"
[[ ! -f "$state_dir/@2.@code_notify_dialog_since" ]] \
    || fail "a window without a fresh running marker must not track sightings"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "a paused window must not re-notify for the same dialog"
rm -f "$state_dir/%3.pane_content" "$state_dir/@2.@code_notify_dialog_ctx" \
    "$HOME/.claude/notifications/notify-types" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
pass "dialog watch goes inert once the running marker is down"

# --- every start mints a run generation the epoch cannot provide ---
# @code_notify_running is a 1-second epoch, so two turns inside one second are
# indistinguishable by it — and these hooks fire well inside a second of each
# other. The generation is what makes "still the run I saw" answerable.
rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_run_gen"
tmux_running_start || fail "running-start for the generation test should succeed"
gen_one="$(cat "$state_dir/@2.@code_notify_run_gen" 2>/dev/null)"
[[ -n "$gen_one" ]] || fail "running-start should mint a run generation"
tmux_running_stop || fail "running-stop for the generation test should succeed"
[[ ! -f "$state_dir/@2.@code_notify_run_gen" ]] \
    || fail "a stop should retire the generation with the marker"
tmux_prompt_submit || fail "prompt-submit for the generation test should succeed"
gen_two="$(cat "$state_dir/@2.@code_notify_run_gen" 2>/dev/null)"
[[ -n "$gen_two" ]] || fail "prompt-submit should mint a run generation"
[[ "$gen_two" != "$gen_one" ]] \
    || fail "a second turn must not reuse the previous generation"
tmux_running_stop || fail "second running-stop for the generation test should succeed"
tmux_running_resume_window "@2" || fail "resume-window for the generation test should succeed"
gen_three="$(cat "$state_dir/@2.@code_notify_run_gen" 2>/dev/null)"
[[ -n "$gen_three" ]] && [[ "$gen_three" != "$gen_two" ]] \
    || fail "a poll resume should mint its own generation (got: $gen_three)"
tmux_running_stop || fail "cleanup stop for the generation test should succeed"
pass "each turn start mints a fresh run generation"

# --- the synthetic-run guard rejects a world that moved on ---
# A watch sweep validates a window, forks a notifier and disowns it; the child
# only reaches delivery tens of milliseconds later. Everything it was scheduled
# against must still hold, or the user's answer has already resumed the turn
# and the child would tear that fresh run down.
tmux_synthetic_guard_ok || fail "no guard window means no guard: a real hook must proceed"
printf '%s' "$(date +%s)" > "$state_dir/@2.@code_notify_running"
printf '%s' "gen-A" > "$state_dir/@2.@code_notify_run_gen"
guard_run="$(cat "$state_dir/@2.@code_notify_running")"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$guard_run" \
    CODE_NOTIFY_TMUX_GUARD_GEN="gen-A" tmux_synthetic_guard_ok \
    || fail "an unchanged run must pass the guard"
printf '%s' "gen-B" > "$state_dir/@2.@code_notify_run_gen"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$guard_run" \
    CODE_NOTIFY_TMUX_GUARD_GEN="gen-A" tmux_synthetic_guard_ok \
    && fail "REGRESSION: a same-second successor turn must fail the guard"
printf '%s' "gen-A" > "$state_dir/@2.@code_notify_run_gen"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$(( guard_run - 5 ))" \
    CODE_NOTIFY_TMUX_GUARD_GEN="gen-A" tmux_synthetic_guard_ok \
    && fail "a different running epoch must fail the guard"
# An empty expected run is the post-completion idle nudge: it was scheduled
# against a window with no live turn, and any turn since owns the window.
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" tmux_synthetic_guard_ok \
    && fail "REGRESSION: a turn started since the fork must cancel the idle nudge"
rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_run_gen"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" tmux_synthetic_guard_ok \
    || fail "a still-idle window must let the idle nudge through"
guard_grace_expiry="$(( $(date +%s) + 60 ))"
printf '%s' "$guard_grace_expiry,grace-A" > "$state_dir/@2.@code_notify_dialog_grace"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" \
    CODE_NOTIFY_TMUX_GUARD_DIALOG_GRACE="$guard_grace_expiry,grace-A" \
    tmux_synthetic_guard_ok \
    || fail "an unchanged queued-dialog grace must pass the guard"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" \
    CODE_NOTIFY_TMUX_GUARD_DIALOG_GRACE="$guard_grace_expiry,grace-stale" \
    tmux_synthetic_guard_ok \
    && fail "a replaced queued-dialog grace must fail the guard"
rm -f "$state_dir/@2.@code_notify_dialog_grace"
printf '%s' "$(( $(date +%s) - TMUX_RUNNING_TTL - 1 ))" > "$state_dir/@2.@code_notify_running"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" tmux_synthetic_guard_ok \
    || fail "a stale epoch is not a live turn and must not cancel the nudge"
rm -f "$state_dir/@2.@code_notify_running"
pass "synthetic-run guard admits the validated world and rejects a moved one"

# --- both watches hand their child what they validated ---
# Without this the child has no way to ask the question at all: it inherits the
# pane and the agent name, and nothing that identifies the run.
guard_env_log="$test_dir/guard-env.log"
cat > "$fake_bin/guard-notifier-stub" <<EOF
#!/bin/bash
printf '%s|%s|%s\n' "\$CODE_NOTIFY_TMUX_GUARD_WINDOW" "\$CODE_NOTIFY_TMUX_GUARD_RUN" \
    "\$CODE_NOTIFY_TMUX_GUARD_GEN" >> "$guard_env_log"
EOF
chmod +x "$fake_bin/guard-notifier-stub"
wait_for_guard_log() {
    local i
    for i in $(seq 1 50); do
        [[ -s "$guard_env_log" ]] && return 0
        sleep 0.1
    done
    return 1
}
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
: > "$guard_env_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/guard-notifier-stub" \
    tmux_dialog_watch_notify "%3" antigravity projX "@2" "1700000000" "gen-A" \
    || fail "dialog watch notify should succeed"
wait_for_guard_log || fail "the dialog watch should invoke the notifier"
[[ "$(cat "$guard_env_log")" == "@2|1700000000|gen-A" ]] \
    || fail "the dialog child should carry window, epoch and generation (got: $(cat "$guard_env_log"))"
: > "$guard_env_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/guard-notifier-stub" \
    tmux_idle_watch_notify "%3" codex projX "@2" \
    || fail "idle watch notify should succeed"
wait_for_guard_log || fail "the idle watch should invoke the notifier"
[[ "$(cat "$guard_env_log")" == "@2||" ]] \
    || fail "the idle child should carry its window and no expected run (got: $(cat "$guard_env_log"))"
rm -f "$HOME/.claude/notifications/notify-types"
pass "detached watch children carry the state their sweep validated"

# --- the sighting is validated against the snapshot, not against itself ---
# The generation the child checks must be the one the dialog was SEEN under.
# Re-reading it at spawn time would be circular: a successor starting in the
# same second leaves the epoch byte-identical, so the sweep would hand the
# child the successor's own generation and the child would dutifully confirm
# it — delivering a stale approval against a turn that never had a dialog.
for opt_name in @code_notify_running @code_notify_run_gen @code_notify_dialog_ctx \
    @code_notify_dialog_since @code_notify_dialog_grace; do
    rm -f "$state_dir/@2.$opt_name"
done
printf '%s' "idle_prompt|permission_prompt" > "$HOME/.claude/notifications/notify-types"
CODE_NOTIFY_TMUX_AGENT_NAME=antigravity tmux_running_start \
    || fail "running-start for the same-second successor test should succeed"
printf '%s' "$agy_file_dialog" > "$state_dir/%3.pane_content"
printf '%s' "$(( $(date +%s) - TMUX_DIALOG_NOTIFY_SECONDS - 1 ))" \
    > "$state_dir/@2.@code_notify_dialog_since"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$guard_env_log"
gen_race_marker="$test_dir/dialog-gen-race"
rm -f "$gen_race_marker"
FAKE_TMUX_GEN_RACE_MARKER="$gen_race_marker" \
    CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/guard-notifier-stub" tmux_agent_exit_sweep \
    || fail "a sweep racing a same-second successor should succeed"
[[ -e "$gen_race_marker" ]] \
    || fail "precondition: the same-second successor race should have fired"
sleep 0.3
[[ ! -s "$guard_env_log" ]] \
    || fail "REGRESSION: a same-second successor was handed its own generation (got: $(cat "$guard_env_log"))"
# The control: unraced, the sighting fires and carries the snapshot pair.
printf '%s' "$(( $(date +%s) - TMUX_DIALOG_NOTIFY_SECONDS - 1 ))" \
    > "$state_dir/@2.@code_notify_dialog_since"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$guard_env_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/guard-notifier-stub" tmux_agent_exit_sweep \
    || fail "an unraced dialog sweep should succeed"
wait_for_guard_log || fail "an unraced sighting should invoke the notifier"
[[ "$(cat "$guard_env_log")" == "@2|$(cat "$state_dir/@2.@code_notify_running")|$(cat "$state_dir/@2.@code_notify_run_gen")" ]] \
    || fail "the child should carry the observed run pair (got: $(cat "$guard_env_log"))"
tmux_running_stop || fail "cleanup stop for the same-second successor test should succeed"
rm -f "$state_dir/@2.@code_notify_dialog_ctx" "$state_dir/@2.@code_notify_dialog_since" \
    "$state_dir/@2.@code_notify_dialog_grace" \
    "$state_dir/%3.pane_content" "$HOME/.claude/notifications/notify-types" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled" "$gen_race_marker"
pass "a same-second successor cancels the sighting instead of relabelling it"

# --- the guard is re-asked under the lock, not just at start-up ---
# A whole notifier run separates the start-up guard from the state change it
# protects, and the user can answer the dialog anywhere in it. The teardown
# must therefore re-ask under the transition lock — where nothing can move
# between the answer and the mutation — and reject there.
for opt_name in @code_notify_running @code_notify_run_gen @code_notify_resume_pending \
    @code_notify_pause_fp; do
    rm -f "$state_dir/@2.$opt_name"
done
tmux_running_start || fail "running-start for the locked-guard test should succeed"
locked_epoch="$(cat "$state_dir/@2.@code_notify_running")"
locked_gen="$(cat "$state_dir/@2.@code_notify_run_gen")"
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$locked_epoch" \
    CODE_NOTIFY_TMUX_GUARD_GEN="stale-generation" \
    tmux_running_pause_for_input watch \
    || fail "a rejected guarded pause should still succeed"
[[ "${TMUX_RUNNING_GUARD_REJECTED:-0}" == "1" ]] \
    || fail "the locked re-check should report its rejection to the notifier"
[[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" == "$locked_epoch" ]] \
    || fail "REGRESSION: a rejected guarded child tore down the run it did not own"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "REGRESSION: a rejected guarded child parked a pause on someone else's turn"
# A guard naming another window is not this window's business either.
CODE_NOTIFY_TMUX_GUARD_WINDOW="@9" CODE_NOTIFY_TMUX_GUARD_RUN="$locked_epoch" \
    CODE_NOTIFY_TMUX_GUARD_GEN="$locked_gen" tmux_running_stop \
    || fail "a foreign-window guarded stop should succeed"
[[ "${TMUX_RUNNING_GUARD_REJECTED:-0}" == "1" ]] \
    || fail "a guard naming another window must fail closed"
[[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" == "$locked_epoch" ]] \
    || fail "a guard naming another window must not touch this one"
# The control: the guard still holding lets the pause through, and an
# unguarded hook is never affected by any of this.
CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$locked_epoch" \
    CODE_NOTIFY_TMUX_GUARD_GEN="$locked_gen" tmux_running_pause_for_input watch \
    || fail "an in-date guarded pause should succeed"
[[ "${TMUX_RUNNING_GUARD_REJECTED:-0}" == "0" ]] \
    || fail "an in-date guard must not report a rejection"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an in-date guarded child should retire the run it owns"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an in-date guarded child should park its pause"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled"
tmux_resume_flag_clear "@2"
tmux_running_start || fail "running-start for the unguarded control should succeed"
tmux_running_pause_for_input || fail "an unguarded pause should succeed"
[[ "${TMUX_RUNNING_GUARD_REJECTED:-0}" == "0" ]] \
    || fail "an unguarded hook must never be rejected"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an unguarded pause should park its wait"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp"
tmux_resume_flag_clear "@2"
pass "the synthetic guard is re-checked under the transition lock"

# --- an input pause must not resurrect state a successor turn cleared ---
# tmux_running_stop releases the transition lock before returning, so a queued
# prompt can claim the window before the pause writes its metadata. Unlocked,
# those writes land on the successor's live turn: a running window carrying a
# pending pause, and a resume poll watching a pane nothing is waiting on.
for opt_name in @code_notify_running @code_notify_run_gen @code_notify_resume_pending \
    @code_notify_pause_fp @code_notify_queued_prompt; do
    rm -f "$state_dir/@2.$opt_name"
done
printf '%s' "approval dialog" > "$state_dir/%3.pane_content"
rm -f "$state_dir/.@code_notify_resume_poll_scheduled"
tmux_running_start || fail "running-start before the pause race should succeed"
successor_marker="$test_dir/pause-successor-race"
rm -f "$successor_marker"
FAKE_TMUX_SUCCESSOR_RACE_MARKER="$successor_marker" \
    FAKE_TMUX_SUCCESSOR_RACE_EPOCH="$(date +%s)" \
    tmux_running_pause_for_input watch \
    || fail "a pause overtaken by a successor should still succeed"
[[ -e "$successor_marker" ]] || fail "precondition: the successor race should have fired"
[[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" =~ ^[0-9]+$ ]] \
    || fail "REGRESSION: the pause must leave the successor turn's marker alone"
[[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "REGRESSION: the pause must not park a wait on a live successor turn"
[[ ! -f "$state_dir/@2.@code_notify_pause_fp" ]] \
    || fail "REGRESSION: the pause must not arm a resume watch on a live successor turn"
[[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "REGRESSION: an overtaken pause must not schedule the resume poll"
[[ ! -e "$(tmux_resume_flag_path "@2")" ]] \
    || fail "REGRESSION: an overtaken pause must not leave a resume flag file"
# The control: with no successor, the identical call parks the whole pause.
rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_run_gen"
tmux_running_start || fail "running-start before the pause control should succeed"
tmux_running_pause_for_input watch || fail "an unraced pause should succeed"
[[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
    || fail "an unraced pause should park the wait"
[[ "$(cat "$state_dir/@2.@code_notify_pause_fp" 2>/dev/null)" == "%3,0,"* ]] \
    || fail "an unraced pause should record the watched pane"
[[ -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
    || fail "an unraced watched pause should schedule the resume poll"
rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_pause_fp" \
    "$state_dir/.@code_notify_resume_poll_scheduled" "$state_dir/%3.pane_content" \
    "$successor_marker"
tmux_resume_flag_clear "@2"
pass "an overtaken input pause leaves the successor turn intact"

# --- a preserved queued-prompt hint self-heals when no successor runs ---
# A FALSE hint (a marker lingering from an interrupted turn, which emits no
# Stop) makes a claude turn's only Stop consume the hint and preserve the
# marker, with no successor to clear it. The preserve arms a settle watch even
# though claude is not a TMUX_SETTLE_AGENT; once the pane proves idle the
# sweep retires the marker and applies the badge the preserve withheld. The
# reconcile must be badge-only (CODE_NOTIFY_BADGE_ONLY=1): the preserving
# Stop already delivered the completion toast — only the badge was gated —
# unlike the codex sections above, where no Stop fired at all and the
# synthetic run is the only notification.
for opt_name in @code_notify_running @code_notify_queued_prompt \
    @code_notify_settle_pane @code_notify_settle_ctx @code_notify_settle_fp \
    @code_notify_settle_since @code_notify_idle_watch @code_notify_clear_mode \
    @code_notify_orig_name @code_notify_badged_name @code_notify_autorename \
    @code_notify_agent_pid; do
    rm -f "$state_dir/@2.$opt_name"
done
printf '%s' "zsh" > "$state_dir/@2.window_name"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "claude prompt-submit for the preserve flow should succeed"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_prompt_submit \
    || fail "second claude prompt-submit (queued) should succeed"
[[ -f "$state_dir/@2.@code_notify_queued_prompt" ]] \
    || fail "precondition: a submission over a live marker leaves a hint"
CODE_NOTIFY_TMUX_AGENT_NAME=claude tmux_running_stop consume-queued-prompt \
    || fail "preserving stop should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "preserve must keep the running marker for a possible successor"
[[ "$(cat "$state_dir/@2.@code_notify_settle_pane" 2>/dev/null)" == "%3" ]] \
    || fail "a preserved hint must arm the settle safety-net watch, even for claude"
[[ "$(cat "$state_dir/@2.@code_notify_settle_badge_only" 2>/dev/null)" == "1" ]] \
    || fail "the preserve must mark its settle watch badge-only (toast already sent)"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "precondition: the static running badge should be up (got: $(window_name))"
printf '%s' "idle at the prompt" > "$state_dir/%3.pane_content"
printf '%s' "$$" > "$state_dir/@2.@code_notify_agent_pid"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
tmux_agent_exit_sweep || fail "preserve settle baseline tick should succeed"
[[ -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the baseline tick must not retire the preserved marker"
[[ -f "$state_dir/@2.@code_notify_settle_fp" ]] \
    || fail "the baseline tick should snapshot the pane"
: > "$settle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
    TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "the settling tick should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "an idle pane must retire the falsely-preserved marker"
[[ ! -f "$state_dir/@2.@code_notify_settle_pane" ]] \
    || fail "the reconcile should disarm the settle watch"
[[ ! -f "$state_dir/@2.@code_notify_settle_badge_only" ]] \
    || fail "the reconcile should clear the badge-only marker with the watch"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the reconcile should restore the window name (got: $(window_name))"
[[ "$(cat "$settle_notify_log")" == "%3|stop|claude|"*"|zsh|0|1|1" ]] \
    || fail "the reconcile must run the notifier badge-only — the preserving Stop already toasted (got: $(cat "$settle_notify_log"))"
for opt_name in @code_notify_agent_pid window_name; do
    rm -f "$state_dir/@2.$opt_name"
done
rm -f "$state_dir/%3.pane_content" "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
pass "a falsely-preserved queued-prompt marker self-heals once the pane idles"

# --- REGRESSION: raced duplicate sweep chains collapse instead of persisting ---
# Two hook processes can both read an empty pending flag and both register a
# sweep timer. Each timer used to clear the flag unconditionally at fire time
# and reschedule at sweep end, so the stray chain survived forever — and every
# idle/settle expiry both chains raced on delivered the same notification
# twice (observed live as an extra "input request" toast alongside each
# Codex idle nudge). The chain token must make the timer that lost the flag
# exit at fire time without sweeping, notifying, or re-arming.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_idle_watch_arm_current codex projX || fail "idle arm for the race test should succeed"
idle_fp="$(printf '%s\n' "turn finished, waiting" | cksum)"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
: > "$idle_notify_log"
saved_cancel_markers="$TMUX_DIALOG_CANCEL_MARKERS"
TMUX_DIALOG_CANCEL_MARKERS=""
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_schedule_sweep \
    || fail "scheduling chain A should succeed"
# Simulate the race: chain B's pending check read the flag before A wrote it.
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/notifier-stub" tmux_agent_exit_schedule_sweep \
    || fail "scheduling chain B should succeed"
TMUX_DIALOG_CANCEL_MARKERS="$saved_cancel_markers"
race_payload_a=$(sed -n 's/^run-shell -b -d 5 \(.*\)$/\1/p' "$log_file" | head -n 1)
race_payload_b=$(sed -n 's/^run-shell -b -d 5 \(.*\)$/\1/p' "$log_file" | tail -n 1)
[[ -n "$race_payload_a" ]] && [[ -n "$race_payload_b" ]] \
    || fail "both raced payloads should be extractable"
payload_has_setting "$race_payload_a" CODE_NOTIFY_TMUX_DIALOG_CANCEL_MARKERS "" \
    || fail "agent-exit payload must preserve disabled/custom decline markers"
payload_has_setting "$race_payload_a" CODE_NOTIFY_TMUX_DIALOG_CANCEL_AGENTS "$TMUX_DIALOG_CANCEL_AGENTS" \
    || fail "agent-exit payload must preserve the decline-detection allowlist"
[[ "$race_payload_a" != "$race_payload_b" ]] \
    || fail "raced registrations should carry distinct chain tokens"
flag_before="$(cat "$state_dir/.@code_notify_agent_exit_sweep_scheduled" 2>/dev/null)"
[[ -n "$flag_before" ]] || fail "the pending flag should record the owning token"
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$race_payload_a" \
    || fail "the losing timer should still exit cleanly"
[[ "$(cat "$state_dir/.@code_notify_agent_exit_sweep_scheduled" 2>/dev/null)" == "$flag_before" ]] \
    || fail "the losing timer must not consume the owner's pending flag"
[[ -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "the losing timer must not sweep the idle watch"
sleep 0.3
[[ ! -s "$idle_notify_log" ]] || fail "the losing timer must not notify"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "the losing timer must not reschedule itself"
env -u TMUX_PANE /bin/sh -c "$race_payload_b" \
    || fail "the owning timer should run cleanly"
wait_for_idle_log || fail "the owning timer should still deliver the idle nudge"
[[ "$(wc -l < "$idle_notify_log" | tr -d ' ')" == "1" ]] \
    || fail "the collapsed race should notify exactly once (got: $(cat "$idle_notify_log"))"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "the owning timer should consume the idle watch"
# The tighter interleaving: the owner fires FIRST, consuming the flag, and
# the stale twin fires into that empty-flag window while state is pending
# again. Empty must read as lost ownership too — treating it as a free pass
# would let the straggler sweep the same state concurrently with the owner
# and re-deliver the duplicate.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
printf '%s' "%3 1000 $idle_fp stable codex projX" > "$state_dir/@2.@code_notify_idle_watch"
: > "$log_file"
env -u TMUX_PANE /bin/sh -c "$race_payload_a" \
    || fail "the straggling timer should still exit cleanly on an empty flag"
[[ -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "an empty flag must read as lost ownership, not sweep"
sleep 0.3
[[ "$(wc -l < "$idle_notify_log" | tr -d ' ')" == "1" ]] \
    || fail "the straggling timer must not re-deliver the nudge (got: $(cat "$idle_notify_log"))"
grep -q "^run-shell -b -d 5 " "$log_file" \
    && fail "the straggling timer must not restart the chain"
rm -f "$state_dir/%3.pane_content" "$state_dir/@2.@code_notify_idle_watch" \
    "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
pass "raced duplicate sweep chains collapse to a single notification"

# --- REGRESSION: ownership is claimed before the timer is armed ---
# Armed-first, a scheduler descheduled (or suspended) past the timer delay
# lets the payload fire against a still-empty flag and exit; the late claim
# then reads as "pending" forever and wedges the chain until the tmux server
# restarts. The claim must land first — and a failed arm (run-shell -d needs
# tmux >= 3.2) must roll the claim back rather than leave that same wedge.
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$log_file"
tmux_agent_exit_schedule_sweep || fail "ordering-test schedule should succeed"
claim_line=$(grep -n "^set-option -g @code_notify_agent_exit_sweep_scheduled " "$log_file" | head -n 1 | cut -d: -f1)
arm_line=$(grep -n "^run-shell -b -d 5 " "$log_file" | head -n 1 | cut -d: -f1)
[[ -n "$claim_line" ]] && [[ -n "$arm_line" ]] \
    || fail "the schedule should log both the ownership claim and the timer arm"
(( claim_line < arm_line )) \
    || fail "the ownership claim must be recorded before the timer is armed"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
FAKE_TMUX_RUN_SHELL_FAIL=1 tmux_agent_exit_schedule_sweep \
    || fail "a schedule whose arm fails should still exit cleanly"
[[ ! -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled" ]] \
    || fail "a failed arm must roll the ownership claim back"
# The rollback must be scoped to this scheduler's own claim. If a racer that
# also passed the empty pending check overwrites the token and arms its
# timer successfully while our arm fails, unsetting unconditionally would
# strand the racer's live timer against an empty flag — its guard would exit
# without sweeping and the chain would stall. Shim run-shell to interleave
# exactly that: the racer's overwrite lands, then our arm fails.
tmux() {
    if [[ "$1" == "run-shell" ]]; then
        printf '%s' "racer.token" > "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
        return 1
    fi
    command tmux "$@"
}
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
tmux_agent_exit_schedule_sweep \
    || fail "a schedule losing the claim race should still exit cleanly"
unset -f tmux
[[ "$(cat "$state_dir/.@code_notify_agent_exit_sweep_scheduled" 2>/dev/null)" == "racer.token" ]] \
    || fail "rollback must not clear a claim a racing scheduler now owns"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
pass "scheduling claims ownership before arming and rolls back only its own claim"

# --- acknowledgment paths cancel the pending nudge ---
# Clearing the badge (glance visit, cleanup) and the click-to-clear command
# both mean the user attended the window.
printf '%s' "turn finished, waiting" > "$state_dir/%3.pane_content"
tmux_badge_set "🟢" glance || fail "badge for the acknowledgment test should succeed"
tmux_idle_watch_arm_current codex projX || fail "idle arm for the acknowledgment test should succeed"
tmux_badge_clear "@2" || fail "badge clear should succeed"
[[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
    || fail "clearing the badge should disarm the idle watch"
clear_cmd=$(tmux_badge_build_clear_command) || fail "clear command should build"
[[ "$clear_cmd" == *"badge-clear-window '@2'"* ]] \
    || fail "the click-to-clear command should use the locked clear subcommand"
rm -f "$state_dir/%3.pane_content"
pass "badge clear and notification click cancel the pending idle nudge"

# --- ordinary tool lifecycle signals must not start a spinner ---
: > "$log_file"
tmux_running_resume_after_input || fail "resume without an input pause should succeed"
grep -q "rename-window" "$log_file" \
    && fail "resume without a pending marker must not create a running badge"
pass "resume hook ignores ordinary tool activity"

# --- running-stop leaves an event badge that replaced the marker ---
export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
tmux_running_start || fail "running-start before event badge should succeed"
tmux_badge_set "🟢" engage || fail "event badge should succeed"
tmux_running_stop || fail "running-stop after event badge should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "running-stop must not clear an event badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "running-stop should still drop the epoch"
tmux_badge_clear "@2"
pass "running-stop leaves a replacing event badge alone"

# --- stale running marker is retired by the sweep ---
tmux_running_start || fail "running-start for staleness test should succeed"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # ancient epoch
export FAKE_TMUX_WINDOWS="@2|1000|running|zsh"              # id|since|mode for the running sweep
tmux_running_sweep_stale
[[ "$(window_name)" == "zsh" ]] || fail "stale sweep should restore the name (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "stale sweep should drop the epoch"
export FAKE_TMUX_WINDOWS=""
pass "stale running marker is retired"

# --- a fresh running marker schedules a one-shot stale sweep on the server ---
# Every other sweep call site needs later activity on the server; the run-shell
# timer is what retires a dead run's marker when none ever comes.
rm -f "$state_dir/.@code_notify_sweep_scheduled"   # earlier cases armed one
: > "$log_file"
tmux_running_start || fail "running-start for the schedule test should succeed"
grep -q "^run-shell -b -d " "$log_file" \
    || fail "a fresh running marker should schedule a delayed stale sweep"
delay=$(sed -n 's/^run-shell -b -d \([0-9][0-9]*\) .*/\1/p' "$log_file" | head -n 1)
[[ "${delay:-0}" -ge $((TMUX_RUNNING_TTL - 60)) ]] \
    || fail "the timer should fire only after the marker can expire (got delay: $delay)"
[[ -f "$state_dir/.@code_notify_sweep_scheduled" ]] \
    || fail "the pending timer should be recorded in @code_notify_sweep_scheduled"
pass "fresh running marker schedules a delayed stale sweep"

# --- a pending timer is not stacked by further sweeps ---
sched_count=$(grep -c "^run-shell -b -d " "$log_file")
tmux_running_sweep_stale
[[ "$(grep -c "^run-shell -b -d " "$log_file")" == "$sched_count" ]] \
    || fail "a pending timer must not be re-armed by another sweep"
pass "pending timer is not stacked"

# --- the scheduled payload clears the flag and retires a stale marker ---
# Extract the run-shell payload exactly as tmux would execute it after the
# delay: /bin/sh -c, no TMUX_PANE. The marker is aged past the TTL first, so
# the timer's sweep must restore the window and drop the epoch and the flag.
payload=$(sed -n 's/^run-shell -b -d [0-9][0-9]* \(.*\)$/\1/p' "$log_file" | head -n 1)
[[ -n "$payload" ]] || fail "the timer payload should be extractable from the run-shell call"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # went stale before firing
env -u TMUX_PANE /bin/sh -c "$payload" || fail "the timer payload should run cleanly"
[[ ! -f "$state_dir/.@code_notify_sweep_scheduled" ]] \
    || fail "the timer payload should clear the pending flag before sweeping"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "the timer's sweep should retire the stale marker"
[[ "$(window_name)" == "zsh" ]] \
    || fail "the timer's sweep should restore the window name (got: $(window_name))"
pass "scheduled sweep retires a stale marker end-to-end"

# --- the timer's sweep re-schedules while fresher markers remain ---
tmux_running_start || fail "running-start for the re-schedule test should succeed"
rm -f "$state_dir/.@code_notify_sweep_scheduled"   # pretend the timer just fired
: > "$log_file"
tmux_running_sweep_stale
grep -q "^run-shell -b -d " "$log_file" \
    || fail "a sweep that leaves fresh markers behind should re-arm the timer"
tmux_running_stop || fail "cleanup running-stop should succeed"
pass "sweep re-schedules while fresh markers remain"

# --- running disabled via badge kill switch ---
: > "$log_file"
CODE_NOTIFY_TMUX_BADGE=false tmux_running_start || fail "disabled running-start should still exit 0"
grep -q "rename-window" "$log_file" && fail "disabled running-start must not rename"
pass "running-start honours the badge kill switch"

# --- spinner: arm injects the snippet, saves state, disarm restores ---
printf '%s' "THEME-FMT" > "$state_dir/.window-status-format"
printf '%s' "THEME-CUR" > "$state_dir/.window-status-current-format"
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "spinner arm should succeed"
snip="$(cat "$state_dir/.@code_notify_spinner_snip")"
[[ "$snip" == *"🌑"* && "$snip" == *"🌘"* ]] || fail "spinner snippet should contain the moon frames"
[[ "$snip" == *'#{T:@code_notify_clock}'* ]] || fail "spinner snippet should be wall-clock driven"
[[ "$snip" == *'@code_notify_running'* ]] || fail "spinner snippet should gate on the running option"
[[ "$snip" == *'#{?#{!=:#{@code_notify_orig_name},},,'* ]] \
    || fail "event badges should suppress the spinner in the status format"
if [[ -n "$REAL_TMUX" ]] && "$REAL_TMUX" -L "$QUOTE_SOCK" has-session 2>/dev/null; then
    real_window=$("$REAL_TMUX" -L "$QUOTE_SOCK" display-message -p '#{window_id}')
    real_now=$(date +%s)
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-option -w -t "$real_window" @code_notify_running "$real_now"
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-option -g @code_notify_clock "$real_now"
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-option -w -t "$real_window" @code_notify_orig_name 0
    [[ -z "$("$REAL_TMUX" -L "$QUOTE_SOCK" display-message -p -t "$real_window" "$snip")" ]] \
        || fail "a literal original window name of 0 must still suppress the spinner"
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-option -wu -t "$real_window" @code_notify_running
    "$REAL_TMUX" -L "$QUOTE_SOCK" set-option -wu -t "$real_window" @code_notify_orig_name
fi
[[ "$(cat "$state_dir/.window-status-format")" == "$snip"THEME-FMT ]] \
    || fail "arm should prepend the snippet to window-status-format"
[[ "$(cat "$state_dir/.window-status-current-format")" == "$snip"THEME-CUR ]] \
    || fail "arm should prepend the snippet to window-status-current-format"
[[ "$(cat "$state_dir/.status-interval")" == "1" ]] || fail "arm should lower status-interval to 1"
[[ "$(cat "$state_dir/.@code_notify_saved_interval")" == "10" ]] || fail "arm should save the user's interval"
tmux_spinner_arm || fail "second arm should be a no-op"
[[ "$(cat "$state_dir/.window-status-format")" == "$snip"THEME-FMT ]] \
    || fail "arm must be idempotent (snippet stacked)"
tmux_spinner_disarm || fail "spinner disarm should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "THEME-FMT" ]] \
    || fail "disarm should restore window-status-format (got: $(cat "$state_dir/.window-status-format"))"
[[ "$(cat "$state_dir/.window-status-current-format")" == "THEME-CUR" ]] \
    || fail "disarm should restore window-status-current-format"
[[ "$(cat "$state_dir/.status-interval")" == "10" ]] || fail "disarm should restore status-interval"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "disarm should drop the saved snippet"
pass "spinner arm/disarm round-trips the status-line state"

# --- spinner: #I themes render the moon after the window number ---
printf '%s' "#[fg=grey] #I #{window_name} " > "$state_dir/.window-status-format"
printf '%s' "#[fg=green] #I #{window_name} " > "$state_dir/.window-status-current-format"
tmux_spinner_arm || fail "spinner arm for #I placement should succeed"
snip="$(cat "$state_dir/.@code_notify_spinner_snip")"
[[ "$(cat "$state_dir/.window-status-format")" == "#[fg=grey] #I $snip#{window_name} " ]] \
    || fail "spinner should follow #I in window-status-format"
[[ "$(cat "$state_dir/.window-status-current-format")" == "#[fg=green] #I $snip#{window_name} " ]] \
    || fail "spinner should follow #I in window-status-current-format"
tmux_spinner_disarm || fail "spinner disarm after #I placement should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "#[fg=grey] #I #{window_name} " ]] \
    || fail "spinner disarm should restore an inline #I format"
pass "spinner follows the window number"

# --- spinner: user-replaced format is left alone on disarm ---
tmux_spinner_arm || fail "arm for replaced-format test should succeed"
printf '%s' "USER-NEW-FMT" > "$state_dir/.window-status-format"   # user replaced it wholesale
tmux_spinner_disarm || fail "disarm after user replacement should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "USER-NEW-FMT" ]] \
    || fail "disarm must not touch a format the user replaced (got: $(cat "$state_dir/.window-status-format"))"
pass "spinner disarm keeps a user-replaced format"

# --- spinner: user-changed interval is left alone on disarm ---
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "arm for the interval-guard test should succeed"
printf '%s' "5" > "$state_dir/.status-interval"   # user changed it while armed
tmux_spinner_disarm || fail "disarm after an interval change should succeed"
[[ "$(cat "$state_dir/.status-interval")" == "5" ]] \
    || fail "disarm must not clobber a user-changed status-interval (got: $(cat "$state_dir/.status-interval"))"
[[ ! -f "$state_dir/.@code_notify_saved_interval" ]] \
    || fail "disarm should still drop the saved interval"
pass "spinner disarm keeps a user-changed interval"

# --- spinner: a config reload that wipes the status format is re-armed ---
# Sourcing a tmux config re-sets window-status-format wholesale from the theme
# and restores the user's status-interval, while leaving our own options in
# place. Reading @code_notify_spinner_snip as an "already armed" flag left the
# spinner dead for up to TMUX_RUNNING_TTL, since only the idle disarm clears
# that flag and it holds off while any window is running. Arm must verify the
# injection instead and repair it.
printf '%s' "THEME-FMT" > "$state_dir/.window-status-format"
printf '%s' "THEME-CUR" > "$state_dir/.window-status-current-format"
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "arm for the config-reload test should succeed"
snip="$(cat "$state_dir/.@code_notify_spinner_snip")"
printf '%s' "THEME-FMT" > "$state_dir/.window-status-format"           # source-file
printf '%s' "THEME-CUR" > "$state_dir/.window-status-current-format"   # source-file
printf '%s' "10" > "$state_dir/.status-interval"                       # source-file
tmux_spinner_arm || fail "re-arm after a config reload should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "$snip"THEME-FMT ]] \
    || fail "re-arm should re-inject the lost snippet (got: $(cat "$state_dir/.window-status-format"))"
[[ "$(cat "$state_dir/.window-status-current-format")" == "$snip"THEME-CUR ]] \
    || fail "re-arm should re-inject into window-status-current-format"
[[ "$(cat "$state_dir/.status-interval")" == "1" ]] \
    || fail "re-arm should lower the reloaded status-interval again"
[[ "$(cat "$state_dir/.@code_notify_saved_interval")" == "10" ]] \
    || fail "re-arm should save the reloaded interval for disarm"
tmux_spinner_disarm || fail "disarm after the reload re-arm should succeed"
[[ "$(cat "$state_dir/.window-status-format")" == "THEME-FMT" ]] \
    || fail "disarm after a reload re-arm should restore the theme format"
[[ "$(cat "$state_dir/.status-interval")" == "10" ]] \
    || fail "disarm after a reload re-arm should restore the interval"
pass "a config reload that wipes the status format is re-armed"

# --- spinner: re-arm keeps a global interval the user raised while armed ---
# The counterpart to the reload repair above: an interval above 1 with the
# formats still injected is the user's own doing, not a reload, and re-arming
# must not fight it on every prompt.
printf '%s' "10" > "$state_dir/.status-interval"
tmux_spinner_arm || fail "arm for the interval re-arm test should succeed"
printf '%s' "5" > "$state_dir/.status-interval"   # user raised it while armed
tmux_spinner_arm || fail "re-arm after a user interval change should succeed"
[[ "$(cat "$state_dir/.status-interval")" == "5" ]] \
    || fail "re-arm must not re-lower an interval the user raised (got: $(cat "$state_dir/.status-interval"))"
[[ "$(cat "$state_dir/.@code_notify_saved_interval")" == "10" ]] \
    || fail "re-arm must keep the arm-time saved interval"
tmux_spinner_disarm || fail "disarm after the interval re-arm test should succeed"
pass "re-arm keeps a user-raised status-interval"

# --- spinner: session-local intervals are lowered and restored ---
# The global status-interval set does not reach a session with a local value;
# its spinner would tick at the slower local rate.
export FAKE_TMUX_SESSIONS='$1'
printf '%s' "10" > "$state_dir/.status-interval"
printf '%s' "9" > "$state_dir"/'$1.status-interval'
tmux_spinner_arm || fail "arm for the session-interval test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "1" ]] \
    || fail "arm should lower a session-local interval to 1"
[[ "$(cat "$state_dir"/'$1.@code_notify_saved_interval')" == "9" ]] \
    || fail "arm should save the session-local interval"
tmux_spinner_disarm || fail "disarm for the session-interval test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "9" ]] \
    || fail "disarm should restore the session-local interval (got: $(cat "$state_dir"/'$1.status-interval'))"
[[ ! -f "$state_dir"/'$1.@code_notify_saved_interval' ]] \
    || fail "disarm should drop the session bookkeeping"
pass "session-local intervals are lowered and restored"

# --- spinner: sessions appearing after arm are synced, user changes win ---
tmux_spinner_arm || fail "arm for the late-session test should succeed"
export FAKE_TMUX_SESSIONS=$'$1\n$4'
printf '%s' "7" > "$state_dir"/'$4.status-interval'   # created after arm
tmux_spinner_arm || fail "re-arm should succeed"
[[ "$(cat "$state_dir"/'$4.status-interval')" == "1" ]] \
    || fail "an already-armed spinner should still sync a late session's interval"
[[ "$(cat "$state_dir"/'$4.@code_notify_saved_interval')" == "7" ]] \
    || fail "the late session's interval should be saved"
printf '%s' "3" > "$state_dir"/'$1.status-interval'   # user changed it while armed
tmux_spinner_arm || fail "re-arm after a user change should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "3" ]] \
    || fail "a session the user re-raised while armed must not be re-lowered"
tmux_spinner_disarm || fail "disarm for the late-session test should succeed"
[[ "$(cat "$state_dir"/'$1.status-interval')" == "3" ]] \
    || fail "disarm must keep a session interval the user changed while armed"
[[ "$(cat "$state_dir"/'$4.status-interval')" == "7" ]] \
    || fail "disarm should restore the late session's interval"
rm -f "$state_dir"/'$1.status-interval' "$state_dir"/'$4.status-interval'
export FAKE_TMUX_SESSIONS=""
pass "late sessions are synced and user changes win"

# --- spinner mode: running-start arms without renaming ---
rm -f "$state_dir/.window-status-format" "$state_dir/.window-status-current-format"
printf '%s' "10" > "$state_dir/.status-interval"
mkdir -p "$HOME/.claude/notifications"
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
: > "$log_file"
tmux_running_start || fail "spinner-mode running-start should succeed"
grep -q "rename-window" "$log_file" && fail "spinner mode must not rename the window"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "spinner mode should arm the status-line spinner"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner mode should still store the start epoch"
pass "spinner-mode running-start arms without renaming"

# --- spinner mode: running-start clears a waiting event badge ---
tmux_running_stop || fail "spinner-mode setup stop should succeed"
tmux_badge_set "💬" engage || fail "spinner-mode waiting badge setup should succeed"
[[ "$(window_name)" == "💬 zsh" ]] \
    || fail "precondition: window should carry the waiting badge"
tmux_running_start || fail "spinner-mode resume from waiting badge should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner-mode resume should clear the waiting badge (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_clear_mode" ]] \
    || fail "spinner-mode resume should remove the waiting badge state"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner-mode resume should retain the running epoch"
pass "spinner-mode running-start clears a waiting event badge"

# --- spinner mode: running-stop disarms once nothing is running ---
export FAKE_TMUX_WINDOWS="@2|"   # no running epoch anywhere after the stop
tmux_running_stop || fail "spinner-mode running-stop should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] || fail "spinner-mode stop should drop the epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "last running-stop should disarm the spinner"
[[ "$(cat "$state_dir/.status-interval")" == "10" ]] || fail "last running-stop should restore status-interval"
export FAKE_TMUX_WINDOWS=""
pass "spinner-mode running-stop disarms when idle"

# --- spinner mode: an exited agent disarms without waiting for TTL ---
tmux_running_start || fail "spinner-mode running-start before agent exit should succeed"
printf '%s' "999999" > "$state_dir/@2.@code_notify_agent_pid"
tmux_agent_exit_sweep || fail "spinner-mode agent-exit sweep should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "agent exit should drop the spinner running epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "agent exit should disarm the spinner immediately"
pass "agent exit clears the spinner promptly"

# --- spinner mode: a settled review removes the spinner before completion ---
printf '%s' "review complete in spinner mode" > "$state_dir/%3.pane_content"
CODE_NOTIFY_TMUX_AGENT_NAME=codex tmux_prompt_submit \
    || fail "spinner-mode codex review start should succeed"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "spinner-mode review should arm the spinner"
spinner_review_fp="$(printf '%s\n' "review complete in spinner mode" | cksum)"
printf '%s' "$spinner_review_fp" > "$state_dir/@2.@code_notify_settle_fp"
printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
: > "$settle_notify_log"
CODE_NOTIFY_NOTIFIER_PATH="$fake_bin/settle-notifier-stub" \
    TMUX_SETTLE_SECONDS=0 tmux_agent_exit_sweep \
    || fail "spinner-mode settled review sweep should succeed"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "settled spinner-mode review should drop the running epoch"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "settled spinner-mode review should disarm the spinner"
[[ "$(cat "$settle_notify_log")" == "%3|stop|codex|"*"|zsh|0|1|" ]] \
    || fail "spinner should be visually inactive before synthetic completion (got: $(cat "$settle_notify_log"))"
rm -f "$state_dir/%3.pane_content"
pass "settled review removes the spinner before synthetic completion"

# --- spinner mode: env var override forces it off ---
: > "$log_file"
CODE_NOTIFY_TMUX_SPINNER=false tmux_running_start || fail "env-forced static running-start should succeed"
grep -q "rename-window" "$log_file" || fail "CODE_NOTIFY_TMUX_SPINNER=false must fall back to the static icon"
tmux_running_stop
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
pass "spinner env override forces static mode"

# --- spinner off mid-run: running windows fall back to the static icon ---
# `cn spinner off` disarms the snippet while agents are still working; each
# window with a fresh running epoch must be re-badged with the static icon or
# it would carry no indicator at all until its run ends.
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
: > "$log_file"
tmux_running_start || fail "running-start for the spinner-off test should succeed"
grep -q "rename-window" "$log_file" && fail "precondition: spinner mode must not rename"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] || fail "precondition: spinner should be armed"
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"   # what `cn spinner off` does
tmux_spinner_disarm || fail "disarm for the spinner-off test should succeed"
tmux_running_apply_static_badges || fail "apply-static-badges should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "spinner off must re-badge running windows with the static icon (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "the fallback badge should be a running-mode marker"
pass "spinner off falls back to the static icon on running windows"

# --- the static fallback skips stale epochs ---
tmux_running_stop || fail "cleanup running-stop should succeed"
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # dead run, long stale
: > "$log_file"
tmux_running_apply_static_badges || fail "apply-static-badges on a stale epoch should still succeed"
grep -q "rename-window" "$log_file" && fail "a stale running epoch must not get a fallback badge"
rm -f "$state_dir/@2.@code_notify_running"
pass "static fallback skips stale epochs"

# --- spinner on mid-run: static running badges convert to the snippet ---
# `cn spinner on` while an agent works: the static 🌕 rename and the newly
# armed snippet render from the same epoch, so the rename must come off or
# the window shows both indicators at once.
tmux_running_start || fail "running-start for the spinner-on test should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] || fail "precondition: window should carry the static running icon"
tmux_running_convert_static_badges_to_spinner || fail "convert-to-spinner should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner on must drop the static running rename (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "the running epoch must survive the conversion — the spinner keys on it"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "conversion should arm the spinner when a fresh marker exists"
tmux_spinner_disarm || fail "cleanup disarm should succeed"
tmux_running_stop || fail "cleanup running-stop after conversion should succeed"
pass "spinner on converts static running badges to the snippet"

# --- the conversion leaves event badges and idle windows alone ---
printf '%s' "1000" > "$state_dir/@2.@code_notify_running"   # stale epoch only
tmux_badge_set "👋" engage || fail "event badge for the conversion test should succeed"
tmux_running_convert_static_badges_to_spinner || fail "convert on stale/idle should succeed"
[[ "$(window_name)" == "👋 zsh" ]] \
    || fail "conversion must not touch an event badge (got: $(window_name))"
[[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "conversion must not arm the spinner when no fresh marker exists"
tmux_badge_clear "@2"
rm -f "$state_dir/@2.@code_notify_running"
pass "conversion skips event badges and stale epochs"

# --- prompt-submit fast path: engage badge swaps to the running icon ---
# The synchronous prompt path must not clear-restore-then-rebadge (two
# renames) or run a server-wide sweep: one capture, one rename, timer armed.
tmux_badge_set "🟢" engage || fail "engage badge for the prompt-submit test should succeed"
[[ "$(window_name)" == "🟢 zsh" ]] || fail "precondition: window should be engage-badged"
: > "$log_file"
tmux_prompt_submit || fail "prompt-submit should succeed"
[[ "$(window_name)" == "🌕 zsh" ]] \
    || fail "prompt-submit should swap the event badge for the running icon (got: $(window_name))"
[[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
    || fail "prompt-submit should leave a running-mode marker"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "prompt-submit should store the running epoch"
[[ "$(grep -c "rename-window" "$log_file")" == "1" ]] \
    || fail "the badge swap should cost exactly one rename"
grep -q "^list-windows" "$log_file" && fail "prompt-submit must not run a server-wide sweep"
tmux_running_stop || fail "cleanup running-stop should succeed"
pass "prompt-submit swaps the badge in one rename, no sweep"

# --- prompt-submit in spinner mode: clears the badge, arms, no re-badge ---
touch "$HOME/.claude/notifications/tmux-spinner-enabled"
tmux_badge_set "🟢" engage || fail "engage badge for the spinner prompt-submit test should succeed"
: > "$log_file"
tmux_prompt_submit || fail "spinner-mode prompt-submit should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "spinner-mode prompt-submit should clear the event badge (got: $(window_name))"
[[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
    || fail "spinner-mode prompt-submit should arm the spinner"
[[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
    || fail "spinner-mode prompt-submit should store the epoch"
[[ "$(grep -c "rename-window" "$log_file")" == "1" ]] \
    || fail "spinner mode should rename only to restore the cleared badge"
tmux_running_stop || fail "cleanup running-stop should succeed"
rm -f "$HOME/.claude/notifications/tmux-spinner-enabled"
pass "spinner-mode prompt-submit clears the badge and arms the spinner"

# --- prompt-submit with the running indicator disabled still engage-clears ---
tmux_badge_set "🟢" engage || fail "engage badge for the disabled prompt-submit test should succeed"
CODE_NOTIFY_TMUX_RUNNING=false tmux_prompt_submit || fail "disabled prompt-submit should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "prompt-submit must clear the badge even with the running indicator disabled (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "disabled prompt-submit must not store an epoch"
pass "disabled prompt-submit still engage-clears"

# Antigravity uses its first PreToolUse as the engage signal. That reaches the
# generic running-start path rather than tmux_prompt_submit, and must still
# clear a waiting badge when the running indicator itself is disabled.
tmux_badge_set "🟢" engage || fail "engage badge for the disabled running-start test should succeed"
CODE_NOTIFY_TMUX_RUNNING=false tmux_running_start || fail "disabled running-start should succeed"
[[ "$(window_name)" == "zsh" ]] \
    || fail "running-start must engage-clear with the indicator disabled (got: $(window_name))"
[[ ! -f "$state_dir/@2.@code_notify_running" ]] \
    || fail "disabled running-start must not store an epoch"
pass "disabled running-start still engage-clears"

# --- clear command structure ---
cmd=$(tmux_badge_build_clear_command) || fail "clear command should build inside tmux"
[[ "$cmd" == *"TMUX='$test_dir/sock,12345,0'"* ]] || fail "clear command should target the captured socket environment"
[[ "$cmd" == *"badge-clear-window '@2'"* ]] && [[ "$cmd" == *"/tmux.sh'"* ]] \
    || fail "clear command should delegate to the locked window-clear entry point"
pass "clear command structure"

# --- generated clear command restores a badged window ---
tmux_badge_set "🧨" || fail "badge for clear-command test should succeed"
[[ "$(window_name)" == "🧨 zsh" ]] || fail "precondition: window should be badged"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "generated clear command should run cleanly"
[[ "$(window_name)" == "zsh" ]] || fail "generated command should restore the original name"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "generated command should unset the saved options"
pass "generated clear command execution"

# --- notification click clear serializes with a concurrent event badge ---
tmux_badge_set "💬" engage || fail "badge for click-clear race should succeed"
click_clear_signal="$test_dir/click-clear-read"
click_clear_release="$test_dir/click-clear-release"
click_set_lock_attempt="$test_dir/click-set-lock-attempt"
FAKE_TMUX_PAUSE_BADGE_CLEAR=1 \
FAKE_TMUX_BADGE_CLEAR_SIGNAL="$click_clear_signal" \
FAKE_TMUX_BADGE_CLEAR_RELEASE="$click_clear_release" \
    /bin/sh -c "$cmd" > /dev/null 2>&1 &
click_clear_pid=$!
wait_for_path "$click_clear_signal" || fail "click clear did not reach its locked state read"
mkdir() {
    if [[ -n "${FAKE_LOCK_ATTEMPT_SIGNAL:-}" ]] && [[ "$*" == *".lock"* ]]; then
        : > "$FAKE_LOCK_ATTEMPT_SIGNAL"
    fi
    command mkdir "$@"
}
FAKE_LOCK_ATTEMPT_SIGNAL="$click_set_lock_attempt" tmux_badge_set "💬" engage &
badge_set_pid=$!
wait_for_path "$click_set_lock_attempt" || fail "concurrent event did not attempt the click clear's lock"
: > "$click_clear_release"
wait "$click_clear_pid"
click_clear_pid=""
wait "$badge_set_pid"
badge_set_pid=""
unset -f mkdir
[[ "$(window_name)" == "💬 zsh" ]] \
    || fail "click clear and concurrent event must leave exactly the newer badge (got: $(window_name))"
tmux_badge_clear "@2"
pass "generated click clear is atomic with concurrent badge delivery"

# --- generated clear command is a no-op without a badge ---
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly without a badge"
grep -q "rename-window" "$log_file" && fail "clear command without badge should not rename"
pass "generated clear command no-op"

# --- generated clear command keeps a manual rename ---
tmux_badge_set "🟢" || fail "badge for manual-rename clear-command test should succeed"
printf '%s' "work" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a manual rename"
[[ "$(window_name)" == "work" ]] || fail "clear command must not clobber a manual rename (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a manual rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state"
pass "generated clear command keeps manual rename"

# --- generated clear command keeps a rename that ends in the original name ---
tmux_badge_set "🟢" || fail "badge for suffix-colliding clear-command test should succeed"
printf '%s' "api zsh" > "$state_dir/@2.window_name"   # user renames after badging
: > "$log_file"
/bin/sh -c "$cmd" > /dev/null 2>&1 || fail "clear command should run cleanly after a suffix-colliding rename"
[[ "$(window_name)" == "api zsh" ]] || fail "clear command must not clobber a rename ending in the original name (got: $(window_name))"
grep -q "rename-window" "$log_file" && fail "clear command after a suffix-colliding rename should not rename"
[[ ! -f "$state_dir/@2.@code_notify_orig_name" ]] || fail "clear command should still drop the badge state after a suffix-colliding rename"
pass "generated clear command keeps suffix-colliding manual rename"

# --- notifier.sh end-to-end wiring (macOS only) ---
# Claude is an engage-clear agent: a stop event badges the origin window with 🟢
# and passes -focus, but does NOT attach a click-to-clear command (clicking is a
# glance). The badge clears on the next UserPromptSubmit instead.
if [[ "$(uname -s)" == "Darwin" ]]; then
    NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
    tn_log="$test_dir/terminal-notifier.log"

    cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-help" ]]; then echo "-focus"; exit 0; fi
printf '%s\n' "\$@" >> "$tn_log"
EOF
    chmod +x "$fake_bin/terminal-notifier"

    rm -f "$state_dir"/*
    : > "$log_file"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh should exit cleanly"

    [[ "$(window_name)" == "🟢 zsh" ]] || fail "notifier should badge the origin window with the stop icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "Claude badge should record clear mode engage"
    grep -qx -- "-focus" "$tn_log" || fail "notifier should pass -focus"
    grep -q -- "badge-clear-window" "$tn_log" \
        && fail "Claude notification must not carry a click-to-clear command (clears on prompt-submit)"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        && fail "Claude badge-set must not arm the glance-clear focus hook"
    pass "notifier end-to-end: Claude badges without glance-clearing"

    # AskUserQuestion has its own specific PreToolUse alert. Claude immediately
    # follows it with a generic permission_prompt Notification for the same UI;
    # that duplicate must not replace either the 🙋 badge or desktop alert.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" PreToolUse claude testproj > /dev/null 2>&1 \
        <<< '{"session_id":"question-session","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?"}]}}' \
        || fail "notifier.sh AskUserQuestion should exit cleanly"
    [[ "$(window_name)" == "🙋 zsh" ]] \
        || fail "AskUserQuestion should set the question badge (got: $(window_name))"
    grep -q "Which database?" "$tn_log" \
        || fail "AskUserQuestion should deliver the question notification"
    question_notification_checksum="$(cksum < "$tn_log")"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"session_id":"question-session","message":"Claude needs your permission","notification_type":"permission_prompt"}' \
        || fail "notifier.sh duplicate permission event should exit cleanly"
    [[ "$(window_name)" == "🙋 zsh" ]] \
        || fail "duplicate permission event replaced the question badge (got: $(window_name))"
    [[ "$(cksum < "$tn_log")" == "$question_notification_checksum" ]] \
        || fail "duplicate permission event replaced the desktop question notification"
    pass "notifier end-to-end: question survives its generic permission duplicate"

    # UserPromptSubmit: the user handed this window work, so the event badge
    # clears and the running marker (agent now working) replaces it.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh UserPromptSubmit should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "UserPromptSubmit should clear the event badge and set the running icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
        || fail "UserPromptSubmit should leave a running-mode marker"
    [[ "$(cat "$state_dir/@2.@code_notify_running")" =~ ^[0-9]+$ ]] \
        || fail "UserPromptSubmit should store the running epoch"
    pass "notifier end-to-end: UserPromptSubmit swaps event badge for running marker"

    # The next stop event takes the running marker off before badging 🟢.
    rm -f "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop after running should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "stop should replace the running icon with the event badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "stop should drop the running epoch"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "the replacing event badge should be engage-clear"
    # Reset for the codex cases below, which assume a clean window.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 || true
    rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_clear_mode" \
        "$state_dir/@2.@code_notify_orig_name" "$state_dir/@2.@code_notify_autorename" \
        "$state_dir/@2.@code_notify_badged_name" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: stop replaces the running marker with the event badge"

    # Responding to an in-turn request does not emit UserPromptSubmit. The
    # notifier must therefore keep a pause marker from the notification and
    # let its PostToolUse hook restore the running indicator.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh input request should exit cleanly"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "input request should retain a tmux resume marker"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "input request should stop the running indicator"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" PostToolUse claude testproj > /dev/null 2>&1 \
        || fail "notifier.sh PostToolUse resume should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "PostToolUse should restore the running icon after input (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "PostToolUse should consume the input pause marker"
    rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_clear_mode" \
        "$state_dir/@2.@code_notify_orig_name" "$state_dir/@2.@code_notify_autorename" \
        "$state_dir/@2.@code_notify_badged_name" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: input response restores the running marker"

    # A permission request is an answerable mid-turn dialog: on top of the
    # pause marker it must arm the activity resume poll. The untyped
    # notification above (an idle-style pause) must not have — no turn is
    # running there, and toast-click/typing activity would light the spinner.
    [[ ! -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
        || fail "a generic notification must not arm the activity poll"
    printf '%s' "permission dialog" > "$state_dir/%3.pane_content"
    : > "$log_file"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "notifier.sh permission request should exit cleanly"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "permission request should retain a tmux resume marker"
    [[ "$(cat "$state_dir/@2.@code_notify_pause_fp" 2>/dev/null)" == "%3,0,"* ]] \
        || fail "permission request should defer its dialog snapshot"
    grep -q "^run-shell -b -d 2 " "$log_file" \
        || fail "permission request should schedule the 2s resume poll"
    [[ -f "$state_dir/.@code_notify_resume_poll_scheduled" ]] \
        || fail "permission request should record the pending poll"
    rm -f "$state_dir/@2.@code_notify_resume_pending" "$state_dir/@2.@code_notify_running" \
        "$state_dir/@2.@code_notify_clear_mode" "$state_dir/@2.@code_notify_orig_name" \
        "$state_dir/@2.@code_notify_autorename" "$state_dir/@2.@code_notify_badged_name" \
        "$state_dir/@2.@code_notify_pause_fp" "$state_dir/%3.pane_content" \
        "$state_dir/.@code_notify_resume_poll_scheduled" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: permission request arms the activity poll"

    # REGRESSION GUARD (recurred repeatedly — keep this test): focusing the
    # window of an UNANSWERED permission request must not swap the waiting
    # badge for the spinner. The PermissionRequest hook fires before the
    # dialog UI paints (under Ctrl+O verbose mode the dialog only renders when
    # the user leaves the transcript view), and merely selecting the window
    # makes the agent's TUI repaint — so the poll's baseline snapshot WILL
    # differ once, with no answer given. A single content change must
    # re-baseline, never resume: only a sustained repaint (content changing on
    # consecutive ticks — a genuinely working agent's ticking TUI) counts as
    # the answer.
    rm -f "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "verbose transcript, dialog not yet rendered" > "$state_dir/%3.pane_content"
    : > "$log_file"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 CODE_NOTIFY_TMUX_SPINNER=true \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "notifier.sh permission request for the focus regression should exit cleanly"
    [[ "$(window_name)" == "💬 zsh" ]] \
        || fail "permission request should badge the waiting window (got: $(window_name))"
    focus_payload=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | head -n 1)
    [[ -n "$focus_payload" ]] || fail "the focus-regression poll payload should be extractable"
    # Each tick re-schedules under a fresh chain token, so fire the payload
    # the previous tick registered — a stale payload string would lose
    # ownership and exit instead of polling.
    fire_focus_payload() {
        env -u TMUX_PANE /bin/sh -c "$focus_payload" || return 1
        local next
        next=$(sed -n 's/^run-shell -b -d 2 \(.*\)$/\1/p' "$log_file" | tail -n 1)
        [[ -n "$next" ]] && focus_payload="$next"
        return 0
    }
    # First tick baselines the pre-dialog pane.
    fire_focus_payload \
        || fail "the focus-regression baseline tick should run cleanly"
    # The user focuses the window: activity advances and the pane repaints
    # once (the dialog finally renders). This is NOT an answer.
    focus_pending=$(cat "$state_dir/@2.@code_notify_resume_pending")
    printf '%s' "$((focus_pending + 5))" > "$state_dir/@2.window_activity"
    printf '%s' "approval dialog rendered on focus" > "$state_dir/%3.pane_content"
    : > "$log_file"
    fire_focus_payload \
        || fail "the focus-repaint tick should run cleanly"
    [[ "$(window_name)" == "💬 zsh" ]] \
        || fail "REGRESSION: focusing replaced the waiting badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "REGRESSION: focusing marked the paused agent as running before the answer"
    [[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
        || fail "REGRESSION: focusing armed the spinner before the answer"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "the unanswered permission should keep its pause marker"
    grep -q "^run-shell -b -d 2 " "$log_file" \
        || fail "the poll should keep watching the unanswered dialog"
    # The dialog then just sits there: a still tick must keep waiting too.
    fire_focus_payload \
        || fail "the still tick should run cleanly"
    [[ "$(window_name)" == "💬 zsh" ]] \
        || fail "a still dialog must keep the waiting badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "a still dialog must not mark the agent running"
    # The reported field case: the dialog (question + Yes/No selector) shares
    # the pane with a backgrounded shell command whose flashing dot repaints
    # the pane on EVERY tick. As long as the dialog is on screen, no amount of
    # animation may swap the waiting badge for the spinner.
    e2e_dialog=$'Do you want to proceed?\n❯ 1. Yes\n  3. No'
    printf '%s\n%s' "$e2e_dialog" "· Running: make test (12s)" \
        > "$state_dir/%3.pane_content"
    fire_focus_payload \
        || fail "the animated-dialog tick should run cleanly"
    printf '%s\n%s' "$e2e_dialog" "• Running: make test (14s)" \
        > "$state_dir/%3.pane_content"
    fire_focus_payload \
        || fail "the second animated-dialog tick should run cleanly"
    [[ "$(window_name)" == "💬 zsh" ]] \
        || fail "REGRESSION: animation under the dialog replaced the waiting badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "REGRESSION: animation under the dialog marked the agent running"
    [[ ! -f "$state_dir/.@code_notify_spinner_snip" ]] \
        || fail "REGRESSION: animation under the dialog armed the spinner"
    # Sanity check the positive path so this guard cannot pass vacuously: an
    # actual answer collapses the dialog and the resumed turn repaints on
    # every tick, which must clear the badge and light the spinner.
    printf '%s' "running tool output (1s)" > "$state_dir/%3.pane_content"
    fire_focus_payload \
        || fail "the dialog-collapse tick should run cleanly"
    printf '%s' "running tool output (3s)" > "$state_dir/%3.pane_content"
    fire_focus_payload \
        || fail "the first answered tick should run cleanly"
    printf '%s' "running tool output (5s)" > "$state_dir/%3.pane_content"
    fire_focus_payload \
        || fail "the second answered tick should run cleanly"
    [[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" =~ ^[0-9]+$ ]] \
        || fail "a sustained repaint should resume the running indicator"
    [[ -f "$state_dir/.@code_notify_spinner_snip" ]] \
        || fail "the poll resume should arm the spinner in spinner mode"
    [[ "$(window_name)" == "zsh" ]] \
        || fail "the poll resume should clear the waiting badge (got: $(window_name))"
    rm -f "$state_dir/@2.@code_notify_running" "$state_dir/@2.@code_notify_clear_mode" \
        "$state_dir/@2.@code_notify_orig_name" "$state_dir/@2.@code_notify_autorename" \
        "$state_dir/@2.@code_notify_badged_name" "$state_dir/@2.@code_notify_resume_pending" \
        "$state_dir/@2.@code_notify_pause_fp" "$state_dir/@2.window_activity" \
        "$state_dir/%3.pane_content" "$state_dir/.@code_notify_resume_poll_scheduled" \
        "$state_dir/.@code_notify_sweep_scheduled" "$state_dir/.@code_notify_spinner_snip" \
        "$state_dir/.@code_notify_saved_interval" "$state_dir/.@code_notify_clock" \
        "$state_dir/.status-interval" "$state_dir/.window-status-format" \
        "$state_dir/.window-status-current-format" 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: focus repaint keeps the unanswered permission badge"

    # A pause releases the transition lock before this run reaches its badge,
    # so a queued prompt can re-light the window in between. The stale waiting
    # badge must not land on that successor turn's live indicator — the "stale
    # 💬 over a running window" report. The desktop alert still goes out: the
    # dialog is real, only the tmux rendering belongs to someone else now.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 \
        || fail "prompt-submit before the badge race should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "precondition: the running badge should be up (got: $(window_name))"
    : > "$tn_log"
    e2e_race_marker="$test_dir/e2e-successor-race"
    rm -f "$e2e_race_marker"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        FAKE_TMUX_SUCCESSOR_RACE_MARKER="$e2e_race_marker" \
        FAKE_TMUX_SUCCESSOR_RACE_EPOCH="$(date +%s)" \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "notifier.sh permission request racing a successor should exit cleanly"
    [[ -e "$e2e_race_marker" ]] || fail "precondition: the successor race should have fired"
    [[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" =~ ^[0-9]+$ ]] \
        || fail "the successor turn's marker should still be up"
    [[ "$(window_name)" != "💬 zsh" ]] \
        || fail "REGRESSION: the waiting badge landed on the successor turn's live window"
    [[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "REGRESSION: the pause parked a wait on the successor turn"
    [[ -s "$tn_log" ]] || fail "the permission alert itself should still be delivered"
    # The control: unraced, the same event badges and pauses as always.
    rm -f "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "notifier.sh unraced permission request should exit cleanly"
    [[ "$(window_name)" == "💬 zsh" ]] \
        || fail "an unraced permission request should badge the waiting window (got: $(window_name))"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "an unraced permission request should park the wait"
    pass "notifier end-to-end: a stale waiting badge stays off a successor turn"

    # A watch's detached child is scheduled against a validated world it can
    # only re-check at delivery. When the user answered in between and the poll
    # resumed the turn, the child must exit before its pause tears that turn
    # back down and before its toast fires for a dialog already dealt with.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 \
        || fail "prompt-submit before the guarded-child test should exit cleanly"
    guard_epoch="$(cat "$state_dir/@2.@code_notify_running")"
    guard_gen="$(cat "$state_dir/@2.@code_notify_run_gen")"
    [[ -n "$guard_gen" ]] || fail "precondition: the turn should carry a generation"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$guard_epoch" \
        CODE_NOTIFY_TMUX_GUARD_GEN="stale-generation" \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "an overtaken synthetic child should exit cleanly"
    [[ ! -s "$tn_log" ]] \
        || fail "REGRESSION: an overtaken synthetic child delivered its stale alert"
    [[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" == "$guard_epoch" ]] \
        || fail "REGRESSION: an overtaken synthetic child tore down the resumed turn"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "REGRESSION: an overtaken synthetic child repainted the window (got: $(window_name))"
    # The control: with the world unchanged, the same child delivers normally.
    rm -f "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$guard_epoch" \
        CODE_NOTIFY_TMUX_GUARD_GEN="$guard_gen" \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        || fail "an in-date synthetic child should exit cleanly"
    [[ -s "$tn_log" ]] || fail "an in-date synthetic child should deliver its alert"
    [[ -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "an in-date synthetic child should park its pause"
    pass "notifier end-to-end: an overtaken watch child delivers nothing"

    # The narrow window the start-up guard cannot cover: it passes, then a
    # whole notifier run happens — config, snooze, rate limiting, sound — and
    # the user answers somewhere inside it, the poll minting the successor.
    # Only the re-check under the transition lock sees that.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit claude testproj > /dev/null 2>&1 \
        || fail "prompt-submit before the late-race test should exit cleanly"
    late_epoch="$(cat "$state_dir/@2.@code_notify_running")"
    late_gen="$(cat "$state_dir/@2.@code_notify_run_gen")"
    late_race_marker="$test_dir/late-gen-race"
    rm -f "$late_race_marker"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_TMUX_GUARD_WINDOW="@2" CODE_NOTIFY_TMUX_GUARD_RUN="$late_epoch" \
        CODE_NOTIFY_TMUX_GUARD_GEN="$late_gen" \
        FAKE_TMUX_LATE_GEN_RACE_MARKER="$late_race_marker" \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" notification claude testproj > /dev/null 2>&1 \
        <<< '{"message": "Claude needs your permission to use Bash"}' \
        || fail "a child overtaken mid-run should exit cleanly"
    [[ -e "$late_race_marker" ]] \
        || fail "precondition: the start-up guard should have read the truthful generation"
    [[ ! -s "$tn_log" ]] \
        || fail "REGRESSION: a child overtaken after its start-up guard still delivered"
    [[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" == "$late_epoch" ]] \
        || fail "REGRESSION: a child overtaken after its start-up guard stopped the successor"
    [[ ! -f "$state_dir/@2.@code_notify_resume_pending" ]] \
        || fail "REGRESSION: a child overtaken after its start-up guard parked a pause"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "REGRESSION: a child overtaken after its start-up guard repainted the window (got: $(window_name))"
    rm -f "$late_race_marker"
    pass "notifier end-to-end: a child overtaken mid-run is stopped at the lock"

    # Codex reaches the notifier via its hooks.json as `notifier.sh stop codex`,
    # so RAW_ARG1 is "stop" and only TOOL_NAME is "codex". With no
    # UserPromptSubmit hook registered (no ~/.codex/hooks.json here) it must
    # glance-clear: badge set, focus hook armed, and the click-to-clear command
    # attached. Guards the RAW_ARG1-vs-TOOL_NAME bug and the engage-clear gate's
    # fallback — a badge must never be left without a clear path.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "codex stop (hooks.json path) should badge the window (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
        || fail "codex badge without a prompt hook should record clear mode glance"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        || fail "codex (glance-clear) badge-set must arm the focus hook"
    grep -q -- "badge-clear-window" "$tn_log" \
        || fail "codex notification should carry the click-to-clear command"
    pass "notifier end-to-end: codex without a prompt hook keeps glance-clearing"

    # A user's own unrelated UserPromptSubmit hook must not switch Codex to
    # engage mode: it won't clear our badge, so glance-clearing has to stay on
    # or the badge would be stuck. Only the managed Code-Notify command counts.
    mkdir -p "$HOME/.codex"
    cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "/usr/local/bin/my-own-hook.sh"}]}
    ]
  }
}
EOF
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (unrelated prompt hook) should exit cleanly"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "glance" ]] \
        || fail "an unrelated UserPromptSubmit hook must not switch codex to engage mode"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        || fail "codex with only an unrelated prompt hook must still arm the focus hook"
    pass "notifier end-to-end: unrelated prompt hook keeps codex glance-clearing"

    # With the UserPromptSubmit hook registered in Codex's hooks.json (what
    # `cn on codex` now installs), Codex is an engage-clear agent like Claude:
    # engage-mode badge, no focus hook, no click-to-clear — the badge clears on
    # the next prompt instead.
    cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {"hooks": [{"type": "command", "command": "notify.sh UserPromptSubmit codex"}]}
    ]
  }
}
EOF
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$log_file"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (prompt hook installed) should exit cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "codex stop should still badge the window with the prompt hook installed (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "engage" ]] \
        || fail "codex badge with the prompt hook should record clear mode engage"
    grep -q "set-hook -g session-window-changed" "$log_file" \
        && fail "codex (engage-clear) badge-set must not arm the focus hook"
    grep -q -- "badge-clear-window" "$tn_log" \
        && fail "codex (engage-clear) notification must not carry a click-to-clear command"
    pass "notifier end-to-end: codex with the prompt hook engage-clears"

    # And the Codex UserPromptSubmit event itself clears the badge, leaving
    # the running marker in its place (codex is now working on the prompt).
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" UserPromptSubmit codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh UserPromptSubmit codex should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "codex UserPromptSubmit should swap the event badge for the running icon (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_clear_mode")" == "running" ]] \
        || fail "codex UserPromptSubmit should leave a running-mode marker"
    pass "notifier end-to-end: codex UserPromptSubmit swaps badge for running marker"

    # A settle-derived completion has already removed its own old marker.
    # If a new prompt claims the window before that synthetic notifier starts,
    # it must neither stop the new run nor attach the old turn's idle watch.
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "already-applied synthetic stop should exit cleanly"
    [[ "$(window_name)" == "🌕 zsh" ]] \
        || fail "an old synthetic stop must not replace a new run (got: $(window_name))"
    [[ "$(cat "$state_dir/@2.@code_notify_running" 2>/dev/null)" =~ ^[0-9]+$ ]] \
        || fail "an old synthetic stop must preserve the new running epoch"
    [[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
        || fail "an old synthetic stop must not arm an idle watch on a new run"
    pass "notifier end-to-end: settled completion preserves a newer prompt"

    # Codex /review emits no native stop. Once its pane settles, the sweep must
    # remove the running rendering first, synthesize the normal completion
    # (🟢 + toast), and arm the same idle watch as a native stop. If the
    # completed review remains untouched, that watch later replaces 🟢 with 🥱.
    printf '%s' "codex review findings" > "$state_dir/%3.pane_content"
    review_fp="$(printf '%s\n' "codex review findings" | cksum)"
    printf '%s' "$review_fp" > "$state_dir/@2.@code_notify_settle_fp"
    printf '%s' "1000" > "$state_dir/@2.@code_notify_settle_since"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled" \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        CODE_NOTIFY_NOTIFIER_PATH="$NOTIFIER" TMUX_SETTLE_SECONDS=0 \
        tmux_agent_exit_sweep \
        || fail "settled codex review should synthesize completion cleanly"
    [[ "$(window_name)" == "🟢 zsh" ]] \
        || fail "settled review should replace running with the completion badge (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_running" ]] \
        || fail "settled review completion should remove the running epoch"
    iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
    [[ "$iw" == "%3 "*" codex "* ]] \
        || fail "settled review completion should arm the codex idle watch (got: $iw)"
    grep -q "Task Complete" "$tn_log" \
        || fail "settled review should deliver a task-complete notification"

    review_idle_fp="$(printf '%s\n' "codex review findings" | cksum)"
    printf '%s' "%3 1000 $review_idle_fp stable codex code-notify" \
        > "$state_dir/@2.@code_notify_idle_watch"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$tn_log"
    # Even a still-focused window is demonstrably untouched: the idle watch
    # held through the full threshold, so 🥱 must replace 🟢 rather than taking
    # the generic waiting-event visible-window skip.
    export FAKE_TMUX_BADGE_INFO='@2|on|1|zsh'
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_NOTIFIER_PATH="$NOTIFIER" tmux_agent_exit_sweep \
        || fail "settled review idle sweep should run cleanly"
    for _ in $(seq 1 100); do [[ "$(window_name)" == "🥱 zsh" ]] && break; sleep 0.1; done
    [[ "$(window_name)" == "🥱 zsh" ]] \
        || fail "review idle reminder should replace the completion badge (got: $(window_name))"
    for _ in $(seq 1 100); do grep -q "Idle" "$tn_log" 2>/dev/null && break; sleep 0.1; done
    grep -q "Idle" "$tn_log" \
        || fail "untouched review should deliver the later idle notification"
    export FAKE_TMUX_BADGE_INFO='@2|on|0|zsh'
    rm -f "$HOME/.codex/hooks.json" "$state_dir"/* "$state_dir"/.@code_notify_* \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: settled review completes, then idles"

    # A codex stop arms the post-completion idle watch (codex sends nothing
    # further once a turn ends), and a pane that then holds still past the
    # threshold delivers a synthetic idle_prompt back through the real
    # notifier: 🥱 badge on the origin window, toast via terminal-notifier.
    rm -f "$state_dir"/* "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    printf '%s' "codex done, waiting" > "$state_dir/%3.pane_content"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$NOTIFIER" stop codex testproj > /dev/null 2>&1 \
        || fail "notifier.sh stop codex (idle-arm) should exit cleanly"
    iw="$(cat "$state_dir/@2.@code_notify_idle_watch" 2>/dev/null)"
    [[ "$iw" == "%3 "*" codex testproj" ]] \
        || fail "codex stop should arm the idle watch with agent and project (got: $iw)"
    # Backdate past the threshold and run the sweep exactly as the timer
    # would (fresh process, script dispatch); the synthetic notification
    # must come back through the real notifier. A tracked agent PID rides
    # along: the nudge runs outside codex's process tree and cannot
    # re-resolve it, so its stop-pipeline cleanup must leave it in place —
    # dropping it here is what orphaned 🥱 badges after the agent exited.
    idle_fp="$(printf '%s\n' "codex done, waiting" | cksum)"
    printf '%s' "%3 1000 $idle_fp stable codex testproj" > "$state_dir/@2.@code_notify_idle_watch"
    sleep 300 &
    idle_agent_pid=$!
    printf '%s' "$idle_agent_pid" > "$state_dir/@2.@code_notify_agent_pid"
    rm -f "$state_dir/.@code_notify_agent_exit_sweep_scheduled"
    : > "$tn_log"
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" agent-exit-sweep \
        || fail "idle sweep should run cleanly"
    for _ in $(seq 1 100); do [[ "$(window_name)" == "🥱 zsh" ]] && break; sleep 0.1; done
    [[ "$(window_name)" == "🥱 zsh" ]] \
        || fail "the synthetic idle nudge should badge the window (got: $(window_name))"
    [[ ! -f "$state_dir/@2.@code_notify_idle_watch" ]] \
        || fail "the fired idle watch should be consumed"
    # The badge is written just before the toast is sent; wait for the
    # detached delivery separately.
    for _ in $(seq 1 100); do grep -q "Codex" "$tn_log" 2>/dev/null && break; sleep 0.1; done
    grep -q "Codex" "$tn_log" \
        || fail "the synthetic nudge should reach terminal-notifier"
    [[ "$(cat "$state_dir/@2.@code_notify_agent_pid" 2>/dev/null)" == "$idle_agent_pid" ]] \
        || fail "the synthetic nudge must keep the exit tracking for its 🥱 badge"
    # The user quits codex with the 🥱 badge up: the next sweep tick is the
    # only path that can clear it, and only the retained PID lets it.
    kill "$idle_agent_pid" 2>/dev/null || true
    wait "$idle_agent_pid" 2>/dev/null || true
    CODE_NOTIFY_TAIL_SYNC=1 CODE_NOTIFY_SKIP_USAGE_CHECK=1 \
        PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$ROOT_DIR/lib/code-notify/utils/tmux.sh" agent-exit-sweep \
        || fail "post-exit sweep should run cleanly"
    [[ "$(window_name)" == "zsh" ]] \
        || fail "exiting the agent must clear the 🥱 badge (got: $(window_name))"
    rm -f "$state_dir"/* "$state_dir"/.@code_notify_* \
        "$HOME/.claude/notifications/state"/* 2>/dev/null || true
    printf '%s' "zsh" > "$state_dir/@2.window_name"
    pass "notifier end-to-end: codex stop arms the idle watch and the nudge fires"
fi

echo "All tmux badge tests passed"
