#!/bin/bash

# Simple test suite for Code-Notify

set -e

# Run the notifier's post-banner tail (channels, usage check, logging)
# synchronously so log/curl assertions are deterministic and temp HOMEs tear
# down cleanly. Production leaves it detached for a faster-returning hook.
export CODE_NOTIFY_TAIL_SYNC=1

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
test_start() {
    echo -n "Testing $1... "
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    echo -e "${GREEN}PASS${RESET}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    echo -e "${RED}FAIL${RESET}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test_script() {
    local script="$1"
    local output
    output="$(mktemp)"

    if bash "$script" >"$output" 2>&1; then
        rm -f "$output"
        return 0
    fi

    sed 's/^/  /' "$output"
    rm -f "$output"
    return 1
}

# Change to project root
cd "$(dirname "$0")/.."
CURRENT_VERSION="$(awk -F'"' '/^VERSION=/{print $2}' bin/code-notify)"

# Test 1: Main executable exists and is executable
test_start "main executable exists"
if [[ -x "bin/code-notify" ]]; then
    test_pass
else
    test_fail "bin/code-notify not found or not executable"
fi

# Test 2: Can show version
test_start "version command"
if ./bin/code-notify version 2>&1 | grep -q "version"; then
    test_pass
else
    test_fail "version command failed"
fi

# Test 3: Can show help
test_start "help command"
if ./bin/code-notify help 2>&1 | grep -q "USAGE"; then
    test_pass
else
    test_fail "help command failed"
fi

# Test 4: Library files exist
test_start "library files"
if [[ -f "lib/code-notify/utils/colors.sh" ]] && \
   [[ -f "lib/code-notify/utils/detect.sh" ]] && \
   [[ -f "lib/code-notify/core/config.sh" ]]; then
    test_pass
else
    test_fail "missing library files"
fi

# Test 5: Command routing (cn alias simulation)
test_start "cn command routing"
if CN_TEST=1 ./bin/code-notify help 2>&1 | grep -q "Code-Notify"; then
    test_pass
else
    test_fail "command routing failed"
fi

# Test 6: Check syntax of all shell scripts
test_start "shell script syntax"
SYNTAX_ERROR=0
for script in bin/code-notify lib/code-notify/**/*.sh; do
    if [[ -f "$script" ]]; then
        if ! bash -n "$script" 2>/dev/null; then
            SYNTAX_ERROR=1
            echo -e "\n  ${YELLOW}Syntax error in: $script${RESET}"
        fi
    fi
done
if [[ $SYNTAX_ERROR -eq 0 ]]; then
    test_pass
else
    test_fail "syntax errors found"
fi

# Test 7: update command is exposed in help
test_start "update command in help"
if ./bin/code-notify help 2>&1 | grep -q "update"; then
    test_pass
else
    test_fail "update command missing from help"
fi

# Test 8: update check command works
test_start "update check command"
if CODE_NOTIFY_INSTALL_METHOD=script CODE_NOTIFY_LATEST_VERSION="$CURRENT_VERSION" ./bin/code-notify update check 2>&1 | grep -q "Code-Notify is up to date"; then
    test_pass
else
    test_fail "update check command failed"
fi

# Test 9: update command skips reinstalling current versions
test_start "no-op update command"
if CODE_NOTIFY_INSTALL_METHOD=script CODE_NOTIFY_LATEST_VERSION="$CURRENT_VERSION" ./bin/code-notify update 2>&1 | grep -q "Code-Notify is up to date"; then
    test_pass
else
    test_fail "update command did not skip reinstalling the current version"
fi

# Test 10: project enable warns when Claude trust is missing
test_start "project trust warning"
if run_test_script tests/test-project-trust-warning.sh; then
    test_pass
else
    test_fail "project trust warning behavior failed"
fi

# Test 11: explicit all aliases map to global behavior
test_start "all tool aliases"
if run_test_script tests/test-all-alias.sh; then
    test_pass
else
    test_fail "all aliases failed"
fi

# Test 12: npm launchers can route to the shell runtime
test_start "npm launcher routing"
if node ./bin/npm-cn.js version 2>&1 | grep -q "code-notify version"; then
    test_pass
else
    test_fail "npm launcher version command failed"
fi

# Test 13: repeated notification states are deduped
test_start "notification dedupe"
if run_test_script tests/test-notification-dedupe.sh; then
    test_pass
else
    test_fail "notification dedupe failed"
fi

# Test 14: Codex payloads are parsed into notifications correctly
test_start "codex payload parsing"
if run_test_script tests/test-codex-notify.sh; then
    test_pass
else
    test_fail "codex payload parsing failed"
fi

# Test 14b: Antigravity (agy) event payloads map to the right notifications
test_start "antigravity payload parsing"
if run_test_script tests/test-antigravity-notify.sh; then
    test_pass
else
    test_fail "antigravity payload parsing failed"
fi

# Test 14b2: Antigravity tool-name extraction works without jq/python3
test_start "antigravity tool-name fallback"
if run_test_script tests/test-agy-tool-name-fallback.sh; then
    test_pass
else
    test_fail "antigravity tool-name fallback failed"
fi

# Test 14b3: Antigravity approval banner is scoped to commands agy will prompt on
test_start "antigravity permission decision"
if run_test_script tests/test-agy-permission-decision.sh; then
    test_pass
else
    test_fail "antigravity permission decision failed"
fi

# Test 14c: Antigravity status reads agy's managed plugin copy as ground truth
test_start "antigravity status source"
if run_test_script tests/test-antigravity-status.sh; then
    test_pass
else
    test_fail "antigravity status source failed"
fi

# Test 14d: Antigravity hook commands survive spaces in the staging/HOME path
test_start "antigravity spaced paths"
if run_test_script tests/test-antigravity-spaces.sh; then
    test_pass
else
    test_fail "antigravity spaced paths failed"
fi

# Test 15: Windows PowerShell status regex stays .NET-safe
test_start "delivery channels"
if run_test_script tests/test-channels.sh; then
    test_pass
else
    test_fail "delivery channels failed"
fi

test_start "snooze"
if run_test_script tests/test-snooze.sh; then
    test_pass
else
    test_fail "snooze failed"
fi

test_start "persistent alerts"
if run_test_script tests/test-persistent-alerts.sh; then
    test_pass
else
    test_fail "persistent alerts failed"
fi

test_start "wording styles"
if run_test_script tests/test-wording-style.sh; then
    test_pass
else
    test_fail "wording styles failed"
fi

test_start "tts cache project separation"
if run_test_script tests/test-tts-cache.sh; then
    test_pass
else
    test_fail "tts cache project separation failed"
fi

test_start "voice cache project scoping"
if run_test_script tests/test-voice-cache-project.sh; then
    test_pass
else
    test_fail "voice cache project scoping failed"
fi

test_start "speech queue"
if run_test_script tests/test-speech-queue.sh; then
    test_pass
else
    test_fail "speech queue failed"
fi

test_start "usage alerts"
if run_test_script tests/test-usage-alerts.sh; then
    test_pass
else
    test_fail "usage alerts failed"
fi

test_start "windows status regex"
if run_test_script tests/test-windows-status-regex.sh; then
    test_pass
else
    test_fail "windows status regex failed"
fi

# Test 16: project-scoped hooks bypass the global kill switch
test_start "project kill switch override"
if run_test_script tests/test-project-kill-switch.sh; then
    test_pass
else
    test_fail "project kill switch override failed"
fi

# Test 17: project status/disable stay aligned with settings.json
test_start "project settings consistency"
if run_test_script tests/test-project-settings-consistency.sh; then
    test_pass
else
    test_fail "project settings consistency failed"
fi

# Test 18: click-through resolver keeps lookup order and defaults stable
test_start "click-through resolver"
if run_test_script tests/test-click-through-resolver.sh; then
    test_pass
else
    test_fail "click-through resolver failed"
fi

# Test: clicking a notification jumps back to the originating tmux pane
test_start "tmux click-to-focus"
if run_test_script tests/test-tmux-focus.sh; then
    test_pass
else
    test_fail "tmux click-to-focus failed"
fi

# Test: a queued prompt submission keeps the running indicator across the
# ending turn's stop teardown
test_start "tmux queued-prompt indicator"
if run_test_script tests/test-tmux-queued-prompt.sh; then
    test_pass
else
    test_fail "tmux queued-prompt indicator failed"
fi

# Test: notifications badge the originating tmux window name with the event icon
test_start "tmux window badge"
if run_test_script tests/test-tmux-badge.sh; then
    test_pass
else
    test_fail "tmux window badge failed"
fi

# Test: a stop silenced only by the (process-wide) stop rate limit still badges
# its window, while hard suppressors withhold the badge along with the alert
test_start "stop rate-limit badge"
if run_test_script tests/test-stop-rate-limit-badge.sh; then
    test_pass
else
    test_fail "stop rate-limit badge failed"
fi

# Test 19: click-through commands persist mappings and drive notifier activation
test_start "click-through commands"
if run_test_script tests/test-click-through.sh; then
    test_pass
else
    test_fail "click-through commands failed"
fi

# Test 20: rate-limit state files live under notifications/state with legacy fallback
test_start "notification state dir"
if run_test_script tests/test-notification-state-dir.sh; then
    test_pass
else
    test_fail "notification state dir failed"
fi

# Test 21: Windows notifier keeps rate-limit state under notifications/state
test_start "windows rate-limit state"
if run_test_script tests/test-windows-rate-limit-state.sh; then
    test_pass
else
    test_fail "windows rate-limit state failed"
fi

# Test 22: Claude hook detection only matches current hooks and preserves unrelated entries on Windows
test_start "windows Claude hook preservation"
if run_test_script tests/test-windows-claude-hook-preservation.sh; then
    test_pass
else
    test_fail "windows Claude hook preservation failed"
fi

# Windows wording command writes the state files the Windows notifier reads
test_start "windows wording styles"
if run_test_script tests/test-windows-wording.sh; then
    test_pass
else
    test_fail "windows wording styles failed"
fi

# Test 23: Claude event alerts install and remove dedicated hooks
test_start "Claude event alert hooks"
if run_test_script tests/test-claude-event-alerts.sh; then
    test_pass
else
    test_fail "Claude event alert hooks failed"
fi

test_start "Claude delegated-work completion deferral"
if run_test_script tests/test-claude-delegated-work.sh; then
    test_pass
else
    test_fail "Claude delegated-work completion deferral failed"
fi

test_start "ask_user notification lifecycle"
if run_test_script tests/test-ask-user-alert.sh; then
    test_pass
else
    test_fail "ask_user notification lifecycle failed"
fi

# Test 24: UserPromptSubmit badge-clear hook installs/removes across jq+python
test_start "badge-clear hook install"
if run_test_script tests/test-badge-clear-hook.sh; then
    test_pass
else
    test_fail "badge-clear hook install failed"
fi

# Test 25: hooks replayed by opencode (OPENCODE env set) are suppressed
test_start "opencode hook suppression"
if run_test_script tests/test-opencode-suppression.sh; then
    test_pass
else
    test_fail "opencode hook suppression failed"
fi

# Test 26: StopFailure hook installs/removes and classifies limit vs error
test_start "StopFailure limit-reached hook"
if run_test_script tests/test-stop-failure-hook.sh; then
    test_pass
else
    test_fail "StopFailure limit-reached hook failed"
fi

# Test 27: Per-event sound pools pick randomly and fall back correctly
test_start "per-event sound pools"
if run_test_script tests/test-sound-pool.sh; then
    test_pass
else
    test_fail "per-event sound pools failed"
fi

# Summary
echo ""
echo "Test Summary:"
echo "============="
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${RESET}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${RESET}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}All tests passed!${RESET}"
    exit 0
else
    echo -e "\n${RED}Some tests failed!${RESET}"
    exit 1
fi
