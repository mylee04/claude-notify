#!/bin/bash

# Core notification functionality for Claude-Notify

# Get the hook type and status from environment or arguments
HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$1}
STATUS=${2:-"completed"}
PROJECT_NAME=${3:-$(basename "$PWD")}

# Read hook data from stdin (Claude Code passes JSON with hook context)
HOOK_DATA=""
if [[ ! -t 0 ]]; then
    # Read all stdin data
    HOOK_DATA=$(cat 2>/dev/null || true)
fi

# Source shared utilities
NOTIFIER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$NOTIFIER_DIR/../utils/detect.sh"
source "$NOTIFIER_DIR/../utils/voice.sh"

# Function to check if notification should be suppressed
should_suppress_notification() {
    # Skip suppression checks for test notifications
    if [[ "$HOOK_TYPE" == "test" ]]; then
        return 1  # Don't suppress test notifications
    fi

    # For Stop hooks: Check if stop_hook_active is true
    # This means Claude is still working (continuing from a previous stop hook)
    # We should only notify when Claude has truly finished
    if [[ "$HOOK_TYPE" == "stop" ]] && [[ -n "$HOOK_DATA" ]]; then
        # Check if stop_hook_active is true (Claude is still working)
        if echo "$HOOK_DATA" | grep -q '"stop_hook_active":\s*true' 2>/dev/null; then
            return 0  # Suppress - Claude is still working
        fi
    fi

    # Check for auto-accept indicator in environment (Issue #7)
    if [[ "${CLAUDE_AUTO_ACCEPT:-}" == "true" ]]; then
        return 0  # Suppress auto-accepted notifications
    fi

    # Check if hook data indicates auto-acceptance
    if [[ -n "$HOOK_DATA" ]]; then
        if echo "$HOOK_DATA" | grep -q '"autoAccepted":\s*true' 2>/dev/null; then
            return 0  # Suppress auto-accepted notifications
        fi
    fi

    return 1  # Don't suppress
}

# Check if notification should be suppressed
if [[ "$HOOK_TYPE" == "stop" ]] || [[ "$HOOK_TYPE" == "notification" ]]; then
    if should_suppress_notification; then
        exit 0  # Skip this notification
    fi
fi

# Set notification parameters based on hook type
case "$HOOK_TYPE" in
    "stop")
        TITLE="Claude Code ✅"
        SUBTITLE="Task Complete - $PROJECT_NAME"
        MESSAGE="Your task has been completed successfully!"
        SOUND="Glass"
        ;;
    "notification")
        TITLE="Claude Code 🔔"
        SUBTITLE="Input Required - $PROJECT_NAME"
        MESSAGE="Claude needs your input to continue"
        SOUND="Ping"
        ;;
    "error"|"failed")
        TITLE="Claude Code ❌"
        SUBTITLE="Error - $PROJECT_NAME"
        MESSAGE="An error occurred during task execution"
        SOUND="Basso"
        ;;
    "test")
        TITLE="Claude-Notify Test ✅"
        SUBTITLE="$PROJECT_NAME"
        MESSAGE="Notifications are working correctly!"
        SOUND="Glass"
        ;;
    *)
        TITLE="Claude Code 📢"
        SUBTITLE="Status Update - $PROJECT_NAME"
        MESSAGE="Task status: $STATUS"
        SOUND="Pop"
        ;;
esac

# Function to send notification on macOS
send_macos_notification() {
    if command -v terminal-notifier &> /dev/null; then
        terminal-notifier \
            -title "$TITLE" \
            -subtitle "$SUBTITLE" \
            -message "$MESSAGE" \
            -sound "$SOUND" \
            -group "claude-notify-$PROJECT_NAME" \
            2>/dev/null
    else
        osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\" sound name \"$SOUND\"" 2>/dev/null
    fi
}

# Function to send notification on Linux
send_linux_notification() {
    if command -v notify-send &> /dev/null; then
        # notify-send is the standard Linux notification tool
        notify-send "$TITLE" "$MESSAGE" \
            --urgency=normal \
            --app-name="Claude-Notify" \
            --icon=dialog-information \
            2>/dev/null
    elif command -v zenity &> /dev/null; then
        # Fallback to zenity if available
        zenity --notification \
            --text="$TITLE\n$MESSAGE" \
            2>/dev/null
    else
        # Last resort: use wall for terminal notification
        echo "[$TITLE] $MESSAGE" | wall 2>/dev/null
    fi
}

# Function to send notification on Windows
send_windows_notification() {
    # Try PowerShell with BurntToast if available
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
        # Fallback to msg command
        msg "%USERNAME%" "$TITLE: $MESSAGE" 2>/dev/null
    fi
}

# Send notification based on OS
OS=$(detect_os)
case "$OS" in
    macos)
        send_macos_notification
        # Add voice notification if enabled
        VOICE=$(get_voice "global" 2>/dev/null || echo "")
        if [[ -n "$VOICE" ]]; then
            say -v "$VOICE" "$MESSAGE"
        fi
        ;;
    linux)
        send_linux_notification
        ;;
    windows)
        send_windows_notification
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

# Log the notification if log directory exists
LOG_DIR="$HOME/.claude/logs"
if [[ -d "$LOG_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$PROJECT_NAME] $TITLE - $SUBTITLE: $MESSAGE" >> "$LOG_DIR/notifications.log"
fi

# Exit successfully
exit 0