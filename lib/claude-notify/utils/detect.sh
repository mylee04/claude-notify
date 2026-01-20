#!/bin/bash

# Environment detection utilities

# Detect Claude Code installation
detect_claude_code() {
    # Check common locations for Claude hooks
    local possible_locations=(
        "$HOME/.claude"
        "$HOME/.config/claude"
        "/usr/local/claude"
        "/opt/claude"
    )
    
    for location in "${possible_locations[@]}"; do
        if [[ -d "$location" ]]; then
            echo "$location"
            return 0
        fi
    done
    
    return 1
}

# Detect if terminal-notifier is installed (macOS)
detect_terminal_notifier() {
    if command -v terminal-notifier &> /dev/null; then
        echo "$(which terminal-notifier)"
        return 0
    fi
    return 1
}

# Detect if wsl-notify-send.exe is installed (WSL)
detect_wsl_notify_send() {
    if command -v wsl-notify-send.exe &> /dev/null; then
        echo "$(which wsl-notify-send.exe)"
        return 0
    fi
    return 1
}

# Detect user's shell
detect_shell() {
    local shell_name=$(basename "$SHELL")
    echo "$shell_name"
}

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            echo "macos"
            ;;
        Linux*)
            echo "linux"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Check if we're in a git repository
is_git_repo() {
    git rev-parse --git-dir &> /dev/null
}

# Get project name
get_project_name() {
    if is_git_repo; then
        basename "$(git rev-parse --show-toplevel)"
    else
        basename "$PWD"
    fi
}

# Get project root
get_project_root() {
    if is_git_repo; then
        git rev-parse --show-toplevel
    else
        echo "$PWD"
    fi
}

# Check if running in Claude Code environment
is_claude_code_env() {
    # Check for Claude Code specific environment variables
    [[ -n "$CLAUDE_CODE_SESSION" ]] || [[ -n "$CLAUDE_HOOK_TYPE" ]]
}