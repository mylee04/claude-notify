#!/bin/bash

# Color definitions for terminal output

# Check if terminal supports colors
if [[ -t 1 ]] && [[ "$(tput colors)" -ge 8 ]]; then
    # Regular Colors
    BLACK=$'\033[0;30m'
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    PURPLE=$'\033[0;35m'
    CYAN=$'\033[0;36m'
    WHITE=$'\033[0;37m'
    
    # Bold
    BOLD=$'\033[1m'
    
    # Dim
    DIM=$'\033[2m'
    
    # Reset
    RESET=$'\033[0m'
    
    # Emojis for status
    CHECK_MARK="✅"
    CROSS_MARK="❌"
    WARNING="⚠️"
    INFO="ℹ️"
    BELL="🔔"
    MUTE="🔕"
    GLOBE="🌐"
    FOLDER="📂"
    ROCKET="🚀"
    SPEAKER="🔊"
else
    # No colors
    BLACK=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    PURPLE=""
    CYAN=""
    WHITE=""
    BOLD=""
    DIM=""
    RESET=""
    
    # ASCII alternatives
    CHECK_MARK="[OK]"
    CROSS_MARK="[X]"
    WARNING="[!]"
    INFO="[i]"
    BELL="[*]"
    MUTE="[-]"
    GLOBE="[G]"
    FOLDER="[D]"
    ROCKET="[>]"
    SPEAKER="[S]"
fi

# Helper functions for colored output
success() {
    echo -e "${GREEN}${CHECK_MARK} $1${RESET}"
}

error() {
    echo -e "${RED}${CROSS_MARK} $1${RESET}" >&2
}

warning() {
    echo -e "${YELLOW}${WARNING} $1${RESET}"
}

info() {
    echo -e "${BLUE}${INFO} $1${RESET}"
}

status_enabled() {
    echo -e "${GREEN}${BELL} $1${RESET}"
}

status_disabled() {
    echo -e "${DIM}${MUTE} $1${RESET}"
}

header() {
    echo -e "${BOLD}$1${RESET}"
}

dim() {
    echo -e "${DIM}$1${RESET}"
}