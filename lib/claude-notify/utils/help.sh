#!/bin/bash

# Shared help text for Claude-Notify

# Show help message
# Usage: show_help [command_name]
show_help() {
    local cmd_name="${1:-claude-notify}"
    cat << EOF
${BOLD}Claude-Notify${RESET} - Native OS notifications for Claude Code

${BOLD}USAGE:${RESET}
    $cmd_name <command> [options]

${BOLD}COMMANDS:${RESET}
    ${GREEN}on${RESET}              Enable notifications globally
    ${GREEN}off${RESET}             Disable notifications globally
    ${GREEN}status${RESET}          Show notification status
    ${GREEN}test${RESET}            Send a test notification
    ${GREEN}voice${RESET} <cmd>     Voice notification commands
    ${GREEN}setup${RESET}           Run initial setup wizard
    ${GREEN}project${RESET} <cmd>   Project-specific commands
    ${GREEN}help${RESET}            Show this help message
    ${GREEN}version${RESET}         Show version information

${BOLD}PROJECT COMMANDS:${RESET}
    ${GREEN}project on${RESET}      Enable for current project
    ${GREEN}project off${RESET}     Disable for current project
    ${GREEN}project status${RESET}  Check project status
    ${GREEN}project init${RESET}    Interactive project setup
    ${GREEN}project voice${RESET}   Set project-specific voice

${BOLD}VOICE COMMANDS:${RESET}
    ${GREEN}voice on${RESET}        Enable voice notifications
    ${GREEN}voice off${RESET}       Disable voice notifications
    ${GREEN}voice status${RESET}    Check voice status

${BOLD}ALIASES:${RESET}
    ${CYAN}cn${RESET}  <command>   Shortcut for claude-notify
    ${CYAN}cnp${RESET} <command>   Shortcut for claude-notify project

${BOLD}EXAMPLES:${RESET}
    $cmd_name on            # Enable notifications
    cn off                      # Disable notifications (using alias)
    cnp on                      # Enable for current project
    claude-notify test          # Send test notification

${BOLD}MORE INFO:${RESET}
    ${DIM}https://github.com/mylee04/claude-notify${RESET}

EOF
}
