#!/bin/bash

# Sound notification utilities for Code-Notify

# Sound configuration paths
SOUND_DIR="$HOME/.claude/notifications"
SOUND_ENABLED_FILE="$SOUND_DIR/sound-enabled"
SOUND_CUSTOM_FILE="$SOUND_DIR/sound-custom"
SOUND_CUSTOM_DIR="$SOUND_DIR/sounds"
# Root of the per-event sound pools: one sub-folder per event name
# (error/idle/permission/question/...), each holding any number of audio files
# that are picked from at random. Defaults to $SOUND_CUSTOM_DIR; `cn sound
# pool <dir>` points it at an existing collection instead.
SOUND_POOL_FILE="$SOUND_DIR/sound-pool"
# Presence of this marker mutes the pools without forgetting their root, so
# `cn sound set <file>` can hand every event to that one file and `cn sound
# pool on` can hand them back.
SOUND_POOL_OFF_FILE="$SOUND_DIR/sound-pool-off"

# Pool folder names, in the order the event mapping prefers them. Kept as a
# list so `cn sound pool` can report every folder it looks at.
SOUND_POOL_EVENTS=(
    complete idle question permission error limit usage reset test notification
    subagent-start subagent-stop teammate-idle task-created task-completed
)

# Default system sounds per platform
get_default_sound() {
    local os
    os=$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        "macos"|"Darwin"|"darwin")
            echo "/System/Library/Sounds/Glass.aiff"
            ;;
        "linux"|"Linux")
            # Try freedesktop sound first, then fallback
            if [[ -f "/usr/share/sounds/freedesktop/stereo/complete.oga" ]]; then
                echo "/usr/share/sounds/freedesktop/stereo/complete.oga"
            elif [[ -f "/usr/share/sounds/freedesktop/stereo/message.oga" ]]; then
                echo "/usr/share/sounds/freedesktop/stereo/message.oga"
            else
                echo ""
            fi
            ;;
        "windows"|"MINGW"*|"MSYS"*|"CYGWIN"*)
            echo "C:\\Windows\\Media\\chimes.wav"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Enable sound notifications
enable_sound() {
    mkdir -p "$SOUND_DIR"
    touch "$SOUND_ENABLED_FILE"
}

# Disable sound notifications
disable_sound() {
    rm -f "$SOUND_ENABLED_FILE"
}

# Check if sound is enabled
is_sound_enabled() {
    [[ -f "$SOUND_ENABLED_FILE" ]]
}

# Get current sound file path
get_sound() {
    if [[ -f "$SOUND_CUSTOM_FILE" ]]; then
        cat "$SOUND_CUSTOM_FILE"
    else
        get_default_sound
    fi
}

# Whether a path is a playable audio file (existence + supported extension).
# Also filters the un-expanded glob pattern out of the pool scan below, which
# is why it checks -f rather than trusting the caller.
is_supported_audio_file() {
    local path="$1"

    [[ -f "$path" ]] || return 1

    local ext="${path##*.}"
    ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        "wav"|"aiff"|"aif"|"mp3"|"ogg"|"oga"|"m4a"|"flac")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Set custom sound file
set_custom_sound() {
    local sound_path="$1"

    # Expand ~ to home directory
    sound_path="${sound_path/#\~/$HOME}"

    # Check if file exists
    if [[ ! -f "$sound_path" ]]; then
        echo "Error: Sound file not found: $sound_path" >&2
        return 1
    fi

    # Validate file extension
    if ! is_supported_audio_file "$sound_path"; then
        echo "Error: Unsupported audio format: .${sound_path##*.}" >&2
        echo "Supported formats: .wav, .aiff, .aif, .mp3, .ogg, .oga, .m4a, .flac" >&2
        return 1
    fi

    mkdir -p "$SOUND_DIR"
    echo "$sound_path" > "$SOUND_CUSTOM_FILE"
    # Picking one file means wanting to hear it: mute the per-event pools so
    # this sound plays for every event. `cn sound pool on` brings them back.
    disable_sound_pool
}

# ============================================
# Per-event sound pools
# ============================================

# Whether events draw from the pools at all
is_sound_pool_enabled() {
    [[ ! -f "$SOUND_POOL_OFF_FILE" ]]
}

# Mute the pools, keeping the configured root for later
disable_sound_pool() {
    mkdir -p "$SOUND_DIR"
    touch "$SOUND_POOL_OFF_FILE"
}

# Draw from the pools again
enable_sound_pool() {
    rm -f "$SOUND_POOL_OFF_FILE"
}

# Root directory holding the per-event sub-folders
get_sound_pool_dir() {
    local dir=""

    if [[ -f "$SOUND_POOL_FILE" ]]; then
        IFS= read -r dir < "$SOUND_POOL_FILE" || true
        dir="${dir/#\~/$HOME}"
    fi

    printf '%s\n' "${dir:-$SOUND_CUSTOM_DIR}"
}

# Point the pools at a directory of per-event sub-folders
set_sound_pool_dir() {
    local pool_dir="$1"

    pool_dir="${pool_dir/#\~/$HOME}"

    if [[ -z "$pool_dir" ]]; then
        echo "Error: pool directory required" >&2
        return 1
    fi

    if [[ ! -d "$pool_dir" ]]; then
        echo "Error: Directory not found: $pool_dir" >&2
        return 1
    fi

    mkdir -p "$SOUND_DIR"
    printf '%s\n' "${pool_dir%/}" > "$SOUND_POOL_FILE"
    # Naming a pool means wanting to hear it, even if `cn sound set` muted the
    # pools earlier.
    enable_sound_pool
}

# Reset the pool root back to ~/.claude/notifications/sounds
reset_sound_pool_dir() {
    rm -f "$SOUND_POOL_FILE"
    enable_sound_pool
}

# List the playable files in one event pool (empty output when the folder is
# missing or holds nothing playable)
list_pool_sounds() {
    local event="$1"
    local pool_dir
    pool_dir="$(get_sound_pool_dir)/$event"

    [[ -d "$pool_dir" ]] || return 0

    local sound
    for sound in "$pool_dir"/*; do
        if is_supported_audio_file "$sound"; then
            printf '%s\n' "$sound"
        fi
    done
}

# Pick one random file from an event pool; returns 1 when the pool is empty
pick_pool_sound() {
    local event="$1"
    local sounds=()
    local sound

    while IFS= read -r sound; do
        [[ -n "$sound" ]] && sounds+=("$sound")
    done < <(list_pool_sounds "$event")

    local count="${#sounds[@]}"
    [[ "$count" -eq 0 ]] && return 1

    printf '%s\n' "${sounds[$((RANDOM % count))]}"
}

# Map a notification event to the pool folders to try, best match first. Every
# event falls through to a folder the user is likely to have created, so a
# collection with only error/idle/permission/question still covers everything.
# Agent-team and subagent events accept the hook-type spelling as an alias
# (SubagentStop/ as well as subagent-stop/), since that is the name Claude Code
# uses for the hook and the one users reach for first.
sound_event_candidates() {
    local hook_type="${1:-}"
    local subtype="${2:-}"

    case "$hook_type" in
        "stop")
            printf '%s\n' "complete idle"
            ;;
        "notification")
            case "$subtype" in
                "idle_prompt")
                    printf '%s\n' "idle"
                    ;;
                "permission_prompt")
                    printf '%s\n' "permission question"
                    ;;
                *)
                    # Generic "input required" and elicitation dialogs both ask
                    # the user something.
                    printf '%s\n' "question permission"
                    ;;
            esac
            ;;
        "PreToolUse")
            # AskUserQuestion
            printf '%s\n' "question permission"
            ;;
        "SubagentStart")
            printf '%s\n' "subagent-start SubagentStart notification idle"
            ;;
        "SubagentStop")
            printf '%s\n' "subagent-stop SubagentStop complete idle"
            ;;
        "TeammateIdle")
            printf '%s\n' "teammate-idle TeammateIdle idle"
            ;;
        "TaskCreated")
            printf '%s\n' "task-created TaskCreated notification idle"
            ;;
        "TaskCompleted")
            printf '%s\n' "task-completed TaskCompleted complete idle"
            ;;
        "error"|"failed")
            printf '%s\n' "error"
            ;;
        "StopFailure")
            printf '%s\n' "limit error"
            ;;
        "usage")
            printf '%s\n' "usage error"
            ;;
        "usage_reset")
            printf '%s\n' "reset complete idle"
            ;;
        "test")
            printf '%s\n' "test complete idle"
            ;;
        *)
            printf '%s\n' "notification idle"
            ;;
    esac
}

# Random sound for an event, or empty when no pool folder matches (callers then
# fall back to the single configured sound)
pick_event_sound() {
    local hook_type="${1:-}"
    local subtype="${2:-}"
    local candidates=()
    local event
    local pick

    is_sound_pool_enabled || return 1

    read -r -a candidates <<< "$(sound_event_candidates "$hook_type" "$subtype")"

    for event in "${candidates[@]}"; do
        if pick=$(pick_pool_sound "$event"); then
            printf '%s\n' "$pick"
            return 0
        fi
    done

    return 1
}

# Sound for an event with the single-sound fallback applied
get_event_sound() {
    local pick
    if pick=$(pick_event_sound "$@"); then
        printf '%s\n' "$pick"
        return 0
    fi
    get_sound
}

# Reset to default sound
reset_sound() {
    rm -f "$SOUND_CUSTOM_FILE"
}

# Play sound based on platform
play_sound() {
    local sound_file="${1:-$(get_sound)}"

    # If no sound file, exit silently
    if [[ -z "$sound_file" ]] || [[ ! -f "$sound_file" ]]; then
        return 0
    fi

    local os
    os=$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        "macos"|"Darwin"|"darwin")
            play_sound_macos "$sound_file"
            ;;
        "linux"|"Linux")
            play_sound_linux "$sound_file"
            ;;
        "wsl")
            play_sound_wsl "$sound_file"
            ;;
        *)
            return 1
            ;;
    esac
}

# Play sound and wait for playback to finish. The speech path uses this so a
# queued speaker keeps the speech lock for the full utterance (`say` already
# blocks; ElevenLabs audio must too). The notification chime keeps using the
# backgrounded play_sound above.
play_sound_sync() {
    local sound_file="${1:-$(get_sound)}"

    if [[ -z "$sound_file" ]] || [[ ! -f "$sound_file" ]]; then
        return 0
    fi

    local os
    os=$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        "macos"|"Darwin"|"darwin")
            if command -v afplay &> /dev/null; then
                afplay "$sound_file" &>/dev/null
            fi
            ;;
        "linux"|"Linux")
            if command -v paplay &> /dev/null; then
                paplay "$sound_file" &>/dev/null
            elif command -v aplay &> /dev/null; then
                aplay "$sound_file" &>/dev/null
            elif command -v ffplay &> /dev/null; then
                ffplay -nodisp -autoexit "$sound_file" &>/dev/null
            elif command -v mpv &> /dev/null; then
                mpv --no-video --really-quiet "$sound_file" &>/dev/null
            fi
            ;;
        "wsl")
            local win_path
            win_path=$(wslpath -w "$sound_file" 2>/dev/null || echo "$sound_file")
            if command -v powershell.exe &> /dev/null; then
                powershell.exe -Command "(New-Object Media.SoundPlayer '$win_path').PlaySync()" &>/dev/null
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# Play sound on macOS
play_sound_macos() {
    local sound_file="$1"

    if command -v afplay &> /dev/null; then
        afplay "$sound_file" &>/dev/null &
    fi
}

# Play sound on Linux with fallback chain
play_sound_linux() {
    local sound_file="$1"

    if command -v paplay &> /dev/null; then
        paplay "$sound_file" &>/dev/null &
    elif command -v aplay &> /dev/null; then
        aplay "$sound_file" &>/dev/null &
    elif command -v ffplay &> /dev/null; then
        ffplay -nodisp -autoexit "$sound_file" &>/dev/null &
    elif command -v mpv &> /dev/null; then
        mpv --no-video --really-quiet "$sound_file" &>/dev/null &
    fi
}

# Play sound on WSL (Windows sound via PowerShell)
play_sound_wsl() {
    local sound_file="$1"

    # Convert WSL path to Windows path if needed
    local win_path
    if [[ "$sound_file" == /mnt/* ]]; then
        # Already a Windows path accessible from WSL
        win_path=$(wslpath -w "$sound_file" 2>/dev/null || echo "$sound_file")
    else
        win_path=$(wslpath -w "$sound_file" 2>/dev/null || echo "$sound_file")
    fi

    if command -v powershell.exe &> /dev/null; then
        powershell.exe -Command "(New-Object Media.SoundPlayer '$win_path').PlaySync()" &>/dev/null &
    fi
}

# Test sound playback
test_sound() {
    local sound_file
    sound_file=$(get_sound)

    if [[ -z "$sound_file" ]]; then
        echo "No sound configured" >&2
        return 1
    fi

    if [[ ! -f "$sound_file" ]]; then
        echo "Sound file not found: $sound_file" >&2
        return 1
    fi

    echo "Playing: $sound_file"
    play_sound "$sound_file"
}

# List available system sounds
list_system_sounds() {
    local os
    os=$(detect_os 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        "macos"|"Darwin"|"darwin")
            list_macos_sounds
            ;;
        "linux"|"Linux")
            list_linux_sounds
            ;;
        "wsl")
            list_wsl_sounds
            ;;
        *)
            echo "No system sounds available for this platform" >&2
            return 1
            ;;
    esac
}

# List macOS system sounds
list_macos_sounds() {
    local sound_dir="/System/Library/Sounds"

    if [[ -d "$sound_dir" ]]; then
        echo "System sounds ($sound_dir):"
        for sound in "$sound_dir"/*.aiff; do
            if [[ -f "$sound" ]]; then
                local name
                name=$(basename "$sound" .aiff)
                echo "  - $name"
            fi
        done
    fi

    # Also check user sounds
    local user_sound_dir="$HOME/Library/Sounds"
    if [[ -d "$user_sound_dir" ]]; then
        echo ""
        echo "User sounds ($user_sound_dir):"
        for sound in "$user_sound_dir"/*; do
            if [[ -f "$sound" ]]; then
                echo "  - $(basename "$sound")"
            fi
        done
    fi
}

# List Linux system sounds
list_linux_sounds() {
    local found=0

    # Check freedesktop sounds
    local freedesktop_dir="/usr/share/sounds/freedesktop/stereo"
    if [[ -d "$freedesktop_dir" ]]; then
        echo "Freedesktop sounds ($freedesktop_dir):"
        local sounds
        sounds=$(ls "$freedesktop_dir"/*.oga "$freedesktop_dir"/*.ogg "$freedesktop_dir"/*.wav 2>/dev/null || true)
        for sound in $sounds; do
            if [[ -f "$sound" ]]; then
                echo "  - $(basename "$sound")"
                found=1
            fi
        done
    fi

    # Check for other common sound directories
    local gnome_dir="/usr/share/sounds/gnome/default/alerts"
    if [[ -d "$gnome_dir" ]]; then
        echo ""
        echo "GNOME sounds ($gnome_dir):"
        local gnome_sounds
        gnome_sounds=$(ls "$gnome_dir"/*.ogg "$gnome_dir"/*.oga 2>/dev/null || true)
        for sound in $gnome_sounds; do
            if [[ -f "$sound" ]]; then
                echo "  - $(basename "$sound")"
                found=1
            fi
        done
    fi

    if [[ $found -eq 0 ]]; then
        echo "No system sounds found"
        echo "You can use custom sound files with: cn sound set <path>"
    fi
}

# List WSL/Windows system sounds
list_wsl_sounds() {
    echo "Windows system sounds (C:\\Windows\\Media):"
    if [[ -d "/mnt/c/Windows/Media" ]]; then
        for sound in /mnt/c/Windows/Media/*.wav; do
            if [[ -f "$sound" ]]; then
                echo "  - $(basename "$sound")"
            fi
        done | head -20
        echo "  ..."
    else
        echo "  (Cannot access Windows Media folder)"
    fi
}

# Get sound status for display
get_sound_status() {
    if is_sound_enabled; then
        local sound_file
        sound_file=$(get_sound)
        if [[ -f "$SOUND_CUSTOM_FILE" ]]; then
            echo "enabled:custom:$sound_file"
        else
            echo "enabled:default:$sound_file"
        fi
    else
        echo "disabled"
    fi
}
