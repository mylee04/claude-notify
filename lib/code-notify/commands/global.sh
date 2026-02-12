#!/bin/bash

# Global command handlers for Code-Notify

# Source utilities
GLOBAL_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$GLOBAL_CMD_DIR/../utils/voice.sh"
source "$GLOBAL_CMD_DIR/../utils/sound.sh"
source "$GLOBAL_CMD_DIR/../utils/help.sh"

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

# Show version (can be called from handle_global_command)
show_version() {
    echo "code-notify version $VERSION"
}

# Enable notifications globally
enable_notifications_global() {
    local tool="${1:-}"

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
        info "Supported tools: Claude Code, Codex, Gemini CLI"
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

    # Check if tool is installed
    if ! is_tool_installed "$tool"; then
        if [[ "$quiet" != "quiet" ]]; then
            warning "$tool is not installed"
        fi
        return 1
    fi

    # Check if already enabled
    if is_tool_enabled "$tool"; then
        if [[ "$quiet" != "quiet" ]]; then
            warning "$tool notifications already enabled"
        fi
        return 0
    fi

    # Enable the tool
    if [[ "$quiet" != "quiet" ]]; then
        info "Enabling $tool notifications..."
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
    esac

    success "$tool: ENABLED"
    if [[ "$quiet" != "quiet" ]]; then
        info "Config: $config_file"
    fi

    return 0
}

# Disable notifications globally
disable_notifications_global() {
    local tool="${1:-}"

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

    for t in claude codex gemini; do
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
    header "${INFO} Code-Notify Status"
    echo ""

    # Check for kill switch
    if [[ -f "$HOME/.claude/notifications/disabled" ]]; then
        echo "  ${MUTE} Kill switch: ${YELLOW}ACTIVE${RESET} (instant disable)"
        echo ""
    fi

    # Show status for each tool
    echo "AI Tools:"
    echo ""

    # Claude Code
    if is_tool_installed "claude"; then
        if is_tool_enabled "claude"; then
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

    # Terminal notifier status (macOS)
    if [[ "$(detect_os)" == "macos" ]]; then
        echo ""
        if detect_terminal_notifier &> /dev/null; then
            echo "  ${CHECK_MARK} terminal-notifier: ${GREEN}INSTALLED${RESET}"
        else
            echo "  ${WARNING} terminal-notifier: ${YELLOW}NOT INSTALLED${RESET}"
            echo "     Install with: ${CYAN}brew install terminal-notifier${RESET}"
        fi
    fi

    # Show version
    echo ""
    dim "code-notify version $VERSION"

    # Check for updates if --check-updates flag is passed
    if [[ "$1" == "--check-updates" ]]; then
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
    else
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

# Check for updates (basic implementation)
check_for_updates() {
    echo ""
    info "Checking for updates..."
    # This would normally check GitHub releases API
    # For now, just show how to update
    echo "To update code-notify, run:"
    echo "  ${CYAN}brew upgrade code-notify${RESET}"
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

    echo "  Active types:"
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

    echo ""
    info "Examples:"
    echo "  ${CYAN}cn alerts add permission_prompt${RESET}   # Also notify on tool permission requests"
    echo "  ${CYAN}cn alerts add auth_success${RESET}        # Also notify on auth success"
    echo "  ${CYAN}cn alerts remove permission_prompt${RESET} # Stop permission notifications"
    echo "  ${CYAN}cn alerts reset${RESET}                   # Back to idle_prompt only"
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
}

# Add an alert type
add_alert_type() {
    local type="$1"

    # Validate type
    case "$type" in
        "idle_prompt"|"permission_prompt"|"auth_success"|"elicitation_dialog")
            ;;
        *)
            error "Unknown notification type: $type"
            echo ""
            show_available_alert_types
            return 1
            ;;
    esac

    if is_notify_type_enabled "$type"; then
        warning "$type is already enabled"
        return 0
    fi

    add_notify_type "$type"
    success "Added: $type"
    echo ""
    info "Run ${CYAN}cn on${RESET} to apply changes"
}

# Remove an alert type
remove_alert_type() {
    local type="$1"

    if ! is_notify_type_enabled "$type"; then
        warning "$type is not currently enabled"
        return 0
    fi

    remove_notify_type "$type"
    success "Removed: $type"
    echo ""
    info "Run ${CYAN}cn on${RESET} to apply changes"
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