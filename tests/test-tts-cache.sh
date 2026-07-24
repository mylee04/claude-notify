#!/bin/bash

# ElevenLabs cache entries should be grouped visibly by project and must not
# collide when the same message is spoken from different worktrees — but only
# when the spoken phrase actually names the project. A project-agnostic phrase
# gets one shared entry, so it is synthesized (and paid for) once in total.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

export HOME="$test_dir/home"
export CODE_NOTIFY_CACHE_DIR="$test_dir/cache"
source "$ROOT_DIR/lib/code-notify/utils/tts.sh"

key_one="$(tts_cache_key 'Task complete' voice model first-project)"
key_two="$(tts_cache_key 'Task complete' voice model second-project)"
[[ "$key_one" != "$key_two" ]] || fail "cache key should include the project"

cache_path="$(tts_cache_path "$key_one" 'My Project!')"
[[ "$cache_path" == "$CODE_NOTIFY_CACHE_DIR/tts-My-Project-$key_one.mp3" ]] ||
    fail "cache filename should include a safe project label"

pass "TTS cache separates and labels projects"

# Without a project (voice project wording off, or `cn voice elevenlabs test`)
# the phrase names no project, so every project shares one entry and the
# filename carries no project segment.
key_none="$(tts_cache_key 'Task complete' voice model '')"
[[ "$key_none" == "$(tts_cache_key 'Task complete' voice model)" ]] ||
    fail "an omitted project should key the same as an empty one"
[[ "$key_none" != "$key_one" ]] || fail "unprojected phrases should not reuse a project's key"

none_path="$(tts_cache_path "$key_none" '')"
[[ "$none_path" == "$CODE_NOTIFY_CACHE_DIR/tts-$key_none.mp3" ]] ||
    fail "unprojected cache filename should carry no project segment, got: $none_path"
[[ "$none_path" == "$(tts_cache_path "$key_none")" ]] ||
    fail "an omitted project should path the same as an empty one"

pass "TTS cache shares one entry for project-agnostic phrases"
