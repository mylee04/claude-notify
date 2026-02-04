---
description: Create a well-formatted commit
---

# Commit Changes

## What This Command Does

1. Checks for uncommitted changes
2. Runs tests to verify code works
3. Generates appropriate commit message
4. Creates the commit

## When to Use

- After completing a feature or fix
- When changes are ready to be saved

## Process

### 1. Pre-Commit Checks

```bash
# Run tests
make test

# Check for lint issues
shellcheck bin/code-notify lib/code-notify/**/*.sh
```

### 2. Review Changes

```bash
git status
git diff --stat
```

### 3. Commit Message Format

```
type: brief description

- Detail 1
- Detail 2
```

#### Types

| Type     | Use For          |
| -------- | ---------------- |
| feat     | New feature      |
| fix      | Bug fix          |
| docs     | Documentation    |
| refactor | Code refactoring |
| test     | Adding tests     |
| chore    | Maintenance      |

### 4. Example Messages

```
feat: add WSL support for notifications

- Detect WSL environment via /proc/version
- Use wsl-notify-send.exe for Windows notifications
- Add setup wizard option to install wsl-notify-send
```

```
fix: handle non-git directories on Windows

- Wrap git commands in try-catch
- Check $LASTEXITCODE after git commands
- Fall back to folder name when not in git repo
```

## Rules

- No Co-Authored-By lines
- No .env files
- Run tests before committing
- Keep messages concise but descriptive
