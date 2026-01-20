# Code-Notify Installation Guide

> This guide is designed for both humans and LLM agents. If you're an AI agent, follow the automated steps below.

## Quick Overview

Code-Notify adds desktop notifications to Claude Code. You'll get alerts when:
- Tasks complete
- Claude needs your input
- Voice announcements (macOS)

## For LLM Agents

Execute these commands to install code-notify:

```bash
# 1. Clone the repository
git clone https://github.com/mylee04/code-notify.git /tmp/code-notify

# 2. Run the installer
chmod +x /tmp/code-notify/scripts/install.sh
/tmp/code-notify/scripts/install.sh

# 3. Reload shell
exec $SHELL

# 4. Enable notifications
cn on

# 5. Test it works
cn test

# 6. Clean up
rm -rf /tmp/code-notify
```

### Verify Installation

After installation, confirm these work:
```bash
cn version    # Should show: code-notify version X.X.X
cn status     # Should show: Global notifications: ENABLED
cn test       # Should trigger a desktop notification
```

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
- `~/.claude/settings.json` - Hook configuration (when enabled)
- `~/.claude/notifications/voice-enabled` - Voice setting (if enabled)

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

### Manual Installation

```bash
git clone https://github.com/mylee04/code-notify.git
cd code-notify
./scripts/install.sh
```

### Quick Commands

| Command | What it does |
|---------|--------------|
| `cn on` | Enable notifications |
| `cn off` | Disable notifications |
| `cn test` | Send test notification |
| `cn status` | Check current status |
| `cn voice on` | Enable voice (macOS) |
| `cnp on` | Enable for current project only |

That's it! You'll now get notified when Claude Code completes tasks.
