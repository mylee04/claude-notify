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

# Gemini CLI paths
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
GEMINI_SETTINGS_FILE="$GEMINI_HOME/settings.json"

# Oh My Pi (omp) paths
OMP_HOME="${OMP_HOME:-$HOME/.omp}"
OMP_EXTENSIONS_DIR="${OMP_EXTENSIONS_DIR:-$OMP_HOME/agent/extensions}"
OMP_EXTENSION_FILE="$OMP_EXTENSIONS_DIR/code-notify.js"
OMP_EXTENSION_MARKER="code-notify: managed omp extension"

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

get_global_claude_pre_tool_use_command() {
    printf '%s PreToolUse claude\n' "$(get_notify_script)"
}

get_project_claude_pre_tool_use_command() {
    local project_name="$1"
    printf '%s PreToolUse claude %s\n' "$(shell_quote "$(get_notify_script)")" "$(shell_quote "$project_name")"
}

get_managed_claude_event_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(SubagentStart|SubagentStop|TeammateIdle|TaskCreated|TaskCompleted)(?:\s|$)'
}

get_managed_claude_pre_tool_use_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*PreToolUse(?:\s|$)'
}

get_managed_claude_notification_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(notification|PreToolUse)(?:\s|$)'
}

get_managed_claude_stop_pattern() {
    printf '%s\n' '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*stop(?:\s|$)'
}

has_claude_hooks_for_commands() {
    local file="$1"
    local matcher notify_cmd stop_cmd event_prefix event_suffix event_types
    matcher="$2"
    notify_cmd="$3"
    stop_cmd="$4"
    event_prefix="${5:-}"
    event_suffix="${6:-}"
    event_types="$(get_claude_event_alert_types)"

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

has_current_global_claude_hooks() {
    local file="$1"
    has_claude_hooks_for_commands \
        "$file" \
        "$(get_notify_matcher)" \
        "$(get_global_claude_notify_command)" \
        "$(get_global_claude_stop_command)" \
        "$(get_notify_script) " \
        " claude"
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
        " claude $(shell_quote "$project_name")"
}

has_legacy_global_claude_hooks() {
    local file="${1:-$GLOBAL_SETTINGS_FILE}"

    if [[ ! -f "$file" ]]; then
        return 1
    fi

    grep -q 'claude-notify' "$file" ||
        grep -qE 'notifier\.sh (notification|stop)"' "$file" ||
        grep -q 'notifier.sh PreToolUse' "$file" ||
        grep -qE 'notify\.ps1.* (notification|stop)"' "$file" ||
        grep -qE 'notify\.ps1.* PreToolUse' "$file"
}

claude_global_hooks_need_repair() {
    has_legacy_global_claude_hooks "$GLOBAL_SETTINGS_FILE"
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

# Check for an installed Code-Notify Claude hook without requiring its
# Notification matcher to match the current alert-type configuration. This is
# used when alert types change, because the matcher is stale until it is
# rewritten.
has_managed_global_claude_hooks() {
    local file="${1:-$GLOBAL_SETTINGS_FILE}"
    local stop_cmd
    stop_cmd="$(get_global_claude_stop_command)"

    if [[ -f "$file" ]]; then
        if has_jq; then
            jq -e --arg cmd "$stop_cmd" '
                any(.hooks.Stop[]?.hooks[]?;
                    (.type // "") == "command" and (.command // "") == $cmd
                )
            ' "$file" >/dev/null 2>&1 && return 0
        elif has_python3; then
            python3 - "$file" "$stop_cmd" <<'PYTHON' >/dev/null 2>&1 && return 0
import json
import sys

file_path, stop_cmd = sys.argv[1:3]
with open(file_path, "r") as fh:
    settings = json.load(fh)

for entry in settings.get("hooks", {}).get("Stop", []):
    for hook in entry.get("hooks", []):
        if hook.get("type") == "command" and hook.get("command") == stop_cmd:
            raise SystemExit(0)

raise SystemExit(1)
PYTHON
        else
            grep -qF "\"command\": \"$stop_cmd\"" "$file" && return 0
        fi
    fi

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
    event_types="$(get_claude_event_alert_types)"

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
        " claude"

    # Register PreToolUse hook for AskUserQuestion if ask_user alert type is enabled
    register_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"
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
        " claude"

    # Remove PreToolUse hook for AskUserQuestion
    unregister_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"
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
        " claude $(shell_quote "$project_name")"

    # Remove PreToolUse hook for AskUserQuestion
    unregister_ask_user_hook "$project_settings" "$(get_project_claude_pre_tool_use_command "$project_name")"
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
        " claude $(shell_quote "$project_name")"

    # Register PreToolUse hook for AskUserQuestion if ask_user alert type is enabled
    register_ask_user_hook "$project_settings" "$(get_project_claude_pre_tool_use_command "$project_name")"
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

# Check if Codex notifications are enabled
is_codex_enabled() {
    toml_has_top_level_key "$CODEX_CONFIG_FILE" "notify"
}

# Enable Codex notifications
enable_codex_hooks() {
    local notify_script=$(get_notify_script)
    local escaped_notify_script
    local notify_line

    # Ensure .codex directory exists
    mkdir -p "$CODEX_HOME"

    escaped_notify_script=$(toml_escape_string "$notify_script")
    notify_line="notify = [\"$escaped_notify_script\", \"codex\"]"

    # Check if config.toml exists
    if [[ -f "$CODEX_CONFIG_FILE" ]]; then
        # Backup existing config
        backup_config "$CODEX_CONFIG_FILE"

        upsert_codex_notify_config "$CODEX_CONFIG_FILE" "$notify_line"
    else
        # Create new config.toml
        cat > "$CODEX_CONFIG_FILE" << EOF
# Codex CLI Configuration
# https://developers.openai.com/codex/config-reference/

# Code-Notify: Desktop notifications
notify = ["$escaped_notify_script", "codex"]
EOF
    fi
}

# Disable Codex notifications
disable_codex_hooks() {
    if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
        return 0
    fi

    # Backup before modifying
    backup_config "$CODEX_CONFIG_FILE"

    # Remove notify line and comment (BSD sed compatible)
    sed -i '' '/^# Code-Notify/d' "$CODEX_CONFIG_FILE" 2>/dev/null || sed -i '/^# Code-Notify/d' "$CODEX_CONFIG_FILE"
    sed -i '' '/^notify.*=/d' "$CODEX_CONFIG_FILE" 2>/dev/null || sed -i '/^notify.*=/d' "$CODEX_CONFIG_FILE"
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
# Oh My Pi (omp) integration
# ============================================
# omp loads JS/TS extension modules from ~/.omp/agent/extensions instead of
# reading hook commands from a config file. So enabling = writing a managed
# extension that forwards omp's agent_end event to notifier.sh; disabling =
# removing that file. All downstream delivery (sound, voice, channels,
# click-through, kill switch, rate limiting) is reused through notifier.sh.

# Generate the omp extension module that forwards completion events to the notifier
generate_omp_extension() {
    local notify_script="$1"
    # Escape backslashes and double quotes for safe embedding in the JS string literal
    notify_script="${notify_script//\\/\\\\}"
    notify_script="${notify_script//\"/\\\"}"
    cat << EOF
// ${OMP_EXTENSION_MARKER}
// Created by \`cn on omp\`; removed by \`cn off omp\`. Do not edit -- regenerated on enable.
// omp (Oh My Pi) loads extension modules instead of config-file hooks, so this
// file forwards the "agent finished" event to code-notify's notifier.
const NOTIFIER = "${notify_script}";

export default function codeNotify(pi) {
  pi.on("agent_end", async (event, ctx) => {
    // Only ping the top-level interactive session; skip subagents/headless runs
    // unless OMP_NOTIFY_ALL=1 is set.
    if (!ctx.hasUI && process.env.OMP_NOTIFY_ALL !== "1") return;
    // Map the final stop reason to the notifier hook type so a failed run produces an
    // error notification instead of a false success. Scan back to the last assistant
    // turn: the array can end in a tool-result or custom (bash/compaction) message
    // that would otherwise mask the outcome.
    const messages = Array.isArray(event?.messages) ? event.messages : [];
    let reason;
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i] && messages[i].role === "assistant") { reason = messages[i].stopReason; break; }
    }
    const hook = (reason === "error" || reason === "aborted" || reason === "length")
      ? "error" : "stop";
    try {
      // Pass the project name via cwd so the notifier derives it from basename(\$PWD),
      // keeping the notification scoped globally (not project-scoped) so that
      // \`cn off\` / the global kill switch correctly suppresses it.
      await pi.exec(NOTIFIER, [hook, "omp"], { timeout: 5000, cwd: ctx.cwd || undefined });
    } catch (err) {
      // Never let notification failures disrupt the session.
      pi.logger?.debug?.(\`code-notify: notifier exec failed: \${err}\`);
    }
  });
}
EOF
}

# Check if omp notifications are enabled
is_omp_enabled() {
    [[ -f "$OMP_EXTENSION_FILE" ]] && grep -q "$OMP_EXTENSION_MARKER" "$OMP_EXTENSION_FILE" 2>/dev/null
}

# Enable omp notifications by writing a managed extension module
enable_omp_hooks() {
    local notify_script
    notify_script="$(get_notify_script)"

    # Refuse to overwrite a file we didn't create (consistent with disable_omp_hooks which
    # preserves non-managed files). Check before creating any dirs so a refused enable
    # leaves the filesystem untouched.
    if [[ -f "$OMP_EXTENSION_FILE" ]] && ! grep -q "$OMP_EXTENSION_MARKER" "$OMP_EXTENSION_FILE" 2>/dev/null; then
        error "Refusing to overwrite existing non-code-notify extension: $OMP_EXTENSION_FILE"
        info "Remove or rename that file manually, then run \`cn on omp\` again."
        return 1
    fi

    mkdir -p "$OMP_EXTENSIONS_DIR"
    atomic_write "$OMP_EXTENSION_FILE" "$(generate_omp_extension "$notify_script")"
}

# Disable omp notifications by removing our managed extension module
disable_omp_hooks() {
    if [[ ! -f "$OMP_EXTENSION_FILE" ]]; then
        return 0
    fi

    # Only remove our own managed file. Never touch ~/.omp/agent or its subdirs --
    # that is omp's data directory (agent.db, sessions, config.yml, ...), not ours.
    if grep -q "$OMP_EXTENSION_MARKER" "$OMP_EXTENSION_FILE" 2>/dev/null; then
        rm -f "$OMP_EXTENSION_FILE"
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
        "omp")
            enable_omp_hooks
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
        "omp")
            disable_omp_hooks
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
        "omp")
            is_omp_enabled
            ;;
        *)
            return 1
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
    get_notification_alert_types
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
