# Code-Notify Installation Script for Windows
# Desktop notifications for Claude Code, Codex, and Gemini CLI
# https://github.com/mylee04/code-notify
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1
#
# Or run directly in PowerShell:
#   irm https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install-windows.ps1 | iex

#Requires -Version 5.1

param(
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$Silent,
    [switch]$SkipShellSetup
)

$ErrorActionPreference = "Stop"

# Version
$VERSION = "1.13.1"

# Colors and formatting
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Error { param([string]$Message) Write-Host "[X] $Message" -ForegroundColor Red }
function Write-Warning { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Header { param([string]$Message) Write-Host "`n$Message" -ForegroundColor White }

# Paths
$ClaudeHome = "$env:USERPROFILE\.claude"
$InstallDir = "$env:USERPROFILE\.code-notify"
$NotificationsDir = "$ClaudeHome\notifications"
$NotificationStateDir = "$NotificationsDir\state"
$LogsDir = "$ClaudeHome\logs"

function Show-Banner {
    Write-Host @"

 ====================================
   Code-Notify for Windows v$VERSION
 ====================================

"@ -ForegroundColor Cyan
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-Prerequisites {
    Write-Header "Checking prerequisites..."

    # Check PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion.Major -lt 5) {
        Write-Error "PowerShell 5.1 or higher is required. Current version: $psVersion"
        return $false
    }
    Write-Success "PowerShell version: $psVersion"

    # Check Windows version (Windows 10+)
    $osVersion = [System.Environment]::OSVersion.Version
    if ($osVersion.Major -lt 10) {
        Write-Warning "Windows 10 or higher is recommended for toast notifications"
    } else {
        Write-Success "Windows version: $($osVersion.Major).$($osVersion.Minor)"
    }

    # Check for BurntToast module (optional)
    $burntToast = Get-Module -ListAvailable -Name BurntToast
    if ($burntToast) {
        Write-Success "BurntToast module: Installed (enhanced notifications)"
    } else {
        Write-Info "BurntToast module: Not installed (using native notifications)"
        Write-Info "  For enhanced notifications, run: Install-Module -Name BurntToast -Scope CurrentUser"
    }

    # Check for Git (optional, for project detection)
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Success "Git: Installed (project detection enabled)"
    } else {
        Write-Info "Git: Not installed (project names will use folder names)"
    }

    return $true
}

function Install-ClaudeNotify {
    Write-Header "Installing Code-Notify..."

    # Create directories
    $directories = @($InstallDir, "$InstallDir\bin", "$InstallDir\lib", $NotificationsDir, $NotificationStateDir, $LogsDir)
    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Info "Created directory: $dir"
        }
    }

    # Create the main PowerShell module
    $mainScript = @'
# Code-Notify PowerShell Module
# https://github.com/mylee04/code-notify

$script:VERSION = "1.13.1"
$script:ClaudeHome = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { "$env:USERPROFILE\.claude" }
$script:DefaultSettingsFile = "$script:ClaudeHome\settings.json"
$script:AlternateSettingsFile = "$env:USERPROFILE\.config\.claude\settings.json"
$script:SettingsFile = if (-not $env:CLAUDE_HOME -and -not (Test-Path $script:DefaultSettingsFile) -and (Test-Path $script:AlternateSettingsFile)) {
    $script:AlternateSettingsFile
} else {
    $script:DefaultSettingsFile
}
$script:NotificationsDir = "$script:ClaudeHome\notifications"
$script:VoiceFile = "$script:NotificationsDir\voice-enabled"
$script:SoundEnabledFile = "$script:NotificationsDir\sound-enabled"
$script:SoundCustomFile = "$script:NotificationsDir\sound-custom"
$script:DefaultSoundFile = "C:\Windows\Media\chimes.wav"
$script:CodexHome = "$env:USERPROFILE\.codex"
$script:CodexConfigFile = "$script:CodexHome\config.toml"
$script:GeminiHome = "$env:USERPROFILE\.gemini"
$script:GeminiSettingsFile = "$script:GeminiHome\settings.json"
$script:CodeNotifyConfigDir = "$env:USERPROFILE\.config\code-notify"
$script:ChannelsFile = "$script:CodeNotifyConfigDir\channels.json"
$script:UsageConfigFile = "$script:CodeNotifyConfigDir\usage.json"
$script:UsageStateFile = "$script:CodeNotifyConfigDir\usage-state.json"

# Helper functions for colored output
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Warning { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Header { param([string]$Message) Write-Host "`n$Message" -ForegroundColor White }

function Get-ToolDisplayName {
    param([string]$Tool = "claude")

    switch ($Tool.ToLower()) {
        "codex" { return "Codex" }
        "gemini" { return "Gemini" }
        default { return "Claude Code" }
    }
}

function Backup-ConfigFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    $backupDir = "$env:USERPROFILE\.config\code-notify\backups"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName = [System.IO.Path]::GetFileName($Path)
    Copy-Item $Path (Join-Path $backupDir "$safeName.$timestamp.bak") -ErrorAction SilentlyContinue
}

function Test-TomlTopLevelKey {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    $content = Get-Content $Path -Raw
    $match = [regex]::Match($content, '(?m)^\s*\[')
    $prefix = if ($match.Success) { $content.Substring(0, $match.Index) } else { $content }

    return [bool]([regex]::IsMatch($prefix, "(?m)^\\s*$([regex]::Escape($Key))\\s*="))
}

function Set-CodexNotifyConfig {
    param(
        [string]$Path,
        [string]$NotifyLine
    )

    $commentLine = "# Code-Notify: Desktop notifications"

    if (Test-Path $Path) {
        $content = Get-Content $Path -Raw
    } else {
        $content = "# Codex CLI Configuration`n# https://developers.openai.com/codex/config-reference/"
    }

    $content = (($content -split "`r?`n") | Where-Object {
        $_ -notmatch '^\s*# Code-Notify: Desktop notifications\s*$' -and $_ -notmatch '^\s*notify\s*='
    }) -join "`n"
    $content = $content.TrimEnd()

    $tableMatch = [regex]::Match($content, '(?m)^\s*\[')
    if ($tableMatch.Success) {
        $prefix = $content.Substring(0, $tableMatch.Index).TrimEnd()
        $suffix = $content.Substring($tableMatch.Index)
        if ($prefix) {
            $content = "$prefix`n`n$commentLine`n$NotifyLine`n`n$suffix"
        } else {
            $content = "$commentLine`n$NotifyLine`n`n$suffix"
        }
    } elseif ($content) {
        $content = "$content`n`n$commentLine`n$NotifyLine"
    } else {
        $content = "$commentLine`n$NotifyLine"
    }

    Set-Content $Path -Value $content -Encoding UTF8
}

function Test-GitInstalled {
    $null = Get-Command git -ErrorAction SilentlyContinue
    return $?
}

function Get-ProjectName {
    if (Test-GitInstalled) {
        try {
            $gitRoot = & git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitRoot) {
                return Split-Path $gitRoot -Leaf
            }
        } catch {
            # Not in a git repo, use folder name
        }
    }
    return Split-Path (Get-Location) -Leaf
}

function Get-ProjectRoot {
    if (Test-GitInstalled) {
        try {
            $gitRoot = & git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitRoot) {
                return $gitRoot
            }
        } catch {
            # Not in a git repo, use current directory
        }
    }
    return (Get-Location).Path
}

function Get-ClaudeTrustFile {
    if ($env:CODE_NOTIFY_CLAUDE_TRUST_FILE) {
        return $env:CODE_NOTIFY_CLAUDE_TRUST_FILE
    }

    return "$env:USERPROFILE\.claude.json"
}

function Test-ClaudeProjectTrusted {
    param(
        [string]$ProjectRoot = (Get-ProjectRoot)
    )

    $trustFile = Get-ClaudeTrustFile
    if (-not (Test-Path $trustFile)) {
        return $null
    }

    try {
        $trustConfig = Get-Content $trustFile -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $trustConfig -or -not $trustConfig.projects) {
        return $false
    }

    $projectEntry = $trustConfig.projects.PSObject.Properties[$ProjectRoot]
    if ($projectEntry -and $projectEntry.Value.hasTrustDialogAccepted -eq $true) {
        return $true
    }

    return $false
}

function Write-ClaudeProjectTrustWarning {
    param(
        [string]$ProjectRoot = (Get-ProjectRoot)
    )

    $isTrusted = Test-ClaudeProjectTrusted -ProjectRoot $ProjectRoot
    if ($null -eq $isTrusted -or $isTrusted) {
        return
    }

    Write-Output ""
    Write-Output "[!] Claude project trust does not appear to be accepted for this project yet"
    Write-Output "[i] Project hooks are configured, but Claude may ignore project settings until this project is trusted"
    Write-Output "[i] Open Claude Code in $ProjectRoot and accept the trust prompt if it appears"
}

function Send-Notification {
    param(
        [string]$Title = "Claude Code",
        [string]$Message = "Task completed",
        [string]$Type = "info"
    )

    $icon = switch ($Type) {
        "success" { "Info" }
        "error" { "Error" }
        "warning" { "Warning" }
        default { "Info" }
    }

    # Try BurntToast first
    if (Get-Module -ListAvailable -Name BurntToast) {
        Import-Module BurntToast -ErrorAction SilentlyContinue
        New-BurntToastNotification -Text $Title, $Message -ErrorAction SilentlyContinue
        return
    }

    # Fallback to native Windows toast notification
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast>
    <visual>
        <binding template="ToastText02">
            <text id="1">$Title</text>
            <text id="2">$Message</text>
        </binding>
    </visual>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Code-Notify").Show($toast)
    }
    catch {
        # Final fallback - balloon notification
        Add-Type -AssemblyName System.Windows.Forms
        $notification = New-Object System.Windows.Forms.NotifyIcon
        $notification.Icon = [System.Drawing.SystemIcons]::Information
        $notification.BalloonTipIcon = $icon
        $notification.BalloonTipTitle = $Title
        $notification.BalloonTipText = $Message
        $notification.Visible = $true
        $notification.ShowBalloonTip(10000)
        Start-Sleep -Seconds 1
        $notification.Dispose()
    }
}

function Send-VoiceNotification {
    param([string]$Message)

    if (Test-Path $script:VoiceFile) {
        $voice = Get-Content $script:VoiceFile -ErrorAction SilentlyContinue
        if (-not $voice) { $voice = "Microsoft David Desktop" }

        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

        try {
            $synth.SelectVoice($voice)
        } catch {
            # Use default voice if specified voice not found
        }

        $synth.SpeakAsync($Message) | Out-Null
    }
}

# Sound notification functions
function Test-SoundEnabled {
    return (Test-Path $script:SoundEnabledFile)
}

function Get-SoundFile {
    if (Test-Path $script:SoundCustomFile) {
        return Get-Content $script:SoundCustomFile -ErrorAction SilentlyContinue
    }
    return $script:DefaultSoundFile
}

function Send-SoundNotification {
    if (-not (Test-SoundEnabled)) { return }

    $soundFile = Get-SoundFile
    if (-not (Test-Path $soundFile)) { return }

    try {
        $player = New-Object System.Media.SoundPlayer
        $player.SoundLocation = $soundFile
        # Hooks run in short-lived PowerShell processes, so async playback can be cut off on exit.
        $player.PlaySync()
    } catch {
        # Silently fail if sound cannot be played
    }
}

function Enable-Sound {
    if (-not (Test-Path $script:NotificationsDir)) {
        New-Item -ItemType Directory -Path $script:NotificationsDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $script:SoundEnabledFile -Force | Out-Null
    Write-Success "Sound notifications enabled"

    $soundFile = Get-SoundFile
    Write-Info "Using: $soundFile"

    # Test the sound
    Send-SoundNotification
}

function Disable-Sound {
    if (Test-Path $script:SoundEnabledFile) {
        Remove-Item $script:SoundEnabledFile -Force
        Write-Success "Sound notifications disabled"
    } else {
        Write-Warning "Sound notifications were not enabled"
    }
}

function Set-CustomSound {
    param([string]$SoundPath)

    if (-not $SoundPath) {
        Write-Host "[X] Please provide a path to a sound file" -ForegroundColor Red
        Write-Host ""
        Write-Host "Usage: cn sound set <path>" -ForegroundColor Gray
        Write-Host "Example: cn sound set C:\sounds\notification.wav" -ForegroundColor Gray
        return
    }

    # Expand environment variables
    $SoundPath = [Environment]::ExpandEnvironmentVariables($SoundPath)

    if (-not (Test-Path $SoundPath)) {
        Write-Host "[X] Sound file not found: $SoundPath" -ForegroundColor Red
        return
    }

    # Validate extension
    $ext = [System.IO.Path]::GetExtension($SoundPath).ToLower()
    $validExtensions = @('.wav', '.aiff', '.mp3', '.wma')
    if ($ext -notin $validExtensions) {
        Write-Host "[X] Unsupported audio format: $ext" -ForegroundColor Red
        Write-Host "Supported formats: .wav, .aiff, .mp3, .wma" -ForegroundColor Gray
        return
    }

    if (-not (Test-Path $script:NotificationsDir)) {
        New-Item -ItemType Directory -Path $script:NotificationsDir -Force | Out-Null
    }

    $SoundPath | Set-Content $script:SoundCustomFile -Encoding UTF8
    New-Item -ItemType File -Path $script:SoundEnabledFile -Force | Out-Null

    Write-Success "Custom sound set: $SoundPath"
    Send-SoundNotification
}

function Reset-Sound {
    if (Test-Path $script:SoundCustomFile) {
        Remove-Item $script:SoundCustomFile -Force
    }
    Write-Success "Reset to default sound"
    Write-Info "Using: $script:DefaultSoundFile"
}

function Test-Sound {
    Write-Host "`n[*] Testing Sound" -ForegroundColor Cyan
    Write-Host "================`n" -ForegroundColor Cyan

    if (Test-SoundEnabled) {
        $soundFile = Get-SoundFile
        Write-Host "Playing: $soundFile" -ForegroundColor Gray
        Send-SoundNotification
        Write-Success "Sound played!"
    } else {
        Write-Warning "Sound is disabled"
        Write-Info "Enable with: cn sound on"
    }
}

function Get-SystemSounds {
    Write-Host "`n[*] Available System Sounds" -ForegroundColor Cyan
    Write-Host "===========================`n" -ForegroundColor Cyan

    $mediaPath = "C:\Windows\Media"
    if (Test-Path $mediaPath) {
        Write-Host "Windows Media folder ($mediaPath):" -ForegroundColor White
        Get-ChildItem -Path $mediaPath -Filter "*.wav" | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Gray
        } | Select-Object -First 20
        Write-Host "  ..." -ForegroundColor DarkGray
    } else {
        Write-Host "Cannot access Windows Media folder" -ForegroundColor Yellow
    }
}

function Show-SoundStatus {
    Write-Host "`n[*] Sound Status" -ForegroundColor Cyan
    Write-Host "================`n" -ForegroundColor Cyan

    if (Test-SoundEnabled) {
        $soundFile = Get-SoundFile
        if (Test-Path $script:SoundCustomFile) {
            Write-Host "[*] Sound: ENABLED (custom)" -ForegroundColor Green
        } else {
            Write-Host "[*] Sound: ENABLED (default)" -ForegroundColor Green
        }
        Write-Host "    File: $soundFile" -ForegroundColor Gray
    } else {
        Write-Host "[-] Sound: DISABLED" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  cn sound on              Enable with default system sound" -ForegroundColor Gray
    Write-Host "  cn sound off             Disable sound notifications" -ForegroundColor Gray
    Write-Host "  cn sound set <path>      Use custom sound file" -ForegroundColor Gray
    Write-Host "  cn sound default         Reset to system default" -ForegroundColor Gray
    Write-Host "  cn sound test            Play current sound" -ForegroundColor Gray
    Write-Host "  cn sound list            Show available system sounds" -ForegroundColor Gray
}

function Get-NotifyScript {
    return "$script:NotificationsDir\notify.ps1"
}

function Get-ClaudeNotifyCommand {
    param([string]$NotifyScript)
    return "powershell -ExecutionPolicy Bypass -File `"$NotifyScript`" notification claude"
}

function Get-ClaudeStopCommand {
    param([string]$NotifyScript)
    return "powershell -ExecutionPolicy Bypass -File `"$NotifyScript`" stop claude"
}

function Get-ManagedClaudeNotificationPattern {
    return '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*(notification|PreToolUse)(?:\s|$)'
}

function Get-ManagedClaudeStopPattern {
    return '(claude-notify|code-notify.*notifier\.sh|(?:^|[\\/])notify\.(?:ps1|sh)).*stop(?:\s|$)'
}

function Test-HookEntriesContainCommand {
    param(
        [object[]]$Entries,
        [string]$Matcher,
        [string]$Command
    )

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }

        $entryMatcher = ""
        if ($null -ne $entry.PSObject.Properties['matcher']) {
            $entryMatcher = [string]$entry.matcher
        }
        if ($entryMatcher -ne $Matcher) {
            continue
        }

        foreach ($hook in @($entry.hooks)) {
            if ($null -eq $hook) {
                continue
            }
            if ($null -eq $hook.PSObject.Properties['type'] -or $hook.type -ne "command") {
                continue
            }
            if ($null -ne $hook.PSObject.Properties['command'] -and [string]$hook.command -eq $Command) {
                return $true
            }
        }
    }

    return $false
}

function Test-ManagedClaudeHookCommand {
    param(
        [object]$Hook,
        [string]$ExactCommand,
        [string]$Pattern
    )

    if ($null -eq $Hook) {
        return $false
    }
    if ($null -eq $Hook.PSObject.Properties['type'] -or $Hook.type -ne "command") {
        return $false
    }
    if ($null -eq $Hook.PSObject.Properties['command']) {
        return $false
    }

    $command = [string]$Hook.command
    if ($command -eq $ExactCommand) {
        return $true
    }

    return ($command -match $Pattern)
}

function Remove-ManagedClaudeHookEntries {
    param(
        [object[]]$Entries,
        [string]$ExactCommand,
        [string]$Pattern
    )

    $result = @()

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }

        if ($null -eq $entry.PSObject.Properties['hooks']) {
            $result += $entry
            continue
        }

        $filteredHooks = @()
        foreach ($hook in @($entry.hooks)) {
            if (-not (Test-ManagedClaudeHookCommand -Hook $hook -ExactCommand $ExactCommand -Pattern $Pattern)) {
                $filteredHooks += $hook
            }
        }

        if ($filteredHooks.Count -eq 0) {
            continue
        }

        $entryClone = [ordered]@{}
        foreach ($prop in $entry.PSObject.Properties) {
            if ($prop.Name -eq "hooks") {
                $entryClone["hooks"] = $filteredHooks
            } else {
                $entryClone[$prop.Name] = $prop.Value
            }
        }
        if (-not $entryClone.Contains("hooks")) {
            $entryClone["hooks"] = $filteredHooks
        }

        $result += [PSCustomObject]$entryClone
    }

    return ,$result
}

function Get-ObjectPropertyNames {
    param([object]$Object)

    if ($null -eq $Object) {
        return @()
    }

    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys)
    }

    return @(
        $Object.PSObject.Properties |
            Where-Object { $_.MemberType -eq "NoteProperty" } |
            ForEach-Object { $_.Name }
    )
}

function Update-ClaudeSettingsHooks {
    param(
        [object]$Settings,
        [string]$NotifyScript,
        [switch]$Disable
    )

    if (-not $Settings) {
        $Settings = [PSCustomObject]@{}
    }

    if ($null -eq $Settings.PSObject.Properties['hooks'] -or $null -eq $Settings.hooks) {
        $Settings | Add-Member -Force -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
    } elseif ($Settings.hooks -isnot [pscustomobject] -and $Settings.hooks -isnot [hashtable]) {
        $Settings.PSObject.Properties.Remove("hooks")
        $Settings | Add-Member -Force -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
    }

    $notifyCommand = Get-ClaudeNotifyCommand -NotifyScript $NotifyScript
    $stopCommand = Get-ClaudeStopCommand -NotifyScript $NotifyScript
    $notificationPattern = Get-ManagedClaudeNotificationPattern
    $stopPattern = Get-ManagedClaudeStopPattern

    $notificationEntries = Remove-ManagedClaudeHookEntries -Entries @($Settings.hooks.Notification) -ExactCommand $notifyCommand -Pattern $notificationPattern
    $stopEntries = Remove-ManagedClaudeHookEntries -Entries @($Settings.hooks.Stop) -ExactCommand $stopCommand -Pattern $stopPattern

    if (-not $Disable) {
        $notificationEntries += [PSCustomObject]@{
            matcher = "idle_prompt"
            hooks = @(
                [PSCustomObject]@{
                    type = "command"
                    command = $notifyCommand
                }
            )
        }
        $stopEntries += [PSCustomObject]@{
            matcher = ""
            hooks = @(
                [PSCustomObject]@{
                    type = "command"
                    command = $stopCommand
                }
            )
        }
    }

    if ($notificationEntries.Count -gt 0) {
        $Settings.hooks | Add-Member -Force -NotePropertyName Notification -NotePropertyValue $notificationEntries
    } else {
        $Settings.hooks.PSObject.Properties.Remove("Notification")
    }

    if ($stopEntries.Count -gt 0) {
        $Settings.hooks | Add-Member -Force -NotePropertyName Stop -NotePropertyValue $stopEntries
    } else {
        $Settings.hooks.PSObject.Properties.Remove("Stop")
    }

    if ((Get-ObjectPropertyNames $Settings.hooks).Count -eq 0) {
        $Settings.PSObject.Properties.Remove("hooks")
    }

    return $Settings
}

function Test-ClaudeSettingsCurrentHooks {
    param(
        [string]$SettingsFile,
        [string]$NotifyScript
    )

    if (-not (Test-Path $SettingsFile)) {
        return $false
    }

    $settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $settings -or -not $settings.hooks) {
        return $false
    }

    $notifyCommand = Get-ClaudeNotifyCommand -NotifyScript $NotifyScript
    $stopCommand = Get-ClaudeStopCommand -NotifyScript $NotifyScript

    return (
        (Test-HookEntriesContainCommand -Entries @($settings.hooks.Notification) -Matcher "idle_prompt" -Command $notifyCommand) -and
        (Test-HookEntriesContainCommand -Entries @($settings.hooks.Stop) -Matcher "" -Command $stopCommand)
    )
}

function Test-NotificationsEnabled {
    param(
        [string]$Tool = "claude",
        [switch]$Project
    )

    switch ($Tool.ToLower()) {
        "codex" {
            if ($Project -or -not (Test-Path $script:CodexConfigFile)) {
                return $false
            }

            return Test-TomlTopLevelKey -Path $script:CodexConfigFile -Key "notify"
        }
        "gemini" {
            if ($Project -or -not (Test-Path $script:GeminiSettingsFile)) {
                return $false
            }

            $settings = Get-Content $script:GeminiSettingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            return ($settings -and $settings.hooks -and (($null -ne $settings.hooks.Notification) -or ($null -ne $settings.hooks.AfterAgent)))
        }
        default {
            if ($Project) {
                $projectRoot = Get-ProjectRoot
                $settingsFile = Join-Path $projectRoot ".claude\settings.json"
            } else {
                $settingsFile = $script:SettingsFile
            }

            if (-not (Test-Path $settingsFile)) {
                return $false
            }

            return Test-ClaudeSettingsCurrentHooks -SettingsFile $settingsFile -NotifyScript (Get-NotifyScript)
        }
    }
}

function Test-LegacyClaudeHooks {
    if (-not (Test-Path $script:SettingsFile)) {
        return $false
    }

    $raw = Get-Content $script:SettingsFile -Raw -ErrorAction SilentlyContinue
    if (-not $raw) {
        return $false
    }

    return ($raw -match 'claude-notify' -or $raw -match 'notify\.ps1.* notification"' -or $raw -match 'notify\.ps1.* stop"' -or $raw -match 'notify\.ps1.* PreToolUse')
}

function Repair-LegacyClaudeHooks {
    param([switch]$Quiet)

    if (Test-LegacyClaudeHooks) {
        if (-not $Quiet) {
            Write-Info "Repairing legacy Claude hooks..."
        }

        Enable-Notifications -Tool "claude"
        return $true
    }

    if (-not $Quiet) {
        Write-Info "No legacy hooks required repair"
    }

    return $false
}

function Enable-Notifications {
    param(
        [switch]$Project,
        [string]$Tool = "claude"
    )

    $tool = $Tool.ToLower()
    $notifyScript = Get-NotifyScript
    $toolDisplay = Get-ToolDisplayName $tool

    if ($Project -and $tool -ne "claude") {
        Write-Warning "Project notifications on Windows are only supported for Claude right now"
        return
    }

    switch ($tool) {
        "codex" {
            Write-Host "[>] Enabling Codex notifications globally" -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $script:CodexHome -Force | Out-Null
            Backup-ConfigFile $script:CodexConfigFile

            $escapedNotifyScript = $notifyScript -replace '\\', '\\\\'
            $notifyLine = 'notify = ["powershell", "-ExecutionPolicy", "Bypass", "-File", "' + $escapedNotifyScript + '", "codex"]'
            Set-CodexNotifyConfig -Path $script:CodexConfigFile -NotifyLine $notifyLine
            Write-Success "Codex notifications enabled!"
            Write-Info "Config: $script:CodexConfigFile"
            Send-Notification -Title "Code-Notify" -Message "Codex notifications enabled!" -Type "success"
            return
        }
        "gemini" {
            Write-Host "[>] Enabling Gemini notifications globally" -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $script:GeminiHome -Force | Out-Null
            Backup-ConfigFile $script:GeminiSettingsFile

            $settings = $null
            if (Test-Path $script:GeminiSettingsFile) {
                $settings = Get-Content $script:GeminiSettingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
            if (-not $settings) {
                $settings = [PSCustomObject]@{}
            }
            if (-not $settings.PSObject.Properties['tools']) {
                $settings | Add-Member -NotePropertyName tools -NotePropertyValue ([PSCustomObject]@{})
            }
            if (-not $settings.PSObject.Properties['hooks']) {
                $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{})
            }

            $settings.tools | Add-Member -Force -NotePropertyName enableHooks -NotePropertyValue $true
            $settings.hooks | Add-Member -Force -NotePropertyName enabled -NotePropertyValue $true
            $settings.hooks | Add-Member -Force -NotePropertyName Notification -NotePropertyValue @(
                @{
                    matcher = ""
                    hooks = @(
                        @{
                            name = "code-notify-notification"
                            type = "command"
                            command = "powershell -ExecutionPolicy Bypass -File `"$notifyScript`" notification gemini"
                            description = "Desktop notification when input needed"
                        }
                    )
                }
            )
            $settings.hooks | Add-Member -Force -NotePropertyName AfterAgent -NotePropertyValue @(
                @{
                    matcher = ""
                    hooks = @(
                        @{
                            name = "code-notify-complete"
                            type = "command"
                            command = "powershell -ExecutionPolicy Bypass -File `"$notifyScript`" stop gemini"
                            description = "Desktop notification when task complete"
                        }
                    )
                }
            )

            $settings | ConvertTo-Json -Depth 10 | Set-Content $script:GeminiSettingsFile -Encoding UTF8
            Write-Success "Gemini notifications enabled!"
            Write-Info "Config: $script:GeminiSettingsFile"
            Send-Notification -Title "Code-Notify" -Message "Gemini notifications enabled!" -Type "success"
            return
        }
        default {
            $projectName = Get-ProjectName

            if ($Project) {
                $projectRoot = Get-ProjectRoot
                $settingsFile = Join-Path $projectRoot ".claude\settings.json"
                $claudeDir = Join-Path $projectRoot ".claude"

                Write-Host "[>] Enabling notifications for project: $projectName" -ForegroundColor Cyan

                if (-not (Test-Path $claudeDir)) {
                    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
                }
            } else {
                $settingsFile = $script:SettingsFile
                Write-Host "[>] Enabling notifications globally" -ForegroundColor Cyan
            }

            Backup-ConfigFile $settingsFile

            $settings = [PSCustomObject]@{}
            if (Test-Path $settingsFile) {
                $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($existingSettings) {
                    $settings = $existingSettings
                }
            }

            $settings = Update-ClaudeSettingsHooks -Settings $settings -NotifyScript $notifyScript

            $parentDir = Split-Path $settingsFile -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }

            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8

            Write-Success "$toolDisplay notifications enabled!"
            Write-Info "Config: $settingsFile"
            if ($Project) {
                Write-ClaudeProjectTrustWarning -ProjectRoot $projectRoot
            }
            Send-Notification -Title "Code-Notify" -Message "$toolDisplay notifications enabled!" -Type "success"
        }
    }
}

function Disable-Notifications {
    param(
        [switch]$Project,
        [string]$Tool = "claude"
    )

    $tool = $Tool.ToLower()

    if ($Project -and $tool -ne "claude") {
        Write-Warning "Project notifications on Windows are only supported for Claude right now"
        return
    }

    switch ($tool) {
        "codex" {
            Write-Host "[>] Disabling Codex notifications globally" -ForegroundColor Cyan
            if (-not (Test-Path $script:CodexConfigFile)) {
                Write-Warning "Codex notifications are already disabled"
                return
            }

            Backup-ConfigFile $script:CodexConfigFile
            $content = @(Get-Content $script:CodexConfigFile | Where-Object {
                $_ -notmatch '^\s*# Code-Notify: Desktop notifications' -and $_ -notmatch '^\s*notify\s*='
            })
            $content | Set-Content $script:CodexConfigFile -Encoding UTF8
            Write-Success "Codex notifications disabled!"
            return
        }
        "gemini" {
            Write-Host "[>] Disabling Gemini notifications globally" -ForegroundColor Cyan
            if (-not (Test-Path $script:GeminiSettingsFile)) {
                Write-Warning "Gemini notifications are already disabled"
                return
            }

            Backup-ConfigFile $script:GeminiSettingsFile
            $settings = Get-Content $script:GeminiSettingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($settings -and $settings.hooks) {
                $settings.hooks.PSObject.Properties.Remove("Notification")
                $settings.hooks.PSObject.Properties.Remove("AfterAgent")
                $settings.hooks.PSObject.Properties.Remove("enabled")
                $settings | ConvertTo-Json -Depth 10 | Set-Content $script:GeminiSettingsFile -Encoding UTF8
                Write-Success "Gemini notifications disabled!"
            } else {
                Write-Warning "Gemini notifications were not enabled"
            }
            return
        }
        default {
            if ($Project) {
                $projectRoot = Get-ProjectRoot
                $settingsFile = Join-Path $projectRoot ".claude\settings.json"
                Write-Host "[>] Disabling notifications for project" -ForegroundColor Cyan
            } else {
                $settingsFile = $script:SettingsFile
                Write-Host "[>] Disabling notifications globally" -ForegroundColor Cyan
            }

            if (-not (Test-Path $settingsFile)) {
                Write-Warning "Notifications are already disabled"
                return
            }

            Backup-ConfigFile $settingsFile
            $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($settings -and $settings.hooks) {
                $settings = Update-ClaudeSettingsHooks -Settings $settings -NotifyScript (Get-NotifyScript) -Disable
                if ((Get-ObjectPropertyNames $settings).Count -eq 0) {
                    Remove-Item $settingsFile -Force -ErrorAction SilentlyContinue
                } else {
                    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
                }
                Write-Success "Notifications disabled!"
            } else {
                Write-Warning "Notifications were not enabled"
            }
        }
    }
}

function Show-Status {
    param(
        [switch]$Project,
        [string]$Tool = ""
    )

    Write-Host "`n[i] Code-Notify Status" -ForegroundColor Cyan
    Write-Host "========================`n" -ForegroundColor Cyan

    if ($Project) {
        $projectRoot = Get-ProjectRoot
        $projectName = Get-ProjectName
        $projectSettings = Join-Path $projectRoot ".claude\settings.json"

        Write-Host "[D] Project: $projectName" -ForegroundColor White
        Write-Host "    Location: $projectRoot" -ForegroundColor DarkGray

        if (Test-NotificationsEnabled -Tool "claude" -Project) {
            Write-Host "[*] Claude project notifications: ENABLED" -ForegroundColor Green
            Write-Host "    Config: $projectSettings" -ForegroundColor Gray
        } else {
            Write-Host "[-] Claude project notifications: DISABLED" -ForegroundColor DarkGray
        }
    } else {
        $toolsToShow = @("claude", "codex", "gemini")
        if ($Tool) {
            $toolsToShow = @($Tool.ToLower())
        }

        foreach ($currentTool in $toolsToShow) {
            $displayName = Get-ToolDisplayName $currentTool
            $configPath = switch ($currentTool) {
                "codex" { $script:CodexConfigFile }
                "gemini" { $script:GeminiSettingsFile }
                default { $script:SettingsFile }
            }

            if (Test-NotificationsEnabled -Tool $currentTool) {
                Write-Host "[*] $displayName notifications: ENABLED" -ForegroundColor Green
                Write-Host "    Config: $configPath" -ForegroundColor Gray
            } else {
                Write-Host "[-] $displayName notifications: DISABLED" -ForegroundColor DarkGray
            }
        }

        $projectRoot = Get-ProjectRoot
        $projectName = Get-ProjectName
        Write-Host "`n[D] Project: $projectName" -ForegroundColor White
        Write-Host "    Location: $projectRoot" -ForegroundColor DarkGray

        if (Test-NotificationsEnabled -Tool "claude" -Project) {
            Write-Host "[*] Claude project notifications: ENABLED" -ForegroundColor Green
        } else {
            Write-Host "[-] Claude project notifications: DISABLED" -ForegroundColor DarkGray
        }
    }

    # Voice status
    Write-Host ""
    if (Test-Path $script:VoiceFile) {
        $voice = Get-Content $script:VoiceFile
        Write-Host "[S] Voice notifications: ENABLED ($voice)" -ForegroundColor Green
    } else {
        Write-Host "[-] Voice notifications: DISABLED" -ForegroundColor DarkGray
    }

    # Sound status
    if (Test-SoundEnabled) {
        $soundFile = Get-SoundFile
        $soundName = Split-Path $soundFile -Leaf
        if (Test-Path $script:SoundCustomFile) {
            Write-Host "[*] Sound: ENABLED (custom: $soundName)" -ForegroundColor Green
        } else {
            Write-Host "[*] Sound: ENABLED (default: $soundName)" -ForegroundColor Green
        }
    } else {
        Write-Host "[-] Sound: DISABLED" -ForegroundColor DarkGray
    }

    $channelConfig = Get-ChannelsConfig
    $channelCount = @($channelConfig.channels).Count
    if ($channelConfig.enabled -and $channelCount -gt 0) {
        Write-Host "[*] Channels: ENABLED ($channelCount configured)" -ForegroundColor Green
    } elseif ($channelCount -gt 0) {
        Write-Host "[-] Channels: DISABLED ($channelCount configured)" -ForegroundColor DarkGray
    } else {
        Write-Host "[-] Channels: not configured" -ForegroundColor DarkGray
    }

    $usageConfig = Get-UsageConfig
    if ($usageConfig.enabled) {
        Write-Host "[*] Usage alerts: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "[-] Usage alerts: DISABLED" -ForegroundColor DarkGray
    }

    # BurntToast status
    Write-Host ""
    if (Get-Module -ListAvailable -Name BurntToast) {
        Write-Host "[OK] BurntToast: Installed" -ForegroundColor Green
    } else {
        Write-Host "[!] BurntToast: Not installed (using native notifications)" -ForegroundColor Yellow
    }

    Write-Host "`ncode-notify version $script:VERSION" -ForegroundColor DarkGray
}

function Enable-Voice {
    param([switch]$Project)

    Write-Host "`n[S] Enabling Voice Notifications" -ForegroundColor Cyan
    Write-Host "================================`n" -ForegroundColor Cyan

    # List available voices
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voices = $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name }

    Write-Host "Available voices:" -ForegroundColor White
    $voices | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
    Write-Host ""

    $defaultVoice = "Microsoft David Desktop"
    if ($voices -contains "Microsoft Zira Desktop") {
        $defaultVoice = "Microsoft Zira Desktop"
    }

    $voice = Read-Host "Which voice would you like? (default: $defaultVoice)"
    if (-not $voice) { $voice = $defaultVoice }

    if ($Project) {
        $projectRoot = Get-ProjectRoot
        $voiceFile = Join-Path $projectRoot ".claude\voice"
        $claudeDir = Join-Path $projectRoot ".claude"
        if (-not (Test-Path $claudeDir)) {
            New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
        }
    } else {
        $voiceFile = $script:VoiceFile
        if (-not (Test-Path $script:NotificationsDir)) {
            New-Item -ItemType Directory -Path $script:NotificationsDir -Force | Out-Null
        }
    }

    $voice | Set-Content $voiceFile -Encoding UTF8
    Write-Success "Voice notifications enabled with voice: $voice"

    # Test voice
    $synth.SelectVoice($voice)
    $synth.SpeakAsync("Voice notifications enabled") | Out-Null
}

function Disable-Voice {
    param([switch]$Project)

    if ($Project) {
        $projectRoot = Get-ProjectRoot
        $voiceFile = Join-Path $projectRoot ".claude\voice"
    } else {
        $voiceFile = $script:VoiceFile
    }

    if (Test-Path $voiceFile) {
        Remove-Item $voiceFile -Force
        Write-Success "Voice notifications disabled"
    } else {
        Write-Warning "Voice notifications were not enabled"
    }
}

function Send-TestNotification {
    Write-Host "`n[*] Testing Notifications" -ForegroundColor Cyan
    Write-Host "=========================`n" -ForegroundColor Cyan

    Send-Notification -Title "Code-Notify Test" -Message "Notifications are working!" -Type "success"
    Write-Success "Test notification sent!"

    if (Test-Path $script:VoiceFile) {
        Send-VoiceNotification -Message "Test notification successful, Master"
    }
}

function Get-InstallMethod {
    if ($env:CODE_NOTIFY_INSTALL_METHOD) {
        return $env:CODE_NOTIFY_INSTALL_METHOD.Trim().ToLowerInvariant()
    }

    return "script"
}

function Get-UpdateCommand {
    switch (Get-InstallMethod) {
        "npm" {
            return "npm install -g code-notify@latest"
        }
        default {
            return "irm https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install-windows.ps1 | iex"
        }
    }
}

function Normalize-Version {
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    return (($Version.Trim()) -replace '^[vV]', '')
}

function Compare-Version {
    param(
        [string]$CurrentVersion,
        [string]$LatestVersion
    )

    $current = Normalize-Version $CurrentVersion
    $latest = Normalize-Version $LatestVersion

    try {
        $currentVersionObject = [version]$current
        $latestVersionObject = [version]$latest

        if ($currentVersionObject -lt $latestVersionObject) {
            return -1
        }

        if ($currentVersionObject -gt $latestVersionObject) {
            return 1
        }

        return 0
    }
    catch {
        $currentParts = $current.Split('.')
        $latestParts = $latest.Split('.')
        $maxParts = [Math]::Max($currentParts.Count, $latestParts.Count)

        for ($i = 0; $i -lt $maxParts; $i++) {
            $currentDigits = if ($i -lt $currentParts.Count) { ($currentParts[$i] -replace '[^\d]', '') } else { '' }
            $latestDigits = if ($i -lt $latestParts.Count) { ($latestParts[$i] -replace '[^\d]', '') } else { '' }

            $currentPart = if ([string]::IsNullOrWhiteSpace($currentDigits)) { 0 } else { [int]$currentDigits }
            $latestPart = if ([string]::IsNullOrWhiteSpace($latestDigits)) { 0 } else { [int]$latestDigits }

            if ($currentPart -lt $latestPart) {
                return -1
            }

            if ($currentPart -gt $latestPart) {
                return 1
            }
        }

        return 0
    }
}

function Get-LatestReleaseVersion {
    if ($env:CODE_NOTIFY_LATEST_VERSION) {
        return Normalize-Version $env:CODE_NOTIFY_LATEST_VERSION
    }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/mylee04/code-notify/releases/latest" -Headers @{ "User-Agent" = "code-notify" }
        if ($release.tag_name) {
            return Normalize-Version $release.tag_name
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-UpdateStatus {
    $currentVersion = Normalize-Version $script:VERSION
    $latestVersion = Get-LatestReleaseVersion

    if (-not $latestVersion) {
        return [PSCustomObject]@{
            CurrentVersion = $currentVersion
            LatestVersion = $null
            Comparison = $null
        }
    }

    return [PSCustomObject]@{
        CurrentVersion = $currentVersion
        LatestVersion = $latestVersion
        Comparison = (Compare-Version -CurrentVersion $currentVersion -LatestVersion $latestVersion)
    }
}

function Write-UpdateStatus {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Status
    )

    if (-not $Status.LatestVersion) {
        Write-Output "[i] Current version: $($Status.CurrentVersion)"
        Write-Output "[!] Could not determine the latest release"
        return
    }

    switch ($Status.Comparison) {
        -1 {
            Write-Output "[i] Current version: $($Status.CurrentVersion)"
            Write-Output "[!] Update available: $($Status.CurrentVersion) -> $($Status.LatestVersion)"
        }
        0 {
            Write-Output "[i] Current version: $($Status.CurrentVersion)"
            Write-Output "[OK] Code-Notify is up to date ($($Status.CurrentVersion))"
        }
        1 {
            Write-Output "[i] Current version: $($Status.CurrentVersion)"
            Write-Output "[i] Installed version is newer than the latest release ($($Status.LatestVersion))"
        }
    }
}

function Update-CodeNotify {
    param(
        [switch]$Check
    )

    $installMethod = Get-InstallMethod
    $updateCommand = Get-UpdateCommand
    $updateStatus = Get-UpdateStatus

    if ($Check) {
        Write-Output ""
        Write-Output "[i] Checking for updates..."
        Write-UpdateStatus -Status $updateStatus
        Write-Output "To update code-notify, run:"
        Write-Output "  $updateCommand"
        return
    }

    if ($updateStatus.LatestVersion) {
        if ($updateStatus.Comparison -eq 0) {
            Write-Output ""
            Write-Output "[i] Checking for updates..."
            Write-UpdateStatus -Status $updateStatus
            return
        }

        if ($updateStatus.Comparison -eq 1) {
            Write-Output ""
            Write-Output "[i] Checking for updates..."
            Write-UpdateStatus -Status $updateStatus
            return
        }
    }

    Write-Host "`n[>] Updating Code-Notify" -ForegroundColor Cyan
    $tempScript = Join-Path $env:TEMP "code-notify-update.ps1"

    try {
        if (-not $updateStatus.LatestVersion) {
            Write-Warning "Could not determine the latest release; proceeding with update"
        } else {
            Write-Info "Current version: $($updateStatus.CurrentVersion)"
            Write-Info "Latest release: $($updateStatus.LatestVersion)"
            Write-Info "Update available: $($updateStatus.CurrentVersion) -> $($updateStatus.LatestVersion)"
        }

        switch ($installMethod) {
            "npm" {
                $null = Get-Command npm -ErrorAction Stop
                & npm install -g code-notify@latest
                if ($LASTEXITCODE -ne 0) {
                    throw "npm install failed with exit code $LASTEXITCODE"
                }
            }
            default {
                Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install-windows.ps1" -OutFile $tempScript
                & $tempScript -Silent -Force
            }
        }
        Write-Success "Update complete!"
        Write-Info "Run 'code-notify version' in a new shell to confirm the installed version"
    }
    catch {
        Write-Host "[X] Failed to update code-notify: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-CodeNotifyConfigDir {
    if (-not (Test-Path $script:CodeNotifyConfigDir)) {
        New-Item -ItemType Directory -Path $script:CodeNotifyConfigDir -Force | Out-Null
    }
}

function Read-CodeNotifyJson {
    param(
        [string]$Path,
        [string]$DefaultJson
    )

    if (Test-Path $Path) {
        try {
            return (Get-Content $Path -Raw | ConvertFrom-Json)
        } catch {
            return ($DefaultJson | ConvertFrom-Json)
        }
    }
    return ($DefaultJson | ConvertFrom-Json)
}

function Save-CodeNotifyJson {
    param(
        [string]$Path,
        [object]$Value
    )

    Ensure-CodeNotifyConfigDir
    $Value | ConvertTo-Json -Depth 20 | Set-Content $Path -Encoding UTF8
}

function Get-DefaultChannelsConfig {
    return ('{"enabled":true,"channels":[]}' | ConvertFrom-Json)
}

function Get-ChannelsConfig {
    return Read-CodeNotifyJson -Path $script:ChannelsFile -DefaultJson '{"enabled":true,"channels":[]}'
}

function Test-ChannelUrl {
    param(
        [string]$Provider,
        [string]$Url
    )

    if ($Provider -eq "slack") {
        return ($Url.StartsWith("https://hooks.slack.com/") -or $Url.StartsWith("https://hooks.slack-gov.com/"))
    }
    if ($Provider -eq "discord") {
        return ($Url.StartsWith("https://discord.com/api/webhooks/") -or $Url.StartsWith("https://discordapp.com/api/webhooks/"))
    }
    return $false
}

function Add-Channel {
    param(
        [string]$Provider,
        [string]$Url,
        [string]$Name
    )

    if (-not $Provider -or -not $Url) {
        Write-Host "Usage: cn channels add <slack|discord> <webhook-url> [--name <name>]" -ForegroundColor Gray
        return
    }
    $Provider = $Provider.ToLower()
    if (-not $Name) { $Name = $Provider }
    if (-not (Test-ChannelUrl -Provider $Provider -Url $Url)) {
        Write-Error "Invalid $Provider webhook URL"
        return
    }

    $config = Get-ChannelsConfig
    $channels = @($config.channels | Where-Object { $_.name -ne $Name })
    $channels += [pscustomobject]@{ name = $Name; provider = $Provider; url = $Url }
    $config.enabled = $true
    $config.channels = $channels
    Save-CodeNotifyJson -Path $script:ChannelsFile -Value $config
    Write-Success "Channel saved: $Name ($Provider)"
}

function Show-ChannelsStatus {
    Write-Host "`n[*] Delivery Channels" -ForegroundColor Cyan
    Write-Host ""
    $config = Get-ChannelsConfig
    if ($config.enabled) {
        Write-Host "Status: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "Status: DISABLED" -ForegroundColor DarkGray
    }
    $channels = @($config.channels)
    if ($channels.Count -eq 0) {
        Write-Host "No Slack/Discord channels configured" -ForegroundColor DarkGray
        return
    }
    foreach ($channel in $channels) {
        try {
            $hostName = ([uri]$channel.url).Host
        } catch {
            $hostName = "unknown"
        }
        Write-Host "[*] $($channel.name): $($channel.provider) ($hostName)" -ForegroundColor Green
    }
}

function Remove-Channel {
    param([string]$Name)

    if (-not $Name) {
        Write-Error "Please specify a channel name"
        return
    }
    $config = Get-ChannelsConfig
    $before = @($config.channels).Count
    $config.channels = @($config.channels | Where-Object { $_.name -ne $Name })
    if (@($config.channels).Count -eq $before) {
        Write-Error "Channel not found: $Name"
        return
    }
    Save-CodeNotifyJson -Path $script:ChannelsFile -Value $config
    Write-Success "Channel removed: $Name"
}

function Set-ChannelsEnabled {
    param([bool]$Enabled)

    $config = Get-ChannelsConfig
    $config.enabled = $Enabled
    Save-CodeNotifyJson -Path $script:ChannelsFile -Value $config
    if ($Enabled) {
        Write-Success "Channels enabled"
    } else {
        Write-Success "Channels disabled"
    }
}

function Reset-Channels {
    Save-CodeNotifyJson -Path $script:ChannelsFile -Value (Get-DefaultChannelsConfig)
    Write-Success "Channels reset"
}

function Send-ChannelDelivery {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Context = ""
    )

    $config = Get-ChannelsConfig
    if (-not $config.enabled) { return }
    foreach ($channel in @($config.channels)) {
        try {
            $text = $Title
            if ($Message) { $text = "$text`n$Message" }
            if ($Context) { $text = "$text`n$Context" }
            if ($channel.provider -eq "discord") {
                $payload = @{ content = $text; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Depth 10
            } else {
                $payload = @{ text = $text } | ConvertTo-Json -Depth 10
            }
            Invoke-RestMethod -Uri $channel.url -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 5 | Out-Null
        } catch {
        }
    }
}

function Test-Channels {
    param([string]$Target = "all")

    $config = Get-ChannelsConfig
    $count = 0
    foreach ($channel in @($config.channels)) {
        if ($Target -ne "all" -and $Target -ne $channel.name) { continue }
        $count++
        Send-ChannelDelivery -Title "Code-Notify Test" -Message "Slack/Discord delivery is working." -Context "Channel: $($channel.name)"
    }
    if ($count -eq 0) {
        Write-Error "No matching channels configured"
    } else {
        Write-Success "Test message sent to $count channel(s)"
    }
}

function Invoke-ChannelsCommand {
    param(
        [string]$SubCommand = "status",
        [string[]]$Args = @()
    )

    switch ($SubCommand) {
        "add" {
            $provider = if ($Args.Count -gt 0) { $Args[0] } else { "" }
            $url = if ($Args.Count -gt 1) { $Args[1] } else { "" }
            $name = ""
            for ($i = 2; $i -lt $Args.Count; $i++) {
                if ($Args[$i] -eq "--name" -and ($i + 1) -lt $Args.Count) {
                    $name = $Args[$i + 1]
                }
            }
            Add-Channel -Provider $provider -Url $url -Name $name
        }
        "remove" { Remove-Channel -Name ($Args | Select-Object -First 1) }
        "test" { Test-Channels -Target ($(if ($Args.Count -gt 0) { $Args[0] } else { "all" })) }
        "on" { Set-ChannelsEnabled -Enabled $true }
        "off" { Set-ChannelsEnabled -Enabled $false }
        "reset" { Reset-Channels }
        default { Show-ChannelsStatus }
    }
}

function Get-DefaultUsageConfig {
    return ('{"enabled":false,"providers":["codex","claude"],"thresholds":[20,10],"provider_enabled":{"codex":false,"claude":false},"reset_alerts":{"enabled":true,"voice":true,"sound":true,"sound_file":""}}' | ConvertFrom-Json)
}

function Get-UsageConfig {
    $config = Read-CodeNotifyJson -Path $script:UsageConfigFile -DefaultJson '{"enabled":false,"providers":["codex","claude"],"thresholds":[20,10],"provider_enabled":{"codex":false,"claude":false},"reset_alerts":{"enabled":true,"voice":true,"sound":true,"sound_file":""}}'
    if (-not $config.reset_alerts) {
        $config | Add-Member -NotePropertyName reset_alerts -NotePropertyValue ([pscustomobject]@{ enabled = $true; voice = $true; sound = $true; sound_file = "" }) -Force
    }
    return $config
}

function Save-UsageConfig {
    param([object]$Config)
    Save-CodeNotifyJson -Path $script:UsageConfigFile -Value $Config
}

function Set-UsageEnabled {
    param(
        [string]$Provider = "all",
        [bool]$Enabled
    )

    $config = Get-UsageConfig
    if (-not $config.provider_enabled) {
        $config | Add-Member -NotePropertyName provider_enabled -NotePropertyValue ([pscustomobject]@{ codex = $false; claude = $false }) -Force
    }
    $targets = if (-not $Provider -or $Provider -eq "all") { @("codex", "claude") } else { @($Provider.ToLower()) }
    foreach ($target in $targets) {
        if ($target -ne "codex" -and $target -ne "claude") {
            Write-Error "Unsupported usage provider: $target"
            return
        }
        $config.provider_enabled.$target = $Enabled
    }
    $config.enabled = [bool]($config.provider_enabled.codex -or $config.provider_enabled.claude)
    Save-UsageConfig -Config $config
    if ($Enabled) {
        Write-Success "Usage alerts enabled"
    } else {
        Write-Success "Usage alerts disabled"
    }
}

function Set-UsageThresholds {
    param([int[]]$Thresholds = @(20, 10))
    $config = Get-UsageConfig
    $config.thresholds = @($Thresholds | Sort-Object -Descending -Unique)
    Save-UsageConfig -Config $config
    Write-Success "Usage thresholds set: $($config.thresholds -join ',')"
}

function Show-UsageStatus {
    Write-Host "`n[*] Usage Alerts" -ForegroundColor Cyan
    Write-Host ""
    $config = Get-UsageConfig
    if ($config.enabled) {
        Write-Host "Status: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "Status: DISABLED" -ForegroundColor DarkGray
    }
    Write-Host "Thresholds: $($config.thresholds -join ',')" -ForegroundColor Cyan
    Write-Host "codex: $(if ($config.provider_enabled.codex) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host "claude: $(if ($config.provider_enabled.claude) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host "Reset alerts: $(if ($config.reset_alerts.enabled) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host "Reset voice: $(if ($config.reset_alerts.voice) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host "Reset sound: $(if ($config.reset_alerts.sound) { 'ENABLED' } else { 'DISABLED' })"
    Write-Host ""
    Write-Host "Usage checks use local Codex/Claude auth files and provider usage endpoints." -ForegroundColor DarkGray
}

function Invoke-UsageSetup {
    param([string[]]$Args = @())

    $provider = "all"
    foreach ($arg in $Args) {
        if ($arg -in @("codex", "claude", "all")) {
            $provider = $arg
        }
    }

    Set-UsageEnabled -Provider $provider -Enabled $true
    Set-UsageThresholds -Thresholds @(20, 10)
    Set-UsageResetAlert -Field "enabled" -Value $true
    Set-UsageResetAlert -Field "voice" -Value $true
    Set-UsageResetAlert -Field "sound" -Value $true
    Set-UsageResetAlert -Field "sound_file" -Value ""
    Write-Success "Usage reset alerts configured"
    Write-Info "Windows background usage watch is not installed in this release."
    Show-UsageStatus
}

function Set-UsageResetAlert {
    param(
        [string]$Field,
        [object]$Value
    )
    $config = Get-UsageConfig
    if (-not $config.reset_alerts) {
        $config | Add-Member -NotePropertyName reset_alerts -NotePropertyValue ([pscustomobject]@{ enabled = $true; voice = $true; sound = $true; sound_file = "" }) -Force
    }
    $config.reset_alerts.$Field = $Value
    Save-UsageConfig -Config $config
}

function Invoke-UsageResetAlertsCommand {
    param([string[]]$Args = @())
    $sub = if ($Args.Count -gt 0) { $Args[0] } else { "status" }
    switch ($sub) {
        "on" { Set-UsageResetAlert -Field "enabled" -Value $true; Write-Success "Usage reset alerts enabled" }
        "off" { Set-UsageResetAlert -Field "enabled" -Value $false; Write-Success "Usage reset alerts disabled" }
        "voice" {
            $value = if ($Args.Count -gt 1) { $Args[1] } else { "status" }
            if ($value -eq "on") { Set-UsageResetAlert -Field "voice" -Value $true; Write-Success "Usage reset voice enabled" }
            elseif ($value -eq "off") { Set-UsageResetAlert -Field "voice" -Value $false; Write-Success "Usage reset voice disabled" }
            else { Show-UsageStatus }
        }
        "sound" {
            $value = if ($Args.Count -gt 1) { $Args[1] } else { "status" }
            if ($value -eq "on") { Set-UsageResetAlert -Field "sound" -Value $true; Write-Success "Usage reset sound enabled" }
            elseif ($value -eq "off") { Set-UsageResetAlert -Field "sound" -Value $false; Write-Success "Usage reset sound disabled" }
            elseif ($value -eq "set" -and $Args.Count -gt 2) { Set-UsageResetAlert -Field "sound_file" -Value $Args[2]; Set-UsageResetAlert -Field "sound" -Value $true; Write-Success "Usage reset sound set" }
            elseif ($value -eq "default") { Set-UsageResetAlert -Field "sound_file" -Value ""; Set-UsageResetAlert -Field "sound" -Value $true; Write-Success "Usage reset sound reset to distinct default" }
            else { Show-UsageStatus }
        }
        default { Show-UsageStatus }
    }
}

function Invoke-UsageCommand {
    param(
        [string]$SubCommand = "status",
        [string[]]$Args = @()
    )

    switch ($SubCommand) {
        "setup" { Invoke-UsageSetup -Args $Args }
        "on" { Set-UsageEnabled -Provider ($(if ($Args.Count -gt 0) { $Args[0] } else { "all" })) -Enabled $true }
        "off" { Set-UsageEnabled -Provider ($(if ($Args.Count -gt 0) { $Args[0] } else { "all" })) -Enabled $false }
        "check" { Write-Info "Windows usage polling will run from hook notifications in a future update. Current status follows."; Show-UsageStatus }
        "watch" { Write-Info "Windows usage watch is not installed as a background scheduler in this release."; Show-UsageStatus }
        "reset-alerts" { Invoke-UsageResetAlertsCommand -Args $Args }
        "reset-state" {
            if (Test-Path $script:UsageStateFile) { Remove-Item $script:UsageStateFile -Force }
            Write-Success "Usage alert state reset"
        }
        default { Show-UsageStatus }
    }
}

function Show-Help {
    Write-Host @"

Code-Notify - Native Windows notifications for Claude Code, Codex, and Gemini CLI

USAGE:
    code-notify <command> [options]
    cn <command>              # Short alias
    cnp <command>             # Project command alias

COMMANDS:
    on [tool|all]   Enable notifications globally or for a specific tool
    off [tool|all]  Disable notifications globally or for a specific tool
    status [tool|all] Show notification status
    test            Send a test notification
    update [check]  Update code-notify or check the latest release
    channels <cmd>  Configure Slack/Discord delivery
    usage <cmd>     Configure Codex/Claude usage alert settings
    voice on        Enable voice notifications
    voice off       Disable voice notifications
    help            Show this help message
    version         Show version information

TOOLS:
    claude          Claude Code
    codex           OpenAI Codex CLI
    gemini          Google Gemini CLI

SOUND COMMANDS:
    sound on        Enable with default system sound
    sound off       Disable sound notifications
    sound set <path> Use custom sound file (.wav, .mp3, .wma)
    sound default   Reset to system default
    sound test      Play current sound
    sound list      Show available system sounds
    sound status    Show sound configuration

CHANNEL COMMANDS:
    channels status
    channels add slack <url> [--name <name>]
    channels add discord <url> [--name <name>]
    channels remove <name>
    channels test <name|all>
    channels on|off

USAGE COMMANDS:
    usage status
    usage setup [codex|claude|all]
    usage on [codex|claude|all]
    usage off [codex|claude|all]
    usage check [codex|claude|all]
    usage reset-alerts on|off
    usage reset-alerts voice on|off
    usage reset-alerts sound on|off|set <path>|default
    usage reset-state

PROJECT COMMANDS:
    project on      Enable for current project (Claude project hooks) (or: cnp on)
    project off     Disable for current project (Claude project hooks) (or: cnp off)
    project status  Check project status (Claude project hooks) (or: cnp status)
    project voice   Set project-specific voice (or: cnp voice)

EXAMPLES:
    code-notify on            # Enable Claude notifications
    cn on all                 # Enable all detected tools
    cn on codex               # Enable Codex notifications
    cn off all                # Disable all tools
    cn off gemini             # Disable Gemini notifications
    cnp on                    # Enable Claude project notifications
    cn test                   # Send test notification
    cn update check           # Check whether an update is needed and show the update command
    cn channels status
    cn usage status
    cn usage setup
    cn sound on               # Enable notification sounds
    cn sound set C:\sounds\ding.wav  # Use custom sound

MORE INFO:
    https://github.com/mylee04/code-notify

"@ -ForegroundColor Gray
}

# Main command handler
function Invoke-CodeNotify {
    param(
        [Parameter(Position=0)]
        [string]$Command = "help",

        [Parameter(Position=1)]
        [string]$SubCommand,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Args
    )

    $toolCommands = @("claude", "codex", "gemini")
    $unsupportedTools = @("omp")

    switch ($Command.ToLower()) {
        "on" {
            if ($SubCommand -and ($unsupportedTools -contains $SubCommand.ToLower())) {
                Write-Warning "omp is not yet supported on Windows. Windows support is planned."
            } elseif ($SubCommand -and ($toolCommands -contains $SubCommand.ToLower())) {
                Enable-Notifications -Tool $SubCommand
            } else {
                Enable-Notifications
            }
        }
        "off" {
            if ($SubCommand -and ($unsupportedTools -contains $SubCommand.ToLower())) {
                Write-Warning "omp is not yet supported on Windows. Windows support is planned."
            } elseif ($SubCommand -and ($toolCommands -contains $SubCommand.ToLower())) {
                Disable-Notifications -Tool $SubCommand
            } else {
                Disable-Notifications
            }
        }
        "status" {
            if ($SubCommand -and ($unsupportedTools -contains $SubCommand.ToLower())) {
                Write-Warning "omp is not yet supported on Windows. Windows support is planned."
            } elseif ($SubCommand -and ($toolCommands -contains $SubCommand.ToLower())) {
                Show-Status -Tool $SubCommand
            } else {
                Show-Status
            }
        }
        "test" { Send-TestNotification }
        "update" {
            if ($SubCommand -eq "check") {
                Update-CodeNotify -Check
            } else {
                Update-CodeNotify
            }
        }
        "repair-hooks" {
            if ($SubCommand -eq "--quiet") {
                Repair-LegacyClaudeHooks -Quiet | Out-Null
            } else {
                Repair-LegacyClaudeHooks | Out-Null
            }
        }
        "voice" {
            switch ($SubCommand) {
                "on" { Enable-Voice }
                "off" { Disable-Voice }
                default {
                    if (Test-Path $script:VoiceFile) {
                        $voice = Get-Content $script:VoiceFile
                        Write-Host "[S] Voice: ENABLED ($voice)" -ForegroundColor Green
                    } else {
                        Write-Host "[-] Voice: DISABLED" -ForegroundColor DarkGray
                    }
                }
            }
        }
        "sound" {
            switch ($SubCommand) {
                "on" { Enable-Sound }
                "off" { Disable-Sound }
                "set" { Set-CustomSound -SoundPath ($Args | Select-Object -First 1) }
                "default" { Reset-Sound }
                "test" { Test-Sound }
                "list" { Get-SystemSounds }
                "status" { Show-SoundStatus }
                default { Show-SoundStatus }
            }
        }
        "channels" {
            Invoke-ChannelsCommand -SubCommand ($(if ($SubCommand) { $SubCommand } else { "status" })) -Args $Args
        }
        "usage" {
            Invoke-UsageCommand -SubCommand ($(if ($SubCommand) { $SubCommand } else { "status" })) -Args $Args
        }
        "project" {
            switch ($SubCommand) {
                "on" { Enable-Notifications -Project }
                "off" { Disable-Notifications -Project }
                "status" { Show-Status -Project }
                "voice" {
                    if ($Args -and $Args[0] -eq "on") { Enable-Voice -Project }
                    elseif ($Args -and $Args[0] -eq "off") { Disable-Voice -Project }
                    else { Show-Status -Project }
                }
                default { Show-Status -Project }
            }
        }
        "help" { Show-Help }
        "version" { Write-Output "code-notify version $script:VERSION" }
        default { Show-Help }
    }
}

function Invoke-ClaudeNotify {
    param(
        [Parameter(Position=0)]
        [string]$Command = "help",

        [Parameter(Position=1)]
        [string]$SubCommand,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Args
    )

    Invoke-CodeNotify -Command $Command -SubCommand $SubCommand -Args $Args
}

# Export functions
Export-ModuleMember -Function @(
    'Invoke-CodeNotify',
    'Invoke-ClaudeNotify',
    'Send-Notification',
    'Send-VoiceNotification',
    'Send-SoundNotification',
    'Enable-Notifications',
    'Disable-Notifications',
    'Show-Status',
    'Enable-Voice',
    'Disable-Voice',
    'Enable-Sound',
    'Disable-Sound',
    'Set-CustomSound',
    'Reset-Sound',
    'Test-Sound',
    'Get-SystemSounds',
    'Show-SoundStatus',
    'Send-TestNotification',
    'Update-CodeNotify',
    'Show-Help'
)
'@

    # Save main module
    $mainScript | Set-Content "$InstallDir\lib\CodeNotify.psm1" -Encoding UTF8
    $mainScript | Set-Content "$InstallDir\lib\ClaudeNotify.psm1" -Encoding UTF8
    Write-Success "Created PowerShell module"

    # Create the notification script (called by hooks)
$notifyScript = @'
# Code-Notify notification script
# Called by Claude Code, Codex, and Gemini hooks

param(
    [Parameter(Position=0)]
    [string]$HookType = "notification",

    [Parameter(Position=1)]
    [string]$ToolName = "claude",

    [Parameter(Position=2)]
    [string]$ProjectName = ""
)

$ClaudeHome = "$env:USERPROFILE\.claude"
$VoiceFile = "$ClaudeHome\notifications\voice-enabled"
$LogFile = "$ClaudeHome\logs\notifications.log"
$CodeNotifyConfigDir = "$env:USERPROFILE\.config\code-notify"
$ChannelsFile = "$CodeNotifyConfigDir\channels.json"

# Read hook data from stdin (Claude Code passes JSON with hook context)
$HookData = ""
try {
    if ([Console]::IsInputRedirected) {
        [Console]::InputEncoding = [System.Text.Encoding]::UTF8
        $HookData = [Console]::In.ReadToEnd()
    }
} catch {
    $HookData = ""
}

function Get-JsonStringValue {
    param(
        [string]$Json,
        [string]$Key
    )

    if (-not $Json) {
        return ""
    }

    try {
        $parsed = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return ""
    }

    $value = $parsed.PSObject.Properties[$Key].Value
    if ($value -is [string]) {
        return $value
    }

    return ""
}

function Get-CodexHookType {
    param([string]$Payload)

    $payloadType = (Get-JsonStringValue -Json $Payload -Key "type").ToLowerInvariant()

    if ($payloadType -eq "agent-turn-complete") {
        return "stop"
    }

    if ($payloadType -match 'request_permissions|permission|approval|elicitation|prompt') {
        return "notification"
    }

    if ($payloadType -match 'error|failed') {
        return "error"
    }

    if ($Payload -match 'last-assistant-message') {
        return "stop"
    }

    if ($Payload -match 'request_permissions|approval|permission') {
        return "notification"
    }

    return "stop"
}

function Get-CodexProjectName {
    param([string]$Payload)

    $payloadCwd = Get-JsonStringValue -Json $Payload -Key "cwd"
    if ($payloadCwd) {
        return Split-Path $payloadCwd -Leaf
    }

    return Split-Path (Get-Location) -Leaf
}

if ($HookType -eq "codex") {
    $ToolName = "codex"
    $HookData = $ProjectName
    $HookType = Get-CodexHookType -Payload $HookData
    $ProjectName = Get-CodexProjectName -Payload $HookData
}

function Get-ToolDisplayName {
    param([string]$Tool = "claude")

    switch ($Tool.ToLower()) {
        "codex" { return "Codex" }
        "gemini" { return "Gemini" }
        default { return "Claude Code" }
    }
}

$ToolDisplay = Get-ToolDisplayName $ToolName

$NotificationStateDir = "$ClaudeHome\notifications\state"
$UsageConfigFile = Join-Path $env:USERPROFILE ".config\code-notify\usage.json"

try {
    $StopRateLimitSeconds = [int]($env:CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS)
} catch {
    $StopRateLimitSeconds = 10
}

try {
    $NotificationRateLimitSeconds = [int]($env:CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS)
} catch {
    $NotificationRateLimitSeconds = 180
}

function Get-ProjectNameForNotification {
    if ($ProjectName) {
        return $ProjectName
    }

    $gitRoot = $null
    try {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $gitRoot = & git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -ne 0) {
                $gitRoot = $null
            }
        }
    } catch {
        $gitRoot = $null
    }

    if ($gitRoot) {
        return Split-Path $gitRoot -Leaf
    }

    return Split-Path (Get-Location) -Leaf
}

function Get-NotificationSubtype {
    if ($HookData -match 'idle_prompt') {
        return "idle_prompt"
    }

    if ($HookData -match 'permission_prompt|request_permissions|sandbox_approval') {
        return "permission_prompt"
    }

    if ($HookData -match 'auth_success') {
        return "auth_success"
    }

    if ($HookData -match 'elicitation_dialog|mcp_elicitations') {
        return "elicitation_dialog"
    }

    return "notification"
}

function Get-UsageResetAlertConfigLocal {
    $defaults = [pscustomobject]@{ enabled = $true; voice = $true; sound = $true; sound_file = "" }
    if (-not (Test-Path $UsageConfigFile)) {
        return $defaults
    }

    try {
        $config = Get-Content $UsageConfigFile -Raw | ConvertFrom-Json
        if ($config.reset_alerts) {
            foreach ($name in @("enabled", "voice", "sound", "sound_file")) {
                if ($null -eq $config.reset_alerts.$name) {
                    $config.reset_alerts | Add-Member -NotePropertyName $name -NotePropertyValue $defaults.$name -Force
                }
            }
            return $config.reset_alerts
        }
    } catch {
    }

    return $defaults
}

function Get-RateLimitPath {
    param([string]$Key)

    $safeKey = ($Key -replace '[^A-Za-z0-9._-]', '_')
    return Join-Path $NotificationStateDir $safeKey
}

function Get-LegacyRateLimitPath {
    param([string]$Key)

    $safeKey = ($Key -replace '[^A-Za-z0-9._-]', '_')
    return Join-Path "$ClaudeHome\notifications" $safeKey
}

function Test-RateLimited {
    param(
        [string]$Key,
        [int]$WindowSeconds
    )

    if ($WindowSeconds -le 0) {
        return $false
    }

    $path = Get-RateLimitPath $Key
    if (-not (Test-Path $path)) {
        $legacyPath = Get-LegacyRateLimitPath $Key
        if (Test-Path $legacyPath) {
            $path = $legacyPath
        }
    }

    if (-not (Test-Path $path)) {
        return $false
    }

    try {
        $lastTime = [long]((Get-Content $path -Raw -ErrorAction Stop).Trim())
    } catch {
        return $false
    }

    $currentTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return (($currentTime - $lastTime) -lt $WindowSeconds)
}

function Update-RateLimit {
    param([string]$Key)

    if (-not (Test-Path $NotificationStateDir)) {
        New-Item -ItemType Directory -Path $NotificationStateDir -Force | Out-Null
    }

    $currentTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $path = Get-RateLimitPath $Key
    $currentTime | Set-Content $path -Encoding ASCII

    $legacyPath = Get-LegacyRateLimitPath $Key
    if ($legacyPath -ne $path -and (Test-Path $legacyPath)) {
        Remove-Item $legacyPath -Force -ErrorAction SilentlyContinue
    }
}

# Function to check if notification should be suppressed
function Test-ShouldSuppressNotification {
    # Skip suppression checks for test notifications
    if ($HookType -eq "test") {
        return $false
    }

    if ($HookType -eq "stop" -and (Test-RateLimited -Key "last_stop_notification" -WindowSeconds $StopRateLimitSeconds)) {
        return $true
    }

    if ($HookType -eq "notification") {
        $notificationKey = "last_notification_{0}_{1}_{2}" -f $ToolName, (Get-ProjectNameForNotification), (Get-NotificationSubtype)
        if (Test-RateLimited -Key $notificationKey -WindowSeconds $NotificationRateLimitSeconds) {
            return $true
        }
    }

    # For Stop hooks: Check if stop_hook_active is true
    # This means Claude is still working (continuing from a previous stop hook)
    # We should only notify when Claude has truly finished
    if ($HookType -eq "stop" -and $HookData) {
        if ($HookData -match '"stop_hook_active"\s*:\s*true') {
            return $true  # Suppress - Claude is still working
        }
    }

    # Check for auto-accept environment variable (Issue #7)
    if ($env:CLAUDE_AUTO_ACCEPT -eq "true") {
        return $true
    }

    # Check if hook data indicates auto-acceptance
    if ($HookData -and $HookData -match '"autoAccepted"\s*:\s*true') {
        return $true
    }

    return $false
}

# Check if notification should be suppressed
if ($HookType -eq "stop" -or $HookType -eq "notification") {
    if (Test-ShouldSuppressNotification) {
        exit 0  # Skip this notification
    }
}

if ($HookType -eq "stop") {
    Update-RateLimit -Key "last_stop_notification"
} elseif ($HookType -eq "notification") {
    Update-RateLimit -Key ("last_notification_{0}_{1}_{2}" -f $ToolName, (Get-ProjectNameForNotification), (Get-NotificationSubtype))
}

if (-not $ProjectName) {
    $ProjectName = Get-ProjectNameForNotification
}

# Set notification content based on hook type
switch ($HookType.ToLower()) {
    "stop" {
        $Title = "$ToolDisplay - Task Complete"
        $Message = "$ToolDisplay completed the task in $ProjectName"
        $VoiceMessage = "$ToolDisplay completed the task in $ProjectName"
    }
    "notification" {
        $Title = "$ToolDisplay - Input Required"
        $Message = "$ToolDisplay needs your input in $ProjectName"
        $VoiceMessage = "$ToolDisplay needs your input in $ProjectName"
    }
    "pretooluse" {
        $Title = "$ToolDisplay - Command Approval"
        $Message = "$ToolDisplay wants to run a command in $ProjectName"
        $VoiceMessage = "$ToolDisplay wants to run a command in $ProjectName"
    }
    "error" {
        $Title = "$ToolDisplay - Error"
        $Message = "An error occurred in $ProjectName"
        $VoiceMessage = "An error occurred in $ProjectName"
    }
    "test" {
        $Title = "Code-Notify Test"
        $Message = "Notifications are working correctly!"
        $VoiceMessage = "Test notification successful"
    }
    "usage" {
        $Title = if ($env:CODE_NOTIFY_USAGE_TITLE) { $env:CODE_NOTIFY_USAGE_TITLE } else { "$ToolDisplay usage alert" }
        $Message = if ($env:CODE_NOTIFY_USAGE_MESSAGE) { $env:CODE_NOTIFY_USAGE_MESSAGE } else { "$ToolDisplay usage changed" }
        $VoiceMessage = if ($env:CODE_NOTIFY_USAGE_VOICE_MESSAGE) { $env:CODE_NOTIFY_USAGE_VOICE_MESSAGE } else { "$ToolDisplay usage alert" }
    }
    "usage_reset" {
        $Title = if ($env:CODE_NOTIFY_USAGE_TITLE) { $env:CODE_NOTIFY_USAGE_TITLE } else { "$ToolDisplay token limit reset" }
        $Message = if ($env:CODE_NOTIFY_USAGE_MESSAGE) { $env:CODE_NOTIFY_USAGE_MESSAGE } else { "$ToolDisplay tokens have reset. Usage is back to 100%." }
        $VoiceMessage = if ($env:CODE_NOTIFY_USAGE_VOICE_MESSAGE) { $env:CODE_NOTIFY_USAGE_VOICE_MESSAGE } else { "$ToolDisplay token limit reset" }
    }
    default {
        $Title = $ToolDisplay
        $Message = "Status update: $HookType"
        $VoiceMessage = "Status update from $ProjectName"
    }
}

# Get the terminal process to activate on notification click
function Get-TerminalProcess {
    # Try to find the parent terminal process
    $terminalApps = @("WindowsTerminal", "powershell", "pwsh", "cmd", "Code")

    foreach ($app in $terminalApps) {
        $proc = Get-Process -Name $app -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            return $proc.MainWindowHandle
        }
    }
    return $null
}

# Bring window to foreground
function Set-WindowForeground {
    param([IntPtr]$WindowHandle)

    if ($WindowHandle -eq [IntPtr]::Zero) { return }

    Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public class WindowHelper {
        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    }
"@
    [WindowHelper]::ShowWindow($WindowHandle, 9) | Out-Null  # SW_RESTORE
    [WindowHelper]::SetForegroundWindow($WindowHandle) | Out-Null
}

# Send desktop notification
function Send-DesktopNotification {
    # Store terminal handle for activation
    $terminalHandle = Get-TerminalProcess

    # Try BurntToast first
    if (Get-Module -ListAvailable -Name BurntToast) {
        Import-Module BurntToast -ErrorAction SilentlyContinue

        # Create activation script - closure variables won't work with BurntToast
        # Use a global variable approach instead
        $global:ClaudeNotify_TerminalHandle = $terminalHandle
        $activateScript = {
            if ($global:ClaudeNotify_TerminalHandle -and $global:ClaudeNotify_TerminalHandle -ne [IntPtr]::Zero) {
                Set-WindowForeground -WindowHandle $global:ClaudeNotify_TerminalHandle
            }
        }

        $toastParams = @{
            Text = $Title, $Message
            ErrorAction = 'SilentlyContinue'
        }
        $burntToastCommand = Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue
        if ($burntToastCommand -and $burntToastCommand.Parameters.ContainsKey('Silent')) {
            $toastParams['Silent'] = $true
        }

        # Add activation if we have a terminal handle
        if ($terminalHandle) {
            $toastParams['ActivatedAction'] = $activateScript
        }

        New-BurntToastNotification @toastParams
        return
    }

    # Fallback to native Windows toast.
    # Foreground activation requires extra registration that a standalone script does not provide,
    # so keep the WinRT path simple and reliable here.
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast>
    <visual>
        <binding template="ToastText02">
            <text id="1">$Title</text>
            <text id="2">$Message</text>
        </binding>
    </visual>
    <audio silent="true"/>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Code-Notify").Show($toast)
    }
    catch {
        # Final fallback - balloon notification (no click activation support)
        Add-Type -AssemblyName System.Windows.Forms
        $notification = New-Object System.Windows.Forms.NotifyIcon
        $notification.Icon = [System.Drawing.SystemIcons]::Information
        $notification.BalloonTipIcon = "Info"
        $notification.BalloonTipTitle = $Title
        $notification.BalloonTipText = $Message
        $notification.Visible = $true
        $notification.ShowBalloonTip(10000)
        Start-Sleep -Milliseconds 500
        $notification.Dispose()
    }
}

# Send voice notification if enabled
function Send-VoiceNotificationLocal {
    if ($HookType -eq "usage_reset") {
        $resetConfig = Get-UsageResetAlertConfigLocal
        if (-not $resetConfig.enabled -or -not $resetConfig.voice) { return }
    }

    # Check for project-specific voice first
    $projectRoot = $null
    try {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $projectRoot = & git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -ne 0) {
                $projectRoot = $null
            }
        }
    } catch {
        $projectRoot = $null
    }

    if ($projectRoot) {
        $projectVoice = Join-Path $projectRoot ".claude\voice"
        if (Test-Path $projectVoice) {
            $VoiceFile = $projectVoice
        }
    }

    $voice = $null
    if (Test-Path $VoiceFile) {
        $voice = Get-Content $VoiceFile -ErrorAction SilentlyContinue
    } elseif ($HookType -eq "usage_reset") {
        $voice = "Microsoft David Desktop"
    }

    if ($voice) {
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer

        try {
            $synth.SelectVoice($voice)
        } catch {
            # Use default voice
        }

        $synth.SpeakAsync($VoiceMessage) | Out-Null
    }
}

# Send sound notification if enabled
function Send-SoundNotificationLocal {
    $SoundEnabledFile = "$ClaudeHome\notifications\sound-enabled"
    $SoundCustomFile = "$ClaudeHome\notifications\sound-custom"
    $DefaultSoundFile = "C:\Windows\Media\chimes.wav"
    $UsageResetSoundFile = "C:\Windows\Media\tada.wav"

    if ($HookType -eq "usage_reset") {
        $resetConfig = Get-UsageResetAlertConfigLocal
        if (-not $resetConfig.enabled -or -not $resetConfig.sound) { return }
        if ($resetConfig.sound_file) {
            $soundFile = $resetConfig.sound_file
        } else {
            $soundFile = $UsageResetSoundFile
        }
    } else {
        if (-not (Test-Path $SoundEnabledFile)) { return }

        $soundFile = $DefaultSoundFile
        if (Test-Path $SoundCustomFile) {
            $soundFile = Get-Content $SoundCustomFile -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $soundFile)) { return }

    try {
        $player = New-Object System.Media.SoundPlayer
        $player.SoundLocation = $soundFile
        # Keep the process alive until playback starts and completes.
        $player.PlaySync()
    } catch {
        # Silently fail if sound cannot be played
    }
}

function Send-ChannelDeliveryLocal {
    if (-not (Test-Path $ChannelsFile)) {
        return
    }

    try {
        $config = Get-Content $ChannelsFile -Raw | ConvertFrom-Json
    } catch {
        return
    }

    if (-not $config.enabled) {
        return
    }

    foreach ($channel in @($config.channels)) {
        try {
            $text = $Title
            if ($Message) { $text = "$text`n$Message" }
            if ($ProjectName) { $text = "$text`nProject: $ProjectName" }

            if ($channel.provider -eq "discord") {
                $payload = @{ content = $text; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Depth 10
            } else {
                $payload = @{ text = $text } | ConvertTo-Json -Depth 10
            }

            Invoke-RestMethod -Uri $channel.url -Method Post -Body $payload -ContentType "application/json" -TimeoutSec 5 | Out-Null
        } catch {
        }
    }
}

# Log notification
function Write-NotificationLog {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$ToolName] [$ProjectName] $Title - $Message"

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
}

# Execute
Send-DesktopNotification
Send-VoiceNotificationLocal
Send-SoundNotificationLocal
Send-ChannelDeliveryLocal
Write-NotificationLog

exit 0
'@

    $notifyScript | Set-Content "$NotificationsDir\notify.ps1" -Encoding UTF8
    Write-Success "Created notification script"

    # Create CLI wrapper scripts
    $cliWrapper = @'
# Code-Notify CLI wrapper
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
$requestedVersionShortcut = $false
$invocationLine = [string]$MyInvocation.Line
if ($Args.Count -eq 1 -and @('version', '-v', '--version') -contains $Args[0]) {
    $requestedVersionShortcut = $true
} elseif ($Args.Count -eq 0 -and $invocationLine -match '(^|\s)-v($|\s)') {
    $requestedVersionShortcut = $true
} elseif ($Args.Count -eq 0 -and $invocationLine -match '(^|\s)--version($|\s)') {
    $requestedVersionShortcut = $true
}
Import-Module "$env:USERPROFILE\.code-notify\lib\CodeNotify.psm1" -Force -Verbose:$false
if ($requestedVersionShortcut) {
    Invoke-CodeNotify "version"
} else {
    Invoke-CodeNotify @Args
}
'@

    $cliWrapper | Set-Content "$InstallDir\bin\code-notify.ps1" -Encoding UTF8

    # Create cn alias
    $cnWrapper = @'
# cn - Code-Notify shortcut
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
$requestedVersionShortcut = $false
$invocationLine = [string]$MyInvocation.Line
if ($Args.Count -eq 1 -and @('version', '-v', '--version') -contains $Args[0]) {
    $requestedVersionShortcut = $true
} elseif ($Args.Count -eq 0 -and $invocationLine -match '(^|\s)-v($|\s)') {
    $requestedVersionShortcut = $true
} elseif ($Args.Count -eq 0 -and $invocationLine -match '(^|\s)--version($|\s)') {
    $requestedVersionShortcut = $true
}
Import-Module "$env:USERPROFILE\.code-notify\lib\CodeNotify.psm1" -Force -Verbose:$false
if ($requestedVersionShortcut) {
    Invoke-CodeNotify "version"
} else {
    Invoke-CodeNotify @Args
}
'@
    $cnWrapper | Set-Content "$InstallDir\bin\cn.ps1" -Encoding UTF8

    # Create cnp alias (project commands)
    $cnpWrapper = @'
# cnp - Code-Notify Project shortcut
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
Import-Module "$env:USERPROFILE\.code-notify\lib\CodeNotify.psm1" -Force -Verbose:$false
Invoke-CodeNotify "project" @Args
'@
    $cnpWrapper | Set-Content "$InstallDir\bin\cnp.ps1" -Encoding UTF8

    Write-Success "Created CLI wrappers"
}

function Add-ToPath {
    Write-Header "Configuring PATH..."

    $binPath = "$InstallDir\bin"
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")

    if ($currentPath -notlike "*$binPath*") {
        $newPath = "$currentPath;$binPath"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$binPath"
        Write-Success "Added to PATH: $binPath"
        Write-Warning "Restart your terminal for PATH changes to take effect"
    } else {
        Write-Info "Already in PATH: $binPath"
    }
}

function Add-PowerShellProfile {
    Write-Header "Configuring PowerShell profile..."

    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent

    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    $aliasBlock = @"

# Code-Notify aliases (added by installer)
Set-Alias -Name code-notify -Value "$InstallDir\bin\code-notify.ps1"
Set-Alias -Name cn -Value "$InstallDir\bin\cn.ps1"
Set-Alias -Name cnp -Value "$InstallDir\bin\cnp.ps1"
# End Code-Notify aliases

"@

    if (Test-Path $profilePath) {
        $profileContent = Get-Content $profilePath -Raw -ErrorAction SilentlyContinue
        if ($profileContent -notlike "*Code-Notify aliases*") {
            Add-Content -Path $profilePath -Value $aliasBlock
            Write-Success "Added aliases to PowerShell profile"
        } else {
            Write-Info "Aliases already in PowerShell profile"
        }
    } else {
        $aliasBlock | Set-Content $profilePath -Encoding UTF8
        Write-Success "Created PowerShell profile with aliases"
    }
}

function Uninstall-ClaudeNotify {
    Write-Header "Uninstalling Code-Notify..."

    # Remove installation directory
    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Success "Removed: $InstallDir"
    }

    # Remove from PATH
    $currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $binPath = "$InstallDir\bin"
    if ($currentPath -like "*$binPath*") {
        $newPath = ($currentPath -split ";" | Where-Object { $_ -ne $binPath }) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Success "Removed from PATH"
    }

    # Clean profile (optional)
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (Test-Path $profilePath) {
        $content = Get-Content $profilePath -Raw
        $content = $content -replace "(?s)# Code-Notify aliases.*?# End Code-Notify aliases\r?\n?", ""
        $content | Set-Content $profilePath -Encoding UTF8
        Write-Success "Cleaned PowerShell profile"
    }

    Write-Success "Code-Notify uninstalled successfully!"
    Write-Info "Note: Your Claude settings in $ClaudeHome were preserved"
}

function Show-PostInstall {
    Write-Host @"

====================================
  Installation Complete!
====================================

"@ -ForegroundColor Green

    Write-Host "Quick Start:" -ForegroundColor White
    Write-Host "  1. Restart your terminal (or run: refreshenv)" -ForegroundColor Gray
    Write-Host "  2. Enable notifications:" -ForegroundColor Gray
    Write-Host "     cn on" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor White
    Write-Host "  cn on          - Enable notifications globally" -ForegroundColor Gray
    Write-Host "  cn off         - Disable notifications" -ForegroundColor Gray
    Write-Host "  cn status      - Check status" -ForegroundColor Gray
    Write-Host "  cn test        - Send test notification" -ForegroundColor Gray
    Write-Host "  cn voice on    - Enable voice notifications" -ForegroundColor Gray
    Write-Host "  cnp on         - Enable for current project only" -ForegroundColor Gray
    Write-Host ""
    Write-Host "For enhanced notifications (recommended):" -ForegroundColor White
    Write-Host "  Install-Module -Name BurntToast -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "More info: https://github.com/mylee04/code-notify" -ForegroundColor DarkGray
    Write-Host ""
}

# Main installation flow
function Main {
    if (-not $Silent) {
        Show-Banner
    }

    if ($Uninstall) {
        Uninstall-ClaudeNotify
        return
    }

    if (-not (Test-Prerequisites)) {
        Write-Error "Prerequisites check failed"
        exit 1
    }

    Install-ClaudeNotify
    if (-not $SkipShellSetup) {
        Add-ToPath
        Add-PowerShellProfile
    }

    try {
        Import-Module "$InstallDir\lib\CodeNotify.psm1" -Force -Verbose:$false
        Invoke-CodeNotify "repair-hooks" "--quiet"
    } catch {
        Write-Warning "Legacy Claude hook repair did not complete during install"
    }

    if (-not $Silent) {
        Show-PostInstall

        # Send test notification
        Write-Host "Sending test notification..." -ForegroundColor Cyan
        & "$NotificationsDir\notify.ps1" "test"
    }
}

# Run
Main
