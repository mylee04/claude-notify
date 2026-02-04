---
description: Test notifications on current platform
---

# Test Notifications

## What This Command Does

1. Detects current platform (macOS/Linux/Windows/WSL)
2. Checks for available notification tools
3. Sends a test notification
4. Verifies notification was delivered

## When to Use

- After installation to verify setup
- When debugging notification issues
- Before releasing a new version

## Process

### 1. Check Environment

```bash
make test
```

### 2. Send Test Notification

```bash
cn test
```

### 3. Verify Delivery

- Notification should appear in system tray/notification center
- Sound should play (if enabled)
- Check logs: `~/.claude/logs/notifications.log`

## Expected Results

| Platform | Tool              | Notification Location |
| -------- | ----------------- | --------------------- |
| macOS    | terminal-notifier | Notification Center   |
| macOS    | osascript         | Notification Center   |
| Linux    | notify-send       | Desktop notifications |
| Windows  | BurntToast        | Action Center         |
| WSL      | wsl-notify-send   | Windows Action Center |

## Troubleshooting

### No notification appears

1. Check if notification tool is installed
2. Check system notification settings (Do Not Disturb, etc.)
3. Run with debug: `DEBUG=1 cn test`

### Sound doesn't play

1. Check system volume
2. Verify sound file exists
3. Check terminal-notifier version (macOS)
