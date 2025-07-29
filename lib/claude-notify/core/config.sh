#!/bin/bash

# Configuration management for Claude-Notify

# Default paths
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
GLOBAL_HOOKS_FILE="$CLAUDE_HOME/hooks.json"
GLOBAL_HOOKS_DISABLED="$CLAUDE_HOME/hooks.json.disabled"
CONFIG_DIR="$HOME/.config/claude-notify"
CONFIG_FILE="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backups"

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
    [[ -f "$GLOBAL_HOOKS_FILE" ]]
}

# Check if notifications are enabled for current project
is_enabled_project() {
    local project_root=$(get_project_root 2>/dev/null || echo "$PWD")
    local project_hooks="$project_root/.claude/hooks.json"
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
        status_info="${status_info}   Config: $GLOBAL_HOOKS_FILE\n"
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
        status_info="${status_info}   Config: $project_root/.claude/hooks.json\n"
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