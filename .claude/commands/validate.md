---
description: Validate shell script syntax and best practices
---

# Validate Scripts

## What This Command Does
1. Runs shellcheck on all .sh files
2. Validates PowerShell syntax on .ps1 files
3. Checks for common issues
4. Reports findings

## When to Use
- Before committing changes
- After refactoring code
- During code review

## Process

### 1. Run Shellcheck
```bash
shellcheck bin/claude-notify lib/claude-notify/**/*.sh
```

### 2. Check PowerShell Syntax
```powershell
# In PowerShell
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    "install-windows.ps1",
    [ref]$null,
    [ref]$errors
)
if ($errors) { $errors | ForEach-Object { Write-Error $_ } }
```

### 3. Run Tests
```bash
make test
```

## Common Issues to Check

### Shell Scripts
- Unquoted variables
- Missing `local` in functions
- Using `[ ]` instead of `[[ ]]`
- Missing error handling
- Undefined variables

### PowerShell
- Missing error handling
- Unhandled exceptions
- Incorrect parameter types
- Missing -ErrorAction

## Fix Common Issues

### Unquoted Variables
```bash
# Before
echo $message

# After
echo "$message"
```

### Missing Local
```bash
# Before
my_func() {
    result="value"
}

# After
my_func() {
    local result="value"
}
```
