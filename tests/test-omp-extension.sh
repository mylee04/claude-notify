#!/bin/bash

# Verifies Oh My Pi (omp) support:
#   - detection from PATH / config dir
#   - `enable` writes a valid managed agent_end extension module
#   - the generated extension's runtime contract (notifier.sh stop omp <project>)
#   - `disable` removes only the managed file, preserving user-owned ones

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib/code-notify"
NOTIFIER="$LIB_DIR/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin" "$log_dir"

# Fake desktop notifier so the runtime contract can be asserted headlessly.
case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for omp extension test"
        exit 0
        ;;
esac

# Fake omp binary so detection reports omp as installed.
cat > "$fake_bin/omp" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$fake_bin"/*

# Source the library under the temp HOME so omp paths resolve into the sandbox.
source "$LIB_DIR/utils/detect.sh"
source "$LIB_DIR/core/config.sh"

ext_file="$HOME/.omp/agent/extensions/code-notify.js"

# 1. Detection picks up omp when the command is present.
PATH="$fake_bin:$PATH" is_tool_installed "omp" || fail "omp not detected when the 'omp' binary is present"
case " $(PATH="$fake_bin:$PATH" get_installed_tools) " in
    *" omp "*) ;;
    *) fail "get_installed_tools did not include omp" ;;
esac
pass "omp detected from PATH"

# 2. Enable writes a valid managed extension module.
enable_omp_hooks || fail "enable_omp_hooks failed"
[[ -f "$ext_file" ]] || fail "extension file not created at $ext_file"
grep -q "$OMP_EXTENSION_MARKER" "$ext_file" || fail "managed marker missing from extension"
grep -q 'pi.on("agent_end"' "$ext_file" || fail "extension does not hook agent_end"
grep -q '"stop", "omp"' "$ext_file" || fail "extension does not call notifier with 'stop omp'"
grep -q "$NOTIFIER" "$ext_file" || fail "extension does not embed the resolved notifier path"
is_omp_enabled || fail "is_omp_enabled returned false after enable"
if command -v node >/dev/null 2>&1; then
    node --check "$ext_file" || fail "generated extension is not valid JavaScript"
fi
pass "enable writes a valid managed agent_end extension"

# 3. Runtime contract: notifier.sh stop omp <project> renders a completion notification.
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
    bash "$NOTIFIER" stop omp demo </dev/null
grep -q "Task Complete - demo" "$notification_log" || fail "stop omp did not produce a completion notification for the project"
pass "notifier renders 'stop omp <project>' as a completion notification"

# 4. Disable removes the managed file.
disable_omp_hooks || fail "disable_omp_hooks failed"
[[ ! -f "$ext_file" ]] || fail "managed extension not removed on disable"
is_omp_enabled && fail "is_omp_enabled returned true after disable"
pass "disable removes the managed extension"

# 5. Disable preserves a user-owned file at the same path.
mkdir -p "$(dirname "$ext_file")"
printf '%s\n' "// my own omp extension" > "$ext_file"
disable_omp_hooks || fail "disable_omp_hooks failed on a user-owned file"
[[ -f "$ext_file" ]] || fail "disable clobbered a non-managed extension file"
pass "disable preserves a non-managed extension file"

echo "All omp extension tests passed"
