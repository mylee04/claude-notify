#!/bin/bash

# Configuration management for Code-Notify

# Default paths - Claude Code
DEFAULT_CLAUDE_HOME="$HOME/.claude"
ALT_CLAUDE_SETTINGS_HOME="$HOME/.config/.claude"
CLAUDE_HOME="${CLAUDE_HOME:-$DEFAULT_CLAUDE_HOME}"

if [[ -n "${CLAUDE_SETTINGS_HOME:-}" ]]; then
    RESOLVED_CLAUDE_SETTINGS_HOME="$CLAUDE_SETTINGS_HOME"
elif [[ "$CLAUDE_HOME" != "$DEFAULT_CLAUDE_HOME" ]]; then
    RESOLVED_CLAUDE_SETTINGS_HOME="$CLAUDE_HOME"
elif [[ -f "$DEFAULT_CLAUDE_HOME/settings.json" || -f "$DEFAULT_CLAUDE_HOME/hooks.json" ]]; then
    RESOLVED_CLAUDE_SETTINGS_HOME="$DEFAULT_CLAUDE_HOME"
elif [[ -f "$ALT_CLAUDE_SETTINGS_HOME/settings.json" || -f "$ALT_CLAUDE_SETTINGS_HOME/hooks.json" ]]; then
    RESOLVED_CLAUDE_SETTINGS_HOME="$ALT_CLAUDE_SETTINGS_HOME"
else
    RESOLVED_CLAUDE_SETTINGS_HOME="$DEFAULT_CLAUDE_HOME"
fi

GLOBAL_SETTINGS_FILE="$RESOLVED_CLAUDE_SETTINGS_HOME/settings.json"
GLOBAL_HOOKS_FILE="$RESOLVED_CLAUDE_SETTINGS_HOME/hooks.json"  # Legacy support
GLOBAL_HOOKS_DISABLED="$RESOLVED_CLAUDE_SETTINGS_HOME/hooks.json.disabled"
CONFIG_DIR="$HOME/.config/code-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

# Project-level settings
PROJECT_SETTINGS_FILE=".claude/settings.json"
PROJECT_SETTINGS_LOCAL_FILE=".claude/settings.local.json"

# Notification types configuration
NOTIFY_TYPES_FILE="$HOME/.claude/notifications/notify-types"
DEFAULT_NOTIFY_TYPE="idle_prompt"
NOTIFICATION_ALERT_TYPES="idle_prompt|permission_prompt|auth_success|elicitation_dialog"
CLAUDE_EVENT_ALERT_TYPES="SubagentStart|SubagentStop|TeammateIdle|TaskCreated|TaskCompleted"

# Available notification types:
# - idle_prompt: AI is waiting for user input (after 60+ seconds idle)
# - permission_prompt: AI needs permission to use a tool
# - auth_success: Authentication success notifications
# - elicitation_dialog: MCP tool input needed
# - ask_user: AI is asking a question via AskUserQuestion (immediate PreToolUse notification)
# - SubagentStart/SubagentStop: Claude Code subagent lifecycle events
# - TeammateIdle: Claude Code teammate waiting for input
# - TaskCreated/TaskCompleted: Claude Code agent-team task lifecycle events

# Codex paths
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$CODEX_HOME/config.toml"
CODEX_HOOKS_FILE="$CODEX_HOME/hooks.json"

# Gemini CLI paths
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
GEMINI_SETTINGS_FILE="$GEMINI_HOME/settings.json"

# Antigravity CLI (agy) paths.
# agy loads hooks from imported plugins, not from a settings.json hooks key, so
# code-notify ships a small plugin and registers it with `agy plugin install`.
# The plugin's hook commands point back at wrapper scripts in a stable staging
# dir that code-notify owns (agy copies the plugin into its own managed dirs on
# install, but the command paths keep referencing the staging wrappers).
ANTIGRAVITY_PLUGIN_NAME="code-notify"
ANTIGRAVITY_PLUGIN_STAGING="${ANTIGRAVITY_PLUGIN_STAGING:-$HOME/.claude/notifications/agy-plugin}"
ANTIGRAVITY_HOOKS_FILE="$ANTIGRAVITY_PLUGIN_STAGING/hooks.json"
# Where `agy plugin install` records imported plugins.
ANTIGRAVITY_IMPORT_MANIFEST="${ANTIGRAVITY_IMPORT_MANIFEST:-$HOME/.gemini/config/import_manifest.json}"
# agy copies each imported plugin into <manifest dir>/plugins/<name>/ and runs it
# from there, so that managed copy — NOT our staging dir — is the ground truth
# for what agy actually executes:
#   * a failed `agy plugin install` leaves the previous managed copy untouched
#     (so it still reflects the live config after a failed update), and
#   * `agy plugin disable` renames its plugin.json to plugin.json.disabled while
#     KEEPING the manifest entry (so manifest presence != enabled).
# Enablement and `cn status` read this dir rather than tracking a separate
# snapshot. Overridable for tests / non-default layouts.
ANTIGRAVITY_PLUGINS_DIR="${ANTIGRAVITY_PLUGINS_DIR:-$(dirname "$ANTIGRAVITY_IMPORT_MANIFEST")/plugins}"
ANTIGRAVITY_IMPORTED_PLUGIN_DIR="$ANTIGRAVITY_PLUGINS_DIR/$ANTIGRAVITY_PLUGIN_NAME"
ANTIGRAVITY_IMPORTED_HOOKS_FILE="$ANTIGRAVITY_IMPORTED_PLUGIN_DIR/hooks.json"

# Ensure config directory exists
ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
}

# --- JSON Helper Functions ---

# Check if jq is available
has_jq() {
    command -v jq &> /dev/null
}

# Check if python3 is available
has_python3() {
    command -v python3 &> /dev/null
}

# Shell quote helper - safely escape strings for shell commands
# Usage: shell_quote "string with spaces; and special chars"
# Returns: properly quoted string safe for shell execution
shell_quote() {
    local str="$1"
    printf '%q' "$str"
}

# Atomic file write helper - prevents data loss on crash
atomic_write() {
    local target="$1"
    local content="$2"
    local dir_path
    local tmp_file

    dir_path=$(dirname "$target")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    if printf '%s\n' "$content" > "$tmp_file"; then
        mv "$tmp_file" "$target"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# Escape a string for use inside a TOML basic string.
toml_escape_string() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    printf '%s' "$str"
}

# Check whether a key exists at TOML top-level (before the first table header).
toml_has_top_level_key() {
    local file="$1"
    local key="$2"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    awk -v key="$key" '
        $0 ~ /^[[:space:]]*\[/ {
            exit(found ? 0 : 1)
        }
        $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            found = 1
        }
        END {
            exit(found ? 0 : 1)
        }
    ' "$file"
}

# Insert Code-Notify's top-level notify key before the first TOML table.
upsert_codex_notify_config() {
    local file="$1"
    local notify_line="$2"
    local dir_path
    local tmp_file

    dir_path=$(dirname "$file")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    awk -v comment_line="# Code-Notify: Desktop notifications" -v notify_line="$notify_line" '
        /^[[:space:]]*# Code-Notify: Desktop notifications[[:space:]]*$/ {
            next
        }
        /^[[:space:]]*notify[[:space:]]*=/ {
            next
        }
        !inserted && $0 ~ /^[[:space:]]*\[/ {
            while (prefix_count > 0 && prefix[prefix_count] ~ /^[[:space:]]*$/) {
                prefix_count--
            }
            for (i = 1; i <= prefix_count; i++) {
                print prefix[i]
            }
            if (prefix_count > 0) {
                print ""
            }
            print comment_line
            print notify_line
            print ""
            print
            inserted = 1
            next
        }
        !inserted {
            prefix[++prefix_count] = $0
            next
        }
        {
            print
        }
        END {
            if (!inserted) {
                while (prefix_count > 0 && prefix[prefix_count] ~ /^[[:space:]]*$/) {
                    prefix_count--
                }
                for (i = 1; i <= prefix_count; i++) {
                    print prefix[i]
                }
                if (prefix_count > 0) {
                    print ""
                }
                print comment_line
                print notify_line
            }
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$file"
}

# Safe jq update helper - applies jq filter and only writes on success
# Usage: safe_jq_update <file> <jq_filter> [--arg name value]...
# Returns 0 on success, 1 on failure (original file unchanged)
safe_jq_update() {
    local file="$1"
    local jq_filter="$2"
    shift 2

    # Read existing content
    local content="{}"
    if [[ -f "$file" ]]; then
        content=$(cat "$file")
    fi

    # Apply jq filter
    local new_content
    if ! new_content=$(echo "$content" | jq "$@" "$jq_filter" 2>/dev/null); then
        echo "Error: Failed to parse or update configuration JSON" >&2
        echo "File unchanged: $file" >&2
        return 1
    fi

    # Validate result is not empty
    if [[ -z "$new_content" ]]; then
        echo "Error: jq produced empty output, file unchanged" >&2
        return 1
    fi

    # Atomic write
    atomic_write "$file" "$new_content"
}

# Validate JSON file format
validate_json() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    if has_jq; then
        jq empty "$file" 2>/dev/null
    else
        # Basic validation: check for balanced braces
        grep -q '{' "$file" && grep -q '}' "$file"
    fi
}

# Check if JSON path exists (returns 0 if exists)
json_has() {
    local file="$1"
    local jq_path="$2"
    local grep_pattern="$3"

    if [[ ! -f "$file" ]]; then
        return 1
    fi
    if has_jq; then
        jq -e "$jq_path" "$file" &>/dev/null
    else
        grep -qE "$grep_pattern" "$file" 2>/dev/null
    fi
}

get_global_claude_notify_command() {
    printf '%s notification claude\n' "$(get_notify_script)"
}

get_global_claude_stop_command() {
    printf '%s stop claude\n' "$(get_notify_script)"
}

get_project_claude_notify_command() {
    local project_name="$1"
    printf '%s notification claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_project_claude_stop_command() {
    local project_name="$1"
    printf '%s stop claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

# StopFailure fires when a turn ends on an API error (usage limit reached,
# server error, ...) — Claude Code sends no Stop event then, so without this
# hook the tmux running indicator keeps spinning after "stop and wait for the
# limit to reset".
get_global_claude_stop_failure_command() {
    printf '%s StopFailure claude\n' "$(get_notify_script)"
}

get_project_claude_stop_failure_command() {
    local project_name="$1"
    printf '%s StopFailure claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_global_claude_pre_tool_use_command() {
    printf '%s PreToolUse claude\n' "$(get_notify_script)"
}

get_project_claude_pre_tool_use_command() {
    local project_name="$1"
    printf '%s PreToolUse claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_global_claude_user_prompt_command() {
    printf '%s UserPromptSubmit claude\n' "$(get_notify_script)"
}

get_project_claude_user_prompt_command() {
    local project_name="$1"
    printf '%s UserPromptSubmit claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_global_claude_post_tool_command() {
    printf '%s PostToolUse claude\n' "$(get_notify_script)"
}

get_project_claude_post_tool_command() {
    local project_name="$1"
    printf '%s PostToolUse claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

# PreToolUse is a fallback resume signal for input tools that do not emit a
# PostToolUse event themselves. It is deliberately distinct from the existing
# AskUserQuestion notifier command: the notifier only resumes when a prior
# input/approval pause marker exists, so normal tool calls remain silent.
get_global_claude_resume_after_input_command() {
    printf '%s ResumeAfterInput claude\n' "$(get_notify_script)"
}

get_project_claude_resume_after_input_command() {
    local project_name="$1"
    printf '%s ResumeAfterInput claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_global_codex_stop_command() {
    printf '%s stop codex\n' "$(get_notify_script)"
}

get_global_codex_permission_command() {
    printf '%s notification codex\n' "$(get_notify_script)"
}

# Codex supports the UserPromptSubmit lifecycle hook (hooks.json, same event
# schema as Claude's), so hooks-based Codex gets the same engage-clear badge
# behavior: the badge clears when the user hands the window work, not when
# they merely glance at it. The notifier gates engage-clear on this hook being
# present in hooks.json, so stale installs keep glance-clearing.
get_global_codex_prompt_command() {
    printf '%s UserPromptSubmit codex\n' "$(get_notify_script)"
}

get_global_codex_post_tool_command() {
    printf '%s PostToolUse codex\n' "$(get_notify_script)"
}

get_global_codex_resume_after_input_command() {
    printf '%s ResumeAfterInput codex\n' "$(get_notify_script)"
}

get_managed_claude_event_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(SubagentStart|SubagentStop|TeammateIdle|TaskCreated|TaskCompleted)(?:\s|$)'
}

get_managed_claude_pre_tool_use_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*PreToolUse(?:\s|$)'
}

get_managed_claude_user_prompt_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*UserPromptSubmit(?:\s|$)'
}

get_managed_claude_post_tool_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*PostToolUse(?:\s|$)'
}

get_managed_claude_resume_after_input_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*ResumeAfterInput(?:\s|$)'
}

get_managed_claude_notification_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(notification|PreToolUse)(?:\s|$)'
}

get_managed_claude_permission_request_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*notification\s+claude(?:\s|$)'
}

get_managed_claude_stop_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*stop(?:\s|$)'
}

get_managed_claude_stop_failure_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*StopFailure(?:\s|$)'
}

get_managed_codex_hook_pattern() {
    printf '%s\n' '(code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(stop|notification|UserPromptSubmit|PostToolUse|ResumeAfterInput)\s+codex(?:\s|$)'
}

has_claude_hooks_for_commands() {
    local file="$1"
    local matcher notify_cmd stop_cmd event_prefix event_suffix event_types
    matcher="$2"
    notify_cmd="$3"
    stop_cmd="$4"
    event_prefix="${5:-}"
    event_suffix="${6:-}"
    event_types="$(get_claude_event_hook_types)"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    if has_jq; then
        jq -e \
            --arg matcher "$matcher" \
            --arg notify "$notify_cmd" \
            --arg stop "$stop_cmd" \
            --arg event_prefix "$event_prefix" \
            --arg event_suffix "$event_suffix" \
            --arg event_types "$event_types" \
            '
            def has_command($entries; $matcher; $command):
                ($entries | type == "array") and
                any($entries[]?;
                    (.matcher // "") == $matcher and
                    any(.hooks[]?;
                        (.type // "") == "command" and
                        (.command // "") == $command
                    )
                );
            def all_events_present:
                ($event_types | split("|") | map(select(. != ""))) as $events |
                . as $root |
                all($events[]; . as $event |
                    ($root | has_command(.hooks[$event]; ""; ($event_prefix + $event + $event_suffix)))
                );
            (
                if $matcher == "" then
                    true
                else
                    has_command(.hooks.Notification; $matcher; $notify)
                end
            ) and
            (.hooks.Stop | type == "array") and
            has_command(.hooks.Stop; ""; $stop) and
            all_events_present
            ' "$file" >/dev/null 2>&1
        return $?
    fi

    if has_python3; then
        python3 - "$file" "$matcher" "$notify_cmd" "$stop_cmd" "$event_prefix" "$event_suffix" "$event_types" << 'PYTHON'
import json
import sys

file_path, matcher, notify_cmd, stop_cmd, event_prefix, event_suffix, event_types = sys.argv[1:8]

with open(file_path, "r") as fh:
    settings = json.load(fh)

hooks = settings.get("hooks", {})
notification = hooks.get("Notification", [])
stop = hooks.get("Stop", [])

def has_matching_command(entries, entry_matcher, command):
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if entry.get("matcher", "") != entry_matcher:
            continue
        for hook in entry.get("hooks", []):
            if (
                isinstance(hook, dict)
                and hook.get("type") == "command"
                and hook.get("command") == command
            ):
                return True
    return False

if matcher and not has_matching_command(notification, matcher, notify_cmd):
    raise SystemExit(1)

if not has_matching_command(stop, "", stop_cmd):
    raise SystemExit(1)

for event in [item for item in event_types.split("|") if item]:
    if not has_matching_command(hooks.get(event, []), "", f"{event_prefix}{event}{event_suffix}"):
        raise SystemExit(1)
PYTHON
        return $?
    fi

    if [[ -n "$matcher" ]]; then
        grep -qF "\"matcher\": \"$matcher\"" "$file" || return 1
        grep -qF "\"command\": \"$notify_cmd\"" "$file" || return 1
    fi

    grep -qF "\"command\": \"$stop_cmd\"" "$file" || return 1

    local event
    local -a _code_notify_events=()
    IFS='|' read -r -a _code_notify_events <<< "$event_types"
    for event in "${_code_notify_events[@]}"; do
        [[ -n "$event" ]] || continue
        grep -qF "\"command\": \"${event_prefix}${event}${event_suffix}\"" "$file" || return 1
    done

    return 0
}

# A current Claude install also needs the lifecycle hooks that swap a paused
# input request back to the running indicator. Keeping this in enablement
# detection makes `cn on claude` repair pre-existing installations instead of
# reporting them as already enabled and leaving the new hooks absent.
has_empty_matcher_lifecycle_command() {
    local file="$1" event="$2" command="$3"
    [[ -f "$file" ]] || return 1

    if has_jq; then
        jq -e --arg event "$event" --arg command "$command" '
            any((.hooks[$event] // [])[]?;
                (.matcher // "") == "" and
                any(.hooks[]?; (.type // "") == "command" and (.command // "") == $command)
            )
        ' "$file" >/dev/null 2>&1
        return $?
    fi

    if has_python3; then
        python3 - "$file" "$event" "$command" << 'PYTHON' 2>/dev/null
import json
import sys

file_path, event, command = sys.argv[1:4]
try:
    with open(file_path, "r", encoding="utf-8") as fh:
        hooks = json.load(fh).get("hooks", {})
except Exception:
    raise SystemExit(1)

for entry in hooks.get(event, []):
    if not isinstance(entry, dict) or entry.get("matcher", "") != "":
        continue
    for hook in entry.get("hooks", []):
        if isinstance(hook, dict) and hook.get("type") == "command" and hook.get("command") == command:
            raise SystemExit(0)
raise SystemExit(1)
PYTHON
        return $?
    fi

    grep -qF "\"command\": \"$command\"" "$file"
}

has_current_global_claude_hooks() {
    local file="$1"
    has_claude_hooks_for_commands \
        "$file" \
        "$(get_notify_matcher)" \
        "$(get_global_claude_notify_command)" \
        "$(get_global_claude_stop_command)" \
        "$(get_notify_script) " \
        " claude" || return 1
    has_empty_matcher_lifecycle_command "$file" "UserPromptSubmit" "$(get_global_claude_user_prompt_command)" || return 1
    has_empty_matcher_lifecycle_command "$file" "PostToolUse" "$(get_global_claude_post_tool_command)" || return 1
    has_empty_matcher_lifecycle_command "$file" "PreToolUse" "$(get_global_claude_resume_after_input_command)" || return 1
    has_empty_matcher_lifecycle_command "$file" "StopFailure" "$(get_global_claude_stop_failure_command)" || return 1
    has_expected_claude_permission_request_hook "$file" "$(get_global_claude_notify_command)"
}

has_current_project_claude_hooks() {
    local file="$1"
    local project_name="${2:-$(get_project_name)}"

    has_claude_hooks_for_commands \
        "$file" \
        "$(get_notify_matcher)" \
        "$(get_project_claude_notify_command "$project_name")" \
        "$(get_project_claude_stop_command "$project_name")" \
        "$(shell_quote "$(get_notify_script)") " \
        " claude $(shell_quote "$project_name")" || return 1
    has_empty_matcher_lifecycle_command "$file" "UserPromptSubmit" "$(get_project_claude_user_prompt_command "$project_name")" || return 1
    has_empty_matcher_lifecycle_command "$file" "PostToolUse" "$(get_project_claude_post_tool_command "$project_name")" || return 1
    has_empty_matcher_lifecycle_command "$file" "PreToolUse" "$(get_project_claude_resume_after_input_command "$project_name")" || return 1
    has_empty_matcher_lifecycle_command "$file" "StopFailure" "$(get_project_claude_stop_failure_command "$project_name")" || return 1
    has_expected_claude_permission_request_hook "$file" "$(get_project_claude_notify_command "$project_name")"
}

has_legacy_global_claude_hooks() {
    local file="${1:-$GLOBAL_SETTINGS_FILE}"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    # Every pattern must pin the END of the command (a closing JSON quote), or
    # it also matches the current tool-scoped shape. `notifier.sh PreToolUse`
    # unanchored matched today's `notifier.sh PreToolUse claude` ask_user hook,
    # so any install with ask_user enabled reported REPAIR NEEDED forever and
    # `cn on claude` rewrote settings.json on every run.
    grep -q 'claude-notify' "$file" ||
        grep -qE 'notifier\.sh (notification|stop)"' "$file" ||
        grep -qE 'notifier\.sh PreToolUse"' "$file" ||
        grep -qE 'notify\.ps1.* (notification|stop)"' "$file" ||
        grep -qE 'notify\.ps1.* PreToolUse' "$file"
}

claude_global_hooks_need_repair() {
    has_legacy_global_claude_hooks "$GLOBAL_SETTINGS_FILE"
}

# Whether a settings file contains ANY code-notify-managed Claude hook
# command, in the current shape or not. Enable and repair key on the strict
# has_current_* predicates; teardown must key on this loose one, or an
# upgraded install whose settings predate a newly mandatory hook type reads
# as "already disabled" and its managed hooks are never removed.
has_any_managed_claude_hooks() {
    local file="$1"
    local pattern

    [[ -f "$file" ]] || return 1

    pattern="$(get_managed_claude_notification_pattern)|$(get_managed_claude_stop_pattern)|$(get_managed_claude_event_pattern)|$(get_managed_claude_stop_failure_pattern)"

    if has_jq; then
        jq -e --arg pattern "$pattern" '
            [.hooks // {} | .. | objects | select((.type? // "") == "command") | (.command? // "")]
            | any(test($pattern))
        ' "$file" >/dev/null 2>&1
        return $?
    fi

    if has_python3; then
        python3 - "$file" "$pattern" << 'PYTHON'
import json
import re
import sys

file_path, pattern = sys.argv[1:3]

with open(file_path, "r") as fh:
    settings = json.load(fh)

regex = re.compile(pattern)

def walk(node):
    if isinstance(node, dict):
        command = node.get("command")
        if node.get("type") == "command" and isinstance(command, str) and regex.search(command):
            return True
        return any(walk(value) for value in node.values())
    if isinstance(node, list):
        return any(walk(item) for item in node)
    return False

raise SystemExit(0 if walk(settings.get("hooks", {})) else 1)
PYTHON
        return $?
    fi

    grep -qE 'claude-notify|code-notify.*notifier\.sh|(^|[\\/])notify\.(ps1|sh)' "$file"
}

repair_legacy_hooks_command() {
    local quiet="${1:-}"
    local repaired=0

    if claude_global_hooks_need_repair; then
        if ! enable_hooks_in_settings; then
            if [[ "$quiet" != "--quiet" ]]; then
                echo "Failed to repair legacy Claude hooks" >&2
            fi
            return 1
        fi
        repaired=1

        if [[ "$quiet" != "--quiet" ]]; then
            echo "Repaired legacy Claude hooks in $GLOBAL_SETTINGS_FILE"
        fi
    fi

    if [[ $repaired -eq 0 ]] && [[ "$quiet" != "--quiet" ]]; then
        echo "No legacy hooks required repair"
    fi

    return 0
}

# Check if file has any hooks
has_any_hooks() {
    local file="$1"
    json_has "$file" '.hooks != null' '"hooks"'
}

# Get hooks file path (project or global)
get_hooks_file() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_hooks="$project_root/.claude/hooks.json"
    
    # Check for project-specific hooks first
    if [[ -f "$project_hooks" ]]; then
        echo "$project_hooks"
        return 0
    fi
    
    # Fall back to global hooks
    echo "$GLOBAL_HOOKS_FILE"
}

# Check if notifications are enabled
is_enabled() {
    local hooks_file=$(get_hooks_file)
    [[ -f "$hooks_file" ]]
}

# Check if notifications are enabled globally
is_enabled_globally() {
    # Check new settings.json format first
    if has_current_global_claude_hooks "$GLOBAL_SETTINGS_FILE"; then
        return 0
    fi
    # Fall back to legacy hooks.json
    [[ -f "$GLOBAL_HOOKS_FILE" ]]
}

# Check if notifications are enabled for current project
is_enabled_project() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/.claude/settings.json"
    local project_hooks="$project_root/.claude/hooks.json"
    
    # Check new format first
    if is_enabled_project_settings; then
        return 0
    fi
    # Fall back to legacy format
    [[ -f "$project_hooks" ]]
}

# Create default hooks configuration
create_default_hooks() {
    local target_file="${1:-$GLOBAL_HOOKS_FILE}"
    local project_name="${2:-}"
    
    cat > "$target_file" << EOF
{
  "hooks": {
    "stop": {
      "description": "Notify when Claude completes a task",
      "command": "~/.claude/notifications/notify.sh stop completed '${project_name}'"
    },
    "notification": {
      "description": "Notify when Claude needs input",
      "command": "~/.claude/notifications/notify.sh notification required '${project_name}'"
    }
  }
}
EOF
}

# Backup existing configuration
backup_config() {
    local file="$1"
    if [[ -f "$file" ]]; then
        # Ensure backup directory exists
        if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
            echo "Warning: Failed to create backup directory: $BACKUP_DIR" >&2
            return 1
        fi

        local backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S)"
        if cp "$file" "$BACKUP_DIR/$backup_name" 2>/dev/null; then
            return 0
        else
            echo "Warning: Failed to create backup of $file" >&2
            return 1
        fi
    fi
    return 1
}

# Get notification script path
get_notify_script() {
    # First check if installed via Homebrew
    if [[ -f "/usr/local/opt/code-notify/lib/code-notify/core/notifier.sh" ]]; then
        echo "/usr/local/opt/code-notify/lib/code-notify/core/notifier.sh"
    # Then check home directory
    elif [[ -f "$HOME/.claude/notifications/notify.sh" ]]; then
        echo "$HOME/.claude/notifications/notify.sh"
    # Finally check relative to this script
    else
        echo "$(dirname "${BASH_SOURCE[0]}")/notifier.sh"
    fi
}

# Validate hooks file format
validate_hooks_file() {
    local file="$1"
    validate_json "$file" && has_any_hooks "$file"
}

# Get current configuration status
get_status_info() {
    local status_info=""
    
    # Global status
    if is_enabled_globally; then
        status_info="${status_info}${BELL} Global notifications: ${GREEN}ENABLED${RESET}\n"
        # Check which config file is being used
        if has_any_hooks "$GLOBAL_SETTINGS_FILE"; then
            status_info="${status_info}   Config: $GLOBAL_SETTINGS_FILE (new format)\n"
        else
            status_info="${status_info}   Config: $GLOBAL_HOOKS_FILE (legacy)\n"
        fi
    else
        status_info="${status_info}${MUTE} Global notifications: ${DIM}DISABLED${RESET}\n"
    fi
    
    # Project status
    local project_name=$(get_project_name)
    local project_root=$(get_project_root)
    status_info="${status_info}\n${FOLDER} Project: $project_name\n"
    status_info="${status_info}   Location: $project_root\n"
    
    if is_enabled_project; then
        status_info="${status_info}${BELL} Project notifications: ${GREEN}ENABLED${RESET}\n"
        # Check which format is being used
        if is_enabled_project_settings; then
            status_info="${status_info}   Config: $project_root/.claude/settings.json (new format)\n"
        else
            status_info="${status_info}   Config: $project_root/.claude/hooks.json (legacy)\n"
        fi
    else
        status_info="${status_info}${MUTE} Project notifications: ${DIM}DISABLED${RESET}\n"
    fi
    
    # Terminal notifier status
    if detect_terminal_notifier &> /dev/null; then
        status_info="${status_info}\n${CHECK_MARK} terminal-notifier: ${GREEN}INSTALLED${RESET}\n"
    else
        status_info="${status_info}\n${WARNING} terminal-notifier: ${YELLOW}NOT INSTALLED${RESET}\n"
        status_info="${status_info}   Install with: ${CYAN}brew install terminal-notifier${RESET}\n"
    fi
    
    echo -e "$status_info"
}

# Enable hooks in settings.json (new format)
update_claude_hooks_in_settings_file() {
    local file="$1"
    local matcher="$2"
    local notify_cmd="$3"
    local stop_cmd="$4"
    local mode="$5"
    local event_cmd_prefix="${6:-}"
    local event_cmd_suffix="${7:-}"
    local notify_pattern stop_pattern event_pattern event_types

    notify_pattern="$(get_managed_claude_notification_pattern)"
    stop_pattern="$(get_managed_claude_stop_pattern)"
    event_pattern="$(get_managed_claude_event_pattern)"
    event_types="$(get_claude_event_hook_types)"

    mkdir -p "$(dirname "$file")"

    if has_jq; then
        local settings new_settings jq_filter
        settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        jq_filter='
            def array_or_empty:
                if type == "array" then . else [] end;
            def strip_managed($exact; $pattern):
                array_or_empty
                | map(
                    if (.hooks | type) == "array" then
                        .hooks = (
                            (.hooks | array_or_empty)
                            | map(
                                select(
                                    ((.type // "") != "command") or
                                    (
                                        ((.command // "") != $exact) and
                                        (((.command // "") | test($pattern)) | not)
                                    )
                                )
                            )
                        )
                    else
                        .
                    end
                )
                | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)));
            def remove_empty_hook($name):
                if (.hooks[$name] | type) == "array" and (.hooks[$name] | length) == 0 then del(.hooks[$name]) else . end;
            ($event_types | split("|") | map(select(. != ""))) as $enabled_events |
            ($all_event_types | split("|") | map(select(. != ""))) as $all_events |
            .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
            .hooks.Notification = (.hooks.Notification | strip_managed($notify; $notify_pattern)) |
            .hooks.Stop = (.hooks.Stop | strip_managed($stop; $stop_pattern)) |
            reduce $all_events[] as $event (.;
                .hooks[$event] = (.hooks[$event] | strip_managed(($event_prefix + $event + $event_suffix); $event_pattern)) |
                remove_empty_hook($event)
            ) |
            if $mode == "enable" then
                (
                    if $matcher != "" then
                        .hooks.Notification = (
                            (.hooks.Notification | array_or_empty) + [{
                                "matcher": $matcher,
                                "hooks": [{
                                    "type": "command",
                                    "command": $notify
                                }]
                            }]
                        )
                    else
                        .
                    end
                ) |
                .hooks.Stop = (
                    (.hooks.Stop | array_or_empty) + [{
                        "matcher": "",
                        "hooks": [{
                            "type": "command",
                            "command": $stop
                        }]
                    }]
                ) |
                reduce $enabled_events[] as $event (.;
                    .hooks[$event] = (
                        (.hooks[$event] | array_or_empty) + [{
                            "matcher": "",
                            "hooks": [{
                                "type": "command",
                                "command": ($event_prefix + $event + $event_suffix)
                            }]
                        }]
                    )
                )
            else
                .
            end |
            remove_empty_hook("Notification") |
            remove_empty_hook("Stop") |
            if (.hooks | length) == 0 then del(.hooks) else . end'

        if ! new_settings=$(printf '%s\n' "$settings" | jq \
            --arg matcher "$matcher" \
            --arg notify "$notify_cmd" \
            --arg stop "$stop_cmd" \
            --arg mode "$mode" \
            --arg notify_pattern "$notify_pattern" \
            --arg stop_pattern "$stop_pattern" \
            --arg event_pattern "$event_pattern" \
            --arg event_prefix "$event_cmd_prefix" \
            --arg event_suffix "$event_cmd_suffix" \
            --arg event_types "$event_types" \
            --arg all_event_types "$CLAUDE_EVENT_ALERT_TYPES" \
            "$jq_filter" 2>/dev/null); then
            echo "Error: Failed to parse or update configuration JSON" >&2
            echo "File unchanged: $file" >&2
            return 1
        fi

        if [[ -z "$new_settings" ]]; then
            echo "Error: jq produced empty output, file unchanged" >&2
            return 1
        fi

        if [[ "$mode" == "disable" && "$new_settings" == "{}" ]]; then
            rm -f "$file"
            return 0
        fi

        atomic_write "$file" "$new_settings"
        return $?
    elif has_python3; then
        local settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        local tmp_json
        tmp_json=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }
        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$file" "$mode" "$matcher" "$notify_cmd" "$stop_cmd" "$notify_pattern" "$stop_pattern" "$event_pattern" "$event_cmd_prefix" "$event_cmd_suffix" "$event_types" "$CLAUDE_EVENT_ALERT_TYPES" "$tmp_json" << 'PYTHON'
import json
import os
import re
import sys
import tempfile

(
    file_path,
    mode,
    matcher,
    notify_cmd,
    stop_cmd,
    notify_pattern,
    stop_pattern,
    event_pattern,
    event_cmd_prefix,
    event_cmd_suffix,
    event_types,
    all_event_types,
    json_file,
) = sys.argv[1:14]

try:
    with open(json_file, "r") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

notify_regex = re.compile(notify_pattern)
stop_regex = re.compile(stop_pattern)
event_regex = re.compile(event_pattern)

def is_managed_hook(hook, exact_cmd, regex):
    if not isinstance(hook, dict):
        return False
    if hook.get("type") != "command":
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    if command == exact_cmd:
        return True
    return bool(regex.search(command))

def strip_managed(entries, exact_cmd, regex):
    cleaned = []
    if not isinstance(entries, list):
        return cleaned

    for entry in entries:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue

        new_entry = dict(entry)
        hooks = entry.get("hooks")
        if isinstance(hooks, list):
            filtered_hooks = [
                hook for hook in hooks
                if not is_managed_hook(hook, exact_cmd, regex)
            ]
            if not filtered_hooks:
                continue
            new_entry["hooks"] = filtered_hooks

        cleaned.append(new_entry)

    return cleaned

hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
else:
    hooks = dict(hooks)

notification_entries = strip_managed(hooks.get("Notification", []), notify_cmd, notify_regex)
stop_entries = strip_managed(hooks.get("Stop", []), stop_cmd, stop_regex)
enabled_events = [event for event in event_types.split("|") if event]
all_events = [event for event in all_event_types.split("|") if event]

for event in all_events:
    event_entries = strip_managed(
        hooks.get(event, []),
        f"{event_cmd_prefix}{event}{event_cmd_suffix}",
        event_regex,
    )
    if event_entries:
        hooks[event] = event_entries
    else:
        hooks.pop(event, None)

if mode == "enable":
    if matcher:
        notification_entries.append({
            "matcher": matcher,
            "hooks": [{"type": "command", "command": notify_cmd}],
        })
    stop_entries.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": stop_cmd}],
    })
    for event in enabled_events:
        hooks[event] = list(hooks.get(event, [])) + [{
            "matcher": "",
            "hooks": [{"type": "command", "command": f"{event_cmd_prefix}{event}{event_cmd_suffix}"}],
        }]

if notification_entries:
    hooks["Notification"] = notification_entries
else:
    hooks.pop("Notification", None)

if stop_entries:
    hooks["Stop"] = stop_entries
else:
    hooks.pop("Stop", None)

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

if not settings:
    try:
        os.remove(file_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    else
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# ============================================
# PreToolUse Hook for AskUserQuestion
# ============================================

# Register PreToolUse hook for AskUserQuestion when ask_user alert type is enabled
register_ask_user_hook() {
    local file="$1"
    local pre_tool_cmd="$2"
    local pre_tool_pattern
    pre_tool_pattern="$(get_managed_claude_pre_tool_use_pattern)"

    if ! is_notify_type_enabled "ask_user"; then
        return 0
    fi

    if has_jq; then
        local settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        local new_settings
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg cmd "$pre_tool_cmd" \
            --arg pattern "$pre_tool_pattern" \
            '
            def array_or_empty:
                if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (
                    ((.command // "") == $exact) or
                    (((.command // "") | test($pattern)) // false)
                );
            def strip_managed_ask_user($exact; $pattern):
                array_or_empty
                | map(
                    if (.matcher // "") == "AskUserQuestion" and ((.hooks | type) == "array") then
                        .hooks = (
                            (.hooks | array_or_empty)
                            | map(select((is_managed_hook($exact; $pattern)) | not))
                        )
                    else
                        .
                    end
                )
                | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)));
            .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
            .hooks.PreToolUse = (
                (.hooks.PreToolUse | strip_managed_ask_user($cmd; $pattern)) + [{
                    "matcher": "AskUserQuestion",
                    "hooks": [{
                        "type": "command",
                        "command": $cmd
                    }]
                }]
            )
        ' 2>/dev/null)

        if [[ -n "$new_settings" ]]; then
            atomic_write "$file" "$new_settings"
        fi
    elif has_python3; then
        local settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        local tmp_json
        tmp_json=$(mktemp) || return 1
        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$file" "$pre_tool_cmd" "$pre_tool_pattern" "$tmp_json" << 'PYTHON'
import json, os, sys, tempfile
import re

file_path, pre_tool_cmd, pre_tool_pattern, json_file = sys.argv[1:5]

try:
    with open(json_file, "r") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
else:
    hooks = dict(hooks)

pre_tool_regex = re.compile(pre_tool_pattern)

def is_managed_hook(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    return command == pre_tool_cmd or bool(pre_tool_regex.search(command))

pre_tool_entries = []
for entry in hooks.get("PreToolUse", []):
    if not isinstance(entry, dict):
        pre_tool_entries.append(entry)
        continue
    if entry.get("matcher", "") != "AskUserQuestion":
        pre_tool_entries.append(entry)
        continue
    filtered_hooks = [hook for hook in entry.get("hooks", []) if not is_managed_hook(hook)]
    if filtered_hooks:
        new_entry = dict(entry)
        new_entry["hooks"] = filtered_hooks
        pre_tool_entries.append(new_entry)

pre_tool_entries.append({
    "matcher": "AskUserQuestion",
    "hooks": [{"type": "command", "command": pre_tool_cmd}]
})
hooks["PreToolUse"] = pre_tool_entries
settings["hooks"] = hooks

dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    else
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Unregister PreToolUse hook for AskUserQuestion
unregister_ask_user_hook() {
    local file="$1"
    local pre_tool_cmd="${2:-}"
    local pre_tool_pattern
    pre_tool_pattern="$(get_managed_claude_pre_tool_use_pattern)"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    if has_jq; then
        local settings
        settings=$(cat "$file")

        local new_settings
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg cmd "$pre_tool_cmd" \
            --arg pattern "$pre_tool_pattern" \
            '
            def array_or_empty:
                if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (
                    ((($exact != "") and ((.command // "") == $exact))) or
                    (((.command // "") | test($pattern)) // false)
                );
            if (.hooks // {}).PreToolUse then
                .hooks.PreToolUse = (
                    (.hooks.PreToolUse | array_or_empty)
                    | map(
                        if (.matcher // "") == "AskUserQuestion" and ((.hooks | type) == "array") then
                            .hooks = (
                                (.hooks | array_or_empty)
                                | map(select((is_managed_hook($cmd; $pattern)) | not))
                            )
                        else
                            .
                        end
                    )
                    | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)))
                ) |
                if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
                if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' 2>/dev/null)

        if [[ -n "$new_settings" ]]; then
            atomic_write "$file" "$new_settings"
        fi
    elif has_python3; then
        local tmp_json
        tmp_json=$(mktemp) || return 1
        cat "$file" > "$tmp_json"

        python3 - "$file" "$pre_tool_cmd" "$pre_tool_pattern" "$tmp_json" << 'PYTHON'
import json, os, sys, tempfile
import re

file_path, pre_tool_cmd, pre_tool_pattern, json_file = sys.argv[1:5]

try:
    with open(json_file, "r") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

hooks = settings.get("hooks", {})
pre_tool = hooks.get("PreToolUse", [])
pre_tool_regex = re.compile(pre_tool_pattern)

def is_managed_hook(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    return (pre_tool_cmd and command == pre_tool_cmd) or bool(pre_tool_regex.search(command))

filtered_entries = []
for entry in pre_tool:
    if not isinstance(entry, dict):
        filtered_entries.append(entry)
        continue
    if entry.get("matcher", "") != "AskUserQuestion":
        filtered_entries.append(entry)
        continue
    filtered_hooks = [hook for hook in entry.get("hooks", []) if not is_managed_hook(hook)]
    if filtered_hooks:
        new_entry = dict(entry)
        new_entry["hooks"] = filtered_hooks
        filtered_entries.append(new_entry)

hooks["PreToolUse"] = filtered_entries
if "PreToolUse" in hooks and not hooks["PreToolUse"]:
    del hooks["PreToolUse"]
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

if not settings:
    try:
        os.remove(file_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    else
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# ============================================
# UserPromptSubmit Hook for badge clearing
# ============================================

# Register the UserPromptSubmit hook that clears the current tmux window's badge
# when the user submits a prompt (Claude's "engage-clear" signal). Unlike
# ask_user this is not tied to an alert type — it is added whenever Claude hooks
# are enabled and is a no-op at runtime when not inside tmux.
register_badge_clear_hook() {
    local file="$1"
    local prompt_cmd="$2"
    local prompt_pattern
    prompt_pattern="$(get_managed_claude_user_prompt_pattern)"

    if has_jq; then
        local settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        local new_settings
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg cmd "$prompt_cmd" \
            --arg pattern "$prompt_pattern" \
            '
            def array_or_empty:
                if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (
                    ((.command // "") == $exact) or
                    (((.command // "") | test($pattern)) // false)
                );
            def strip_managed_prompt($exact; $pattern):
                array_or_empty
                | map(
                    if (.matcher // "") == "" and ((.hooks | type) == "array") then
                        .hooks = (
                            (.hooks | array_or_empty)
                            | map(select((is_managed_hook($exact; $pattern)) | not))
                        )
                    else
                        .
                    end
                )
                | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)));
            .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
            .hooks.UserPromptSubmit = (
                (.hooks.UserPromptSubmit | strip_managed_prompt($cmd; $pattern)) + [{
                    "matcher": "",
                    "hooks": [{
                        "type": "command",
                        "command": $cmd
                    }]
                }]
            )
        ' 2>/dev/null)

        if [[ -n "$new_settings" ]]; then
            atomic_write "$file" "$new_settings"
        fi
    elif has_python3; then
        local settings="{}"
        if [[ -f "$file" ]]; then
            settings=$(cat "$file")
        fi

        local tmp_json
        tmp_json=$(mktemp) || return 1
        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$file" "$prompt_cmd" "$prompt_pattern" "$tmp_json" << 'PYTHON'
import json, os, sys, tempfile
import re

file_path, prompt_cmd, prompt_pattern, json_file = sys.argv[1:5]

try:
    with open(json_file, "r") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
else:
    hooks = dict(hooks)

prompt_regex = re.compile(prompt_pattern)

def is_managed_hook(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    return command == prompt_cmd or bool(prompt_regex.search(command))

prompt_entries = []
for entry in hooks.get("UserPromptSubmit", []):
    if not isinstance(entry, dict):
        prompt_entries.append(entry)
        continue
    if entry.get("matcher", "") != "":
        prompt_entries.append(entry)
        continue
    filtered_hooks = [hook for hook in entry.get("hooks", []) if not is_managed_hook(hook)]
    if filtered_hooks:
        new_entry = dict(entry)
        new_entry["hooks"] = filtered_hooks
        prompt_entries.append(new_entry)

prompt_entries.append({
    "matcher": "",
    "hooks": [{"type": "command", "command": prompt_cmd}]
})
hooks["UserPromptSubmit"] = prompt_entries
settings["hooks"] = hooks

dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    else
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Unregister the UserPromptSubmit badge-clear hook.
unregister_badge_clear_hook() {
    local file="$1"
    local prompt_cmd="${2:-}"
    local prompt_pattern
    prompt_pattern="$(get_managed_claude_user_prompt_pattern)"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    if has_jq; then
        local settings
        settings=$(cat "$file")

        local new_settings
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg cmd "$prompt_cmd" \
            --arg pattern "$prompt_pattern" \
            '
            def array_or_empty:
                if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (
                    ((($exact != "") and ((.command // "") == $exact))) or
                    (((.command // "") | test($pattern)) // false)
                );
            if (.hooks // {}).UserPromptSubmit then
                .hooks.UserPromptSubmit = (
                    (.hooks.UserPromptSubmit | array_or_empty)
                    | map(
                        if (.matcher // "") == "" and ((.hooks | type) == "array") then
                            .hooks = (
                                (.hooks | array_or_empty)
                                | map(select((is_managed_hook($cmd; $pattern)) | not))
                            )
                        else
                            .
                        end
                    )
                    | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)))
                ) |
                if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end |
                if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' 2>/dev/null)

        if [[ -n "$new_settings" ]]; then
            # This unregister runs last in disable_hooks_in_settings, so when it
            # empties the file it must remove it (the python path already does),
            # matching update_claude_hooks_in_settings_file's rm-on-empty.
            if [[ "$new_settings" == "{}" ]]; then
                rm -f "$file"
            else
                atomic_write "$file" "$new_settings"
            fi
        fi
    elif has_python3; then
        local tmp_json
        tmp_json=$(mktemp) || return 1
        cat "$file" > "$tmp_json"

        python3 - "$file" "$prompt_cmd" "$prompt_pattern" "$tmp_json" << 'PYTHON'
import json, os, sys, tempfile
import re

file_path, prompt_cmd, prompt_pattern, json_file = sys.argv[1:5]

try:
    with open(json_file, "r") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

hooks = settings.get("hooks", {})
prompt = hooks.get("UserPromptSubmit", [])
prompt_regex = re.compile(prompt_pattern)

def is_managed_hook(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    if not isinstance(command, str):
        return False
    return (prompt_cmd and command == prompt_cmd) or bool(prompt_regex.search(command))

filtered_entries = []
for entry in prompt:
    if not isinstance(entry, dict):
        filtered_entries.append(entry)
        continue
    if entry.get("matcher", "") != "":
        filtered_entries.append(entry)
        continue
    filtered_hooks = [hook for hook in entry.get("hooks", []) if not is_managed_hook(hook)]
    if filtered_hooks:
        new_entry = dict(entry)
        new_entry["hooks"] = filtered_hooks
        filtered_entries.append(new_entry)

hooks["UserPromptSubmit"] = filtered_entries
if "UserPromptSubmit" in hooks and not hooks["UserPromptSubmit"]:
    del hooks["UserPromptSubmit"]
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

if not settings:
    try:
        os.remove(file_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    else
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Register a command under a no-matcher lifecycle event while preserving every
# unrelated hook in the same settings file. This is shared by the lightweight
# resume hooks below; unlike notification hooks, these commands are silent
# unless a tmux input-pause marker is present.
register_empty_matcher_lifecycle_hook() {
    local file="$1"
    local event="$2"
    local hook_cmd="$3"
    local hook_pattern="$4"

    if has_jq; then
        local settings="{}"
        [[ -f "$file" ]] && settings=$(cat "$file")
        local new_settings
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg event "$event" \
            --arg cmd "$hook_cmd" \
            --arg pattern "$hook_pattern" \
            '
            def array_or_empty: if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (((.command // "") == $exact) or (((.command // "") | test($pattern)) // false));
            def strip_managed($exact; $pattern):
                array_or_empty
                | map(
                    if (.matcher // "") == "" and ((.hooks | type) == "array") then
                        .hooks = ((.hooks | array_or_empty)
                            | map(select((is_managed_hook($exact; $pattern)) | not)))
                    else . end
                )
                | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)));
            .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
            .hooks[$event] = ((.hooks[$event] | strip_managed($cmd; $pattern)) + [{
                "matcher": "",
                "hooks": [{"type": "command", "command": $cmd}]
            }])
        ' 2>/dev/null)
        if [[ -n "$new_settings" ]]; then
            atomic_write "$file" "$new_settings"
            return $?
        fi
        return 1
    fi

    if has_python3; then
        local settings="{}" tmp_json
        [[ -f "$file" ]] && settings=$(cat "$file")
        tmp_json=$(mktemp) || return 1
        printf '%s\n' "$settings" > "$tmp_json"
        python3 - "$file" "$event" "$hook_cmd" "$hook_pattern" "$tmp_json" << 'PYTHON'
import json
import os
import re
import sys
import tempfile

file_path, event, hook_cmd, hook_pattern, json_file = sys.argv[1:6]
try:
    with open(json_file, "r", encoding="utf-8") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

if not isinstance(settings, dict):
    settings = {}
hooks = settings.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
else:
    hooks = dict(hooks)
pattern = re.compile(hook_pattern)

def managed(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    return isinstance(command, str) and (command == hook_cmd or bool(pattern.search(command)))

entries = []
for entry in hooks.get(event, []):
    if not isinstance(entry, dict) or entry.get("matcher", "") != "":
        entries.append(entry)
        continue
    retained = [hook for hook in entry.get("hooks", []) if not managed(hook)]
    if retained:
        replacement = dict(entry)
        replacement["hooks"] = retained
        entries.append(replacement)
entries.append({"matcher": "", "hooks": [{"type": "command", "command": hook_cmd}]})
hooks[event] = entries
settings["hooks"] = hooks

dir_path = os.path.dirname(file_path)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    fi

    echo "Error: jq or python3 required for config preservation" >&2
    return 1
}

# Remove a no-matcher lifecycle command installed by the helper above without
# disturbing user hooks for the same event.
unregister_empty_matcher_lifecycle_hook() {
    local file="$1"
    local event="$2"
    local hook_cmd="$3"
    local hook_pattern="$4"
    [[ -f "$file" ]] || return 0

    if has_jq; then
        local settings new_settings
        settings=$(cat "$file")
        new_settings=$(printf '%s\n' "$settings" | jq \
            --arg event "$event" \
            --arg cmd "$hook_cmd" \
            --arg pattern "$hook_pattern" \
            '
            def array_or_empty: if type == "array" then . else [] end;
            def is_managed_hook($exact; $pattern):
                ((.type // "") == "command") and
                (((($exact != "") and ((.command // "") == $exact))) or
                    (((.command // "") | test($pattern)) // false));
            if (.hooks // {})[$event] then
                .hooks[$event] = ((.hooks[$event] | array_or_empty)
                    | map(
                        if (.matcher // "") == "" and ((.hooks | type) == "array") then
                            .hooks = ((.hooks | array_or_empty)
                                | map(select((is_managed_hook($cmd; $pattern)) | not)))
                        else . end
                    )
                    | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)))) |
                if (.hooks[$event] | length) == 0 then del(.hooks[$event]) else . end |
                if (.hooks | length) == 0 then del(.hooks) else . end
            else . end
        ' 2>/dev/null)
        if [[ -n "$new_settings" ]]; then
            if [[ "$new_settings" == "{}" ]]; then rm -f "$file"; else atomic_write "$file" "$new_settings"; fi
        fi
        return 0
    fi

    if has_python3; then
        local tmp_json
        tmp_json=$(mktemp) || return 1
        cat "$file" > "$tmp_json"
        python3 - "$file" "$event" "$hook_cmd" "$hook_pattern" "$tmp_json" << 'PYTHON'
import json
import os
import re
import sys
import tempfile

file_path, event, hook_cmd, hook_pattern, json_file = sys.argv[1:6]
try:
    with open(json_file, "r", encoding="utf-8") as fh:
        settings = json.load(fh)
finally:
    try:
        os.unlink(json_file)
    except OSError:
        pass

hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(0)
pattern = re.compile(hook_pattern)

def managed(hook):
    if not isinstance(hook, dict) or hook.get("type") != "command":
        return False
    command = hook.get("command")
    return isinstance(command, str) and ((hook_cmd and command == hook_cmd) or bool(pattern.search(command)))

entries = []
for entry in hooks.get(event, []):
    if not isinstance(entry, dict) or entry.get("matcher", "") != "":
        entries.append(entry)
        continue
    retained = [hook for hook in entry.get("hooks", []) if not managed(hook)]
    if retained:
        replacement = dict(entry)
        replacement["hooks"] = retained
        entries.append(replacement)
if entries:
    hooks[event] = entries
else:
    hooks.pop(event, None)
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)
if not settings:
    try:
        os.remove(file_path)
    except FileNotFoundError:
        pass
    raise SystemExit(0)

dir_path = os.path.dirname(file_path)
fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix=".tmp.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
        return $?
    fi

    echo "Error: jq or python3 required for config preservation" >&2
    return 1
}

register_resume_after_input_hooks() {
    local file="$1" post_tool_cmd="$2" resume_cmd="$3"
    register_empty_matcher_lifecycle_hook "$file" "PostToolUse" "$post_tool_cmd" "$(get_managed_claude_post_tool_pattern)" || return 1
    register_empty_matcher_lifecycle_hook "$file" "PreToolUse" "$resume_cmd" "$(get_managed_claude_resume_after_input_pattern)"
}

unregister_resume_after_input_hooks() {
    local file="$1" post_tool_cmd="$2" resume_cmd="$3"
    unregister_empty_matcher_lifecycle_hook "$file" "PostToolUse" "$post_tool_cmd" "$(get_managed_claude_post_tool_pattern)" || return 1
    unregister_empty_matcher_lifecycle_hook "$file" "PreToolUse" "$resume_cmd" "$(get_managed_claude_resume_after_input_pattern)"
}

# Claude's Notification event is dispatched by the interactive UI and can be
# held while the Ctrl+O verbose transcript is open. PermissionRequest runs at
# the earlier permission lifecycle point, so approval alerts remain immediate
# regardless of which UI view is active. Keep the same notifier command: its
# payload classifier recognizes PermissionRequest as a permission_prompt.
register_claude_permission_request_hook() {
    local file="$1" command="$2" pattern
    pattern="$(get_managed_claude_permission_request_pattern)"

    if is_notify_type_enabled "permission_prompt"; then
        register_empty_matcher_lifecycle_hook "$file" "PermissionRequest" "$command" "$pattern"
    else
        unregister_empty_matcher_lifecycle_hook "$file" "PermissionRequest" "$command" "$pattern"
    fi
}

unregister_claude_permission_request_hook() {
    local file="$1" command="$2"
    unregister_empty_matcher_lifecycle_hook \
        "$file" "PermissionRequest" "$command" "$(get_managed_claude_permission_request_pattern)"
}

# A turn that dies on an API error (usage limit, server error) emits
# StopFailure instead of Stop. The notifier needs that event to take down the
# running indicator and badge the window, so the hook installs unconditionally
# alongside Stop rather than behind an alert type.
register_claude_stop_failure_hook() {
    local file="$1" command="$2"
    register_empty_matcher_lifecycle_hook \
        "$file" "StopFailure" "$command" "$(get_managed_claude_stop_failure_pattern)"
}

unregister_claude_stop_failure_hook() {
    local file="$1" command="$2"
    unregister_empty_matcher_lifecycle_hook \
        "$file" "StopFailure" "$command" "$(get_managed_claude_stop_failure_pattern)"
}

has_expected_claude_permission_request_hook() {
    local file="$1" command="$2"
    if is_notify_type_enabled "permission_prompt"; then
        has_empty_matcher_lifecycle_command "$file" "PermissionRequest" "$command"
    else
        ! has_empty_matcher_lifecycle_command "$file" "PermissionRequest" "$command"
    fi
}

enable_hooks_in_settings() {
    local notify_matcher
    notify_matcher=$(get_notify_matcher)

    update_claude_hooks_in_settings_file \
        "$GLOBAL_SETTINGS_FILE" \
        "$notify_matcher" \
        "$(get_global_claude_notify_command)" \
        "$(get_global_claude_stop_command)" \
        "enable" \
        "$(get_notify_script) " \
        " claude" || return 1

    # Register PreToolUse hook for AskUserQuestion if ask_user alert type is enabled
    register_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"

    # Register UserPromptSubmit hook that clears the tmux window badge on engage
    register_badge_clear_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_user_prompt_command)"

    # Input responses and approval decisions resume an existing turn without a
    # UserPromptSubmit event. PostToolUse handles the resumed tool itself and
    # the silent PreToolUse hook covers input tools that emit no PostToolUse.
    register_resume_after_input_hooks \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_post_tool_command)" \
        "$(get_global_claude_resume_after_input_command)" || return 1

    register_claude_stop_failure_hook \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_stop_failure_command)" || return 1

    register_claude_permission_request_hook \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_notify_command)"
}

# Disable hooks in settings.json (new format)
disable_hooks_in_settings() {
    if [[ ! -f "$GLOBAL_SETTINGS_FILE" ]]; then
        return 0
    fi

    update_claude_hooks_in_settings_file \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_notify_matcher)" \
        "$(get_global_claude_notify_command)" \
        "$(get_global_claude_stop_command)" \
        "disable" \
        "$(get_notify_script) " \
        " claude" || return 1

    # Remove PreToolUse hook for AskUserQuestion
    unregister_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"

    # Remove UserPromptSubmit badge-clear hook
    unregister_badge_clear_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_user_prompt_command)"

    unregister_resume_after_input_hooks \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_post_tool_command)" \
        "$(get_global_claude_resume_after_input_command)" || return 1

    unregister_claude_stop_failure_hook \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_stop_failure_command)" || return 1

    unregister_claude_permission_request_hook \
        "$GLOBAL_SETTINGS_FILE" \
        "$(get_global_claude_notify_command)"
}

# Disable hooks in project settings.json
disable_project_hooks_in_settings() {
    local project_root="${1:-$(get_project_root)}"
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    local project_name="${2:-$(basename "$project_root")}"

    if [[ ! -f "$project_settings" ]]; then
        return 0
    fi

    update_claude_hooks_in_settings_file \
        "$project_settings" \
        "$(get_notify_matcher)" \
        "$(get_project_claude_notify_command "$project_name")" \
        "$(get_project_claude_stop_command "$project_name")" \
        "disable" \
        "$(shell_quote "$(get_notify_script)") " \
        " claude $(shell_quote "$project_name")" || return 1

    # Remove PreToolUse hook for AskUserQuestion
    unregister_ask_user_hook "$project_settings" "$(get_project_claude_pre_tool_use_command "$project_name")"

    # Remove UserPromptSubmit badge-clear hook
    unregister_badge_clear_hook "$project_settings" "$(get_project_claude_user_prompt_command "$project_name")"

    unregister_resume_after_input_hooks \
        "$project_settings" \
        "$(get_project_claude_post_tool_command "$project_name")" \
        "$(get_project_claude_resume_after_input_command "$project_name")" || return 1

    unregister_claude_stop_failure_hook \
        "$project_settings" \
        "$(get_project_claude_stop_failure_command "$project_name")" || return 1

    unregister_claude_permission_request_hook \
        "$project_settings" \
        "$(get_project_claude_notify_command "$project_name")"
}

# Enable hooks in project settings.json
enable_project_hooks_in_settings() {
    local project_root="${1:-$(get_project_root)}"
    local project_name="${2:-$(get_project_name)}"
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    local notify_matcher
    notify_matcher=$(get_notify_matcher)

    mkdir -p "$project_root/.claude"

    update_claude_hooks_in_settings_file \
        "$project_settings" \
        "$notify_matcher" \
        "$(get_project_claude_notify_command "$project_name")" \
        "$(get_project_claude_stop_command "$project_name")" \
        "enable" \
        "$(shell_quote "$(get_notify_script)") " \
        " claude $(shell_quote "$project_name")" || return 1

    # Register PreToolUse hook for AskUserQuestion if ask_user alert type is enabled
    register_ask_user_hook "$project_settings" "$(get_project_claude_pre_tool_use_command "$project_name")"

    # Register UserPromptSubmit hook that clears the tmux window badge on engage
    register_badge_clear_hook "$project_settings" "$(get_project_claude_user_prompt_command "$project_name")"

    register_resume_after_input_hooks \
        "$project_settings" \
        "$(get_project_claude_post_tool_command "$project_name")" \
        "$(get_project_claude_resume_after_input_command "$project_name")" || return 1

    register_claude_stop_failure_hook \
        "$project_settings" \
        "$(get_project_claude_stop_failure_command "$project_name")" || return 1

    register_claude_permission_request_hook \
        "$project_settings" \
        "$(get_project_claude_notify_command "$project_name")"
}

# Check if project has settings.json with code-notify hooks
is_enabled_project_settings() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    has_current_project_claude_hooks "$project_settings" "$(get_project_name)"
}

# ============================================
# Codex Configuration
# ============================================

remove_codex_notify_config() {
    local file="$1"
    local dir_path
    local tmp_file

    [[ -f "$file" ]] || return 0

    dir_path=$(dirname "$file")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    awk '
        function bracket_delta(s,   t, o, c) {
            t = s; o = gsub(/\[/, "", t)
            t = s; c = gsub(/\]/, "", t)
            return o - c
        }
        function flush_notify(   block) {
            block = notify_buf
            notify_buf = ""
            buffering = 0
            # Drop only when the whole assignment points at our notifier and
            # passes the codex argument; otherwise restore it untouched.
            if (block ~ /(code-notify|notifier\.sh|notify\.(sh|ps1))/ && block ~ /codex/) {
                return
            }
            print block
        }
        /^[[:space:]]*# Code-Notify: Desktop notifications[[:space:]]*$/ {
            next
        }
        buffering {
            notify_buf = notify_buf "\n" $0
            depth += bracket_delta($0)
            if (depth <= 0) {
                flush_notify()
            }
            next
        }
        /^[[:space:]]*notify[[:space:]]*=/ {
            # notify may be a single line or a multi-line array; buffer the whole
            # assignment so a managed multi-line notify is removed in full.
            notify_buf = $0
            depth = bracket_delta($0)
            if (depth > 0) {
                buffering = 1
                next
            }
            flush_notify()
            next
        }
        {
            print
        }
        END {
            if (buffering) {
                # Unterminated array (malformed TOML): preserve what we buffered.
                print notify_buf
            }
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$file"
}

disable_codex_tui_notifications() {
    local file="$1"
    local dir_path
    local tmp_file

    dir_path=$(dirname "$file")
    mkdir -p "$dir_path"
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    if [[ -f "$file" ]]; then
        awk '
            BEGIN {
                in_tui = 0
                saw_tui = 0
                wrote = 0
                managed = 0
                capturing = 0
                depth = 0
                norig = 0
                comment = "# Code-Notify: Codex notifications are handled by hooks"
                saved_prefix = "# Code-Notify-saved: "
                setting = "notifications = false"
            }
            function bracket_delta(s,   t, o, c) {
                t = s; o = gsub(/\[/, "", t)
                t = s; c = gsub(/\]/, "", t)
                return o - c
            }
            function emit_managed(   i) {
                print comment
                for (i = 1; i <= norig; i++) {
                    print saved_prefix orig[i]
                }
                print setting
                wrote = 1
            }
            /^[[:space:]]*# Code-Notify: Codex notifications are handled by hooks[[:space:]]*$/ {
                if (in_tui) {
                    managed = 1
                }
                next
            }
            in_tui && /^[[:space:]]*# Code-Notify-saved: / {
                line = $0
                sub(/^[[:space:]]*# Code-Notify-saved: /, "", line)
                norig++
                orig[norig] = line
                next
            }
            # Continuation lines of a multi-line user value being captured.
            in_tui && capturing {
                norig++
                orig[norig] = $0
                depth += bracket_delta($0)
                if (depth <= 0) {
                    capturing = 0
                }
                next
            }
            /^[[:space:]]*\[/ {
                if (in_tui && !wrote) {
                    emit_managed()
                }
                in_tui = ($0 ~ /^[[:space:]]*\[tui\][[:space:]]*$/)
                if (in_tui) {
                    saw_tui = 1
                }
                managed = 0
                print
                next
            }
            in_tui && /^[[:space:]]*notifications[[:space:]]*=/ {
                # Our managed false (preceded by the managed comment) is dropped;
                # a user-authored value is captured verbatim so disable can
                # restore it. The value may be a multi-line array, so keep
                # consuming lines until the brackets balance.
                if (managed) {
                    managed = 0
                } else {
                    norig++
                    orig[norig] = $0
                    depth = bracket_delta($0)
                    if (depth > 0) {
                        capturing = 1
                    }
                }
                next
            }
            {
                managed = 0
                print
            }
            END {
                if (in_tui && !wrote) {
                    emit_managed()
                }
                if (!saw_tui) {
                    print ""
                    print "[tui]"
                    print comment
                    print setting
                }
            }
        ' "$file" > "$tmp_file" || {
            rm -f "$tmp_file"
            return 1
        }
    else
        cat > "$tmp_file" << 'EOF'
[tui]
# Code-Notify: Codex notifications are handled by hooks
notifications = false
EOF
    fi

    mv "$tmp_file" "$file"
}

remove_codex_tui_notifications_override() {
    local file="$1"
    local dir_path
    local tmp_file

    [[ -f "$file" ]] || return 0

    dir_path=$(dirname "$file")
    tmp_file=$(mktemp "${dir_path}/.tmp.XXXXXX") || return 1

    awk '
        /^[[:space:]]*# Code-Notify: Codex notifications are handled by hooks[[:space:]]*$/ {
            managed = 1
            next
        }
        managed && /^[[:space:]]*# Code-Notify-saved: / {
            line = $0
            sub(/^[[:space:]]*# Code-Notify-saved: /, "", line)
            print line
            next
        }
        managed && /^[[:space:]]*notifications[[:space:]]*=[[:space:]]*false[[:space:]]*$/ {
            managed = 0
            next
        }
        {
            managed = 0
            print
        }
    ' "$file" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$file"
}

has_current_codex_hooks() {
    local file="${1:-$CODEX_HOOKS_FILE}"
    local stop_cmd permission_cmd prompt_cmd post_tool_cmd resume_cmd pattern
    stop_cmd="$(get_global_codex_stop_command)"
    permission_cmd="$(get_global_codex_permission_command)"
    prompt_cmd="$(get_global_codex_prompt_command)"
    post_tool_cmd="$(get_global_codex_post_tool_command)"
    resume_cmd="$(get_global_codex_resume_after_input_command)"
    pattern="$(get_managed_codex_hook_pattern)"

    [[ -f "$file" ]] || return 1

    if has_jq; then
        jq -e \
            --arg stop "$stop_cmd" \
            --arg permission "$permission_cmd" \
            --arg prompt "$prompt_cmd" \
            --arg post_tool "$post_tool_cmd" \
            --arg resume "$resume_cmd" \
            --arg pattern "$pattern" \
            --argjson permission_enabled "$(is_notify_type_enabled "permission_prompt" && echo true || echo false)" '
            def command_matches($exact):
                . == $exact or test($pattern);

            any((.hooks.Stop // [])[]?.hooks[]?.command?; command_matches($stop)) and
            any((.hooks.UserPromptSubmit // [])[]?.hooks[]?.command?; command_matches($prompt)) and
            any((.hooks.PostToolUse // [])[]?.hooks[]?.command?; command_matches($post_tool)) and
            any((.hooks.PreToolUse // [])[]?.hooks[]?.command?; command_matches($resume)) and
            (
                ($permission_enabled | not) or
                any((.hooks.PermissionRequest // [])[]?.hooks[]?.command?; command_matches($permission))
            )
        ' "$file" &>/dev/null
        return $?
    fi

    if has_python3; then
        python3 - "$file" "$stop_cmd" "$permission_cmd" "$prompt_cmd" "$post_tool_cmd" "$resume_cmd" "$pattern" "$(is_notify_type_enabled "permission_prompt" && echo true || echo false)" << 'PYTHON' 2>/dev/null
import json
import re
import sys

file_path, stop_cmd, permission_cmd, prompt_cmd, post_tool_cmd, resume_cmd, pattern, permission_enabled = sys.argv[1:9]

try:
    with open(file_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)

hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(1)

regex = re.compile(pattern)

def has_command(event, exact):
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for hook in entry.get("hooks", []):
            if not isinstance(hook, dict):
                continue
            command = hook.get("command", "")
            if command == exact or regex.search(command):
                return True
    return False

if not has_command("Stop", stop_cmd):
    raise SystemExit(1)
if not has_command("UserPromptSubmit", prompt_cmd):
    raise SystemExit(1)
if not has_command("PostToolUse", post_tool_cmd):
    raise SystemExit(1)
if not has_command("PreToolUse", resume_cmd):
    raise SystemExit(1)
if permission_enabled == "true" and not has_command("PermissionRequest", permission_cmd):
    raise SystemExit(1)
PYTHON
        return $?
    fi

    grep -q '"Stop"' "$file" &&
        grep -q '"UserPromptSubmit"' "$file" &&
        grep -q '"PostToolUse"' "$file" &&
        grep -q '"PreToolUse"' "$file" &&
        grep -qE 'code-notify|notifier\.sh|notify\.(sh|ps1)' "$file" &&
        grep -q 'codex' "$file" || return 1

    # Keep the parser-free fallback aligned with the jq/Python paths: an
    # enabled permission_prompt alert requires a PermissionRequest hook.
    if is_notify_type_enabled "permission_prompt"; then
        grep -q '"PermissionRequest"' "$file" || return 1
    fi
    return 0
}

update_codex_hooks_file() {
    local mode="$1"
    local file="$2"
    local stop_cmd permission_cmd prompt_cmd post_tool_cmd resume_cmd pattern permission_enabled
    stop_cmd="$(get_global_codex_stop_command)"
    permission_cmd="$(get_global_codex_permission_command)"
    prompt_cmd="$(get_global_codex_prompt_command)"
    post_tool_cmd="$(get_global_codex_post_tool_command)"
    resume_cmd="$(get_global_codex_resume_after_input_command)"
    pattern="$(get_managed_codex_hook_pattern)"
    permission_enabled="$(is_notify_type_enabled "permission_prompt" && echo true || echo false)"

    if has_jq; then
        safe_jq_update "$file" '
            def array_or_empty:
                if type == "array" then . else [] end;

            def strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern):
                array_or_empty
                | map(
                    if ((.hooks | type) == "array") then
                        .hooks = (
                            .hooks
                            | map(select(
                                (
                                    (.type // "") == "command" and
                                    (
                                        (.command // "") == $stop or
                                        (.command // "") == $permission or
                                        (.command // "") == $prompt or
                                        (.command // "") == $post_tool or
                                        (.command // "") == $resume or
                                        ((.command // "") | test($pattern))
                                    )
                                ) | not
                            ))
                        )
                    else
                        .
                    end
                )
                | map(select(((.hooks | type) != "array") or ((.hooks | length) > 0)));

            .hooks = (if (.hooks | type) == "object" then .hooks else {} end) |
            .hooks.Stop = (.hooks.Stop | strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern)) |
            .hooks.PermissionRequest = (.hooks.PermissionRequest | strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern)) |
            .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit | strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern)) |
            .hooks.PostToolUse = (.hooks.PostToolUse | strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern)) |
            .hooks.PreToolUse = (.hooks.PreToolUse | strip_managed($stop; $permission; $prompt; $post_tool; $resume; $pattern)) |
            if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
            if (.hooks.PermissionRequest | length) == 0 then del(.hooks.PermissionRequest) else . end |
            if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end |
            if (.hooks.PostToolUse | length) == 0 then del(.hooks.PostToolUse) else . end |
            if (.hooks.PreToolUse | length) == 0 then del(.hooks.PreToolUse) else . end |
            if $mode == "enable" then
                .hooks.Stop = ((.hooks.Stop // []) + [{
                    "hooks": [{
                        "type": "command",
                        "command": $stop,
                        "timeout": 5,
                        "statusMessage": "Notifying task completion"
                    }]
                }]) |
                .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [{
                    "hooks": [{
                        "type": "command",
                        "command": $prompt,
                        "timeout": 5,
                        "statusMessage": "Clearing window badge"
                    }]
                }]) |
                .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
                    "matcher": "*",
                    "hooks": [{
                        "type": "command",
                        "command": $post_tool,
                        "timeout": 5,
                        "statusMessage": "Restoring running indicator"
                    }]
                }]) |
                .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
                    "matcher": "*",
                    "hooks": [{
                        "type": "command",
                        "command": $resume,
                        "timeout": 5,
                        "statusMessage": "Restoring running indicator"
                    }]
                }]) |
                if $permission_enabled then
                    .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [{
                        "matcher": "*",
                        "hooks": [{
                            "type": "command",
                            "command": $permission,
                            "timeout": 5,
                            "statusMessage": "Notifying approval request"
                        }]
                    }])
                else
                    .
                end
            else
                .
            end |
            if (.hooks | length) == 0 then del(.hooks) else . end
        ' --arg mode "$mode" \
          --arg stop "$stop_cmd" \
          --arg permission "$permission_cmd" \
          --arg prompt "$prompt_cmd" \
          --arg post_tool "$post_tool_cmd" \
          --arg resume "$resume_cmd" \
          --arg pattern "$pattern" \
          --argjson permission_enabled "$permission_enabled"
        return $?
    fi

    if has_python3; then
        local tmp_json
        tmp_json=$(mktemp "$(dirname "$file")/.tmp.XXXXXX") || return 1
        python3 - "$file" "$mode" "$stop_cmd" "$permission_cmd" "$prompt_cmd" "$post_tool_cmd" "$resume_cmd" "$pattern" "$permission_enabled" "$tmp_json" << 'PYTHON' || {
import json
import os
import re
import sys

file_path, mode, stop_cmd, permission_cmd, prompt_cmd, post_tool_cmd, resume_cmd, pattern, permission_enabled, tmp_path = sys.argv[1:11]

try:
    with open(file_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except Exception as exc:
    print(f"Error: Failed to parse Codex hooks JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(data, dict):
    data = {}

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
else:
    hooks = dict(hooks)

regex = re.compile(pattern)

def strip_managed(entries):
    if not isinstance(entries, list):
        return []
    cleaned = []
    for entry in entries:
        if not isinstance(entry, dict):
            cleaned.append(entry)
            continue
        entry = dict(entry)
        entry_hooks = entry.get("hooks")
        if isinstance(entry_hooks, list):
            filtered = []
            for hook in entry_hooks:
                if not isinstance(hook, dict):
                    filtered.append(hook)
                    continue
                command = hook.get("command", "")
                if (
                    hook.get("type") == "command"
                    and (
                        command == stop_cmd
                        or command == permission_cmd
                        or command == prompt_cmd
                        or command == post_tool_cmd
                        or command == resume_cmd
                        or regex.search(command)
                    )
                ):
                    continue
                filtered.append(hook)
            entry["hooks"] = filtered
            if not filtered:
                continue
        cleaned.append(entry)
    return cleaned

hooks["Stop"] = strip_managed(hooks.get("Stop", []))
hooks["PermissionRequest"] = strip_managed(hooks.get("PermissionRequest", []))
hooks["UserPromptSubmit"] = strip_managed(hooks.get("UserPromptSubmit", []))
hooks["PostToolUse"] = strip_managed(hooks.get("PostToolUse", []))
hooks["PreToolUse"] = strip_managed(hooks.get("PreToolUse", []))
if not hooks["Stop"]:
    hooks.pop("Stop", None)
if not hooks.get("PermissionRequest"):
    hooks.pop("PermissionRequest", None)
if not hooks.get("UserPromptSubmit"):
    hooks.pop("UserPromptSubmit", None)
if not hooks.get("PostToolUse"):
    hooks.pop("PostToolUse", None)
if not hooks.get("PreToolUse"):
    hooks.pop("PreToolUse", None)

if mode == "enable":
    hooks["Stop"] = list(hooks.get("Stop", [])) + [{
        "hooks": [{
            "type": "command",
            "command": stop_cmd,
            "timeout": 5,
            "statusMessage": "Notifying task completion",
        }],
    }]
    hooks["UserPromptSubmit"] = list(hooks.get("UserPromptSubmit", [])) + [{
        "hooks": [{
            "type": "command",
            "command": prompt_cmd,
            "timeout": 5,
            "statusMessage": "Clearing window badge",
        }],
    }]
    hooks["PostToolUse"] = list(hooks.get("PostToolUse", [])) + [{
        "matcher": "*",
        "hooks": [{
            "type": "command",
            "command": post_tool_cmd,
            "timeout": 5,
            "statusMessage": "Restoring running indicator",
        }],
    }]
    hooks["PreToolUse"] = list(hooks.get("PreToolUse", [])) + [{
        "matcher": "*",
        "hooks": [{
            "type": "command",
            "command": resume_cmd,
            "timeout": 5,
            "statusMessage": "Restoring running indicator",
        }],
    }]
    if permission_enabled == "true":
        hooks["PermissionRequest"] = list(hooks.get("PermissionRequest", [])) + [{
            "matcher": "*",
            "hooks": [{
                "type": "command",
                "command": permission_cmd,
                "timeout": 5,
                "statusMessage": "Notifying approval request",
            }],
        }]

if hooks:
    data["hooks"] = hooks
else:
    data.pop("hooks", None)

with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")

os.replace(tmp_path, file_path)
PYTHON
            rm -f "$tmp_json"
            return 1
        }
        return 0
    fi

    echo "Error: jq or python3 required to safely update Codex hooks" >&2
    return 1
}

# Check if Codex notifications are enabled
is_codex_enabled() {
    has_current_codex_hooks "$CODEX_HOOKS_FILE"
}

# Enable Codex notifications
enable_codex_hooks() {
    mkdir -p "$CODEX_HOME"

    # Install the hooks first: this is the step that can fail closed (e.g. a
    # malformed hooks.json). Only suppress Codex's built-in TUI notifications
    # once our hooks are actually in place, so a failure never leaves Codex
    # silenced with no Code-Notify hooks to replace it.
    if [[ -f "$CODEX_HOOKS_FILE" ]]; then
        backup_config "$CODEX_HOOKS_FILE" || true
    fi
    update_codex_hooks_file "enable" "$CODEX_HOOKS_FILE" || return 1

    if [[ -f "$CODEX_CONFIG_FILE" ]]; then
        backup_config "$CODEX_CONFIG_FILE" || true
        remove_codex_notify_config "$CODEX_CONFIG_FILE" || return 1
    fi
    disable_codex_tui_notifications "$CODEX_CONFIG_FILE" || return 1
}

# Disable Codex notifications
disable_codex_hooks() {
    if [[ -f "$CODEX_HOOKS_FILE" ]]; then
        backup_config "$CODEX_HOOKS_FILE" || true
        update_codex_hooks_file "disable" "$CODEX_HOOKS_FILE" || return 1
    fi

    if [[ -f "$CODEX_CONFIG_FILE" ]]; then
        backup_config "$CODEX_CONFIG_FILE" || true
        remove_codex_notify_config "$CODEX_CONFIG_FILE" || return 1
        remove_codex_tui_notifications_override "$CODEX_CONFIG_FILE" || return 1
    fi
}

# ============================================
# Gemini CLI Configuration
# ============================================

# Check if Gemini CLI notifications are enabled
is_gemini_enabled() {
    if [[ ! -f "$GEMINI_SETTINGS_FILE" ]]; then
        return 1
    fi
    # Check for our hooks in Gemini settings
    if has_jq; then
        jq -e '.hooks.AfterAgent != null or .hooks.Notification != null' "$GEMINI_SETTINGS_FILE" &>/dev/null
    else
        grep -qE '"(AfterAgent|Notification)"' "$GEMINI_SETTINGS_FILE" 2>/dev/null
    fi
}

# Enable Gemini CLI notifications
enable_gemini_hooks() {
    local notify_script=$(get_notify_script)

    # Ensure .gemini directory exists
    mkdir -p "$GEMINI_HOME"

    # Backup existing config
    if [[ -f "$GEMINI_SETTINGS_FILE" ]]; then
        backup_config "$GEMINI_SETTINGS_FILE"
    fi

    if has_jq; then
        # Use safe_jq_update for error checking
        safe_jq_update "$GEMINI_SETTINGS_FILE" '
            .tools.enableHooks = true |
            .hooks.enabled = true |
            .hooks.Notification = [{
                "matcher": "",
                "hooks": [{
                    "name": "code-notify-notification",
                    "type": "command",
                    "command": ($script + " notification gemini"),
                    "description": "Desktop notification when input needed"
                }]
            }] |
            .hooks.AfterAgent = [{
                "matcher": "",
                "hooks": [{
                    "name": "code-notify-complete",
                    "type": "command",
                    "command": ($script + " stop gemini"),
                    "description": "Desktop notification when task complete"
                }]
            }]
        ' --arg script "$notify_script"
    elif has_python3; then
        # Use Python fallback - pass JSON via temp file to avoid shell escaping issues
        local settings="{}"
        if [[ -f "$GEMINI_SETTINGS_FILE" ]]; then
            settings=$(cat "$GEMINI_SETTINGS_FILE")
        fi

        local tmp_json
        tmp_json=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }

        printf '%s\n' "$settings" > "$tmp_json"

        python3 - "$GEMINI_SETTINGS_FILE" "$notify_script" "$tmp_json" << 'PYTHON'
import sys
import json
import tempfile
import os

file_path = sys.argv[1]
script = sys.argv[2]
json_file = sys.argv[3]

try:
    with open(json_file, 'r') as f:
        settings = json.load(f)
finally:
    # Always clean up temp file
    try:
        os.unlink(json_file)
    except OSError:
        pass

settings.setdefault('tools', {})['enableHooks'] = True
settings.setdefault('hooks', {})['enabled'] = True
settings['hooks']['Notification'] = [{
    'matcher': '',
    'hooks': [{
        'name': 'code-notify-notification',
        'type': 'command',
        'command': f'{script} notification gemini',
        'description': 'Desktop notification when input needed'
    }]
}]
settings['hooks']['AfterAgent'] = [{
    'matcher': '',
    'hooks': [{
        'name': 'code-notify-complete',
        'type': 'command',
        'command': f'{script} stop gemini',
        'description': 'Desktop notification when task complete'
    }]
}]

# Atomic write: write to temp file, then rename
dir_path = os.path.dirname(file_path)
content = json.dumps(settings, indent=2)

fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
        f.write('\n')
    os.replace(tmp_path, file_path)
except Exception:
    os.unlink(tmp_path)
    raise
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Disable Gemini CLI notifications
disable_gemini_hooks() {
    if [[ ! -f "$GEMINI_SETTINGS_FILE" ]]; then
        return 0
    fi

    backup_config "$GEMINI_SETTINGS_FILE"

    if has_jq; then
        local settings new_settings
        settings=$(cat "$GEMINI_SETTINGS_FILE")

        # Remove code-notify specific hooks with error checking
        if ! new_settings=$(echo "$settings" | jq 'del(.hooks.Notification) | del(.hooks.AfterAgent) | del(.hooks.enabled)' 2>/dev/null); then
            echo "Error: Failed to parse configuration JSON" >&2
            echo "File unchanged: $GEMINI_SETTINGS_FILE" >&2
            return 1
        fi

        # If hooks object is now empty, remove it entirely
        if ! new_settings=$(echo "$new_settings" | jq 'if .hooks == {} then del(.hooks) else . end' 2>/dev/null); then
            echo "Error: Failed to process configuration JSON" >&2
            echo "File unchanged: $GEMINI_SETTINGS_FILE" >&2
            return 1
        fi

        if [[ "$new_settings" != "{}" ]]; then
            atomic_write "$GEMINI_SETTINGS_FILE" "$new_settings"
        else
            rm -f "$GEMINI_SETTINGS_FILE"
        fi
    elif has_python3; then
        python3 - "$GEMINI_SETTINGS_FILE" << 'PYTHON'
import sys
import json
import os
import tempfile

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    settings = json.load(f)

if 'hooks' in settings:
    settings['hooks'].pop('Notification', None)
    settings['hooks'].pop('AfterAgent', None)
    settings['hooks'].pop('enabled', None)
    if not settings['hooks']:
        del settings['hooks']

if settings:
    # Atomic write: write to temp file, then rename
    dir_path = os.path.dirname(file_path)
    content = json.dumps(settings, indent=2)

    fd, tmp_path = tempfile.mkstemp(dir=dir_path, prefix='.tmp.')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(content)
            f.write('\n')
        os.replace(tmp_path, file_path)
    except Exception:
        os.unlink(tmp_path)
        raise
else:
    os.remove(file_path)
PYTHON
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required to safely disable hooks" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# ============================================
# Antigravity CLI (agy) Configuration
# ============================================
#
# Notes from live testing against agy 1.0.11 and 1.1.3:
#   * Hooks load from imported plugins (`agy plugin install <dir>`), NOT from a
#     settings.json hooks key.
#   * In 1.0.x only the tool hooks PreToolUse/PostToolUse actually executed;
#     since 1.1.3 the lifecycle hooks (PreInvocation/PostInvocation/Stop) run
#     too, and the hooks.json schema requires them as FLAT handler lists.
#   * agy passes NO argv to a hook command and reads the hook's stdout as
#     protojson, so each hook is a fixed wrapper script that pipes agy's stdin
#     payload into the notifier and prints nothing.
# Mapping: PreInvocation (every model call) -> running indicator from prompt
# submission + cancel the pending debounce (still working); PreToolUse (every
# tool) -> the same cancel plus a run_command-scoped "input needed" approval
# banner; PostToolUse -> fallback debounced "task complete" plus immediate
# error alerts; Stop -> native "task complete" (or failure alert when the turn
# ended with an error).

# Check if Antigravity notifications are enabled (plugin imported AND active).
is_antigravity_enabled() {
    # Ground truth is agy's managed copy. An enabled plugin keeps plugin.json;
    # `agy plugin disable` renames it to plugin.json.disabled but KEEPS the
    # manifest entry, so a manifest grep alone reports a disabled plugin as
    # enabled. Check the managed copy first.
    if [[ -f "$ANTIGRAVITY_IMPORTED_PLUGIN_DIR/plugin.json" ]]; then
        return 0
    fi
    if [[ -f "$ANTIGRAVITY_IMPORTED_PLUGIN_DIR/plugin.json.disabled" ]]; then
        return 1
    fi
    # Managed copy not found (non-default layout): fall back to manifest presence.
    if [[ -f "$ANTIGRAVITY_IMPORT_MANIFEST" ]]; then
        grep -q "\"$ANTIGRAVITY_PLUGIN_NAME\"" "$ANTIGRAVITY_IMPORT_MANIFEST" 2>/dev/null && return 0
    fi
    return 1
}

# Check if the plugin is IMPORTED at all, regardless of whether it is currently
# active. `agy plugin disable` deactivates the plugin (is_antigravity_enabled
# becomes false) but leaves it imported — the manifest entry and managed dir
# remain. `cn off antigravity` must still uninstall it in that state, so the
# disable path keys on this rather than on is_antigravity_enabled.
is_antigravity_imported() {
    [[ -f "$ANTIGRAVITY_IMPORTED_PLUGIN_DIR/plugin.json" ]] && return 0
    [[ -f "$ANTIGRAVITY_IMPORTED_PLUGIN_DIR/plugin.json.disabled" ]] && return 0
    if [[ -f "$ANTIGRAVITY_IMPORT_MANIFEST" ]]; then
        grep -q "\"$ANTIGRAVITY_PLUGIN_NAME\"" "$ANTIGRAVITY_IMPORT_MANIFEST" 2>/dev/null && return 0
    fi
    return 1
}

# Write a single no-arg agy hook wrapper. agy gives the command no arguments, so
# the event name is baked in here; the wrapper pipes agy's stdin payload into the
# notifier and stays silent on stdout (agy parses hook stdout as protojson).
write_agy_hook_wrapper() {
    local path="$1"
    local event="$2"
    local notify_script="$3"

    cat > "$path" <<EOF
#!/bin/bash
# code-notify Antigravity hook wrapper for the $event event.
# Auto-generated by 'cn on antigravity' — do not edit.
exec "$notify_script" "agy:$event" "antigravity" >/dev/null 2>&1
EOF
    chmod +x "$path"
}

# Shell-quote a wrapper path for embedding inside an agy hook "command" string.
# agy runs the command through a shell, so an unquoted path containing spaces
# splits into multiple words and the hook fails (exit 127). The returned token
# is single-quoted (valid JSON string content, no JSON escaping needed) and is
# placed inside the JSON value's double quotes by the caller. Paths containing a
# single quote are not supported — code-notify's wrappers live under HOME.
agy_shell_quote() {
    printf "'%s'" "$1"
}

# Enable Antigravity notifications by building and importing a code-notify plugin.
enable_antigravity_hooks() {
    if ! command -v agy &> /dev/null; then
        echo "Error: agy (Antigravity CLI) not found in PATH" >&2
        return 1
    fi

    local notify_script staging
    notify_script="$(get_notify_script)"
    staging="$ANTIGRAVITY_PLUGIN_STAGING"

    mkdir -p "$staging/hooks"

    # Plugin manifest
    cat > "$staging/plugin.json" <<EOF
{
  "name": "$ANTIGRAVITY_PLUGIN_NAME",
  "version": "${VERSION:-1.0.0}",
  "description": "Desktop notifications for Antigravity CLI via code-notify"
}
EOF

    # One wrapper per event (event baked in; agy passes no argv)
    write_agy_hook_wrapper "$staging/hooks/preinvocation.sh" "PreInvocation" "$notify_script"
    write_agy_hook_wrapper "$staging/hooks/pretooluse.sh"  "PreToolUse"  "$notify_script"
    write_agy_hook_wrapper "$staging/hooks/posttooluse.sh" "PostToolUse" "$notify_script"
    write_agy_hook_wrapper "$staging/hooks/stop.sh"        "Stop"        "$notify_script"

    # PreToolUse is always registered with an empty matcher (all tools). agy
    # fires it before every tool call, which is code-notify's "agent is still
    # working" signal: the notifier cancels any pending debounced completion so a
    # tool that outlives the debounce window can't fire a premature "task
    # complete". The notifier scopes the approval ("input needed") banner to
    # calls that pause for the user (run_command and MCP tools — call_mcp_tool
    # or eager mcp_<server>_<tool> registrations) and to the permission_prompt
    # alert type at runtime, so this hook no longer depends on the alert
    # config at install time.
    local pre_tool_use_block
    pre_tool_use_block=$(cat <<EOF
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "$(agy_shell_quote "$staging/hooks/pretooluse.sh")" } ] }
    ],
EOF
)

    # hooks.json. PreInvocation (before every model call — agy's de-facto
    # prompt-submit event) lights the running indicator from the start of a
    # turn; PostToolUse powers the fallback debounced "task complete" plus
    # error alerts; Stop delivers the native turn-end (completion or failure).
    # Since agy 1.1.3 lifecycle events (PreInvocation/Stop) take a FLAT list
    # of handler objects — wrapping them in {"hooks": [...]} like the tool
    # events fails validation ("command hook must specify 'command'") and the
    # whole file is rejected, silently disabling every hook. Only PreToolUse
    # and PostToolUse keep the grouped {"matcher", "hooks"} shape.
    cat > "$ANTIGRAVITY_HOOKS_FILE" <<EOF
{
  "$ANTIGRAVITY_PLUGIN_NAME": {
$pre_tool_use_block
    "PostToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "$(agy_shell_quote "$staging/hooks/posttooluse.sh")" } ] }
    ],
    "PreInvocation": [
      { "type": "command", "command": "$(agy_shell_quote "$staging/hooks/preinvocation.sh")" }
    ],
    "Stop": [
      { "type": "command", "command": "$(agy_shell_quote "$staging/hooks/stop.sh")" }
    ]
  }
}
EOF

    # Install the freshly built plugin. agy keys plugins by name, so installing
    # over an existing import updates it in place — no pre-uninstall needed.
    if ! agy plugin install "$staging" >/dev/null 2>&1; then
        # Install failed. If a working plugin was already imported, leave it
        # intact: a failed update must not disable a working integration (no
        # rollback exists once the plugin is gone). Report the failure instead.
        if is_antigravity_enabled; then
            echo "Error: 'agy plugin install' failed; kept the existing code-notify plugin" >&2
            return 1
        fi

        # Nothing imported to protect. A stale/partial registration the manifest
        # check missed could still block a clean import, so clear it and retry.
        agy plugin uninstall "$ANTIGRAVITY_PLUGIN_NAME" >/dev/null 2>&1 || true
        if ! agy plugin install "$staging" >/dev/null 2>&1; then
            echo "Error: 'agy plugin install' failed" >&2
            return 1
        fi
    fi

    # No snapshot to maintain: agy's managed copy of the plugin is the ground
    # truth that `cn status` reads (see ANTIGRAVITY_IMPORTED_HOOKS_FILE).
    return 0
}

# Disable Antigravity notifications by uninstalling the plugin.
disable_antigravity_hooks() {
    # Nothing to do if agy is gone or the plugin was never imported. Key on
    # "imported" (not "enabled"): a plugin deactivated with `agy plugin disable`
    # is still imported and must be uninstalled by `cn off antigravity`.
    if ! command -v agy &> /dev/null || ! is_antigravity_imported; then
        return 0
    fi

    agy plugin uninstall "$ANTIGRAVITY_PLUGIN_NAME" >/dev/null 2>&1 || true

    # Report failure if the plugin is still imported, so callers don't claim the
    # tool was disabled while its hooks remain installed.
    if is_antigravity_imported; then
        echo "Error: 'agy plugin uninstall $ANTIGRAVITY_PLUGIN_NAME' did not remove the plugin" >&2
        return 1
    fi
    return 0
}

# ============================================
# Multi-tool helpers
# ============================================

# Enable notifications for a specific tool
enable_tool() {
    local tool="$1"

    case "$tool" in
        "claude")
            enable_hooks_in_settings
            ;;
        "codex")
            enable_codex_hooks
            ;;
        "gemini")
            enable_gemini_hooks
            ;;
        "antigravity")
            enable_antigravity_hooks
            ;;
        *)
            return 1
            ;;
    esac
}

# Disable notifications for a specific tool
disable_tool() {
    local tool="$1"

    case "$tool" in
        "claude")
            disable_hooks_in_settings
            ;;
        "codex")
            disable_codex_hooks
            ;;
        "gemini")
            disable_gemini_hooks
            ;;
        "antigravity")
            disable_antigravity_hooks
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if a specific tool has notifications enabled
is_tool_enabled() {
    local tool="$1"

    case "$tool" in
        "claude")
            is_enabled_globally
            ;;
        "codex")
            is_codex_enabled
            ;;
        "gemini")
            is_gemini_enabled
            ;;
        "antigravity")
            is_antigravity_enabled
            ;;
        *)
            return 1
            ;;
    esac
}

# Whether `cn off <tool>` has anything to tear down. For most tools that means
# "currently enabled". Antigravity differs: a plugin deactivated out-of-band
# with `agy plugin disable` reads as not-enabled but is still imported, and
# `cn off antigravity` must still uninstall it. Key the disable path on this.
is_tool_disable_needed() {
    local tool="$1"

    case "$tool" in
        "antigravity")
            is_antigravity_imported
            ;;
        "claude")
            # is_tool_enabled requires the exact current hook set, which an
            # install upgraded across a new mandatory hook type no longer
            # matches. Its managed hooks still fire, so teardown falls back
            # to the loose any-managed detection.
            is_tool_enabled "claude" ||
                has_any_managed_claude_hooks "$GLOBAL_SETTINGS_FILE"
            ;;
        *)
            is_tool_enabled "$tool"
            ;;
    esac
}

# ============================================
# Notification Types Management
# ============================================

# Get current notification types (returns pipe-separated list)
get_notify_types() {
    if [[ -f "$NOTIFY_TYPES_FILE" ]]; then
        normalize_notify_types "$(cat "$NOTIFY_TYPES_FILE")"
    else
        echo "$DEFAULT_NOTIFY_TYPE"
    fi
}

# Normalize an alert type to the canonical value stored in notify-types.
normalize_alert_type() {
    local type="$1"
    local key
    key="$(printf '%s' "$type" | tr '[:upper:]-' '[:lower:]_')"

    case "$key" in
        "idle_prompt"|"permission_prompt"|"auth_success"|"elicitation_dialog"|"ask_user")
            printf '%s\n' "$key"
            ;;
        "subagentstart"|"subagent_start")
            printf '%s\n' "SubagentStart"
            ;;
        "subagentstop"|"subagent_stop")
            printf '%s\n' "SubagentStop"
            ;;
        "teammateidle"|"teammate_idle")
            printf '%s\n' "TeammateIdle"
            ;;
        "taskcreated"|"task_created")
            printf '%s\n' "TaskCreated"
            ;;
        "taskcompleted"|"task_completed")
            printf '%s\n' "TaskCompleted"
            ;;
        *)
            return 1
            ;;
    esac
}

is_notification_alert_type() {
    case "$1" in
        "idle_prompt"|"permission_prompt"|"auth_success"|"elicitation_dialog")
            return 0
            ;;
    esac
    return 1
}

is_claude_event_alert_type() {
    case "$1" in
        "SubagentStart"|"SubagentStop"|"TeammateIdle"|"TaskCreated"|"TaskCompleted")
            return 0
            ;;
    esac
    return 1
}

append_unique_notify_type() {
    local list="$1"
    local type="$2"
    local item
    local -a _code_notify_types=()

    if [[ -z "$list" ]]; then
        printf '%s\n' "$type"
        return 0
    fi

    IFS='|' read -r -a _code_notify_types <<< "$list"
    for item in "${_code_notify_types[@]}"; do
        if [[ "$item" == "$type" ]]; then
            printf '%s\n' "$list"
            return 0
        fi
    done

    printf '%s|%s\n' "$list" "$type"
}

normalize_notify_types() {
    local raw="$1"
    local result="" item canonical
    local -a _code_notify_raw_types=()

    IFS='|' read -r -a _code_notify_raw_types <<< "$raw"
    for item in "${_code_notify_raw_types[@]}"; do
        canonical="$(normalize_alert_type "$item" 2>/dev/null || true)"
        [[ -n "$canonical" ]] || continue
        result="$(append_unique_notify_type "$result" "$canonical")"
    done

    if [[ -z "$result" ]]; then
        result="$DEFAULT_NOTIFY_TYPE"
    fi

    printf '%s\n' "$result"
}

# Set notification types
set_notify_types() {
    local types="$1"
    mkdir -p "$(dirname "$NOTIFY_TYPES_FILE")"
    normalize_notify_types "$types" > "$NOTIFY_TYPES_FILE"
}

# Add a notification type
add_notify_type() {
    local type
    type="$(normalize_alert_type "$1")" || return 1
    local current=$(get_notify_types)

    if is_notify_type_enabled "$type"; then
        return 0  # Already exists
    fi

    set_notify_types "$(append_unique_notify_type "$current" "$type")"
}

# Remove a notification type
remove_notify_type() {
    local type
    type="$(normalize_alert_type "$1")" || return 1
    local current=$(get_notify_types)
    local new_types="" item
    local -a _code_notify_types=()

    IFS='|' read -r -a _code_notify_types <<< "$current"
    for item in "${_code_notify_types[@]}"; do
        [[ "$item" != "$type" ]] || continue
        new_types="$(append_unique_notify_type "$new_types" "$item")"
    done

    if [[ -z "$new_types" ]]; then
        new_types="$DEFAULT_NOTIFY_TYPE"
    fi

    set_notify_types "$new_types"
}

# Check if a notification type is enabled
is_notify_type_enabled() {
    local type item
    type="$(normalize_alert_type "$1" 2>/dev/null || true)"
    [[ -n "$type" ]] || return 1
    local current=$(get_notify_types)
    local -a _code_notify_types=()

    IFS='|' read -r -a _code_notify_types <<< "$current"
    for item in "${_code_notify_types[@]}"; do
        [[ "$item" == "$type" ]] && return 0
    done

    return 1
}

# Reset to default notification type
reset_notify_types() {
    set_notify_types "$DEFAULT_NOTIFY_TYPE"
}

# Get matcher pattern for current notification types
get_notify_matcher() {
    # Claude permission alerts use PermissionRequest instead of Notification.
    # The latter is UI-dispatched and is delayed while Ctrl+O verbose output is
    # open. Other agents still read the full type list directly where needed.
    local current result="" item
    current="$(get_notification_alert_types)"
    local -a _code_notify_types=()

    IFS='|' read -r -a _code_notify_types <<< "$current"
    for item in "${_code_notify_types[@]}"; do
        [[ "$item" != "permission_prompt" ]] || continue
        result="$(append_unique_notify_type "$result" "$item")"
    done

    printf '%s\n' "$result"
}

get_notification_alert_types() {
    local current result="" item
    current="$(get_notify_types)"
    local -a _code_notify_types=()

    IFS='|' read -r -a _code_notify_types <<< "$current"
    for item in "${_code_notify_types[@]}"; do
        if is_notification_alert_type "$item"; then
            result="$(append_unique_notify_type "$result" "$item")"
        fi
    done

    printf '%s\n' "$result"
}

get_claude_event_alert_types() {
    local current result="" item
    current="$(get_notify_types)"
    local -a _code_notify_types=()

    IFS='|' read -r -a _code_notify_types <<< "$current"
    for item in "${_code_notify_types[@]}"; do
        if is_claude_event_alert_type "$item"; then
            result="$(append_unique_notify_type "$result" "$item")"
        fi
    done

    printf '%s\n' "$result"
}

# Retirement events are state signals even when their optional toasts are
# disabled. The notifier gates delivery at runtime.
get_claude_event_hook_types() {
    local result
    result="$(get_claude_event_alert_types)"
    result="$(append_unique_notify_type "$result" "SubagentStop")"
    result="$(append_unique_notify_type "$result" "TeammateIdle")"
    printf '%s\n' "$result"
}
