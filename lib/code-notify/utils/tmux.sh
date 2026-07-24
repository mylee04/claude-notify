#!/bin/bash

# tmux click-to-focus support for Code-Notify (macOS).
#
# When a notification originates from a process running inside a tmux pane
# (Claude Code, Codex, Gemini CLI hooks inherit TMUX/TMUX_PANE), these
# helpers build a shell command that jumps back to that exact pane when the
# user clicks the notification.
#
# The generated command runs from the notifier app's context (/bin/sh -c,
# minimal PATH, no attached tmux client), so it embeds the absolute tmux
# path, the server socket, and performs an explicit client lookup.

# Quote a value for safe single-quoted embedding in a shell command,
# escaping embedded single quotes: a'b -> 'a'\''b'
tmux_focus_shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}

# Escape a string for embedding inside a tmux double-quoted command argument
# and return it wrapped in those double quotes. When a hook fires, tmux
# re-parses the stored command and, inside "...", processes \, " and $ itself —
# so shell-quoting the inner values (which only protects the innermost
# /bin/sh) is not enough: a ", \ or $ in an embedded path would break tmux's
# parse before /bin/sh ever sees the safely-quoted value. Escape backslashes
# first so the escapes we add are not re-escaped. run-shell additionally
# format-expands its argument when it executes, so # must be doubled too —
# otherwise a #{...} or #( in an embedded path is rewritten by format
# expansion before /bin/sh sees it.
tmux_focus_cmd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    value="${value//\#/##}"
    printf '"%s"' "$value"
}

# Whether the current process is running inside a usable tmux pane.
tmux_focus_available() {
    [[ -n "${TMUX:-}" ]] && [[ -n "${TMUX_PANE:-}" ]] && command -v tmux &> /dev/null
}

# Print "session_id window_id pane_id" for the current pane.
# Uses stable tmux IDs ($N @N %N) that survive window renumbering.
tmux_focus_capture_target() {
    if ! tmux_focus_available; then
        return 1
    fi
    tmux display-message -p -t "$TMUX_PANE" '#{session_id} #{window_id} #{pane_id}' 2>/dev/null
}

# Build the command a notifier should run on click to focus the originating
# tmux session/window/pane. Takes an optional macOS bundle ID to activate.
# Prints nothing and returns 1 when not running inside tmux.
tmux_focus_build_command() {
    local bundle_id="${1:-}"
    local target session_id window_id pane_id tmux_bin socket_path

    target=$(tmux_focus_capture_target) || return 1
    read -r session_id window_id pane_id <<< "$target"

    # Only stable tmux IDs get embedded in the command; reject anything else.
    # Patterns live in variables so the \$ escape survives both bash and zsh.
    local session_re='^\$[0-9]+$' window_re='^@[0-9]+$' pane_re='^%[0-9]+$'
    if [[ ! "$session_id" =~ $session_re ]] ||
        [[ ! "$window_id" =~ $window_re ]] ||
        [[ ! "$pane_id" =~ $pane_re ]]; then
        return 1
    fi

    tmux_bin=$(command -v tmux)
    socket_path="${TMUX%%,*}"
    if [[ -z "$tmux_bin" ]] || [[ -z "$socket_path" ]]; then
        return 1
    fi

    local q_tmux q_socket q_session q_window q_pane q_bundle
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_session=$(tmux_focus_shell_quote "$session_id")
    q_window=$(tmux_focus_shell_quote "$window_id")
    q_pane=$(tmux_focus_shell_quote "$pane_id")

    # t() wraps tmux with the captured socket. The client lookup prefers the
    # most recently active client attached to the target session, then falls
    # back to the most recently active client overall and switches it over.
    # Append system dirs so head/sort/cut/open resolve even under the
    # notifier app's minimal PATH; appending keeps any existing PATH first.
    local cmd
    cmd="PATH=\"\${PATH:-}:/usr/bin:/bin\"; export PATH; "
    cmd+="t() { $q_tmux -S $q_socket \"\$@\" 2>/dev/null; }; "
    cmd+="t select-window -t $q_window; "
    cmd+="t select-pane -t $q_pane; "
    cmd+="c=\$(t list-clients -t $q_session -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); "
    cmd+="if [ -z \"\$c\" ]; then c=\$(t list-clients -F \"#{client_activity} #{client_name}\" | sort -rn | head -n 1 | cut -d \" \" -f 2-); fi; "
    cmd+="if [ -n \"\$c\" ]; then t switch-client -c \"\$c\" -t $q_session; fi"

    if [[ -n "$bundle_id" ]]; then
        q_bundle=$(tmux_focus_shell_quote "$bundle_id")
        cmd+="; open -b $q_bundle"
    fi

    printf '%s' "$cmd"
}

# --- tmux window badging ---------------------------------------------------
#
# When a notification fires, the originating tmux window's name gets the event
# icon prepended ("🟢 zsh"), so pending work is visible in the status line
# from anywhere in the session. Badge state lives in tmux window options
# (@code_notify_orig_name, @code_notify_autorename, @code_notify_badged_name,
# @code_notify_clear_mode) so it survives across hook processes and clears from
# any of them. How a badge clears depends on its saved clear mode ("glance" or
# "engage" — see tmux_badge_set); the glance paths are:
#   - visiting the window: a server hook (session-window-changed /
#     client-session-changed, installed lazily when the first badge is set)
#     sweeps the moment the window becomes active — whether the user switched
#     manually, clicked the notification, or used terminal-notifier -focusLast
#     (all run select-window / switch-client, which fire the hook)
#   - the next notification also sweeps, so badges converge even on a tmux
#     server that predates the hook install
#   - clicking the notification additionally rides the notifier's own click
#     handler (macOS -execute); Linux notify-send has no click hook
#
# The hook is retired the moment the last badge clears, so idle window
# switching (no badge pending — the common case) spawns nothing; the next badge
# re-arms it. Cost is therefore paid only while a badge is actually outstanding.
#
# rename-window implicitly turns off automatic-rename for the window, so the
# original setting is saved alongside the name and restored on clear.
#
# A third clear mode, "running", marks a window whose agent is still working
# (set on UserPromptSubmit, replaced by the event badge when the agent stops).
# Unlike event badges it is applied even to the visible window — the user just
# submitted a prompt there and wants the marker in place before switching away
# — and it never clears on glance: only the terminating event, the next
# prompt-submit, or staleness (older than TMUX_RUNNING_TTL, the safety net for
# runs that end without any hook, e.g. an Escape-interrupt) clears it. The
# start epoch lives in @code_notify_running. See the running-indicator section
# below for the opt-in spinner variant, which animates in the status line
# without renaming at all.
#
# A manual rename while badged always wins: badge-set adopts the new name as
# the original, and clear keeps it (leaving automatic-rename off, as a manual
# rename implies) instead of restoring the stale saved name. Rename detection
# compares against the exact badged name saved at badge time
# (@code_notify_badged_name) — a suffix match alone would mistake a rename
# like "zsh" -> "api zsh" for a badged form of "zsh". Badges written by older
# versions lack the option, so a "<something> <original>" suffix match remains
# as the fallback for them only.

TMUX_BADGE_DISABLED_FILE="$HOME/.claude/notifications/tmux-badge-disabled"
TMUX_BADGE_VISIBLE_ENABLED_FILE="$HOME/.claude/notifications/tmux-badge-visible-enabled"

# Absolute path to this library, so the tmux focus hook can re-invoke it as a
# script (bash <this> badge-sweep). Resolved at source time.
TMUX_BADGE_LIB_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Fixed array index for our server hooks: reusing one index means re-setting on
# every badge overwrites in place (no stacking) while leaving the user's own
# hooks at other indices untouched. Overridable only for tests.
TMUX_BADGE_HOOK_INDEX="${CODE_NOTIFY_TMUX_HOOK_INDEX:-8471}"

tmux_badge_enabled() {
    [[ "${CODE_NOTIFY_TMUX_BADGE:-}" != "false" ]] && [[ ! -f "$TMUX_BADGE_DISABLED_FILE" ]]
}

# Whether event badges should land even on the window the user is currently
# looking at (`cn badge-visible on`). Off by default: waiting-type events skip
# the visible window so an idle reminder can't wipe or restack a badge the
# user has not engaged away yet. The env var (when set) wins over the flag
# file, so a single session can force the behavior on or off without touching
# persistent state.
tmux_badge_visible_enabled() {
    if [[ -n "${CODE_NOTIFY_TMUX_BADGE_VISIBLE:-}" ]]; then
        [[ "$CODE_NOTIFY_TMUX_BADGE_VISIBLE" == "true" ]]
        return
    fi
    [[ -f "$TMUX_BADGE_VISIBLE_ENABLED_FILE" ]]
}

# Install the server hook that clears a window's badge the instant it becomes
# active, so a manually switched-to (or focus-jumped) window sheds its badge
# without waiting for the next notification. Idempotent: the fixed index makes
# a repeat set overwrite rather than stack. session-window-changed covers
# switching windows within a session; client-session-changed covers switching
# between attached sessions; client-attached covers reattaching to a session
# whose active window was badged while detached (badge-set only skips the
# active window of an *attached* session). run-shell -b keeps tmux responsive.
#
# The hook embeds an absolute lib path that can outlive the install (uninstall
# while a badge is pending), and a dangling hook would then error on every
# window switch forever — the sweep that retires it can no longer run. So the
# hook guards itself: if the lib is gone, it unsets both hooks and exits
# silently. The tmux binary and socket are embedded for that self-retire
# because run-shell's environment guarantees neither PATH nor $TMUX. The whole
# run-shell argument is tmux-quoted (tmux_focus_cmd_quote) on top of the inner
# shell-quoting, so an embedded path containing ", \ or $ survives tmux's
# re-parse of the hook when it fires.
tmux_badge_install_focus_hook() {
    [[ -n "$TMUX_BADGE_LIB_PATH" ]] && [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 0
    local tmux_bin socket_path q_lib q_tmux q_socket idx retire inner hook_cmd
    tmux_bin=$(command -v tmux) || return 0
    socket_path="${TMUX%%,*}"
    [[ -n "$socket_path" ]] || return 0
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    idx="$TMUX_BADGE_HOOK_INDEX"
    retire="$q_tmux -S $q_socket set-hook -gu 'session-window-changed[$idx]'; "
    retire+="$q_tmux -S $q_socket set-hook -gu 'client-session-changed[$idx]'; "
    retire+="$q_tmux -S $q_socket set-hook -gu 'client-attached[$idx]'"
    inner="if [ -f $q_lib ]; then bash $q_lib badge-sweep; else $retire; fi"
    hook_cmd="run-shell -b $(tmux_focus_cmd_quote "$inner")"
    tmux set-hook -g "session-window-changed[$idx]" "$hook_cmd" 2>/dev/null
    tmux set-hook -g "client-session-changed[$idx]" "$hook_cmd" 2>/dev/null
    tmux set-hook -g "client-attached[$idx]" "$hook_cmd" 2>/dev/null
}

# Retire the focus hook. Called when the last badge clears, so idle window
# switching (the common case — no badge pending) costs nothing until the next
# badge re-arms it.
tmux_badge_uninstall_focus_hook() {
    tmux set-hook -gu "session-window-changed[$TMUX_BADGE_HOOK_INDEX]" 2>/dev/null
    tmux set-hook -gu "client-session-changed[$TMUX_BADGE_HOOK_INDEX]" 2>/dev/null
    tmux set-hook -gu "client-attached[$TMUX_BADGE_HOOK_INDEX]" 2>/dev/null
}

# Whether a live window name is a badged form of the saved original: exactly
# the name written at badge time, or — for badges from versions predating
# @code_notify_badged_name — anything ending in " <original>".
tmux_badge_name_is_badged() {
    local name="$1" orig_name="$2" badged_name="$3"
    if [[ -n "$badged_name" ]]; then
        [[ "$name" == "$badged_name" ]]
    else
        [[ "$name" == *" $orig_name" ]]
    fi
}

# Prepend an icon to the originating window's name. Idempotent: a repeat
# notification swaps the icon instead of stacking a second one. Windows the
# user is currently looking at (active window of an attached session) are
# skipped — the badge would be noise there.
#
# The optional second argument records how this badge clears (stored in
# @code_notify_clear_mode so the sweep, which runs agent-blind, can honour it):
#   - "glance" (default): cleared by the sweep/focus hook the moment the user
#     visits the window
#   - "engage": only an owning-agent work signal clears it (prompt-submit for
#     Claude/Codex, first PreToolUse for Antigravity); the sweep skips it and no
#     focus hook is armed, so it survives glances — even glances triggered by
#     another agent's badge activity on the same server
#   - "running": the agent-is-working marker (see tmux_running_start). Set
#     even on the visible window — the user just submitted a prompt there and
#     the marker should be in place before they switch away. Cleared by the
#     terminating event (tmux_running_stop), the next prompt-submit, or the
#     sweep once stale; never by a mere glance.
# tmux_badge_apply is the badge state machine on an already-resolved window;
# tmux_badge_set below wraps it with target capture and the visibility gate
# for callers that haven't queried the window yet.
tmux_badge_apply() {
    local window_id="$1" autorename="$2" name="$3" icon="$4" clear_mode="$5"
    local orig_name badged_name current_mode
    orig_name=$(tmux show-options -wqv -t "$window_id" @code_notify_orig_name 2>/dev/null)
    badged_name=$(tmux show-options -wqv -t "$window_id" @code_notify_badged_name 2>/dev/null)
    if [[ -n "$orig_name" ]] && [[ "$name" == "$icon $orig_name" ]] &&
        [[ "$badged_name" == "$name" ]]; then
        current_mode=$(tmux show-options -wqv -t "$window_id" @code_notify_clear_mode 2>/dev/null)
        if [[ "$current_mode" == "$clear_mode" ]]; then
            # A burst of identical subagent events already has exactly the
            # requested state. The first writer completed tracking/hook setup
            # before releasing this same lock, so later writers need no tmux
            # mutations at all.
            return 0
        fi
    fi
    if [[ -z "$orig_name" ]]; then
        orig_name="$name"
        tmux set-option -w -t "$window_id" @code_notify_orig_name "$orig_name" 2>/dev/null || return 1
        tmux set-option -w -t "$window_id" @code_notify_autorename "${autorename:-off}" 2>/dev/null
    elif [[ "$name" != "$orig_name" ]] &&
        ! tmux_badge_name_is_badged "$name" "$orig_name" "$badged_name"; then
        # Badged, but the current name is neither the saved original nor the
        # badged form of it: the user renamed the window while it was badged.
        # Their name becomes the new original, and automatic-rename is pinned
        # off — restoring the pre-badge "on" would rename right past their
        # choice.
        orig_name="$name"
        tmux set-option -w -t "$window_id" @code_notify_orig_name "$orig_name" 2>/dev/null || return 1
        tmux set-option -w -t "$window_id" @code_notify_autorename off 2>/dev/null
    fi
    tmux rename-window -t "$window_id" "$icon $orig_name" 2>/dev/null || return 1
    tmux set-option -w -t "$window_id" @code_notify_badged_name "$icon $orig_name" 2>/dev/null
    tmux set-option -w -t "$window_id" @code_notify_clear_mode "$clear_mode" 2>/dev/null
    tmux_agent_exit_track "$window_id"
    # A glance badge now exists, so arm the focus hook that clears it on the
    # next visit. Cheap and idempotent, so setting it per badge is fine. Engage
    # and running badges don't arm it — engage clears on prompt-submit, running
    # on the terminating event, and the sweep skips both anyway.
    # CODE_NOTIFY_TMUX_FOCUS_HOOK=false suppresses arming entirely.
    if [[ "$clear_mode" == "glance" ]] && [[ "${CODE_NOTIFY_TMUX_FOCUS_HOOK:-}" != "false" ]]; then
        tmux_badge_install_focus_hook
    fi
    return 0
}

# Resolve the caller's target once before locking. The original target is kept
# for the state capture under the lock: a pane target retains tmux's session
# context for linked windows, while the resolved window id provides a stable
# per-window lock key.
tmux_badge_resolve_target() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        tmux_focus_available || return 1
        target="$TMUX_PANE"
    else
        { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 1
    fi
    local window_id
    window_id=$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null) || return 1
    [[ "$window_id" =~ ^@[0-9]+$ ]] || return 1
    TMUX_BADGE_TARGET="$target"
    TMUX_BADGE_WINDOW_ID="$window_id"
    return 0
}

# Badge a resolved target while the caller holds its transition lock. Keeping
# the decorated-name capture inside the lock prevents a concurrent clear from
# turning a stale "💬 name" capture into the next saved original.
tmux_badge_set_locked() {
    local icon="$1"
    local clear_mode="${2:-glance}"
    local target="$3"
    local visible_action="${4:-skip}"
    local expected_window_id="${5:-}"

    # window_name goes last so embedded "|" cannot shift the other fields.
    local info window_id autorename visible name
    info=$(tmux display-message -p -t "$target" \
        '#{window_id}|#{automatic-rename}|#{&&:#{window_active},#{session_attached}}|#{window_name}' 2>/dev/null) || return 1
    IFS='|' read -r window_id autorename visible name <<< "$info"

    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 1
    if [[ -n "$expected_window_id" ]] && [[ "$window_id" != "$expected_window_id" ]]; then
        return 1
    fi
    # Running markers land even on the visible window (the user just submitted
    # a prompt there). What an event badge does there depends on
    # visible_action ($4):
    #   - "skip" (default): don't touch the window. Waiting-type events (idle
    #     prompt, permission, mid-run subagent/task events) would be noise
    #     where the user is already looking, and must leave any existing badge
    #     alone — an idle reminder firing while the user reads the output must
    #     not wipe or restack a "done" badge they have not engaged away yet.
    #   - "apply": badge it like any hidden window. Terminal events (stop,
    #     error) use this so completion is glanceable even on the focused
    #     window, and the apply inherently replaces a stale waiting badge
    #     whose turn the user just watched end (an approval answered inline
    #     leaves one — no new prompt, so no engage-clear).
    if [[ "$visible" == "1" ]] && [[ "$clear_mode" != "running" ]] &&
        [[ "$visible_action" != "apply" ]]; then
        return 0
    fi

    tmux_badge_apply "$window_id" "$autorename" "$name" "$icon" "$clear_mode"
}

# Resolve a target and badge it. The optional third argument targets a
# specific window (or pane) instead of the caller's own pane, for callers
# that iterate windows without running in them (e.g. the spinner-off fallback
# re-badging every running window). Badge mutations share the running-state
# transition lock so concurrent Claude team hooks cannot interleave a clear
# and apply or turn a decorated name into the next saved original.
tmux_badge_set() {
    local icon="$1"
    local clear_mode="${2:-glance}"
    local target="${3:-}"
    local visible_action="${4:-skip}"
    [[ -n "$icon" ]] || return 1
    tmux_badge_enabled || return 1
    tmux_badge_resolve_target "$target" || return 1
    target="$TMUX_BADGE_TARGET"
    local window_id="$TMUX_BADGE_WINDOW_ID" transition_lock transition_token status
    tmux_running_transition_lock_acquire "$window_id" || return 1
    transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    if tmux_badge_set_locked "$icon" "$clear_mode" "$target" "$visible_action" "$window_id"; then
        status=0
    else
        status=$?
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    return "$status"
}

# Apply a terminal badge only while the originating window is still stopped.
# tmux_running_stop releases the transition lock before the notifier performs
# delivery, so a queued successor can begin in that gap even when Stop won the
# earlier race and consumed no hint. Re-taking the same per-window lock makes
# the final check and badge application atomic with prompt submission: either
# completion lands first and the prompt replaces it, or the fresh running
# marker lands first and completion leaves it alone.
tmux_badge_set_unless_running() {
    local icon="$1"
    local clear_mode="${2:-glance}"
    local target="${3:-}"
    local visible_action="${4:-skip}"
    [[ -n "$icon" ]] || return 1
    tmux_badge_enabled || return 1
    tmux_badge_resolve_target "$target" || return 1
    target="$TMUX_BADGE_TARGET"
    local window_id="$TMUX_BADGE_WINDOW_ID" transition_lock transition_token since now status
    tmux_running_transition_lock_acquire "$window_id" || return 1
    transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
    now=$(date +%s)
    if [[ "$since" =~ ^[0-9]+$ ]] && (( now - since < TMUX_RUNNING_TTL )); then
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
        return 0
    fi
    if tmux_badge_set_locked "$icon" "$clear_mode" "$target" "$visible_action" "$window_id"; then
        status=0
    else
        status=$?
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    return "$status"
}

# Restore a badged window: original name back, automatic-rename re-enabled if
# it was on, badge options removed. No-op when the window carries no badge.
# If the user renamed the window while badged, their name wins: keep it (and
# leave automatic-rename off, as a manual rename implies) and only drop the
# badge state.
# Clear badge state while the caller holds the window transition lock.
tmux_badge_clear_locked() {
    local window_id="$1"
    local orig_name autorename badged_name current
    orig_name=$(tmux show-options -wqv -t "$window_id" @code_notify_orig_name 2>/dev/null)
    [[ -n "$orig_name" ]] || return 0
    autorename=$(tmux show-options -wqv -t "$window_id" @code_notify_autorename 2>/dev/null)
    badged_name=$(tmux show-options -wqv -t "$window_id" @code_notify_badged_name 2>/dev/null)
    current=$(tmux display-message -p -t "$window_id" '#{window_name}' 2>/dev/null)
    # Restore when the window still looks badged (the exact name written at
    # badge time) or already carries the original name; an empty result means
    # the name query failed, where restoring is the safer default.
    if [[ -z "$current" ]] || [[ "$current" == "$orig_name" ]] ||
        tmux_badge_name_is_badged "$current" "$orig_name" "$badged_name"; then
        tmux rename-window -t "$window_id" "$orig_name" 2>/dev/null
        if [[ "$autorename" == "on" ]]; then
            tmux set-option -w -t "$window_id" automatic-rename on 2>/dev/null
        fi
    fi
    tmux set-option -wu -t "$window_id" @code_notify_orig_name 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_autorename 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_badged_name 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_clear_mode 2>/dev/null
    tmux_agent_exit_untrack "$window_id"
    # A cleared badge means the user acknowledged this window (glance-clear
    # visit, notification click, or the cleanup paths), so a pending
    # post-completion idle nudge is moot.
    tmux set-option -wu -t "$window_id" @code_notify_idle_watch 2>/dev/null
}

tmux_badge_clear() {
    local window_id="$1"
    [[ "$window_id" =~ ^@[0-9]+$ ]] || return 0
    local transition_lock transition_token
    tmux_running_transition_lock_acquire "$window_id" || return 0
    transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    # A direct clear is an acknowledgement even if another hook already
    # removed the visible badge; always cancel its pending idle nudge.
    tmux set-option -wu -t "$window_id" @code_notify_idle_watch 2>/dev/null
    tmux_badge_clear_locked "$window_id"
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
}

# Clear badges the user has implicitly acknowledged: any badged window that is
# now the active window of an attached session was visited without clicking
# the notification. Runs on every notification, so stale badges converge even
# though no daemon watches window focus. Intentionally not gated on
# tmux_badge_enabled — badges left over from before the feature was disabled
# should still be cleaned up.
#
# Engage-clear badges (@code_notify_clear_mode=engage) are skipped entirely:
# they clear on the owning agent's next work signal, and sweeping them here would
# reintroduce glance-clearing through another agent's badge activity. They are
# also not counted toward keeping the focus hook alive — the hook only serves
# glance badges. Badges with no saved mode (written by older versions) are
# treated as glance so they still converge.
tmux_badge_sweep() {
    # Only needs to be inside a tmux server with a tmux binary; unlike badge-set
    # it never touches the current pane, so it must not require TMUX_PANE (the
    # focus hook's run-shell context may not set it).
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local window_id visible mode orig remaining=0
    while IFS='|' read -r window_id visible mode orig; do
        [[ -n "$orig" ]] || continue
        # Engage badges clear on the owning agent's next work signal; running
        # markers clear on the terminating event (or staleness, handled by the
        # running sweep below). Neither may clear on a mere glance, and neither
        # counts toward keeping the focus hook alive — it only serves glance badges.
        if [[ "$mode" == "engage" ]] || [[ "$mode" == "running" ]]; then continue; fi
        if [[ "$visible" == "1" ]]; then
            tmux_badge_clear "$window_id"   # clear always drops the orig-name option
        else
            remaining=$((remaining + 1))    # badged but still hidden
        fi
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{&&:#{window_active},#{session_attached}}|#{@code_notify_clear_mode}|#{@code_notify_orig_name}' 2>/dev/null)
    # With no badge left anywhere, retire the focus hook so it stops spawning a
    # sweep on every window switch until the next badge re-arms it. Kept as an
    # explicit if (not `&& ...`) so the function still returns 0 when a badge
    # remains — a trailing false would trip callers running under `set -e`.
    if [[ "$remaining" -eq 0 ]]; then
        tmux_badge_uninstall_focus_hook
    fi
    # Piggyback stale-running convergence on every sweep: a run that died
    # without a hook sheds its marker (and the spinner's 1s redraw interval)
    # the next time any badge activity happens on this server.
    tmux_running_sweep_stale
}

# Clear the badge on the window the caller is running in. This is the
# "engage-clear" path: an agent that emits a prompt-submit signal (Claude's
# UserPromptSubmit) runs this to drop the badge the moment the user hands the
# window more work — unlike the sweep/focus hook, which clear merely on glance.
# Pane-local (needs TMUX_PANE), so it resolves the current window and clears
# just that one.
tmux_badge_clear_current() {
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    tmux_badge_clear "$window_id"
}

# --- running indicator -------------------------------------------------------
#
# UserPromptSubmit marks the originating window as "agent working"
# (tmux_running_start); the terminating event — stop, input needed, error —
# unmarks it (tmux_running_stop). The start epoch lives in the window option
# @code_notify_running, which doubles as the staleness guard: an agent that
# ends without any hook firing (Escape-interrupt, crash, cn off mid-run)
# leaves the epoch behind, and tmux_running_sweep_stale — run from every badge
# sweep and from a one-shot timer parked on the tmux server while markers are
# outstanding (tmux_running_schedule_sweep) — retires markers older than
# TMUX_RUNNING_TTL. The prompt path only arms that timer; it never sweeps
# itself, because it runs synchronously on every prompt submission.
#
# Two renderings:
#   - default: a static icon (TMUX_RUNNING_ICON) prepended to the window name
#     via the badge machinery, clear mode "running". Costs two renames per
#     agent turn and nothing in between.
#   - opt-in spinner (cn spinner on / CODE_NOTIFY_TMUX_SPINNER=true): no
#     rename at all. A format snippet prepended to window-status-format (and
#     -current-format) picks a moon frame from wall-clock seconds —
#     #{T:@code_notify_clock} is now-as-%s, mod 8 indexes the frames — so tmux
#     animates it during its own status redraw with no external process. The
#     snippet renders only while the window's @code_notify_running epoch is
#     fresher than the TTL, so a stale marker disappears from the status line
#     by itself even before a sweep drops the option. status-interval is
#     lowered to 1 while armed (a frame per second) and the user's value is
#     restored when the last running window clears, so the idle cost is zero.

# Safety net for runs that end without a hook. Seconds; default 4 hours.
TMUX_RUNNING_TTL="${CODE_NOTIFY_TMUX_RUNNING_TTL:-14400}"
TMUX_RUNNING_ICON="${CODE_NOTIFY_TMUX_RUNNING_ICON:-🌕}"
TMUX_SPINNER_ENABLED_FILE="$HOME/.claude/notifications/tmux-spinner-enabled"
# Seconds between exit checks while an agent owns a running marker or event
# badge. Set to 0 to rely on the TTL safety net only.
TMUX_AGENT_EXIT_POLL_SECONDS="${CODE_NOTIFY_TMUX_AGENT_EXIT_POLL_SECONDS:-5}"
# Seconds between #{window_activity} checks while a window is paused for an
# input/approval request. Claude Code fires no hook when the user answers an
# approval dialog — the earliest one is the approved tool's PostToolUse,
# minutes away for a long command — but answering repaints the agent's TUI,
# which bumps the window's activity clock past the pause epoch. Set to 0 to
# disable and rely on the tool lifecycle hooks alone.
TMUX_RESUME_POLL_SECONDS="${CODE_NOTIFY_TMUX_RESUME_POLL_SECONDS:-2}"
# How long an unanswered request keeps the poll alive. A dialog left open
# overnight should not tick a timer every 2 seconds forever; past this age the
# chain stops and the lifecycle hooks remain the resume path.
TMUX_RESUME_POLL_TTL="${CODE_NOTIFY_TMUX_RESUME_POLL_TTL:-900}"
# Detects an on-screen approval/input dialog in the watched pane's captured
# content. Content fingerprints alone cannot tell an unanswered dialog from an
# answered one when something else in the pane animates — a backgrounded shell
# command's flashing dot or ticking timer repaints the pane on every poll even
# though the user has not approved anything. While the dialog is detected the
# poll never resumes; when the detection clears, the fingerprint heuristic
# takes over (the dialog vanishing is not itself an answer — Ctrl+O hides it
# behind the transcript view).
#
# Detection requires BOTH grep -E patterns to match somewhere in the capture:
# the question prompt (TMUX_DIALOG_MARKERS) AND a numbered Yes/No selector row
# (TMUX_DIALOG_OPTIONS). The question line alone is not enough — ordinary model
# output or transcript can open a line with "Do you want …", including behind a
# bullet or box border, and the question pattern is line-anchored only past
# leading non-letters, so it would match that too. Pairing it with the Yes/No
# option row (which a real permission dialog always renders and prose almost
# never places alongside the question) is what keeps casual "Do you want …"
# text from freezing the badge. This trades a small false-negative risk (if a
# future Claude Code changes the option wording the dialog stops being
# detected and the fingerprint heuristic resumes early) for far fewer false
# positives; that direction is deliberate — an early spinner self-corrects on
# the next hook, whereas a frozen "waiting" badge is the bug this whole path
# exists to prevent.
#
# The default question pattern covers a tool approval ("Do you want to
# …?"), plan-mode approval ("Would you like to proceed?"), Antigravity's
# file-write approval ("Allow creation of this file?" — anchored like the
# others but requiring the question mark, since prose opens lines with
# "Allow" far more often than with "Do you want"), and Antigravity's
# subagent approval ("research needs approval for Read" — unanchored, the
# subagent's name precedes it); the selector requirement is what lets the
# marker set stay this permissive without re-admitting prose false
# positives. The selector set pairs the numbered Yes/No row with
# Antigravity's keybinding row ("ctrl+k approve · alt+j manage"), which its
# subagent dialogs render instead of numbered options. AskUserQuestion
# needs no coverage here: it pauses via PreToolUse without the watch flag,
# so it resumes through the tool lifecycle hooks and never reaches this
# poll.
#
# These patterns serve two consumers: the resume poll below (is the pause
# still unanswered?) and the approval-dialog watch (see
# TMUX_DIALOG_WATCH_AGENTS), which detects pauses that no hook announced.
#
# A residual false positive remains: prose that places a "Do you want …?" line
# and a "N. Yes"/"N. No" list item in the same visible pane. Its cost is
# bounded and mild — the approved tool's PostToolUse hook still resumes the
# indicator (the poll TTL does NOT resume anything; it only stops polling), so
# the worst case is the indicator staying in the waiting state until the
# pending tool completes, not "stuck forever".
#
# Either pattern set empty disables its half (an empty TMUX_DIALOG_MARKERS
# turns detection off entirely; an empty TMUX_DIALOG_OPTIONS falls back to
# question-only matching). The `-` (not `:-`) expansion makes an explicit
# empty value stick instead of reverting to the default.
TMUX_DIALOG_MARKERS="${CODE_NOTIFY_TMUX_DIALOG_MARKERS-^[^A-Za-z]*(Do you want|Would you like|Allow .*\?)|needs approval for}"
TMUX_DIALOG_OPTIONS="${CODE_NOTIFY_TMUX_DIALOG_OPTIONS-^[^0-9A-Za-z]*[0-9]+\.[[:space:]]+(Yes|No)([[:space:],.]|$)|ctrl\+k[[:space:]]+approve}"
# Agents whose running marker additionally gets a settle watch
# (pipe-separated names as passed by the hooks). Codex finishes /review
# without emitting any turn-end hook, so its marker would otherwise stand
# until the 4-hour TTL; while a watched agent's marker is up, the agent-exit
# sweep compares the pane's rendered content across ticks and takes the
# marker down once it has held still for TMUX_SETTLE_SECONDS. Safe for
# agents whose working TUI repaints at least once per settle window (Codex
# ticks an elapsed-time counter every second); an agent that can look
# static while working must not be listed.
TMUX_SETTLE_AGENTS="${CODE_NOTIFY_TMUX_SETTLE_AGENTS:-codex}"
TMUX_SETTLE_SECONDS="${CODE_NOTIFY_TMUX_SETTLE_SECONDS:-15}"
# Agents with no native idle reminder (pipe-separated). Claude nudges by
# itself once it has been waiting for input for a while (its idle_prompt
# notification); Codex and Antigravity never do, so their windows can sit in
# "complete" state indefinitely with no follow-up. For agents listed here a
# turn end arms an idle watch: once the pane's rendered content has held
# still for TMUX_IDLE_SECONDS after the completion — the user never came
# back — one synthetic idle_prompt notification fires through the notifier.
# This is a tmux-derived approximation of the reminder, not native idle
# support: final UI repaints are absorbed until the pane settles, then any
# later repaint disarms the watch. Outside tmux nothing is watched at all. The
# watch rides the agent-exit sweep, so
# CODE_NOTIFY_TMUX_AGENT_EXIT_POLL_SECONDS=0 disables it as well.
TMUX_IDLE_AGENTS="${CODE_NOTIFY_TMUX_IDLE_AGENTS:-codex|antigravity}"
# Seconds of post-completion stillness before the nudge. 0 disables.
TMUX_IDLE_SECONDS="${CODE_NOTIFY_TMUX_IDLE_SECONDS:-60}"
# Agents whose running marker additionally gets an approval-dialog watch
# (pipe-separated names as passed by the hooks). Claude Code announces every
# permission prompt through its Notification hook, but Antigravity's hooks
# carry no "this call will pause" signal beyond what the PreToolUse banner
# reconstructs from its permission lists — and that covers run_command and
# MCP calls only. A file-write approval ("Allow creation of this file?") or
# a subagent's tool approval ("research needs approval for Read") pauses the
# turn with no event at all: no toast, and a running indicator that lies.
# For agents listed here, while the running marker is fresh the agent-exit
# sweep also captures the recorded pane; once the content has shown an
# approval dialog (TMUX_DIALOG_MARKERS/TMUX_DIALOG_OPTIONS) across
# consecutive ticks spanning TMUX_DIALOG_NOTIFY_SECONDS, one synthetic
# permission_prompt fires through the notifier — the same pipeline a
# predicted approval banner uses (badge, toast, input pause + resume poll).
# Claude must not be listed: its native Notification hook already covers
# every dialog, and a second toast would duplicate it.
TMUX_DIALOG_WATCH_AGENTS="${CODE_NOTIFY_TMUX_DIALOG_WATCH_AGENTS:-antigravity}"
# Seconds an unanswered dialog must stay on screen before the synthetic
# approval alert fires. The check rides the agent-exit poll, so the
# effective latency is the first tick past this age; an answer landing
# before that resets the watch silently — the user was already there.
# 0 disables the watch.
TMUX_DIALOG_NOTIFY_SECONDS="${CODE_NOTIFY_TMUX_DIALOG_NOTIFY_SECONDS:-5}"

tmux_running_enabled() {
    [[ "${CODE_NOTIFY_TMUX_RUNNING:-}" != "false" ]] && tmux_badge_enabled
}

# Hooks are normally launched through a short-lived shell, so $PPID is not
# necessarily the agent itself. Walk its ancestors and retain the process that
# actually owns the configured agent command. Once that process exits, the
# tmux marker is no longer meaningful even if the agent did not emit Stop
# (for example /exit, Ctrl-C, or a terminal close).
tmux_agent_exit_resolve_pid() {
    local agent="$1" pid="$2" info parent executable command hops=0
    [[ "$agent" =~ ^(claude|codex|gemini|antigravity|agy)$ ]] || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    while [[ "$pid" =~ ^[0-9]+$ ]] && (( hops < 12 )); do
        # ppid+comm come from one call (a space-embedding comm — an app
        # bundle path — would shift a combined three-field read); command
        # gets its own call so its embedded spaces cannot collide either.
        info=$(ps -o ppid= -o comm= -p "$pid" 2>/dev/null) || return 1
        read -r parent executable <<< "$info"
        executable="${executable%% *}"
        command=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
        # A hook command is commonly run as `sh -c ... codex`; its command
        # line mentions the agent even though that shell vanishes immediately.
        # Never track an interpreter wrapper — keep walking to the real agent.
        case "${executable##*/}" in
            sh|bash|zsh|dash|fish) command="" ;;
        esac
        case "$agent" in
            claude) [[ "$command" == *claude* || "$command" == *Claude* ]] && { printf '%s' "$pid"; return 0; } ;;
            codex) [[ "$command" == *codex* || "$command" == *Codex* ]] && { printf '%s' "$pid"; return 0; } ;;
            gemini) [[ "$command" == *gemini* || "$command" == *Gemini* ]] && { printf '%s' "$pid"; return 0; } ;;
            antigravity|agy) [[ "$command" == *antigravity* || "$command" == *Antigravity* || "$command" == *agy* ]] && { printf '%s' "$pid"; return 0; } ;;
        esac
        [[ "$parent" =~ ^[0-9]+$ ]] && [[ "$parent" != "$pid" ]] || return 1
        pid="$parent"
        hops=$((hops + 1))
    done
    return 1
}

tmux_agent_exit_untrack() {
    local window_id="$1"
    tmux set-option -wu -t "$window_id" @code_notify_agent_pid 2>/dev/null
}

# Record the owning agent's PID for the current window. CODE_NOTIFY_TMUX_AGENT_NAME
# is set by notifier.sh; direct tmux utility callers intentionally do not start
# a monitor because they have no reliable agent process to associate with it.
tmux_agent_exit_track() {
    local window_id="$1" pid
    [[ "${TMUX_AGENT_EXIT_POLL_SECONDS:-0}" =~ ^[0-9]+$ ]] || return 0
    (( TMUX_AGENT_EXIT_POLL_SECONDS > 0 )) || return 0
    pid=$(tmux_agent_exit_resolve_pid "${CODE_NOTIFY_TMUX_AGENT_NAME:-}" "${PPID:-}") || return 0
    tmux set-option -w -t "$window_id" @code_notify_agent_pid "$pid" 2>/dev/null || return 0
    tmux_agent_exit_schedule_sweep
}

# Arm the settle watch on a window whose agent (per TMUX_SETTLE_AGENTS) may
# end a turn without any hook. Stores the pane to observe; the snapshot
# bookkeeping (@code_notify_settle_fp/_since) is reset so a fresh turn never
# inherits the previous turn's settle countdown.
#
# Pass "force" as $3 to arm regardless of TMUX_SETTLE_AGENTS. The queued-prompt
# preserve (tmux_running_stop) uses it to verify a consumed hint really had a
# successor turn — that check must cover any agent, including ones with real
# Stop hooks, not just the no-stop agents the allowlist targets. A force arm
# also marks the watch badge-only: the preserving Stop already delivered its
# completion toast/sound/voice (only the terminal badge was withheld with the
# marker), so the reconcile must not notify again — unlike the allowlist case,
# where the turn ended with no hook and the synthetic run is the only alert.
tmux_running_settle_arm() {
    local window_id="$1" pane_id="$2" force="${3:-}"
    local agent="${CODE_NOTIFY_TMUX_AGENT_NAME:-}"
    [[ -n "$agent" ]] || return 0
    [[ "$force" == "force" ]] || [[ "|$TMUX_SETTLE_AGENTS|" == *"|$agent|"* ]] || return 0
    local pane_re='^%[0-9]+$'
    [[ "$pane_id" =~ $pane_re ]] || return 0
    tmux set-option -w -t "$window_id" @code_notify_settle_pane "$pane_id" 2>/dev/null
    if [[ "$force" == "force" ]]; then
        tmux set-option -w -t "$window_id" @code_notify_settle_badge_only 1 2>/dev/null
    else
        tmux set-option -wu -t "$window_id" @code_notify_settle_badge_only 2>/dev/null
    fi
    # The settle stop synthesizes the missing completion through the notifier,
    # which also arms the post-completion idle watch. Both paths need an agent
    # and project the sweep process cannot reconstruct — record them now, while
    # the prompt hook still has that context.
    # Project is best-effort: hooks run with the agent's working directory
    # as cwd. Agent first, project last, so embedded spaces survive the
    # positional parse.
    tmux set-option -w -t "$window_id" @code_notify_settle_ctx \
        "$agent $(basename "$PWD")" 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_fp 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_since 2>/dev/null
    # The settle check rides the agent-exit sweep; make sure it is ticking
    # even when PID resolution failed and nothing else armed it.
    tmux_agent_exit_schedule_sweep
    return 0
}

tmux_running_settle_disarm() {
    local window_id="$1"
    tmux set-option -wu -t "$window_id" @code_notify_settle_pane 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_ctx 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_fp 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_since 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_settle_badge_only 2>/dev/null
}

# True when permission_prompt alerts are enabled — same notify-types file and
# default (idle_prompt only, so approval alerts off) as the notifier's own
# check. The approval-dialog watch bypasses hook installation, so like the
# idle nudge it must consult the alert types itself: at arm time to avoid
# pointless pane captures, and again at delivery so disabling the alert
# mid-watch still silences an already-armed notification.
tmux_permission_prompt_enabled() {
    local types_file="$HOME/.claude/notifications/notify-types"
    local current="idle_prompt"
    [[ -f "$types_file" ]] && current="$(cat "$types_file" 2>/dev/null)"
    [[ "$current" == *permission_prompt* ]]
}

# Arm (or clear) the approval-dialog watch on a window whose turn just
# started (see TMUX_DIALOG_WATCH_AGENTS). Records the pane to observe plus
# the agent/project identity the eventual synthetic notification needs —
# none of which the sweep process can reconstruct. Project is best-effort
# the same way the settle context is: hooks run with the agent's working
# directory as cwd. Agent first, project last, so embedded spaces survive
# the positional parse.
#
# Deliberately not disarmed by stop/pause: the context is only acted on
# while the running marker is fresh, so it stays armed across an approval
# pause and its poll-driven resume — Antigravity skips tmux_running_start
# for the rest of the turn (see agy_maybe_start_running), so a stop-time
# disarm would blind the watch to every approval after the first — and it
# simply goes inert when the turn ends. A non-watched agent claiming the
# window clears the leftover context here, so its dialogs are never watched
# under a stale identity; the agent-exit cleanup drops it with the rest of
# the window state.
tmux_running_dialog_arm() {
    local window_id="$1" pane_id="$2"
    local agent="${CODE_NOTIFY_TMUX_AGENT_NAME:-}"
    local pane_re='^%[0-9]+$'
    # A fresh turn never inherits the previous turn's sighting epoch.
    tmux set-option -wu -t "$window_id" @code_notify_dialog_since 2>/dev/null
    if [[ -z "$agent" ]] || [[ "|$TMUX_DIALOG_WATCH_AGENTS|" != *"|$agent|"* ]] ||
        [[ ! "${TMUX_DIALOG_NOTIFY_SECONDS:-0}" =~ ^[0-9]+$ ]] ||
        (( TMUX_DIALOG_NOTIFY_SECONDS <= 0 )) ||
        [[ ! "$pane_id" =~ $pane_re ]] ||
        ! tmux_permission_prompt_enabled; then
        tmux set-option -wu -t "$window_id" @code_notify_dialog_ctx 2>/dev/null
        return 0
    fi
    tmux set-option -w -t "$window_id" @code_notify_dialog_ctx \
        "$pane_id $agent $(basename "$PWD")" 2>/dev/null
    # The watch rides the agent-exit sweep; make sure it is ticking even
    # when PID resolution failed and nothing else armed it.
    tmux_agent_exit_schedule_sweep
    return 0
}

tmux_running_dialog_disarm() {
    local window_id="$1"
    tmux set-option -wu -t "$window_id" @code_notify_dialog_ctx 2>/dev/null
    tmux set-option -wu -t "$window_id" @code_notify_dialog_since 2>/dev/null
}

# True when idle_prompt alerts are enabled — same notify-types file config.sh
# writes (normalized, pipe-separated; an absent file means the default, which
# is idle_prompt only). The synthetic idle nudge bypasses hook installation,
# so unlike Claude's native reminder it must consult the alert types itself:
# checked at arm time to avoid pointless watches, and again at delivery so
# removing idle_prompt mid-watch still silences an already-armed nudge.
tmux_idle_prompt_enabled() {
    local types_file="$HOME/.claude/notifications/notify-types"
    local current="idle_prompt"
    [[ -f "$types_file" ]] && current="$(cat "$types_file" 2>/dev/null)"
    [[ "$current" == *idle_prompt* ]]
}

# Arm the post-completion idle watch (see TMUX_IDLE_AGENTS) on a window whose
# turn just ended. Records everything the eventual synthetic notification
# needs — none of which the sweep process can reconstruct on its own: the
# pane to observe, the settle epoch, the content snapshot, and the agent/project
# identity. cksum emits two whitespace-separated fields (sum and size), so
# the packed layout is "pane epoch sum size state agent project", project last
# so embedded whitespace survives the positional parse. The initial settling
# state absorbs the final repaint that Codex performs after its Stop hook exits;
# once two snapshots match, the watch becomes stable and later repaints cancel
# it. An uncapturable pane
# simply never arms — with the turn over there is no recovery path worth
# keeping open.
tmux_idle_watch_arm() {
    local agent="$1" project="$2" window_id="$3" pane_id="$4" fp
    [[ "${TMUX_IDLE_SECONDS:-0}" =~ ^[0-9]+$ ]] || return 0
    (( TMUX_IDLE_SECONDS > 0 )) || return 0
    [[ -n "$agent" ]] || return 0
    [[ "|$TMUX_IDLE_AGENTS|" == *"|$agent|"* ]] || return 0
    tmux_idle_prompt_enabled || return 0
    local pane_re='^%[0-9]+$'
    [[ "$pane_id" =~ $pane_re ]] || return 0
    fp=$(tmux_resume_poll_fingerprint "$pane_id") || return 0
    [[ -n "$fp" ]] || return 0
    tmux set-option -w -t "$window_id" @code_notify_idle_watch \
        "$pane_id $(date +%s) $fp settling $agent $project" 2>/dev/null
    # Rides the agent-exit sweep; make sure it is ticking even though the
    # stop that led here just retired the turn's PID tracking.
    tmux_agent_exit_schedule_sweep
    return 0
}

# Notifier-facing entry: resolve the calling hook's window/pane, then arm.
tmux_idle_watch_arm_current() {
    local agent="$1" project="$2"
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    [[ "$window_id" =~ ^@[0-9]+$ ]] || return 0
    tmux_idle_watch_arm "$agent" "$project" "$window_id" "$pane_id"
}

# The settle sweep has already removed the old run before it invokes the
# notifier's synthetic completion. Arm that completion's idle watch only if a
# new prompt has not claimed the window in the meantime. The check and write
# share the transition lock with prompt-submit, so either the watch lands
# first and the new prompt clears it, or the prompt lands first and this skips.
tmux_idle_watch_arm_current_unless_running() {
    local agent="$1" project="$2"
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    [[ "$window_id" =~ ^@[0-9]+$ ]] || return 0

    tmux_running_transition_lock_acquire "$window_id" || return 0
    local transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    local transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    local since now
    since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
    now=$(date +%s)
    if [[ ! "$since" =~ ^[0-9]+$ ]] || (( now - since >= TMUX_RUNNING_TTL )); then
        tmux_idle_watch_arm "$agent" "$project" "$window_id" "$pane_id"
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    return 0
}

tmux_idle_watch_disarm() {
    tmux set-option -wu -t "$1" @code_notify_idle_watch 2>/dev/null
}

# Deliver the synthetic idle reminder through the real notifier so it
# inherits the whole idle_prompt pipeline — the 🥱 title and badge, sounds,
# per-subtype rate limiting, snooze, and the kill switch. Unlike a native
# waiting event, this watch has already proved the pane remained untouched for
# the full idle window, so force the badge to apply even if that tmux window is
# still marked visible: 🥱 must replace the earlier 🟢. TMUX_PANE targets the
# watched pane; detached delivery keeps a persistent alert from blocking the
# sweep tick. CODE_NOTIFY_NOTIFIER_PATH exists for tests to substitute a stub.
tmux_idle_watch_notify() {
    local pane_id="$1" agent="$2" project="$3" notifier
    tmux_idle_prompt_enabled || return 0
    notifier="${CODE_NOTIFY_NOTIFIER_PATH:-${TMUX_BADGE_LIB_PATH%/*}/../core/notifier.sh}"
    [[ -f "$notifier" ]] || return 0
    ( printf '%s' '{"type":"idle_prompt"}' \
        | CODE_NOTIFY_TMUX_BADGE_VISIBLE=true TMUX_PANE="$pane_id" \
          bash "$notifier" notification "$agent" "$project" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
}

# Deliver the synthetic approval alert through the real notifier so it
# inherits the whole permission_prompt pipeline — the waiting badge, sounds,
# snooze, the kill switch, and the input pause with its resume poll (which
# shares the dialog patterns that detected this prompt, so the running
# indicator comes back once the user answers and the agent repaints).
# TMUX_PANE targets the watched pane; detached delivery keeps a persistent
# alert from blocking the sweep tick. CODE_NOTIFY_NOTIFIER_PATH exists for
# tests to substitute a stub.
tmux_dialog_watch_notify() {
    local pane_id="$1" agent="$2" project="$3" notifier
    tmux_permission_prompt_enabled || return 0
    notifier="${CODE_NOTIFY_NOTIFIER_PATH:-${TMUX_BADGE_LIB_PATH%/*}/../core/notifier.sh}"
    [[ -f "$notifier" ]] || return 0
    ( printf '%s' '{"type":"permission_prompt"}' \
        | TMUX_PANE="$pane_id" bash "$notifier" notification "$agent" "$project" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
    return 0
}

# Deliver a completion for a turn that ended without its native stop hook
# (currently Codex /review). The sweep removes the running state first, then
# calls this synchronously so the normal stop pipeline can apply the 🟢 badge,
# send the completion toast, and arm the later idle reminder before the sweep
# decides whether another tick is needed. TMUX_PANE restores the originating
# context because a tmux run-shell timer has no pane of its own.
#
# Pass "1" as $4 when the watch was badge-only (a queued-prompt preserve, see
# tmux_running_settle_arm): that turn's Stop already delivered the toast, so
# the synthetic run applies only the badge and idle watch it withheld.
tmux_settle_watch_notify() {
    local pane_id="$1" agent="$2" project="$3" badge_only="${4:-}" notifier
    notifier="${CODE_NOTIFY_NOTIFIER_PATH:-${TMUX_BADGE_LIB_PATH%/*}/../core/notifier.sh}"
    [[ -f "$notifier" ]] || return 1
    if [[ "$badge_only" == "1" ]]; then
        CODE_NOTIFY_BADGE_ONLY=1 CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED=1 \
            TMUX_PANE="$pane_id" \
            bash "$notifier" stop "$agent" "$project" >/dev/null 2>&1
    else
        CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED=1 TMUX_PANE="$pane_id" \
            bash "$notifier" stop "$agent" "$project" >/dev/null 2>&1
    fi
}

# Ownership token for the repeating one-shot timer chains below. Each
# registration mints a fresh token, stores it in the chain's pending flag,
# and embeds it in the timer payload; at fire time the payload exits unless
# the flag still names it EXACTLY. So when a scheduling race produces two
# pending timers, only the one whose registration wrote the flag last
# survives its firing and the stray collapses instead of persisting as a
# parallel chain. An empty flag is also lost ownership, not a free pass: it
# means the owner already fired (consuming the flag) and its sweep covers
# this tick, so a stale twin firing into that window would otherwise sweep
# the same idle/settle state concurrently and deliver the very duplicate
# notification the token exists to prevent. A flag lost abnormally just ends
# the chain; the next hook event sees it empty and schedules a fresh one.
#
# Registration order matters: the flag is written BEFORE the timer is armed.
# Armed-first, a scheduler descheduled (or suspended) past the timer delay
# would let the payload fire against a still-empty flag and exit; the late
# flag write would then park an ownerless token that reads as "pending"
# forever, wedging the chain until the tmux server restarts. Claimed-first,
# the worst remaining case is a process dying in the instant between claim
# and arm — and if arming fails outright, the claim is rolled back so the
# chain degrades instead of jamming. The rollback clears the flag only while
# it still holds OUR token: a racer that overwrote the claim and armed
# successfully owns the chain now, and blindly unsetting would strand its
# timer against an empty flag (the guard would exit it without sweeping).
# That compare-and-clear runs server-side as one command (if-shell -F with a
# #{==:} format condition) — the tmux server serializes client commands, so
# a competing claim cannot land between the comparison and the unset the way
# it could between a client-side show-options and set-option pair. Tokens
# are digits and dots only, so embedding one in the format is expansion-safe.
#
# Returns the token in TMUX_TIMER_CHAIN_TOKEN (an out-param, not a setting):
# re-arms run on every poll tick, so minting must not fork — no command
# substitution, no external date. Uniqueness only has to tell apart nearby
# competing registrations; the PID plus two RANDOM draws is ample, and a
# collision merely leaves one duplicate tick uncollapsed.
tmux_timer_chain_token() {
    TMUX_TIMER_CHAIN_TOKEN="$$.$RANDOM.$RANDOM"
}

# One short tmux-server timer checks tracked agent PIDs. Repeating one-shots
# avoid a resident daemon and stop automatically when the last marker clears.
#
# The pending flag holds a chain-ownership token (see tmux_timer_chain_token),
# and the fired payload runs the sweep only while it still owns the flag.
# The pending check alone cannot prevent stacked timers: two hook processes
# can both read an empty flag before either writes it, and with the old
# unconditional payload each stray timer resurvived its own firing (clear
# flag, sweep, reschedule at sweep end) — duplicate chains persisted forever,
# and every expiry they raced on delivered the same idle/settle notification
# two or three times. With the token, whichever chain wrote the flag last
# survives and every other timer exits at fire time without sweeping.
tmux_agent_exit_schedule_sweep() {
    [[ "${TMUX_AGENT_EXIT_POLL_SECONDS:-0}" =~ ^[0-9]+$ ]] || return 0
    (( TMUX_AGENT_EXIT_POLL_SECONDS > 0 )) || return 0
    [[ -n "$TMUX_BADGE_LIB_PATH" ]] && [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 0
    local pending tmux_bin socket_path token q_lib q_tmux q_socket q_env q_poll q_token inner
    pending=$(tmux show-options -gqv @code_notify_agent_exit_sweep_scheduled 2>/dev/null)
    [[ -z "$pending" ]] || return 0
    tmux_bin=$(command -v tmux) || return 0
    socket_path="${TMUX%%,*}"
    [[ -n "$socket_path" ]] || return 0
    tmux_timer_chain_token
    token="$TMUX_TIMER_CHAIN_TOKEN"
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_env=$(tmux_focus_shell_quote "$TMUX")
    q_token=$(tmux_focus_shell_quote "$token")
    # Pass the interval through like the TTL sweep passes the TTL: the timer's
    # fresh process would otherwise fall back to the default, so a custom
    # interval would only survive the first firing. The settle and idle
    # thresholds and the idle-agent allowlist ride along for the same reason
    # (the settle-to-idle handoff arms inside the fired process, so a session
    # that excluded an agent must stay excluded there too), plus the notifier
    # override so tests exercising the fired payload keep their stub (empty
    # behaves as unset).
    q_poll=$(tmux_focus_shell_quote "$TMUX_AGENT_EXIT_POLL_SECONDS")
    local q_settle q_idle q_idle_agents q_notifier
    local q_dialog_secs q_dialog_agents q_dialog_markers q_dialog_options
    q_settle=$(tmux_focus_shell_quote "$TMUX_SETTLE_SECONDS")
    q_idle=$(tmux_focus_shell_quote "$TMUX_IDLE_SECONDS")
    q_idle_agents=$(tmux_focus_shell_quote "$TMUX_IDLE_AGENTS")
    q_notifier=$(tmux_focus_shell_quote "${CODE_NOTIFY_NOTIFIER_PATH:-}")
    # The dialog-watch settings ride along too: the fired sweep evaluates
    # sightings and the dialog patterns itself, so a session that tuned the
    # threshold or the marker set must keep it across the process boundary.
    q_dialog_secs=$(tmux_focus_shell_quote "$TMUX_DIALOG_NOTIFY_SECONDS")
    q_dialog_agents=$(tmux_focus_shell_quote "$TMUX_DIALOG_WATCH_AGENTS")
    q_dialog_markers=$(tmux_focus_shell_quote "$TMUX_DIALOG_MARKERS")
    q_dialog_options=$(tmux_focus_shell_quote "$TMUX_DIALOG_OPTIONS")
    inner="cur=\$($q_tmux -S $q_socket show-options -gqv @code_notify_agent_exit_sweep_scheduled 2>/dev/null); "
    inner+="if [ \"\$cur\" != $q_token ]; then exit 0; fi; "
    inner+="$q_tmux -S $q_socket set-option -gu @code_notify_agent_exit_sweep_scheduled; "
    inner+="if [ -f $q_lib ]; then TMUX=$q_env CODE_NOTIFY_TMUX_AGENT_EXIT_POLL_SECONDS=$q_poll "
    inner+="CODE_NOTIFY_TMUX_SETTLE_SECONDS=$q_settle "
    inner+="CODE_NOTIFY_TMUX_IDLE_SECONDS=$q_idle CODE_NOTIFY_TMUX_IDLE_AGENTS=$q_idle_agents "
    inner+="CODE_NOTIFY_NOTIFIER_PATH=$q_notifier "
    inner+="CODE_NOTIFY_TMUX_DIALOG_NOTIFY_SECONDS=$q_dialog_secs "
    inner+="CODE_NOTIFY_TMUX_DIALOG_WATCH_AGENTS=$q_dialog_agents "
    inner+="CODE_NOTIFY_TMUX_DIALOG_MARKERS=$q_dialog_markers "
    inner+="CODE_NOTIFY_TMUX_DIALOG_OPTIONS=$q_dialog_options "
    inner+="bash $q_lib agent-exit-sweep; fi"
    inner="${inner//\#/##}"
    # Claim before arming (see tmux_timer_chain_token); a failed arm rolls
    # back only a claim that is still ours, compared-and-cleared server-side
    # in one command.
    tmux set-option -g @code_notify_agent_exit_sweep_scheduled "$token" 2>/dev/null || return 0
    if ! tmux run-shell -b -d "$TMUX_AGENT_EXIT_POLL_SECONDS" "$inner" 2>/dev/null; then
        tmux if-shell -F "#{==:#{@code_notify_agent_exit_sweep_scheduled},$token}" \
            "set-option -gu @code_notify_agent_exit_sweep_scheduled" 2>/dev/null
    fi
}

tmux_agent_exit_sweep() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local now window_id pid since settle_pane idle_watch resume orig live=0
    local fp_now fp_prev settle_since settle_ctx settle_badge_only mode transition_lock transition_token
    local current_pid current_since current_settle_since
    local ipane isince ifp1 ifp2 istate iagent iproject
    local dialog_ctx dialog_since dpane dagent dproject dialog_content
    now=$(date +%s)
    # orig (the badge marker) reads last: it is the only field that may embed
    # "|" (a window name), and read folds any remainder into the final var.
    while IFS='|' read -r window_id pid since settle_pane idle_watch resume dialog_ctx dialog_since orig; do
        [[ "$window_id" =~ ^@[0-9]+$ ]] || continue
        # list-windows emits every window, with empty fields when the options
        # are unset. Windows that are neither PID-tracked nor settle-watched
        # are strictly out of scope — their badges (e.g. an agy StopFinal
        # completion, whose disowned watcher can never resolve an agent pid)
        # live by the normal glance/engage/TTL rules, not by this monitor.
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            if kill -0 "$pid" 2>/dev/null; then
                if [[ -n "$since$settle_pane$idle_watch$resume$orig" ]]; then
                    live=1
                else
                    # A live agent but nothing the monitor serves — no badge,
                    # running marker, settle/idle watch, or input pause. A
                    # suppressed terminal event (snoozed or rate-limited stop
                    # in spinner mode) can strand a bare PID like this; retire
                    # it so the sweep stops rescheduling for the rest of a
                    # long-lived agent session. The next hook event re-tracks.
                    tmux_agent_exit_untrack "$window_id"
                fi
            else
                # The associated agent is gone: remove both renderings, any
                # pending input-resume/settle state, and an event badge
                # without disturbing a manual window rename
                # (tmux_badge_clear already preserves one).
                if ! tmux_running_transition_lock_acquire "$window_id"; then
                    live=1
                    continue
                fi
                transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
                transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
                current_pid=$(tmux show-options -wqv -t "$window_id" @code_notify_agent_pid 2>/dev/null)
                if [[ "$current_pid" == "$pid" ]]; then
                    tmux set-option -wu -t "$window_id" @code_notify_running 2>/dev/null
                    tmux set-option -wu -t "$window_id" @code_notify_resume_pending 2>/dev/null
                    tmux_resume_flag_clear "$window_id"
                    tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
                    tmux_running_settle_disarm "$window_id"
                    tmux_idle_watch_disarm "$window_id"
                    tmux_running_dialog_disarm "$window_id"
                    tmux_badge_clear_locked "$window_id"
                    tmux_agent_exit_untrack "$window_id"
                else
                    # A fresh hook already associated this window with a new
                    # owner; leave its state intact and keep the sweep alive.
                    live=1
                fi
                tmux_running_transition_lock_release "$transition_lock" "$transition_token"
                continue
            fi
        fi
        # Post-completion idle watch (see TMUX_IDLE_AGENTS): the turn is
        # over, but Codex repaints once more after its Stop hook exits. Follow
        # those final frames until two snapshots match, then start the idle
        # countdown. Once stable, a repaint means the user is already there
        # and disarms silently. A vanished/moved pane, capture failure, or a
        # feature disabled mid-watch also disarms.
        if [[ -n "$idle_watch" ]]; then
            read -r ipane isince ifp1 ifp2 istate iagent iproject <<< "$idle_watch"
            # Watches armed by an older process have no state field. Treat
            # them as stable so an upgrade cannot reinterpret their agent as
            # state or silently lose the pending reminder.
            if [[ "$istate" != "settling" ]] && [[ "$istate" != "stable" ]]; then
                iproject="$iagent${iproject:+ $iproject}"
                iagent="$istate"
                istate="stable"
            fi
            if [[ "$ipane" =~ ^%[0-9]+$ ]] && [[ "$isince" =~ ^[0-9]+$ ]] &&
                [[ "${TMUX_IDLE_SECONDS:-0}" =~ ^[0-9]+$ ]] && (( TMUX_IDLE_SECONDS > 0 )) &&
                [[ "$(tmux display-message -p -t "$ipane" '#{window_id}' 2>/dev/null)" == "$window_id" ]] &&
                fp_now=$(tmux_resume_poll_fingerprint "$ipane"); then
                if [[ "$istate" == "settling" ]]; then
                    if [[ "$fp_now" == "$ifp1 $ifp2" ]]; then
                        istate="stable"
                    fi
                    tmux set-option -w -t "$window_id" @code_notify_idle_watch \
                        "$ipane $now $fp_now $istate $iagent $iproject" 2>/dev/null
                    live=1
                elif [[ "$fp_now" != "$ifp1 $ifp2" ]]; then
                    tmux_idle_watch_disarm "$window_id"
                elif (( now - isince >= TMUX_IDLE_SECONDS )); then
                    tmux_idle_watch_disarm "$window_id"
                    tmux_idle_watch_notify "$ipane" "$iagent" "$iproject"
                else
                    live=1
                fi
            else
                tmux_idle_watch_disarm "$window_id"
            fi
        fi
        # Approval-dialog watch (see TMUX_DIALOG_WATCH_AGENTS): while a
        # watched agent's running marker is fresh, its hooks announced no
        # pause — yet an approval dialog sitting rendered on the recorded
        # pane means the agent is in fact blocked on the user (a pause the
        # PreToolUse banner could not predict: file-write and subagent
        # approvals appear in no permission list). Record when the dialog
        # was first seen; once it has stayed on screen across ticks spanning
        # TMUX_DIALOG_NOTIFY_SECONDS, deliver one synthetic
        # permission_prompt through the notifier. Its input pause then
        # removes the running marker, which both gates this branch off (no
        # re-fire while the same dialog waits) and hands resume detection to
        # the poll that pause arms. The dialog vanishing before the
        # threshold means the user was already there — reset silently. Same
        # observability guards as the settle watch: the recorded pane must
        # still belong to this window and must actually capture.
        if [[ -n "$dialog_ctx" ]] && [[ "$since" =~ ^[0-9]+$ ]] &&
            (( now - since < TMUX_RUNNING_TTL )) &&
            [[ "${TMUX_DIALOG_NOTIFY_SECONDS:-0}" =~ ^[0-9]+$ ]] &&
            (( TMUX_DIALOG_NOTIFY_SECONDS > 0 )); then
            read -r dpane dagent dproject <<< "$dialog_ctx"
            if [[ "$dpane" =~ ^%[0-9]+$ ]]; then
                live=1
                if [[ "$(tmux display-message -p -t "$dpane" '#{window_id}' 2>/dev/null)" == "$window_id" ]] &&
                    dialog_content=$(tmux capture-pane -p -t "$dpane" 2>/dev/null); then
                    if [[ "$(tmux_resume_poll_dialog_flag "$dialog_content")" == "1" ]]; then
                        if [[ ! "$dialog_since" =~ ^[0-9]+$ ]]; then
                            tmux set-option -w -t "$window_id" \
                                @code_notify_dialog_since "$now" 2>/dev/null
                        elif (( now - dialog_since >= TMUX_DIALOG_NOTIFY_SECONDS )); then
                            tmux set-option -wu -t "$window_id" \
                                @code_notify_dialog_since 2>/dev/null
                            # A turn transition between the snapshot and now
                            # owns the window's state; a stale sighting must
                            # not toast over it.
                            current_since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
                            if [[ "$current_since" == "$since" ]]; then
                                tmux_dialog_watch_notify "$dpane" "$dagent" "$dproject"
                            fi
                        fi
                    elif [[ -n "$dialog_since" ]]; then
                        tmux set-option -wu -t "$window_id" \
                            @code_notify_dialog_since 2>/dev/null
                    fi
                fi
            fi
        fi
        # Settle watch (see TMUX_SETTLE_AGENTS): while a watched agent's
        # running marker is fresh, a pane whose rendered content holds still
        # for a full settle window means the turn ended without a hook
        # (Codex /review) — take the marker down. Same observability guards
        # as the resume poll: the recorded pane must still belong to this
        # window and must actually capture; otherwise leave the marker to
        # the PID/TTL paths.
        [[ "$settle_pane" =~ ^%[0-9]+$ ]] || continue
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        (( now - since < TMUX_RUNNING_TTL )) || continue
        live=1
        [[ "$(tmux display-message -p -t "$settle_pane" '#{window_id}' 2>/dev/null)" == "$window_id" ]] || continue
        fp_now=$(tmux_resume_poll_fingerprint "$settle_pane") || fp_now=""
        [[ -n "$fp_now" ]] || continue
        fp_prev=$(tmux show-options -wqv -t "$window_id" @code_notify_settle_fp 2>/dev/null)
        if [[ "$fp_now" != "$fp_prev" ]]; then
            tmux set-option -w -t "$window_id" @code_notify_settle_fp "$fp_now" 2>/dev/null
            tmux set-option -w -t "$window_id" @code_notify_settle_since "$now" 2>/dev/null
            continue
        fi
        settle_since=$(tmux show-options -wqv -t "$window_id" @code_notify_settle_since 2>/dev/null)
        if [[ ! "$settle_since" =~ ^[0-9]+$ ]]; then
            tmux set-option -w -t "$window_id" @code_notify_settle_since "$now" 2>/dev/null
            continue
        fi
        (( now - settle_since >= TMUX_SETTLE_SECONDS )) || continue
        # Settled: the agent is idle. Mirror tmux_running_stop for this
        # window — drop the marker, clear the running rename (an event badge
        # that replaced it is left alone), and stop tracking; the next hook
        # event re-arms everything.
        if ! tmux_running_transition_lock_acquire "$window_id"; then
            live=1
            continue
        fi
        transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
        transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
        current_since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
        current_settle_since=$(tmux show-options -wqv -t "$window_id" @code_notify_settle_since 2>/dev/null)
        if [[ "$current_since" != "$since" ]] || [[ "$current_settle_since" != "$settle_since" ]]; then
            # A prompt started after the sweep snapshot. Its epoch/watch owns
            # the window now, even when second-resolution epochs collide.
            tmux_running_transition_lock_release "$transition_lock" "$transition_token"
            live=1
            continue
        fi
        settle_ctx=$(tmux show-options -wqv -t "$window_id" @code_notify_settle_ctx 2>/dev/null)
        settle_badge_only=$(tmux show-options -wqv -t "$window_id" @code_notify_settle_badge_only 2>/dev/null)
        tmux set-option -wu -t "$window_id" @code_notify_running 2>/dev/null
        tmux_running_settle_disarm "$window_id"
        mode=$(tmux show-options -wqv -t "$window_id" @code_notify_clear_mode 2>/dev/null)
        if [[ "$mode" == "running" ]]; then
            tmux_badge_clear_locked "$window_id"
        fi
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
        # Run the missing terminal event through the real notifier after the
        # running rendering is gone. That applies the normal completion badge
        # and toast, then arms the same idle watch as a native stop. If the
        # notifier is unavailable, retain the old idle-only fallback so a
        # hook-less review does not remain silently unattended forever.
        if [[ -n "$settle_ctx" ]]; then
            read -r iagent iproject <<< "$settle_ctx"
            if ! tmux_settle_watch_notify "$settle_pane" "$iagent" "$iproject" "$settle_badge_only"; then
                tmux_idle_watch_arm "$iagent" "$iproject" "$window_id" "$settle_pane"
            fi
            live=1
        fi
        # The synthetic completion runs outside the agent's process tree, so
        # its badge could not re-resolve the PID that tmux_badge_clear dropped
        # along with the running rendering. Restore the one this sweep already
        # verified alive, or the completion badge outlives the agent forever.
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            tmux set-option -w -t "$window_id" @code_notify_agent_pid "$pid" 2>/dev/null
        fi
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{@code_notify_agent_pid}|#{@code_notify_running}|#{@code_notify_settle_pane}|#{@code_notify_idle_watch}|#{@code_notify_resume_pending}|#{@code_notify_dialog_ctx}|#{@code_notify_dialog_since}|#{@code_notify_orig_name}' 2>/dev/null)
    if [[ "$live" -eq 1 ]]; then
        tmux_agent_exit_schedule_sweep
    fi
    tmux_spinner_disarm_if_idle
    return 0
}

# The env var (when set) wins over the flag file, so a single session can
# force the spinner on or off without touching persistent state.
tmux_running_spinner_enabled() {
    if [[ -n "${CODE_NOTIFY_TMUX_SPINNER:-}" ]]; then
        [[ "$CODE_NOTIFY_TMUX_SPINNER" == "true" ]]
        return
    fi
    [[ -f "$TMUX_SPINNER_ENABLED_FILE" ]]
}

# The status-line snippet: while this window's @code_notify_running epoch is
# fresher than the TTL, show the moon frame for the current wall-clock second
# (a trailing space separates it from the theme's own content); otherwise show
# nothing. An event badge owns @code_notify_orig_name and has higher display
# priority, so it suppresses the independent spinner until the badge clears.
# Everything is computed by tmux during its normal status redraw — no process
# is spawned. Frame choice is a nested-conditional table because tmux formats
# have no array indexing.
tmux_spinner_build_format() {
    local frames=(🌑 🌒 🌓 🌔 🌕 🌖 🌗 🌘)
    local idx='#{e|m:#{T:@code_notify_clock},8}'
    local frame="${frames[7]}"
    local i
    for ((i = 6; i >= 0; i--)); do
        frame="#{?#{e|==:$idx,$i},${frames[$i]},$frame}"
    done
    local age='#{e|-:#{T:@code_notify_clock},#{@code_notify_running}}'
    printf '%s' "#{?#{!=:#{@code_notify_orig_name},},,#{?#{@code_notify_running},#{?#{e|<:$age,$TMUX_RUNNING_TTL},$frame ,},}}"
}

# The global status-interval set in tmux_spinner_arm does not reach sessions
# with a session-local value, whose spinner would tick at the slower local
# rate. Lower each such session to 1, saving the old value in a session-scoped
# option so disarm can restore it. Sessions already carrying a saved value are
# skipped: they were adjusted this armed period, and a user who deliberately
# re-raised their interval since must not be fought on every prompt.
tmux_spinner_sync_session_intervals() {
    local sid val
    while read -r sid; do
        [[ -n "$sid" ]] || continue
        val=$(tmux show-options -qv -t "$sid" @code_notify_saved_interval 2>/dev/null)
        [[ -z "$val" ]] || continue
        val=$(tmux show-options -qv -t "$sid" status-interval 2>/dev/null)
        { [[ -n "$val" ]] && [[ "$val" != "1" ]]; } || continue
        tmux set-option -t "$sid" @code_notify_saved_interval "$val" 2>/dev/null
        tmux set-option -t "$sid" status-interval 1 2>/dev/null
    done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)
    return 0
}

# Undo the session sync: restore each session's saved interval — only while
# our 1 is still in place, so a value the user changed while armed wins — and
# drop the per-session bookkeeping.
tmux_spinner_restore_session_intervals() {
    local sid val cur
    while read -r sid; do
        [[ -n "$sid" ]] || continue
        val=$(tmux show-options -qv -t "$sid" @code_notify_saved_interval 2>/dev/null)
        [[ -n "$val" ]] || continue
        cur=$(tmux show-options -qv -t "$sid" status-interval 2>/dev/null)
        if [[ "$cur" == "1" ]]; then
            tmux set-option -t "$sid" status-interval "$val" 2>/dev/null
        fi
        tmux set-option -u -t "$sid" @code_notify_saved_interval 2>/dev/null
    done < <(tmux list-sessions -F '#{session_id}' 2>/dev/null)
    return 0
}

# Put the spinner immediately after tmux's conventional #I window-number token
# when the theme uses it: `3 🌕 project` rather than a moon visually attached to
# the previous Powerline segment. Themes without #I retain the old prefix
# fallback so the indicator remains visible.
tmux_spinner_insert_after_window_number() {
    local format="$1" snip="$2" before after
    if [[ "$format" == *"#I"* ]]; then
        before="${format%%\#I*}"
        after="${format#*\#I}"
        # The vast majority of themes separate #I and the name with a space.
        # snip already ends with one, so consume that separator to avoid two.
        [[ "$after" == " "* ]] && after="${after# }"
        printf '%s' "${before}#I ${snip}${after}"
    else
        printf '%s' "${snip}${format}"
    fi
}

# Add the spinner snippet to the global window-status formats and lower
# status-interval to 1 so the frame advances every second. Idempotent: the
# saved snippet (@code_notify_spinner_snip) doubles as the armed flag. The
# exact snippet is saved so disarm can strip precisely what was added even if
# the TTL env var changed in between; the user's status-interval (global and
# any session-local values) is saved for the same reason.
tmux_spinner_arm() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local snip
    snip=$(tmux show-options -gqv @code_notify_spinner_snip 2>/dev/null)
    if [[ -n "$snip" ]]; then
        # Already armed globally, but a session created — or given a
        # session-local status-interval — since then still ticks at its own
        # rate: bring it in line.
        tmux_spinner_sync_session_intervals
        return 0
    fi
    snip=$(tmux_spinner_build_format)
    local interval wsf wscf
    interval=$(tmux show-options -gv status-interval 2>/dev/null)
    wsf=$(tmux show-options -gwv window-status-format 2>/dev/null)
    wscf=$(tmux show-options -gwv window-status-current-format 2>/dev/null)
    tmux set-option -g @code_notify_spinner_snip "$snip" 2>/dev/null || return 0
    tmux set-option -g @code_notify_saved_interval "${interval:-15}" 2>/dev/null
    tmux set-option -g @code_notify_clock '%s' 2>/dev/null
    tmux set-option -gw window-status-format \
        "$(tmux_spinner_insert_after_window_number "$wsf" "$snip")" 2>/dev/null
    tmux set-option -gw window-status-current-format \
        "$(tmux_spinner_insert_after_window_number "$wscf" "$snip")" 2>/dev/null
    tmux set-option -g status-interval 1 2>/dev/null
    tmux_spinner_sync_session_intervals
    return 0
}

# Undo tmux_spinner_arm: strip the exact snippet wherever it was injected (a
# format the user has since replaced wholesale is left alone), restore the
# saved status-interval, and drop the bookkeeping options. No-op when not armed.
tmux_spinner_disarm() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local snip cur interval
    snip=$(tmux show-options -gqv @code_notify_spinner_snip 2>/dev/null)
    if [[ -z "$snip" ]]; then
        return 0
    fi
    cur=$(tmux show-options -gwv window-status-format 2>/dev/null)
    if [[ "$cur" == *"$snip"* ]]; then
        tmux set-option -gw window-status-format "${cur/"$snip"/}" 2>/dev/null
    fi
    cur=$(tmux show-options -gwv window-status-current-format 2>/dev/null)
    if [[ "$cur" == *"$snip"* ]]; then
        tmux set-option -gw window-status-current-format "${cur/"$snip"/}" 2>/dev/null
    fi
    interval=$(tmux show-options -gqv @code_notify_saved_interval 2>/dev/null)
    if [[ -n "$interval" ]]; then
        # Same protection as the formats above: only restore while our value
        # (1) is still in place. A user who changed status-interval while the
        # spinner was armed (config reload, manual set) keeps their newer
        # value instead of having the arm-time snapshot clobber it.
        cur=$(tmux show-options -gv status-interval 2>/dev/null)
        if [[ "$cur" == "1" ]]; then
            tmux set-option -g status-interval "$interval" 2>/dev/null
        fi
    fi
    tmux_spinner_restore_session_intervals
    tmux set-option -gu @code_notify_spinner_snip 2>/dev/null
    tmux set-option -gu @code_notify_saved_interval 2>/dev/null
    tmux set-option -gu @code_notify_clock 2>/dev/null
    return 0
}

# Disarm the spinner once no window carries a fresh running epoch, so the 1s
# status redraw stops the moment the last agent finishes.
tmux_spinner_disarm_if_idle() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local snip
    snip=$(tmux show-options -gqv @code_notify_spinner_snip 2>/dev/null)
    if [[ -z "$snip" ]]; then
        return 0
    fi
    local now window_id since live=0
    now=$(date +%s)
    while IFS='|' read -r window_id since; do
        if [[ "$since" =~ ^[0-9]+$ ]] && [[ $((now - since)) -lt "$TMUX_RUNNING_TTL" ]]; then
            live=1
        fi
    done < <(tmux list-windows -a -F '#{window_id}|#{@code_notify_running}' 2>/dev/null)
    if [[ "$live" -eq 0 ]]; then
        tmux_spinner_disarm
    fi
    return 0
}

# Mark the caller's window as running. Standalone form for the running-start
# dispatch; the notifier's prompt intercept uses tmux_prompt_submit below,
# which folds the engage-clear and this marker into one target capture.
tmux_running_start() {
    if ! tmux_running_enabled; then
        # Starting or resuming work is still an engage-clear signal when the
        # running indicator is disabled. This is also Antigravity's clear path:
        # its first PreToolUse replaces the prompt-submit event it does not emit.
        tmux_badge_clear_current
        return 0
    fi
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    local transition_lock transition_token spinner=0
    tmux_running_transition_lock_acquire "$window_id" || return 0
    transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    if tmux_running_spinner_enabled; then
        spinner=1
        # The spinner is rendered independently from the window name, so it
        # does not naturally replace a waiting/event badge the way the static
        # running icon below does. Clear that badge BEFORE the running marker
        # lands: the marker makes the spinner render on the very next status
        # repaint, and the badge restore is several tmux round-trips away, so
        # the reverse order flashes the spinner next to the still-badged name.
        tmux_badge_clear_locked "$window_id"
    fi
    if ! tmux set-option -w -t "$window_id" @code_notify_running "$(date +%s)" 2>/dev/null; then
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
        return 0
    fi
    # A new prompt or a resumed tool turn supersedes any earlier input wait —
    # and any pending post-completion idle nudge.
    tmux set-option -wu -t "$window_id" @code_notify_resume_pending 2>/dev/null
    tmux_resume_flag_clear "$window_id"
    tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
    tmux_idle_watch_disarm "$window_id"
    tmux_running_settle_arm "$window_id" "$pane_id"
    tmux_running_dialog_arm "$window_id" "$pane_id"
    if (( spinner )); then
        tmux_agent_exit_track "$window_id"
        tmux_spinner_arm
    elif tmux_badge_enabled; then
        tmux_badge_set_locked "$TMUX_RUNNING_ICON" running "$TMUX_PANE" skip "$window_id" || true
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    # Make sure the retire timer is armed for this fresh marker — one
    # show-options round trip when it already is. A server-wide stale sweep
    # would also converge dead runs here, but it lists every window on every
    # prompt; stale markers are the timer's job.
    tmux_running_schedule_sweep $((TMUX_RUNNING_TTL + 2))
    return 0
}

# Recoverable, bounded cross-process lock for one window's badge/running state.
# tmux's `wait-for -L` mutex has no owner association, so a killed hook can
# strand it for the server lifetime. An atomic directory records PID, age and
# an ownership token; dead/old owners are reclaimed, waits time out instead of
# hanging hooks forever, and a socket-local fallback keeps badging available
# when the normal notification state directory is not writable.
TMUX_RUNNING_LOCK_DIR="$HOME/.claude/notifications/state/running-locks"
TMUX_RUNNING_LOCK_TIMEOUT_MS="${CODE_NOTIFY_TMUX_LOCK_TIMEOUT_MS:-2000}"
TMUX_RUNNING_LOCK_STALE_SECONDS="${CODE_NOTIFY_TMUX_LOCK_STALE_SECONDS:-30}"
[[ "$TMUX_RUNNING_LOCK_TIMEOUT_MS" =~ ^[0-9]+$ ]] || TMUX_RUNNING_LOCK_TIMEOUT_MS=2000
[[ "$TMUX_RUNNING_LOCK_STALE_SECONDS" =~ ^[0-9]+$ ]] || TMUX_RUNNING_LOCK_STALE_SECONDS=30
(( TMUX_RUNNING_LOCK_TIMEOUT_MS > 0 )) || TMUX_RUNNING_LOCK_TIMEOUT_MS=2000
(( TMUX_RUNNING_LOCK_STALE_SECONDS > 0 )) || TMUX_RUNNING_LOCK_STALE_SECONDS=30

tmux_running_transition_lock_fallback_dir() {
    local socket_path socket_dir
    socket_path="${TMUX%%,*}"
    socket_dir="${socket_path%/*}"
    if [[ -n "$socket_dir" ]] && [[ "$socket_dir" != "$socket_path" ]]; then
        printf '%s/.code-notify-running-locks' "$socket_dir"
        return 0
    fi
    tmux_running_transition_lock_shared_tmp_dir
}

tmux_running_transition_lock_shared_tmp_dir() {
    local uid
    uid="${UID:-$(id -u 2>/dev/null || printf 'user')}"
    printf '%s/code-notify-%s/running-locks' "${TMPDIR:-/tmp}" "$uid"
}

# A fallback can live below a shared temporary directory. Never follow a
# pre-planted final symlink or reuse a directory owned by another user (or one
# whose group/other permissions expose it). Re-check after mkdir so a race at
# creation time cannot silently substitute an unsafe path.
tmux_running_transition_lock_dir_secure() {
    local dir="$1" mode numeric
    [[ -d "$dir" ]] && [[ ! -L "$dir" ]] && [[ -O "$dir" ]] || return 1
    mode=$(stat -f '%Lp' "$dir" 2>/dev/null) || mode=$(stat -c '%a' "$dir" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    numeric=$((8#$mode))
    (( (numeric & 077) == 0 ))
}

tmux_running_transition_lock_prepare_fallback() {
    local dir="$1" parent
    parent="${dir%/*}"
    [[ -n "$parent" ]] && [[ "$parent" != "$dir" ]] || return 1

    # Create one level at a time. `mkdir -p` would follow an attacker-planted
    # symlink in the per-user component before the final-path check could see
    # it. Both the socket directory and TMPDIR already exist, so the immediate
    # parent is the only intermediate component this fallback owns.
    if [[ ! -e "$parent" ]] && [[ ! -L "$parent" ]]; then
        ( umask 077; mkdir "$parent" ) 2>/dev/null || return 1
    fi
    tmux_running_transition_lock_dir_secure "$parent" || return 1

    if [[ ! -e "$dir" ]] && [[ ! -L "$dir" ]]; then
        ( umask 077; mkdir "$dir" ) 2>/dev/null || return 1
    fi
    tmux_running_transition_lock_dir_secure "$dir"
}

# Prefer the directory beside the tmux socket, but a custom socket may itself
# live directly in a shared directory (for example /tmp). If that candidate
# fails the ownership/mode checks, fall through to the private per-user temp
# hierarchy rather than disabling badges.
tmux_running_transition_lock_select_fallback() {
    local candidate shared
    candidate=$(tmux_running_transition_lock_fallback_dir) || return 1
    if tmux_running_transition_lock_prepare_fallback "$candidate"; then
        TMUX_RUNNING_FALLBACK_DIR="$candidate"
        return 0
    fi
    shared=$(tmux_running_transition_lock_shared_tmp_dir) || return 1
    [[ "$shared" != "$candidate" ]] || return 1
    tmux_running_transition_lock_prepare_fallback "$shared" || return 1
    TMUX_RUNNING_FALLBACK_DIR="$shared"
    return 0
}

tmux_running_transition_lock_path() {
    local window_id="$1" base_dir="${2:-$TMUX_RUNNING_LOCK_DIR}" socket_base
    socket_base="${TMUX%%,*}"
    socket_base="${socket_base##*/}"
    socket_base="${socket_base//[^A-Za-z0-9_.-]/_}"
    printf '%s/%s.%s.lock' "$base_dir" "${socket_base:-default}" "$window_id"
}

tmux_running_transition_lock_mtime() {
    local path="$1" value
    value=$(stat -f '%m' "$path" 2>/dev/null) || value=$(stat -c '%Y' "$path" 2>/dev/null) || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$value"
}

tmux_running_transition_lock_is_stale() {
    local lockdir="$1" owner created now mtime
    [[ -d "$lockdir" ]] || return 1
    if [[ -r "$lockdir/pid" ]]; then
        read -r owner created _ < "$lockdir/pid" 2>/dev/null || true
    fi
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
        return 0
    fi
    now=$(date +%s)
    if [[ "$owner" =~ ^[0-9]+$ ]]; then
        [[ "$created" =~ ^[0-9]+$ ]] &&
            (( now - created >= TMUX_RUNNING_LOCK_STALE_SECONDS ))
        return
    fi
    mtime=$(tmux_running_transition_lock_mtime "$lockdir") || return 1
    (( now - mtime >= TMUX_RUNNING_LOCK_STALE_SECONDS ))
}

# Claim the per-generation reclaim gate. It uses the same tokenized directory
# shape as the main lock so a reclaimer killed in this tiny critical section
# delays recovery only until the stale threshold instead of wedging the window
# forever. Removing a stale gate cannot expose a second main-lock owner: every
# main candidate checks for the gate immediately after mkdir, and the gate
# winner revalidates the main generation before deleting it.
tmux_running_transition_reclaim_gate_acquire() {
    local reclaimdir="$1" now token
    if ! mkdir "$reclaimdir" 2>/dev/null; then
        if tmux_running_transition_lock_is_stale "$reclaimdir"; then
            rm -f "$reclaimdir/pid" 2>/dev/null || true
            rmdir "$reclaimdir" 2>/dev/null || true
        fi
        return 1
    fi
    now=$(date +%s)
    token="$$.$now.${RANDOM:-0}.${RANDOM:-0}"
    if ! ( umask 077; printf '%s %s %s' "$$" "$now" "$token" > "$reclaimdir/pid" ); then
        rm -f "$reclaimdir/pid" 2>/dev/null || true
        rmdir "$reclaimdir" 2>/dev/null || true
        return 1
    fi
    TMUX_RUNNING_TRANSITION_LOCKDIR="$reclaimdir"
    TMUX_RUNNING_TRANSITION_LOCKTOKEN="$token"
    return 0
}

tmux_running_transition_lock_acquire() {
    local window_id="$1" base_dir lockdir reclaimdir fallback_dir
    local token now attempts=0 using_fallback=0
    local max_attempts=$(( (TMUX_RUNNING_LOCK_TIMEOUT_MS + 9) / 10 ))

    base_dir="$TMUX_RUNNING_LOCK_DIR"
    if { [[ ! -d "$base_dir" ]] && ! mkdir -p "$base_dir" 2>/dev/null; } ||
        [[ ! -w "$base_dir" ]]; then
        tmux_running_transition_lock_select_fallback || return 1
        fallback_dir="$TMUX_RUNNING_FALLBACK_DIR"
        base_dir="$fallback_dir"
        using_fallback=1
    fi
    lockdir="$(tmux_running_transition_lock_path "$window_id" "$base_dir")"
    reclaimdir="${lockdir}.reclaim"

    while true; do
        if mkdir "$lockdir" 2>/dev/null; then
            # A stale-owner reclaimer may have removed the preceding lock just
            # before this mkdir. It owns the adjacent gate until that removal
            # is complete; relinquish this still-empty candidate and retry so
            # the reclaimer can never mistake it for the stale generation.
            if [[ -e "$reclaimdir" ]] || [[ -L "$reclaimdir" ]]; then
                rmdir "$lockdir" 2>/dev/null || true
                # A reclaimer killed after removing the primary lock but before
                # releasing this gate would otherwise strand the window: every
                # later acquire re-creates the lock, sees the orphaned gate, and
                # relinquishes forever. Retire the gate once it ages out. Only a
                # dead/old owner is removed, so a live reclaimer keeps its gate.
                if tmux_running_transition_lock_is_stale "$reclaimdir"; then
                    rm -f "$reclaimdir/pid" 2>/dev/null || true
                    rmdir "$reclaimdir" 2>/dev/null || true
                fi
                attempts=$((attempts + 1))
                (( attempts < max_attempts )) || return 1
                sleep 0.01
                continue
            fi
            break
        fi

        # A parent that looked writable may still reject the atomic mkdir due
        # to ACLs or a concurrent permission change. Fall back only when no
        # lock exists there; an existing primary lock must remain authoritative.
        if [[ ! -d "$lockdir" ]] && (( using_fallback == 0 )); then
            tmux_running_transition_lock_select_fallback || return 1
            fallback_dir="$TMUX_RUNNING_FALLBACK_DIR"
            base_dir="$fallback_dir"
            lockdir="$(tmux_running_transition_lock_path "$window_id" "$base_dir")"
            reclaimdir="${lockdir}.reclaim"
            using_fallback=1
            continue
        fi

        attempts=$((attempts + 1))
        if (( attempts % 10 == 0 )) &&
            tmux_running_transition_lock_is_stale "$lockdir"; then
            # Only one waiter may reclaim, and it must revalidate after taking
            # the gate. A waiter that merely observed the old owner can never
            # delete a lock another waiter recreated in the meantime.
            if tmux_running_transition_reclaim_gate_acquire "$reclaimdir"; then
                local reclaim_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
                local reclaim_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
                if tmux_running_transition_lock_is_stale "$lockdir"; then
                    rm -f "$lockdir/pid" 2>/dev/null || true
                    rmdir "$lockdir" 2>/dev/null || true
                fi
                tmux_running_transition_lock_release "$reclaim_lock" "$reclaim_token"
            fi
            continue
        fi
        (( attempts < max_attempts )) || return 1
        sleep 0.01
    done

    now=$(date +%s)
    token="$$.$now.${RANDOM:-0}.${RANDOM:-0}"
    if ! ( umask 077; printf '%s %s %s' "$$" "$now" "$token" > "$lockdir/pid" ); then
        rm -f "$lockdir/pid" 2>/dev/null || true
        rmdir "$lockdir" 2>/dev/null || true
        return 1
    fi
    TMUX_RUNNING_TRANSITION_LOCKDIR="$lockdir"
    TMUX_RUNNING_TRANSITION_LOCKTOKEN="$token"
    return 0
}

tmux_running_transition_lock_release() {
    local lockdir="$1" token="${2:-}" owner created current_token
    [[ -n "$lockdir" ]] && [[ -n "$token" ]] || return 0
    if [[ -r "$lockdir/pid" ]]; then
        read -r owner created current_token < "$lockdir/pid" 2>/dev/null || true
    fi
    [[ "$current_token" == "$token" ]] || return 0
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
}

# The UserPromptSubmit fast path: the user just handed the caller's window
# more work, so the pending event badge clears (the engage-clear) and the
# running marker replaces it. This runs synchronously on every prompt
# submission, so it is built around a single target capture — static mode
# swaps the badge icon in place (one rename) instead of clear-restore
# followed by a re-badge, and stale cleanup is left to the scheduled timer.
tmux_prompt_submit() {
    tmux_focus_available || return 0
    if ! tmux_running_enabled; then
        # Running indicator disabled: just the engage-clear. Intentionally not
        # gated on tmux_badge_enabled — badges left from before the feature
        # was disabled should still clear.
        tmux_badge_clear_current
        return 0
    fi

    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0

    # Serialize the queued-successor handoff with terminal teardown. Without
    # this lock, Stop can observe no hint, then let this submission write the
    # hint and a fresh epoch, and finally unset that fresh epoch. Keeping the
    # complete marker/badge transition inside the same per-window lock also
    # prevents either side from clearing the rendering applied by the other.
    tmux_running_transition_lock_acquire "$window_id" || return 0
    local transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    local transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"

    # A submission that arrives while this window's running marker is still
    # up means the ending turn has a queued successor: hook processes run
    # concurrently, so the older turn's Stop teardown can execute after this
    # prompt armed the indicator — and nothing between a Stop and the next
    # UserPromptSubmit re-lights it (tool hooks are resume-gated). Leave a
    # hint for that Stop to consume so the successor turn keeps its
    # indicator. A marker lingering from an interrupted turn (Esc emits no
    # Stop) sets a false hint, whose consuming Stop would otherwise strand the
    # indicator; tmux_running_stop arms a settle watch on that preserve so the
    # sweep reconciles it once the pane proves idle, rather than waiting on the
    # native idle reminder or the TTL.
    local prev_running now_epoch
    now_epoch="$(date +%s)"
    prev_running=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
    if [[ "$prev_running" =~ ^[0-9]+$ ]] && (( now_epoch - prev_running < TMUX_RUNNING_TTL )); then
        tmux set-option -w -t "$window_id" @code_notify_queued_prompt "$now_epoch" 2>/dev/null
    else
        tmux set-option -wu -t "$window_id" @code_notify_queued_prompt 2>/dev/null
    fi

    local spinner=0
    if tmux_running_spinner_enabled; then
        spinner=1
        # No rename in spinner mode: drop the event badge — before the running
        # marker below, so no repaint ever shows spinner and badge together.
        tmux_badge_clear_locked "$window_id"
    fi
    if ! tmux set-option -w -t "$window_id" @code_notify_running "$now_epoch" 2>/dev/null; then
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
        return 0
    fi
    tmux set-option -wu -t "$window_id" @code_notify_resume_pending 2>/dev/null
    tmux_resume_flag_clear "$window_id"
    tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
    tmux_idle_watch_disarm "$window_id"
    tmux_running_settle_arm "$window_id" "$TMUX_PANE"
    tmux_running_dialog_arm "$window_id" "$TMUX_PANE"
    if (( spinner )); then
        # Arm the snippet (a show-options no-op when already armed).
        tmux_agent_exit_track "$window_id"
        tmux_spinner_arm
    else
        tmux_badge_set_locked "$TMUX_RUNNING_ICON" running "$TMUX_PANE" skip "$window_id" || true
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    tmux_running_schedule_sweep $((TMUX_RUNNING_TTL + 2))
    return 0
}

# Unmark the caller's window: the agent emitted a terminating event. Drops the
# epoch, clears the rename marker if (and only if) the window still carries
# one — an event badge that replaced it in the meantime is left alone — and
# retires the spinner interval when this was the last running window.
#
# Pass "consume-queued-prompt" as $1 from genuine turn-end events (the
# notifier's stop/error path). When UserPromptSubmit left a queued-prompt
# hint — a submission arrived while this window's marker was still up — the
# ending turn has a successor already armed, so the teardown is skipped and
# the hint consumed: one hint covers one Stop, and the successor's own Stop
# clears normally. Callers that take the indicator down for other reasons
# (input pauses, auth completion, synthetic sweeps) must not pass the flag —
# a pending hint describes a future Stop, not their event.
# shellcheck disable=SC2120  # the flag is passed by notifier.sh, not this file
tmux_running_stop() {
    local honor_queued="${1:-}"
    # Out-param for notifier.sh: a preserved successor must keep its running
    # rendering instead of receiving this Stop's terminal badge.
    TMUX_RUNNING_STOP_PRESERVED=0
    tmux_focus_available || return 0
    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    tmux_running_transition_lock_acquire "$window_id" || return 0
    local transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    local transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    if [[ "$honor_queued" == "consume-queued-prompt" ]]; then
        local queued now_queued
        queued=$(tmux show-options -wqv -t "$window_id" @code_notify_queued_prompt 2>/dev/null)
        if [[ "$queued" =~ ^[0-9]+$ ]]; then
            tmux set-option -wu -t "$window_id" @code_notify_queued_prompt 2>/dev/null
            now_queued="$(date +%s)"
            if (( now_queued - queued < TMUX_RUNNING_TTL )); then
                # shellcheck disable=SC2034  # out-param read by notifier.sh
                TMUX_RUNNING_STOP_PRESERVED=1
                # The hint bets a successor turn is (or is about to be) running,
                # so keep the indicator. That bet is wrong for a FALSE hint: a
                # marker lingering from an interrupted turn (Esc/Ctrl-C emit no
                # Stop) makes the next prompt's UserPromptSubmit set a hint that
                # this same turn's only Stop then consumes, stranding the
                # indicator until idle_prompt (~a minute, and only if enabled)
                # or the 4h TTL. Arm a settle watch as the safety net: if the
                # pane holds still — no successor is actually running — the
                # agent-exit sweep retires the marker and applies the terminal
                # badge this Stop withheld. Badge only: the toast, sound and
                # voice already went out with this Stop (the preserve gates
                # nothing but the badge), so the reconcile must not deliver
                # the completion a second time. A genuine successor keeps
                # repainting (Claude/Codex animate an elapsed counter while
                # working) so the watch never fires, and that turn's own Stop
                # disarms it. Force past TMUX_SETTLE_AGENTS: this verifies any
                # agent's preserve, not just the no-stop ones.
                tmux_running_settle_arm "$window_id" "$pane_id" force
                tmux_running_transition_lock_release "$transition_lock" "$transition_token"
                return 0
            fi
        fi
    fi
    # A genuine terminal event must also retire a stale "waiting for input"
    # marker. tmux_running_pause_for_input sets it again after this cleanup,
    # and the notifier's stop path re-arms the idle watch after it.
    # The tracked agent PID is deliberately NOT dropped here: the event badge
    # this event leaves behind is cleaned by the agent-exit sweep, and not
    # every path through here can re-track it — badge-set skips a visible
    # window, and a synthetic notifier run (idle nudge, settle completion)
    # has no agent ancestry to re-resolve the PID from. An untrack that
    # nothing re-arms would orphan that badge forever once the agent exits.
    tmux set-option -wu -t "$window_id" @code_notify_resume_pending 2>/dev/null
    tmux_resume_flag_clear "$window_id"
    tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
    tmux_running_settle_disarm "$window_id"
    tmux_idle_watch_disarm "$window_id"
    local since mode
    since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
    if [[ -n "$since" ]]; then
        tmux set-option -wu -t "$window_id" @code_notify_running 2>/dev/null
        mode=$(tmux show-options -wqv -t "$window_id" @code_notify_clear_mode 2>/dev/null)
        if [[ "$mode" == "running" ]]; then
            tmux_badge_clear_locked "$window_id"
        fi
    fi
    tmux_spinner_disarm_if_idle
    if [[ -n "$since" ]] && tmux_running_spinner_enabled; then
        # Dropping the marker does not repaint the status line by itself, so
        # the spinner would linger until the next interval tick — or the event
        # badge's rename, which some stops never send (badge-set skips the
        # visible window). One status-only refresh makes the stop transition
        # as immediate as the start one. After disarm-if-idle so the repaint
        # sees the final state. Best-effort: targets the session's attached
        # client, and a detached session simply has no client to refresh.
        tmux refresh-client -S 2>/dev/null
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    return 0
}

# The notifier's per-tool-call hooks (PreToolUse/PostToolUse) only need to do
# work while some window is paused for input, yet learning "nothing pending"
# from the tmux server costs two client round-trips plus sourcing this library
# on every tool call. Mirror the pause state into a flag file per paused
# window so the hook can stat a directory before sourcing anything (see the
# fast gate in notifier.sh). The flag is advisory in both directions: a stale
# flag only routes hooks through the full path below (the pre-flag behavior),
# and a lost flag is healed by the resume poll, which resumes paused windows
# on its own. Flags are scoped by server socket basename so hooks on one
# server don't pay for a pause on another.
TMUX_RESUME_FLAG_DIR="$HOME/.claude/notifications/state/resume-pending"

tmux_resume_flag_path() {
    local window_id="$1" socket_base
    socket_base="${TMUX%%,*}"
    socket_base="${socket_base##*/}"
    printf '%s/%s.%s' "$TMUX_RESUME_FLAG_DIR" "${socket_base:-default}" "$window_id"
}

tmux_resume_flag_set() {
    local window_id="$1"
    mkdir -p "$TMUX_RESUME_FLAG_DIR" 2>/dev/null || return 0
    # Orphan GC: a window killed mid-pause takes @code_notify_resume_pending
    # with it, so no clear site ever fires for its flag. Anything older than
    # the running-marker TTL is certainly dead; a stale flag only costs the
    # slow path, so this coarse bound is enough and runs on the rare pause
    # event rather than in the per-tool-call hooks.
    find "$TMUX_RESUME_FLAG_DIR" -type f -mmin +$((TMUX_RUNNING_TTL / 60)) \
        -delete 2>/dev/null
    : > "$(tmux_resume_flag_path "$window_id")" 2>/dev/null
    return 0
}

tmux_resume_flag_clear() {
    local window_id="$1"
    rm -f "$(tmux_resume_flag_path "$window_id")" 2>/dev/null
    return 0
}

# An input/approval request pauses the current turn. Remember that state after
# taking down the running indicator so the next tool lifecycle event can put it
# back once the user has answered. A separate option is essential: PostToolUse
# fires after every tool, so using the absence of @code_notify_running alone
# would incorrectly mark completed or idle turns as active.
#
# Pass "watch" as $1 for answerable mid-turn dialogs (permission prompts, MCP
# elicitations), where answering resumes the turn without any hook firing:
# those additionally arm the activity poll (see TMUX_RESUME_POLL_SECONDS).
# Pauses that merely mark an idle agent (idle reminders) must not watch — no
# turn is running, so any pane activity after them (clicking the toast focuses
# and repaints the TUI, typing the next prompt echoes) would light the spinner
# with nothing going on.
tmux_running_pause_for_input() {
    local watch="${1:-}"
    tmux_focus_available || return 0
    tmux_running_stop

    local target session_id window_id pane_id
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    tmux set-option -w -t "$window_id" @code_notify_resume_pending "$(date +%s)" 2>/dev/null
    tmux_resume_flag_set "$window_id"
    # The answer itself emits no hook (see TMUX_RESUME_POLL_SECONDS), so watch
    # the pane while the dialog is outstanding. The deferred snapshot is the
    # settled dialog as rendered: the poll resumes only when pane CONTENT
    # changes on consecutive ticks (see tmux_resume_poll_sweep), because
    # #{window_activity} alone also advances on a mere glance — selecting the
    # window delivers a focus event and the TUI repaints, identically — and a
    # single content change can just be the dialog rendering late (this hook
    # fires before the dialog UI). The snapshot option doubles as the watch
    # flag: pauses without it (idle reminders) are never resumed by the poll.
    local pane_re='^%[0-9]+$'
    if [[ "$watch" == "watch" ]] && [[ "$pane_id" =~ $pane_re ]] && tmux_running_enabled; then
        # Do not snapshot synchronously inside the notification hook. While
        # this command is running, Claude/Codex renders the hook's transient
        # status message alongside the still-unanswered dialog; its removal
        # would otherwise look like an answer at the first poll and replace
        # the waiting badge with the running indicator. Store only the pane
        # now; the first poll records a baseline after the hook UI has settled.
        tmux set-option -w -t "$window_id" @code_notify_pause_fp \
            "$pane_id" 2>/dev/null
        tmux_resume_poll_schedule
    else
        # No watch: drop any earlier snapshot instead of letting an alive poll
        # chain (serving another window) resume this window on a later change.
        tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
    fi
    return 0
}

# PreToolUse/PostToolUse hooks call this after a user action. It is a no-op
# unless the same window previously emitted an input/approval request, so the
# extra hook events never create a spinner for unrelated tool completions.
tmux_running_resume_after_input() {
    tmux_focus_available || return 0

    local target session_id window_id pane_id pending
    target=$(tmux_focus_capture_target) || return 0
    read -r session_id window_id pane_id <<< "$target"
    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 0
    pending=$(tmux show-options -wqv -t "$window_id" @code_notify_resume_pending 2>/dev/null)
    [[ -n "$pending" ]] || return 0

    tmux_running_start
    return 0
}

# Window-targeted variant of tmux_running_start for contexts with no pane of
# their own (the resume poll's run-shell payload). Skips agent-exit tracking —
# there is no hook-process ancestry to resolve a PID from here; the next real
# hook event re-tracks, and the TTL sweep covers runs that never get one.
tmux_running_resume_window() {
    local window_id="$1"
    tmux_running_enabled || return 0
    [[ "$window_id" =~ ^@[0-9]+$ ]] || return 0
    local transition_lock transition_token spinner=0
    tmux_running_transition_lock_acquire "$window_id" || return 0
    transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
    transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
    if tmux_running_spinner_enabled; then
        spinner=1
        # Same shape as tmux_running_start: the waiting badge must not sit
        # next to a live spinner, so it clears before the marker lands.
        tmux_badge_clear_locked "$window_id"
    fi
    if ! tmux set-option -w -t "$window_id" @code_notify_running "$(date +%s)" 2>/dev/null; then
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
        return 0
    fi
    tmux set-option -wu -t "$window_id" @code_notify_resume_pending 2>/dev/null
    tmux_resume_flag_clear "$window_id"
    tmux set-option -wu -t "$window_id" @code_notify_pause_fp 2>/dev/null
    tmux_idle_watch_disarm "$window_id"
    # The dialog watch's context survives the pause (see
    # tmux_running_dialog_arm), but a sighting epoch recorded before it must
    # not carry into the resumed turn — a later dialog would fire without
    # its confirmation tick.
    tmux set-option -wu -t "$window_id" @code_notify_dialog_since 2>/dev/null
    if (( spinner )); then
        tmux_spinner_arm
    elif tmux_badge_enabled; then
        tmux_badge_set_locked "$TMUX_RUNNING_ICON" running "$window_id" skip "$window_id" || true
    fi
    tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    tmux_running_schedule_sweep $((TMUX_RUNNING_TTL + 2))
    return 0
}

# One short tmux-server timer watches paused windows for a content change,
# the earliest observable sign that the user answered an approval/input
# dialog (Claude Code emits no hook at answer time — only when the approved
# tool completes). Same pattern as tmux_agent_exit_schedule_sweep: repeating
# one-shots, a token-carrying global flag prevents stacking (a fired timer
# the flag no longer names exits without polling), and the chain stops as
# soon as no watched pause remains (or the outstanding ones outlive the poll
# TTL).
# The poll settings and the active running-indicator configuration ride along
# in the payload's environment: the timer's fresh process would otherwise
# fall back to defaults, flipping a session that forced e.g.
# CODE_NOTIFY_TMUX_SPINNER=false back to the flag-file rendering (or losing a
# custom icon/TTL) the moment it resumes. Empty values behave exactly like
# unset ones in the corresponding checks, so unset overrides pass through
# harmlessly.
tmux_resume_poll_schedule() {
    [[ "${TMUX_RESUME_POLL_SECONDS:-0}" =~ ^[0-9]+$ ]] || return 0
    (( TMUX_RESUME_POLL_SECONDS > 0 )) || return 0
    [[ -n "$TMUX_BADGE_LIB_PATH" ]] && [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 0
    local pending tmux_bin socket_path token q_lib q_tmux q_socket q_env q_poll q_ttl q_token inner
    local q_running q_spinner q_badge q_icon q_rttl
    pending=$(tmux show-options -gqv @code_notify_resume_poll_scheduled 2>/dev/null)
    [[ -z "$pending" ]] || return 0
    tmux_bin=$(command -v tmux) || return 0
    socket_path="${TMUX%%,*}"
    [[ -n "$socket_path" ]] || return 0
    tmux_timer_chain_token
    token="$TMUX_TIMER_CHAIN_TOKEN"
    q_token=$(tmux_focus_shell_quote "$token")
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_env=$(tmux_focus_shell_quote "$TMUX")
    q_poll=$(tmux_focus_shell_quote "$TMUX_RESUME_POLL_SECONDS")
    q_ttl=$(tmux_focus_shell_quote "$TMUX_RESUME_POLL_TTL")
    # Enablement flags forward the raw env overrides (persistent flag files
    # are re-read fresh by the fired process); icon, running-TTL and the
    # dialog-marker pattern forward the resolved values, matching the
    # running-sweep timer.
    q_running=$(tmux_focus_shell_quote "${CODE_NOTIFY_TMUX_RUNNING:-}")
    q_spinner=$(tmux_focus_shell_quote "${CODE_NOTIFY_TMUX_SPINNER:-}")
    q_badge=$(tmux_focus_shell_quote "${CODE_NOTIFY_TMUX_BADGE:-}")
    q_icon=$(tmux_focus_shell_quote "$TMUX_RUNNING_ICON")
    q_rttl=$(tmux_focus_shell_quote "$TMUX_RUNNING_TTL")
    local q_markers q_options
    q_markers=$(tmux_focus_shell_quote "$TMUX_DIALOG_MARKERS")
    q_options=$(tmux_focus_shell_quote "$TMUX_DIALOG_OPTIONS")
    inner="cur=\$($q_tmux -S $q_socket show-options -gqv @code_notify_resume_poll_scheduled 2>/dev/null); "
    inner+="if [ \"\$cur\" != $q_token ]; then exit 0; fi; "
    inner+="$q_tmux -S $q_socket set-option -gu @code_notify_resume_poll_scheduled; "
    inner+="if [ -f $q_lib ]; then TMUX=$q_env CODE_NOTIFY_TMUX_RESUME_POLL_SECONDS=$q_poll "
    inner+="CODE_NOTIFY_TMUX_RESUME_POLL_TTL=$q_ttl "
    inner+="CODE_NOTIFY_TMUX_RUNNING=$q_running CODE_NOTIFY_TMUX_SPINNER=$q_spinner "
    inner+="CODE_NOTIFY_TMUX_BADGE=$q_badge CODE_NOTIFY_TMUX_RUNNING_ICON=$q_icon "
    inner+="CODE_NOTIFY_TMUX_RUNNING_TTL=$q_rttl CODE_NOTIFY_TMUX_DIALOG_OPTIONS=$q_options "
    inner+="CODE_NOTIFY_TMUX_DIALOG_MARKERS=$q_markers bash $q_lib resume-poll; fi"
    inner="${inner//\#/##}"
    # Claim before arming (see tmux_timer_chain_token); a failed arm rolls
    # back only a claim that is still ours, compared-and-cleared server-side
    # in one command.
    tmux set-option -g @code_notify_resume_poll_scheduled "$token" 2>/dev/null || return 0
    if ! tmux run-shell -b -d "$TMUX_RESUME_POLL_SECONDS" "$inner" 2>/dev/null; then
        tmux if-shell -F "#{==:#{@code_notify_resume_poll_scheduled},$token}" \
            "set-option -gu @code_notify_resume_poll_scheduled" 2>/dev/null
    fi
    return 0
}

# Checksum of a pane's visible content, used to tell an answered dialog from
# a merely re-rendered one. cksum is POSIX and lives in /usr/bin, so it
# resolves even under run-shell's minimal PATH; its "sum size" output is
# treated as an opaque token. Fails with no output when the pane cannot be
# captured — piping capture-pane straight into cksum would hide that failure
# as the (valid-looking) checksum of empty input, and a vanished pane would
# read as "content changed".
tmux_resume_poll_fingerprint() {
    local pane_id="$1" content
    content=$(tmux capture-pane -p -t "$pane_id" 2>/dev/null) || return 1
    printf '%s\n' "$content" | cksum 2>/dev/null
}

# Resume the running indicator on watched windows whose pane content changed
# after the pause: the user answered the dialog. Two filters precede the
# content check. Per-pause TTL first: a request nobody answers stops being
# polled after TMUX_RESUME_POLL_TTL even while a fresher pause keeps the
# chain alive — its retained marker stays answerable through the tool
# lifecycle hooks. Then #{window_activity} as a cheap pre-filter: no pane
# output at all since the pause (with one second of grace for the dialog's
# own render straggling past the epoch) means no answer, without spawning a
# capture. Activity alone is NOT sufficient to resume — visiting the window
# delivers a focus event and the TUI repaints identically, so only a changed
# fingerprint counts.
#
# One changed fingerprint is not sufficient either: the approval dialog can
# render long after the pause snapshot (the PermissionRequest hook fires
# before the dialog UI, and in Ctrl+O verbose mode the dialog only paints
# once the user leaves the transcript view), and a focus repaint or view
# toggle can shift content without any answer. Each of those is a ONE-SHOT
# change: the pane repaints once and holds still again. An answered dialog
# instead puts the agent back to work, whose TUI repaints continuously (the
# elapsed-seconds counter — the same property the settle watch relies on).
# So resume only when the content changes on two consecutive ticks; a
# single change re-baselines (flagged in the snapshot option) and a still
# tick clears the flag.
#
# The fingerprint heuristic still fails when the pane animates WHILE the
# dialog waits — a backgrounded shell command's flashing dot or ticking
# timer changes the content on every tick with no answer given. So the
# strongest signal comes first: while the capture matches
# TMUX_DIALOG_MARKERS, the dialog is provably on screen and the poll never
# resumes, however much the rest of the pane moves. The marker vanishing is
# NOT itself an answer (Ctrl+O hides the dialog behind the transcript view);
# it re-baselines and hands over to the fingerprint heuristic. False
# positives that remain (the user scrolling or typing steadily in a
# marker-less view) merely show the spinner early; the next hook event
# re-derives the true state.
tmux_resume_poll_sweep() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local now window_id pending activity fp pane fp_sum fp_size changed dialog
    local fp_saved fp_now content marker_now waiting=0
    now=$(date +%s)
    while IFS='|' read -r window_id pending activity fp; do
        [[ "$window_id" =~ ^@[0-9]+$ ]] || continue
        [[ "$pending" =~ ^[0-9]+$ ]] || continue
        # Only watch-mode pauses carry a pane id, followed (after the first
        # poll) by a dialog snapshot — the two cksum fields, a changed flag
        # (1 when the previous tick saw the content change) and a dialog flag
        # (1 when it saw the dialog marker on screen). Idle-style pauses
        # carry none of this and resume through their hooks, never the poll.
        read -r pane fp_sum fp_size changed dialog <<< "$fp"
        fp_saved="$fp_sum $fp_size"
        [[ "$pane" =~ ^%[0-9]+$ ]] || continue
        (( now - pending < TMUX_RESUME_POLL_TTL )) || continue
        # The pause hook itself temporarily changes the rendered TUI. Defer
        # the baseline until this first timer tick, after that status has gone
        # away, so hook completion cannot be mistaken for user input.
        if [[ -z "$fp_sum" ]]; then
            if [[ "$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)" != "$window_id" ]]; then
                waiting=1
                continue
            fi
            if content=$(tmux capture-pane -p -t "$pane" 2>/dev/null); then
                fp_now=$(printf '%s\n' "$content" | cksum 2>/dev/null)
                if [[ -n "$fp_now" ]]; then
                    tmux set-option -w -t "$window_id" @code_notify_pause_fp \
                        "$pane $fp_now 0 $(tmux_resume_poll_dialog_flag "$content")" 2>/dev/null
                fi
            fi
            waiting=1
            continue
        fi
        if [[ ! "$activity" =~ ^[0-9]+$ ]] || (( activity <= pending + 1 )); then
            waiting=1
            continue
        fi
        # The recorded pane can vanish (its split closed) or move to another
        # window (break-pane) while the dialog waits; an empty or
        # wrong-window capture must not read as "content changed". Such
        # windows stay in waiting state until a hook, the agent-exit
        # monitor, or the poll TTL retires them.
        if [[ "$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null)" != "$window_id" ]]; then
            waiting=1
            continue
        fi
        if ! content=$(tmux capture-pane -p -t "$pane" 2>/dev/null); then
            waiting=1
            continue
        fi
        fp_now=$(printf '%s\n' "$content" | cksum 2>/dev/null)
        if [[ -z "$fp_now" ]]; then
            waiting=1
            continue
        fi
        marker_now=$(tmux_resume_poll_dialog_flag "$content")
        if [[ "$marker_now" == "1" ]]; then
            # The dialog text is on screen: unanswered, no matter what else
            # in the pane animates. Track the moving content so its eventual
            # disappearance is judged against the freshest baseline.
            tmux set-option -w -t "$window_id" @code_notify_pause_fp \
                "$pane $fp_now 0 1" 2>/dev/null
            waiting=1
        elif [[ "$dialog" == "1" ]]; then
            # The marker just vanished — an answer OR a view toggle hiding
            # the dialog. Re-baseline and let the fingerprint heuristic
            # decide from here: an answered turn keeps repainting, a
            # transcript view over a waiting dialog holds still.
            tmux set-option -w -t "$window_id" @code_notify_pause_fp \
                "$pane $fp_now 0 0" 2>/dev/null
            waiting=1
        elif [[ "$fp_now" != "$fp_saved" ]]; then
            if [[ "$changed" == "1" ]]; then
                # Second consecutive changed tick: the pane is repainting
                # continuously, so the agent is working again.
                tmux_running_resume_window "$window_id"
            else
                # First change: could be the dialog finally rendering or a
                # focus/view repaint. Re-baseline, remember that this tick
                # changed, and let the next tick decide.
                tmux set-option -w -t "$window_id" @code_notify_pause_fp \
                    "$pane $fp_now 1 0" 2>/dev/null
                waiting=1
            fi
        else
            # Still tick: a preceding one-shot change was not an answer, so
            # drop the changed flag.
            if [[ "$changed" == "1" ]]; then
                tmux set-option -w -t "$window_id" @code_notify_pause_fp \
                    "$pane $fp_now 0 0" 2>/dev/null
            fi
            waiting=1
        fi
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{@code_notify_resume_pending}|#{window_activity}|#{@code_notify_pause_fp}' 2>/dev/null)
    if [[ "$waiting" -eq 1 ]]; then
        tmux_resume_poll_schedule
    fi
    return 0
}

# Whether captured pane content shows an approval/input dialog (see
# TMUX_DIALOG_MARKERS / TMUX_DIALOG_OPTIONS). Prints 1 or 0 so callers can
# embed the answer in the packed snapshot option. Requires the question
# prompt AND — unless TMUX_DIALOG_OPTIONS is empty — a Yes/No selector row, so
# a lone "Do you want …" line in prose is not mistaken for the dialog.
tmux_resume_poll_dialog_flag() {
    local content="$1"
    # -e guards patterns that begin with "-" (a user-supplied override) from
    # being parsed as grep options.
    if [[ -z "$TMUX_DIALOG_MARKERS" ]] ||
        ! printf '%s\n' "$content" | grep -qE -e "$TMUX_DIALOG_MARKERS" 2>/dev/null; then
        printf '0'
        return
    fi
    if [[ -n "$TMUX_DIALOG_OPTIONS" ]] &&
        ! printf '%s\n' "$content" | grep -qE -e "$TMUX_DIALOG_OPTIONS" 2>/dev/null; then
        printf '0'
        return
    fi
    printf '1'
}

# The piggyback call sites above all require *something* to happen on this
# server later — another badge, another prompt. A run that ends without a
# terminal hook (the Escape-interrupt case the TTL exists for) on an otherwise
# quiet server would keep its static 🌕 rename forever, and in spinner mode
# keep status-interval at 1 even after the snippet blanks itself past the TTL.
# So while any fresh marker exists, park a one-shot `run-shell -b -d` timer on
# the tmux server itself that re-runs the sweep just after the oldest marker
# expires. The pending timer is tracked in the global option
# @code_notify_sweep_scheduled so repeat sweeps don't stack timers; the flag
# carries the chain token (see tmux_timer_chain_token), the payload sweeps
# only while it still owns the flag, and that sweep re-schedules when fresher
# markers remain. `run-shell -d` needs tmux >= 3.2 — on older servers the call
# fails, the claimed flag is rolled back, and behavior degrades to
# piggyback-only convergence. Like the focus hook, the payload guards against
# the lib having
# been uninstalled before the timer fires; TMUX is passed explicitly because
# run-shell's environment does not guarantee it, the TTL is passed so the
# fired sweep judges staleness by the same clock that computed the delay (the
# timer's fresh process would otherwise fall back to the default), and # is
# doubled because run-shell format-expands its argument when it executes.
tmux_running_schedule_sweep() {
    local delay="$1"
    [[ -n "$TMUX_BADGE_LIB_PATH" ]] && [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 0
    local pending
    pending=$(tmux show-options -gqv @code_notify_sweep_scheduled 2>/dev/null)
    [[ -z "$pending" ]] || return 0
    local tmux_bin socket_path token q_lib q_tmux q_socket q_env q_ttl q_token inner
    tmux_bin=$(command -v tmux) || return 0
    socket_path="${TMUX%%,*}"
    [[ -n "$socket_path" ]] || return 0
    tmux_timer_chain_token
    token="$TMUX_TIMER_CHAIN_TOKEN"
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_tmux=$(tmux_focus_shell_quote "$tmux_bin")
    q_socket=$(tmux_focus_shell_quote "$socket_path")
    q_env=$(tmux_focus_shell_quote "$TMUX")
    q_ttl=$(tmux_focus_shell_quote "$TMUX_RUNNING_TTL")
    q_token=$(tmux_focus_shell_quote "$token")
    inner="cur=\$($q_tmux -S $q_socket show-options -gqv @code_notify_sweep_scheduled 2>/dev/null); "
    inner+="if [ \"\$cur\" != $q_token ]; then exit 0; fi; "
    inner+="$q_tmux -S $q_socket set-option -gu @code_notify_sweep_scheduled; "
    inner+="if [ -f $q_lib ]; then TMUX=$q_env CODE_NOTIFY_TMUX_RUNNING_TTL=$q_ttl "
    inner+="bash $q_lib running-sweep; fi"
    inner="${inner//\#/##}"
    # Claim before arming (see tmux_timer_chain_token); a failed arm rolls
    # back only a claim that is still ours, compared-and-cleared server-side
    # in one command.
    tmux set-option -g @code_notify_sweep_scheduled "$token" 2>/dev/null || return 0
    if ! tmux run-shell -b -d "$delay" "$inner" 2>/dev/null; then
        tmux if-shell -F "#{==:#{@code_notify_sweep_scheduled},$token}" \
            "set-option -gu @code_notify_sweep_scheduled" 2>/dev/null
    fi
    return 0
}

# Retire running markers whose epoch is older than the TTL: unset the option,
# restore the window name when the rename marker is still in place, and stop
# the spinner redraw if nothing is left running. Piggybacked on every badge
# sweep and every running-start so dead runs converge without a daemon, with
# the scheduled one-shot timer above covering servers where no such activity
# ever comes.
tmux_running_sweep_stale() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local now window_id since mode oldest="" retry=0
    local transition_lock transition_token current_since
    now=$(date +%s)
    while IFS='|' read -r window_id since mode; do
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        if [[ $((now - since)) -lt "$TMUX_RUNNING_TTL" ]]; then
            # Still fresh: remember the oldest epoch so the timer below fires
            # right after the first marker can actually expire.
            if [[ -z "$oldest" ]] || [[ "$since" -lt "$oldest" ]]; then
                oldest="$since"
            fi
            continue
        fi
        if ! tmux_running_transition_lock_acquire "$window_id"; then
            retry=1
            continue
        fi
        transition_lock="$TMUX_RUNNING_TRANSITION_LOCKDIR"
        transition_token="$TMUX_RUNNING_TRANSITION_LOCKTOKEN"
        current_since=$(tmux show-options -wqv -t "$window_id" @code_notify_running 2>/dev/null)
        if [[ "$current_since" != "$since" ]] || [[ ! "$current_since" =~ ^[0-9]+$ ]] ||
            (( now - current_since < TMUX_RUNNING_TTL )); then
            tmux_running_transition_lock_release "$transition_lock" "$transition_token"
            continue
        fi
        tmux set-option -wu -t "$window_id" @code_notify_running 2>/dev/null
        tmux_running_settle_disarm "$window_id"
        tmux_idle_watch_disarm "$window_id"
        mode=$(tmux show-options -wqv -t "$window_id" @code_notify_clear_mode 2>/dev/null)
        if [[ "$mode" == "running" ]]; then
            tmux_badge_clear_locked "$window_id"
        fi
        tmux_running_transition_lock_release "$transition_lock" "$transition_token"
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{@code_notify_running}|#{@code_notify_clear_mode}' 2>/dev/null)
    if (( retry )); then
        tmux_running_schedule_sweep 1
    elif [[ -n "$oldest" ]]; then
        tmux_running_schedule_sweep $((oldest + TMUX_RUNNING_TTL - now + 2))
    fi
    tmux_spinner_disarm_if_idle
    return 0
}

# Re-render active running markers as static window-name icons: every window
# whose @code_notify_running epoch is still fresh gets the badge it would have
# received had the spinner never been armed. Used by `cn spinner off` while
# agents are still working — the status-line snippet vanishes the moment the
# spinner disarms, so without this those windows would carry no indicator at
# all until their runs end. Stale epochs are left to the sweep.
tmux_running_apply_static_badges() {
    tmux_running_enabled || return 0
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local now window_id since
    now=$(date +%s)
    while IFS='|' read -r window_id since; do
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        [[ $((now - since)) -lt "$TMUX_RUNNING_TTL" ]] || continue
        tmux_badge_set "$TMUX_RUNNING_ICON" running "$window_id" || continue
    done < <(tmux list-windows -a -F '#{window_id}|#{@code_notify_running}' 2>/dev/null)
    return 0
}

# The inverse, for `cn spinner on` while agents are mid-run: their windows
# carry the static running rename, and the snippet renders from the very same
# epoch — leaving the rename in place would show both indicators at once.
# Drop the rename (the epoch stays: it is what the spinner keys on) and arm
# the snippet when any fresh marker exists, so the animation takes over
# immediately instead of waiting for the next hook event.
tmux_running_convert_static_badges_to_spinner() {
    { [[ -n "${TMUX:-}" ]] && command -v tmux &> /dev/null; } || return 0
    local now window_id since mode live=0
    now=$(date +%s)
    while IFS='|' read -r window_id since mode; do
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        [[ $((now - since)) -lt "$TMUX_RUNNING_TTL" ]] || continue
        live=1
        if [[ "$mode" == "running" ]]; then
            tmux_badge_clear "$window_id"
        fi
    done < <(tmux list-windows -a -F \
        '#{window_id}|#{@code_notify_running}|#{@code_notify_clear_mode}' 2>/dev/null)
    if [[ "$live" -eq 1 ]]; then
        tmux_spinner_arm
    fi
    return 0
}

# Build the command a notifier click handler runs to clear the badge on the
# originating window. Same execution context as tmux_focus_build_command
# (/bin/sh -c, minimal PATH, no attached client), so it embeds the tmux path,
# socket environment and this library's absolute path. The library subcommand
# takes the same bounded per-window lock as hook-driven clears; a notification
# click therefore cannot race a concurrent event into a stacked badge.
tmux_badge_build_clear_command() {
    local target session_id window_id pane_id tmux_bin socket_path bash_bin clear_path

    target=$(tmux_focus_capture_target) || return 1
    read -r session_id window_id pane_id <<< "$target"

    local window_re='^@[0-9]+$'
    [[ "$window_id" =~ $window_re ]] || return 1

    tmux_bin=$(command -v tmux)
    socket_path="${TMUX%%,*}"
    if [[ -z "$tmux_bin" ]] || [[ -z "$socket_path" ]]; then
        return 1
    fi
    bash_bin="${BASH:-$(command -v bash 2>/dev/null)}"
    [[ -x "$bash_bin" ]] || return 1
    [[ -f "$TMUX_BADGE_LIB_PATH" ]] || return 1
    clear_path="${tmux_bin%/*}:${PATH:-/usr/bin:/bin}"

    local q_bash q_lib q_env q_path q_window
    q_bash=$(tmux_focus_shell_quote "$bash_bin")
    q_lib=$(tmux_focus_shell_quote "$TMUX_BADGE_LIB_PATH")
    q_env=$(tmux_focus_shell_quote "$TMUX")
    q_path=$(tmux_focus_shell_quote "$clear_path")
    q_window=$(tmux_focus_shell_quote "$window_id")

    printf '%s' "if [ -f $q_lib ]; then TMUX=$q_env PATH=$q_path $q_bash $q_lib badge-clear-window $q_window; fi"
}

# When run as a script rather than sourced, dispatch the requested subcommand:
#   - badge-sweep: the tmux focus hook (`bash <this> badge-sweep`)
#   - badge-clear-current: the UserPromptSubmit hook clearing this window's badge
#   - badge-clear-window: a notification click clearing a resolved window id
#   - running-sweep: the scheduled stale-marker timer (tmux_running_schedule_sweep)
# Sourcing — the normal path, where BASH_SOURCE[0] differs from $0 — skips this.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        badge-sweep) tmux_badge_sweep ;;
        badge-clear-current) tmux_badge_clear_current ;;
        badge-clear-window) tmux_badge_clear "${2:-}" ;;
        running-start) tmux_running_start ;;
        running-stop) tmux_running_stop ;;
        running-pause) tmux_running_pause_for_input "${2:-}" ;;
        running-resume) tmux_running_resume_after_input ;;
        agent-exit-sweep) tmux_agent_exit_sweep ;;
        resume-poll) tmux_resume_poll_sweep ;;
        running-sweep) tmux_running_sweep_stale ;;
    esac
fi
