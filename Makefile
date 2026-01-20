# Makefile for Claude-Notify

.PHONY: test install clean lint help

# Run the test suite
test:
	@echo "Running tests..."
	@./test/run_tests.sh

# Install locally for development
install:
	@echo "Installing claude-notify locally..."
	@chmod +x bin/claude-notify
	@mkdir -p $(HOME)/.local/bin
	@ln -sf $(PWD)/bin/claude-notify $(HOME)/.local/bin/claude-notify
	@ln -sf $(PWD)/bin/claude-notify $(HOME)/.local/bin/cn
	@ln -sf $(PWD)/bin/claude-notify $(HOME)/.local/bin/cnp
	@echo "Installed. Make sure $(HOME)/.local/bin is in your PATH"

# Uninstall local installation
uninstall:
	@echo "Removing local installation..."
	@rm -f $(HOME)/.local/bin/claude-notify
	@rm -f $(HOME)/.local/bin/cn
	@rm -f $(HOME)/.local/bin/cnp
	@echo "Uninstalled."

# Clean up backup files and caches
clean:
	@echo "Cleaning up..."
	@rm -rf $(HOME)/.config/claude-notify/backups/*
	@echo "Cleaned."

# Basic shell script linting (requires shellcheck)
lint:
	@echo "Linting shell scripts..."
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/claude-notify lib/claude-notify/**/*.sh; \
	else \
		echo "shellcheck not installed. Install with: brew install shellcheck"; \
		exit 1; \
	fi

# Show help
help:
	@echo "Claude-Notify Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  test      - Run the test suite"
	@echo "  install   - Install locally for development"
	@echo "  uninstall - Remove local installation"
	@echo "  clean     - Clean up backup files"
	@echo "  lint      - Run shellcheck on scripts"
	@echo "  help      - Show this help message"
