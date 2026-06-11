#!/bin/bash

# Shared help text for Code-Notify

is_macos_help_context() {
    [[ "$(uname -s)" == "Darwin" ]]
}

# Show help message
# Usage: show_help [command_name]
show_help() {
    local cmd_name="${1:-cn}"
    cat << EOF
${BOLD}Code-Notify${RESET} - Desktop notifications for AI coding tools

${BOLD}SUPPORTED TOOLS:${RESET}
    Claude Code, OpenAI Codex, Google Gemini CLI, Oh My Pi (omp)

${BOLD}USAGE:${RESET}
    $cmd_name <command> [tool]

${BOLD}COMMANDS:${RESET}
    ${GREEN}on${RESET}              Enable notifications (all detected tools)
    ${GREEN}on${RESET} all          Enable notifications (explicit alias for all detected tools)
    ${GREEN}on${RESET} <tool>       Enable for specific tool (claude/codex/gemini/omp)
    ${GREEN}off${RESET}             Disable notifications (all tools)
    ${GREEN}off${RESET} all         Disable notifications (explicit alias for all tools)
    ${GREEN}off${RESET} <tool>      Disable for specific tool
    ${GREEN}status${RESET}          Show status for all tools
    ${GREEN}status${RESET} all      Show status for all tools (explicit alias)
    ${GREEN}test${RESET}            Send a test notification
    ${GREEN}update${RESET} [check]  Update code-notify or check the latest release
    ${GREEN}alerts${RESET} <cmd>    Configure which events trigger alerts
    ${GREEN}channels${RESET} <cmd>  Configure Slack/Discord delivery
    ${GREEN}usage${RESET} <cmd>     Configure Codex/Claude usage alerts
    ${GREEN}voice${RESET} <cmd>     Voice notification commands
EOF

    if is_macos_help_context; then
        cat << EOF
    ${GREEN}click-through${RESET}   Configure which app opens on notification click
EOF
    fi

    cat << EOF
    ${GREEN}setup${RESET}           Run initial setup wizard
    ${GREEN}help${RESET}            Show this help message
    ${GREEN}version${RESET}         Show version information

${BOLD}TOOL NAMES:${RESET}
    ${CYAN}claude${RESET}          Claude Code
    ${CYAN}codex${RESET}           OpenAI Codex CLI
    ${CYAN}gemini${RESET}          Google Gemini CLI
    ${CYAN}omp${RESET}             Oh My Pi (omp)

${BOLD}PROJECT COMMANDS:${RESET}
    ${GREEN}project on${RESET}      Enable for current project
    ${GREEN}project off${RESET}     Disable for current project
    ${GREEN}project status${RESET}  Check project status

${BOLD}ALERT TYPES:${RESET}
    ${GREEN}alerts${RESET}              Show current alert type configuration
    ${GREEN}alerts add${RESET} <type>   Add a notification type
    ${GREEN}alerts remove${RESET} <type> Remove a notification type
    ${GREEN}alerts reset${RESET}        Reset to default (idle_prompt only)

    Notification types: ${CYAN}idle_prompt${RESET} (default), ${CYAN}permission_prompt${RESET}, ${CYAN}auth_success${RESET}, ${CYAN}elicitation_dialog${RESET}, ${CYAN}ask_user${RESET}
    Claude events: ${CYAN}SubagentStart${RESET}, ${CYAN}SubagentStop${RESET}, ${CYAN}TeammateIdle${RESET}, ${CYAN}TaskCreated${RESET}, ${CYAN}TaskCompleted${RESET}
    Note: alert-type matching applies to Claude Code and Gemini CLI hooks.
          Codex currently exposes completion events through its notify payload.
          omp exposes completion events through a generated extension module.

${BOLD}VOICE COMMANDS:${RESET}
    ${GREEN}voice on${RESET}            Enable voice for all tools
    ${GREEN}voice on${RESET} <tool>     Enable voice for specific tool
    ${GREEN}voice off${RESET}           Disable all voice
    ${GREEN}voice off${RESET} <tool>    Disable voice for specific tool
    ${GREEN}voice status${RESET}        Show voice settings

${BOLD}SOUND COMMANDS:${RESET}
    ${GREEN}sound on${RESET}            Enable with default system sound
    ${GREEN}sound off${RESET}           Disable sound notifications
    ${GREEN}sound set${RESET} <path>    Use custom sound file (.wav, .aiff, .mp3, .ogg)
    ${GREEN}sound default${RESET}       Reset to system default
    ${GREEN}sound test${RESET}          Play current sound
    ${GREEN}sound list${RESET}          Show available system sounds
    ${GREEN}sound status${RESET}        Show sound configuration

${BOLD}CHANNEL COMMANDS:${RESET}
    ${GREEN}channels status${RESET}     Show Slack/Discord channel status
    ${GREEN}channels add${RESET} slack <url> [--name <name>]
    ${GREEN}channels add${RESET} discord <url> [--name <name>]
    ${GREEN}channels remove${RESET} <name>
    ${GREEN}channels test${RESET} [name|all]
    ${GREEN}channels on${RESET}         Enable remote delivery
    ${GREEN}channels off${RESET}        Disable remote delivery

${BOLD}USAGE ALERT COMMANDS:${RESET}
    ${GREEN}usage status${RESET}        Show usage alert status
    ${GREEN}usage setup${RESET}         Guided usage alert setup
    ${GREEN}usage on${RESET} [tool]     Enable Codex/Claude usage alerts
    ${GREEN}usage off${RESET} [tool]    Disable usage alerts
    ${GREEN}usage check${RESET} [tool]  Check now and notify on threshold/reset changes
    ${GREEN}usage watch${RESET} [tool] [--interval seconds]
    ${GREEN}usage watch start${RESET} [tool] [--interval seconds]
    ${GREEN}usage watch stop${RESET}    Stop background usage watcher
    ${GREEN}usage thresholds set${RESET} 20,10
    ${GREEN}usage reset-state${RESET}   Clear usage alert dedupe state
EOF

    if is_macos_help_context; then
        cat << EOF

${BOLD}CLICK-THROUGH COMMANDS:${RESET}
    ${GREEN}click-through${RESET}              Show current mappings
    ${GREEN}click-through add${RESET} [name]   Add an app mapping
    ${GREEN}click-through remove${RESET}       Interactively remove mappings
    ${GREEN}click-through reset${RESET}        Reset to built-in defaults

    Note: controls which app Code-Notify activates when you click a macOS notification.
EOF
    fi

    cat << EOF

${BOLD}ALIASES:${RESET}
    ${CYAN}cn${RESET}  <command>   Main command
    ${CYAN}cnp${RESET} <command>   Shortcut for project commands

${BOLD}EXAMPLES:${RESET}
    cn on                   # Enable for all detected tools
    cn on all               # Same as cn on
    cn on claude            # Enable for Claude Code only
    cn off                  # Disable all
    cn off all              # Same as cn off
    cn status               # Show status for all tools
    cn status all           # Same as cn status
    cn test                 # Send test notification
    cn update check         # Check whether an update is needed and show the update command
    cn alerts               # Show alert type config
    cn alerts add permission_prompt  # Also notify on permission requests
    cn alerts add ask_user
    cn alerts add SubagentStop       # Also notify when Claude subagents finish
    cn alerts reset         # Back to idle_prompt only (less noisy)
    cn channels add slack https://hooks.slack.com/services/...
    cn channels add discord https://discord.com/api/webhooks/...
    cn usage on
    cn usage setup --watch
    cn usage check
    cn sound on             # Enable notification sounds
    cn sound set ~/ding.wav # Use custom sound
EOF

    if is_macos_help_context; then
        cat << EOF
    cn click-through        # Show current click-through mappings
    cn click-through add    # Add an app mapping
    cn click-through remove # Interactively remove mappings
EOF
    fi

    cat << EOF
    cnp on                  # Enable for current project

${BOLD}MORE INFO:${RESET}
    ${DIM}https://github.com/mylee04/code-notify${RESET}

EOF
}

show_channels_help() {
    cat << EOF
${BOLD}Channel Commands${RESET}

${BOLD}USAGE:${RESET}
    cn channels status
    cn channels add slack <webhook-url> [--name <name>]
    cn channels add discord <webhook-url> [--name <name>]
    cn channels remove <name>
    cn channels test <name|all>
    cn channels on|off
    cn channels reset

Webhook URLs are stored locally and redacted in status output.
EOF
}

show_usage_help() {
    cat << EOF
${BOLD}Usage Alert Commands${RESET}

${BOLD}USAGE:${RESET}
    cn usage status
    cn usage setup [codex|claude|all] [--watch] [--interval seconds]
    cn usage on [codex|claude|all]
    cn usage off [codex|claude|all]
    cn usage check [codex|claude|all]
    cn usage watch [codex|claude|all] [--interval seconds]
    cn usage watch start [codex|claude|all] [--interval seconds]
    cn usage watch stop|restart|status
    cn usage thresholds set 20,10
    cn usage thresholds reset
    cn usage reset-alerts on|off
    cn usage reset-alerts voice on|off
    cn usage reset-alerts sound on|off|set <path>|default
    cn usage reset-state

Usage alerts are opt-in. Use 'cn usage setup --watch' for the fastest setup. Low-usage warnings use normal Code-Notify delivery. Reset alerts have separate voice/sound controls so token reset can feel distinct from task-complete notifications.
EOF
}
