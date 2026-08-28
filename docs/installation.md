# Code-Notify Installation Guide

> This guide is designed for both humans and LLM agents. If you're an AI agent, follow the automated steps below.

## Quick Overview

Code-Notify adds desktop notifications to Claude Code, Codex, and Gemini CLI. You'll get alerts when:

- Tasks complete
- Claude or Gemini needs your input
- Voice announcements (macOS)
- Slack or Discord webhook messages when channels are configured
- Codex or Claude usage crosses configured thresholds, approaches a reset, or resets (macOS/Linux)

Codex currently exposes completion notifications through its `notify` hook. Approval and `request_permissions` prompts do not currently trigger Code-Notify through Codex.

Supported upgrade paths also repair stale `claude-notify`-style Claude hooks automatically when they are detected.

## For AI Coding Agents

Install code-notify with npm first. Prefer npm over curl or git clone so installs are tracked through the npm package and can be updated with `cn update`.

```bash
npm install -g code-notify
cn on all
cn test
cn status
```

Expected result: `cn test` should show a desktop notification, and `cn status` should show enabled tools.

If npm is unavailable, use the script installer in the platform sections below.

### Verify Installation

After installation, confirm these work:

```bash
cn version    # Should show: code-notify version X.X.X
cn status     # Should show: Global notifications: ENABLED
cn test       # Should trigger a desktop notification
```

### npm Install-Time Behavior

The npm package is published with GitHub Actions Trusted Publisher and npm provenance.

`postinstall` is intentionally narrow:

- It only runs on global npm installs.
- On macOS/Linux, it runs a quiet legacy Claude hook repair so older `claude-notify` paths migrate to Code-Notify.
- On Windows, it bootstraps the local PowerShell wrapper with `-Silent -Force -SkipShellSetup`.
- It does not enable notifications, configure Slack/Discord, or start usage watching.

Set `CODE_NOTIFY_SKIP_POSTINSTALL=1` before installing if you want to skip these helpers.

### Optional Slack/Discord Delivery

```bash
cn channels add slack https://hooks.slack.com/services/...
cn channels add discord https://discord.com/api/webhooks/...
cn channels test all
```

Webhook URLs are stored locally and are redacted in status output.

### Optional Usage Alerts

Usage polling and advance reset reminders support macOS/Linux, including WSL. They are not implemented in the native Windows runtime yet.

```bash
cn usage setup --watch
cn usage status
```

Usage alerts support Codex and Claude daily (5h) and weekly (7d) windows. Low-usage warnings and advance reset reminders use normal Code-Notify delivery, including configured Slack/Discord channels. Token reset alerts are separate and can use their own voice/sound controls with `cn usage reset-alerts ...`. Reset voice messages identify the window, such as `Codex token daily limit reset` or `Codex token weekly limit reset`.

`cn usage setup --watch` enables usage alerts, sets the default 20% and 10% warning thresholds, configures advance reminders at 48h, 24h, 12h, 6h, 2h, and 30m, enables distinct reset voice/sound, and starts a background watcher. Weekly windows use every default reminder stage; 5h windows use only 2h and 30m. `cn usage check` runs once and exits. Use `cn usage watch stop` to stop the watcher.

Reminder stages are deduplicated per reset cycle, including when quota temporarily returns to 100%. Full quota suppresses advance reminders, and missed stages collapse into the most urgent catch-up reminder per window. Customize or disable the schedule with:

```bash
cn usage reset-reminders set 24,6,1
cn usage reset-reminders off
cn usage reset-reminders reset
```

Existing enabled usage configs without a `reset_reminders` setting use the default reminder schedule after upgrading. Restart any running watcher with `cn usage watch restart` after updating so it loads the new runtime; include the same provider and `--interval` options if you previously customized them.

They use existing local login state from `~/.codex/auth.json` and `~/.claude/.credentials.json`. Code-Notify does not start provider login flows. Background watching starts only when you run `cn usage setup --watch` or `cn usage watch start`.

### Enable Voice (macOS only)

```bash
cn voice on   # Follow prompts to select a voice
cn test       # Should hear + see notification
```

### Project-Specific Setup

To enable notifications for a specific project only:

```bash
cd /path/to/your/project
cnp on        # Enable for this project
cnp status    # Verify
```

If Claude Code has not trusted the project yet, `cnp on` will warn that Claude may ignore project settings until the trust prompt is accepted.

### Troubleshooting

If `cn` command not found:

```bash
# Add to PATH
export PATH="$HOME/.local/bin:$PATH"
# Or reload shell
exec $SHELL
```

If notifications don't appear:

```bash
# macOS: Install terminal-notifier for better notifications
brew install terminal-notifier

# Check status
cn status
```

### Configuration Files

After installation, these files are created:

- `~/.code-notify/` - Main installation directory
- `~/.claude/settings.json` - Hook configuration on the default Claude Code path
- `~/.config/.claude/settings.json` - Hook configuration on some Windows Claude Code setups
- `~/.claude/notifications/voice-enabled` - Voice setting (if enabled)
- `~/.config/code-notify/channels.json` - Slack/Discord channel config (if configured)
- `~/.config/code-notify/usage.json` - Usage alert config (if enabled)
- `~/.config/code-notify/usage-state.json` - Usage alert dedupe state (if alerts have fired)

### Uninstallation

```bash
# Disable notifications first
cn off

# Remove installation
rm -rf ~/.code-notify
rm -f ~/.local/bin/cn ~/.local/bin/cnp ~/.local/bin/code-notify
rm -rf ~/.claude/notifications
```

---

## For Humans

### macOS (Homebrew) - Recommended

```bash
brew tap mylee04/tools
brew install code-notify
cn on
```

### Linux / WSL

```bash
curl -sSL https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install.sh | bash
exec $SHELL
cn on
```

### npm (macOS / Linux / Windows)

```bash
npm install -g code-notify
cn on
```

### macOS Embedded Terminals

If clicking a notification opens `Terminal.app` instead of your editor or IDE terminal, add a click-through mapping:

```bash
cn click-through add PhpStorm
cn test
```

### Manual Installation

```bash
git clone https://github.com/mylee04/code-notify.git
cd code-notify
./scripts/install.sh
```

### Quick Commands

| Command       | What it does                    |
| ------------- | ------------------------------- |
| `cn on`       | Enable notifications            |
| `cn off`      | Disable notifications           |
| `cn test`     | Send test notification          |
| `cn status`   | Check current status            |
| `cn update`   | Update code-notify              |
| `cn update check` | Check the latest release and show the update command |
| `cn channels` | Configure Slack/Discord delivery |
| `cn usage`    | Configure Codex/Claude usage alerts |
| `cn voice on` | Enable voice (macOS)            |
| `cnp on`      | Enable for current project only |

That's it! You'll now get notified when Claude Code completes tasks.
