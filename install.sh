#!/bin/bash

# Claude-Notify Installation Script
# For users who want to install without Homebrew

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

echo "🔔 Claude-Notify Installer"
echo "========================="
echo ""

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "${RED}Error: Claude-Notify currently only supports macOS${RESET}"
    exit 1
fi

# Check for terminal-notifier
echo "Checking dependencies..."
if ! command -v terminal-notifier &> /dev/null; then
    echo -e "${YELLOW}Warning: terminal-notifier not found${RESET}"
    echo "For the best experience, install it with:"
    echo "  brew install terminal-notifier"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Install to user's home directory
INSTALL_DIR="$HOME/.claude-notify"
echo "Installing to: $INSTALL_DIR"

# Create directories
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$HOME/.claude/notifications"

# Copy files
cp -r bin/* "$INSTALL_DIR/bin/"
cp -r lib/* "$INSTALL_DIR/lib/"

# Update paths in the main script
sed -i.bak "s|\$(dirname \"\$SCRIPT_DIR\")/lib/claude-notify|$INSTALL_DIR/lib/claude-notify|g" "$INSTALL_DIR/bin/claude-notify"
rm "$INSTALL_DIR/bin/claude-notify.bak"

# Make executable
chmod +x "$INSTALL_DIR/bin/claude-notify"

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
ln -sf "$INSTALL_DIR/bin/claude-notify" "$BIN_DIR/claude-notify"
ln -sf "$INSTALL_DIR/bin/claude-notify" "$BIN_DIR/cn"
ln -sf "$INSTALL_DIR/bin/claude-notify" "$BIN_DIR/cnp"

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
echo "  claude-notify setup    # Initial setup"
echo "  cn on                  # Enable notifications"
echo ""
echo "For more info: https://github.com/mylee04/claude-notify"