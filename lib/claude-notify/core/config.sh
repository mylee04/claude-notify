#!/bin/bash

# Configuration management for Claude-Notify

# Default paths
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GLOBAL_SETTINGS_FILE="$CLAUDE_HOME/settings.json"
GLOBAL_HOOKS_FILE="$CLAUDE_HOME/hooks.json"  # Legacy support
GLOBAL_HOOKS_DISABLED="$CLAUDE_HOME/hooks.json.disabled"
CONFIG_DIR="$HOME/.config/claude-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

# Project-level settings
PROJECT_SETTINGS_FILE=".claude/settings.json"
PROJECT_SETTINGS_LOCAL_FILE=".claude/settings.local.json"

# Ensure config directory exists
ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
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
    if [[ -f "$GLOBAL_SETTINGS_FILE" ]] && command -v jq &> /dev/null; then
        jq -e '.hooks != null and .hooks != {}' "$GLOBAL_SETTINGS_FILE" &>/dev/null
        return $?
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
    if [[ -f "/usr/local/opt/claude-notify/lib/claude-notify/core/notifier.sh" ]]; then
        echo "/usr/local/opt/claude-notify/lib/claude-notify/core/notifier.sh"
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
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    # Basic JSON validation
    if command -v jq &> /dev/null; then
        jq empty "$file" 2>/dev/null
        return $?
    else
        # Fallback: just check if file contains "hooks"
        grep -q '"hooks"' "$file"
        return $?
    fi
}

# Get current configuration status
get_status_info() {
    local status_info=""
    
    # Global status
    if is_enabled_globally; then
        status_info="${status_info}${BELL} Global notifications: ${GREEN}ENABLED${RESET}\n"
        # Check which config file is being used
        if [[ -f "$GLOBAL_SETTINGS_FILE" ]] && command -v jq &> /dev/null && jq -e '.hooks != null' "$GLOBAL_SETTINGS_FILE" &>/dev/null; then
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
    
    # Read existing settings or create new
    local settings="{}"
    if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
        settings=$(cat "$GLOBAL_SETTINGS_FILE")
    fi
    
    # Add hooks using jq if available
    if command -v jq &> /dev/null; then
        settings=$(echo "$settings" | jq --arg script "$notify_script" '.hooks = {
            "Notification": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": ($script + " notification")
                }]
            }],
            "Stop": [{
                "matcher": "",
                "hooks": [{
                    "type": "command",
                    "command": ($script + " stop")
                }]
            }],
            "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{
                    "type": "command",
                    "command": ($script + " PreToolUse")
                }]
            }]
        }')
        echo "$settings" > "$GLOBAL_SETTINGS_FILE"
    else
        # Manual JSON construction without jq
        cat > "$GLOBAL_SETTINGS_FILE" << EOF
{
  "model": "opus",
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script notification"
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
            "command": "$notify_script stop"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script PreToolUse"
          }
        ]
      }
    ]
  }
}
EOF
    fi
}

# Disable hooks in settings.json (new format)
disable_hooks_in_settings() {
    if [[ ! -f "$GLOBAL_SETTINGS_FILE" ]]; then
        return 0
    fi
    
    # Remove hooks using jq if available
    if command -v jq &> /dev/null; then
        local settings=$(cat "$GLOBAL_SETTINGS_FILE")
        echo "$settings" | jq 'del(.hooks)' > "$GLOBAL_SETTINGS_FILE"
    else
        # Manual removal - just keep model setting
        if grep -q '"model"' "$GLOBAL_SETTINGS_FILE"; then
            echo '{"model": "opus"}' > "$GLOBAL_SETTINGS_FILE"
        else
            echo '{}' > "$GLOBAL_SETTINGS_FILE"
        fi
    fi
}

# Enable hooks in project settings.json
enable_project_hooks_in_settings() {
    local project_root="${1:-$(get_project_root)}"
    local project_name="${2:-$(get_project_name)}"
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    local notify_script=$(get_notify_script)
    
    # Ensure .claude directory exists
    mkdir -p "$project_root/.claude"
    
    # Create project settings.json with hooks
    cat > "$project_settings" << EOF
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script notification required '$project_name'"
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
            "command": "$notify_script stop completed '$project_name'"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$notify_script PreToolUse"
          }
        ]
      }
    ]
  }
}
EOF
}

# Check if project has settings.json with hooks
is_enabled_project_settings() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_settings="$project_root/$PROJECT_SETTINGS_FILE"
    
    if [[ -f "$project_settings" ]] && command -v jq &> /dev/null; then
        jq -e '.hooks != null and .hooks != {}' "$project_settings" &>/dev/null
        return $?
    fi
    return 1
}