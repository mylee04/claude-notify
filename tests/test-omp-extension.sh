#!/bin/bash

# Verifies Oh My Pi (omp) support:
#   - detection from PATH / config dir
#   - `enable` writes a valid managed agent_end extension module
#   - the generated extension's runtime contract (notifier.sh stop omp <project>)
#   - `disable` removes only the managed file, preserving user-owned ones
#   - global kill switch suppresses omp stop notifications
#   - `enable` refuses to overwrite a non-managed extension file
#   - `detect_omp` does not stay true after enable+disable with no binary

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
# Extension now passes only [hook, "omp"] -- no project arg3.
grep -q '"omp"]' "$ext_file" || fail "extension does not call notifier with 'omp' as tool arg"
grep -q "$NOTIFIER" "$ext_file" || fail "extension does not embed the resolved notifier path"
is_omp_enabled || fail "is_omp_enabled returned false after enable"

# JS validity check: copy to .mjs so Node parses it as ESM regardless of version.
if command -v node >/dev/null 2>&1; then
    cp "$ext_file" "$test_dir/code-notify-check.mjs"
    node --check "$test_dir/code-notify-check.mjs" || fail "generated extension is not valid JavaScript"
fi

# Functional import harness: load the extension under a fake pi API and verify
# that the agent_end handler calls exec with the right arguments.
if command -v node >/dev/null 2>&1; then
    node --input-type=module <<HARNESS
import { createRequire } from "module";
import { readFileSync } from "fs";
import { pathToFileURL } from "url";

// Load extension source via dynamic import (requires .mjs or URL with module context).
const modUrl = pathToFileURL("${test_dir}/code-notify-check.mjs").href;
const mod = await import(modUrl);
const factory = mod.default;

// ── fake pi ──────────────────────────────────────────────────────────────────
let capturedArgs;
const fakePi = {
  _handler: null,
  on(event, handler) {
    if (event === "agent_end") this._handler = handler;
  },
  async exec(cmd, args, opts) {
    capturedArgs = { cmd, args, opts };
  },
  logger: { debug() {} },
};

factory(fakePi);
if (!fakePi._handler) throw new Error("agent_end handler was not registered");

// Case A: normal completion (hasUI=true) -> calls exec with ["stop","omp"]
capturedArgs = undefined;
await fakePi._handler({ messages: [] }, { hasUI: true, cwd: "/Users/me/myrepo" });
if (!capturedArgs) throw new Error("exec not called for normal stop");
if (capturedArgs.args[0] !== "stop") throw new Error("expected hook=stop, got " + capturedArgs.args[0]);
if (capturedArgs.args[1] !== "omp")  throw new Error("expected tool=omp");
if (capturedArgs.args.length !== 2)  throw new Error("project must NOT be passed as arg3 (kill-switch fix)");
if (capturedArgs.opts?.cwd !== "/Users/me/myrepo") throw new Error("cwd must be passed via opts.cwd");

// Case B: error outcome -> calls exec with ["error","omp"]
capturedArgs = undefined;
const errMsg = { role: "assistant", stopReason: "error" };
await fakePi._handler({ messages: [errMsg] }, { hasUI: true, cwd: "/Users/me/myrepo" });
if (!capturedArgs) throw new Error("exec not called for error outcome");
if (capturedArgs.args[0] !== "error") throw new Error("expected hook=error for error stopReason, got " + capturedArgs.args[0]);

// Case C: aborted -> calls exec with ["error","omp"]
capturedArgs = undefined;
const abortMsg = { role: "assistant", stopReason: "aborted" };
await fakePi._handler({ messages: [abortMsg] }, { hasUI: true, cwd: "/Users/me/myrepo" });
if (!capturedArgs) throw new Error("exec not called for aborted outcome");
if (capturedArgs.args[0] !== "error") throw new Error("expected hook=error for aborted, got " + capturedArgs.args[0]);

// Case D: headless session (hasUI=false, OMP_NOTIFY_ALL unset) -> NOT called
capturedArgs = undefined;
await fakePi._handler({ messages: [] }, { hasUI: false, cwd: "/Users/me/myrepo" });
if (capturedArgs) throw new Error("exec must not be called for headless sessions");

// Case E: headless with OMP_NOTIFY_ALL=1 -> called
process.env.OMP_NOTIFY_ALL = "1";
capturedArgs = undefined;
await fakePi._handler({ messages: [] }, { hasUI: false, cwd: "/Users/me/myrepo" });
if (!capturedArgs) throw new Error("exec must be called when OMP_NOTIFY_ALL=1");
delete process.env.OMP_NOTIFY_ALL;

// Case F: exec throws -> does NOT propagate (catch absorbs)
capturedArgs = undefined;
const throwingPi = Object.assign({}, fakePi, { async exec() { throw new Error("spawn ENOENT"); } });
throwingPi._handler = null;
factory(throwingPi);
await throwingPi._handler({ messages: [] }, { hasUI: true, cwd: "/Users/me/myrepo" });
// If we reach here, the error was absorbed -- correct.

console.log("HARNESS OK");
HARNESS
    [[ $? -eq 0 ]] || fail "functional JS harness failed"
    pass "functional JS harness: all runtime contract cases pass"
fi

# 3. Runtime contract: notifier.sh stop omp renders a completion notification.
# Extension now sends no arg3; notifier derives project from $PWD (basename).
# Override PWD so the test gets a predictable project name.
(
    cd "$test_dir"
    mkdir -p demo && cd demo
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        bash "$NOTIFIER" stop omp </dev/null
)
grep -q "Task Complete - demo" "$notification_log" || fail "stop omp did not produce a completion notification for the project"
grep -q "omp completed the task" "$notification_log" || fail "stop omp did not use the omp display name"
pass "notifier renders 'stop omp' as a completion notification"

# 3b. Kill-switch suppresses omp stop notifications (P1 regression test).
> "$notification_log"
touch "$HOME/.claude/notifications/disabled"
(
    cd "$test_dir"
    mkdir -p demo2 && cd demo2
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
        bash "$NOTIFIER" stop omp </dev/null
)
[[ ! -s "$notification_log" ]] || fail "kill switch did not suppress omp stop notification"
rm -f "$HOME/.claude/notifications/disabled"
pass "global kill switch suppresses omp notifications"

# 4. Disable removes the managed file.
enable_omp_hooks || fail "enable_omp_hooks failed"
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

# 6. Enable refuses to overwrite a non-managed extension file (P2 clobber fix).
rm -f "$ext_file"
mkdir -p "$(dirname "$ext_file")"
printf '%s\n' "// user's own extension -- do not clobber" > "$ext_file"
enable_omp_hooks 2>/dev/null && fail "enable_omp_hooks should have refused to overwrite non-managed file"
[[ "$(head -n 1 "$ext_file")" == "// user's own extension -- do not clobber" ]] || \
    fail "enable_omp_hooks clobbered a non-managed extension file"
# Clean up for detection test
rm -f "$ext_file"
pass "enable refuses to overwrite a non-managed extension file"

# 7. Detection is binary-only (matches detect_codex / detect_gemini_cli). Leftover
#    ~/.omp dirs -- from a prior `cn on omp`, or from omp's own data that survives a
#    binary uninstall -- must NOT make detect_omp report omp as installed.
(
    sticky_home="$(mktemp -d)/home"
    export HOME="$sticky_home"
    mkdir -p "$sticky_home"
    export OMP_HOME="$sticky_home/.omp"
    # config.sh was sourced at the top of this file; its OMP_* vars leak into this
    # subshell and would shadow the fresh OMP_HOME (config.sh uses ${VAR:-default}).
    # Clear them so every omp path recomputes under sticky_home.
    unset OMP_EXTENSIONS_DIR OMP_EXTENSION_FILE
    source "$LIB_DIR/utils/detect.sh"
    source "$LIB_DIR/core/config.sh"
    PATH="/usr/bin:/bin:/usr/sbin:/sbin"   # deliberately no omp binary on PATH
    # Simulate leftovers: omp's own data dir, plus a full enable+disable cycle.
    mkdir -p "$OMP_HOME/agent/sessions"
    : > "$OMP_HOME/agent/agent.db"
    enable_omp_hooks &>/dev/null || true
    disable_omp_hooks &>/dev/null || true
    if detect_omp &>/dev/null; then
        echo "FAIL: detect_omp reported omp installed with no binary (leftover ~/.omp dir fooled it)"
        exit 1
    fi
    rm -rf "$sticky_home"
)
pass "detect_omp is binary-only: leftover ~/.omp dirs do not trigger detection"

echo "All omp extension tests passed"
