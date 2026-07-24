#!/bin/bash

# The TTS cache must be scoped exactly like the spoken phrase. With
# `cn wording project voice off` the message names no project, so two
# worktrees speaking the same words must share ONE cache entry (one paid
# synthesis) and its filename must not be labelled with whichever project
# happened to synthesize it first. With the project spoken, the entries stay
# separate and labelled.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
NOTIFIER="$ROOT_DIR/lib/code-notify/core/notifier.sh"
CN="$ROOT_DIR/bin/code-notify"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Speech is only wired up on macOS (see the `macos)` branch of notifier.sh's
# OS case statement — Linux never calls speak_notification).
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SKIP: voice cache project test requires macOS"
    exit 0
fi

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODE_NOTIFY_CACHE_DIR="$test_dir/cache"
export CODE_NOTIFY_SKIP_USAGE_CHECK=1
export ELEVENLABS_API_KEY="test-key"
export CURL_LOG="$test_dir/curl.log"

stub_bin="$test_dir/bin"
mkdir -p "$HOME/.claude/notifications" "$HOME/.claude/logs" \
    "$HOME/.config/code-notify" "$stub_bin" "$CODE_NOTIFY_CACHE_DIR"

cat > "$stub_bin/terminal-notifier" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "-help" ]] && exit 0
exit 0
STUB
cat > "$stub_bin/say" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$stub_bin/afplay" <<'STUB'
#!/bin/bash
exit 0
STUB
# Stands in for the ElevenLabs API: records the call and writes fake audio to
# the -o target so the cache entry lands where the real synthesis would.
cat > "$stub_bin/curl" <<'STUB'
#!/bin/bash
out=""
prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out="$arg"
    prev="$arg"
done
echo "curl-called" >> "$CURL_LOG"
[[ -n "$out" ]] && printf 'FAKE-AUDIO' > "$out"
printf '200'
STUB
chmod +x "$stub_bin"/*
fake_path="$stub_bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Speech on, and the voice name the `say` fallback would use.
printf 'TestVoice\n' > "$HOME/.claude/notifications/voice-claude"
printf '%s' '{"engine":"elevenlabs","elevenlabs":{}}' > "$HOME/.config/code-notify/tts.json"

cached_files() {
    find "$CODE_NOTIFY_CACHE_DIR" -name 'tts-*.mp3' -type f 2>/dev/null | sort
}

# Speech runs detached from the hook, so wait for its cache entry to appear.
wait_for_cache_count() {
    local want="$1"
    local _ got
    for _ in $(seq 1 200); do
        got="$(cached_files | grep -c . || true)"
        [[ "$got" == "$want" ]] && return 0
        sleep 0.05
    done
    fail "timed out waiting for $want cache entrie(s), saw: $(cached_files | tr '\n' ' ')"
}

run_stop() {
    local project="$1"
    # Each run must notify: drop the rate-limit state from the previous one.
    rm -rf "$HOME/.claude/notifications/state"
    printf '{}' | PATH="$fake_path" bash "$NOTIFIER" stop claude "$project"
}

# --- project spoken (default): one labelled entry per project ---
: > "$CURL_LOG"
run_stop "alpha-proj"
wait_for_cache_count 1
entry="$(cached_files)"
[[ "$(basename "$entry")" == tts-alpha-proj-* ]] ||
    fail "a spoken project should label its cache entry, got: $(basename "$entry")"
pass "spoken project labels its cache entry"

# --- project silenced: the entry is shared and unlabelled ---
PATH="$fake_path" "$CN" wording project voice off >/dev/null
rm -f "$CODE_NOTIFY_CACHE_DIR"/tts-*.mp3
: > "$CURL_LOG"
run_stop "alpha-proj"
wait_for_cache_count 1
entry="$(cached_files)"
[[ "$(basename "$entry")" != *alpha-proj* ]] ||
    fail "a silenced project must not appear in the cache filename: $(basename "$entry")"
[[ "$(basename "$entry")" =~ ^tts-[0-9a-f]+\.mp3$ ]] ||
    fail "unprojected entry should be tts-<hash>.mp3, got: $(basename "$entry")"
pass "silenced project is absent from the cache filename"

# --- and a second worktree adds no project-scoped entry of its own ---
# The message pools are randomized, so a second run may legitimately speak a
# different phrase and synthesize it; what must never happen is any entry
# carrying a project label, which is what fragments the cache per worktree.
# (That identical phrases then share one entry is covered by test-tts-cache.sh,
# where the key is checked directly instead of through a random pool.)
: > "$CURL_LOG"
run_stop "beta-proj"
sleep 1
after="$(cached_files)"
while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$(basename "$entry")" =~ ^tts-[0-9a-f]+\.mp3$ ]] ||
        fail "silenced projects must leave every entry unlabelled, got: $(basename "$entry")"
done <<< "$after"
pass "a second project adds no project-scoped entry"
