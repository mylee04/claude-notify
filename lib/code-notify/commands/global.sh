#!/bin/bash

# Global command handlers for Code-Notify

# Source utilities
GLOBAL_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$GLOBAL_CMD_DIR/../utils/voice.sh"
source "$GLOBAL_CMD_DIR/../utils/sound.sh"
source "$GLOBAL_CMD_DIR/../utils/help.sh"
source "$GLOBAL_CMD_DIR/../utils/click-through.sh"
source "$GLOBAL_CMD_DIR/../utils/channels.sh"
source "$GLOBAL_CMD_DIR/../utils/usage.sh"

CODE_NOTIFY_RELEASES_API="https://api.github.com/repos/mylee04/code-notify/releases/latest"

# Handle global commands
handle_global_command() {
    local command="${1:-status}"
    shift
    
    case "$command" in
        "on")
            enable_notifications_global "$@"
            ;;
        "off")
            disable_notifications_global "$@"
            ;;
        "status")
            show_status "$@"
            ;;
        "test")
            test_notification "$@"
            ;;
        "update")
            handle_update_command "$@"
            ;;
        "setup")
            run_setup_wizard "$@"
            ;;
        "voice")
            handle_voice_command "$@"
            ;;
        "sound")
            handle_sound_command "$@"
            ;;
        "alerts")
            handle_alerts_command "$@"
            ;;
        "channels")
            handle_channels_command "$@"
            ;;
        "usage")
            handle_usage_command "$@"
            ;;
        "click-through")
            handle_click_through_command "$@"
            ;;
        "help")
            show_help
            ;;
        "version")
            show_version
            ;;
        *)
            error "Unknown command: $command"
            exit 1
            ;;
    esac
}

# Detect how the current code-notify command was installed.
detect_update_method() {
    local source_dir="${1:-$GLOBAL_CMD_DIR}"

    if [[ -n "${CODE_NOTIFY_INSTALL_METHOD:-}" ]]; then
        echo "$CODE_NOTIFY_INSTALL_METHOD"
        return 0
    fi

    case "$source_dir" in
        /opt/homebrew/Cellar/code-notify/*|/usr/local/Cellar/code-notify/*|/opt/homebrew/opt/code-notify/*|/usr/local/opt/code-notify/*)
            echo "homebrew"
            ;;
        */node_modules/code-notify/lib/code-notify/*)
            echo "npm"
            ;;
        "$HOME"/.code-notify/lib/code-notify/*)
            echo "script"
            ;;
        *)
            echo "manual"
            ;;
    esac
}

normalize_version() {
    local version="${1:-}"
    version="${version#v}"
    version="${version#V}"
    printf '%s\n' "$version"
}

compare_versions() {
    local left_version right_version
    local -a left_parts=()
    local -a right_parts=()
    local max_len=0
    local i left_part right_part

    left_version="$(normalize_version "$1")"
    right_version="$(normalize_version "$2")"

    IFS='.' read -r -a left_parts <<< "$left_version"
    IFS='.' read -r -a right_parts <<< "$right_version"

    max_len="${#left_parts[@]}"
    if (( ${#right_parts[@]} > max_len )); then
        max_len="${#right_parts[@]}"
    fi

    for ((i = 0; i < max_len; i++)); do
        left_part="${left_parts[i]:-0}"
        right_part="${right_parts[i]:-0}"

        left_part="${left_part//[^0-9]/}"
        right_part="${right_part//[^0-9]/}"

        [[ -z "$left_part" ]] && left_part=0
        [[ -z "$right_part" ]] && right_part=0

        if ((10#$left_part > 10#$right_part)); then
            echo 1
            return 0
        fi

        if ((10#$left_part < 10#$right_part)); then
            echo -1
            return 0
        fi
    done

    echo 0
}

get_latest_release_version() {
    local response latest_version

    if [[ -n "${CODE_NOTIFY_LATEST_VERSION:-}" ]]; then
        normalize_version "$CODE_NOTIFY_LATEST_VERSION"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    response="$(curl -fsSL "$CODE_NOTIFY_RELEASES_API" 2>/dev/null)" || return 1
    latest_version="$(printf '%s\n' "$response" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([^"]+)".*/\1/')"

    [[ -n "$latest_version" ]] || return 1
    normalize_version "$latest_version"
}

print_update_status() {
    local current_version="$1"
    local latest_version="$2"
    local comparison="$3"

    case "$comparison" in
        -1)
            info "Current version: $current_version"
            warning "Update available: $current_version -> $latest_version"
            ;;
        0)
            info "Current version: $current_version"
            success "Code-Notify is up to date ($current_version)"
            ;;
        1)
            info "Current version: $current_version"
            info "Installed version is newer than the latest release ($latest_version)"
            ;;
    esac
}

normalize_tool_argument() {
    local tool="${1:-}"

    case "$tool" in
        ""|"all")
            printf '%s\n' ""
            ;;
        *)
            printf '%s\n' "$tool"
            ;;
    esac
}

# Return the user-facing update command for a specific install method.
get_update_command() {
    local method="${1:-$(detect_update_method)}"

    case "$method" in
        "homebrew")
            echo "brew update && brew upgrade code-notify"
            ;;
        "npm")
            echo "npm install -g code-notify@latest"
            ;;
        "script")
            echo "curl -fsSL https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install.sh | bash"
            ;;
        *)
            return 1
            ;;
    esac
}

# Run the update command for a specific install method.
run_update_for_method() {
    local method="$1"

    case "$method" in
        "homebrew")
            brew update && brew upgrade code-notify
            ;;
        "npm")
            npm install -g code-notify@latest
            ;;
        "script")
            curl -fsSL https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install.sh | bash
            ;;
        *)
            return 1
            ;;
    esac
}

# Show update guidance without changing the current installation.
check_for_updates() {
    local method="${1:-$(detect_update_method)}"
    local current_version latest_version comparison

    echo ""
    info "Checking for updates..."
    current_version="$(normalize_version "${VERSION:-unknown}")"

    if [[ "$method" != "manual" ]]; then
        if latest_version="$(get_latest_release_version)"; then
            comparison="$(compare_versions "$current_version" "$latest_version")"
            print_update_status "$current_version" "$latest_version" "$comparison"
        else
            info "Current version: $current_version"
            warning "Could not determine the latest release"
        fi
    fi

    case "$method" in
        "homebrew")
            info "Install method: Homebrew"
            echo "To update code-notify, run:"
            echo "  ${CYAN}$(get_update_command "$method")${RESET}"
            ;;
        "npm")
            info "Install method: npm"
            echo "To update code-notify, run:"
            echo "  ${CYAN}$(get_update_command "$method")${RESET}"
            ;;
        "script")
            info "Install method: install script"
            echo "To update code-notify, run:"
            echo "  ${CYAN}$(get_update_command "$method")${RESET}"
            ;;
        *)
            warning "Local checkout or unsupported install method detected"
            echo "Update manually:"
            echo "  ${CYAN}git pull${RESET}"
            echo "  ${CYAN}https://github.com/mylee04/code-notify${RESET}"
            ;;
    esac
}

# Handle update commands
handle_update_command() {
    local subcommand="${1:-run}"
    local method
    local current_version latest_version comparison

    case "$subcommand" in
        "check"|"status"|"--check")
            check_for_updates
            ;;
        "help"|"-h"|"--help")
            echo "Usage: cn update [check]"
            echo "  cn update        Update the current installation"
            echo "  cn update check  Show which update command will be used"
            ;;
        *)
            method=$(detect_update_method)

            echo ""
            header "${ROCKET} Updating Code-Notify"
            echo ""

            case "$method" in
                "homebrew")
                    info "Detected Homebrew installation"
                    ;;
                "npm")
                    info "Detected npm installation"
                    ;;
                "script")
                    info "Detected install-script installation"
                    ;;
                *)
                    warning "Local checkout or unsupported install method detected"
                    info "Use ${CYAN}cn update check${RESET} for guidance"
                    return 1
                    ;;
            esac

            current_version="$(normalize_version "${VERSION:-unknown}")"
            if latest_version="$(get_latest_release_version)"; then
                comparison="$(compare_versions "$current_version" "$latest_version")"
                print_update_status "$current_version" "$latest_version" "$comparison"

                case "$comparison" in
                    0|1)
                        return 0
                        ;;
                esac
            else
                info "Current version: $current_version"
                warning "Could not determine the latest release; proceeding with update"
            fi

            if ! run_update_for_method "$method"; then
                error "Failed to update code-notify"
                return 1
            fi

            success "Update complete!"
            info "Run ${CYAN}code-notify version${RESET} to confirm the installed version"
            ;;
    esac
}

# Show version (can be called from handle_global_command)
show_version() {
    echo "code-notify version $VERSION"
}

# Enable notifications globally
enable_notifications_global() {
    local tool
    tool="$(normalize_tool_argument "${1:-}")"

    header "${ROCKET} Enabling Notifications"
    echo ""

    ensure_config_dir

    # Remove kill switch if present
    rm -f "$HOME/.claude/notifications/disabled"

    # If specific tool requested
    if [[ -n "$tool" ]]; then
        enable_single_tool "$tool"
        return $?
    fi

    # No tool specified - enable for all detected tools
    local installed_tools=$(get_installed_tools)

    if [[ -z "$installed_tools" ]]; then
        warning "No supported AI tools detected"
        info "Supported tools: Claude Code, Codex, Gemini CLI, Oh My Pi (omp)"
        return 1
    fi

    local enabled_count=0
    for t in $installed_tools; do
        if enable_single_tool "$t" "quiet"; then
            ((enabled_count++))
        fi
    done

    echo ""
    if [[ $enabled_count -gt 0 ]]; then
        success "Enabled notifications for $enabled_count tool(s)"
        echo ""
        info "Sending test notification..."
        test_notification "silent"
    else
        warning "No tools were enabled"
    fi
}

# Enable a single tool
enable_single_tool() {
    local tool="$1"
    local quiet="${2:-}"
    local needs_repair=1

    # Check if tool is installed
    if ! is_tool_installed "$tool"; then
        if [[ "$quiet" != "quiet" ]]; then
            warning "$tool is not installed"
        fi
        return 1
    fi

    if [[ "$tool" == "claude" ]] && claude_global_hooks_need_repair; then
        needs_repair=0
    fi

    # Check if already enabled
    if [[ $needs_repair -ne 0 ]] && is_tool_enabled "$tool"; then
        if [[ "$quiet" != "quiet" ]]; then
            warning "$tool notifications already enabled"
        fi
        return 0
    fi

    # Enable the tool
    if [[ "$quiet" != "quiet" ]]; then
        if [[ "$tool" == "claude" ]] && [[ $needs_repair -eq 0 ]]; then
            info "Repairing existing $tool notification hooks..."
        else
            info "Enabling $tool notifications..."
        fi
    fi

    if ! enable_tool "$tool"; then
        error "Failed to enable $tool notifications"
        return 1
    fi

    local config_file
    case "$tool" in
        "claude") config_file="$GLOBAL_SETTINGS_FILE" ;;
        "codex") config_file="$CODEX_CONFIG_FILE" ;;
        "gemini") config_file="$GEMINI_SETTINGS_FILE" ;;
        "omp") config_file="$OMP_EXTENSION_FILE" ;;
    esac

    success "$tool: ENABLED"
    if [[ "$quiet" != "quiet" ]]; then
        info "Config: $config_file"
    fi

    return 0
}

# Disable notifications globally
disable_notifications_global() {
    local tool
    tool="$(normalize_tool_argument "${1:-}")"

    header "${MUTE} Disabling Notifications"
    echo ""

    # Create kill switch for instant effect on running sessions
    touch "$HOME/.claude/notifications/disabled"

    # If specific tool requested
    if [[ -n "$tool" ]]; then
        disable_single_tool "$tool"
        return $?
    fi

    # No tool specified - disable all enabled tools
    local disabled_count=0

    for t in claude codex gemini omp; do
        if is_tool_enabled "$t"; then
            if disable_single_tool "$t" "quiet"; then
                ((disabled_count++))
            fi
        fi
    done

    echo ""
    if [[ $disabled_count -gt 0 ]]; then
        success "Disabled notifications for $disabled_count tool(s)"
    else
        warning "No tools had notifications enabled"
    fi
}

# Disable a single tool
disable_single_tool() {
    local tool="$1"
    local quiet="${2:-}"

    # Check if enabled
    if ! is_tool_enabled "$tool"; then
        if [[ "$quiet" != "quiet" ]]; then
            warning "$tool notifications already disabled"
        fi
        return 0
    fi

    # Disable the tool
    if [[ "$quiet" != "quiet" ]]; then
        info "Disabling $tool notifications..."
    fi

    if ! disable_tool "$tool"; then
        error "Failed to disable $tool notifications"
        return 1
    fi

    success "$tool: DISABLED"
    return 0
}

# Show current status
show_status() {
    local arg
    local check_updates_flag=""

    for arg in "$@"; do
        if [[ "$arg" == "--check-updates" ]]; then
            check_updates_flag="yes"
            break
        fi
    done

    header "${INFO} Code-Notify Status"
    echo ""

    # Check for kill switch
    if [[ -f "$HOME/.claude/notifications/disabled" ]]; then
        echo "  ${MUTE} Kill switch: ${YELLOW}ACTIVE${RESET} (suppresses global notifications; project-scoped hooks still run)"
        echo ""
    fi

    # Show status for each tool
    echo "AI Tools:"
    echo ""

    # Claude Code
    if is_tool_installed "claude"; then
        if claude_global_hooks_need_repair; then
            echo "  ${WARNING} Claude Code: ${YELLOW}REPAIR NEEDED${RESET}"
            echo "     Config: $GLOBAL_SETTINGS_FILE"
            echo "     Current hooks still point to an older claude-notify-style configuration"
            echo "     Run: ${CYAN}cn on claude${RESET}"
        elif is_tool_enabled "claude"; then
            echo "  ${CHECK_MARK} Claude Code: ${GREEN}ENABLED${RESET}"
            echo "     Config: $GLOBAL_SETTINGS_FILE"
        else
            echo "  ${MUTE} Claude Code: ${DIM}DISABLED${RESET}"
        fi
    else
        echo "  ${DIM}- Claude Code: not installed${RESET}"
    fi

    # Codex
    if is_tool_installed "codex"; then
        if is_tool_enabled "codex"; then
            echo "  ${CHECK_MARK} Codex: ${GREEN}ENABLED${RESET}"
            echo "     Config: $CODEX_CONFIG_FILE"
            echo "     Events: completion-only via Codex notify payloads"
        else
            echo "  ${MUTE} Codex: ${DIM}DISABLED${RESET}"
        fi
    else
        echo "  ${DIM}- Codex: not installed${RESET}"
    fi

    # Gemini CLI
    if is_tool_installed "gemini"; then
        if is_tool_enabled "gemini"; then
            echo "  ${CHECK_MARK} Gemini CLI: ${GREEN}ENABLED${RESET}"
            echo "     Config: $GEMINI_SETTINGS_FILE"
        else
            echo "  ${MUTE} Gemini CLI: ${DIM}DISABLED${RESET}"
        fi
    else
        echo "  ${DIM}- Gemini CLI: not installed${RESET}"
    fi

    # Oh My Pi (omp)
    if is_tool_installed "omp"; then
        if is_tool_enabled "omp"; then
            echo "  ${CHECK_MARK} omp: ${GREEN}ENABLED${RESET}"
            echo "     Config: $OMP_EXTENSION_FILE"
            echo "     Events: completion via agent_end extension"
        else
            echo "  ${MUTE} omp: ${DIM}DISABLED${RESET}"
        fi
    else
        echo "  ${DIM}- omp: not installed${RESET}"
    fi

    # Voice status
    echo ""
    if is_voice_enabled "global"; then
        local current_voice=$(get_voice "global")
        echo "  ${SPEAKER} Voice: ${GREEN}ENABLED${RESET} ($current_voice)"
    else
        echo "  ${MUTE} Voice: ${DIM}DISABLED${RESET}"
    fi

    # Sound status
    if is_sound_enabled; then
        local sound_file
        sound_file=$(get_sound)
        local sound_name
        sound_name=$(basename "$sound_file" 2>/dev/null || echo "default")
        if [[ -f "$SOUND_CUSTOM_FILE" ]]; then
            echo "  ${BELL} Sound: ${GREEN}ENABLED${RESET} (custom: $sound_name)"
        else
            echo "  ${BELL} Sound: ${GREEN}ENABLED${RESET} (default: $sound_name)"
        fi
    else
        echo "  ${MUTE} Sound: ${DIM}DISABLED${RESET}"
    fi

    # Alert types
    local alert_types=$(get_notify_types)
    echo "  ${BELL} Alert types: ${CYAN}$alert_types${RESET}"

    echo ""
    if channels_has_python3; then
        local channel_summary
        channel_summary="$(channels_list_redacted 2>/dev/null | awk -F '\t' '
            $1 == "enabled" { enabled = $2 }
            $1 == "channel" { count++; providers[$3] = 1 }
            END {
                if (enabled == "") enabled = "true"
                provider_list = ""
                for (provider in providers) {
                    provider_list = provider_list (provider_list ? "," : "") provider
                }
                if (count == "") count = 0
                print enabled "\t" count "\t" provider_list
            }
        ')"
        local channels_enabled channels_count channels_providers
        IFS=$'\t' read -r channels_enabled channels_count channels_providers <<< "$channel_summary"
        if [[ "$channels_enabled" == "true" && "$channels_count" -gt 0 ]]; then
            echo "  ${CHECK_MARK} Channels: ${GREEN}ENABLED${RESET} ($channels_count configured: $channels_providers)"
        elif [[ "$channels_count" -gt 0 ]]; then
            echo "  ${MUTE} Channels: ${DIM}DISABLED${RESET} ($channels_count configured)"
        else
            echo "  ${MUTE} Channels: ${DIM}not configured${RESET}"
        fi
    fi

    if usage_has_python3; then
        local usage_enabled
        usage_enabled="$(usage_read_config_json | python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get("enabled", False) else "false")' 2>/dev/null || echo false)"
        if [[ "$usage_enabled" == "true" ]]; then
            echo "  ${CHECK_MARK} Usage alerts: ${GREEN}ENABLED${RESET}"
        else
            echo "  ${MUTE} Usage alerts: ${DIM}DISABLED${RESET}"
        fi
    fi

    # Notification tool status (platform-specific)
    local current_os
    current_os="$(detect_os)"
    if [[ "$current_os" == "macos" ]]; then
        echo ""
        if detect_terminal_notifier &> /dev/null; then
            echo "  ${CHECK_MARK} terminal-notifier: ${GREEN}INSTALLED${RESET}"
        else
            echo "  ${WARNING} terminal-notifier: ${YELLOW}NOT INSTALLED${RESET}"
            echo "     Install with: ${CYAN}brew install terminal-notifier${RESET}"
        fi
    elif [[ "$current_os" == "wsl" ]]; then
        echo ""
        if detect_wsl_notify_send &> /dev/null; then
            echo "  ${CHECK_MARK} wsl-notify-send.exe: ${GREEN}INSTALLED${RESET}"
        else
            echo "  ${WARNING} wsl-notify-send.exe: ${YELLOW}NOT INSTALLED${RESET}"
            echo "     Install to enable Windows toast notifications in WSL"
        fi
        if command -v notify-send &> /dev/null; then
            echo "  ${CHECK_MARK} notify-send: ${GREEN}INSTALLED${RESET} (WSLg fallback)"
        fi
    elif [[ "$current_os" == "linux" ]]; then
        echo ""
        if command -v notify-send &> /dev/null; then
            echo "  ${CHECK_MARK} notify-send: ${GREEN}INSTALLED${RESET}"
        else
            echo "  ${WARNING} notify-send: ${YELLOW}NOT INSTALLED${RESET}"
            echo "     Install with: ${CYAN}sudo apt install libnotify-bin${RESET} or ${CYAN}sudo dnf install libnotify${RESET}"
        fi
    fi

    # Show version
    echo ""
    dim "code-notify version $VERSION"

    # Check for updates if --check-updates flag is passed
    if [[ -n "$check_updates_flag" ]]; then
        check_for_updates
    fi
}

# Send test notification
test_notification() {
    local silent="${1:-}"
    
    if [[ "$silent" != "silent" ]]; then
        header "${BELL} Testing Notifications"
        echo ""
    fi
    
    # Get notification script
    local notify_script=$(get_notify_script)
    
    if [[ ! -f "$notify_script" ]]; then
        # Fallback to basic notification
        if command -v terminal-notifier &> /dev/null; then
            terminal-notifier \
                -title "Code-Notify Test ${CHECK_MARK}" \
                -message "Notifications are working!" \
                -sound "Glass"
        else
            osascript -e 'display notification "Notifications are working!" with title "Code-Notify Test"'
        fi
    else
        # Use the actual notification script
        "$notify_script" "test"
    fi
    
    if [[ "$silent" != "silent" ]]; then
        success "Test notification sent!"
        info "You should see a notification appear"
    fi
}

# Run setup wizard
run_setup_wizard() {
    header "${ROCKET} Code-Notify Setup Wizard"
    echo ""
    
    # Check Claude Code
    info "Checking Claude Code installation..."
    if detect_claude_code &> /dev/null; then
        success "Claude Code found at: $(detect_claude_code)"
    else
        warning "Claude Code installation not detected"
        info "Code-Notify will create configuration at: $CLAUDE_HOME"
    fi
    
    # Check notification system
    echo ""
    info "Checking notification system..."
    if grep -qi microsoft /proc/version 2>/dev/null; then
        # Check wsl-notify-send (WSL)
        if detect_wsl_notify_send &> /dev/null; then
            success "wsl-notify-send.exe is installed"
        else
            # Prompt to install wsl-notify-send
            warning "wsl-notify-send.exe not found"
            echo ""
            echo "WSL requires wsl-notify-send for Windows Toast notifications."
            echo "Install it with:"
            echo "  ${CYAN}curl -L -o wsl-notify-send.zip https://github.com/stuartleeks/wsl-notify-send/releases/download/v0.1.871612270/wsl-notify-send_windows_amd64.zip${RESET}"
            echo "  ${CYAN}unzip wsl-notify-send.zip -d ~/.local/bin/${RESET}"
            echo "  ${CYAN}chmod +x ~/.local/bin/wsl-notify-send.exe${RESET}"
            echo ""
            read -p "Would you like to install it now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                info "Installing wsl-notify-send.exe..."
                mkdir -p ~/.local/bin
                if curl -sL -o wsl-notify-send.zip https://github.com/stuartleeks/wsl-notify-send/releases/download/v0.1.871612270/wsl-notify-send_windows_amd64.zip && \
                   unzip -o wsl-notify-send.zip -d ~/.local/bin/ && \
                   chmod +x ~/.local/bin/wsl-notify-send.exe; then
                    success "wsl-notify-send.exe installed successfully"
                    info "Make sure ~/.local/bin is in your PATH"
                else
                    error "Failed to install wsl-notify-send.exe"
                    info "You can install it manually later"
                fi
                rm -f wsl-notify-send.zip
            fi
        fi
    elif [[ "$(detect_os)" == "macos" ]]; then
        # Check terminal-notifier (macOS)
        if detect_terminal_notifier &> /dev/null; then
            success "terminal-notifier is installed"
        else
            # Prompt to install terminal-notifier
            warning "terminal-notifier not found"
            echo ""
            echo "For the best experience, install terminal-notifier:"
            echo "  ${CYAN}brew install terminal-notifier${RESET}"
            echo ""
            read -p "Would you like to install it now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                info "Installing terminal-notifier..."
                if brew install terminal-notifier; then
                    success "terminal-notifier installed successfully"
                else
                    error "Failed to install terminal-notifier"
                    info "You can install it manually later"
                fi
            fi
        fi
    else
        # Check notify-send (Linux)
        if command -v notify-send &> /dev/null; then
            success "notify-send is installed"
        else
            warning "notify-send not found"
            echo ""
            echo "For desktop notifications, install libnotify:"
            if command -v apt &> /dev/null; then
                echo "  ${CYAN}sudo apt install libnotify-bin${RESET}"
                echo ""
                read -p "Would you like to install it now? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    info "Installing libnotify-bin..."
                    if sudo apt install -y libnotify-bin; then
                        success "notify-send installed successfully"
                    else
                        error "Failed to install libnotify-bin"
                        info "You can install it manually later"
                    fi
                fi
            elif command -v dnf &> /dev/null; then
                echo "  ${CYAN}sudo dnf install libnotify${RESET}"
                echo ""
                read -p "Would you like to install it now? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    info "Installing libnotify..."
                    if sudo dnf install -y libnotify; then
                        success "notify-send installed successfully"
                    else
                        error "Failed to install libnotify"
                        info "You can install it manually later"
                    fi
                fi
            elif command -v pacman &> /dev/null; then
                echo "  ${CYAN}sudo pacman -S libnotify${RESET}"
                echo ""
                read -p "Would you like to install it now? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    info "Installing libnotify..."
                    if sudo pacman -S --noconfirm libnotify; then
                        success "notify-send installed successfully"
                    else
                        error "Failed to install libnotify"
                        info "You can install it manually later"
                    fi
                fi
            else
                echo "  Install libnotify using your distro's package manager"
                info "Alternatively, zenity can be used as a fallback"
            fi
        fi
    fi
    
    # Enable notifications
    echo ""
    read -p "Enable notifications globally? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        enable_notifications_global
    else
        info "You can enable notifications later with: ${CYAN}cn on${RESET}"
    fi
    
    echo ""
    success "Setup complete!"
    echo ""
    echo "Quick commands:"
    echo "  ${CYAN}cn on${RESET}     - Enable notifications"
    echo "  ${CYAN}cn off${RESET}    - Disable notifications"
    echo "  ${CYAN}cn status${RESET} - Check status"
    echo "  ${CYAN}cnp on${RESET}    - Enable for current project"
    echo ""
}

# Handle voice commands
# Usage: cn voice on [tool], cn voice off [tool], cn voice status
handle_voice_command() {
    local subcommand="${1:-status}"
    local tool="${2:-}"

    case "$subcommand" in
        "on")
            header "${SPEAKER} Enabling Voice Notifications"
            echo ""

            # Show available voices
            info "Available English voices:"
            list_available_voices | awk '{print "  - " $1}' | column
            echo ""

            # Ask for voice preference
            read -p "Which voice would you like? (default: Samantha) " voice
            voice=${voice:-Samantha}

            if [[ -n "$tool" ]]; then
                # Enable for specific tool
                enable_voice "$voice" "tool" "$tool"
                success "Voice ENABLED for $tool with voice: $voice"
                test_voice "$voice" "$tool voice notifications enabled"
            else
                # Enable globally (for all tools)
                enable_voice "$voice" "global"
                success "Voice ENABLED globally with voice: $voice"
                test_voice "$voice" "Voice notifications enabled for all tools"
            fi
            ;;

        "off")
            header "${MUTE} Disabling Voice Notifications"
            echo ""

            if [[ -n "$tool" ]]; then
                # Disable for specific tool
                disable_voice "tool" "$tool"
                success "Voice DISABLED for $tool"
            else
                # Disable all voice settings
                disable_voice "all"
                success "Voice DISABLED for all tools"
            fi
            ;;

        "status"|*)
            show_voice_status
            ;;
    esac
}

# Show detailed voice status
show_voice_status() {
    header "${SPEAKER} Voice Status"
    echo ""

    # Global voice
    if is_voice_enabled "global"; then
        local voice=$(get_voice "global")
        echo "  ${CHECK_MARK} Global: ${GREEN}ENABLED${RESET} ($voice)"
    else
        echo "  ${MUTE} Global: ${DIM}DISABLED${RESET}"
    fi

    # Per-tool voice
    for tool in claude codex gemini; do
        local tool_display
        case "$tool" in
            "claude") tool_display="Claude" ;;
            "codex") tool_display="Codex" ;;
            "gemini") tool_display="Gemini" ;;
        esac

        if is_voice_enabled "tool" "$tool"; then
            local voice=$(get_voice "tool" "$tool")
            echo "  ${CHECK_MARK} $tool_display: ${GREEN}ENABLED${RESET} ($voice)"
        else
            echo "  ${DIM}- $tool_display: uses global setting${RESET}"
        fi
    done

    echo ""
    info "Commands:"
    echo "  ${CYAN}cn voice on${RESET}          Enable for all tools"
    echo "  ${CYAN}cn voice on claude${RESET}   Enable for Claude only"
    echo "  ${CYAN}cn voice off${RESET}         Disable all"
    echo "  ${CYAN}cn voice off codex${RESET}   Disable for Codex only"
}

# ============================================
# Alert Types Management
# ============================================

# Handle alerts commands
# Usage: cn alerts, cn alerts add <type>, cn alerts remove <type>, cn alerts reset
handle_alerts_command() {
    local subcommand="${1:-}"
    local type="${2:-}"

    case "$subcommand" in
        "")
            show_alerts_status
            ;;
        "add")
            if [[ -z "$type" ]]; then
                error "Please specify a notification type"
                echo ""
                show_available_alert_types
                return 1
            fi
            add_alert_type "$type"
            ;;
        "remove"|"rm")
            if [[ -z "$type" ]]; then
                error "Please specify a notification type to remove"
                return 1
            fi
            remove_alert_type "$type"
            ;;
        "reset")
            reset_alert_types
            ;;
        "help"|"-h"|"--help")
            show_alerts_help
            ;;
        *)
            error "Unknown alerts command: $subcommand"
            show_alerts_help
            return 1
            ;;
    esac
}

# Show current alert types status
show_alerts_status() {
    header "${BELL} Alert Types"
    echo ""

    local current=$(get_notify_types)

    echo "  Current configuration:"
    echo "  Matcher: ${CYAN}$current${RESET}"
    echo ""

    echo "  Claude Notification subtypes:"
    if is_notify_type_enabled "idle_prompt"; then
        echo "    ${CHECK_MARK} ${GREEN}idle_prompt${RESET} - AI is waiting for your input (60+ sec idle)"
    else
        echo "    ${MUTE} ${DIM}idle_prompt${RESET}"
    fi

    if is_notify_type_enabled "permission_prompt"; then
        echo "    ${CHECK_MARK} ${GREEN}permission_prompt${RESET} - AI needs tool permission (Y/n)"
    else
        echo "    ${MUTE} ${DIM}permission_prompt${RESET}"
    fi

    if is_notify_type_enabled "auth_success"; then
        echo "    ${CHECK_MARK} ${GREEN}auth_success${RESET} - Authentication success"
    else
        echo "    ${MUTE} ${DIM}auth_success${RESET}"
    fi

    if is_notify_type_enabled "elicitation_dialog"; then
        echo "    ${CHECK_MARK} ${GREEN}elicitation_dialog${RESET} - MCP tool input needed"
    else
        echo "    ${MUTE} ${DIM}elicitation_dialog${RESET}"
    fi

    if is_notify_type_enabled "ask_user"; then
        echo "    ${CHECK_MARK} ${GREEN}ask_user${RESET} - AI asks a question (immediate notification)"
    else
        echo "    ${MUTE} ${DIM}ask_user${RESET}"
    fi

    echo ""
    echo "  Claude agent/team hook events:"
    if is_notify_type_enabled "SubagentStart"; then
        echo "    ${CHECK_MARK} ${GREEN}SubagentStart${RESET} - A Claude subagent started"
    else
        echo "    ${MUTE} ${DIM}SubagentStart${RESET}"
    fi

    if is_notify_type_enabled "SubagentStop"; then
        echo "    ${CHECK_MARK} ${GREEN}SubagentStop${RESET} - A Claude subagent completed"
    else
        echo "    ${MUTE} ${DIM}SubagentStop${RESET}"
    fi

    if is_notify_type_enabled "TeammateIdle"; then
        echo "    ${CHECK_MARK} ${GREEN}TeammateIdle${RESET} - A Claude teammate is idle"
    else
        echo "    ${MUTE} ${DIM}TeammateIdle${RESET}"
    fi

    if is_notify_type_enabled "TaskCreated"; then
        echo "    ${CHECK_MARK} ${GREEN}TaskCreated${RESET} - An agent-team task was created"
    else
        echo "    ${MUTE} ${DIM}TaskCreated${RESET}"
    fi

    if is_notify_type_enabled "TaskCompleted"; then
        echo "    ${CHECK_MARK} ${GREEN}TaskCompleted${RESET} - An agent-team task completed"
    else
        echo "    ${MUTE} ${DIM}TaskCompleted${RESET}"
    fi

    echo ""
    info "Examples:"
    echo "  ${CYAN}cn alerts add permission_prompt${RESET}   # Also notify on tool permission requests"
    echo "  ${CYAN}cn alerts add ask_user${RESET}            # Notify immediately when Claude asks a question"
    echo "  ${CYAN}cn alerts add SubagentStop${RESET}        # Notify when Claude subagents finish"
    echo "  ${CYAN}cn alerts add auth_success${RESET}        # Also notify on auth success"
    echo "  ${CYAN}cn alerts remove permission_prompt${RESET} # Stop permission notifications"
    echo "  ${CYAN}cn alerts reset${RESET}                   # Back to idle_prompt only"
    echo ""
    dim "Alert-type matching applies to Claude Code and Gemini CLI hooks."
    dim "Claude agent/team events are separate hooks and are opt-in."
    dim "Codex currently exposes completion events through notify, so permission_prompt/idle_prompt settings do not change Codex behavior."
    echo ""
    dim "After changing, run 'cn on' to apply the new settings."
}

# Show available alert types
show_available_alert_types() {
    echo "Available notification types:"
    echo "  ${CYAN}idle_prompt${RESET}        - AI is waiting for your input (recommended)"
    echo "  ${CYAN}permission_prompt${RESET}  - AI needs tool permission (can be noisy)"
    echo "  ${CYAN}auth_success${RESET}       - Authentication success"
    echo "  ${CYAN}elicitation_dialog${RESET} - MCP tool input needed"
    echo "  ${CYAN}ask_user${RESET}           - AI asks a question (immediate PreToolUse notification)"
    echo ""
    echo "Claude agent/team hook events:"
    echo "  ${CYAN}SubagentStart${RESET}      - A Claude subagent started"
    echo "  ${CYAN}SubagentStop${RESET}       - A Claude subagent completed"
    echo "  ${CYAN}TeammateIdle${RESET}       - A Claude teammate is idle"
    echo "  ${CYAN}TaskCreated${RESET}        - An agent-team task was created"
    echo "  ${CYAN}TaskCompleted${RESET}      - An agent-team task completed"
    echo ""
    echo "Aliases like ${CYAN}subagent_stop${RESET}, ${CYAN}teammate-idle${RESET}, and ${CYAN}task_completed${RESET} are accepted."
}

# Add an alert type
add_alert_type() {
    local type
    type="$(normalize_alert_type "$1" 2>/dev/null || true)"

    if [[ -z "$type" ]]; then
        error "Unknown notification type: $1"
        echo ""
        show_available_alert_types
        return 1
    fi

    if is_notify_type_enabled "$type"; then
        warning "$type is already enabled"
        return 0
    fi

    add_notify_type "$type"

    # For ask_user: register PreToolUse hook immediately
    if [[ "$type" == "ask_user" ]] && is_tool_enabled "claude"; then
        register_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"
    fi

    success "Added: $type"
    if [[ "$type" != "ask_user" ]]; then
        echo ""
        info "Run ${CYAN}cn on${RESET} to apply changes"
    fi
}

# Remove an alert type
remove_alert_type() {
    local type
    type="$(normalize_alert_type "$1" 2>/dev/null || true)"

    if [[ -z "$type" ]]; then
        error "Unknown notification type: $1"
        echo ""
        show_available_alert_types
        return 1
    fi

    if ! is_notify_type_enabled "$type"; then
        warning "$type is not currently enabled"
        return 0
    fi

    remove_notify_type "$type"

    # For ask_user: unregister PreToolUse hook immediately
    if [[ "$type" == "ask_user" ]] && is_tool_enabled "claude"; then
        unregister_ask_user_hook "$GLOBAL_SETTINGS_FILE" "$(get_global_claude_pre_tool_use_command)"
    fi

    success "Removed: $type"
    if [[ "$type" != "ask_user" ]]; then
        echo ""
        info "Run ${CYAN}cn on${RESET} to apply changes"
    fi
}

# Reset alert types to default
reset_alert_types() {
    reset_notify_types
    success "Reset to default: idle_prompt"
    echo ""
    info "Run ${CYAN}cn on${RESET} to apply changes"
}

# Show alerts help
show_alerts_help() {
    echo ""
    echo "Usage: cn alerts [command] [type]"
    echo ""
    echo "Commands:"
    echo "  (none)         Show current alert type configuration"
    echo "  add <type>     Add a notification type"
    echo "  remove <type>  Remove a notification type"
    echo "  reset          Reset to default (idle_prompt only)"
    echo ""
    show_available_alert_types
    echo ""
    echo "Examples:"
    echo "  cn alerts                        # Show current config"
    echo "  cn alerts add permission_prompt  # Also notify on permission requests"
    echo "  cn alerts add SubagentStop       # Also notify when Claude subagents finish"
    echo "  cn alerts remove permission_prompt"
    echo "  cn alerts reset                  # Back to idle_prompt only"
}

# ============================================
# Sound Notifications Management
# ============================================

# Handle sound commands
# Usage: cn sound on, cn sound off, cn sound set <path>, cn sound test, etc.
handle_sound_command() {
    local subcommand="${1:-status}"
    shift 2>/dev/null || true

    case "$subcommand" in
        "on")
            header "${BELL} Enabling Sound Notifications"
            echo ""
            enable_sound
            success "Sound notifications ENABLED"
            echo ""
            info "Using: $(get_sound)"
            echo ""
            test_sound
            ;;
        "off")
            header "${MUTE} Disabling Sound Notifications"
            echo ""
            disable_sound
            success "Sound notifications DISABLED"
            ;;
        "set")
            local sound_path="$1"
            if [[ -z "$sound_path" ]]; then
                error "Please provide a path to a sound file"
                echo ""
                echo "Usage: cn sound set <path>"
                echo "Example: cn sound set ~/sounds/notification.wav"
                return 1
            fi
            header "${BELL} Setting Custom Sound"
            echo ""
            if set_custom_sound "$sound_path"; then
                enable_sound
                success "Custom sound set: $sound_path"
                echo ""
                test_sound
            fi
            ;;
        "default")
            header "${BELL} Resetting to Default Sound"
            echo ""
            reset_sound
            local default_sound
            default_sound=$(get_default_sound)
            if [[ -n "$default_sound" ]]; then
                success "Reset to default sound"
                info "Using: $default_sound"
            else
                warning "No default sound available for this platform"
            fi
            ;;
        "test")
            header "${BELL} Testing Sound"
            echo ""
            if is_sound_enabled; then
                test_sound
                success "Sound played!"
            else
                warning "Sound is disabled"
                info "Enable with: cn sound on"
            fi
            ;;
        "list")
            header "${BELL} Available System Sounds"
            echo ""
            list_system_sounds
            ;;
        "status"|*)
            show_sound_status
            ;;
    esac
}

# Show detailed sound status
show_sound_status() {
    header "${BELL} Sound Status"
    echo ""

    if is_sound_enabled; then
        local sound_file
        sound_file=$(get_sound)
        if [[ -f "$SOUND_CUSTOM_FILE" ]]; then
            echo "  ${CHECK_MARK} Sound: ${GREEN}ENABLED${RESET} (custom)"
            echo "     File: $sound_file"
        else
            echo "  ${CHECK_MARK} Sound: ${GREEN}ENABLED${RESET} (default)"
            echo "     File: $sound_file"
        fi
    else
        echo "  ${MUTE} Sound: ${DIM}DISABLED${RESET}"
    fi

    echo ""
    info "Commands:"
    echo "  ${CYAN}cn sound on${RESET}              Enable with default system sound"
    echo "  ${CYAN}cn sound off${RESET}             Disable sound notifications"
    echo "  ${CYAN}cn sound set <path>${RESET}      Use custom sound file"
    echo "  ${CYAN}cn sound default${RESET}         Reset to system default"
    echo "  ${CYAN}cn sound test${RESET}            Play current sound"
    echo "  ${CYAN}cn sound list${RESET}            Show available system sounds"
}
