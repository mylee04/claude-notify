#!/bin/bash

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
quota_count="$test_dir/quota-count"
curl_log="$test_dir/curl.log"
notify_log="$test_dir/notify.log"
say_log="$test_dir/say.log"
mkdir -p "$HOME/.codex" "$HOME/.claude/notifications" "$HOME/.claude/logs" "$fake_bin"

printf '{"tokens":{"access_token":"codex-token"}}' > "$HOME/.codex/auth.json"
printf '0' > "$quota_count"

case "$(uname -s)" in
    Darwin)
        notifier_name="terminal-notifier"
        ;;
    Linux)
        notifier_name="notify-send"
        ;;
    *)
        echo "SKIP: unsupported OS for usage alert test"
        exit 0
        ;;
esac

cat > "$fake_bin/$notifier_name" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notify_log"
EOF

cat > "$fake_bin/say" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$say_log"
EOF

cat > "$fake_bin/curl" <<EOF
#!/bin/bash
last_arg="\${@: -1}"
if [[ "\$last_arg" == *"wham/usage"* ]]; then
    if [[ -n "\${CODE_NOTIFY_TEST_RESET_AT:-}" ]]; then
        used="\${CODE_NOTIFY_TEST_PRIMARY_USED:-50}"
        secondary_used="\${CODE_NOTIFY_TEST_SECONDARY_USED:-50}"
        primary_reset_at="\${CODE_NOTIFY_TEST_PRIMARY_RESET_AT:-\$CODE_NOTIFY_TEST_RESET_AT}"
        secondary_reset_at="\$CODE_NOTIFY_TEST_RESET_AT"
    else
        count=\$(cat "$quota_count")
        count=\$((count + 1))
        printf '%s' "\$count" > "$quota_count"
        case "\$count" in
            1) used=5 ;;
            2) used=80 ;;
            3) used=91 ;;
            4) used=91 ;;
            5) used=70 ;;
            6) used=91 ;;
            7) used=50 ;;
            8) used=0 ;;
            9) used=0 ;;
            10) used=10 ;;
            *) used=0 ;;
        esac
        secondary_used=50
        primary_reset_at=1900000000
        secondary_reset_at=1900000000
    fi
    printf '{"rate_limit":{"primary_window":{"used_percent":%s,"reset_at":%s},"secondary_window":{"used_percent":%s,"reset_at":%s}}}' \
        "\$used" "\$primary_reset_at" "\$secondary_used" "\$secondary_reset_at"
    exit 0
fi
printf '%s\n' "\$*" >> "$curl_log"
exit 0
EOF
chmod +x "$fake_bin"/*

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" channels add slack "https://hooks.slack.com/services/T000/B000/SECRET" >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage on codex >/dev/null
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts voice off >/dev/null
reset_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$reset_status" | grep -q "Reset voice: .*DISABLED" || fail "reset voice should be configurable separately"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts voice on >/dev/null

run_check() {
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$ROOT_DIR/bin/code-notify" usage check codex >/dev/null
}

run_check
[[ ! -s "$notify_log" ]] || fail "95 percent remaining should not alert"

run_check
grep -q "daily (5h) remaining usage is 20%" "$notify_log" || fail "20 percent threshold alert missing"
first_count=$(wc -l < "$notify_log")

run_check
grep -q "daily (5h) remaining usage is 9%" "$notify_log" || fail "10 percent threshold alert missing"
second_count=$(wc -l < "$notify_log")
[[ "$second_count" -gt "$first_count" ]] || fail "10 percent alert did not add a notification"

run_check
third_count=$(wc -l < "$notify_log")
[[ "$third_count" -eq "$second_count" ]] || fail "repeated 9 percent should not duplicate"

run_check
run_check
repeat_count=$(wc -l < "$notify_log")
[[ "$repeat_count" -gt "$third_count" ]] || fail "threshold alert should re-arm after recovery"

run_check
before_reset_count=$(wc -l < "$notify_log")
run_check
grep -q "token daily limit reset" "$notify_log" || fail "reset alert title should identify the limit window"
grep -q "daily (5h) tokens have reset" "$notify_log" || fail "reset alert message should mention tokens"
after_reset_count=$(wc -l < "$notify_log")
[[ "$after_reset_count" -gt "$before_reset_count" ]] || fail "reset alert did not add a notification"

run_check
same_reset_count=$(wc -l < "$notify_log")
[[ "$same_reset_count" -eq "$after_reset_count" ]] || fail "repeated 100 percent should not duplicate"

run_check
run_check
refill_count=$(grep -c "tokens have reset" "$notify_log")
[[ "$refill_count" -ge 2 ]] || fail "reset alert should re-arm after usage drops"

grep -q "hooks.slack.com/services/T000/B000/SECRET" "$curl_log" || fail "usage alert should deliver to Slack channel"
grep -q "token daily limit reset" "$say_log" || fail "reset voice should use the dedicated reset message"

: > "$notify_log"
: > "$say_log"
printf '7' > "$quota_count"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-state >/dev/null
run_check
[[ ! -s "$notify_log" ]] || fail "first observation at 100 percent should not emit reset notification"
[[ ! -s "$say_log" ]] || fail "first observation at 100 percent should not speak reset voice"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT_DIR/bin/code-notify" usage reset-alerts off >/dev/null
disabled_reset_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$disabled_reset_status" | grep -q "Reset alerts: .*DISABLED" || fail "reset alerts should be optional"

reminder_home="$test_dir/reminder-home"
mkdir -p "$reminder_home/.codex"
printf '{"tokens":{"access_token":"codex-token"}}' > "$reminder_home/.codex/auth.json"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$reminder_home" \
    "$ROOT_DIR/bin/code-notify" usage setup codex >/dev/null

reminder_reset_at=2000169200
reminder_primary_reset_at=2000014400
reminder_now=2000000000

run_reminder_check() {
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$reminder_home" \
        CODE_NOTIFY_USAGE_NOW_EPOCH="$reminder_now" \
        CODE_NOTIFY_TEST_PRIMARY_RESET_AT="$reminder_primary_reset_at" \
        CODE_NOTIFY_TEST_RESET_AT="$reminder_reset_at" \
        CODE_NOTIFY_TEST_PRIMARY_USED="${reminder_primary_used:-50}" \
        CODE_NOTIFY_TEST_SECONDARY_USED="${reminder_secondary_used:-24}" \
        "$ROOT_DIR/bin/code-notify" usage check codex >/dev/null
}

: > "$notify_log"
run_reminder_check
grep -q "weekly (7d) resets in under 48 hours. 76% remains" "$notify_log" || fail "48 hour reset reminder missing"
reminder_count=$(wc -l < "$notify_log")
[[ "$reminder_count" -eq 1 ]] || fail "5h window should not emit long-horizon reset reminders"

run_reminder_check
same_reminder_count=$(wc -l < "$notify_log")
[[ "$same_reminder_count" -eq "$reminder_count" ]] || fail "same reset reminder should not duplicate"

# A full-quota observation must not erase reminders already sent in this cycle.
reminder_secondary_used=1
run_reminder_check
before_full_reminder_count=$(grep -c "weekly (7d) resets in under" "$notify_log")
reminder_secondary_used=0
run_reminder_check
full_reminder_count=$(grep -c "weekly (7d) resets in under" "$notify_log")
[[ "$full_reminder_count" -eq "$before_full_reminder_count" ]] || fail "full quota should suppress advance reminders"
reminder_secondary_used=1
run_reminder_check
after_full_reminder_count=$(grep -c "weekly (7d) resets in under" "$notify_log")
[[ "$after_full_reminder_count" -eq "$before_full_reminder_count" ]] || fail "99 -> 100 -> 99 percent in the same reset cycle should not repeat a reminder"
reminder_secondary_used=24

reminder_now=$((reminder_reset_at - 23 * 3600))
run_reminder_check
grep -q "weekly (7d) resets in under 24 hours" "$notify_log" || fail "24 hour reset reminder missing"

reminder_now=$((reminder_reset_at - 5 * 3600))
before_late_count=$(wc -l < "$notify_log")
run_reminder_check
after_late_count=$(wc -l < "$notify_log")
[[ "$after_late_count" -eq $((before_late_count + 1)) ]] || fail "late watcher should emit only one catch-up reminder"
grep -q "weekly (7d) resets in under 6 hours" "$notify_log" || fail "late watcher should choose the most urgent reminder"

reminder_now=$((reminder_reset_at - 20 * 60))
run_reminder_check
grep -q "weekly (7d) resets in under 30 minutes" "$notify_log" || fail "30 minute reset reminder missing"

# A new reset timestamp must re-arm reminders even without observing full quota.
reminder_reset_at=$((reminder_reset_at + 7 * 24 * 3600))
reminder_now=$((reminder_reset_at - 47 * 3600))
before_new_cycle_count=$(grep -c "weekly (7d) resets in under 48 hours" "$notify_log")
run_reminder_check
new_cycle_count=$(grep -c "weekly (7d) resets in under 48 hours" "$notify_log")
[[ "$new_cycle_count" -eq $((before_new_cycle_count + 1)) ]] || fail "new reset cycle should re-arm the 48 hour reminder"
run_reminder_check
repeated_new_cycle_count=$(grep -c "weekly (7d) resets in under 48 hours" "$notify_log")
[[ "$repeated_new_cycle_count" -eq "$new_cycle_count" ]] || fail "new reset cycle reminder should still be deduplicated"

: > "$notify_log"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$reminder_home" \
    "$ROOT_DIR/bin/code-notify" usage reset-state >/dev/null
reminder_primary_used=0
reminder_secondary_used=0
run_reminder_check
[[ ! -s "$notify_log" ]] || fail "full quota should not emit a reset reminder"

PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$reminder_home" \
    "$ROOT_DIR/bin/code-notify" usage reset-reminders off >/dev/null
reminder_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$reminder_home" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$reminder_status" | grep -q "Reset reminders: .*DISABLED" || fail "reset reminders should be optional"

watch_home="$test_dir/watch-home"
mkdir -p "$watch_home/.codex"
printf '{"tokens":{"access_token":"codex-token"}}' > "$watch_home/.codex/auth.json"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" \
    "$ROOT_DIR/bin/code-notify" usage setup codex --watch --interval 60 >/dev/null
watch_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" "$ROOT_DIR/bin/code-notify" usage status)
printf '%s' "$watch_status" | grep -q "Watcher: .*RUNNING" || fail "setup --watch should start background watcher"
PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" \
    "$ROOT_DIR/bin/code-notify" usage watch stop >/dev/null
stopped_status=$(PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$watch_home" "$ROOT_DIR/bin/code-notify" usage watch status)
printf '%s' "$stopped_status" | grep -q "Watcher: .*STOPPED" || fail "usage watcher should stop cleanly"

pass "usage alerts detect Codex thresholds, reset reminders, and reset transitions without duplicates"
