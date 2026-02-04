# Claude Code Hooks Guide

## Available Hooks

Claude Code supports the following hooks that trigger at different points during execution:

### 1. **Notification**

- **When it triggers**: When Claude needs user input or attention
- **Use case**: Get notified when Claude is waiting for you
- **Example**: Play a sound or show a notification

### 2. **Stop**

- **When it triggers**: When Claude completes a task or stops processing
- **Use case**: Know when your requested task is done
- **Matcher tip**: Use `^(?!.*Bash).*$` to exclude Bash commands

### 3. **PreToolUse**

- **When it triggers**: Before Claude uses any tool (Bash, Write, Edit, etc.)
- **Use case**: Log actions, validate operations, or prepare environment
- **Matcher examples**:
  - `"Bash"` - Before running shell commands
  - `"Write|Edit"` - Before file modifications
  - `"Read"` - Before reading files

### 4. **PostToolUse**

- **When it triggers**: After Claude completes using a tool
- **Use case**: Clean up, validate results, or log completions

### 5. **UserPromptSubmit**

- **When it triggers**: When you submit a prompt to Claude
- **Use case**: Log user requests, track usage

### 6. **SessionStart**

- **When it triggers**: When a Claude Code session begins
- **Use case**: Set up environment, start logging

### 7. **SessionEnd**

- **When it triggers**: When a Claude Code session ends
- **Use case**: Clean up, save logs, send summary

### 8. **SubagentStop**

- **When it triggers**: When a subagent completes its task
- **Use case**: Track complex multi-step operations

### 9. **PreCompact**

- **When it triggers**: Before Claude compacts conversation history
- **Use case**: Save conversation state, backup important context

## Matcher Patterns

The `matcher` field supports:

- **Empty string `""`**: Matches everything
- **Tool names**: `"Bash"`, `"Write"`, `"Edit"`, `"Read"`, etc.
- **Pipe for OR**: `"Write|Edit"` matches either Write or Edit
- **Regex patterns**: `^(?!.*Bash).*$` matches everything except Bash

## Common Configurations

### Minimal (just notifications when Claude needs input):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "your-notification-command"
          }
        ]
      }
    ]
  }
}
```

### Balanced (notifications + task completion):

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "notification-command"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "^(?!.*Bash).*$",
        "hooks": [
          {
            "type": "command",
            "command": "completion-command"
          }
        ]
      }
    ]
  }
}
```

### Developer Mode (track everything):

Add PreToolUse and PostToolUse hooks to monitor all operations.

## Tips

1. **Start simple**: Begin with just Notification hook
2. **Test carefully**: Hooks run frequently, avoid slow commands
3. **Use matchers**: Filter hooks to specific tools to reduce noise
4. **Timeout**: Add `"timeout": 5` to prevent hanging hooks
5. **Debug**: Use `echo` commands first to understand when hooks trigger
