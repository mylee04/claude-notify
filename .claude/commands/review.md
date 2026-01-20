---
description: Code review for shell scripts
---

# Code Review

## What This Command Does
1. Analyzes code for security issues
2. Checks shell scripting best practices
3. Verifies cross-platform compatibility
4. Provides improvement suggestions

## When to Use
- Before merging PRs
- After significant changes
- When adding new features

## Process

### 1. Invoke Code Reviewer Agent
The code-reviewer agent will analyze:
- Security vulnerabilities
- Shell best practices
- Cross-platform compatibility
- Code quality

### 2. Review Areas

#### Security Checklist
- [ ] No hardcoded credentials
- [ ] Input sanitization
- [ ] No command injection risks
- [ ] Safe file handling

#### Best Practices
- [ ] Variables quoted
- [ ] Functions use local
- [ ] Error handling present
- [ ] Commands existence checked

#### Cross-Platform
- [ ] Works on macOS
- [ ] Works on Linux
- [ ] PowerShell equivalent correct
- [ ] WSL compatible

### 3. Output
Review generates a report with:
- Issues found (by severity)
- Specific line numbers
- Suggested fixes
- Overall verdict (APPROVE/NEEDS CHANGES/BLOCK)

## Usage

```
Review the changes in lib/claude-notify/core/notifier.sh
```

The code-reviewer agent will be invoked automatically.
