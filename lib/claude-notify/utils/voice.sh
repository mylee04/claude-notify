#!/bin/bash

# Voice notification utilities for Code-Notify

# Voice configuration paths
VOICE_DIR="$HOME/.claude/notifications"
GLOBAL_VOICE_FILE="$VOICE_DIR/voice-enabled"

# Get tool-specific voice file path
get_tool_voice_file() {
    local tool="$1"
    echo "$VOICE_DIR/voice-$tool"
}

# Get project-specific voice file path
get_project_voice_file() {
    local project_root="${1:-$(get_project_root 2>/dev/null || echo "$PWD")}"
    echo "$project_root/.claude/voice"
}

# Enable voice notifications
# Usage: enable_voice <voice> <scope> [tool_or_project_root]
# Scope: "global", "tool", "project"
enable_voice() {
    local voice="${1:-Samantha}"
    local scope="${2:-global}"
    local target="${3:-}"

    mkdir -p "$VOICE_DIR"

    case "$scope" in
        "tool")
            if [[ -n "$target" ]]; then
                echo "$voice" > "$(get_tool_voice_file "$target")"
            fi
            ;;
        "project")
            if [[ -n "$target" ]]; then
                mkdir -p "$target/.claude"
                echo "$voice" > "$(get_project_voice_file "$target")"
            fi
            ;;
        "global"|*)
            echo "$voice" > "$GLOBAL_VOICE_FILE"
            ;;
    esac
}

# Disable voice notifications
# Usage: disable_voice <scope> [tool_or_project_root]
disable_voice() {
    local scope="${1:-global}"
    local target="${2:-}"

    case "$scope" in
        "tool")
            if [[ -n "$target" ]]; then
                rm -f "$(get_tool_voice_file "$target")"
            fi
            ;;
        "project")
            if [[ -n "$target" ]]; then
                rm -f "$(get_project_voice_file "$target")"
            fi
            ;;
        "all")
            # Disable all voice settings
            rm -f "$GLOBAL_VOICE_FILE"
            rm -f "$VOICE_DIR/voice-claude"
            rm -f "$VOICE_DIR/voice-codex"
            rm -f "$VOICE_DIR/voice-gemini"
            ;;
        "global"|*)
            rm -f "$GLOBAL_VOICE_FILE"
            ;;
    esac
}

# Get current voice setting
# Usage: get_voice <scope> [tool_or_project_root]
get_voice() {
    local scope="${1:-global}"
    local target="${2:-}"

    case "$scope" in
        "tool")
            if [[ -n "$target" ]]; then
                local tool_voice_file
                tool_voice_file="$(get_tool_voice_file "$target")"
                if [[ -f "$tool_voice_file" ]]; then
                    cat "$tool_voice_file"
                    return 0
                fi
            fi
            ;;
        "project")
            if [[ -n "$target" ]]; then
                local project_voice_file
                project_voice_file="$(get_project_voice_file "$target")"
                if [[ -f "$project_voice_file" ]]; then
                    cat "$project_voice_file"
                    return 0
                fi
            fi
            ;;
    esac

    # Fall back to global
    if [[ -f "$GLOBAL_VOICE_FILE" ]]; then
        cat "$GLOBAL_VOICE_FILE"
        return 0
    fi

    return 1
}

# Check if voice is enabled
# Usage: is_voice_enabled <scope> [tool_or_project_root]
is_voice_enabled() {
    local scope="${1:-global}"
    local target="${2:-}"

    case "$scope" in
        "tool")
            if [[ -n "$target" ]]; then
                [[ -f "$(get_tool_voice_file "$target")" ]]
                return $?
            fi
            ;;
        "project")
            if [[ -n "$target" ]]; then
                [[ -f "$(get_project_voice_file "$target")" ]]
                return $?
            fi
            ;;
        "any")
            # Check if any voice is enabled (global or any tool)
            [[ -f "$GLOBAL_VOICE_FILE" ]] || \
            [[ -f "$VOICE_DIR/voice-claude" ]] || \
            [[ -f "$VOICE_DIR/voice-codex" ]] || \
            [[ -f "$VOICE_DIR/voice-gemini" ]]
            return $?
            ;;
        "global"|*)
            [[ -f "$GLOBAL_VOICE_FILE" ]]
            return $?
            ;;
    esac

    return 1
}

# Enable voice for all tools
enable_voice_all() {
    local voice="${1:-Samantha}"
    mkdir -p "$VOICE_DIR"
    echo "$voice" > "$GLOBAL_VOICE_FILE"
}

# Get voice status for all tools (for display)
get_voice_status() {
    local status=""

    # Global
    if [[ -f "$GLOBAL_VOICE_FILE" ]]; then
        local voice=$(cat "$GLOBAL_VOICE_FILE")
        status="${status}global:$voice "
    fi

    # Per-tool
    for tool in claude codex gemini; do
        local tool_file="$VOICE_DIR/voice-$tool"
        if [[ -f "$tool_file" ]]; then
            local voice=$(cat "$tool_file")
            status="${status}$tool:$voice "
        fi
    done

    echo "$status"
}

# List available voices (macOS only)
list_available_voices() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "Voice notifications are only available on macOS" >&2
        return 1
    fi
    say -v ? | grep "en_" | head -10 | awk '{print $1}'
}

# Test voice
test_voice() {
    local voice="${1:-Samantha}"
    local message="${2:-Voice notifications enabled}"

    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "Voice notifications are only available on macOS" >&2
        return 1
    fi
    say -v "$voice" "$message"
}
