# Claude-Notify

Desktop notifications for Claude Code - get alerts when tasks complete or input is needed.

![Claude-Notify Banner](assets/banner.png)

[![Version](https://img.shields.io/badge/version-1.2.0-blue.svg)](https://github.com/mylee04/claude-notify/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-supported-green.svg)](https://www.apple.com/macos)
[![Linux](https://img.shields.io/badge/Linux-supported-green.svg)](https://www.linux.org/)

## Features

- **Cross-platform** - macOS, Linux, Windows (experimental)
- **Native notifications** - Uses system notification APIs
- **Voice announcements** - Hear when tasks complete (macOS)
- **Project-specific settings** - Different configs per project
- **Quick aliases** - `cn` and `cnp` for fast access

## Installation

### For Humans

**macOS (Homebrew)**
```bash
brew tap mylee04/tools
brew install claude-notify
cn on
```

**Linux / WSL**
```bash
curl -sSL https://raw.githubusercontent.com/mylee04/claude-notify/main/scripts/install.sh | bash
```

### For LLM Agents

Paste this to your AI agent (Claude Code, Cursor, etc.):

```
Install claude-notify by following:
https://raw.githubusercontent.com/mylee04/claude-notify/main/docs/installation.md
```

Or fetch directly:
```bash
curl -s https://raw.githubusercontent.com/mylee04/claude-notify/main/docs/installation.md
```

## Usage

![cn help output](assets/cn-help.png)

| Command | Description |
|---------|-------------|
| `cn on` | Enable notifications globally |
| `cn off` | Disable notifications |
| `cn test` | Send test notification |
| `cn status` | Show current status |
| `cn voice on` | Enable voice (macOS) |
| `cnp on` | Enable for current project only |

## How It Works

Claude-Notify uses Claude Code's hook system. When enabled, it adds hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "notify.sh stop" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "notify.sh notification" }] }]
  }
}
```

## Troubleshooting

**Command not found?**
```bash
exec $SHELL   # Reload shell
```

**No notifications?**
```bash
cn status     # Check if enabled
cn test       # Test notification
brew install terminal-notifier  # Better notifications (macOS)
```

## Project Structure

```
claude-notify/
├── bin/           # Main executable
├── lib/           # Library code
├── scripts/       # Install scripts
├── docs/          # Documentation
└── assets/        # Images
```

## Links

- [Installation Guide](docs/installation.md)
- [Hook Configuration](docs/HOOKS_GUIDE.md)
- [Contributing](docs/CONTRIBUTING.md)
- [GitHub Issues](https://github.com/mylee04/claude-notify/issues)

## License

MIT License - see [LICENSE](LICENSE)
