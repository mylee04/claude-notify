---
name: shell-scripting
description: Shell scripting best practices for cross-platform CLI tools
---

# Shell Scripting Standards

## When to Use
- Writing new shell scripts
- Refactoring existing scripts
- Adding new functions

## Script Structure

### 1. File Header
```bash
#!/bin/bash

# Script description
# https://github.com/mylee04/code-notify

set -e  # Exit on error
```

### 2. Constants (UPPER_CASE)
```bash
VERSION="1.2.0"
CONFIG_DIR="$HOME/.claude"
DEFAULT_SOUND="Glass"
```

### 3. Functions (snake_case)
```bash
# Description of function
# Arguments: $1 = name, $2 = optional value
function_name() {
    local name="$1"
    local value="${2:-default}"

    # Function body
}
```

### 4. Main Logic
```bash
# Main execution
main() {
    validate_args "$@"
    do_work
    cleanup
}

main "$@"
```

## Best Practices

### Variable Handling
```bash
# Good - quoted variables
echo "$message"
path="$HOME/.config"

# Bad - unquoted
echo $message
path=$HOME/.config
```

### Conditionals
```bash
# Good - double brackets
if [[ -n "$var" ]]; then
    echo "not empty"
fi

# Bad - single brackets
if [ -n "$var" ]; then
    echo "not empty"
fi
```

### Command Existence Check
```bash
# Good
if command -v terminal-notifier &> /dev/null; then
    terminal-notifier -message "Hello"
fi

# Bad
if which terminal-notifier; then
    terminal-notifier -message "Hello"
fi
```

### Error Handling
```bash
# Good - explicit error handling
if ! some_command; then
    echo "Error: command failed" >&2
    exit 1
fi

# Good - trap for cleanup
cleanup() {
    rm -f "$temp_file"
}
trap cleanup EXIT
```

### Local Variables in Functions
```bash
# Good
my_function() {
    local input="$1"
    local result
    result=$(process "$input")
    echo "$result"
}

# Bad - pollutes global scope
my_function() {
    input="$1"
    result=$(process "$input")
    echo "$result"
}
```

## Common Patterns

### OS Detection
```bash
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos" ;;
        Linux*)     echo "linux" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *)          echo "unknown" ;;
    esac
}
```

### Safe File Operations
```bash
# Create directory if not exists
mkdir -p "$dir"

# Safe file reading
if [[ -f "$config_file" ]]; then
    config=$(cat "$config_file")
fi

# Atomic write
echo "$content" > "$file.tmp" && mv "$file.tmp" "$file"
```

### JSON Handling (without jq)
```bash
# Simple grep-based check
if grep -q '"enabled":\s*true' "$file"; then
    echo "enabled"
fi

# With jq (if available)
if command -v jq &> /dev/null; then
    value=$(jq -r '.key' "$file")
fi
```

## Testing

### Test Function Output
```bash
test_detect_os() {
    result=$(detect_os)
    if [[ "$result" != "macos" ]] && [[ "$result" != "linux" ]]; then
        echo "FAIL: unexpected OS: $result"
        return 1
    fi
    echo "PASS"
}
```

### Test Exit Codes
```bash
test_error_handling() {
    if invalid_command 2>/dev/null; then
        echo "FAIL: should have failed"
        return 1
    fi
    echo "PASS"
}
```

## Success Metrics
- shellcheck passes with no warnings
- All functions use local variables
- All variables are quoted
- Commands existence checked before use
- Error handling for all failure points
