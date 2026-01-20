#!/bin/bash

# Global command handlers for Claude-Notify

# Source utilities
GLOBAL_CMD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$GLOBAL_CMD_DIR/../utils/voice.sh"
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
    echo "claude-notify version $VERSION"
}

# Enable notifications globally
enable_notifications_global() {
    local tool="${1:-}"

    header "${ROCKET} Enabling Notifications"
    echo ""

    ensure_config_dir

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

    enable_tool "$tool"

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

    disable_tool "$tool"

    success "$tool: DISABLED"
    return 0
}

# Show current status
show_status() {
    header "${INFO} Code-Notify Status"
    echo ""

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
                -title "Claude-Notify Test ${CHECK_MARK}" \
                -message "Notifications are working!" \
                -sound "Glass"
        else
            osascript -e 'display notification "Notifications are working!" with title "Claude-Notify Test"'
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
    header "${ROCKET} Claude-Notify Setup Wizard"
    echo ""
    
    # Check Claude Code
    info "Checking Claude Code installation..."
    if detect_claude_code &> /dev/null; then
        success "Claude Code found at: $(detect_claude_code)"
    else
        warning "Claude Code installation not detected"
        info "Claude-Notify will create configuration at: $CLAUDE_HOME"
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
    echo "To update claude-notify, run:"
    echo "  ${CYAN}brew upgrade claude-notify${RESET}"
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