#!/bin/bash

# Shared help text for Code-Notify

# Show help message
# Usage: show_help [command_name]
show_help() {
    local cmd_name="${1:-cn}"
    cat << EOF
${BOLD}Code-Notify${RESET} - Desktop notifications for AI coding tools

${BOLD}SUPPORTED TOOLS:${RESET}
    Claude Code, OpenAI Codex, Google Gemini CLI

${BOLD}USAGE:${RESET}
    $cmd_name <command> [tool]

${BOLD}COMMANDS:${RESET}
    ${GREEN}on${RESET}              Enable notifications (all detected tools)
    ${GREEN}on${RESET} <tool>       Enable for specific tool (claude/codex/gemini)
    ${GREEN}off${RESET}             Disable notifications (all tools)
    ${GREEN}off${RESET} <tool>      Disable for specific tool
    ${GREEN}status${RESET}          Show status for all tools
    ${GREEN}test${RESET}            Send a test notification
    ${GREEN}alerts${RESET} <cmd>    Configure which events trigger alerts
    ${GREEN}voice${RESET} <cmd>     Voice notification commands
    ${GREEN}setup${RESET}           Run initial setup wizard
    ${GREEN}help${RESET}            Show this help message
    ${GREEN}version${RESET}         Show version information

${BOLD}TOOL NAMES:${RESET}
    ${CYAN}claude${RESET}          Claude Code
    ${CYAN}codex${RESET}           OpenAI Codex CLI
    ${CYAN}gemini${RESET}          Google Gemini CLI

${BOLD}PROJECT COMMANDS:${RESET}
    ${GREEN}project on${RESET}      Enable for current project
    ${GREEN}project off${RESET}     Disable for current project
    ${GREEN}project status${RESET}  Check project status

${BOLD}ALERT TYPES:${RESET}
    ${GREEN}alerts${RESET}              Show current alert type configuration
    ${GREEN}alerts add${RESET} <type>   Add a notification type
    ${GREEN}alerts remove${RESET} <type> Remove a notification type
    ${GREEN}alerts reset${RESET}        Reset to default (idle_prompt only)

    Types: ${CYAN}idle_prompt${RESET} (default), ${CYAN}permission_prompt${RESET}, ${CYAN}auth_success${RESET}, ${CYAN}elicitation_dialog${RESET}

${BOLD}VOICE COMMANDS:${RESET}
    ${GREEN}voice on${RESET}            Enable voice for all tools
    ${GREEN}voice on${RESET} <tool>     Enable voice for specific tool
    ${GREEN}voice off${RESET}           Disable all voice
    ${GREEN}voice off${RESET} <tool>    Disable voice for specific tool
    ${GREEN}voice status${RESET}        Show voice settings

${BOLD}ALIASES:${RESET}
    ${CYAN}cn${RESET}  <command>   Main command
    ${CYAN}cnp${RESET} <command>   Shortcut for project commands

${BOLD}EXAMPLES:${RESET}
    cn on                   # Enable for all detected tools
    cn on claude            # Enable for Claude Code only
    cn off                  # Disable all
    cn status               # Show status for all tools
    cn test                 # Send test notification
    cn alerts               # Show alert type config
    cn alerts add permission_prompt  # Also notify on permission requests
    cn alerts reset         # Back to idle_prompt only (less noisy)
    cnp on                  # Enable for current project

${BOLD}MORE INFO:${RESET}
    ${DIM}https://github.com/mylee04/code-notify${RESET}

EOF
}
