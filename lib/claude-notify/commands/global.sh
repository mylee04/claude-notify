#!/bin/bash

# Global command handlers for Claude-Notify

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
        *)
            error "Unknown command: $command"
            exit 1
            ;;
    esac
}

# Enable notifications globally
enable_notifications_global() {
    header "${ROCKET} Enabling Claude-Notify Globally"
    echo ""
    
    ensure_config_dir
    
    # Check if already enabled
    if is_enabled_globally; then
        warning "Global notifications are already enabled"
        info "Config location: $GLOBAL_SETTINGS_FILE"
        return 0
    fi
    
    info "Enabling notifications in settings.json..."
    
    # Backup existing settings
    if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
        backup_config "$GLOBAL_SETTINGS_FILE"
    fi
    
    # Enable hooks in settings.json
    enable_hooks_in_settings
    
    success "Global notifications ENABLED"
    info "Config updated: $GLOBAL_SETTINGS_FILE"
    
    # Send test notification
    echo ""
    info "Sending test notification..."
    test_notification "silent"
}

# Disable notifications globally
disable_notifications_global() {
    header "${MUTE} Disabling Claude-Notify Globally"
    echo ""
    
    if ! is_enabled_globally; then
        warning "Global notifications are already disabled"
        return 0
    fi
    
    # Backup before disabling
    if [[ -f "$GLOBAL_SETTINGS_FILE" ]]; then
        backup_config "$GLOBAL_SETTINGS_FILE"
    fi
    
    # Disable hooks in settings.json
    disable_hooks_in_settings
    
    success "Global notifications DISABLED"
    info "Hooks removed from: $GLOBAL_SETTINGS_FILE"
}

# Show current status
show_status() {
    header "${INFO} Claude-Notify Status"
    echo ""
    get_status_info
    
    # Show version
    echo ""
    dim "claude-notify version $VERSION"
    
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
    
    # Check terminal-notifier
    echo ""
    info "Checking notification system..."
    if detect_terminal_notifier &> /dev/null; then
        success "terminal-notifier is installed"
    else
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
handle_voice_command() {
    local subcommand="${1:-status}"
    
    case "$subcommand" in
        "on")
            header "${SPEAKER} Enabling Voice Notifications"
            echo ""
            
            # Show available voices
            info "Available English voices:"
            say -v ? | grep "en_" | head -10 | awk '{print "  - " $1}' | column
            echo ""
            
            # Ask for voice preference
            read -p "Which voice would you like? (default: Samantha) " voice
            voice=${voice:-Samantha}
            
            # Enable voice
            mkdir -p ~/.claude/notifications
            echo "$voice" > ~/.claude/notifications/voice-enabled
            success "Voice notifications ENABLED with voice: $voice"
            
            # Test it
            say -v "$voice" "Voice notifications enabled, Master" &
            ;;
            
        "off")
            header "${MUTE} Disabling Voice Notifications"
            echo ""
            rm -f ~/.claude/notifications/voice-enabled
            success "Voice notifications DISABLED"
            ;;
            
        "status"|*)
            if [[ -f ~/.claude/notifications/voice-enabled ]]; then
                local current_voice=$(cat ~/.claude/notifications/voice-enabled)
                status_enabled "Voice notifications: ENABLED (using $current_voice)"
            else
                status_disabled "Voice notifications: DISABLED"
            fi
            ;;
    esac
}