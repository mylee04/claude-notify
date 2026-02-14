# Bug Fix: Config Preservation

## Summary

Critical bug fix: `cn off` was destroying all user settings in `settings.json` instead of only removing notification hooks.

## The Problem

### Before Fix (Bug Behavior)

When users run `cn off` to disable notifications, the original code **overwrites the entire settings file**:

```bash
# User's original ~/.claude/settings.json
{
  "model": "sonnet",
  "permissions": {
    "allow": ["Bash(npm run*)", "Bash(pytest*)"]
  },
  "env": {
    "MY_API_KEY": "secret-key"
  }
}

# After running `cn off` (BUGGY!)
{
  "model": "opus"   # ← ALL OTHER SETTINGS DESTROYED!
}
```

### Root Causes

Three functions had this bug:

| Function | File | Bug |
|----------|------|-----|
| `enable_hooks_in_settings()` | config.sh:233 | Hardcoded `"model": "opus"`, overwriting user's preference |
| `disable_hooks_in_settings()` | config.sh:298 | Rewrote entire file to `{"model": "opus"}` or `{}` |
| `disable_gemini_hooks()` | config.sh:588 | Rewrote entire file to `{"tools": {"enableHooks": false}}` |

### Impact

Users lost:
- Their preferred model setting (e.g., `sonnet` → `opus`)
- All permission rules
- All environment variables
- Any other custom settings

## The Fix

### After Fix (Correct Behavior)

Now `cn off` only removes the `hooks` section while preserving all other settings:

```bash
# User's original ~/.claude/settings.json
{
  "model": "sonnet",
  "permissions": {
    "allow": ["Bash(npm run*)", "Bash(pytest*)"]
  },
  "env": {
    "MY_API_KEY": "secret-key"
  }
}

# After running `cn on` (adds hooks, preserves settings)
{
  "model": "sonnet",                    # ← PRESERVED
  "permissions": {                      # ← PRESERVED
    "allow": ["Bash(npm run*)", "Bash(pytest*)"]
  },
  "env": {                              # ← PRESERVED
    "MY_API_KEY": "secret-key"
  },
  "hooks": {                            # ← ADDED
    "Notification": [...],
    "Stop": [...]
  }
}

# After running `cn off` (removes hooks, preserves settings)
{
  "model": "sonnet",                    # ← STILL PRESERVED
  "permissions": {                      # ← STILL PRESERVED
    "allow": ["Bash(npm run*)", "Bash(pytest*)"]
  },
  "env": {                              # ← STILL PRESERVED
    "MY_API_KEY": "secret-key"
  }
}
```

## Technical Changes

### 1. `enable_hooks_in_settings()`

**Before:**
```bash
# Hardcoded "opus" model
echo '{"model": "opus", "hooks": {...}}' > "$GLOBAL_SETTINGS_FILE"
```

**After:**
```bash
# Use jq to merge hooks into existing settings
jq '.hooks = {...}' existing_settings.json > "$GLOBAL_SETTINGS_FILE"
```

### 2. `disable_hooks_in_settings()`

**Before:**
```bash
# Overwrote entire file
echo '{"model": "opus"}' > "$GLOBAL_SETTINGS_FILE"
```

**After:**
```bash
# Only remove hooks key
jq 'del(.hooks)' settings.json > "$GLOBAL_SETTINGS_FILE"
```

### 3. `disable_gemini_hooks()`

**Before:**
```bash
# Overwrote entire file
echo '{"tools": {"enableHooks": false}}' > "$GEMINI_SETTINGS_FILE"
```

**After:**
```bash
# Only remove code-notify hooks
jq 'del(.hooks.Notification) | del(.hooks.AfterAgent)' settings.json
```

### Fallback Support

For systems without `jq`, the fix uses `python3` as a fallback (available on most systems):

```bash
if has_jq; then
    jq 'del(.hooks)' "$file"
elif command -v python3 &> /dev/null; then
    python3 -c "import json; ..."
else
    # Warn user, don't modify file (safer)
    echo "Warning: jq or python3 required"
fi
```

## Testing

Added `tests/test-config-preservation.sh` that verifies:

| Test | Description | Result |
|------|-------------|--------|
| Test 1 | `enable_hooks` preserves existing model | ✅ PASS |
| Test 2 | `disable_hooks` preserves other settings | ✅ PASS |
| Test 3 | Works with no existing config | ✅ PASS |

Run tests:
```bash
./tests/test-config-preservation.sh
```

## Files Changed

| File | Changes |
|------|---------|
| `lib/code-notify/core/config.sh` | Fixed 3 functions to preserve user settings |
| `tests/test-config-preservation.sh` | New test file |

## Migration Notes

- No user action required
- Existing configurations will be preserved correctly going forward
- If you previously lost settings, you may need to reconfigure manually

## Recommendation

We strongly recommend installing `jq` for the best experience:
```bash
# macOS
brew install jq

# Linux
sudo apt install jq  # Debian/Ubuntu
sudo dnf install jq  # Fedora
```
