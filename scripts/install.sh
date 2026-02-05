#!/bin/bash

# Code-Notify Installation Script
# Desktop notifications for Claude Code, Codex, and Gemini CLI
# For users who want to install without Homebrew

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

echo "🔔 Code-Notify Installer"
echo "========================="
echo ""

# Detect OS
OS=$(uname -s)
case "$OS" in
    Darwin*)
        echo "Detected: macOS"
        ;;
    Linux*)
        echo "Detected: Linux"
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Detected: Windows (Git Bash/MSYS)"
        echo ""
        echo -e "${YELLOW}Note: For native Windows support, please use the PowerShell installer:${RESET}"
        echo "  powershell -ExecutionPolicy Bypass -File install-windows.ps1"
        echo ""
        echo "Or download and run directly:"
        echo "  irm https://raw.githubusercontent.com/mylee04/code-notify/main/scripts/install-windows.ps1 | iex"
        echo ""
        exit 1
        ;;
    *)
        echo -e "${RED}Error: Unsupported operating system${RESET}"
        exit 1
        ;;
esac

# Check for platform-specific notification tools
echo "Checking dependencies..."

# Check for jq (required for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo -e "${YELLOW}Warning: jq not found (required for status detection)${RESET}"
    echo "Install it with:"
    case "$OS" in
        Darwin*)
            echo "  brew install jq"
            ;;
        Linux*)
            echo "  Ubuntu/Debian: sudo apt-get install jq"
            echo "  Fedora: sudo dnf install jq"
            echo "  Arch: sudo pacman -S jq"
            ;;
    esac
    echo ""
fi

case "$OS" in
    Darwin*)
        if ! command -v terminal-notifier &> /dev/null; then
            echo -e "${YELLOW}Warning: terminal-notifier not found${RESET}"
            echo "For the best experience on macOS, install it with:"
            echo "  brew install terminal-notifier"
        fi
        ;;
    Linux*)
        if ! command -v notify-send &> /dev/null; then
            echo -e "${YELLOW}Warning: notify-send not found${RESET}"
            echo "Install it with your package manager:"
            echo "  Ubuntu/Debian: sudo apt-get install libnotify-bin"
            echo "  Fedora: sudo dnf install libnotify"
            echo "  Arch: sudo pacman -S libnotify"
        fi
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo "Windows notifications will use PowerShell"
        if ! command -v powershell &> /dev/null; then
            echo -e "${YELLOW}Warning: PowerShell not found${RESET}"
            echo "For better notifications, install BurntToast:"
            echo "  Install-Module -Name BurntToast"
        fi
        ;;
esac

# Install to user's home directory
INSTALL_DIR="$HOME/.code-notify"
echo "Installing to: $INSTALL_DIR"

# Create directories
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/lib/code-notify/commands"
mkdir -p "$INSTALL_DIR/lib/code-notify/core"
mkdir -p "$INSTALL_DIR/lib/code-notify/utils"
mkdir -p "$HOME/.claude/notifications"

# GitHub raw URL base
GITHUB_RAW="https://raw.githubusercontent.com/mylee04/code-notify/main"

# Check if running locally (repo exists) or via curl (need to download)
if [[ -d "bin" ]] && [[ -d "lib" ]]; then
    echo "Installing from local files..."
    cp -r bin/* "$INSTALL_DIR/bin/"
    cp -r lib/* "$INSTALL_DIR/lib/"
else
    echo "Downloading files from GitHub..."

    # Download main script
    curl -fsSL "$GITHUB_RAW/bin/code-notify" -o "$INSTALL_DIR/bin/code-notify"

    # Download lib files
    curl -fsSL "$GITHUB_RAW/lib/code-notify/commands/global.sh" -o "$INSTALL_DIR/lib/code-notify/commands/global.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/commands/project.sh" -o "$INSTALL_DIR/lib/code-notify/commands/project.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/core/config.sh" -o "$INSTALL_DIR/lib/code-notify/core/config.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/core/notifier.sh" -o "$INSTALL_DIR/lib/code-notify/core/notifier.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/utils/colors.sh" -o "$INSTALL_DIR/lib/code-notify/utils/colors.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/utils/detect.sh" -o "$INSTALL_DIR/lib/code-notify/utils/detect.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/utils/help.sh" -o "$INSTALL_DIR/lib/code-notify/utils/help.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/utils/voice.sh" -o "$INSTALL_DIR/lib/code-notify/utils/voice.sh"
    curl -fsSL "$GITHUB_RAW/lib/code-notify/utils/sound.sh" -o "$INSTALL_DIR/lib/code-notify/utils/sound.sh"
fi

# Update paths in the main script
sed -i.bak "s|\$(dirname \"\$SCRIPT_DIR\")/lib/code-notify|$INSTALL_DIR/lib/code-notify|g" "$INSTALL_DIR/bin/code-notify"
rm "$INSTALL_DIR/bin/code-notify.bak"

# Make executable
chmod +x "$INSTALL_DIR/bin/code-notify"
chmod +x "$INSTALL_DIR/lib/code-notify/core/notifier.sh"

# Create symlinks in a directory that's likely in PATH
if [[ -d "$HOME/.local/bin" ]]; then
    BIN_DIR="$HOME/.local/bin"
elif [[ -d "$HOME/bin" ]]; then
    BIN_DIR="$HOME/bin"
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi

# Create symlinks
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/code-notify"
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/cn"
ln -sf "$INSTALL_DIR/bin/code-notify" "$BIN_DIR/cnp"

echo -e "${GREEN}✅ Installation complete!${RESET}"
echo ""

# Check if bin directory is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "${YELLOW}⚠️  Add this to your shell configuration:${RESET}"
    echo ""
    echo "  export PATH=\"\$PATH:$BIN_DIR\""
    echo ""
    echo "Add it to ~/.zshrc (zsh) or ~/.bashrc (bash)"
fi

echo "Run these commands to get started:"
echo "  code-notify setup    # Initial setup"
echo "  cn on                  # Enable notifications"
echo ""
echo "For more info: https://github.com/mylee04/code-notify"