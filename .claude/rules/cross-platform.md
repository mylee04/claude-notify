# Cross-Platform Rules

## Mandatory Checks

### Platform Detection
- [ ] Detect OS before platform-specific code
- [ ] Handle unknown platforms gracefully
- [ ] Check for required tools before use
- [ ] Provide helpful messages when tools missing

### Path Handling
- [ ] Use `$HOME` not `~` in scripts
- [ ] Don't hardcode path separators
- [ ] Handle spaces in paths
- [ ] Use variables for common paths

### Command Compatibility
- [ ] Use POSIX-compatible commands where possible
- [ ] Check command existence with `command -v`
- [ ] Provide fallbacks for missing commands
- [ ] Document platform-specific requirements

### Testing
- [ ] Test on macOS (latest and -1)
- [ ] Test on Ubuntu LTS
- [ ] Test on Windows 10+
- [ ] Test on WSL2

## Platform Matrix

| Feature | macOS | Linux | Windows | WSL |
|---------|-------|-------|---------|-----|
| Notifications | terminal-notifier, osascript | notify-send, zenity | BurntToast, Forms | wsl-notify-send |
| Shell | bash, zsh | bash | PowerShell | bash |
| Config | ~/.claude | ~/.claude | %USERPROFILE%\.claude | ~/.claude |

## Patterns

### Platform-Specific Code
```bash
# Good - explicit platform handling
case "$(detect_os)" in
    macos)
        send_macos_notification "$@"
        ;;
    linux)
        send_linux_notification "$@"
        ;;
    wsl)
        send_wsl_notification "$@"
        ;;
    windows)
        # Shouldn't reach here in bash
        echo "Use PowerShell on Windows" >&2
        exit 1
        ;;
    *)
        echo "Unsupported platform" >&2
        exit 1
        ;;
esac

# Bad - assumes one platform
terminal-notifier -message "$message"
```

### Graceful Degradation
```bash
# Good - fallback chain
send_notification() {
    if command -v terminal-notifier &> /dev/null; then
        terminal-notifier -message "$1"
    elif command -v osascript &> /dev/null; then
        osascript -e "display notification \"$1\""
    else
        echo "Warning: No notification tool found" >&2
        echo "$1"  # At least print it
    fi
}
```

## Consequences
- Hardcoded paths fail on other platforms
- Missing tool checks cause cryptic errors
- Platform assumptions break portability
