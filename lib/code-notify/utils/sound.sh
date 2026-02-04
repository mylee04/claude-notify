#!/bin/bash

# Sound notification utilities for Code-Notify

# Sound configuration paths
SOUND_DIR="$HOME/.claude/notifications"
SOUND_ENABLED_FILE="$SOUND_DIR/sound-enabled"
SOUND_CUSTOM_FILE="$SOUND_DIR/sound-custom"
SOUND_CUSTOM_DIR="$SOUND_DIR/sounds"

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
    local ext="${sound_path##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        "wav"|"aiff"|"aif"|"mp3"|"ogg"|"oga"|"m4a"|"flac")
            ;;
        *)
            echo "Error: Unsupported audio format: .$ext" >&2
            echo "Supported formats: .wav, .aiff, .mp3, .ogg, .m4a, .flac" >&2
            return 1
            ;;
    esac

    mkdir -p "$SOUND_DIR"
    echo "$sound_path" > "$SOUND_CUSTOM_FILE"
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
