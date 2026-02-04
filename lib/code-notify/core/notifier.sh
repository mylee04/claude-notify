#!/bin/bash

# Core notification functionality for Code-Notify
# Supports: Claude Code, Codex, Gemini CLI

# Get arguments: notify.sh <hook_type> <tool_name> [project_name]
HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$1}
TOOL_NAME=${2:-""}
PROJECT_NAME=${3:-$(basename "$PWD")}

# Read hook data from stdin (Claude Code passes JSON with hook context)
HOOK_DATA=""
if [[ ! -t 0 ]]; then
    HOOK_DATA=$(cat 2>/dev/null || true)
fi

# Source shared utilities
NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$NOTIFIER_DIR/../utils/detect.sh"
source "$NOTIFIER_DIR/../utils/voice.sh"
source "$NOTIFIER_DIR/../utils/sound.sh"

# Get display name for tool
get_tool_display_name() {
    local tool="$1"
    case "$tool" in
        "claude") echo "Claude" ;;
        "codex") echo "Codex" ;;
        "gemini") echo "Gemini" ;;
        *) echo "AI" ;;
    esac
}

TOOL_DISPLAY=$(get_tool_display_name "$TOOL_NAME")

# Rate limiting for stop notifications (prevents spam from parallel sub-agents)
RATE_LIMIT_DIR="$HOME/.claude/notifications"
RATE_LIMIT_SECONDS=10

is_rate_limited() {
    local lock_file="$RATE_LIMIT_DIR/last_stop_notification"

    if [[ ! -f "$lock_file" ]]; then
        return 1  # No previous notification, not rate limited
    fi

    local last_time
    last_time=$(cat "$lock_file" 2>/dev/null || echo "0")
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - last_time))

    if [[ $elapsed -lt $RATE_LIMIT_SECONDS ]]; then
        return 0  # Rate limited
    fi

    return 1  # Not rate limited
}

update_rate_limit() {
    mkdir -p "$RATE_LIMIT_DIR"
    date +%s > "$RATE_LIMIT_DIR/last_stop_notification"
}

# Function to check if notification should be suppressed
should_suppress_notification() {
    # Check kill switch first - instant disable without restart
    if [[ -f "$HOME/.claude/notifications/disabled" ]]; then
        return 0  # Suppress notification
    fi

    # Skip suppression checks for test notifications
    if [[ "$HOOK_TYPE" == "test" ]]; then
        return 1
    fi

    # Rate limit stop notifications to prevent spam from parallel sub-agents
    if [[ "$HOOK_TYPE" == "stop" ]]; then
        if is_rate_limited; then
            return 0  # Suppress - too soon since last notification
        fi
    fi

    # For Stop hooks: Check if stop_hook_active is true
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"stop_hook_active":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    # Check for auto-accept indicator
    if [[ "${CLAUDE_AUTO_ACCEPT:-}" == "true" ]]; then
        return 0
    fi

    if [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"autoAccepted":\s*true' 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Check if notification should be suppressed
if [[ "$HOOK_TYPE" == "stop" ]] || [[ "$HOOK_TYPE" == "notification" ]]; then
    if should_suppress_notification; then
        exit 0
    fi
fi

# Update rate limit timestamp for stop notifications
if [[ "$HOOK_TYPE" == "stop" ]]; then
    update_rate_limit
fi

# Set notification parameters based on hook type and tool
case "$HOOK_TYPE" in
    "stop")
        TITLE="$TOOL_DISPLAY ✅"
        SUBTITLE="Task Complete"
        MESSAGE="$TOOL_DISPLAY completed the task"
        VOICE_MESSAGE="$TOOL_DISPLAY completed the task"
        SOUND="Glass"
        ;;
    "notification")
        TITLE="$TOOL_DISPLAY 🔔"
        SUBTITLE="Input Required"
        MESSAGE="$TOOL_DISPLAY needs your input"
        VOICE_MESSAGE="$TOOL_DISPLAY needs your input"
        SOUND="Ping"
        ;;
    "error"|"failed")
        TITLE="$TOOL_DISPLAY ❌"
        SUBTITLE="Error"
        MESSAGE="An error occurred in $TOOL_DISPLAY"
        VOICE_MESSAGE="An error occurred in $TOOL_DISPLAY"
        SOUND="Basso"
        ;;
    "test")
        TITLE="Code-Notify Test ✅"
        SUBTITLE="$PROJECT_NAME"
        MESSAGE="Notifications are working!"
        VOICE_MESSAGE="Notifications are working"
        SOUND="Glass"
        ;;
    "PreToolUse")
        # Silent for PreToolUse - just log, no notification
        exit 0
        ;;
    *)
        TITLE="$TOOL_DISPLAY 📢"
        SUBTITLE="Status Update"
        MESSAGE="$TOOL_DISPLAY: $HOOK_TYPE"
        VOICE_MESSAGE="$TOOL_DISPLAY status update"
        SOUND="Pop"
        ;;
esac

# Add project name to subtitle if available
if [[ -n "$PROJECT_NAME" ]] && [[ "$HOOK_TYPE" != "test" ]]; then
    SUBTITLE="$SUBTITLE - $PROJECT_NAME"
fi

# Get terminal bundle ID for macOS activation
get_terminal_bundle_id() {
    case "${TERM_PROGRAM:-}" in
        "iTerm.app") echo "com.googlecode.iterm2" ;;
        "Apple_Terminal") echo "com.apple.Terminal" ;;
        "vscode") echo "com.microsoft.VSCode" ;;
        "WezTerm") echo "com.github.wez.wezterm" ;;
        "Alacritty") echo "org.alacritty" ;;
        "Hyper") echo "co.zeit.hyper" ;;
        *)
            # Fallback: try to detect from parent process
            if [[ -n "${ITERM_SESSION_ID:-}" ]]; then
                echo "com.googlecode.iterm2"
            elif [[ -n "${WEZTERM_PANE:-}" ]]; then
                echo "com.github.wez.wezterm"
            else
                echo "com.apple.Terminal"
            fi
            ;;
    esac
}

# Function to send notification on macOS
send_macos_notification() {
    local bundle_id
    bundle_id=$(get_terminal_bundle_id)

    if command -v terminal-notifier &> /dev/null; then
        terminal-notifier \
            -title "$TITLE" \
            -subtitle "$SUBTITLE" \
            -message "$MESSAGE" \
            -sound "$SOUND" \
            -group "code-notify-$TOOL_NAME-$PROJECT_NAME" \
            -activate "$bundle_id" \
            2>/dev/null
    else
        # osascript doesn't support click-to-activate, but we can use a workaround
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\" sound name \"$SOUND\"" 2>/dev/null
    fi
}

# Function to send notification on Linux
send_linux_notification() {
    if command -v notify-send &> /dev/null; then
        notify-send "$TITLE" "$MESSAGE" \
            --urgency=normal \
            --app-name="Code-Notify" \
            --icon=dialog-information \
            2>/dev/null
    elif command -v zenity &> /dev/null; then
        zenity --notification \
            --text="$TITLE\n$MESSAGE" \
            2>/dev/null
    else
        echo "[$TITLE] $MESSAGE" | wall 2>/dev/null
    fi
}

# Function to send notification on Windows
send_windows_notification() {
    if command -v powershell &> /dev/null; then
        powershell -Command "
            if (Get-Module -ListAvailable -Name BurntToast) {
                New-BurntToastNotification -Text '$TITLE', '$MESSAGE'
            } else {
                Add-Type -AssemblyName System.Windows.Forms
                \$notification = New-Object System.Windows.Forms.NotifyIcon
                \$notification.Icon = [System.Drawing.SystemIcons]::Information
                \$notification.BalloonTipIcon = 'Info'
                \$notification.BalloonTipTitle = '$TITLE'
                \$notification.BalloonTipText = '$MESSAGE'
                \$notification.Visible = \$true
                \$notification.ShowBalloonTip(10000)
            }
        " 2>/dev/null
    elif command -v msg &> /dev/null; then
        msg "%USERNAME%" "$TITLE: $MESSAGE" 2>/dev/null
    fi
}

# Check if voice is enabled for this tool
should_speak() {
    # Check tool-specific voice setting first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            return 0
        fi
    fi

    # Fall back to global voice setting
    local global_voice_file="$HOME/.claude/notifications/voice-enabled"
    if [[ -f "$global_voice_file" ]]; then
        return 0
    fi

    return 1
}

# Get voice setting (tool-specific or global)
get_voice_setting() {
    # Check tool-specific voice first
    if [[ -n "$TOOL_NAME" ]]; then
        local tool_voice_file="$HOME/.claude/notifications/voice-$TOOL_NAME"
        if [[ -f "$tool_voice_file" ]]; then
            cat "$tool_voice_file"
            return
        fi
    fi

    # Fall back to global
    get_voice "global" 2>/dev/null || echo ""
}

# Check if sound should play
should_play_sound() {
    is_sound_enabled
}

# Send notification based on OS
OS=$(detect_os)
case "$OS" in
    macos)
        send_macos_notification
        # Voice notification if enabled
        if should_speak; then
            VOICE=$(get_voice_setting)
            if [[ -n "$VOICE" ]]; then
                say -v "$VOICE" "$VOICE_MESSAGE"
            fi
        fi
        # Sound notification if enabled (separate from voice)
        if should_play_sound; then
            play_sound
        fi
        ;;
    linux)
        send_linux_notification
        # Sound notification if enabled
        if should_play_sound; then
            play_sound
        fi
        ;;
    wsl)
        send_linux_notification
        # Sound notification if enabled
        if should_play_sound; then
            play_sound
        fi
        ;;
    windows)
        send_windows_notification
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Log the notification
LOG_DIR="$HOME/.claude/logs"
if [[ -d "$LOG_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TOOL_NAME] [$PROJECT_NAME] $MESSAGE" >> "$LOG_DIR/notifications.log"
fi

exit 0
