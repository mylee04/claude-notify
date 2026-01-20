# Shell Script Standards

## Mandatory Checks

### Variable Handling
- [ ] All variables are quoted: `"$var"` not `$var`
- [ ] Function variables use `local`
- [ ] Constants are UPPER_CASE
- [ ] Local variables are lower_case

### Conditionals
- [ ] Use `[[ ]]` instead of `[ ]`
- [ ] Use `command -v` to check for tools (not `which`)
- [ ] Handle empty variables: `${var:-default}`

### Functions
- [ ] All functions have descriptive names
- [ ] Use `local` for all function variables
- [ ] Return explicit exit codes
- [ ] Document complex functions with comments

### Error Handling
- [ ] Use `set -e` at script start
- [ ] Check command exit codes
- [ ] Provide helpful error messages to stderr
- [ ] Clean up resources on exit (trap)

## Patterns

### Good
```bash
#!/bin/bash
set -e

readonly CONFIG_DIR="$HOME/.claude"

send_notification() {
    local title="$1"
    local message="${2:-No message}"

    if [[ -z "$title" ]]; then
        echo "Error: title required" >&2
        return 1
    fi

    if command -v terminal-notifier &> /dev/null; then
        terminal-notifier -title "$title" -message "$message"
    fi
}
```

### Bad
```bash
#!/bin/bash

CONFIG_DIR=$HOME/.claude

send_notification() {
    title=$1
    message=$2

    if [ -z $title ]; then
        echo Error: title required
        return
    fi

    if which terminal-notifier; then
        terminal-notifier -title $title -message $message
    fi
}
```

## Consequences
- Unquoted variables cause word splitting bugs
- Missing `local` pollutes global scope
- `[ ]` has different behavior than `[[ ]]`
- Missing error handling causes silent failures
