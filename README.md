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

## Quick Start

### Install (macOS)

```bash
brew tap mylee04/tools
brew install claude-notify
```

### Install (Linux/WSL)

```bash
curl -sSL https://raw.githubusercontent.com/mylee04/claude-notify/main/scripts/install.sh | bash
```

### Enable Notifications

```bash
cn on          # Enable globally
cn test        # Send test notification
```

That's it! You'll now receive notifications when Claude Code completes tasks.

## Usage

![cn help output](assets/cn-help.png)

### Commands

| Command | Description |
|---------|-------------|
| `cn on` | Enable notifications globally |
| `cn off` | Disable notifications globally |
| `cn status` | Show current status |
| `cn test` | Send test notification |
| `cn voice on` | Enable voice announcements |

### Project Commands

Use `cnp` for project-specific settings that override global config:

```bash
cnp on         # Enable for current project only
cnp off        # Disable for current project
cnp status     # Show project status
cnp voice on   # Set project-specific voice
```

## Configuration

Claude-Notify uses Claude Code's hook system via `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "notify.sh stop" }] }],
    "Notification": [{ "matcher": "", "hooks": [{ "type": "command", "command": "notify.sh notification" }] }]
  }
}
```

Project settings are stored in `.claude/settings.json` within your project.

## Voice Notifications (macOS)

```bash
cn voice on    # Enable with voice selection
cn voice off   # Disable
cn voice status
```

Available voices: Samantha, Alex, Daniel (British), Fiona (Scottish), Whisper, and more.

## Project Structure

```
claude-notify/
├── bin/                  # Main executable
├── lib/claude-notify/    # Library code
│   ├── commands/         # Command handlers
│   ├── core/             # Config & notifier
│   └── utils/            # Helpers
├── scripts/              # Install scripts & tests
├── docs/                 # Documentation
└── assets/               # Images
```

## Troubleshooting

**Notifications not appearing?**
```bash
cn status              # Check if enabled
cn test                # Test notification
brew install terminal-notifier  # Better notifications (macOS)
```

**Command not found?**
```bash
exec $SHELL            # Reload shell
```

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Links

- [GitHub Issues](https://github.com/mylee04/claude-notify/issues)
- [Hook Configuration Guide](docs/HOOKS_GUIDE.md)
