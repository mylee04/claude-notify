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
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

# Version
$VERSION = "1.4.4"

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
    $directories = @($InstallDir, "$InstallDir\bin", "$InstallDir\lib", $NotificationsDir, $LogsDir)
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

$script:VERSION = "1.4.4"
$script:ClaudeHome = "$env:USERPROFILE\.claude"
$script:SettingsFile = "$script:ClaudeHome\settings.json"
$script:NotificationsDir = "$script:ClaudeHome\notifications"
$script:VoiceFile = "$script:NotificationsDir\voice-enabled"

# Helper functions for colored output
function Write-Success { param([string]$Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Info { param([string]$Message) Write-Host "[i] $Message" -ForegroundColor Cyan }
function Write-Warning { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Header { param([string]$Message) Write-Host "`n$Message" -ForegroundColor White }

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

function Get-NotifyScript {
    return "$script:NotificationsDir\notify.ps1"
}

function Test-NotificationsEnabled {
    if (-not (Test-Path $script:SettingsFile)) {
        return $false
    }

    $settings = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    return ($null -ne $settings.hooks)
}

function Enable-Notifications {
    param([switch]$Project)

    $projectName = Get-ProjectName
    $notifyScript = Get-NotifyScript

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

    # Backup existing settings
    if (Test-Path $settingsFile) {
        $backupDir = "$env:USERPROFILE\.config\code-notify\backups"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        Copy-Item $settingsFile "$backupDir\settings.$timestamp.json" -ErrorAction SilentlyContinue
    }

    # Create settings with hooks
    $settings = @{
        hooks = @{
            Notification = @(
                @{
                    matcher = ""
                    hooks = @(
                        @{
                            type = "command"
                            command = "powershell -ExecutionPolicy Bypass -File `"$notifyScript`" notification"
                        }
                    )
                }
            )
            Stop = @(
                @{
                    matcher = ""
                    hooks = @(
                        @{
                            type = "command"
                            command = "powershell -ExecutionPolicy Bypass -File `"$notifyScript`" stop"
                        }
                    )
                }
            )
        }
    }

    # Merge with existing settings if present
    if (Test-Path $settingsFile) {
        $existingSettings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($existingSettings) {
            # Preserve other settings like model
            $existingSettings.PSObject.Properties | ForEach-Object {
                if ($_.Name -ne "hooks") {
                    $settings[$_.Name] = $_.Value
                }
            }
        }
    }

    # Ensure parent directory exists
    $parentDir = Split-Path $settingsFile -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8

    Write-Success "Notifications enabled!"
    Write-Info "Config: $settingsFile"

    # Test notification
    Send-Notification -Title "Code-Notify" -Message "Notifications enabled!" -Type "success"
}

function Disable-Notifications {
    param([switch]$Project)

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

    $settings = Get-Content $settingsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($settings -and $settings.hooks) {
        $settings.PSObject.Properties.Remove("hooks")
        $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
        Write-Success "Notifications disabled!"
    } else {
        Write-Warning "Notifications were not enabled"
    }
}

function Show-Status {
    param([switch]$Project)

    Write-Host "`n[i] Code-Notify Status" -ForegroundColor Cyan
    Write-Host "========================`n" -ForegroundColor Cyan

    # Global status
    if (Test-NotificationsEnabled) {
        Write-Host "[*] Global notifications: ENABLED" -ForegroundColor Green
    } else {
        Write-Host "[-] Global notifications: DISABLED" -ForegroundColor DarkGray
    }

    # Project status
    $projectRoot = Get-ProjectRoot
    $projectName = Get-ProjectName
    $projectSettings = Join-Path $projectRoot ".claude\settings.json"

    Write-Host "`n[D] Project: $projectName" -ForegroundColor White
    Write-Host "    Location: $projectRoot" -ForegroundColor DarkGray

    if (Test-Path $projectSettings) {
        $settings = Get-Content $projectSettings -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($settings -and $settings.hooks) {
            Write-Host "[*] Project notifications: ENABLED" -ForegroundColor Green
        } else {
            Write-Host "[-] Project notifications: DISABLED" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "[-] Project notifications: Not configured" -ForegroundColor DarkGray
    }

    # Voice status
    Write-Host ""
    if (Test-Path $script:VoiceFile) {
        $voice = Get-Content $script:VoiceFile
        Write-Host "[S] Voice notifications: ENABLED ($voice)" -ForegroundColor Green
    } else {
        Write-Host "[-] Voice notifications: DISABLED" -ForegroundColor DarkGray
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

function Show-Help {
    Write-Host @"

Code-Notify - Native Windows notifications for Claude Code

USAGE:
    code-notify <command> [options]
    cn <command>              # Short alias
    cnp <command>             # Project command alias

COMMANDS:
    on              Enable notifications globally
    off             Disable notifications globally
    status          Show notification status
    test            Send a test notification
    voice on        Enable voice notifications
    voice off       Disable voice notifications
    help            Show this help message
    version         Show version information

PROJECT COMMANDS:
    project on      Enable for current project (or: cnp on)
    project off     Disable for current project (or: cnp off)
    project status  Check project status (or: cnp status)
    project voice   Set project-specific voice (or: cnp voice)

EXAMPLES:
    code-notify on            # Enable notifications
    cn off                      # Disable notifications
    cnp on                      # Enable for current project
    cn test                     # Send test notification

MORE INFO:
    https://github.com/mylee04/code-notify

"@ -ForegroundColor Gray
}

# Main command handler
function Invoke-ClaudeNotify {
    param(
        [Parameter(Position=0)]
        [string]$Command = "help",

        [Parameter(Position=1)]
        [string]$SubCommand,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Args
    )

    switch ($Command.ToLower()) {
        "on" { Enable-Notifications }
        "off" { Disable-Notifications }
        "status" { Show-Status }
        "test" { Send-TestNotification }
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
        "version" { Write-Host "code-notify version $script:VERSION" }
        default { Show-Help }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Invoke-ClaudeNotify',
    'Send-Notification',
    'Send-VoiceNotification',
    'Enable-Notifications',
    'Disable-Notifications',
    'Show-Status',
    'Enable-Voice',
    'Disable-Voice',
    'Send-TestNotification',
    'Show-Help'
)
'@

    # Save main module
    $mainScript | Set-Content "$InstallDir\lib\ClaudeNotify.psm1" -Encoding UTF8
    Write-Success "Created PowerShell module"

    # Create the notification script (called by hooks)
    $notifyScript = @'
# Code-Notify notification script
# Called by Claude Code hooks

param(
    [Parameter(Position=0)]
    [string]$HookType = "notification",

    [Parameter(Position=1)]
    [string]$Status = "completed",

    [Parameter(Position=2)]
    [string]$ProjectName = ""
)

$ClaudeHome = "$env:USERPROFILE\.claude"
$VoiceFile = "$ClaudeHome\notifications\voice-enabled"
$LogFile = "$ClaudeHome\logs\notifications.log"

# Read hook data from stdin (Claude Code passes JSON with hook context)
$HookData = ""
try {
    if ([Console]::IsInputRedirected) {
        $HookData = [Console]::In.ReadToEnd()
    }
} catch {
    $HookData = ""
}

# Function to check if notification should be suppressed
function Test-ShouldSuppressNotification {
    # Skip suppression checks for test notifications
    if ($HookType -eq "test") {
        return $false
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

if (-not $ProjectName) {
    $gitRoot = $null
    try {
        # Check if git is available and we're in a git repo
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            # Use cmd to avoid PowerShell surfacing git stderr as an error record
            $insideRepo = cmd /c "git rev-parse --is-inside-work-tree 2>nul"
            if ($LASTEXITCODE -eq 0 -and $insideRepo.Trim() -eq "true") {
                $gitRoot = cmd /c "git rev-parse --show-toplevel 2>nul"
                if ($LASTEXITCODE -ne 0) {
                    $gitRoot = $null
                }
            }
        }
    } catch {
        $gitRoot = $null
    }

    if ($gitRoot) {
        $ProjectName = Split-Path $gitRoot -Leaf
    } else {
        $ProjectName = Split-Path (Get-Location) -Leaf
    }
}

# Set notification content based on hook type
switch ($HookType.ToLower()) {
    "stop" {
        $Title = "Claude Code - Task Complete"
        $Message = "Your task in $ProjectName has been completed!"
        $VoiceMessage = "Your task in $ProjectName is complete"
    }
    "notification" {
        $Title = "Claude Code - Input Required"
        $Message = "Claude needs your input in $ProjectName"
        $VoiceMessage = "Input needed in $ProjectName"
    }
    "pretooluse" {
        $Title = "Claude Code - Command Approval"
        $Message = "Claude wants to run a command in $ProjectName"
        $VoiceMessage = "Command approval needed in $ProjectName"
    }
    "error" {
        $Title = "Claude Code - Error"
        $Message = "An error occurred in $ProjectName"
        $VoiceMessage = "An error occurred in $ProjectName"
    }
    "test" {
        $Title = "Code-Notify Test"
        $Message = "Notifications are working correctly!"
        $VoiceMessage = "Test notification successful"
    }
    default {
        $Title = "Claude Code"
        $Message = "Status update: $Status"
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

        # Add activation if we have a terminal handle
        if ($terminalHandle) {
            $toastParams['ActivatedAction'] = $activateScript
        }

        New-BurntToastNotification @toastParams
        return
    }

    # Fallback to native Windows toast with activation
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast activationType="foreground" launch="code-notify:activate">
    <visual>
        <binding template="ToastText02">
            <text id="1">$Title</text>
            <text id="2">$Message</text>
        </binding>
    </visual>
    <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

        # Register activation handler
        if ($terminalHandle) {
            $toast.add_Activated({
                Set-WindowForeground -WindowHandle $terminalHandle
            }.GetNewClosure())
        }

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

    if (Test-Path $VoiceFile) {
        $voice = Get-Content $VoiceFile -ErrorAction SilentlyContinue
        if (-not $voice) { $voice = "Microsoft David Desktop" }

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

# Log notification
function Write-NotificationLog {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$ProjectName] $Title - $Message"

    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
}

# Execute
Send-DesktopNotification
Send-VoiceNotificationLocal
Write-NotificationLog

exit 0
'@

    $notifyScript | Set-Content "$NotificationsDir\notify.ps1" -Encoding UTF8
    Write-Success "Created notification script"

    # Create CLI wrapper scripts
    $cliWrapper = @'
# Code-Notify CLI wrapper
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
Import-Module "$env:USERPROFILE\.code-notify\lib\ClaudeNotify.psm1" -Force
Invoke-ClaudeNotify @Args
'@

    $cliWrapper | Set-Content "$InstallDir\bin\code-notify.ps1" -Encoding UTF8

    # Create cn alias
    $cnWrapper = @'
# cn - Code-Notify shortcut
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
Import-Module "$env:USERPROFILE\.code-notify\lib\ClaudeNotify.psm1" -Force
Invoke-ClaudeNotify @Args
'@
    $cnWrapper | Set-Content "$InstallDir\bin\cn.ps1" -Encoding UTF8

    # Create cnp alias (project commands)
    $cnpWrapper = @'
# cnp - Code-Notify Project shortcut
param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
Import-Module "$env:USERPROFILE\.code-notify\lib\ClaudeNotify.psm1" -Force
Invoke-ClaudeNotify "project" @Args
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
    Show-Banner

    if ($Uninstall) {
        Uninstall-ClaudeNotify
        return
    }

    if (-not (Test-Prerequisites)) {
        Write-Error "Prerequisites check failed"
        exit 1
    }

    Install-ClaudeNotify
    Add-ToPath
    Add-PowerShellProfile

    if (-not $Silent) {
        Show-PostInstall

        # Send test notification
        Write-Host "Sending test notification..." -ForegroundColor Cyan
        & "$NotificationsDir\notify.ps1" "test"
    }
}

# Run
Main
