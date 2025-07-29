#!/bin/bash

# Core notification functionality for Claude-Notify

# Get the hook type and status from environment or arguments
HOOK_TYPE=${CLAUDE_HOOK_TYPE:-$1}
STATUS=${2:-"completed"}
PROJECT_NAME=${3:-$(basename "$PWD")}

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

# Function to send notification using terminal-notifier
send_terminal_notification() {
    terminal-notifier \
        -title "$TITLE" \
        -subtitle "$SUBTITLE" \
        -message "$MESSAGE" \
        -sound "$SOUND" \
        -group "claude-notify-$PROJECT_NAME" \
        -ignoreDnD \
        -activate "com.apple.Terminal" \
        -sender "com.apple.Terminal" \
        2>/dev/null
}

# Function to send notification using osascript
send_osascript_notification() {
    osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" subtitle \"$SUBTITLE\" sound name \"$SOUND\"" 2>/dev/null
}

# Send the notification
if command -v terminal-notifier &> /dev/null; then
    send_terminal_notification
else
    send_osascript_notification
fi

# Log the notification if log directory exists
LOG_DIR="$HOME/.claude/logs"
if [[ -d "$LOG_DIR" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$PROJECT_NAME] $TITLE - $SUBTITLE: $MESSAGE" >> "$LOG_DIR/notifications.log"
fi

# Exit successfully
exit 0