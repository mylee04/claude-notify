#!/bin/bash

# Core notification functionality for Code-Notify
# Supports: Claude Code, Codex, Gemini CLI

# Get arguments:
#   Claude/Gemini: notify.sh <hook_type> <tool_name> [project_name]
#   Codex (hooks): notify.sh <hook_type> codex      (payload JSON on stdin)
#   Codex (legacy notify=): notify.sh codex <payload_json>
# The legacy form is retained for users upgrading from the config.toml notify
# integration who have not yet re-run `cn on codex`.
RAW_ARG1="${1:-}"
RAW_ARG2="${2:-}"
RAW_ARG3="${3:-}"

# opencode compatibility plugins (e.g. oh-my-openagent) replay the Claude Code
# hooks from settings.json inside opencode's own process, so this notifier can
# fire for an agent it does not support: UserPromptSubmit starts the tmux
# spinner, but opencode never delivers a compatible turn-end, so the spinner
# never clears — and notifications fire for turns code-notify cannot track.
# opencode exports OPENCODE=1 and OPENCODE_PID into every process it spawns
# (and into nothing else — an agent in a sibling window is unaffected); bail
# out before touching any badge, spinner, or notification state.
if [[ -n "${OPENCODE:-}" ]] || [[ -n "${OPENCODE_PID:-}" ]]; then
    exit 0
fi

NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# UserPromptSubmit (any agent whose installer registered the hook — Claude,
# Codex): the user just handed this window more work, so clear its badge — the
# accurate "no longer waiting" signal, unlike a mere glance. No notification
# fires for this event. Handled before the utility sourcing below because the
# agent runs this hook synchronously on every prompt submission, so the path
# must stay cheap: it only needs tmux.sh.
# Antigravity exports CLAUDE_HOOK_TYPE for compatibility even though its
# wrappers identify their lifecycle event as agy:<Event> in argv. Keep those
# events on the dedicated Antigravity path below; otherwise an agy PostToolUse
# would be mistaken for a Claude/Codex spinner-resume hook.
if [[ "$RAW_ARG1" != agy:* ]] && [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "UserPromptSubmit" ]]; then
    source "$NOTIFIER_DIR/../utils/tmux.sh"
    # Let tmux.sh associate the marker with the actual agent process, so an
    # explicit tool exit can clear it even though Codex has no SessionEnd hook.
    CODE_NOTIFY_TMUX_AGENT_NAME="${RAW_ARG2:-}"
    # One capture serves both halves: the event badge clears (engage-clear)
    # and the running marker — the agent is now working — replaces it.
    tmux_prompt_submit 2>/dev/null || true
    exit 0
fi

# A direct prompt submission is not the only way an agent resumes: approving a
# command or answering an in-turn question continues the existing turn. Those
# actions do not emit UserPromptSubmit, so the lightweight PostToolUse hook and
# the fallback PreToolUse hook use this path to restore the running indicator.
# tmux_running_resume_after_input itself is gated by a marker set only when the
# notifier observed an input/approval request, making ordinary tool hooks
# no-ops.
if [[ "$RAW_ARG1" != agy:* ]] && {
    [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "PostToolUse" ]] ||
    [[ "${CLAUDE_HOOK_TYPE:-$RAW_ARG1}" == "ResumeAfterInput" ]]
}; then
    # Fast gate: that marker is mirrored to a flag file per paused window (see
    # tmux_resume_flag_set) precisely so this hook — which the agent runs
    # synchronously around every tool call — can stat a directory instead of
    # sourcing the tmux library and making two server round-trips just to
    # learn nothing is pending. Outside tmux, or with no flag for this
    # server's socket, there is nothing to resume. A stale flag only costs
    # the full path below; a lost flag is healed by the resume poll.
    [[ -n "${TMUX:-}" ]] || exit 0
    RESUME_SOCKET_BASE="${TMUX%%,*}"
    RESUME_SOCKET_BASE="${RESUME_SOCKET_BASE##*/}"
    RESUME_FLAGS=("$HOME/.claude/notifications/state/resume-pending/${RESUME_SOCKET_BASE:-default}".*)
    [[ -e "${RESUME_FLAGS[0]}" ]] || exit 0
    source "$NOTIFIER_DIR/../utils/tmux.sh"
    CODE_NOTIFY_TMUX_AGENT_NAME="${RAW_ARG2:-}"
    tmux_running_resume_after_input 2>/dev/null || true
    exit 0
fi

# Source shared utilities
source "$NOTIFIER_DIR/../utils/detect.sh"
source "$NOTIFIER_DIR/../utils/voice.sh"
source "$NOTIFIER_DIR/../utils/sound.sh"
source "$NOTIFIER_DIR/../utils/tts.sh"
source "$NOTIFIER_DIR/../utils/channels.sh"
source "$NOTIFIER_DIR/../utils/usage.sh"
source "$NOTIFIER_DIR/../utils/click-through-store.sh"
source "$NOTIFIER_DIR/../utils/click-through-runtime.sh"
source "$NOTIFIER_DIR/../utils/click-through-resolver.sh"
source "$NOTIFIER_DIR/../utils/tmux.sh"
source "$NOTIFIER_DIR/../utils/snooze.sh"
source "$NOTIFIER_DIR/../utils/persist.sh"

# A synthetic run spawned by one of the tmux watches (idle nudge, approval
# dialog) may have been overtaken between its fork and this line — the user
# answers, the turn resumes, and this process would tear that fresh run down
# and toast about a dialog already dealt with. The scheduler passed in what it
# validated; bail before any state change or delivery if it no longer holds.
# Both conditions are required so a run without the guard env — every real
# hook — is never affected, even if tmux.sh failed to define the helper.
if [[ -n "${CODE_NOTIFY_TMUX_GUARD_WINDOW:-}" ]] &&
    declare -f tmux_synthetic_guard_ok > /dev/null 2>&1 &&
    ! tmux_synthetic_guard_ok 2>/dev/null; then
    exit 0
fi

has_jq() {
    command -v jq >/dev/null 2>&1
}

has_python3() {
    command -v python3 >/dev/null 2>&1
}

json_extract_string() {
    local json="$1"
    local key="$2"

    if [[ -z "$json" ]]; then
        return 0
    fi

    if has_jq; then
        printf '%s' "$json" | jq -r --arg key "$key" '(.[$key] // "") | if type == "string" then . else "" end' 2>/dev/null
        return 0
    fi

    if has_python3; then
        printf '%s' "$json" | python3 -c '
import json, sys
key = sys.argv[1]
try:
    value = json.load(sys.stdin).get(key, "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' "$key" 2>/dev/null
        return 0
    fi

    case "$key" in
        "type")
            printf '%s' "$json" | sed -nE 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "notification_type")
            printf '%s' "$json" | sed -nE 's/.*"notification_type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "cwd")
            printf '%s' "$json" | sed -nE 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "conversationId")
            # Needed so Antigravity debounce tokens stay per-conversation even
            # without jq/python3; otherwise every session collapses onto the
            # default token and concurrent turns cancel each other's completion.
            printf '%s' "$json" | sed -nE 's/.*"conversationId"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "session_id")
            # Claude lifecycle and Notification hooks share this identifier.
            # It lets the notifier correlate an AskUserQuestion PreToolUse
            # event with Claude's generic permission_prompt for the same UI.
            printf '%s' "$json" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "tool_name")
            printf '%s' "$json" | sed -nE 's/.*"tool_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
        "error")
            # StopFailure payloads carry the API error class here (rate_limit,
            # server_error, ...); it selects the limit-reached badge. The
            # pattern anchors on the colon so "error_details" cannot match.
            printf '%s' "$json" | sed -nE 's/.*"error"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
            ;;
    esac
}

# Extract the payload's type ("type", falling back to "notification_type")
# in a single interpreter spawn — this runs before every notification, so
# spawn count directly delays the banner.
get_payload_type_field() {
    local json="$1"

    if [[ -z "$json" ]]; then
        return 0
    fi

    if has_jq; then
        printf '%s' "$json" | jq -r '(((.type | strings) // (.notification_type | strings)) // "")' 2>/dev/null
        return 0
    fi

    if has_python3; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    value = data.get("type") or data.get("notification_type") or ""
except Exception:
    value = ""
print(value if isinstance(value, str) else "", end="")
' 2>/dev/null
        return 0
    fi

    local value
    value=$(json_extract_string "$json" "type")
    if [[ -z "$value" ]]; then
        value=$(json_extract_string "$json" "notification_type")
    fi
    printf '%s' "$value"
}

get_codex_hook_type() {
    local payload_type
    payload_type=$(json_extract_string "$HOOK_DATA" "type" | tr '[:upper:]' '[:lower:]')

    case "$payload_type" in
        "agent-turn-complete")
            printf '%s\n' "stop"
            return 0
            ;;
        *"request_permissions"*|*"permission"*|*"approval"*|*"elicitation"*|*"prompt"*)
            printf '%s\n' "notification"
            return 0
            ;;
        *"error"*|*"failed"*)
            printf '%s\n' "error"
            return 0
            ;;
    esac

    if [[ "$HOOK_DATA" == *"last-assistant-message"* ]]; then
        printf '%s\n' "stop"
    elif [[ "$HOOK_DATA" == *"request_permissions"* ]] || [[ "$HOOK_DATA" == *"approval"* ]] || [[ "$HOOK_DATA" == *"permission"* ]]; then
        printf '%s\n' "notification"
    else
        printf '%s\n' "stop"
    fi
}

get_codex_project_name() {
    local payload_cwd
    payload_cwd=$(json_extract_string "$HOOK_DATA" "cwd")

    if [[ -n "$payload_cwd" ]]; then
        get_project_name_at "$payload_cwd"
    else
        get_project_name
    fi
}

# --- Antigravity CLI (agy) payload helpers ---
# agy hooks deliver a JSON payload on stdin and pass no argv; the calling
# wrapper encodes the lifecycle event as the first arg ("agy:<Event>").

# Absolute path to this notifier, used to re-invoke ourselves from the
# debounce watcher (notifier.sh does not source config.sh / get_notify_script).
SELF_NOTIFIER="$NOTIFIER_DIR/$(basename "${BASH_SOURCE[0]}")"

# Project name from the first workspace path (falls back to cwd).
get_agy_project_name() {
    local ws=""
    if has_jq; then
        ws=$(printf '%s' "$HOOK_DATA" | jq -r '(.workspacePaths[0] // "")' 2>/dev/null)
    elif has_python3; then
        ws=$(printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    paths = json.load(sys.stdin).get("workspacePaths") or []
    print(paths[0] if paths else "", end="")
except Exception:
    print("", end="")
' 2>/dev/null)
    fi
    if [[ -n "$ws" ]]; then
        get_project_name_at "$ws"
    else
        get_project_name
    fi
}

# Returns non-empty when the payload reports a tool failure. agy may send
# `error` as a plain string OR as a structured HookErrorMessage object, so a
# string-only check would misclassify real failures as success.
get_agy_error() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '
            (.error // empty) as $e
            | if   ($e | type) == "string" then $e
              elif ($e | type) == "object" then (if ($e | length) > 0 then ($e.message // "error") else "" end)
              elif ($e | type) == "null"   then ""
              else ($e | tostring) end' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    e = json.load(sys.stdin).get("error")
except Exception:
    e = None
if e is None:
    print("", end="")
elif isinstance(e, str):
    print(e, end="")
elif isinstance(e, dict):
    print((e.get("message") or "error") if e else "", end="")
else:
    print(str(e), end="")
' 2>/dev/null
        return 0
    fi
    # Last resort (no jq/python): regex on the raw payload. An empty string
    # error (`"error":""`) is success; a non-empty string or an object
    # (`"error":{...}`) is a failure. Matching the empty form first avoids
    # misreading a structured failure as success.
    if printf '%s' "$HOOK_DATA" | grep -Eq '"error"[[:space:]]*:[[:space:]]*""'; then
        return 0
    fi
    if printf '%s' "$HOOK_DATA" | grep -Eq '"error"[[:space:]]*:[[:space:]]*("[^"]|\{)'; then
        printf '%s' "error"
    fi
}

get_agy_conversation_id() {
    local cid
    cid=$(json_extract_string "$HOOK_DATA" "conversationId")
    printf '%s' "${cid:-default}"
}

# Tool name for the current tool event (.toolCall.name); empty for model-only
# steps. Used to scope the approval ("input needed") banner to calls that
# actually pause for the user (run_command).
get_agy_tool_name() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '(.toolCall.name // "")' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    tc = json.load(sys.stdin).get("toolCall") or {}
    print(tc.get("name") or "", end="")
except Exception:
    print("", end="")
' 2>/dev/null
        return 0
    fi
    # sed fallback (no jq/python3): json_extract_string only knows top-level
    # keys, and a bare "name" match could hit any other "name" key in the
    # payload. Scope the match to the toolCall object instead; [^{}]* keeps it
    # from crossing into a nested object, so an unmatched payload (name after a
    # nested object, or pretty-printed across lines) yields "" — no banner,
    # same as a model-only step.
    printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"toolCall"[[:space:]]*:[[:space:]]*\{[^{}]*"name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
}

# The shell command a run_command tool event will run (.toolCall.args.CommandLine);
# empty when absent. Same jq -> python3 -> sed ladder as get_agy_tool_name.
get_agy_command_line() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '(.toolCall.args.CommandLine // "")' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    args = (json.load(sys.stdin).get("toolCall") or {}).get("args") or {}
    print(args.get("CommandLine") or "", end="")
except Exception:
    print("", end="")
' 2>/dev/null
        return 0
    fi
    printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"toolCall"[[:space:]]*:[[:space:]]*\{.*"CommandLine"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1
}

# Path to agy's permission settings (permissions.allow/ask/deny). Overridable
# for tests and non-default installs.
agy_permissions_file() {
    printf '%s' "${CODE_NOTIFY_AGY_SETTINGS:-$HOME/.gemini/antigravity-cli/settings.json}"
}

# Antigravity 1.1.1 can pass the model's serialized CommandLine to PreToolUse,
# including one pair of double quotes around the whole command (for example,
# `"git diff"`). Its permission engine removes that wrapper before matching and
# execution, so mirror that normalization before reconstructing its decision.
agy_normalize_command_line() {
    local cmd="$1"
    if [[ ${#cmd} -ge 2 ]] && [[ "${cmd:0:1}" == '"' ]] && [[ "${cmd: -1}" == '"' ]]; then
        cmd="${cmd:1:${#cmd}-2}"
    fi
    printf '%s' "$cmd"
}

# Resolve what agy will do with a command against its own permission lists:
# prints "auto" when it runs without prompting (matched allow, or auto-denied),
# or "ask" when it pauses for the user. Precedence is deny > ask > allow (per
# https://antigravity.google/docs/cli/permissions); an unlisted command
# defaults to "ask". Rules are command(<prefix>) and match when their words are
# a leading prefix of the command's words, so command(git) covers "git status"
# but not "git-foo", and command(git add) is checked before command(git).
# Unreadable/absent settings or no parser -> "ask" (never suppress blindly).
agy_permission_decision() {
    local cmd="$1" settings out
    cmd="$(agy_normalize_command_line "$cmd")"
    settings="$(agy_permissions_file)"
    [[ -f "$settings" ]] || { printf 'ask'; return 0; }

    # shellcheck disable=SC2016  # $cmd/$ct/$pt are jq variables, not shell
    local jq_prog='
def cmdtoks: ($cmd | split(" ") | map(select(. != "")));
def pats(l): (.permissions[l] // [])
  | map(select(type == "string" and test("^command\\(.*\\)$")))
  | map(sub("^command\\("; "") | sub("\\)$"; ""))
  | map(split(" ") | map(select(. != "")));
def anymatch(l): cmdtoks as $ct
  | (pats(l) | any(. as $pt | ($pt | length) > 0 and $ct[0:($pt | length)] == $pt));
if (cmdtoks | length) == 0 then "ask"
elif anymatch("deny") then "auto"
elif anymatch("ask") then "ask"
elif anymatch("allow") then "auto"
else "ask" end'

    if has_jq; then
        out=$(jq -r --arg cmd "$cmd" "$jq_prog" "$settings" 2>/dev/null)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    if has_python3; then
        out=$(python3 - "$cmd" "$settings" <<'PY' 2>/dev/null
import json, sys
cmd, path = sys.argv[1], sys.argv[2]
def toks(s): return [t for t in s.split(" ") if t]
try:
    with open(path) as f:
        perms = json.load(f).get("permissions") or {}
except Exception:
    print("ask", end=""); sys.exit(0)
ct = toks(cmd)
def pats(l):
    out = []
    for e in (perms.get(l) or []):
        if isinstance(e, str) and e.startswith("command(") and e.endswith(")"):
            out.append(toks(e[len("command("):-1]))
    return out
def anymatch(l):
    return any(pt and ct[:len(pt)] == pt for pt in pats(l))
if not ct: print("ask", end="")
elif anymatch("deny"): print("auto", end="")
elif anymatch("ask"): print("ask", end="")
elif anymatch("allow"): print("auto", end="")
else: print("ask", end="")
PY
)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    printf 'ask'
}

# Whether a run_command tool event should raise the approval banner: true only
# when agy will actually pause for the user. agy's PreToolUse payload carries no
# approval flag (every run_command looks identical), so the decision is
# reconstructed from agy's own permission lists via agy_permission_decision.
# Commands with shell chaining/redirection are treated as "ask" — the leading
# command may auto-run while a chained one prompts, and over-notifying beats
# swallowing a real prompt.
agy_command_needs_approval() {
    local cmd
    cmd="$(agy_normalize_command_line "$1")"
    [[ -n "$cmd" ]] || return 0
    # shellcheck disable=SC2016  # these are literal shell-operator glob patterns
    case "$cmd" in
        *';'* | *'|'* | *'&'* | *'`'* | *'$('* | *'>'* | *'<'* | *$'\n'*) return 0 ;;
    esac
    # Pass the raw command: agy_permission_decision normalizes too, and agy
    # strips exactly one wrapper pair, so stripping here and again there would
    # over-normalize (e.g. ""git diff"" -> git diff) and could swallow a prompt.
    [[ "$(agy_permission_decision "$1")" != "auto" ]]
}

# "<ServerName>/<ToolName>" for a call_mcp_tool event (agy's dispatch tool for
# lazily-loaded MCP tools); empty when either half is absent. Same jq ->
# python3 -> sed ladder as get_agy_tool_name. The sed fallback matches the keys
# anywhere in the payload, so a colliding key inside the free-form
# .toolCall.args.Arguments object can win — jq/python3 take precedence, and a
# wrong target only skews the banner decision toward its "ask" default.
get_agy_mcp_target() {
    if has_jq; then
        printf '%s' "$HOOK_DATA" | jq -r '(.toolCall.args // {})
            | if ((.ServerName // "") != "") and ((.ToolName // "") != "")
              then "\(.ServerName)/\(.ToolName)" else "" end' 2>/dev/null
        return 0
    fi
    if has_python3; then
        printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    args = (json.load(sys.stdin).get("toolCall") or {}).get("args") or {}
    s, t = args.get("ServerName") or "", args.get("ToolName") or ""
    print("%s/%s" % (s, t) if s and t else "", end="")
except Exception:
    print("", end="")
' 2>/dev/null
        return 0
    fi
    local server tool
    server=$(printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"ServerName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)
    tool=$(printf '%s' "$HOOK_DATA" | sed -nE \
        's/.*"ToolName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n1)
    if [[ -n "$server" ]] && [[ -n "$tool" ]]; then
        printf '%s/%s' "$server" "$tool"
    fi
}

# Resolve what agy will do with an MCP tool call against its permission lists:
# prints "auto" when it runs without prompting (matched allow, or auto-denied)
# or "ask" when it pauses for the user. Rules are mcp(<server>/<tool>) where *
# is a wildcard — mcp(*), mcp(srv/*), mcp(srv/tool) — with the same precedence
# as commands (deny > ask > allow); an unlisted MCP tool defaults to "ask".
# $1 is the candidate target; $2 selects how rule targets are compared:
# "slash" for the <server>/<tool> form (call_mcp_tool), or "underscore" for an
# eagerly loaded tool's flat name with the mcp_ prefix stripped, where each
# rule's "/" is flattened to "_" (eager tools register as mcp_<server>_<tool>).
# Unreadable/absent settings or no parser -> "ask" (never suppress blindly).
agy_mcp_permission_decision() {
    local target="$1" style="${2:-slash}" settings out
    settings="$(agy_permissions_file)"
    [[ -f "$settings" ]] || { printf 'ask'; return 0; }

    # shellcheck disable=SC2016  # $target/$style/$g are jq variables, not shell
    local jq_prog='
def reesc: gsub("(?<c>[\\\\.\\^\\$\\+\\(\\)\\[\\]\\{\\}\\|\\?])"; "\\" + .c);
def globre($g): "^" + ($g | split("*") | map(reesc) | join(".*")) + "$";
def pats(l): (.permissions[l] // [])
  | map(select(type == "string" and test("^mcp\\(.*\\)$")))
  | map(sub("^mcp\\("; "") | sub("\\)$"; ""))
  | map(if $style == "underscore" then gsub("/"; "_") else . end);
def anymatch(l): (pats(l) | any(. as $g | $target | test(globre($g))));
if ($target | length) == 0 then "ask"
elif anymatch("deny") then "auto"
elif anymatch("ask") then "ask"
elif anymatch("allow") then "auto"
else "ask" end'

    if has_jq; then
        out=$(jq -r --arg target "$target" --arg style "$style" "$jq_prog" "$settings" 2>/dev/null)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    if has_python3; then
        out=$(python3 - "$target" "$style" "$settings" <<'PY' 2>/dev/null
import json, re, sys
target, style, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        perms = json.load(f).get("permissions") or {}
except Exception:
    print("ask", end=""); sys.exit(0)
def pats(l):
    out = []
    for e in (perms.get(l) or []):
        if isinstance(e, str) and e.startswith("mcp(") and e.endswith(")"):
            p = e[len("mcp("):-1]
            out.append(p.replace("/", "_") if style == "underscore" else p)
    return out
def match(p):
    rx = "^" + ".*".join(re.escape(part) for part in p.split("*")) + "$"
    return re.match(rx, target) is not None
def anymatch(l):
    return any(match(p) for p in pats(l))
if not target: print("ask", end="")
elif anymatch("deny"): print("auto", end="")
elif anymatch("ask"): print("ask", end="")
elif anymatch("allow"): print("auto", end="")
else: print("ask", end="")
PY
)
        [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
    fi
    printf 'ask'
}

# Whether an MCP tool event should raise the approval banner. agy prompts for
# every MCP tool call unless an mcp(...) rule lets it auto-run, so this mirrors
# agy_command_needs_approval: banner unless agy's own lists resolve to "auto"
# (allowlisted, or auto-denied). $1 is the toolCall name — call_mcp_tool for
# lazily-loaded tools (server/tool live in the payload args), mcp_<server>_<tool>
# for eagerly loaded ones (server/tool are baked into the name).
agy_mcp_needs_approval() {
    local name="$1" target style
    if [[ "$name" == "call_mcp_tool" ]]; then
        target="$(get_agy_mcp_target)"
        style="slash"
        # Unextractable server/tool: assume it prompts — over-notifying beats
        # swallowing a real approval pause.
        [[ -n "$target" ]] || return 0
    else
        target="${name#mcp_}"
        style="underscore"
    fi
    [[ "$(agy_mcp_permission_decision "$target" "$style")" != "auto" ]]
}

# True when permission_prompt alerts are enabled. The notifier does not source
# config.sh, so read the same notify-types file config.sh writes (normalized,
# pipe-separated). Absent file means the default (idle_prompt only) — approval
# prompts off — matching config.sh's DEFAULT_NOTIFY_TYPE.
agy_permission_prompt_enabled() {
    local types_file="$HOME/.claude/notifications/notify-types"
    local current="idle_prompt"
    [[ -f "$types_file" ]] && current="$(cat "$types_file" 2>/dev/null)"
    [[ "$current" == *permission_prompt* ]]
}

# Debounce PostToolUse into a single "task complete": agy 1.0.x fired no usable
# Stop event, and PostToolUse fires after every step (including model-only
# steps), so we treat the agent as done once step activity has been quiet for a
# few seconds. Each call stamps a token and arms a detached watcher; only the
# most recent watcher (whose token is still current after the quiet period)
# sends the notification.
#
# Since agy 1.1.3 the native Stop hook executes, making this whole mechanism a
# FALLBACK: the first native Stop of a conversation writes a marker (see
# agy_native_stop_markerfile) and later PostToolUse steps skip arming watchers.
# Everything below still carries the first turn of each conversation and any
# agy build whose lifecycle hooks are (again) broken.
#
# Tool runs no longer trip this early: PreToolUse (empty matcher, every tool)
# cancels the pending watcher when the next tool starts, so a tool that outlives
# the quiet window can't fire a premature completion.
#
# Heuristic caveat (while no real turn-end event is proven): a single long *model*
# generation that exceeds the quiet window with no following tool can still fire
# early. The quiet window (CODE_NOTIFY_AGY_DEBOUNCE_SECONDS, default 8s) plus the
# global stop rate limit keep this in check; repeated completions are not cooled
# down per conversation, because that would also swallow legitimate completions
# of quick back-to-back turns in the same session.
#
# Inside tmux the watcher additionally gates the completion on the pane having
# SETTLED: agy paints the pane continuously while generating and its idle
# prompt is static, so "no step for a quiet window" only counts as done once
# the pane content (capture-pane checksum) also held still for a full window.
# A changing pane re-arms the watcher instead of firing, which closes the
# long-generation hole above. The postponement is bounded by
# CODE_NOTIFY_AGY_SETTLE_MAX_SECONDS (default 120, 0 disables the gate): past
# it the watcher fires on the step-quiet signal alone, so a pane that never
# settles (unexpected animation, another process writing to it) degrades to
# the old behavior instead of never notifying. Outside tmux there is no pane
# to observe and the step-quiet heuristic stands alone, as before.

# Path of the per-conversation debounce token. The token is the single source of
# truth for "is a completion still pending": a newer step or an error overwrites
# it, which cancels any watcher still sleeping on the old value.
agy_debounce_tokenfile() {
    local state_dir cid_safe
    state_dir="$HOME/.claude/notifications/agy"
    mkdir -p "$state_dir"
    # Inline sanitize: sanitize_rate_limit_key is defined later in this file
    # than these helpers are invoked, so we can't rely on it here.
    cid_safe="$(get_agy_conversation_id | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.token' "$state_dir" "$cid_safe"
}

# Per-conversation marker that prevents tmux_running_start from firing on every
# PreInvocation/PreToolUse in a turn.  The first such event of a turn (normally
# the PreInvocation before the first model call) creates this file and lights
# the indicator; subsequent calls see the file and skip the tmux IPC entirely.
# Turn-end events (StopFinal/Stop/error) remove it so the next turn re-arms,
# and a permission prompt removes it so the first working signal after approval
# restarts the paused indicator.
agy_running_markerfile() {
    local state_dir cid_safe
    state_dir="$HOME/.claude/notifications/agy"
    mkdir -p "$state_dir"
    cid_safe="$(get_agy_conversation_id | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.running' "$state_dir" "$cid_safe"
}

# Start the running indicator if this is the first tool call of the turn.
# A marker older than TMUX_RUNNING_TTL is ignored: a turn that ended without
# any hook (Escape-interrupt — the case the TTL exists for) leaves its marker
# behind, and honouring it would keep the whole next turn unlit. The indicator
# itself self-expires at the same TTL, so past it the marker is dead weight.
agy_maybe_start_running() {
    local marker now stamp=""
    marker="$(agy_running_markerfile)"
    now="$(date +%s)"
    if [[ -r "$marker" ]]; then
        read -r stamp < "$marker" 2>/dev/null || true
        if [[ "$stamp" =~ ^[0-9]+$ ]] && [[ $((now - stamp)) -lt "$TMUX_RUNNING_TTL" ]]; then
            return 0
        fi
    fi
    printf '%s' "$now" > "$marker" 2>/dev/null || true
    # Hand the marker path to the tmux layer. The interrupt watch can retire
    # this window's indicator long before the TTL, and a marker left behind
    # would then keep the whole next turn unlit — Antigravity has no
    # UserPromptSubmit to re-light it, only this PreInvocation, which skips the
    # tmux call whenever the marker looks fresh.
    CODE_NOTIFY_TMUX_RUNNING_MARKERFILE="$marker" \
        tmux_running_start 2>/dev/null || true
}

# Clear the per-conversation running marker so the next turn re-arms.
agy_clear_running_marker() {
    rm -f "$(agy_running_markerfile)" 2>/dev/null || true
}

# Per-conversation marker recording that a NATIVE Stop hook has fired (agy
# executes lifecycle hooks since 1.1.3). Once real turn-end events are proven
# for a conversation, PostToolUse stops arming debounce watchers — the guess
# is strictly worse than the event. Keyed per conversation rather than
# globally so the fallback self-heals: a later agy build with lifecycle hooks
# broken again simply never writes the marker, and the debounce keeps
# delivering completions.
agy_native_stop_markerfile() {
    local state_dir cid_safe
    state_dir="$HOME/.claude/notifications/agy"
    mkdir -p "$state_dir"
    cid_safe="$(get_agy_conversation_id | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s.native-stop' "$state_dir" "$cid_safe"
}

# Serialize the running-indicator transition with a debounce completion.  The
# token check alone is not enough: a new PreToolUse can invalidate the token
# after StopFinal checks it but before StopFinal clears the marker/stops tmux.
# mkdir is atomic, and the pid file lets later hooks recover a lock left by a
# killed hook process.
agy_with_running_lock() {
    local lockdir owner attempts=0 status
    lockdir="$(agy_running_markerfile).lock"
    while ! mkdir "$lockdir" 2>/dev/null; do
        if (( attempts >= 500 )); then
            owner=""
            if [[ -r "$lockdir/pid" ]]; then
                # read exits nonzero on the newline-less pid file even though
                # it populates owner, so its status is deliberately ignored.
                read -r owner < "$lockdir/pid" 2>/dev/null || true
            fi
            if [[ "$owner" =~ ^[0-9]+$ ]]; then
                if ! kill -0 "$owner" 2>/dev/null; then
                    rm -f "$lockdir/pid" 2>/dev/null || true
                    rmdir "$lockdir" 2>/dev/null || true
                fi
            elif [[ ! -e "$lockdir/pid" ]]; then
                # The owner may have been killed between mkdir and writing its
                # pid.  The empty directory is safe to reclaim.
                rmdir "$lockdir" 2>/dev/null || true
            fi
            attempts=0
        fi
        ((attempts++))
        sleep 0.01
    done
    printf '%s' "$$" > "$lockdir/pid" 2>/dev/null || true
    "$@"
    status=$?
    rm -f "$lockdir/pid" 2>/dev/null || true
    rmdir "$lockdir" 2>/dev/null || true
    return "$status"
}

agy_start_running_locked() {
    cancel_agy_debounced_stop
    agy_maybe_start_running
}

# PreToolUse for a call that is about to pause for approval: the turn is not
# done (cancel the debounce) and the first post-approval PreToolUse must
# re-light the indicator (drop the marker), but the running indicator itself
# stays untouched — starting it here would clear the waiting badge and flash
# the spinner for the instant before the banner pauses it again. With several
# permission asks queued (agy dispatches parallel tool calls back to back)
# that start/pause cycle strobed the window between spinner and badge.
agy_banner_locked() {
    cancel_agy_debounced_stop
    agy_clear_running_marker
}

agy_stop_final_locked() {
    local expected_token="$1" current_token
    current_token="$(cat "$(agy_debounce_tokenfile)" 2>/dev/null || true)"
    [[ -n "$expected_token" ]] && [[ "$current_token" == "$expected_token" ]] || return 1
    agy_clear_running_marker
    tmux_running_stop 2>/dev/null || true
}

# Remove stale per-conversation debounce tokens. A token only matters for the
# few seconds a watcher sleeps on it; once that window passes the file is dead
# weight. Without pruning, every Antigravity conversation leaves one tiny file
# behind forever (the key is the conversation id, so it is never reused). Runs
# best-effort and backgrounded so it never adds latency to the hook.
prune_agy_debounce_tokens() {
    local state_dir retention_days
    state_dir="$HOME/.claude/notifications/agy"
    [[ -d "$state_dir" ]] || return 0
    retention_days="${CODE_NOTIFY_AGY_TOKEN_RETENTION_DAYS:-3}"
    [[ "$retention_days" =~ ^[0-9]+$ ]] || retention_days=3
    find "$state_dir" -maxdepth 1 -type f \
        \( -name '*.token' -o -name '*.completed' -o -name '*.running' \
           -o -name '*.native-stop' \) \
        -mtime "+${retention_days}" -delete 2>/dev/null || true
    # A .running.lock directory this old is a hook killed mid-transition:
    # legitimate holds last milliseconds, and both mkdir and the pid write
    # refresh the dir mtime, so an old dir cannot be live. rm -rf (not
    # -delete) because the leftover pid file makes the dir non-empty, and
    # deleting it first would freshen the dir mtime out of the stale set.
    find "$state_dir" -maxdepth 1 -type d -name '*.running.lock' \
        -mtime "+${retention_days}" -exec rm -rf {} + 2>/dev/null || true
}

# Throttle wrapper around the prune. The stale-file set only changes on a day
# boundary, so scanning the directory on every tool step is pure waste. We stamp
# the last sweep in a tiny file and skip until the interval (default 24h) has
# elapsed -- the common path is one `read` from that file plus an integer
# compare, with no process spawn and no directory scan. $1 is the current epoch,
# reused from the caller so we add zero extra `date` calls.
maybe_prune_agy_debounce_tokens() {
    local now="$1" stamp last interval
    interval="${CODE_NOTIFY_AGY_PRUNE_INTERVAL_SECONDS:-86400}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
    stamp="$HOME/.claude/notifications/agy/.last-prune"
    last=0
    [[ -r "$stamp" ]] && read -r last < "$stamp" 2>/dev/null
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last < interval )) && return 0
    printf '%s' "$now" > "$stamp" 2>/dev/null || true
    prune_agy_debounce_tokens >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Cancel any pending debounced completion for this conversation. Used when a
# later step reports an error: that error supersedes the earlier "looks done"
# guess, so we must not also fire a "task complete".
cancel_agy_debounced_stop() {
    printf 'cancelled-%s-%s' "$(date +%s)" "$RANDOM" > "$(agy_debounce_tokenfile)" 2>/dev/null || true
}

schedule_agy_debounced_stop() {
    local now tokenfile token delay
    now="$(date +%s)"
    tokenfile="$(agy_debounce_tokenfile)"
    token="${now}-$$-$RANDOM"
    printf '%s' "$token" > "$tokenfile"
    delay="${CODE_NOTIFY_AGY_DEBOUNCE_SECONDS:-8}"

    # Clean up old tokens from past conversations, throttled to ~once/day so this
    # is effectively free on the per-step hot path.
    maybe_prune_agy_debounce_tokens "$now"

    # Snapshot the pane for the settle gate (see the comment block above the
    # token helpers). Empty when disabled or outside tmux, which turns the
    # gate off in the watcher. The deadline deliberately excludes the delay:
    # CODE_NOTIFY_AGY_DEBOUNCE_SECONDS may be fractional ("0.25") — sleep
    # accepts that, but bash integer arithmetic aborts the whole hook on it,
    # so the delay must never appear in $((...)). Measuring the bound from
    # arming rather than from the first wake costs at most one quiet window
    # of postponement headroom.
    local settle_fp="" settle_deadline settle_max
    settle_max="${CODE_NOTIFY_AGY_SETTLE_MAX_SECONDS:-120}"
    [[ "$settle_max" =~ ^[0-9]+$ ]] || settle_max=120
    if (( settle_max > 0 )) && tmux_focus_available; then
        settle_fp="$(tmux_resume_poll_fingerprint "$TMUX_PANE")"
    fi
    settle_deadline=$((now + settle_max))

    (
        while :; do
            sleep "$delay"
            # Only the latest activity wins; a newer step or an error overwrites
            # the token, so earlier/cancelled watchers bail out here — checked
            # every round, so a step arriving mid-settle cancels the loop too.
            [[ "$(cat "$tokenfile" 2>/dev/null)" == "$token" ]] || exit 0
            # Settle gate: a pane that painted during the quiet window is a
            # model still generating, not a finished turn — re-arm on the new
            # snapshot. Past the deadline (or when capture fails) fire on the
            # step-quiet signal alone.
            if [[ -n "$settle_fp" ]] && (( $(date +%s) < settle_deadline )); then
                fp_now="$(tmux_resume_poll_fingerprint "$TMUX_PANE")"
                if [[ -n "$fp_now" ]] && [[ "$fp_now" != "$settle_fp" ]]; then
                    settle_fp="$fp_now"
                    continue
                fi
            fi
            # Carry the token into StopFinal so that the completion is
            # revalidated after the watcher crosses the process boundary.
            printf '%s' "$HOOK_DATA" | "$SELF_NOTIFIER" "agy:StopFinal" "antigravity" "$token" >/dev/null 2>&1
            exit 0
        done
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

AGY_FORCED_SUBTYPE=""
AGY_STOP_FINAL_CLEANUP=0
HOOK_DATA=""
if [[ "$RAW_ARG1" == "codex" ]]; then
    TOOL_NAME="codex"
    HOOK_DATA="$RAW_ARG2"
    HOOK_TYPE=$(get_codex_hook_type)
    PROJECT_NAME="${RAW_ARG3:-$(get_codex_project_name)}"
elif [[ "$RAW_ARG1" == agy:* ]]; then
    # Antigravity CLI: "agy:<Event>" + payload on stdin.
    TOOL_NAME="antigravity"
    CODE_NOTIFY_TMUX_AGENT_NAME="$TOOL_NAME"
    AGY_EVENT="${RAW_ARG1#agy:}"
    if [[ ! -t 0 ]]; then
        HOOK_DATA=$(cat 2>/dev/null || true)
    fi
    # PROJECT_NAME is resolved after the per-tool-call fast paths below exit:
    # the lookup costs a jq/python spawn plus a git worktree probe, and the
    # silent PreToolUse/PostToolUse events fire before/after every tool call.
    case "$AGY_EVENT" in
        PreInvocation)
            # Fires before every model call (executes since agy 1.1.3) — agy's
            # de-facto prompt-submit signal, since it has no UserPromptSubmit
            # event. The first one of a turn lights the running indicator at
            # prompt submission: turns that open with a long model-only
            # generation, or never call a tool at all, would otherwise stay
            # dark until the first PreToolUse (or forever). It also re-lights
            # the indicator after an approval pause and, like PreToolUse,
            # cancels any pending debounced completion ("still working").
            # Later invocations of the same turn dedup via the running marker.
            # Always silent.
            agy_with_running_lock agy_start_running_locked || true
            exit 0
            ;;
        PreToolUse)
            # agy 1.0.11 fires PreToolUse before EVERY tool call (registered
            # with an empty matcher), so it is code-notify's "agent is still
            # working" signal: a tool is about to run, therefore any pending
            # "looks done" debounce from the previous step is wrong — cancel it.
            # Without this, a tool that outlives the debounce window (e.g. a slow
            # file read between two quick steps) lets the previous step's watcher
            # fire a bogus "task complete" mid-turn.
            # The approval banner is only meaningful for calls that pause for
            # the user — run_command and MCP tools (call_mcp_tool dispatch, or
            # eager mcp_<server>_<tool> registrations) — only when
            # permission_prompt alerts are on, and only when agy will actually
            # stop to ask: calls its permission lists auto-run (an allowlisted
            # "git status", an mcp(server/*) allow rule) fire PreToolUse too
            # but never prompt, so bannering them is just noise. Every other
            # tool start is silent — it just cancelled the debounce.
            # The banner decision comes BEFORE the running-indicator start: a
            # call that is about to pause must not light the spinner only for
            # the banner to pause it milliseconds later (see agy_banner_locked).
            agy_tool_name="$(get_agy_tool_name)"
            agy_needs_banner=""
            if agy_permission_prompt_enabled; then
                case "$agy_tool_name" in
                    run_command)
                        agy_command_needs_approval "$(get_agy_command_line)" && agy_needs_banner=1
                        ;;
                    call_mcp_tool | mcp_*)
                        agy_mcp_needs_approval "$agy_tool_name" && agy_needs_banner=1
                        ;;
                esac
            fi
            if [[ -n "$agy_needs_banner" ]]; then
                HOOK_TYPE="notification"
                AGY_FORCED_SUBTYPE="permission_prompt"
                # This notification pauses the running indicator further down.
                # Under the same lock StopFinal uses (so a stale completion
                # cannot race the transition), cancel the debounce and drop
                # the marker so the next PreToolUse — the first tool call
                # after the user approves — re-lights it via tmux_running_start
                # (which also retires the window's resume-pending flag). agy
                # has no PostToolUse resume shim, so without this the indicator
                # would stay paused for the rest of the turn.
                agy_with_running_lock agy_banner_locked || true
            else
                # Cancel the debounce and possibly start tmux as one transaction
                # with StopFinal, so a completion cannot stop a newly started
                # turn.
                agy_with_running_lock agy_start_running_locked || true
                exit 0
            fi
            ;;
        PostToolUse)
            if [[ -n "$(get_agy_error)" ]]; then
                # A failing step supersedes any earlier "looks done" guess, so
                # cancel the pending debounce before raising the error alert.
                HOOK_TYPE="error"
                cancel_agy_debounced_stop
                agy_clear_running_marker
            else
                # Once a native Stop has been seen for this conversation, the
                # real turn-end event supersedes the debounced guess: skip
                # arming a watcher process (and its capture-pane fingerprint
                # polling) entirely. The first turn of every conversation
                # still debounces, so an agy build whose lifecycle hooks are
                # broken never writes the marker and keeps its completions.
                [[ -f "$(agy_native_stop_markerfile)" ]] && exit 0
                HOOK_TYPE="agy_debounce_stop"
            fi
            ;;
        StopFinal)
            # Emitted by our own debounce watcher once step activity went quiet.
            # Revalidate the token while holding the same lock used by
            # PreToolUse. If a newer turn won the race, this completion is stale
            # and must not stop the newer turn's indicator or notify for it.
            agy_with_running_lock agy_stop_final_locked "$RAW_ARG3" || exit 0
            HOOK_TYPE="stop"
            # tmux_running_stop already ran inside the lock; skipping the
            # generic cleanup below keeps a newer PreToolUse from being stopped
            # after the lock is released.
            AGY_STOP_FINAL_CLEANUP=1
            ;;
        Stop)
            # Native lifecycle Stop (executes since agy 1.1.3; was inert in
            # 1.0.x). A real turn-end supersedes our PostToolUse guess, so cancel
            # any pending debounced completion for this conversation to avoid a
            # duplicate "task complete" from the watcher.
            HOOK_TYPE="stop"
            # The Stop payload carries the turn's terminal error (empty string
            # on a clean end, e.g. terminationReason NO_TOOL_CALL): a turn
            # that died is a failure alert, not "task complete".
            if [[ -n "$(get_agy_error)" ]]; then
                HOOK_TYPE="error"
            fi
            # Record that this conversation delivers native turn-end events so
            # later PostToolUse steps skip arming debounce watchers. With
            # watchers gone, this branch also takes over the throttled state
            # pruning that used to ride on arming them.
            agy_stop_now="$(date +%s)"
            printf '%s' "$agy_stop_now" > "$(agy_native_stop_markerfile)" 2>/dev/null || true
            maybe_prune_agy_debounce_tokens "$agy_stop_now"
            cancel_agy_debounced_stop
            agy_clear_running_marker
            ;;
        *)
            HOOK_TYPE="stop"
            ;;
    esac
else
    HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$RAW_ARG1}
    TOOL_NAME="${RAW_ARG2:-""}"
    PROJECT_NAME="${RAW_ARG3:-$(get_project_name)}"

    # Read hook data from stdin (Claude Code passes JSON with hook context)
    if [[ ! -t 0 ]]; then
        HOOK_DATA=$(cat 2>/dev/null || true)
    fi
fi

# tmux helpers use this only to find the agent ancestor of a hook shell. It is
# deliberately set after TOOL_NAME has been resolved rather than inferred from
# a pane command, which can temporarily be a child tool such as git or bash.
# shellcheck disable=SC2034  # read by the sourced tmux.sh, not this file
CODE_NOTIFY_TMUX_AGENT_NAME="$TOOL_NAME"

# Antigravity PostToolUse with no error: arm the debounced "task complete" and
# return immediately (no banner for intermediate steps).
if [[ "$HOOK_TYPE" == "agy_debounce_stop" ]]; then
    schedule_agy_debounced_stop
    exit 0
fi

# Any agy event still running here will notify, so the project lookup deferred
# above is paid only now — never on the silent per-tool-call paths.
if [[ "$RAW_ARG1" == agy:* ]]; then
    PROJECT_NAME="$(get_agy_project_name)"
fi

# How this agent's badges clear (stored per badge — see tmux_badge_set):
#   - "engage": the next reliable work signal clears the badge when the user
#     actually hands the window work (UserPromptSubmit for Claude/Codex, first
#     PreInvocation/PreToolUse for Antigravity), so
#     glance-clearing (sweep + focus hook + macOS click-to-clear) is suppressed
#     and the badge survives mere peeks at the output.
#   - "glance": no prompt-submit signal is wired, so visiting the window must
#     clear the badge or nothing will.
# Claude's installer always registers the UserPromptSubmit hook alongside its
# others. Antigravity's per-model-call PreInvocation hook (with the all-tools
# PreToolUse as backstop) is its equivalent engagement signal. Codex supports
# UserPromptSubmit too (hooks.json), but only installs
# that have re-run `cn on codex` since it was added carry it — so engage-clear
# is gated on the hook actually being present in hooks.json, never leaving a
# badge without a clear path (legacy `notify =` users and stale hooks.json
# files keep glance-clearing). Keyed off TOOL_NAME, which is resolved above
# for every entry path (codex/antigravity/claude/gemini).
# Matches the managed Code-Notify command (notifier.sh/notify.sh/notify.ps1
# invoked with "UserPromptSubmit codex"), not just the event name: a user's own
# unrelated UserPromptSubmit hook won't clear our badge, so it must not switch
# Codex to engage mode — that would leave badges with no clear path.
codex_prompt_clear_hook_installed() {
    local hooks_file="${CODE_NOTIFY_CODEX_HOOKS_FILE:-${CODEX_HOME:-$HOME/.codex}/hooks.json}"
    [[ -f "$hooks_file" ]] || return 1
    grep -Eq '(notifier\.sh|notify\.(sh|ps1))[^"]* UserPromptSubmit codex' "$hooks_file" 2>/dev/null
}

BADGE_CLEAR_MODE="glance"
case "$TOOL_NAME" in
    "claude")
        BADGE_CLEAR_MODE="engage"
        ;;
    "codex")
        if codex_prompt_clear_hook_installed; then
            BADGE_CLEAR_MODE="engage"
        fi
        ;;
    "antigravity")
        BADGE_CLEAR_MODE="engage"
        ;;
esac

badge_glance_clear_enabled() {
    [[ "$BADGE_CLEAR_MODE" == "glance" ]]
}

# Get display name for tool
get_tool_display_name() {
    local tool="$1"
    case "$tool" in
        "claude") echo "Claude" ;;
        "codex") echo "Codex" ;;
        "gemini") echo "Gemini" ;;
        "antigravity") echo "Antigravity" ;;
        *) echo "AI" ;;
    esac
}

TOOL_DISPLAY=$(get_tool_display_name "$TOOL_NAME")

# Rate limiting for stop notifications (prevents spam from parallel sub-agents)
NOTIFICATIONS_DIR="$HOME/.claude/notifications"
RATE_LIMIT_DIR="$NOTIFICATIONS_DIR/state"
STOP_RATE_LIMIT_SECONDS="${CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS:-10}"
NOTIFICATION_RATE_LIMIT_SECONDS="${CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS:-180}"
EVENT_RATE_LIMIT_SECONDS="${CODE_NOTIFY_EVENT_RATE_LIMIT_SECONDS:-10}"
DELEGATED_WORK_MARKER_TTL_SECONDS="${CODE_NOTIFY_DELEGATED_WORK_TTL_SECONDS:-3600}"
if [[ ! "$DELEGATED_WORK_MARKER_TTL_SECONDS" =~ ^[0-9]+$ ]] ||
    (( DELEGATED_WORK_MARKER_TTL_SECONDS <= 0 )); then
    DELEGATED_WORK_MARKER_TTL_SECONDS=3600
fi

sanitize_rate_limit_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

get_rate_limit_file() {
    local key
    key=$(sanitize_rate_limit_key "$1")
    printf '%s/%s\n' "$RATE_LIMIT_DIR" "$key"
}

get_legacy_rate_limit_file() {
    local key
    key=$(sanitize_rate_limit_key "$1")
    printf '%s/%s\n' "$NOTIFICATIONS_DIR" "$key"
}

# Claude emits two hook events for one AskUserQuestion UI: the specific
# PreToolUse event (which supplies the question text) followed immediately by
# a generic permission_prompt Notification. Without correlating them, the
# generic event replaces both the 🙋 tmux badge and the macOS notification
# group with a misleading approval alert.
#
# Keep a short-lived, session-scoped marker for the specific event. The first
# matching permission prompt atomically consumes it, so a later real approval
# request in the same session is still delivered. The age check is a fallback
# for interrupted/older Claude installs where the generic event never arrives.
ASK_USER_PERMISSION_DUPLICATE_WINDOW_SECONDS="${CODE_NOTIFY_ASK_USER_DUPLICATE_WINDOW_SECONDS:-15}"

get_ask_user_pending_file() {
    local session_id hook_scope
    session_id=$(json_extract_string "$HOOK_DATA" "session_id")
    [[ -n "$session_id" ]] || return 1
    # Global and project-scoped hooks can both be enabled. Keep one marker per
    # registration scope so each scope's generic Notification consumes only
    # the marker created by its matching PreToolUse command.
    hook_scope="${RAW_ARG3:-global}"
    get_rate_limit_file "pending_ask_user_${TOOL_NAME}_${hook_scope}_${session_id}"
}

mark_ask_user_pending() {
    local tool_name marker_file marker_tmp
    [[ "$TOOL_NAME" == "claude" ]] || return 0
    [[ "$HOOK_TYPE" == "PreToolUse" ]] || return 0

    # The managed PreToolUse command is matcher-scoped to AskUserQuestion, but
    # retain this payload check so a manually reused notifier command cannot
    # suppress an unrelated approval notification.
    tool_name=$(json_extract_string "$HOOK_DATA" "tool_name")
    [[ "$tool_name" == "AskUserQuestion" ]] || return 0
    marker_file=$(get_ask_user_pending_file) || return 0

    mkdir -p "$RATE_LIMIT_DIR"
    marker_tmp="${marker_file}.tmp.$$"
    date +%s > "$marker_tmp" || return 0
    mv -f "$marker_tmp" "$marker_file" 2>/dev/null || rm -f "$marker_tmp"
}

consume_recent_ask_user_pending() {
    local marker_file claim_file marked_at now age window
    marker_file=$(get_ask_user_pending_file) || return 1
    [[ -f "$marker_file" ]] || return 1

    # Claim by rename so concurrent/repeated Notification hooks cannot both
    # consume the same question marker.
    claim_file="${marker_file}.claim.$$"
    mv "$marker_file" "$claim_file" 2>/dev/null || return 1
    marked_at=$(cat "$claim_file" 2>/dev/null || true)
    rm -f "$claim_file"

    window="$ASK_USER_PERMISSION_DUPLICATE_WINDOW_SECONDS"
    [[ "$window" =~ ^[0-9]+$ ]] || window=15
    [[ "$marked_at" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    age=$((now - marked_at))
    (( age >= 0 && age <= window ))
}

# Claude Code 2.1.145+ includes the session's in-flight task registry in Stop
# payloads. A main turn can therefore end while delegated subagent or teammate
# work is still running; treating that Stop as terminal would replace the
# running badge with "Task Complete", followed later by a misleading idle
# reminder. Persist a session-scoped marker from that authoritative snapshot
# so both events can be suppressed without returning a blocking hook decision.
get_delegated_work_marker_file() {
    local session_id hook_scope
    session_id=$(json_extract_string "$HOOK_DATA" "session_id")
    [[ -n "$session_id" ]] || return 1
    # Global and project-scoped hook commands can both run for one event. Keep
    # their markers separate so either command can reconcile its own state.
    hook_scope="${RAW_ARG3:-global}"
    get_rate_limit_file "delegated_work_${TOOL_NAME}_${hook_scope}_${session_id}"
}

# Print one of:
#   running       - a running subagent/cloud session/remote agent is in
#                   background_tasks (statuses there are trustworthy: they
#                   transition to completed when the work ends)
#   teammate-only - the only running delegates are teammates, whose registry
#                   entry stays status=running even when parked idle; the
#                   caller weighs this against the TeammateIdle tombstone
#   clear         - the documented array is present with no running delegate
#   unknown       - the payload is malformed or the registry is unavailable
get_claude_delegated_work_state() {
    local state="unknown"

    if has_jq; then
        state=$(printf '%s' "$HOOK_DATA" | jq -r '
            def is_running: (.status == "running" or .status == "pending");
            if (has("background_tasks") and (.background_tasks | type == "array")) then
                if any(.background_tasks[]?;
                    ((.type == "subagent" or .type == "cloud session" or
                      .type == "remote_agent") and is_running))
                then "running"
                elif any(.background_tasks[]?; (.type == "teammate" and is_running))
                then "teammate-only"
                else "clear" end
            else
                "unknown"
            end
        ' 2>/dev/null) || state="unknown"
    elif has_python3; then
        state=$(printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
    tasks = payload.get("background_tasks")
    if not isinstance(tasks, list):
        state = "unknown"
    else:
        def running(kinds):
            return any(
                isinstance(task, dict)
                and task.get("type") in kinds
                and task.get("status") in {"running", "pending"}
                for task in tasks
            )
        if running({"subagent", "cloud session", "remote_agent"}):
            state = "running"
        elif running({"teammate"}):
            state = "teammate-only"
        else:
            state = "clear"
except Exception:
    state = "unknown"
print(state, end="")
' 2>/dev/null) || state="unknown"
    fi

    case "$state" in
        "running"|"teammate-only"|"clear"|"unknown") printf '%s\n' "$state" ;;
        *) printf '%s\n' "unknown" ;;
    esac
}

mark_delegated_work_running() {
    local marker_file marker_tmp
    marker_file=$(get_delegated_work_marker_file) || return 0
    # Preserve the original observation time. Claude serializes an idle
    # teammate as status=running, so refreshing on every Stop would prevent
    # the fail-open TTL below from ever expiring.
    if delegated_work_marker_exists; then
        return 0
    fi
    mkdir -p "$RATE_LIMIT_DIR"
    marker_tmp="${marker_file}.tmp.$$"
    date +%s > "$marker_tmp" || return 0
    mv -f "$marker_tmp" "$marker_file" 2>/dev/null || rm -f "$marker_tmp"
}

clear_delegated_work_marker() {
    local marker_file
    marker_file=$(get_delegated_work_marker_file) || return 0
    rm -f "$marker_file" 2>/dev/null || true
}

# TeammateIdle is a one-shot signal, but the teammate it retires stays in
# background_tasks as status=running for as long as it sits parked. Without
# a durable record of the retirement, the next Stop would re-mark the session
# from that stale registry entry and suppress every later completion. The
# tombstone remembers "this session's teammates were seen idle" for the
# marker TTL; while fresh, teammate-only snapshots read as clear. A second
# teammate that is genuinely working during that window loses its deferral —
# a premature completion toast, the failure direction this feature prefers.
get_teammate_idle_tombstone_file() {
    local session_id hook_scope
    session_id=$(json_extract_string "$HOOK_DATA" "session_id")
    [[ -n "$session_id" ]] || return 1
    hook_scope="${RAW_ARG3:-global}"
    get_rate_limit_file "teammate_idle_${TOOL_NAME}_${hook_scope}_${session_id}"
}

mark_teammate_idle_tombstone() {
    local tombstone_file tombstone_tmp
    tombstone_file=$(get_teammate_idle_tombstone_file) || return 0
    mkdir -p "$RATE_LIMIT_DIR"
    tombstone_tmp="${tombstone_file}.tmp.$$"
    date +%s > "$tombstone_tmp" || return 0
    mv -f "$tombstone_tmp" "$tombstone_file" 2>/dev/null || rm -f "$tombstone_tmp"
}

teammate_idle_tombstone_fresh() {
    local tombstone_file marked_at now age
    tombstone_file=$(get_teammate_idle_tombstone_file) || return 1
    [[ -f "$tombstone_file" ]] || return 1
    marked_at=$(cat "$tombstone_file" 2>/dev/null || true)
    [[ "$marked_at" =~ ^[0-9]+$ ]] || {
        rm -f "$tombstone_file" 2>/dev/null || true
        return 1
    }
    now=$(date +%s)
    age=$((now - marked_at))
    if (( age < 0 || age >= DELEGATED_WORK_MARKER_TTL_SECONDS )); then
        rm -f "$tombstone_file" 2>/dev/null || true
        return 1
    fi
    return 0
}

delegated_work_marker_exists() {
    local marker_file marked_at now age
    marker_file=$(get_delegated_work_marker_file) || return 1
    [[ -f "$marker_file" ]] || return 1
    marked_at=$(cat "$marker_file" 2>/dev/null || true)
    [[ "$marked_at" =~ ^[0-9]+$ ]] || {
        rm -f "$marker_file" 2>/dev/null || true
        return 1
    }
    now=$(date +%s)
    age=$((now - marked_at))
    if (( age < 0 || age >= DELEGATED_WORK_MARKER_TTL_SECONDS )); then
        rm -f "$marker_file" 2>/dev/null || true
        return 1
    fi
    return 0
}

claude_event_alert_enabled() {
    local types_file="$HOME/.claude/notifications/notify-types"
    local current="idle_prompt"
    [[ -f "$types_file" ]] && current="$(cat "$types_file" 2>/dev/null)"
    [[ "|$current|" == *"|$1|"* ]]
}

# Reconcile Stop against its task-registry snapshot, then answer whether this
# Stop (or a later native idle_prompt) must be hidden. An unreadable Stop keeps
# an existing marker but never creates one, avoiding both premature clearing
# and guesses from an unverified payload.
claude_delegated_work_should_suppress() {
    local state
    [[ "$TOOL_NAME" == "claude" ]] || return 1

    if [[ "$HOOK_TYPE" == "stop" ]]; then
        state=$(get_claude_delegated_work_state)
        case "$state" in
            "running")
                mark_delegated_work_running
                return 0
                ;;
            "teammate-only")
                # A teammate parked idle serializes exactly like a working
                # one. Once TeammateIdle has been observed for this session
                # (fresh tombstone), stale teammate entries must not re-mark
                # it — that would suppress every later completion with no
                # second retirement signal ever coming.
                if teammate_idle_tombstone_fresh; then
                    clear_delegated_work_marker
                    return 1
                fi
                mark_delegated_work_running
                return 0
                ;;
            "clear")
                clear_delegated_work_marker
                return 1
                ;;
            "unknown")
                delegated_work_marker_exists
                return $?
                ;;
        esac
    fi

    if [[ "$HOOK_TYPE" == "notification" ]] &&
        [[ "$NOTIFICATION_SUBTYPE" == "idle_prompt" ]]; then
        delegated_work_marker_exists
        return $?
    fi

    return 1
}

get_notification_subtype() {
    # Match approval/permission tokens against the structured type field when
    # the payload has one, so free-form message text containing words like
    # "permission" or "approved" can't misclassify (and bypass rate limiting).
    # Untyped payloads (Claude Code Notification hooks only carry a message)
    # keep the raw substring match.
    local payload_type permission_source
    payload_type=$(get_payload_type_field "$HOOK_DATA")
    # Lowercase for case-insensitive matching — gemini sends capitalised
    # types like "ToolPermission" (PowerShell's -match is already
    # case-insensitive, keeping the two implementations in parity).
    permission_source=$(printf '%s' "${payload_type:-$HOOK_DATA}" | tr '[:upper:]' '[:lower:]')

    if [[ "$HOOK_DATA" == *"idle_prompt"* ]]; then
        printf '%s\n' "idle_prompt"
        return 0
    fi

    if [[ "$permission_source" == *"permission_prompt"* ]] ||
        [[ "$permission_source" == *"request_permissions"* ]] ||
        [[ "$permission_source" == *"sandbox_approval"* ]] ||
        [[ "$permission_source" == *"approval"* ]] ||
        [[ "$permission_source" == *"approve"* ]] ||
        [[ "$permission_source" == *"permission"* ]]; then
        printf '%s\n' "permission_prompt"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"auth_success"* ]]; then
        printf '%s\n' "auth_success"
        return 0
    fi

    if [[ "$HOOK_DATA" == *"elicitation_dialog"* ]] || [[ "$HOOK_DATA" == *"mcp_elicitations"* ]]; then
        printf '%s\n' "elicitation_dialog"
        return 0
    fi

    printf '%s\n' "notification"
}

should_rate_limit_notification_subtype() {
    case "$1" in
        "permission_prompt"|"elicitation_dialog")
            return 1
            ;;
    esac

    return 0
}

get_notification_rate_limit_key() {
    local subtype="${1:-}"
    if [[ -z "$subtype" ]]; then
        subtype=$(get_notification_subtype)
    fi
    printf '%s\n' "last_notification_${TOOL_NAME}_${PROJECT_NAME}_${subtype}"
}

is_claude_event_hook() {
    case "$HOOK_TYPE" in
        "SubagentStart"|"SubagentStop"|"TeammateIdle"|"TaskCreated"|"TaskCompleted")
            return 0
            ;;
    esac
    return 1
}

get_event_rate_limit_key() {
    printf '%s\n' "last_event_${TOOL_NAME}_${PROJECT_NAME}_${HOOK_TYPE}"
}

is_rate_limited() {
    local rate_limit_key="$1"
    local rate_limit_seconds="$2"
    local lock_file legacy_lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")
    legacy_lock_file=$(get_legacy_rate_limit_file "$rate_limit_key")

    if [[ ! -f "$lock_file" ]] && [[ -f "$legacy_lock_file" ]]; then
        lock_file="$legacy_lock_file"
    fi

    if [[ ! -f "$lock_file" ]]; then
        return 1  # No previous notification, not rate limited
    fi

    local last_time
    last_time=$(cat "$lock_file" 2>/dev/null || echo "0")
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - last_time))

    if [[ $elapsed -lt $rate_limit_seconds ]]; then
        return 0  # Rate limited
    fi

    return 1  # Not rate limited
}

update_rate_limit() {
    local rate_limit_key="$1"
    local lock_file legacy_lock_file
    lock_file=$(get_rate_limit_file "$rate_limit_key")
    legacy_lock_file=$(get_legacy_rate_limit_file "$rate_limit_key")
    mkdir -p "$RATE_LIMIT_DIR"
    date +%s > "$lock_file"
    if [[ "$legacy_lock_file" != "$lock_file" ]]; then
        rm -f "$legacy_lock_file"
    fi
}

is_project_scoped_notification() {
    if [[ "${CODE_NOTIFY_SCOPE:-}" == "project" ]]; then
        return 0
    fi

    if [[ "$RAW_ARG1" != "codex" ]] && [[ -n "$RAW_ARG3" ]]; then
        return 0
    fi

    return 1
}

# Find the newest Codex state database without hard-coding a schema version suffix.
get_latest_codex_state_db() {
    local latest=""
    local candidate

    for candidate in "$HOME/.codex"/state*.sqlite; do
        [[ -e "$candidate" ]] || continue
        if [[ -z "$latest" ]] || [[ "$candidate" -nt "$latest" ]]; then
            latest="$candidate"
        fi
    done

    [[ -n "$latest" ]] || return 1
    printf '%s\n' "$latest"
}

# Resolve the thread originator from Codex local state when the notify payload includes thread-id.
get_codex_thread_originator() {
    local thread_id="$1"
    local state_db

    [[ -n "$thread_id" ]] || return 1
    has_python3 || return 1

    state_db=$(get_latest_codex_state_db) || return 1

    python3 - "$state_db" "$thread_id" <<'PY' 2>/dev/null
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1])
thread_id = sys.argv[2]

try:
    with sqlite3.connect(db_path) as conn:
        cur = conn.cursor()
        cur.execute("select rollout_path from threads where id = ?", (thread_id,))
        row = cur.fetchone()
except Exception:
    row = None

if not row or not row[0]:
    raise SystemExit(0)

try:
    first_line = pathlib.Path(row[0]).read_text(encoding="utf-8", errors="ignore").splitlines()[0]
    payload = json.loads(first_line).get("payload", {})
    originator = payload.get("originator", "")
except Exception:
    originator = ""

if isinstance(originator, str):
    print(originator, end="")
PY
}

# Suppress only when this Codex event came from the desktop app itself.
# Set CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK=1 to disable (used in tests).
is_codex_desktop_trigger() {
    [[ "$TOOL_NAME" != "codex" ]] && return 1
    [[ "${CODE_NOTIFY_SKIP_CODEX_DESKTOP_CHECK:-}" == "1" ]] && return 1

    local client
    client=$(json_extract_string "$HOOK_DATA" "client" | tr '[:upper:]' '[:lower:]')
    case "$client" in
        *app*|appserver)
            return 0
            ;;
    esac

    local thread_id originator
    thread_id=$(json_extract_string "$HOOK_DATA" "thread-id")
    [[ -n "$thread_id" ]] || return 1

    originator=$(get_codex_thread_originator "$thread_id")
    case "$originator" in
        "Codex Desktop")
            return 0
            ;;
    esac

    return 1
}

# Set when the only thing suppressing a stop is the stop rate limit, so the
# call site can still deliver that window's tmux badge. Every other suppressor
# is a hard one and leaves this at 0.
# shellcheck disable=SC2034  # read at the suppression call site below
STOP_RATE_LIMIT_BADGE_ONLY=0

# Function to check if notification should be suppressed
should_suppress_notification() {
    STOP_RATE_LIMIT_BADGE_ONLY=0

    # Check kill switch first - instant disable without restart
    if [[ -f "$HOME/.claude/notifications/disabled" ]] && ! is_project_scoped_notification; then
        return 0  # Suppress notification
    fi

    # Skip suppression checks for test notifications
    if [[ "$HOOK_TYPE" == "test" ]]; then
        return 1
    fi

    # Timed snooze silences everything, including approval prompts — unlike
    # automatic rate limiting it is an explicit user request for quiet.
    if snooze_is_active; then
        return 0
    fi

    # Suppress only when this Codex event originated from the desktop app.
    if is_codex_desktop_trigger; then
        return 0
    fi

    # Suppress repeated state-style notifications such as idle_prompt.
    # Uses NOTIFICATION_SUBTYPE computed once in the main flow.
    if [[ "$HOOK_TYPE" == "notification" ]]; then
        if should_rate_limit_notification_subtype "$NOTIFICATION_SUBTYPE"; then
            if is_rate_limited "$(get_notification_rate_limit_key "$NOTIFICATION_SUBTYPE")" "$NOTIFICATION_RATE_LIMIT_SECONDS"; then
                return 0
            fi
        fi
    fi

    if is_claude_event_hook; then
        if is_rate_limited "$(get_event_rate_limit_key)" "$EVENT_RATE_LIMIT_SECONDS"; then
            return 0
        fi
    fi

    # For Stop hooks: Check if stop_hook_active is true
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"stop_hook_active":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    # Check for auto-accept indicator
    if [[ "${CLAUDE_AUTO_ACCEPT:-}" == "true" ]]; then
        return 0
    fi

    if [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"autoAccepted":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    # Rate limit stop notifications to prevent spam from parallel sub-agents.
    # Deliberately the last check: every suppressor above is a hard one that
    # must withhold the tmux badge too, while this one only silences the alert —
    # the call site turns it into a badge-only run. Ordering it last is what
    # makes "returned here" mean "nothing else objected", so a stop_hook_active
    # or auto-accepted stop cannot slip through as a badge.
    #
    # Badge-only runs are exempt entirely: they never toast, and the completion
    # that preceded them stamped this very key — limiting here would silently
    # drop the badge reconcile they exist to deliver.
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ "${CODE_NOTIFY_BADGE_ONLY:-}" != "1" ]]; then
        if is_rate_limited "last_stop_notification" "$STOP_RATE_LIMIT_SECONDS"; then
            STOP_RATE_LIMIT_BADGE_ONLY=1
            return 0  # Suppress the alert - too soon since last notification
        fi
    fi

    return 1
}

# Classify the notification subtype once; both the suppression check and the
# rate-limit update below use it (classification spawns jq/python3, which is
# the dominant pre-banner cost).
NOTIFICATION_SUBTYPE=""
if [[ "$HOOK_TYPE" == "notification" ]]; then
    if [[ -n "$AGY_FORCED_SUBTYPE" ]]; then
        # Antigravity hooks carry no type tokens in the payload, so the
        # wrapper-declared subtype (e.g. permission_prompt) is authoritative.
        NOTIFICATION_SUBTYPE="$AGY_FORCED_SUBTYPE"
    else
        NOTIFICATION_SUBTYPE=$(get_notification_subtype)
    fi
fi

# StopFailure fires when a turn ends on an API error instead of a Stop event
# (Claude Code sends no Stop then, so nothing else would take the running
# indicator down). The payload's "error" field carries the error class:
# rate_limit is the "usage limit reached, stop and wait" outcome — kept as
# its own hook type for a distinct badge and pause-style resume semantics;
# every other class (or an unreadable payload — the safe default) is a plain
# failure and is folded into the existing error path. Only the structured
# field decides: a raw-substring fallback would misclassify failures whose
# error_details or last_assistant_message merely mention "rate_limit".
STOP_FAILURE_ERROR_TYPE=""
if [[ "$HOOK_TYPE" == "StopFailure" ]]; then
    STOP_FAILURE_ERROR_TYPE=$(json_extract_string "$HOOK_DATA" "error")
    if [[ "$STOP_FAILURE_ERROR_TYPE" != "rate_limit" ]]; then
        HOOK_TYPE="error"
    fi
fi

# Prefer the specific AskUserQuestion notification over Claude's immediately
# following generic permission alert. Exit before any running-state, badge,
# audio, channel, or desktop-notification side effects so the 🙋 state remains
# intact. Other sessions and the next permission prompt in this session do not
# share the consumed marker and proceed normally.
if [[ "$HOOK_TYPE" == "PreToolUse" ]]; then
    mark_ask_user_pending
elif [[ "$TOOL_NAME" == "claude" ]] &&
    [[ "$HOOK_TYPE" == "notification" ]] &&
    [[ "$NOTIFICATION_SUBTYPE" == "permission_prompt" ]] &&
    consume_recent_ask_user_pending; then
    exit 0
fi

# background_tasks cannot distinguish a working teammate from one parked
# idle: both serialize as type=teammate,status=running. The lifecycle events
# are therefore the retirement signal for the persisted snapshot. They clear
# state before their optional event toast proceeds normally.
#
# One retirement clears eagerly even if other delegates are still running:
# the marker stores no per-delegate identity because event delivery is not
# guaranteed, so counting down could wedge in the suppressing state — the
# failure direction this feature is designed to avoid. The next Stop
# snapshot re-arms the marker while delegated work remains, so the cost of
# eager clearing is at most one early idle reminder in between.
if [[ "$TOOL_NAME" == "claude" ]]; then
    case "$HOOK_TYPE" in
        "TeammateIdle")
            # The tombstone outlives this one-shot event: the parked teammate
            # keeps its status=running registry entry, so later Stops need a
            # durable record that it already retired.
            clear_delegated_work_marker
            mark_teammate_idle_tombstone
            claude_event_alert_enabled "$HOOK_TYPE" || exit 0
            ;;
        "SubagentStop")
            clear_delegated_work_marker
            claude_event_alert_enabled "$HOOK_TYPE" || exit 0
            ;;
    esac
fi

# A Stop with delegated work still in flight is a pause, not completion. Exit
# before persistent-alert classification, running-state mutation, rate-limit
# updates, logging, and notification delivery. The marker also suppresses the
# native idle reminder until a later Stop snapshot reports no running
# subagent/teammate and clears it.
if claude_delegated_work_should_suppress; then
    exit 0
fi

# Map the current event to the canonical key stored by `cn alerts persist add`.
get_persist_key() {
    case "$HOOK_TYPE" in
        "stop")
            printf '%s\n' "stop"
            ;;
        "notification")
            printf '%s\n' "$NOTIFICATION_SUBTYPE"
            ;;
        "PreToolUse")
            printf '%s\n' "ask_user"
            ;;
        "SubagentStart"|"SubagentStop"|"TeammateIdle"|"TaskCreated"|"TaskCompleted")
            printf '%s\n' "$HOOK_TYPE"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

# Persistent ("sticky") delivery: classified once, used by the per-platform
# senders to keep the alert visible until dismissed or until persist-timeout.
PERSIST_ACTIVE=0
if persist_is_type_enabled "$(get_persist_key)"; then
    PERSIST_ACTIVE=1
fi

notification_is_persistent() {
    [[ "$PERSIST_ACTIVE" == "1" ]]
}

# The agent reached a terminal state (done, waiting for input, or failed):
# take the running marker off its window. This must precede the suppression
# check — a snoozed or rate-limited stop is still a stop, and leaving the
# marker (or spinner) up would show an agent working when none is. Mid-run
# events (SubagentStart/Stop, TaskCreated/Completed, TeammateIdle) don't stop
# it: the main agent is still going.
case "$HOOK_TYPE" in
    "notification")
        # Notifications represent a pause except auth_success, which reports a
        # completed authentication flow rather than a question the user must
        # answer. Preserve the pause so a subsequent tool lifecycle hook can
        # put the running indicator back immediately after the user responds.
        # Only answerable mid-turn dialogs watch pane activity for the answer
        # itself: an idle reminder means no turn is running, so activity after
        # it (clicking the toast, typing the next prompt) must not light the
        # spinner — UserPromptSubmit is its real resume signal.
        case "$NOTIFICATION_SUBTYPE" in
            "auth_success")
                tmux_running_stop 2>/dev/null || true
                ;;
            "permission_prompt"|"elicitation_dialog")
                tmux_running_pause_for_input watch 2>/dev/null || true
                ;;
            *)
                tmux_running_pause_for_input 2>/dev/null || true
                ;;
        esac
        # Every subtype above took the indicator down, and each releases the
        # transition lock before this run reaches its badge — so the same
        # queued-successor race the terminal events guard against applies here
        # (see TMUX_BADGE_RUNNING_GUARD below). Mid-run events reach this file
        # under a different hook type; they leave the marker alone and must
        # keep badging a running window.
        TMUX_BADGE_RUNNING_GUARD=1
        ;;
    "PreToolUse")
        # The managed Claude AskUserQuestion hook uses this event. Once its
        # answer is supplied, PostToolUse (or the following PreToolUse) resumes
        # the same turn without a UserPromptSubmit event.
        tmux_running_pause_for_input 2>/dev/null || true
        TMUX_BADGE_RUNNING_GUARD=1
        ;;
    "StopFailure")
        # The usage limit ended the turn mid-task. Pause rather than stop: the
        # turn may continue when the limit resets, and PostToolUse (or the
        # user's next prompt) re-lights the running indicator via the
        # resume-pending marker. No pane watch — repaints of the limit dialog
        # or its countdown must not be mistaken for the turn resuming.
        tmux_running_pause_for_input 2>/dev/null || true
        TMUX_BADGE_RUNNING_GUARD=1
        ;;
    "stop"|"error"|"failed")
        if [[ "$AGY_STOP_FINAL_CLEANUP" != "1" ]]; then
            if [[ "${CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED:-}" == "1" ]]; then
                # The settle sweep removed this hook-less turn under the
                # transition lock before invoking us. Do not run the generic
                # stop again: a new prompt may have claimed the window in the
                # small handoff between the sweep and this synthetic event.
                :
            else
                # consume-queued-prompt: a UserPromptSubmit that raced or queued
                # ahead of this turn end already armed the indicator for the next
                # turn; this teardown must not run it dark (see tmux_running_stop).
                tmux_running_stop consume-queued-prompt 2>/dev/null || true
            fi
            # Only this queued-prompt path shares its running state with
            # UserPromptSubmit. Antigravity performs separate cleanup and
            # must still receive its normal terminal badge.
            TMUX_BADGE_RUNNING_GUARD=1
        fi
        # Codex and Antigravity send nothing further once a turn ends —
        # there is no equivalent of Claude's native idle_prompt reminder —
        # so a completed window could sit unattended forever. Arm the tmux
        # idle watch: if the pane's content holds still for the idle window
        # after this completion, one synthetic idle_prompt fires through
        # this notifier. Agent gating (TMUX_IDLE_AGENTS), alert-type gating
        # and tmux availability all live inside the helper; outside tmux
        # this is a no-op. Deliberately before the suppression check below:
        # a rate-limited completion is still a completion the user has not
        # seen, and the nudge run self-gates on snooze/kill switch anyway.
        if [[ "$HOOK_TYPE" == "stop" ]]; then
            if [[ "${CODE_NOTIFY_TMUX_STOP_ALREADY_APPLIED:-}" == "1" ]]; then
                tmux_idle_watch_arm_current_unless_running \
                    "$TOOL_NAME" "$PROJECT_NAME" 2>/dev/null || true
            else
                tmux_idle_watch_arm_current "$TOOL_NAME" "$PROJECT_NAME" 2>/dev/null || true
            fi
        fi
        ;;
esac

# The locked re-check inside that transition rejected this run: it is a
# synthetic child of a tmux watch, and the run it was scheduled against was
# retired or replaced while this process was starting up. Nothing was changed
# above, and nothing may be delivered below — the alert describes a dialog the
# user has already dealt with. The start-up guard catches most of these; this
# is the one that cannot be raced, because it was answered under the same lock
# that guards the state change. Rate limiting is deliberately left unstamped:
# no alert went out, so none was consumed.
if [[ "${TMUX_RUNNING_GUARD_REJECTED:-0}" == "1" ]]; then
    exit 0
fi

# Check if notification should be suppressed. "error" is included so that the
# kill switch (cn off) and snooze silence failure alerts too — they are still
# notifications and must honour an explicit request for quiet.
if [[ "$HOOK_TYPE" == "stop" ]] || [[ "$HOOK_TYPE" == "notification" ]] || [[ "$HOOK_TYPE" == "error" ]] || [[ "$HOOK_TYPE" == "StopFailure" ]] || [[ "$HOOK_TYPE" == "PreToolUse" ]] || is_claude_event_hook; then
    if should_suppress_notification; then
        # A stop silenced only by the rate limit still earns its tmux badge.
        # The limit exists to keep parallel sub-agents from spamming toasts, but
        # the badge is per-window, silent and idempotent, so it cannot spam —
        # and exiting here left the window with no indicator at all, because the
        # running-marker teardown above already ran (it deliberately precedes
        # this check, so the spinner is already down). Worse, the key is a
        # single process-wide file, not scoped by agent/project/window, so any
        # agent finishing anywhere could blank an unrelated window's badge and
        # leave a completed turn looking untouched.
        #
        # Downgrade to a badge-only run instead of exiting: it takes the normal
        # path as far as the badge and stops there (see the badge-only exit
        # below), so no toast, sound, voice or channel delivery follows. It also
        # leaves the rate-limit key unstamped and writes no notifications.log
        # line (both are guarded on CODE_NOTIFY_BADGE_ONLY), so the next
        # completion still alerts on time rather than being pushed out by a stop
        # that never made a sound.
        if [[ "$STOP_RATE_LIMIT_BADGE_ONLY" == "1" ]]; then
            CODE_NOTIFY_BADGE_ONLY=1
        else
            exit 0
        fi
    fi
fi

# Update rate limit timestamp for stop notifications. A badge-only run sends
# no toast, so it must not stamp the key either — that could swallow the next
# real completion's alert.
if [[ "$HOOK_TYPE" == "stop" ]] && [[ "${CODE_NOTIFY_BADGE_ONLY:-}" != "1" ]]; then
    update_rate_limit "last_stop_notification"
elif [[ "$HOOK_TYPE" == "notification" ]]; then
    if should_rate_limit_notification_subtype "$NOTIFICATION_SUBTYPE"; then
        update_rate_limit "$(get_notification_rate_limit_key "$NOTIFICATION_SUBTYPE")"
    fi
elif is_claude_event_hook; then
    update_rate_limit "$(get_event_rate_limit_key)"
fi

choose_random_message() {
    local messages=("$@")
    local count="${#messages[@]}"

    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    printf '%s\n' "${messages[$((RANDOM % count))]}"
}

# Wording style for the banner and the spoken message, each "short" (terse
# one-liners) or "long" (friendlier sentences in the style of
# opencode-smart-voice-notify). Banners truncate after a line or two, so they
# default to short; speech reads well at length, so it defaults to long.
# `cn wording` writes the state files; the env vars override per invocation.
wording_style() {
    local target="$1"
    local default="$2"
    local value=""
    local style_file="$HOME/.claude/notifications/wording-$target"

    case "$target" in
        "banner") value="${CODE_NOTIFY_BANNER_WORDING:-}" ;;
        "voice") value="${CODE_NOTIFY_VOICE_WORDING:-}" ;;
    esac
    if [[ -z "$value" ]] && [[ -r "$style_file" ]]; then
        read -r value < "$style_file" 2>/dev/null || true
    fi
    case "$value" in
        "short"|"long") printf '%s\n' "$value" ;;
        *) printf '%s\n' "$default" ;;
    esac
}
BANNER_WORDING=$(wording_style banner short)
VOICE_WORDING=$(wording_style voice long)

# Whether the project name is appended to a target ("banner" or "voice"),
# each on by default and toggled independently. `cn wording project` writes
# the state files; the env vars override per invocation. Only the visible/
# audible suffix is affected — the project stays in cache, dedupe, and
# rate-limit keys, which are functional rather than cosmetic.
project_wording_enabled() {
    local target="$1"
    local value=""
    local state_file="$HOME/.claude/notifications/wording-project-$target"

    case "$target" in
        "banner") value="${CODE_NOTIFY_BANNER_PROJECT:-}" ;;
        "voice") value="${CODE_NOTIFY_VOICE_PROJECT:-}" ;;
    esac
    if [[ -z "$value" ]] && [[ -r "$state_file" ]]; then
        read -r value < "$state_file" 2>/dev/null || true
    fi
    [[ "$value" != "off" ]]
}

# Set MESSAGE and VOICE_MESSAGE for an event from a short pool and a long
# pool (arguments separated by --), honouring the configured wording styles.
set_event_messages() {
    local -a short_pool=()
    local -a long_pool=()
    local in_long=0
    local arg

    for arg in "$@"; do
        if [[ "$arg" == "--" ]]; then
            in_long=1
            continue
        fi
        if [[ "$in_long" == "1" ]]; then
            long_pool+=("$arg")
        else
            short_pool+=("$arg")
        fi
    done

    if [[ "$BANNER_WORDING" == "long" ]]; then
        MESSAGE=$(choose_random_message "${long_pool[@]}")
    else
        MESSAGE=$(choose_random_message "${short_pool[@]}")
    fi
    if [[ "$VOICE_WORDING" == "long" ]]; then
        VOICE_MESSAGE=$(choose_random_message "${long_pool[@]}")
    else
        VOICE_MESSAGE=$(choose_random_message "${short_pool[@]}")
    fi
}

# Set notification parameters based on hook type and tool.
# BADGE_ICON marks the originating tmux window's name (see tmux_badge_set);
# events without one (usage alerts fire from the background watcher, not the
# user's pane) skip the badge.
BADGE_ICON=""
case "$HOOK_TYPE" in
    "stop")
        TITLE="$TOOL_DISPLAY 🟢"
        BADGE_ICON="🟢"
        SUBTITLE="Task Complete"
        set_event_messages \
            "$TOOL_DISPLAY completed the task" \
            "$TOOL_DISPLAY finished the task" \
            "$TOOL_DISPLAY is done" \
            "$TOOL_DISPLAY wrapped up" \
            -- \
            "All done! $TOOL_DISPLAY completed your task" \
            "Task complete! $TOOL_DISPLAY finished working on your request" \
            "Over to you! $TOOL_DISPLAY completed your task and is standing by" \
            "Good news! $TOOL_DISPLAY is done and ready for you" \
            "Finished! $TOOL_DISPLAY wrapped up your request"
        SOUND="Glass"
        ;;
    "notification")
        TITLE="$TOOL_DISPLAY 💬"
        BADGE_ICON="💬"
        SUBTITLE="Input Required"
        SOUND="Ping"
        case "$NOTIFICATION_SUBTYPE" in
            "idle_prompt")
                # Idle is a nudge, not a question: distinct icon so a glance
                # tells "waiting on you" apart from an actual input request.
                TITLE="$TOOL_DISPLAY 🥱"
                BADGE_ICON="🥱"
                SUBTITLE="Idle"
                set_event_messages \
                    "$TOOL_DISPLAY is idle" \
                    "$TOOL_DISPLAY is waiting" \
                    "$TOOL_DISPLAY is ready for you" \
                    "$TOOL_DISPLAY can take more work now" \
                    -- \
                    "Hey, are you still there? $TOOL_DISPLAY is waiting for you" \
                    "Just a gentle reminder - $TOOL_DISPLAY finished a while ago" \
                    "Hello? $TOOL_DISPLAY is idle and ready for more work" \
                    "Still waiting for you! $TOOL_DISPLAY can take more work now" \
                    "Knock knock! $TOOL_DISPLAY is patiently waiting for you"
                ;;
            "permission_prompt")
                set_event_messages \
                    "$TOOL_DISPLAY needs your approval" \
                    "$TOOL_DISPLAY is waiting for approval" \
                    "$TOOL_DISPLAY needs permission to continue" \
                    "$TOOL_DISPLAY has an approval request" \
                    -- \
                    "Attention please! $TOOL_DISPLAY needs your permission to continue" \
                    "Hey! $TOOL_DISPLAY needs a quick approval to proceed" \
                    "Heads up! $TOOL_DISPLAY has a permission request waiting for you" \
                    "Excuse me! $TOOL_DISPLAY needs your authorization to continue" \
                    "Permission required! $TOOL_DISPLAY is waiting for your approval"
                ;;
            "elicitation_dialog")
                set_event_messages \
                    "$TOOL_DISPLAY needs MCP tool input" \
                    "$TOOL_DISPLAY is waiting for MCP input" \
                    "$TOOL_DISPLAY needs a tool response" \
                    "$TOOL_DISPLAY has an MCP prompt" \
                    -- \
                    "Attention! $TOOL_DISPLAY needs MCP tool input to continue" \
                    "Hey! An MCP tool in $TOOL_DISPLAY is waiting for your input" \
                    "Quick response needed! $TOOL_DISPLAY has an MCP prompt for you" \
                    "$TOOL_DISPLAY needs a tool response to proceed"
                ;;
            "auth_success")
                SUBTITLE="Authentication"
                MESSAGE=$(choose_random_message \
                    "$TOOL_DISPLAY authentication succeeded" \
                    "$TOOL_DISPLAY signed in successfully" \
                    "$TOOL_DISPLAY authentication is complete" \
                    "$TOOL_DISPLAY is authenticated")
                ;;
            *)
                set_event_messages \
                    "$TOOL_DISPLAY needs your input" \
                    "$TOOL_DISPLAY is waiting for you" \
                    "$TOOL_DISPLAY needs a response" \
                    "$TOOL_DISPLAY has something for you" \
                    -- \
                    "Hey! $TOOL_DISPLAY needs your input to continue" \
                    "Attention! $TOOL_DISPLAY is waiting for you" \
                    "Quick check! $TOOL_DISPLAY has something for you" \
                    "$TOOL_DISPLAY needs a response to proceed"
                ;;
        esac
        # Subtypes without their own spoken form fall back to the banner text.
        VOICE_MESSAGE="${VOICE_MESSAGE:-$MESSAGE}"
        ;;
    "SubagentStart")
        TITLE="$TOOL_DISPLAY 🍃"
        BADGE_ICON="🍃"
        SUBTITLE="Subagent Started"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY started a subagent" \
            "$TOOL_DISPLAY launched a subagent" \
            "$TOOL_DISPLAY delegated work to a subagent" \
            "$TOOL_DISPLAY spun up a subagent")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
    "SubagentStop")
        TITLE="$TOOL_DISPLAY 🍂"
        BADGE_ICON="🍂"
        SUBTITLE="Subagent Complete"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY subagent completed" \
            "$TOOL_DISPLAY subagent finished" \
            "$TOOL_DISPLAY subagent is done" \
            "$TOOL_DISPLAY subagent wrapped up")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "TeammateIdle")
        TITLE="$TOOL_DISPLAY 💤"
        BADGE_ICON="💤"
        SUBTITLE="Teammate Idle"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY teammate is waiting for input" \
            "$TOOL_DISPLAY teammate is idle" \
            "$TOOL_DISPLAY teammate needs your response" \
            "$TOOL_DISPLAY teammate can take more work now")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Ping"
        ;;
    "TaskCreated")
        TITLE="$TOOL_DISPLAY 📙"
        BADGE_ICON="📙"
        SUBTITLE="Task Created"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY agent-team task was created" \
            "$TOOL_DISPLAY created an agent-team task" \
            "$TOOL_DISPLAY added a team task" \
            "$TOOL_DISPLAY opened a new agent-team task")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
    "TaskCompleted")
        TITLE="$TOOL_DISPLAY 📗"
        BADGE_ICON="📗"
        SUBTITLE="Task Complete"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY agent-team task completed" \
            "$TOOL_DISPLAY completed a team task" \
            "$TOOL_DISPLAY finished an agent-team task" \
            "$TOOL_DISPLAY team task is done")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "StopFailure")
        # Only the rate_limit error class keeps this hook type (others were
        # normalized to "error" above): the session/usage limit ended the turn.
        TITLE="$TOOL_DISPLAY ⏳"
        BADGE_ICON="⏳"
        SUBTITLE="Limit Reached"
        set_event_messages \
            "$TOOL_DISPLAY hit the usage limit" \
            "$TOOL_DISPLAY reached the session limit" \
            "$TOOL_DISPLAY is paused at the usage limit" \
            "$TOOL_DISPLAY stopped at the usage limit" \
            -- \
            "Whoopsie! $TOOL_DISPLAY hit the usage limit and is waiting for it to reset" \
            "Uh-oh! $TOOL_DISPLAY reached the session limit, so the task is paused until it resets" \
            "Oh no! $TOOL_DISPLAY stopped mid-task until your usage resets" \
            "Oops! $TOOL_DISPLAY is waiting out the usage limit before it can continue"
        SOUND="Basso"
        ;;
    "error"|"failed")
        TITLE="$TOOL_DISPLAY 🧨"
        BADGE_ICON="🧨"
        SUBTITLE="Error"
        MESSAGE=$(choose_random_message \
            "An error occurred in $TOOL_DISPLAY" \
            "$TOOL_DISPLAY hit an error" \
            "$TOOL_DISPLAY ran into a problem" \
            "$TOOL_DISPLAY reported a failure")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Basso"
        ;;
    "test")
        TITLE="Code-Notify Test 🧪"
        BADGE_ICON="🧪"
        SUBTITLE="$PROJECT_NAME"
        MESSAGE=$(choose_random_message \
            "Notifications are working!" \
            "Code-Notify is working!" \
            "Test notification delivered!" \
            "Notification delivery is working!")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Glass"
        ;;
    "usage")
        TITLE="${CODE_NOTIFY_USAGE_TITLE:-$TOOL_DISPLAY usage alert}"
        SUBTITLE="Usage Alert"
        MESSAGE="${CODE_NOTIFY_USAGE_MESSAGE:-$(choose_random_message \
            "$TOOL_DISPLAY usage changed" \
            "$TOOL_DISPLAY usage has an update" \
            "$TOOL_DISPLAY usage needs attention" \
            "$TOOL_DISPLAY usage crossed a threshold")}"
        VOICE_MESSAGE="${CODE_NOTIFY_USAGE_VOICE_MESSAGE:-$MESSAGE}"
        SOUND="Ping"
        ;;
    "usage_reset")
        TITLE="${CODE_NOTIFY_USAGE_TITLE:-$TOOL_DISPLAY tokens reset}"
        SUBTITLE="Tokens Reset"
        MESSAGE="${CODE_NOTIFY_USAGE_MESSAGE:-$(choose_random_message \
            "$TOOL_DISPLAY tokens have reset. Usage is back to 100%." \
            "$TOOL_DISPLAY token window reset" \
            "$TOOL_DISPLAY usage is back to full" \
            "$TOOL_DISPLAY tokens are available again")}"
        VOICE_MESSAGE="${CODE_NOTIFY_USAGE_VOICE_MESSAGE:-$MESSAGE}"
        SOUND="Hero"
        ;;
    "PreToolUse")
        # AskUserQuestion: extract question text and show notification
        ASK_QUESTION_TEXT=""
        if has_jq; then
            ASK_QUESTION_TEXT=$(printf '%s' "$HOOK_DATA" | jq -r '.tool_input.questions[0].question // ""' 2>/dev/null)
        elif has_python3; then
            ASK_QUESTION_TEXT=$(printf '%s' "$HOOK_DATA" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    questions = data.get("tool_input", {}).get("questions", [])
    print(questions[0]["question"] if questions else "", end="")
except Exception:
    print("", end="")
' 2>/dev/null)
        fi

        TITLE="$TOOL_DISPLAY 🙋"
        BADGE_ICON="🙋"
        SUBTITLE="Question"
        if [[ -n "$ASK_QUESTION_TEXT" ]]; then
            MESSAGE=$(printf '%s\n' "$ASK_QUESTION_TEXT" | head -c 150 | tr '\n' ' ')
            MESSAGE="${MESSAGE% }"
            if [[ ${#ASK_QUESTION_TEXT} -gt 150 ]]; then
                MESSAGE="${MESSAGE}..."
            fi
            if [[ "$VOICE_WORDING" == "long" ]]; then
                VOICE_MESSAGE="Hey! $TOOL_DISPLAY has a question for you"
            else
                VOICE_MESSAGE="$TOOL_DISPLAY is asking a question"
            fi
        else
            set_event_messages \
                "$TOOL_DISPLAY is asking a question" \
                "$TOOL_DISPLAY has a question" \
                "$TOOL_DISPLAY needs an answer" \
                "$TOOL_DISPLAY is waiting on a question" \
                -- \
                "Hey! $TOOL_DISPLAY has a question for you" \
                "Attention! $TOOL_DISPLAY needs your answer to continue" \
                "Quick question! $TOOL_DISPLAY needs your input" \
                "$TOOL_DISPLAY needs some clarification from you" \
                "Question time! $TOOL_DISPLAY is waiting for your answer"
        fi
        SOUND="Ping"
        ;;
    *)
        TITLE="$TOOL_DISPLAY 📢"
        BADGE_ICON="📢"
        SUBTITLE="Status Update"
        MESSAGE=$(choose_random_message \
            "$TOOL_DISPLAY: $HOOK_TYPE" \
            "$TOOL_DISPLAY sent a status update" \
            "$TOOL_DISPLAY reported $HOOK_TYPE" \
            "$TOOL_DISPLAY has an update")
        VOICE_MESSAGE="$MESSAGE"
        SOUND="Pop"
        ;;
esac

# Project context is already carried in the notification subtitle and channel
# metadata. Speak it as well, so identical events from different worktrees are
# distinguishable without looking at the banner.
# VOICE_PROJECT scopes the TTS cache and is set only when the spoken message
# actually names the project: an unnamed project must not fragment the cache,
# or the same audio is synthesized (and paid for) once per worktree.
VOICE_PROJECT=""
if [[ -n "$PROJECT_NAME" ]] && [[ "$HOOK_TYPE" != "test" ]] &&
    project_wording_enabled voice; then
    # "in project X" flows as one sentence — a ". Project X" suffix reads as
    # a run-on ("completed your task project X") with most voices. Speak the
    # name hyphenated: spaces let the TTS parser split the name into clauses
    # ("in project code <pause> notify"), while hyphens read as one compound;
    # underscores become hyphens so no voice verbalizes "underscore".
    VOICE_MESSAGE="${VOICE_MESSAGE} in project ${PROJECT_NAME//_/-}"
    VOICE_PROJECT="$PROJECT_NAME"
fi

# Add project name to subtitle if available
if [[ -n "$PROJECT_NAME" ]] && [[ "$HOOK_TYPE" != "test" ]] &&
    project_wording_enabled banner; then
    SUBTITLE="$SUBTITLE - $PROJECT_NAME"
fi

# Get terminal bundle ID for macOS activation
get_terminal_bundle_id() {
    click_through_resolve_activation_bundle_id
}

# Persistent alert via alerter (https://github.com/vjeantet/alerter).
# alerter blocks until the user interacts, so it runs detached and the
# click handler jumps back to the originating tmux pane.
send_macos_alerter_notification() {
    local focus_cmd="$1"
    local timeout_seconds="${2:-${CODE_NOTIFY_ALERTER_TIMEOUT:-600}}"
    local -a alerter_args=(
        --title "$TITLE"
        --subtitle "$SUBTITLE"
        --message "$MESSAGE"
        --group "code-notify-$TOOL_NAME-$PROJECT_NAME"
    )
    # Timeout 0 keeps the alert up until the user closes it (alerter waits
    # forever when no --timeout is given).
    if (( timeout_seconds > 0 )); then
        alerter_args+=(--timeout "$timeout_seconds")
    fi
    (
        # result stays scoped to this background subshell (the subshell body
        # is not a function, so `local` cannot be used here).
        result=$(alerter "${alerter_args[@]}" 2>/dev/null)
        case "$result" in
            "@CONTENTCLICKED"|"@ACTIONCLICKED")
                if [[ -n "$focus_cmd" ]]; then
                    /bin/sh -c "$focus_cmd" > /dev/null 2>&1
                fi
                ;;
        esac
    ) > /dev/null 2>&1 &
    disown 2>/dev/null || true
}

terminal_notifier_supports_focus() {
    terminal-notifier -help 2>&1 | grep -q -- "-focus"
}

# Function to send notification on macOS
send_macos_notification() {
    local bundle_id focus_cmd badge_clear_cmd
    bundle_id=$(get_terminal_bundle_id)

    # When running inside tmux, clicking the notification jumps back to the
    # originating tmux window/pane (in addition to activating the terminal).
    focus_cmd=$(tmux_focus_build_command "$bundle_id" 2>/dev/null) || focus_cmd=""

    # For glance-clear agents, clicking also clears the window-name badge.
    # Appended to focus_cmd so every click path (alerter, -execute) restores the
    # name; the clear command re-checks the saved state at click time, so it is a
    # no-op when no badge is set. Engage-clear agents (Claude, hooks-based Codex)
    # clear on prompt-submit instead, so a click there jumps to the window
    # without clearing — clicking is a glance.
    badge_clear_cmd=""
    if badge_glance_clear_enabled; then
        badge_clear_cmd=$(tmux_badge_build_clear_command 2>/dev/null) || badge_clear_cmd=""
    fi
    if [[ -n "$badge_clear_cmd" ]] && [[ -n "$focus_cmd" ]]; then
        focus_cmd="$focus_cmd; $badge_clear_cmd"
    fi

    if notification_is_persistent && command -v alerter &> /dev/null; then
        # Persistent alert: stays visible until clicked/closed or until the
        # persist timeout. Outside tmux, clicking still activates the
        # originating terminal app.
        if [[ -z "$focus_cmd" ]] && [[ -n "$bundle_id" ]]; then
            focus_cmd=$(printf 'open -b %q' "$bundle_id")
        fi
        send_macos_alerter_notification "$focus_cmd" "$(persist_get_timeout_seconds)"
    elif command -v terminal-notifier &> /dev/null; then
        # Keep desktop notifications silent and let play_sound() own audio playback.
        # That avoids double audio and preserves custom sound files.
        local tn_args=(
            -title "$TITLE"
            -subtitle "$SUBTITLE"
            -message "$MESSAGE"
            -group "code-notify-$TOOL_NAME-$PROJECT_NAME"
            -activate "$bundle_id"
        )
        # Show the originating tool's icon when known (claude/codex/gemini).
        if [[ -n "$TOOL_NAME" ]]; then
            tn_args+=(-appIcon "$TOOL_NAME")
        fi
        if terminal_notifier_supports_focus; then
            # -focus and -execute run together on click, so the badge clear
            # rides alongside the built-in focus handling.
            tn_args+=(-focus)
            if [[ -n "$badge_clear_cmd" ]]; then
                tn_args+=(-execute "$badge_clear_cmd")
            fi
        elif [[ -n "$focus_cmd" ]]; then
            tn_args+=(-execute "$focus_cmd")
        fi
        terminal-notifier "${tn_args[@]}" 2>/dev/null
    elif [[ -n "$focus_cmd" ]] && command -v alerter &> /dev/null; then
        send_macos_alerter_notification "$focus_cmd"
    else
        # osascript doesn't support click-to-activate, but we can use a workaround.
        # Keep this silent too so custom/default sound playback stays single-sourced.
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\"" 2>/dev/null
    fi
}

# Function to send notification on Linux
send_linux_notification() {
    if command -v notify-send &> /dev/null; then
        local -a ns_args=(
            --urgency=normal
            --app-name="Code-Notify"
            --icon=dialog-information
        )
        if notification_is_persistent; then
            # Critical urgency stays on screen in GNOME/KDE until dismissed;
            # expire-time is a best-effort cap (0 = never expire).
            ns_args=(
                --urgency=critical
                --app-name="Code-Notify"
                --icon=dialog-information
                --expire-time="$(( $(persist_get_timeout_seconds) * 1000 ))"
            )
        fi
        # notify-send has no subtitle field. Include it in the summary so the
        # event type and originating project remain visible on Linux.
        notify-send "$TITLE - $SUBTITLE" "$MESSAGE" "${ns_args[@]}" 2>/dev/null
    elif command -v zenity &> /dev/null; then
        zenity --notification \
            --text="$TITLE\n$MESSAGE" \
            2>/dev/null
    else
        echo "[$TITLE] $MESSAGE" | wall 2>/dev/null
    fi
}

# Strip non-ASCII characters before sending toast text to wsl-notify-send.exe.
sanitize_wsl_text() {
    printf '%s' "$1" | LC_ALL=C sed 's/[^\x20-\x7E]//g; s/  */ /g; s/^ *//; s/ *$//'
}

# Function to send notification on Windows
send_windows_notification() {
    if command -v powershell &> /dev/null; then
        powershell -Command "
            if (Get-Module -ListAvailable -Name BurntToast) {
                New-BurntToastNotification -Text '$TITLE', '$MESSAGE'
            } else {
                Add-Type -AssemblyName System.Windows.Forms
                \$notification = New-Object System.Windows.Forms.NotifyIcon
                \$notification.Icon = [System.Drawing.SystemIcons]::Information
                \$notification.BalloonTipIcon = 'Info'
                \$notification.BalloonTipTitle = '$TITLE'
                \$notification.BalloonTipText = '$MESSAGE'
                \$notification.Visible = \$true
                \$notification.ShowBalloonTip(10000)
            }
        " 2>/dev/null
    elif command -v msg &> /dev/null; then
        msg "%USERNAME%" "$TITLE: $MESSAGE" 2>/dev/null
    fi
}

# Check if voice is enabled for this tool
should_speak() {
    if [[ "$HOOK_TYPE" == "usage_reset" && "${CODE_NOTIFY_USAGE_RESET_VOICE:-true}" == "true" ]]; then
        return 0
    fi

    # Check tool-specific voice setting first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            return 0
        fi
    fi

    # Fall back to global voice setting
    local global_voice_file="$HOME/.claude/notifications/voice-enabled"
    if [[ -f "$global_voice_file" ]]; then
        return 0
    fi

    return 1
}

# Get voice setting (tool-specific or global)
get_voice_setting() {
    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        local usage_reset_voice
        usage_reset_voice=$(get_voice "tool" "$TOOL_NAME" 2>/dev/null || get_voice "global" 2>/dev/null || true)
        if [[ -n "$usage_reset_voice" ]]; then
            printf '%s\n' "$usage_reset_voice"
            return
        fi
        printf '%s\n' "Samantha"
        return
    fi

    # Check tool-specific voice first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            cat "$tool_voice_file"
            return
        fi
    fi

    # Fall back to global
    get_voice "global" 2>/dev/null || echo ""
}

# Check if sound should play
should_play_sound() {
    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        [[ "${CODE_NOTIFY_USAGE_RESET_SOUND:-true}" == "true" ]]
        return $?
    fi
    is_sound_enabled
}

get_notification_sound_file() {
    # An explicit reset-alert override wins over everything.
    if [[ "$HOOK_TYPE" == "usage_reset" ]] && [[ -n "${CODE_NOTIFY_USAGE_RESET_SOUND_FILE:-}" ]]; then
        printf '%s\n' "$CODE_NOTIFY_USAGE_RESET_SOUND_FILE"
        return
    fi

    # Per-event pool next: a random file from the folder matching this event
    # (see sound_event_candidates), so repeated alerts of the same kind vary.
    local pool_sound
    if pool_sound=$(pick_event_sound "$HOOK_TYPE" "${NOTIFICATION_SUBTYPE:-}" 2>/dev/null); then
        printf '%s\n' "$pool_sound"
        return
    fi

    if [[ "$HOOK_TYPE" == "usage_reset" ]]; then
        case "$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')" in
            "macos"|"Darwin"|"darwin")
                printf '%s\n' "/System/Library/Sounds/Hero.aiff"
                return
                ;;
        esac
    fi

    get_sound
}

# Badge the originating tmux window's name with the event icon so the alert
# stays visible in the status line. Clearing differs by agent (BADGE_CLEAR_MODE,
# recorded on the badge itself so the agent-blind sweep honours it):
#   - Glance-clear agents (legacy codex, gemini): sweep first so badges on
#     windows the user has since visited are restored before a new one lands,
#     and let badge-set arm the focus hook that clears on the next visit. On
#     macOS clicking the notification also clears; elsewhere only these paths
#     do (notify-send has no click hook).
#   - Engage-clear agents (claude, hooks-based codex, antigravity): clear on the
#     next work signal instead, so no sweep and no focus hook — the badge
#     persists until the user actually engages the window with new work, and
#     the sweep skips it even when another agent's activity triggers one.
if badge_glance_clear_enabled; then
    tmux_badge_sweep 2>/dev/null || true
fi
if [[ -n "$BADGE_ICON" ]] && [[ "${TMUX_RUNNING_STOP_PRESERVED:-0}" != "1" ]]; then
    # Terminal events badge even the visible window — completion should be
    # glanceable everywhere — and applying there also replaces a stale
    # waiting badge whose turn the user just watched end (an approval
    # answered inline leaves one). Waiting and mid-run events keep the
    # default skip: an idle reminder must not wipe or restack a badge the
    # user has not engaged away yet. `cn badge-visible on` (or
    # CODE_NOTIFY_TMUX_BADGE_VISIBLE=true) lifts the skip so every event
    # badges the window, focused or not.
    BADGE_VISIBLE_ACTION="skip"
    case "$HOOK_TYPE" in
        "stop"|"error"|"failed"|"StopFailure")
            BADGE_VISIBLE_ACTION="apply"
            ;;
    esac
    if tmux_badge_visible_enabled; then
        BADGE_VISIBLE_ACTION="apply"
    fi
    # Set by every event that retired this window's running marker above. Each
    # of those released the transition lock before delivery got here, so a
    # queued prompt can have re-lit the window in between — and this badge must
    # not land on top of the successor turn's live indicator.
    if [[ "${TMUX_BADGE_RUNNING_GUARD:-0}" == "1" ]]; then
        tmux_badge_set_unless_running \
            "$BADGE_ICON" "$BADGE_CLEAR_MODE" "" "$BADGE_VISIBLE_ACTION" 2>/dev/null || true
    else
        tmux_badge_set \
            "$BADGE_ICON" "$BADGE_CLEAR_MODE" "" "$BADGE_VISIBLE_ACTION" 2>/dev/null || true
    fi
fi

# A badge-only run ends at the badge. The settle reconcile of a preserved
# Stop (tmux_settle_watch_notify with CODE_NOTIFY_BADGE_ONLY=1) synthesizes a
# stop whose toast, sound, voice and channel delivery already went out with
# the Stop that kept the marker — only the terminal badge (above) and the
# idle watch (armed before the suppression check) were withheld. Skipping the
# log line too keeps notifications.log one-line-per-alert for diagnostics.
if [[ "${CODE_NOTIFY_BADGE_ONLY:-}" == "1" ]]; then
    exit 0
fi

# Send notification based on OS
OS=$(detect_os)
case "$OS" in
    macos)
        send_macos_notification
        # Voice and sound run detached so the hook exits right after the
        # banner — `say` alone blocks for seconds. Sound goes first so the
        # short alert chime starts before speech; `play_sound` backgrounds
        # afplay, and the natural TTS startup delay (synthesis round-trip,
        # or `say` warm-up) means the chime is done before speech is audible.
        (
            # Sound notification first if enabled (separate from voice)
            if should_play_sound; then
                play_sound "$(get_notification_sound_file)"
            fi
            # Voice notification if enabled
            if should_speak; then
                VOICE=$(get_voice_setting)
                if [[ -n "$VOICE" ]]; then
                    speak_notification "$VOICE_MESSAGE" "$VOICE" "$VOICE_PROJECT"
                fi
            fi
        ) > /dev/null 2>&1 &
        disown 2>/dev/null || true
        ;;
    linux)
        send_linux_notification
        # Sound notification if enabled
        if should_play_sound; then
            play_sound "$(get_notification_sound_file)"
        fi
        ;;
    wsl)
        # Send Windows toast notification via wsl-notify-send.exe
        # Windows requires toast notifications to use an AppUserModelID registered via a Start Menu
        # shortcut. Without a registered appId, toasts may not appear or only show in Action Center.
        # We borrow the terminal's appId since it's already registered and has banner permissions.
        if command -v wsl-notify-send.exe &> /dev/null; then
            WSL_APP_ID=""
            # Detect terminal app ID from environment
            if [[ "${WT_SESSION:-}" != "" ]]; then
                # Running inside Windows Terminal
                WSL_APP_ID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
            fi
            # Strip non-ASCII (emojis corrupt the XML toast template inside wsl-notify-send.exe)
            # wsl-notify-send.exe only accepts ONE positional arg; two args prints usage and exits
            WSL_TITLE=$(sanitize_wsl_text "$TITLE")
            WSL_MESSAGE=$(sanitize_wsl_text "$MESSAGE")
            # Add project name and branch to body, honouring the banner
            # project toggle (`cn test` always identifies the project, like
            # the macOS test subtitle does).
            WSL_PROJECT=""
            if [[ "$HOOK_TYPE" == "test" ]] || project_wording_enabled banner; then
                WSL_BRANCH=$(sanitize_wsl_text "$(git -C "$PWD" branch --show-current 2>/dev/null || true)")
                WSL_PROJECT=$(sanitize_wsl_text "$PROJECT_NAME")
                if [[ -n "$WSL_BRANCH" ]]; then
                    WSL_PROJECT="$WSL_PROJECT ($WSL_BRANCH)"
                fi
            fi
            WSL_NOTIFY_ARGS=(--appId "${WSL_APP_ID:-wsl-notify-send}" -c "$WSL_TITLE")
            if [[ -n "$WSL_PROJECT" ]]; then
                WSL_BODY=$(printf '%s\n%s' "$WSL_PROJECT" "$WSL_MESSAGE")
            else
                WSL_BODY="$WSL_MESSAGE"
            fi
            wsl-notify-send.exe "${WSL_NOTIFY_ARGS[@]}" "$WSL_BODY" 2>/dev/null
        else
            # Fallback to notify-send (only works if WSLg is active)
            send_linux_notification
        fi
        # Sound notification if enabled
        if should_play_sound; then
            play_sound "$(get_notification_sound_file)"
        fi
        ;;
    windows)
        send_windows_notification
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Post-banner bookkeeping: channel delivery (logs/webhooks), the usage check,
# and the log line. The usage check makes a network curl (up to
# CODE_NOTIFY_USAGE_TIMEOUT_SECONDS, default 5s) and channel webhooks can also
# touch the network, so none of this should keep the hook process alive — while
# a Stop/Notification hook runs, Claude Code treats the session as still
# working, which is what made notifications feel seconds late.
run_post_banner_tail() {
    channels_deliver "$TITLE" "$MESSAGE" "$TOOL_NAME" "$PROJECT_NAME" "${CODE_NOTIFY_USAGE_CONTEXT:-}" || true

    if [[ "${CODE_NOTIFY_SKIP_USAGE_CHECK:-}" != "1" ]]; then
        case "$TOOL_NAME" in
            "codex"|"claude")
                usage_check_with_lock "$TOOL_NAME" >/dev/null 2>&1 || true
                ;;
        esac
    fi

    local log_dir="$HOME/.claude/logs"
    if [[ -d "$log_dir" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TOOL_NAME] [$PROJECT_NAME] $MESSAGE" >> "$log_dir/notifications.log"
    fi
}

# Default: detach so the hook returns immediately. Tests set
# CODE_NOTIFY_TAIL_SYNC=1 to keep the tail synchronous (deterministic log/curl
# assertions and clean temp-dir teardown).
if [[ "${CODE_NOTIFY_TAIL_SYNC:-}" == "1" ]]; then
    run_post_banner_tail
else
    run_post_banner_tail > /dev/null 2>&1 &
    disown 2>/dev/null || true
fi

exit 0
