#!/bin/bash

# Voice notification utilities for Claude-Notify

# Voice configuration paths
GLOBAL_VOICE_FILE="$HOME/.claude/notifications/voice-enabled"

# Get project-specific voice file path
get_project_voice_file() {
    local project_root="${1:-$(get_project_root 2>/dev/null || echo "$PWD")}"
    echo "$project_root/.claude/voice"
}

# Enable voice notifications
enable_voice() {
    local voice="${1:-Samantha}"
    local scope="${2:-global}"
    local project_root="${3:-}"

    if [[ "$scope" == "project" ]] && [[ -n "$project_root" ]]; then
        mkdir -p "$project_root/.claude"
        echo "$voice" > "$(get_project_voice_file "$project_root")"
    else
        mkdir -p "$(dirname "$GLOBAL_VOICE_FILE")"
        echo "$voice" > "$GLOBAL_VOICE_FILE"
    fi
}

# Disable voice notifications
disable_voice() {
    local scope="${1:-global}"
    local project_root="${2:-}"

    if [[ "$scope" == "project" ]] && [[ -n "$project_root" ]]; then
        rm -f "$(get_project_voice_file "$project_root")"
    else
        rm -f "$GLOBAL_VOICE_FILE"
    fi
}

# Get current voice setting
get_voice() {
    local scope="${1:-global}"
    local project_root="${2:-}"

    if [[ "$scope" == "project" ]] && [[ -n "$project_root" ]]; then
        local project_voice_file
        project_voice_file="$(get_project_voice_file "$project_root")"
        if [[ -f "$project_voice_file" ]]; then
            cat "$project_voice_file"
            return 0
        fi
    fi

    # Check global voice
    if [[ -f "$GLOBAL_VOICE_FILE" ]]; then
        cat "$GLOBAL_VOICE_FILE"
        return 0
    fi

    return 1
}

# Check if voice is enabled
is_voice_enabled() {
    local scope="${1:-global}"
    local project_root="${2:-}"

    if [[ "$scope" == "project" ]] && [[ -n "$project_root" ]]; then
        [[ -f "$(get_project_voice_file "$project_root")" ]]
    else
        [[ -f "$GLOBAL_VOICE_FILE" ]]
    fi
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
    say -v "$voice" "$message" &
}
