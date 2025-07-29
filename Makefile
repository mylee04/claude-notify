# Makefile for Claude-Notify

PREFIX ?= /usr/local
BINDIR = $(PREFIX)/bin
LIBDIR = $(PREFIX)/lib
SHAREDIR = $(PREFIX)/share

# Version
VERSION = 1.0.0

.PHONY: all install uninstall test clean

all:
	@echo "Claude-Notify $(VERSION)"
	@echo ""
	@echo "Available targets:"
	@echo "  make install    - Install claude-notify"
	@echo "  make uninstall  - Remove claude-notify"
	@echo "  make test       - Run tests"
	@echo "  make clean      - Clean build artifacts"

install:
	@echo "Installing Claude-Notify..."
	
	# Create directories
	@mkdir -p $(BINDIR)
	@mkdir -p $(LIBDIR)/claude-notify
	
	# Install main executable
	@cp bin/claude-notify $(BINDIR)/
	@chmod +x $(BINDIR)/claude-notify
	
	# Create symlinks
	@ln -sf claude-notify $(BINDIR)/cn
	@ln -sf claude-notify $(BINDIR)/cnp
	
	# Install library files
	@cp -r lib/claude-notify/* $(LIBDIR)/claude-notify/
	
	# Update paths in the main script
	@sed -i.bak 's|$$(dirname "$$SCRIPT_DIR")/lib/claude-notify|$(LIBDIR)/claude-notify|g' $(BINDIR)/claude-notify
	@rm $(BINDIR)/claude-notify.bak
	
	@echo "✅ Claude-Notify installed successfully!"
	@echo ""
	@echo "Run 'claude-notify setup' to get started"

uninstall:
	@echo "Removing Claude-Notify..."
	
	# Remove executables and symlinks
	@rm -f $(BINDIR)/claude-notify
	@rm -f $(BINDIR)/cn
	@rm -f $(BINDIR)/cnp
	
	# Remove library files
	@rm -rf $(LIBDIR)/claude-notify
	
	@echo "✅ Claude-Notify uninstalled"

test:
	@echo "Running tests..."
	@bash test/run_tests.sh

clean:
	@echo "Cleaning..."
	@find . -name "*.bak" -delete
	@find . -name ".DS_Store" -delete