---
name: cross-platform
description: Cross-platform development patterns for macOS, Windows, and Linux
---

# Cross-Platform Development

## When to Use
- Adding new platform support
- Writing platform-specific code
- Testing across platforms

## Platform Detection

### Bash (macOS/Linux)
```bash
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos" ;;
        Linux*)
            # Check for WSL
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *)          echo "unknown" ;;
    esac
}
```

### PowerShell (Windows)
```powershell
function Get-Platform {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        return "windows"
    } elseif ($IsLinux) {
        return "linux"
    } elseif ($IsMacOS) {
        return "macos"
    }
    return "unknown"
}
```

## Notification Tools by Platform

| Platform | Primary | Fallback |
|----------|---------|----------|
| macOS | terminal-notifier | osascript |
| Linux | notify-send | zenity, wall |
| Windows | BurntToast | System.Windows.Forms |
| WSL | wsl-notify-send | notify-send |

## Platform-Specific Patterns

### macOS
```bash
send_macos_notification() {
    local title="$1"
    local message="$2"

    if command -v terminal-notifier &> /dev/null; then
        terminal-notifier \
            -title "$title" \
            -message "$message" \
            -sound "Glass"
    else
        osascript -e "display notification \"$message\" with title \"$title\""
    fi
}
```

### Linux
```bash
send_linux_notification() {
    local title="$1"
    local message="$2"

    if command -v notify-send &> /dev/null; then
        notify-send "$title" "$message" \
            --urgency=normal \
            --app-name="Claude-Notify"
    elif command -v zenity &> /dev/null; then
        zenity --notification --text="$title\n$message"
    else
        echo "[$title] $message" | wall 2>/dev/null
    fi
}
```

### Windows (PowerShell)
```powershell
function Send-WindowsNotification {
    param(
        [string]$Title,
        [string]$Message
    )

    if (Get-Module -ListAvailable -Name BurntToast) {
        New-BurntToastNotification -Text $Title, $Message
    } else {
        Add-Type -AssemblyName System.Windows.Forms
        $notification = New-Object System.Windows.Forms.NotifyIcon
        $notification.Icon = [System.Drawing.SystemIcons]::Information
        $notification.BalloonTipTitle = $Title
        $notification.BalloonTipText = $Message
        $notification.Visible = $true
        $notification.ShowBalloonTip(10000)
    }
}
```

### WSL
```bash
send_wsl_notification() {
    local title="$1"
    local message="$2"

    if command -v wsl-notify-send.exe &> /dev/null; then
        wsl-notify-send.exe --category "$title" "$message"
    else
        # Fall back to Linux notification
        send_linux_notification "$title" "$message"
    fi
}
```

## Path Handling

### Unix vs Windows Paths
```bash
# Convert Unix path to Windows path (in WSL)
to_windows_path() {
    local unix_path="$1"
    wslpath -w "$unix_path"
}

# Convert Windows path to Unix path (in WSL)
to_unix_path() {
    local win_path="$1"
    wslpath -u "$win_path"
}
```

### Home Directory
```bash
# Bash
HOME_DIR="$HOME"

# PowerShell
$HomeDir = $env:USERPROFILE
```

## Git Handling Across Platforms

### Safe Git Commands
```bash
# Works on all platforms
get_project_name() {
    local git_root
    if git rev-parse --git-dir &> /dev/null; then
        git_root=$(git rev-parse --show-toplevel 2>/dev/null)
        if [[ -n "$git_root" ]]; then
            basename "$git_root"
            return 0
        fi
    fi
    basename "$PWD"
}
```

### PowerShell Git Handling
```powershell
function Get-ProjectName {
    try {
        $gitRoot = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            return Split-Path $gitRoot -Leaf
        }
    } catch {
        # Not in git repo
    }
    return Split-Path (Get-Location) -Leaf
}
```

## Testing Strategy

### CI/CD Matrix
```yaml
strategy:
  matrix:
    os: [macos-latest, ubuntu-latest, windows-latest]
```

### Platform-Specific Tests
```bash
# test/test-platform.sh
test_current_platform() {
    local os=$(detect_os)
    case "$os" in
        macos)  test_macos_notification ;;
        linux)  test_linux_notification ;;
        wsl)    test_wsl_notification ;;
        *)      echo "Unknown platform: $os" ;;
    esac
}
```

## Common Pitfalls

1. **Line Endings**: Windows uses CRLF, Unix uses LF
   - Use `.gitattributes` to enforce line endings

2. **Path Separators**: Windows uses `\`, Unix uses `/`
   - Use variables like `$HOME` instead of hardcoded paths

3. **Case Sensitivity**: Windows is case-insensitive
   - Be consistent with file naming

4. **Command Availability**: Commands differ by platform
   - Always check with `command -v` before use

## Success Metrics
- Works on macOS 10.14+
- Works on Ubuntu 20.04+
- Works on Windows 10+ (PowerShell 5.1+)
- Works on WSL2
- Graceful fallback when tools missing
