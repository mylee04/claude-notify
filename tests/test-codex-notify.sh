#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFIER="$SCRIPT_DIR/../lib/code-notify/core/notifier.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

wait_for_lines() {
    local file="$1"
    local expected_lines="$2"

    for _ in $(seq 1 40); do
        if [[ -f "$file" ]] && [[ $(wc -l < "$file") -ge "$expected_lines" ]]; then
            return 0
        fi
        sleep 0.05
    done

    return 1
}

run_codex_notifier() {
    local fake_path="$1"
    local payload="$2"

    PATH="$fake_path" \
    CODE_NOTIFY_STOP_RATE_LIMIT_SECONDS=0 \
    CODE_NOTIFY_NOTIFICATION_RATE_LIMIT_SECONDS=180 \
    bash "$NOTIFIER" codex "$payload"
}

write_codex_thread_metadata() {
    local thread_id="$1"
    local originator="$2"
    local source="${3:-vscode}"

    python3 - "$HOME/.codex/state_5.sqlite" "$HOME/.codex/sessions" "$thread_id" "$originator" "$source" <<'PY'
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1])
sessions_dir = pathlib.Path(sys.argv[2])
thread_id = sys.argv[3]
originator = sys.argv[4]
source = sys.argv[5]

rollout_path = sessions_dir / f"{thread_id}.jsonl"
rollout_path.parent.mkdir(parents=True, exist_ok=True)
rollout_path.write_text(
    json.dumps(
        {
            "type": "session_meta",
            "payload": {
                "id": thread_id,
                "originator": originator,
                "source": source,
            },
        }
    )
    + "\n",
    encoding="utf-8",
)

with sqlite3.connect(db_path) as conn:
    cur = conn.cursor()
    cur.execute(
        """
        create table if not exists threads (
            id text primary key,
            source text,
            rollout_path text
        )
        """
    )
    cur.execute(
        "insert or replace into threads (id, source, rollout_path) values (?, ?, ?)",
        (thread_id, source, str(rollout_path)),
    )
    conn.commit()
PY
}

write_t3_thread_metadata() {
    local codex_thread_id="$1"
    local title="$2"

    python3 - "$HOME/.t3/userdata/state.sqlite" "$codex_thread_id" "$title" <<'PY'
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1])
codex_thread_id = sys.argv[2]
title = sys.argv[3]
db_path.parent.mkdir(parents=True, exist_ok=True)

with sqlite3.connect(db_path) as conn:
    conn.execute(
        "create table projection_threads (thread_id text primary key, title text not null)"
    )
    conn.execute(
        """
        create table provider_session_runtime (
            thread_id text primary key,
            provider_name text not null,
            resume_cursor_json text
        )
        """
    )
    conn.execute(
        "insert into projection_threads values (?, ?)",
        ("malformed-runtime", "Wrong thread"),
    )
    conn.execute(
        "insert into provider_session_runtime values (?, ?, ?)",
        ("malformed-runtime", "codex", "not-json"),
    )
    conn.execute(
        "insert into projection_threads values (?, ?)",
        ("non-object-runtime", "Wrong thread"),
    )
    conn.execute(
        "insert into provider_session_runtime values (?, ?, ?)",
        ("non-object-runtime", "codex", json.dumps([])),
    )
    conn.execute(
        "insert into projection_threads values (?, ?)",
        ("matching-runtime", title),
    )
    conn.execute(
        "insert into provider_session_runtime values (?, ?, ?)",
        ("matching-runtime", "codex", json.dumps({"threadId": codex_thread_id})),
    )
PY
}

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
fake_bin="$test_dir/bin"
log_dir="$test_dir/log"
sound_file="$test_dir/custom.aiff"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" "$HOME/.codex" "$fake_bin" "$log_dir"

touch "$sound_file"
: > "$HOME/.claude/notifications/sound-enabled"
printf '%s\n' "$sound_file" > "$HOME/.claude/notifications/sound-custom"

case "$(uname -s)" in
    Darwin)
        notification_log="$log_dir/terminal-notifier.log"
        sound_log="$log_dir/afplay.log"
        cat > "$fake_bin/terminal-notifier" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/afplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    Linux)
        notification_log="$log_dir/notify-send.log"
        sound_log="$log_dir/paplay.log"
        cat > "$fake_bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$notification_log"
EOF
        cat > "$fake_bin/paplay" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sound_log"
EOF
        ;;
    *)
        echo "SKIP: unsupported OS for Codex notify test"
        exit 0
        ;;
esac

chmod +x "$fake_bin"/*

fake_path="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","cwd":"/tmp/demo","client":"codex-exec","input-messages":["Run tests"],"last-assistant-message":"All tests passed"}'
run_codex_notifier "$fake_path" '{"type":"request_permissions","cwd":"/tmp/demo","tool":"exec_command"}'
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","cwd":"/tmp/demo","client":"codex-app","last-assistant-message":"Desktop event"}'

write_codex_thread_metadata "desktop-thread" "Codex Desktop"
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"desktop-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"Desktop-backed event"}'

write_codex_thread_metadata "cli-thread" "Codex CLI" "shell"
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"cli-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"CLI event still notifies"}'

write_t3_thread_metadata "t3-codex-thread" 'Investigate "missing" desktop notifications'
run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"t3-codex-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"T3 event"}'

wait_for_lines "$notification_log" 4 || fail "expected four Codex notification deliveries"
wait_for_lines "$sound_log" 4 || fail "expected four Codex sound playbacks"
wait_for_lines "$HOME/.claude/logs/notifications.log" 4 || fail "expected four Codex notification log entries"

grep -q "Task Complete - demo" "$notification_log" || fail "Codex completion payload did not map to a stop notification"
grep -q "Input Required - demo" "$notification_log" || fail "Codex permission-like payload did not map to an input-required notification"
grep -Fq 'Task Complete - Investigate "missing" desktop notifications' "$notification_log" || fail "T3 thread title was not used as Codex notification context"
[[ $(wc -l < "$notification_log") -eq 4 ]] || fail "desktop-origin Codex events were not suppressed correctly"
[[ $(wc -l < "$sound_log") -eq 4 ]] || fail "desktop-origin Codex sound playback was not suppressed correctly"
[[ $(wc -l < "$HOME/.claude/logs/notifications.log") -eq 4 ]] || fail "desktop-origin Codex log entries were not suppressed correctly"

if [[ "$(uname -s)" == "Darwin" ]]; then
    osascript_log="$log_dir/osascript.log"
    rm "$fake_bin/terminal-notifier"
    cat > "$fake_bin/osascript" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$osascript_log"
EOF
    chmod +x "$fake_bin/osascript"

    run_codex_notifier "$fake_path" '{"type":"agent-turn-complete","thread-id":"t3-codex-thread","cwd":"/tmp/demo","client":"codex-exec","last-assistant-message":"T3 fallback event"}'

    wait_for_lines "$osascript_log" 4 || fail "osascript fallback did not receive notification arguments"
    grep -Fqx 'Task Complete - Investigate "missing" desktop notifications' "$osascript_log" || fail "osascript fallback did not preserve quotes in the T3 thread title"
fi

pass "Codex resolves T3 titles while preserving CLI fallback and desktop suppression"
