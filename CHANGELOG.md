# Changelog

All notable changes to Claude-Notify will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2025-01-29

### Added
- Initial release of Claude-Notify
- Homebrew formula for easy installation
- Global notification commands (`cn on`, `cn off`, `cn status`)
- Project-specific notification commands (`cnp on`, `cnp off`, `cnp status`)
- Integration with Claude Code hooks system
- Support for terminal-notifier (recommended) with osascript fallback
- Shell completions for bash and zsh
- Setup wizard for first-time users
- Test command to verify notifications are working
- Comprehensive documentation and examples

### Features
- Cross-platform desktop notifications (macOS, Linux, Windows)
- Platform-specific notification methods:
  - macOS: terminal-notifier or osascript
  - Linux: notify-send, zenity, or wall
  - Windows: PowerShell with BurntToast or native notifications
- Project name detection (git repositories or directory names)
- Non-invasive integration using Claude Code's existing hook system
- Easy toggle without losing configuration
- Notification logging to `~/.claude/logs/notifications.log`

[1.0.0]: https://github.com/mylee04/claude-notify/releases/tag/v1.0.0