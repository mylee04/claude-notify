class ClaudeNotify < Formula
  desc "Native OS notifications for Claude Code"
  homepage "https://github.com/mylee04/claude-notify"
  url "https://github.com/mylee04/claude-notify/archive/v1.0.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"  # Will be updated when creating release
  license "MIT"
  
  depends_on "terminal-notifier" => :recommended
  
  def install
    # Install the main executable
    bin.install "bin/claude-notify"
    
    # Create symlinks for aliases
    bin.install_symlink "claude-notify" => "cn"
    bin.install_symlink "claude-notify" => "cnp"
    
    # Install library files
    lib.install "lib/claude-notify"
    
    # Install shared resources
    share.install "share/claude-notify" if Dir.exist?("share/claude-notify")
    
    # Install completions
    bash_completion.install "completions/bash/claude-notify" if File.exist?("completions/bash/claude-notify")
    zsh_completion.install "completions/zsh/_claude-notify" if File.exist?("completions/zsh/_claude-notify")
    fish_completion.install "completions/fish/claude-notify.fish" if File.exist?("completions/fish/claude-notify.fish")
    
    # Update paths in the main script to point to Homebrew locations
    inreplace bin/"claude-notify" do |s|
      s.gsub! '$(dirname "$SCRIPT_DIR")/lib/claude-notify', "#{lib}/claude-notify"
    end
  end
  
  def post_install
    ohai "Claude-Notify installed successfully!"
    ohai ""
    ohai "Quick start:"
    ohai "  claude-notify setup    # Run initial setup"
    ohai "  cn on                  # Enable notifications"
    ohai ""
    ohai "Available commands:"
    ohai "  claude-notify (full commands)"
    ohai "  cn (global shortcuts)"
    ohai "  cnp (project shortcuts)"
    ohai ""
    ohai "For more info: https://github.com/mylee04/claude-notify"
  end
  
  test do
    system "#{bin}/claude-notify", "version"
    system "#{bin}/cn", "version"
    system "#{bin}/cnp", "status"
  end
end