#!/bin/bash

# Configuration management for Code-Notify

# Default paths - Claude Code
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GLOBAL_SETTINGS_FILE="$CLAUDE_HOME/settings.json"
GLOBAL_HOOKS_FILE="$CLAUDE_HOME/hooks.json"  # Legacy support
GLOBAL_HOOKS_DISABLED="$CLAUDE_HOME/hooks.json.disabled"
CONFIG_DIR="$HOME/.config/code-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

# Project-level settings
PROJECT_SETTINGS_FILE=".claude/settings.json"
PROJECT_SETTINGS_LOCAL_FILE=".claude/settings.local.json"

# Notification types configuration
NOTIFY_TYPES_FILE="$HOME/.claude/notifications/notify-types"
DEFAULT_NOTIFY_TYPE="idle_prompt"

# Available notification types:
# - idle_prompt: AI is waiting for user input (after 60+ seconds idle)
# - permission_prompt: AI needs permission to use a tool
# - auth_success: Authentication success notifications
# - elicitation_dialog: MCP tool input needed

# Codex paths
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG_FILE="$CODEX_HOME/config.toml"

# Gemini CLI paths
GEMINI_HOME="${GEMINI_HOME:-$HOME/.gemini}"
GEMINI_SETTINGS_FILE="$GEMINI_HOME/settings.json"

# Ensure config directory exists
ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
}

# --- JSON Helper Functions ---

# Check if jq is available
has_jq() {
    command -v jq &> /dev/null
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

# Check if file has code-notify specific hooks (Notification or Stop)
has_claude_notify_hooks() {
    local file="$1"
    json_has "$file" '(.hooks.Notification != null) or (.hooks.Stop != null)' '"(Notification|Stop)"'
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
    if has_claude_notify_hooks "$GLOBAL_SETTINGS_FILE"; then
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
        local backup_name="$(basename "$file").$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$BACKUP_DIR/$backup_name"
        return 0
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
enable_hooks_in_settings() {
    local notify_script=$(get_notify_script)
    local notify_matcher=$(get_notify_matcher)

    # Ensure .claude directory exists
    mkdir -p "$(dirname "$GLOBAL_SETTINGS_FILE")"

    # Read existing settings or create new
    local settings="{}"
    if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
        settings=$(cat "$GLOBAL_SETTINGS_FILE")
    fi

    # Add hooks using jq (preferred) or python (fallback)
    if has_jq; then
        settings=$(echo "$settings" | jq --arg script "$notify_script" --arg matcher "$notify_matcher" '.hooks = {
            "Notification": [{
                "matcher": $matcher,
                "hooks": [{
                    "type": "command",
                    "command": ($script + " notification claude")
                }]
            }],
            "Stop": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": ($script + " stop claude")
                }]
            }]
        }')
        echo "$settings" > "$GLOBAL_SETTINGS_FILE"
    elif command -v python3 &> /dev/null; then
        # Use Python as fallback (available on most systems)
        # Pass JSON via stdin using echo and pipe
        echo "$settings" | python3 -c "
import sys
import json

script = '$notify_script'
matcher = '$notify_matcher'
settings = json.load(sys.stdin)

settings['hooks'] = {
    'Notification': [{
        'matcher': matcher,
        'hooks': [{'type': 'command', 'command': f'{script} notification claude'}]
    }],
    'Stop': [{
        'matcher': '',
        'hooks': [{'type': 'command', 'command': f'{script} stop claude'}]
    }]
}

print(json.dumps(settings, indent=2))
" > "$GLOBAL_SETTINGS_FILE"
    else
        # No jq or python - abort to avoid data loss
        echo "Error: jq or python3 required for config preservation" >&2
        echo "Install jq: brew install jq" >&2
        return 1
    fi
}

# Disable hooks in settings.json (new format)
disable_hooks_in_settings() {
    if [[ ! -f "$GLOBAL_SETTINGS_FILE" ]]; then
        return 0
    fi

    # Remove hooks using jq (preferred) or python (fallback)
    if has_jq; then
        local settings=$(cat "$GLOBAL_SETTINGS_FILE")
        local new_settings=$(echo "$settings" | jq 'del(.hooks)')
        # Only write if there's actual content left (not just {})
        if [[ "$new_settings" != "{}" ]]; then
            echo "$new_settings" > "$GLOBAL_SETTINGS_FILE"
        else
            # File would be empty, just remove it
            rm -f "$GLOBAL_SETTINGS_FILE"
        fi
    elif command -v python3 &> /dev/null; then
        python3 - "$GLOBAL_SETTINGS_FILE" << 'PYTHON'
import sys
import json
import os

file_path = sys.argv[1]
with open(file_path, 'r') as f:
    settings = json.load(f)

if 'hooks' in settings:
    del settings['hooks']

if settings:
    with open(file_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
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

# Enable hooks in project settings.json
enable_project_hooks_in_settings() {
    local project_root="${1:-$(get_project_root)}"
    local project_name="${2:-$(get_project_name)}"
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    local notify_script=$(get_notify_script)
    local notify_matcher=$(get_notify_matcher)

    # Ensure .claude directory exists
    mkdir -p "$project_root/.claude"

    # Create project settings.json with hooks
    cat > "$project_settings" << EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "$notify_matcher",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script notification claude '$project_name'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script stop claude '$project_name'"
          }
        ]
      }
    ]
  }
}
EOF
}

# Check if project has settings.json with code-notify hooks
is_enabled_project_settings() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    has_claude_notify_hooks "$project_settings"
}

# ============================================
# Codex Configuration
# ============================================

# Check if Codex notifications are enabled
is_codex_enabled() {
    if [[ ! -f "$CODEX_CONFIG_FILE" ]]; then
        return 1
    fi
    grep -qE '^notify\s*=' "$CODEX_CONFIG_FILE" 2>/dev/null
}

# Enable Codex notifications
enable_codex_hooks() {
    local notify_script=$(get_notify_script)

    # Ensure .codex directory exists
    mkdir -p "$CODEX_HOME"

    # Check if config.toml exists
    if [[ -f "$CODEX_CONFIG_FILE" ]]; then
        # Backup existing config
        backup_config "$CODEX_CONFIG_FILE"

        # Remove existing notify line if present
        if grep -qE '^notify\s*=' "$CODEX_CONFIG_FILE"; then
            sed -i.bak '/^notify\s*=/d' "$CODEX_CONFIG_FILE"
            rm -f "$CODEX_CONFIG_FILE.bak"
        fi

        # Append notify setting
        echo "" >> "$CODEX_CONFIG_FILE"
        echo "# Code-Notify: Desktop notifications" >> "$CODEX_CONFIG_FILE"
        echo "notify = [\"bash\", \"-c\", \"$notify_script stop codex\"]" >> "$CODEX_CONFIG_FILE"
    else
        # Create new config.toml
        cat > "$CODEX_CONFIG_FILE" << EOF
# Codex CLI Configuration
# https://developers.openai.com/codex/config-reference/

# Code-Notify: Desktop notifications
notify = ["bash", "-c", "$notify_script stop codex"]
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

    # Read existing settings or create new
    local settings="{}"
    if [[ -f "$GEMINI_SETTINGS_FILE" ]]; then
        backup_config "$GEMINI_SETTINGS_FILE"
        settings=$(cat "$GEMINI_SETTINGS_FILE")
    fi

    if has_jq; then
        # Use jq to merge settings
        settings=$(echo "$settings" | jq --arg script "$notify_script" '
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
        ')
        echo "$settings" > "$GEMINI_SETTINGS_FILE"
    else
        # Manual JSON construction without jq
        cat > "$GEMINI_SETTINGS_FILE" << EOF
{
  "tools": {
    "enableHooks": true
  },
  "hooks": {
    "enabled": true,
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "name": "code-notify-notification",
            "type": "command",
            "command": "$notify_script notification gemini",
            "description": "Desktop notification when input needed"
          }
        ]
      }
    ],
    "AfterAgent": [
      {
        "matcher": "",
        "hooks": [
          {
            "name": "code-notify-complete",
            "type": "command",
            "command": "$notify_script stop gemini",
            "description": "Desktop notification when task complete"
          }
        ]
      }
    ]
  }
}
EOF
    fi
}

# Disable Gemini CLI notifications
disable_gemini_hooks() {
    if [[ ! -f "$GEMINI_SETTINGS_FILE" ]]; then
        return 0
    fi

    backup_config "$GEMINI_SETTINGS_FILE"

    if has_jq; then
        local settings=$(cat "$GEMINI_SETTINGS_FILE")
        # Remove code-notify specific hooks but preserve other settings
        local new_settings=$(echo "$settings" | jq 'del(.hooks.Notification) | del(.hooks.AfterAgent) | del(.hooks.enabled)')
        # If hooks object is now empty, remove it entirely
        new_settings=$(echo "$new_settings" | jq 'if .hooks == {} then del(.hooks) else . end')
        if [[ "$new_settings" != "{}" ]]; then
            echo "$new_settings" > "$GEMINI_SETTINGS_FILE"
        else
            rm -f "$GEMINI_SETTINGS_FILE"
        fi
    elif command -v python3 &> /dev/null; then
        python3 - "$GEMINI_SETTINGS_FILE" << 'PYTHON'
import sys
import json
import os

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
    with open(file_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
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
        cat "$NOTIFY_TYPES_FILE"
    else
        echo "$DEFAULT_NOTIFY_TYPE"
    fi
}

# Set notification types
set_notify_types() {
    local types="$1"
    mkdir -p "$(dirname "$NOTIFY_TYPES_FILE")"
    echo "$types" > "$NOTIFY_TYPES_FILE"
}

# Add a notification type
add_notify_type() {
    local type="$1"
    local current=$(get_notify_types)

    if [[ "$current" == *"$type"* ]]; then
        return 0  # Already exists
    fi

    if [[ -z "$current" ]]; then
        set_notify_types "$type"
    else
        set_notify_types "$current|$type"
    fi
}

# Remove a notification type
remove_notify_type() {
    local type="$1"
    local current=$(get_notify_types)

    # Remove the type (handle edge cases)
    local new_types=$(echo "$current" | sed "s/|$type//g; s/$type|//g; s/^$type$//g")

    if [[ -z "$new_types" ]]; then
        new_types="$DEFAULT_NOTIFY_TYPE"
    fi

    set_notify_types "$new_types"
}

# Check if a notification type is enabled
is_notify_type_enabled() {
    local type="$1"
    local current=$(get_notify_types)
    [[ "$current" == *"$type"* ]]
}

# Reset to default notification type
reset_notify_types() {
    set_notify_types "$DEFAULT_NOTIFY_TYPE"
}

# Get matcher pattern for current notification types
get_notify_matcher() {
    get_notify_types
}