# Security Rules

## Mandatory Checks

### Credentials

- [ ] No hardcoded API keys, tokens, or passwords
- [ ] No credentials in commit history
- [ ] Use environment variables for sensitive data
- [ ] Never log sensitive data

### Input Validation

- [ ] Sanitize user input before use
- [ ] No `eval` on untrusted input
- [ ] Escape special characters in user input
- [ ] Validate file paths

### Command Execution

- [ ] No command injection vulnerabilities
- [ ] Quote all variables in commands
- [ ] Use arrays for command arguments
- [ ] Avoid shell expansion on user input

### File Operations

- [ ] Use absolute paths where possible
- [ ] Check file existence before operations
- [ ] Set appropriate file permissions
- [ ] Don't follow symlinks blindly

## Patterns

### Safe Command Execution

```bash
# Good - quoted and validated
run_command() {
    local cmd="$1"
    shift
    local args=("$@")

    if [[ ! "$cmd" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Invalid command" >&2
        return 1
    fi

    "$cmd" "${args[@]}"
}

# Bad - injection risk
run_command() {
    eval "$1 $2"
}
```

### Safe File Handling

```bash
# Good
config_file="$HOME/.claude/settings.json"
if [[ -f "$config_file" ]] && [[ -r "$config_file" ]]; then
    config=$(cat "$config_file")
fi

# Bad
config=$(cat $config_file)
```

### Environment Variables

```bash
# Good - use env vars
API_KEY="${CLAUDE_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: CLAUDE_API_KEY not set" >&2
    exit 1
fi

# Bad - hardcoded
API_KEY="sk-1234567890"
```

## Never Commit

- `.env` files
- `*.pem`, `*.key` files
- `credentials.json`
- `secrets.json`
- API keys or tokens

## Consequences

- Command injection can execute arbitrary code
- Credential exposure leads to account compromise
- Unsanitized input causes unexpected behavior
